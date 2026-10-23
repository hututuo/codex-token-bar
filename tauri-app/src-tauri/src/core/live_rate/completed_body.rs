//! Bounded completed-response-body throughput samples from Codex rollouts.
//!
//! This reader owns an independent tail cursor. It does not touch the live
//! rollout metrics cursor, and it never persists response text.

use super::state::{read_recent_rollout_threads, RolloutThread};
use super::LiveRateSourceScope;
use crate::models::{BodySpeedHistoryPage, SpeedSample};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::Condvar;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const RECENT_THREAD_LIMIT: usize = 64;
const MAX_BACKFILL_SECONDS: f64 = 30.0 * 86_400.0;
const MAX_TOTAL_BYTES_PER_POLL: usize = 64 * 1024 * 1024;
const MAX_FILE_BYTES_PER_POLL: usize = 8 * 1024 * 1024;
const MAX_LINE_BYTES: usize = 1_100_000;
const MAX_BODY_BYTES: usize = 1024 * 1024;
const BOUNDARY_BYTES: usize = 256;
const MAX_PENDING_ITEMS: usize = 32;
const MAX_PENDING_BODY_BYTES: usize = 4 * 1024 * 1024;
const MAX_MODELS: usize = 128;
const MAX_SEEN_IDS: usize = 10_000;
const MAX_RETAINED_RESULTS: usize = 10_000;
const MAX_JOB_SCOPES: usize = 8;
const MAX_READER_SCOPES: usize = 16;
const MAX_READER_FILES: usize = 128;
const RESCAN_INTERVAL: Duration = Duration::from_secs(1);
const HISTORY_PAGE_LIMIT: usize = 100;

static JOBS: OnceLock<Mutex<HashMap<LiveRateSourceScope, Job>>> = OnceLock::new();
#[cfg(test)]
static JOBS_IDLE: OnceLock<Condvar> = OnceLock::new();
static READERS: OnceLock<Mutex<HashMap<LiveRateSourceScope, Reader>>> = OnceLock::new();

#[derive(Default)]
struct Job {
    in_flight: bool,
    generation: u64,
    last_started: Option<Instant>,
    last_used: Option<Instant>,
    samples: VecDeque<SpeedSample>,
}

#[derive(Default)]
struct Reader {
    last_used: Option<Instant>,
    files: HashMap<PathBuf, FileState>,
}

struct FileState {
    identity: String,
    cursor: u64,
    modified_at: Option<SystemTime>,
    boundary: Vec<u8>,
    discard_until_newline: bool,
    carry: Vec<u8>,
    assembler: Assembler,
}

impl FileState {
    fn new(identity: String, size: u64, modified_at: Option<SystemTime>, header: &[u8]) -> Self {
        let mut assembler = Assembler::default();
        if let Some(line) = header.split(|byte| *byte == b'\n').next() {
            assembler.configure(line);
        }
        let backfill_start = size.saturating_sub(MAX_FILE_BYTES_PER_POLL as u64);
        Self {
            identity,
            cursor: backfill_start,
            modified_at,
            boundary: Vec::new(),
            discard_until_newline: backfill_start > 0,
            carry: Vec::new(),
            assembler,
        }
    }

    fn consume_bytes(&mut self, bytes: &[u8], thread: &str, now: f64) -> Vec<SpeedSample> {
        let mut input = Vec::with_capacity(self.carry.len().saturating_add(bytes.len()));
        if !self.discard_until_newline {
            input.extend_from_slice(&self.carry);
        }
        self.carry.clear();
        input.extend_from_slice(bytes);

        let mut output = Vec::new();
        let mut start = 0;
        for (index, byte) in input.iter().enumerate() {
            if *byte != b'\n' {
                continue;
            }
            if self.discard_until_newline {
                self.discard_until_newline = false;
            } else if index.saturating_sub(start) <= MAX_LINE_BYTES {
                output.extend(
                    self.assembler
                        .consume_line(&input[start..index], thread, now),
                );
            }
            start = index + 1;
        }

        if self.discard_until_newline {
            return output;
        }
        let remainder = &input[start..];
        if remainder.len() > MAX_LINE_BYTES {
            self.discard_until_newline = true;
            self.carry.clear();
        } else {
            self.carry.extend_from_slice(remainder);
        }
        output
    }
}

#[derive(Default)]
struct Assembler {
    current_turn: Option<String>,
    models: HashMap<String, String>,
    model_order: VecDeque<String>,
    pending: HashMap<(String, String), PendingPart>,
    seen_ids: HashSet<String>,
    seen_order: VecDeque<String>,
    ownership: Ownership,
}

#[derive(Default)]
struct Ownership {
    is_fork: bool,
    is_paginated: bool,
    created_at: Option<f64>,
    child_created_ms: Option<u64>,
    history_boundary: Option<u64>,
    own_start_ordinal: Option<u64>,
    pending_turn_id: Option<String>,
    pending_turn_ordinal: Option<u64>,
    pending_is_context: Option<bool>,
}

#[derive(Default)]
struct PendingPart {
    text: Option<String>,
    started_at: Option<f64>,
    ended_at: Option<f64>,
    touched_at: f64,
    body_phase: Option<String>,
    owned_by_ordinal: bool,
    born_own: bool,
}

impl Assembler {
    fn configure(&mut self, header: &[u8]) {
        let Ok(root) = serde_json::from_slice::<Value>(header) else {
            return;
        };
        if root.get("type").and_then(Value::as_str) != Some("session_meta") {
            return;
        }
        let Some(payload) = root.get("payload") else {
            return;
        };
        let parent = payload
            .get("forked_from_id")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty());
        let subagent = payload.get("thread_source").and_then(Value::as_str) == Some("subagent")
            || payload
                .get("source")
                .and_then(|source| source.get("subagent"))
                .is_some()
            || payload
                .get("agent_role")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty())
            || payload
                .get("agent_path")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty());
        self.ownership.is_fork = parent || subagent;
        self.ownership.is_paginated =
            payload.get("history_mode").and_then(Value::as_str) == Some("paginated");
        self.ownership.child_created_ms = payload
            .get("id")
            .and_then(Value::as_str)
            .and_then(uuid_v7_milliseconds);
        self.ownership.created_at = self
            .ownership
            .child_created_ms
            .map(|milliseconds| milliseconds as f64 / 1_000.0)
            .or_else(|| {
                payload
                    .get("timestamp")
                    .and_then(Value::as_str)
                    .and_then(parse_rfc3339)
                    .filter(|value| value.is_finite())
            });
        self.ownership.history_boundary = payload
            .get("subagent_history_start_ordinal")
            .and_then(Value::as_u64);
    }

    fn owns(&self, root: &Value, turn: Option<&str>) -> bool {
        if !self.ownership.is_fork {
            return true;
        }
        if !self.ownership.is_paginated {
            let event_timestamp = root
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339)
                .filter(|value| value.is_finite());
            let timestamp_own = self
                .ownership
                .created_at
                .zip(event_timestamp)
                .is_some_and(|(created_at, event)| event >= created_at);
            let born_own = self
                .ownership
                .child_created_ms
                .zip(turn.and_then(uuid_v7_milliseconds))
                .is_some_and(|(child, turn)| turn >= child);
            return timestamp_own || born_own;
        }
        if self
            .ownership
            .history_boundary
            .zip(root.get("ordinal").and_then(Value::as_u64))
            .is_some_and(|(boundary, ordinal)| ordinal >= boundary)
        {
            return true;
        }
        if self
            .ownership
            .own_start_ordinal
            .zip(root.get("ordinal").and_then(Value::as_u64))
            .is_some_and(|(start, ordinal)| ordinal >= start)
        {
            return true;
        }
        self.ownership
            .child_created_ms
            .zip(turn.and_then(uuid_v7_milliseconds))
            .is_some_and(|(child, turn)| turn >= child)
    }

    fn consume_line(&mut self, line: &[u8], thread: &str, now: f64) -> Vec<SpeedSample> {
        if line.is_empty() || line.len() > MAX_LINE_BYTES {
            return Vec::new();
        }
        let Ok(root) = serde_json::from_slice::<Value>(line) else {
            return Vec::new();
        };
        let Some(payload) = root.get("payload") else {
            return Vec::new();
        };
        let record_type = root.get("type").and_then(Value::as_str).unwrap_or_default();
        let payload_type = payload
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if record_type == "session_meta" {
            self.configure(line);
            return Vec::new();
        }
        let event_timestamp = root
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339)
            .filter(|value| value.is_finite());
        let timestamp = event_timestamp.unwrap_or(now);

        if record_type == "turn_context"
            || (record_type == "event_msg" && payload_type == "task_started")
        {
            self.observe_own_turn(&root, payload);
            let turn = explicit_turn(&root, payload);
            if let Some(turn) = turn.as_deref().filter(|turn| self.owns(&root, Some(turn))) {
                self.current_turn = Some(turn.to_owned());
                if record_type == "turn_context" {
                    if let Some(model) = payload
                        .get("model")
                        .and_then(Value::as_str)
                        .filter(|model| valid_model(model))
                    {
                        self.remember_model(turn, model);
                    }
                }
            }
            return self.emit_ready(thread, now);
        }

        let part_key = if record_type == "event_msg" && payload_type == "item_completed" {
            let Some(item) = payload.get("item") else {
                return Vec::new();
            };
            if !item
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(|kind| kind.eq_ignore_ascii_case("agentmessage"))
            {
                return Vec::new();
            }
            let (Some(turn), Some(item_id)) = (
                explicit_turn(&root, payload),
                item.get("id")
                    .and_then(Value::as_str)
                    .filter(|id| !id.is_empty() && id.len() <= 512),
            ) else {
                return Vec::new();
            };
            if !self.owns(&root, Some(&turn)) {
                return Vec::new();
            }
            let started = payload
                .get("started_at_ms")
                .and_then(Value::as_f64)
                .or_else(|| item.get("started_at_ms").and_then(Value::as_f64));
            let ended = payload
                .get("completed_at_ms")
                .and_then(Value::as_f64)
                .or_else(|| item.get("completed_at_ms").and_then(Value::as_f64));
            let (Some(started), Some(ended)) = (started, ended) else {
                return Vec::new();
            };
            if !started.is_finite() || !ended.is_finite() || started <= 0.0 || ended <= started {
                return Vec::new();
            }
            (
                (turn, item_id.to_owned()),
                Some((started / 1_000.0, ended / 1_000.0)),
                None,
                body_phase(item.get("phase").or_else(|| payload.get("phase"))),
            )
        } else if record_type == "response_item"
            && payload_type == "message"
            && payload.get("role").and_then(Value::as_str) == Some("assistant")
        {
            let Some(item_id) = payload
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty() && id.len() <= 512)
            else {
                return Vec::new();
            };
            let turn = explicit_turn(&root, payload).or_else(|| self.current_turn.clone());
            let Some(turn) = turn.filter(|turn| self.owns(&root, Some(turn))) else {
                return Vec::new();
            };
            let Some(content) = payload.get("content").and_then(Value::as_array) else {
                return Vec::new();
            };
            let mut body = String::new();
            let mut body_bytes = 0usize;
            for part in content {
                if part.get("type").and_then(Value::as_str) != Some("output_text") {
                    continue;
                }
                let Some(text) = part.get("text").and_then(Value::as_str) else {
                    continue;
                };
                body_bytes = body_bytes.saturating_add(text.len());
                if body_bytes > MAX_BODY_BYTES {
                    return Vec::new();
                }
                body.push_str(text);
            }
            if body.is_empty() || body_bytes > MAX_BODY_BYTES {
                return Vec::new();
            }
            (
                (turn, item_id.to_owned()),
                None,
                Some(body),
                body_phase(payload.get("phase")),
            )
        } else {
            return Vec::new();
        };

        let ((turn, item), timing, text, phase) = part_key;
        let ordinal = root.get("ordinal").and_then(Value::as_u64);
        let owned_by_ordinal = self.ownership.is_paginated
            && (self
                .ownership
                .history_boundary
                .zip(ordinal)
                .is_some_and(|(boundary, ordinal)| ordinal >= boundary)
                || self
                    .ownership
                    .own_start_ordinal
                    .zip(ordinal)
                    .is_some_and(|(start, ordinal)| ordinal >= start));
        let born_own = self
            .ownership
            .child_created_ms
            .zip(uuid_v7_milliseconds(&turn))
            .is_some_and(|(child, turn)| turn >= child);
        let key = (turn, item);
        let pending = self.pending.entry(key).or_default();
        pending.touched_at = timestamp;
        pending.owned_by_ordinal |= owned_by_ordinal;
        pending.born_own |= born_own;
        if phase.is_some() {
            pending.body_phase = phase;
        }
        if let Some((started_at, ended_at)) = timing {
            pending.started_at = Some(started_at);
            pending.ended_at = Some(ended_at);
        }
        if let Some(text) = text {
            pending.text = Some(text);
        }
        self.prune_pending(now);
        self.emit_ready(thread, now)
    }

    fn remember_model(&mut self, turn: &str, model: &str) {
        if !self.models.contains_key(turn) {
            self.model_order.push_back(turn.to_owned());
        }
        self.models.insert(turn.to_owned(), model.to_owned());
        while self.model_order.len() > MAX_MODELS {
            if let Some(oldest) = self.model_order.pop_front() {
                self.models.remove(&oldest);
            }
        }
    }

    // Mirror the paginated-history ownership proof used by the usage parser:
    // a post-child UUID turn_context and its task_started record may use
    // different identities after history migration. A synthetic rollout ID
    // is accepted only as the other half of that ordered pair.
    fn observe_own_turn(&mut self, root: &Value, payload: &Value) {
        if !self.ownership.is_fork
            || !self.ownership.is_paginated
            || self.ownership.own_start_ordinal.is_some()
        {
            return;
        }
        let Some(child_created_ms) = self.ownership.child_created_ms else {
            return;
        };
        let inherited_boundary = self.ownership.history_boundary.unwrap_or(u64::MAX);
        let Some(ordinal) = root
            .get("ordinal")
            .and_then(Value::as_u64)
            .filter(|ordinal| *ordinal < inherited_boundary)
        else {
            return;
        };
        let Some(record_type) = root.get("type").and_then(Value::as_str) else {
            return;
        };
        let payload_type = payload.get("type").and_then(Value::as_str);
        if record_type == "event_msg" && payload_type == Some("task_started") {
            let task_turn = payload.get("turn_id").and_then(Value::as_str);
            if self.ownership.pending_is_context == Some(true)
                && self
                    .ownership
                    .pending_turn_ordinal
                    .is_some_and(|pending| pending < ordinal)
                && task_turn.is_some_and(|task| {
                    self.ownership.pending_turn_id.as_deref() == Some(task)
                        || synthetic_rollout_turn(task)
                })
            {
                self.ownership.own_start_ordinal = Some(ordinal);
                self.clear_pending_own_turn();
                return;
            }
            self.clear_pending_own_turn();
            if let Some(task_turn) = task_turn.filter(|turn| {
                uuid_v7_milliseconds(turn).is_some_and(|born| born >= child_created_ms)
                    || synthetic_rollout_turn(turn)
            }) {
                self.ownership.pending_turn_id = Some(task_turn.to_owned());
                self.ownership.pending_turn_ordinal = Some(ordinal);
            }
        } else if record_type == "turn_context" {
            let Some(context_turn) =
                payload
                    .get("turn_id")
                    .and_then(Value::as_str)
                    .filter(|turn| {
                        uuid_v7_milliseconds(turn).is_some_and(|born| born >= child_created_ms)
                    })
            else {
                return;
            };
            if self.ownership.pending_is_context != Some(true)
                && self
                    .ownership
                    .pending_turn_id
                    .as_deref()
                    .is_some_and(|pending| {
                        pending == context_turn || synthetic_rollout_turn(pending)
                    })
                && self
                    .ownership
                    .pending_turn_ordinal
                    .is_some_and(|pending| pending < ordinal)
            {
                self.ownership.own_start_ordinal = self.ownership.pending_turn_ordinal;
                self.clear_pending_own_turn();
            } else if self.ownership.pending_turn_id.is_none() {
                self.ownership.pending_turn_id = Some(context_turn.to_owned());
                self.ownership.pending_turn_ordinal = Some(ordinal);
                self.ownership.pending_is_context = Some(true);
            }
        }
    }

    fn clear_pending_own_turn(&mut self) {
        self.ownership.pending_turn_id = None;
        self.ownership.pending_turn_ordinal = None;
        self.ownership.pending_is_context = None;
    }

    fn prune_pending(&mut self, now: f64) {
        self.pending.retain(|_, part| {
            part.touched_at.is_finite()
                && part.touched_at <= now + 2.0
                && now - part.touched_at <= MAX_BACKFILL_SECONDS
                && part
                    .text
                    .as_ref()
                    .is_none_or(|text| text.len() <= MAX_BODY_BYTES)
        });
        while self.pending.len() > MAX_PENDING_ITEMS
            || self.pending_body_bytes() > MAX_PENDING_BODY_BYTES
        {
            let Some(oldest) = self
                .pending
                .iter()
                .min_by(|left, right| left.1.touched_at.total_cmp(&right.1.touched_at))
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            self.pending.remove(&oldest);
        }
    }

    fn pending_body_bytes(&self) -> usize {
        self.pending
            .values()
            .filter_map(|part| part.text.as_ref())
            .map(String::len)
            .sum()
    }

    fn emit_ready(&mut self, thread: &str, now: f64) -> Vec<SpeedSample> {
        self.prune_pending(now);
        let ready = self
            .pending
            .iter()
            .filter_map(|((turn, item), part)| {
                let text = part.text.as_ref()?;
                let started = part.started_at?;
                let ended = part.ended_at?;
                Some((
                    turn.clone(),
                    item.clone(),
                    self.models
                        .get(turn)
                        .cloned()
                        .unwrap_or_else(|| "unknown".to_owned()),
                    text.clone(),
                    started,
                    ended,
                    part.body_phase.clone(),
                    part.owned_by_ordinal,
                    part.born_own,
                ))
            })
            .collect::<Vec<_>>();
        let mut output = Vec::new();
        for (
            turn,
            item,
            model,
            text,
            started_at,
            ended_at,
            body_phase,
            owned_by_ordinal,
            born_own,
        ) in ready
        {
            let key = (turn.clone(), item.clone());
            self.pending.remove(&key);
            let duration = ended_at - started_at;
            if !started_at.is_finite()
                || !ended_at.is_finite()
                || !duration.is_finite()
                || started_at <= 0.0
                || ended_at <= started_at
                || ended_at < now - MAX_BACKFILL_SECONDS
                || ended_at > now + 2.0
                || (self.ownership.is_fork
                    && self
                        .ownership
                        .created_at
                        .is_some_and(|created_at| started_at < created_at)
                    && !owned_by_ordinal
                    && !born_own)
                || model.is_empty()
                || model.len() > 256
                || text.is_empty()
                || text.len() > MAX_BODY_BYTES
            {
                continue;
            }
            let output_tokens = match u32::try_from(
                tiktoken_rs::o200k_base_singleton()
                    .encode_ordinary(&text)
                    .len(),
            ) {
                Ok(tokens) if tokens > 0 => tokens,
                _ => continue,
            };
            let id = stable_id(thread, &turn, &item);
            if !self.seen_ids.insert(id.clone()) {
                continue;
            }
            self.seen_order.push_back(id.clone());
            while self.seen_order.len() > MAX_SEEN_IDS {
                if let Some(oldest) = self.seen_order.pop_front() {
                    self.seen_ids.remove(&oldest);
                }
            }
            let tokens_per_second = f64::from(output_tokens) / duration;
            if !tokens_per_second.is_finite() {
                continue;
            }
            let mut sample = SpeedSample {
                id,
                thread_id: thread.to_owned(),
                turn_id: turn,
                item_id: item,
                model: Some(model),
                started_at,
                ended_at,
                output_tokens,
                output_characters: text.chars().count() as u64,
                output_bytes: text.len() as u64,
                chunk_count: 0,
                duration_seconds: duration,
                tokens_per_second,
                confidence: "low".to_owned(),
                network_warning: None,
                source: "Codex rollout completed-body / local o200k_base".to_owned(),
                measurement_kind: Some("completed_body".to_owned()),
                tokenizer: Some("o200k_base".to_owned()),
                body_phase,
                quality_reason: None,
            };
            apply_body_quality(&mut sample);
            output.push(sample);
        }
        output
    }
}

impl Reader {
    fn read_threads(&mut self, home: &Path, now: f64) -> rusqlite::Result<Vec<SpeedSample>> {
        let threads = read_recent_rollout_threads(home, RECENT_THREAD_LIMIT)?;
        self.read_thread_files(threads, now)
    }

    fn read_thread_files(
        &mut self,
        threads: Vec<RolloutThread>,
        now: f64,
    ) -> rusqlite::Result<Vec<SpeedSample>> {
        let mut budget = MAX_TOTAL_BYTES_PER_POLL;
        let mut file_count = 0usize;
        let mut seen_paths = HashSet::new();
        let mut samples = Vec::new();

        for thread in threads {
            if budget == 0
                || file_count >= RECENT_THREAD_LIMIT
            {
                continue;
            }
            if thread.id.is_empty()
                || thread.id.len() > 512
                || !seen_paths.insert(thread.rollout_path.clone())
            {
                continue;
            }
            let Ok(mut file) = File::open(&thread.rollout_path) else {
                continue;
            };
            let Ok(metadata) = file.metadata() else {
                continue;
            };
            if !metadata.is_file() {
                continue;
            }
            file_count += 1;
            let size = metadata.len();
            let modified_at = metadata.modified().ok();
            let identity = file_identity(&thread.rollout_path, &metadata);
            let already_bound = self.files.contains_key(&thread.rollout_path);
            if !already_bound
                && modified_at.is_some_and(|modified| {
                    now.is_finite()
                        && modified
                            .duration_since(UNIX_EPOCH)
                            .ok()
                            .is_some_and(|modified| {
                                modified.as_secs_f64() < now - MAX_BACKFILL_SECONDS
                            })
                })
            {
                continue;
            }
            let mut needs_reset = self.files.get(&thread.rollout_path).is_none_or(|state| {
                state.identity != identity
                    || size < state.cursor
                    || (size == state.cursor && state.modified_at != modified_at)
            });
            let mut per_file_budget = MAX_FILE_BYTES_PER_POLL;
            if !needs_reset {
                let state = self
                    .files
                    .get(&thread.rollout_path)
                    .expect("bound reader state");
                let boundary_size = state.cursor.min(BOUNDARY_BYTES as u64) as usize;
                if boundary_size > budget || boundary_size > per_file_budget {
                    continue;
                }
                let boundary = match read_boundary(&mut file, state.cursor) {
                    Ok(boundary) => boundary,
                    Err(_) => continue,
                };
                budget = budget.saturating_sub(boundary.len());
                per_file_budget = per_file_budget.saturating_sub(boundary.len());
                needs_reset = boundary != state.boundary;
            }
            if needs_reset {
                let header = match read_header(&mut file, &mut budget, &mut per_file_budget) {
                    Ok(header) => header,
                    Err(_) => {
                        self.files.remove(&thread.rollout_path);
                        continue;
                    }
                };
                if header.is_empty() {
                    self.files.remove(&thread.rollout_path);
                    continue;
                }
                let mut state = FileState::new(identity, size, modified_at, &header);
                let boundary_size = state.cursor.min(BOUNDARY_BYTES as u64) as usize;
                if boundary_size > budget || boundary_size > per_file_budget {
                    self.files.remove(&thread.rollout_path);
                    continue;
                }
                state.boundary = match read_boundary(&mut file, state.cursor) {
                    Ok(boundary) => boundary,
                    Err(_) => {
                        self.files.remove(&thread.rollout_path);
                        continue;
                    }
                };
                budget = budget.saturating_sub(state.boundary.len());
                per_file_budget = per_file_budget.saturating_sub(state.boundary.len());
                self.files.insert(thread.rollout_path.clone(), state);
            }
            let Some(state) = self.files.get_mut(&thread.rollout_path) else {
                continue;
            };
            state.modified_at = modified_at;
            if size <= state.cursor || budget == 0 || per_file_budget == 0 {
                continue;
            }
            let amount = (size - state.cursor)
                .min(budget as u64)
                .min(per_file_budget as u64) as usize;
            if amount == 0 {
                continue;
            }
            if file.seek(SeekFrom::Start(state.cursor)).is_err() {
                continue;
            }
            let mut bytes = vec![0u8; amount];
            let Ok(read) = file.read(&mut bytes) else {
                continue;
            };
            bytes.truncate(read);
            state.cursor = state.cursor.saturating_add(read as u64);
            state.boundary = advance_boundary(&state.boundary, &bytes);
            budget = budget.saturating_sub(read);
            per_file_budget = per_file_budget.saturating_sub(read);
            let _remaining_file_budget = per_file_budget;
            samples.extend(state.consume_bytes(&bytes, &thread.id, now));
        }
        if self.files.len() > MAX_READER_FILES {
            self.files.retain(|path, _| seen_paths.contains(path));
        }
        Ok(samples)
    }
}

fn read_header(
    file: &mut File,
    budget: &mut usize,
    per_file_budget: &mut usize,
) -> std::io::Result<Vec<u8>> {
    if *budget == 0 || *per_file_budget == 0 {
        return Ok(Vec::new());
    }
    file.seek(SeekFrom::Start(0))?;
    let limit = MAX_LINE_BYTES.min(*budget).min(*per_file_budget);
    let mut bytes = vec![0u8; limit];
    let read = file.read(&mut bytes)?;
    bytes.truncate(read);
    *budget = budget.saturating_sub(read);
    *per_file_budget = per_file_budget.saturating_sub(read);
    if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
        bytes.truncate(newline);
    } else if read == limit && read == MAX_LINE_BYTES {
        return Ok(Vec::new());
    }
    Ok(bytes)
}

fn read_boundary(file: &mut File, cursor: u64) -> std::io::Result<Vec<u8>> {
    let length = cursor.min(BOUNDARY_BYTES as u64) as usize;
    let start = cursor.saturating_sub(length as u64);
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = vec![0u8; length];
    file.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn advance_boundary(previous: &[u8], appended: &[u8]) -> Vec<u8> {
    if appended.len() >= BOUNDARY_BYTES {
        return appended[appended.len() - BOUNDARY_BYTES..].to_vec();
    }
    let keep_previous = BOUNDARY_BYTES.saturating_sub(appended.len());
    let previous_start = previous.len().saturating_sub(keep_previous);
    let mut boundary = Vec::with_capacity(BOUNDARY_BYTES);
    boundary.extend_from_slice(&previous[previous_start..]);
    boundary.extend_from_slice(appended);
    boundary
}

fn file_identity(path: &Path, metadata: &fs::Metadata) -> String {
    let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let created = metadata
        .created()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{}:{created}", path.display())
}

fn explicit_turn(root: &Value, payload: &Value) -> Option<String> {
    payload
        .get("turn_id")
        .or_else(|| root.get("turn_id"))
        .or_else(|| {
            payload
                .get("metadata")
                .and_then(|metadata| metadata.get("turn_id"))
        })
        .and_then(Value::as_str)
        .filter(|turn| !turn.is_empty() && turn.len() <= 512)
        .map(ToOwned::to_owned)
}

fn valid_model(model: &str) -> bool {
    !model.is_empty() && model.len() <= 256 && model != "unknown"
}

fn body_phase(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|phase| !phase.is_empty() && phase.len() <= 64)
        .map(ToOwned::to_owned)
}

/// Recompute trust from the recorded numeric fields every time a body sample
/// is collected or exposed. The stored confidence string is legacy metadata.
pub(super) fn apply_body_quality(sample: &mut SpeedSample) {
    let reason = if sample.output_tokens == 0
        || !sample.started_at.is_finite()
        || !sample.ended_at.is_finite()
        || !sample.duration_seconds.is_finite()
        || !sample.tokens_per_second.is_finite()
        || sample.duration_seconds <= 0.0
        || sample.tokens_per_second <= 0.0
    {
        Some("文本或计时过短")
    } else {
        let endpoint_duration = sample.ended_at - sample.started_at;
        let start_millis = (sample.started_at * 1_000.0).round();
        let end_millis = (sample.ended_at * 1_000.0).round();
        if !endpoint_duration.is_finite()
            || (endpoint_duration - sample.duration_seconds).abs() > 0.01
            || !start_millis.is_finite()
            || !end_millis.is_finite()
        {
            Some("计时数据不一致")
        } else if end_millis - start_millis <= 400.0 {
            Some("采样时长不超过 0.4 秒")
        } else {
            let computed_rate = f64::from(sample.output_tokens) / sample.duration_seconds;
            let tolerance = 0.01_f64.max(sample.tokens_per_second.abs() * 0.001);
            if !computed_rate.is_finite()
                || (sample.tokens_per_second - computed_rate).abs() > tolerance
            {
                Some("速率计算不一致")
            } else if sample.tokens_per_second > 500.0 {
                Some("速率异常偏高")
            } else if sample.tokens_per_second < 2.0 {
                Some("速率异常偏低")
            } else if sample
                .network_warning
                .as_ref()
                .is_some_and(|warning| !warning.trim().is_empty())
            {
                Some("采样存在异常标记")
            } else if sample.duration_seconds >= 5.0 {
                sample.confidence = "high".to_owned();
                sample.quality_reason = None;
                return;
            } else {
                sample.confidence = "medium".to_owned();
                sample.quality_reason = None;
                return;
            }
        }
    };
    sample.confidence = "low".to_owned();
    sample.quality_reason = reason.map(ToOwned::to_owned);
}

fn parse_rfc3339(value: &str) -> Option<f64> {
    OffsetDateTime::parse(value, &Rfc3339)
        .ok()
        .map(|time| time.unix_timestamp_nanos() as f64 / 1_000_000_000.0)
}

fn current_time_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or_default()
}

fn uuid_v7_milliseconds(value: &str) -> Option<u64> {
    let id = uuid::Uuid::parse_str(value).ok()?;
    (id.get_version_num() == 7).then_some((id.as_u128() >> 80) as u64)
}

fn synthetic_rollout_turn(value: &str) -> bool {
    value.strip_prefix("rollout-").is_some_and(|suffix| {
        !suffix.is_empty()
            && suffix.bytes().all(|byte| byte.is_ascii_digit())
            && suffix.parse::<u64>().is_ok()
    })
}

#[cfg(test)]
pub(super) fn wait_until_idle_for_test(scope: &LiveRateSourceScope, timeout: Duration) -> bool {
    let jobs = JOBS.get_or_init(|| Mutex::new(HashMap::new()));
    let jobs = jobs.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let idle = JOBS_IDLE.get_or_init(Condvar::new);
    let (jobs, _) = idle
        .wait_timeout_while(jobs, timeout, |jobs| {
            jobs.get(scope).is_some_and(|job| job.in_flight)
        })
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    !jobs.get(scope).is_some_and(|job| job.in_flight)
}

fn stable_id(thread: &str, turn: &str, item: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"codex-token-bar/completed-body/v1\0");
    for value in [thread.as_bytes(), turn.as_bytes(), item.as_bytes()] {
        digest.update((value.len() as u64).to_be_bytes());
        digest.update(value);
    }
    let bytes = digest.finalize();
    let mut hex = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(&mut hex, "{byte:02x}");
    }
    format!("completed-body/{hex}")
}

/// Start/advance the local utility reader. The returned numeric samples are
/// cached and replayed until the observed-speed store confirms them by ID.
pub(super) fn poll(home: &Path, scope: &LiveRateSourceScope, now: f64) -> Vec<SpeedSample> {
    let jobs = JOBS.get_or_init(|| Mutex::new(HashMap::new()));
    let (samples, generation_to_start) = {
        let mut jobs = jobs.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !jobs.contains_key(scope) && jobs.len() >= MAX_JOB_SCOPES {
            let recently = Instant::now();
            let oldest_idle = jobs
                .iter()
                .filter(|(_, job)| !job.in_flight)
                .min_by_key(|(_, job)| job.last_used.or(job.last_started).unwrap_or(recently))
                .map(|(key, _)| key.clone());
            let Some(oldest_idle) = oldest_idle else {
                return Vec::new();
            };
            jobs.remove(&oldest_idle);
        }
        let job = jobs.entry(scope.clone()).or_default();
        job.last_used = Some(Instant::now());
        prune_job_samples(&mut job.samples, now);
        let should_start = !job.in_flight
            && job
                .last_started
                .is_none_or(|started| started.elapsed() >= RESCAN_INTERVAL);
        let generation = if should_start {
            job.in_flight = true;
            job.generation = job.generation.saturating_add(1);
            job.last_started = Some(Instant::now());
            Some(job.generation)
        } else {
            None
        };
        (job.samples.iter().cloned().collect::<Vec<_>>(), generation)
    };

    if let Some(generation) = generation_to_start {
        let home = home.to_path_buf();
        let job_scope = scope.clone();
        let worker_scope = job_scope.clone();
        let spawned = thread::Builder::new()
            .name("completed-body-speed-reader".into())
            .spawn(move || {
                let result = {
                    let readers = READERS.get_or_init(|| Mutex::new(HashMap::new()));
                    let mut readers = readers
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    if !readers.contains_key(&worker_scope) && readers.len() >= MAX_READER_SCOPES {
                        let oldest = readers
                            .iter()
                            .min_by_key(|(_, reader)| reader.last_used)
                            .map(|(key, _)| key.clone());
                        if let Some(oldest) = oldest {
                            readers.remove(&oldest);
                        }
                    }
                    let reader = readers.entry(worker_scope.clone()).or_default();
                    reader.last_used = Some(Instant::now());
                    reader.read_threads(&home, now)
                };
                let jobs = JOBS.get().expect("completed-body job manager initialized");
                let mut jobs = jobs.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                if let Some(job) = jobs
                    .get_mut(&worker_scope)
                    .filter(|job| job.generation == generation)
                {
                    job.in_flight = false;
                    job.last_used = Some(Instant::now());
                    if let Ok(samples) = result {
                        let mut known_ids = job
                            .samples
                            .iter()
                            .map(|sample| sample.id.clone())
                            .collect::<HashSet<_>>();
                        for sample in samples {
                            if known_ids.insert(sample.id.clone()) {
                                job.samples.push_back(sample);
                            }
                        }
                        while job.samples.len() > MAX_RETAINED_RESULTS {
                            job.samples.pop_front();
                        }
                    }
                }
                #[cfg(test)]
                JOBS_IDLE.get_or_init(Condvar::new).notify_all();
            });
        if spawned.is_err() {
            if let Some(jobs) = JOBS.get() {
                let mut jobs = jobs.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                if let Some(job) = jobs
                    .get_mut(&job_scope)
                    .filter(|job| job.generation == generation)
                {
                    job.in_flight = false;
                }
                #[cfg(test)]
                JOBS_IDLE.get_or_init(Condvar::new).notify_all();
            }
        }
    }

    samples
}

/// Return a stable bounded page from the numeric body samples retained in the
/// observed-speed store. This path never reads rollout files.
pub(super) fn read_history_page(
    retained_samples: Vec<SpeedSample>,
    offset: usize,
    limit: usize,
    as_of: Option<f64>,
    retention_days: u16,
) -> BodySpeedHistoryPage {
    let as_of = as_of.filter(|value| value.is_finite()).unwrap_or_else(current_time_seconds);
    let retention_days = match retention_days {
        15 | 30 => retention_days,
        _ => 30,
    };
    let cutoff = as_of - f64::from(retention_days) * 86_400.0;
    let limit = limit.clamp(1, HISTORY_PAGE_LIMIT);
    let mut all_samples = retained_samples
        .into_iter()
        .filter(|sample| {
            sample.measurement_kind.as_deref() == Some("completed_body")
                && sample.tokenizer.as_deref() == Some("o200k_base")
                && sample.ended_at.is_finite()
                && sample.ended_at >= cutoff
                && sample.ended_at <= as_of
        })
        .collect::<Vec<_>>();
    all_samples.sort_by(|left, right| {
        right
            .ended_at
            .total_cmp(&left.ended_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    let total_count = all_samples.len();
    let start = offset.min(total_count);
    let end = start.saturating_add(limit).min(total_count);
    let samples = all_samples[start..end]
        .iter()
        .cloned()
        .map(|mut sample| {
            apply_body_quality(&mut sample);
            sample
        })
        .collect();
    BodySpeedHistoryPage {
        samples,
        total_count,
        offset: start,
        limit,
        next_offset: (end < total_count).then_some(end),
        as_of,
        thread_titles: None,
        retention_days,
    }
}

fn prune_job_samples(samples: &mut VecDeque<SpeedSample>, now: f64) {
    if !now.is_finite() {
        return;
    }
    let cutoff = now - MAX_BACKFILL_SECONDS;
    samples.retain(|sample| sample.ended_at.is_finite() && sample.ended_at >= cutoff);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(record_type: &str, payload: Value, timestamp: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "timestamp": timestamp,
            "type": record_type,
            "payload": payload,
        }))
        .unwrap()
    }

    fn ordinal_line(record_type: &str, payload: Value, timestamp: &str, ordinal: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "ordinal": ordinal,
            "timestamp": timestamp,
            "type": record_type,
            "payload": payload,
        }))
        .unwrap()
    }

    fn timestamp(now: f64) -> String {
        OffsetDateTime::from_unix_timestamp_nanos((now * 1_000_000_000.0) as i128)
            .unwrap()
            .format(&Rfc3339)
            .unwrap()
    }

    fn retained_sample(id: &str, ended_at: f64) -> SpeedSample {
        SpeedSample {
            id: id.to_owned(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: "item".into(),
            model: Some("unknown".into()),
            started_at: ended_at - 1.0,
            ended_at,
            output_tokens: 1,
            output_characters: 1,
            output_bytes: 1,
            chunk_count: 0,
            duration_seconds: 1.0,
            tokens_per_second: 1.0,
            confidence: "low".into(),
            network_warning: None,
            source: "test".into(),
            measurement_kind: Some("completed_body".into()),
            tokenizer: Some("o200k_base".into()),
            body_phase: None,
            quality_reason: None,
        }
    }

    #[test]
    fn body_quality_recomputes_legacy_confidence_and_excludes_anomalies() {
        let mut sample = retained_sample("quality", 10.0);
        sample.started_at = 2.0;
        sample.ended_at = 7.0;
        sample.output_tokens = 10;
        sample.duration_seconds = 5.0;
        sample.tokens_per_second = 2.0;
        sample.confidence = "low".into();
        apply_body_quality(&mut sample);
        assert_eq!(sample.confidence, "high");
        assert_eq!(sample.quality_reason, None);

        sample.output_tokens = 3_000;
        sample.tokens_per_second = 600.0;
        apply_body_quality(&mut sample);
        assert_eq!(sample.confidence, "low");
        assert_eq!(sample.quality_reason.as_deref(), Some("速率异常偏高"));

        sample.output_tokens = 10;
        sample.tokens_per_second = 2.0;
        sample.network_warning = Some("incomplete".into());
        apply_body_quality(&mut sample);
        assert_eq!(sample.quality_reason.as_deref(), Some("采样存在异常标记"));

        sample.network_warning = None;
        sample.output_tokens = 5;
        sample.duration_seconds = 5.0;
        sample.tokens_per_second = 1.0;
        apply_body_quality(&mut sample);
        assert_eq!(sample.quality_reason.as_deref(), Some("速率异常偏低"));

        sample.output_tokens = 10;
        sample.tokens_per_second = 2.1;
        apply_body_quality(&mut sample);
        assert_eq!(sample.quality_reason.as_deref(), Some("速率计算不一致"));

        sample.output_tokens = 0;
        apply_body_quality(&mut sample);
        assert_eq!(sample.quality_reason.as_deref(), Some("文本或计时过短"));

        sample.output_tokens = 10;
        sample.started_at = f64::NAN;
        apply_body_quality(&mut sample);
        assert_eq!(sample.quality_reason.as_deref(), Some("文本或计时过短"));
    }

    #[test]
    fn body_quality_uses_rounded_endpoint_milliseconds_and_accepts_short_text() {
        let started_at = 1_760_000_000_000_i64;
        let mut sample = retained_sample("boundary", 1_760_000_000.0);
        sample.started_at = started_at as f64 / 1_000.0;
        sample.ended_at = (started_at + 400) as f64 / 1_000.0;
        sample.duration_seconds = 0.4;
        sample.output_tokens = 2;
        sample.tokens_per_second = f64::from(sample.output_tokens) / sample.duration_seconds;
        sample.network_warning = Some("also anomalous".into());
        apply_body_quality(&mut sample);
        assert_eq!(sample.confidence, "low");
        assert_eq!(
            sample.quality_reason.as_deref(),
            Some("采样时长不超过 0.4 秒")
        );

        sample.id = "short-accepted".into();
        sample.ended_at = (started_at + 401) as f64 / 1_000.0;
        sample.duration_seconds = 0.401;
        sample.network_warning = None;
        sample.confidence = "low".into();
        sample.quality_reason = Some("legacy low confidence".into());
        sample.tokens_per_second = f64::from(sample.output_tokens) / sample.duration_seconds;
        apply_body_quality(&mut sample);
        assert_eq!(sample.confidence, "medium");
        assert_eq!(sample.quality_reason, None);
    }

    #[test]
    fn history_pages_use_only_retained_numeric_body_samples_with_fixed_as_of() {
        let mut newest = retained_sample("newest", 1_200_000.0);
        newest.output_tokens = 120;
        newest.duration_seconds = 3.0;
        newest.started_at = newest.ended_at - 3.0;
        newest.tokens_per_second = 40.0;
        let mut older = retained_sample("older", 900_000.0);
        older.output_tokens = 100;
        older.duration_seconds = 2.0;
        older.started_at = older.ended_at - 2.0;
        older.tokens_per_second = 50.0;
        let expired_for_15_days = retained_sample("older-than-15d", 100_000.0);
        let mut legacy = retained_sample("legacy-stream", 1_300_000.0);
        legacy.measurement_kind = None;
        legacy.tokenizer = None;

        let first = read_history_page(
            vec![
                newest.clone(),
                older.clone(),
                expired_for_15_days.clone(),
                legacy,
            ],
            0,
            1,
            Some(1_500_000.0),
            15,
        );
        assert_eq!(first.total_count, 2);
        assert_eq!(first.retention_days, 15);
        assert_eq!(first.samples[0].id, "newest");
        assert_eq!(first.next_offset, Some(1));

        let second = read_history_page(
            vec![newest, older, expired_for_15_days],
            first.next_offset.unwrap(),
            1,
            Some(first.as_of),
            15,
        );
        assert_eq!(second.as_of, first.as_of);
        assert_eq!(second.samples[0].id, "older");

        let thirty_day_page = read_history_page(
            vec![retained_sample("older-than-15d", 100_000.0)],
            0,
            50,
            Some(1_500_000.0),
            30,
        );
        assert_eq!(thirty_day_page.total_count, 1);
        assert_eq!(thirty_day_page.retention_days, 30);
    }

    fn context(turn: &str, model: &str, now: f64) -> Vec<u8> {
        line(
            "turn_context",
            serde_json::json!({ "turn_id": turn, "model": model }),
            &timestamp(now),
        )
    }

    fn completed(turn: &str, item: &str, start_ms: f64, end_ms: f64, now: f64) -> Vec<u8> {
        line(
            "event_msg",
            serde_json::json!({
                "type": "item_completed", "turn_id": turn,
                "started_at_ms": start_ms, "completed_at_ms": end_ms,
                "item": { "type": "AgentMessage", "id": item },
            }),
            &timestamp(now),
        )
    }

    fn body(turn: &str, item: &str, text: &str, now: f64) -> Vec<u8> {
        line(
            "response_item",
            serde_json::json!({
                "type": "message", "role": "assistant", "id": item,
                "turn_id": turn, "phase": "final_answer",
                "content": [{"type":"output_text", "text":text}],
            }),
            &timestamp(now),
        )
    }

    #[test]
    fn pairs_out_of_order_and_uses_exact_turn_model_and_o200k_unicode() {
        let now = 1_800_000_100.0;
        let turn = "018f0000-0001-7000-8000-000000000000";
        let mut assembler = Assembler::default();
        assert!(assembler
            .consume_line(&context(turn, "gpt-5.5", now), "thread-a", now)
            .is_empty());
        assert!(assembler
            .consume_line(
                &completed(turn, "item-a", (now - 4.0) * 1_000.0, now * 1_000.0, now),
                "thread-a",
                now,
            )
            .is_empty());
        assembler.consume_line(
            &context(
                "018f0000-0002-7000-8000-000000000000",
                "different-model",
                now,
            ),
            "thread-a",
            now,
        );
        let samples = assembler.consume_line(
            &body(turn, "item-a", "你好 café 👩🏽‍💻 hello", now),
            "thread-a",
            now,
        );
        assert_eq!(samples.len(), 1);
        let sample = &samples[0];
        assert_eq!(sample.model.as_deref(), Some("gpt-5.5"));
        assert_eq!(sample.measurement_kind.as_deref(), Some("completed_body"));
        assert_eq!(sample.tokenizer.as_deref(), Some("o200k_base"));
        assert_eq!(sample.chunk_count, 0);
        assert_eq!(sample.duration_seconds, 4.0);
        assert_eq!(sample.body_phase.as_deref(), Some("final_answer"));
        assert_eq!(
            sample.output_tokens as usize,
            tiktoken_rs::o200k_base_singleton()
                .encode_ordinary("你好 café 👩🏽‍💻 hello")
                .len()
        );
        assert!(sample.network_warning.is_none());
    }

    #[test]
    fn timing_falls_back_to_nested_agent_message_fields() {
        let now = 1_800_000_100.0;
        let turn = "turn-nested";
        let mut assembler = Assembler::default();
        assembler.consume_line(&context(turn, "gpt-5.5", now), "thread-a", now);
        let nested_timing = line(
            "event_msg",
            serde_json::json!({
                "type":"item_completed", "turn_id":turn,
                "item":{
                    "type":"AgentMessage", "id":"nested-item",
                    "started_at_ms":(now - 10.0) * 1_000.0,
                    "completed_at_ms":now * 1_000.0,
                }
            }),
            &timestamp(now),
        );
        assert!(assembler
            .consume_line(&nested_timing, "thread-a", now)
            .is_empty());
        let samples = assembler.consume_line(
            &body(turn, "nested-item", "nested timing body", now),
            "thread-a",
            now,
        );
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].duration_seconds, 10.0);
        assert_eq!(samples[0].body_phase.as_deref(), Some("final_answer"));
    }

    #[test]
    fn duplicate_pair_emits_once_and_negative_times_are_rejected() {
        let now = 1_800_000_100.0;
        let turn = "turn-1";
        let mut assembler = Assembler::default();
        assembler.consume_line(&context(turn, "gpt-5.5", now), "thread-a", now);
        let valid_body = body(turn, "item-a", "hello body", now);
        let complete = completed(turn, "item-a", (now - 2.0) * 1_000.0, now * 1_000.0, now);
        assert_eq!(
            assembler.consume_line(&valid_body, "thread-a", now).len(),
            0
        );
        assert_eq!(assembler.consume_line(&complete, "thread-a", now).len(), 1);
        assert_eq!(
            assembler.consume_line(&valid_body, "thread-a", now).len(),
            0
        );

        let invalid = completed(turn, "item-b", -1.0, now * 1_000.0, now);
        assert!(assembler.consume_line(&invalid, "thread-a", now).is_empty());
        assert!(assembler
            .consume_line(&body(turn, "item-b", "invalid", now), "thread-a", now)
            .is_empty());
    }

    #[test]
    fn forked_rollout_rejects_inherited_turns_and_keeps_child_turns() {
        let now = 1_800_000_100.0;
        let child = "018f0000-0001-7000-8000-000000000000";
        let inherited = "018e0000-0000-7000-8000-000000000000";
        let mut assembler = Assembler::default();
        let header = serde_json::to_vec(&serde_json::json!({
            "type":"session_meta",
            "payload":{"id":child,"forked_from_id":"parent","history_mode":"paginated"}
        }))
        .unwrap();
        assembler.configure(&header);
        assembler.consume_line(
            &context(inherited, "parent-model", now),
            "child-thread",
            now,
        );
        assert!(assembler
            .consume_line(
                &body(inherited, "old", "inherited", now),
                "child-thread",
                now
            )
            .is_empty());
        assembler.consume_line(&context(child, "child-model", now), "child-thread", now);
        assembler.consume_line(
            &completed(child, "new", (now - 2.0) * 1000.0, now * 1000.0, now),
            "child-thread",
            now,
        );
        let samples = assembler.consume_line(
            &body(child, "new", "child output", now),
            "child-thread",
            now,
        );
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].model.as_deref(), Some("child-model"));
    }

    #[test]
    fn non_paginated_subagent_uses_metadata_time_to_keep_only_child_bodies() {
        let now = 1_800_000_100.0;
        let mut assembler = Assembler::default();
        let header = serde_json::to_vec(&serde_json::json!({
            "type":"session_meta",
            "payload":{
                "id":"child-thread",
                "thread_source":"subagent",
                "timestamp":timestamp(now - 5.0),
            }
        }))
        .unwrap();
        assembler.configure(&header);

        let inherited_turn = "parent-turn";
        let inherited_context = line(
            "turn_context",
            serde_json::json!({"turn_id":inherited_turn, "model":"parent-model"}),
            &timestamp(now - 6.0),
        );
        assembler.consume_line(&inherited_context, "child-thread", now);
        let inherited_timing = line(
            "event_msg",
            serde_json::json!({
                "type":"item_completed", "turn_id":inherited_turn,
                "started_at_ms":(now - 8.0) * 1_000.0,
                "completed_at_ms":(now - 6.0) * 1_000.0,
                "item":{"type":"AgentMessage", "id":"inherited-item"},
            }),
            &timestamp(now - 6.0),
        );
        assert!(assembler
            .consume_line(&inherited_timing, "child-thread", now)
            .is_empty());
        let inherited_body = line(
            "response_item",
            serde_json::json!({
                "type":"message", "role":"assistant", "id":"inherited-item",
                "turn_id":inherited_turn,
                "content":[{"type":"output_text", "text":"inherited answer"}],
            }),
            &timestamp(now - 6.0),
        );
        assert!(assembler
            .consume_line(&inherited_body, "child-thread", now)
            .is_empty());

        let child_turn = "child-owned-turn";
        let child_context = line(
            "turn_context",
            serde_json::json!({"turn_id":child_turn, "model":"child-model"}),
            &timestamp(now),
        );
        assembler.consume_line(&child_context, "child-thread", now);
        let child_timing = line(
            "event_msg",
            serde_json::json!({
                "type":"item_completed", "turn_id":child_turn,
                "started_at_ms":(now - 2.0) * 1_000.0,
                "completed_at_ms":now * 1_000.0,
                "item":{"type":"AgentMessage", "id":"child-item"},
            }),
            &timestamp(now),
        );
        assembler.consume_line(&child_timing, "child-thread", now);
        let child_body = line(
            "response_item",
            serde_json::json!({
                "type":"message", "role":"assistant", "id":"child-item",
                "turn_id":child_turn,
                "content":[{"type":"output_text", "text":"child answer"}],
            }),
            &timestamp(now),
        );
        let samples = assembler.consume_line(&child_body, "child-thread", now);
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].turn_id, child_turn);
        assert_eq!(samples[0].model.as_deref(), Some("child-model"));
    }

    #[test]
    fn non_paginated_fork_without_birth_proof_rejects_body() {
        let now = 1_800_000_100.0;
        let mut assembler = Assembler::default();
        let header = serde_json::to_vec(&serde_json::json!({
            "type":"session_meta",
            "payload":{"id":"child", "thread_source":"subagent"}
        }))
        .unwrap();
        assembler.configure(&header);
        let turn = "inherited-turn";
        assembler.consume_line(&context(turn, "parent-model", now), "child-thread", now);
        assert!(assembler
            .consume_line(
                &completed(turn, "inherited-item", (now - 2.0) * 1_000.0, now * 1_000.0, now),
                "child-thread",
                now,
            )
            .is_empty());
        assert!(assembler
            .consume_line(
                &body(turn, "inherited-item", "inherited answer", now),
                "child-thread",
                now,
            )
            .is_empty());
    }

    #[test]
    fn paginated_ordinal_proof_keeps_child_body_without_uuid_birth() {
        let now = 1_800_000_100.0;
        let mut assembler = Assembler::default();
        let header = serde_json::to_vec(&serde_json::json!({
            "type":"session_meta",
            "payload":{
                "id":"child",
                "forked_from_id":"parent",
                "history_mode":"paginated",
                "subagent_history_start_ordinal":900,
            }
        }))
        .unwrap();
        assembler.configure(&header);
        assembler.consume_line(
            &ordinal_line(
                "turn_context",
                serde_json::json!({"turn_id":"own-turn", "model":"child-model"}),
                &timestamp(now),
                900,
            ),
            "child-thread",
            now,
        );
        assembler.consume_line(
            &ordinal_line(
                "event_msg",
                serde_json::json!({
                    "type":"item_completed", "turn_id":"own-turn",
                    "started_at_ms":(now - 10.0) * 1_000.0,
                    "completed_at_ms":now * 1_000.0,
                    "item":{"type":"AgentMessage", "id":"own-item"},
                }),
                &timestamp(now),
                900,
            ),
            "child-thread",
            now,
        );
        let samples = assembler.consume_line(
            &ordinal_line(
                "response_item",
                serde_json::json!({
                    "type":"message", "role":"assistant", "id":"own-item",
                    "turn_id":"own-turn",
                    "content":[{"type":"output_text", "text":"owned output"}],
                }),
                &timestamp(now),
                900,
            ),
            "child-thread",
            now,
        );
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].turn_id, "own-turn");
        assert_eq!(samples[0].model.as_deref(), Some("child-model"));
    }

    #[test]
    fn reader_includes_subagent_rollout_and_filters_inherited_fork_events() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        let child = "018f0000-0001-7000-8000-000000000000";
        let inherited = "018e0000-0000-7000-8000-000000000000";
        let path = std::env::temp_dir().join(format!(
            "completed-body-subagent-{}.jsonl",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut content = Vec::new();
        for line in [
            serde_json::to_vec(&serde_json::json!({
                "type":"session_meta",
                "payload":{
                    "id":child,
                    "forked_from_id":"parent",
                    "thread_source":"subagent",
                    "history_mode":"paginated",
                    "subagent_history_start_ordinal":4,
                }
            }))
            .unwrap(),
            ordinal_line(
                "turn_context",
                serde_json::json!({"turn_id":inherited, "model":"parent-model"}),
                &timestamp(now),
                1,
            ),
            ordinal_line(
                "event_msg",
                serde_json::json!({
                    "type":"item_completed", "turn_id":inherited,
                    "started_at_ms":(now - 2.0) * 1_000.0,
                    "completed_at_ms":now * 1_000.0,
                    "item":{"type":"AgentMessage", "id":"inherited-item"},
                }),
                &timestamp(now),
                2,
            ),
            ordinal_line(
                "response_item",
                serde_json::json!({
                    "type":"message", "role":"assistant", "id":"inherited-item",
                    "turn_id":inherited,
                    "content":[{"type":"output_text", "text":"inherited answer"}],
                }),
                &timestamp(now),
                3,
            ),
            ordinal_line(
                "turn_context",
                serde_json::json!({"turn_id":child, "model":"child-model"}),
                &timestamp(now),
                4,
            ),
            ordinal_line(
                "event_msg",
                serde_json::json!({
                    "type":"item_completed", "turn_id":child,
                    "started_at_ms":(now - 2.0) * 1_000.0,
                    "completed_at_ms":now * 1_000.0,
                    "item":{"type":"AgentMessage", "id":"child-item"},
                }),
                &timestamp(now),
                5,
            ),
            ordinal_line(
                "response_item",
                serde_json::json!({
                    "type":"message", "role":"assistant", "id":"child-item",
                    "turn_id":child,
                    "content":[{"type":"output_text", "text":"child answer"}],
                }),
                &timestamp(now),
                6,
            ),
        ] {
            content.extend_from_slice(&line);
            content.push(b'\n');
        }
        fs::write(&path, content).unwrap();

        let thread = RolloutThread {
            id: child.into(),
            rollout_path: path.clone(),
            thread_source: "subagent".into(),
        };
        let samples = Reader::default()
            .read_thread_files(vec![thread], now)
            .unwrap();
        let _ = fs::remove_file(path);

        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].turn_id, child);
        assert_eq!(samples[0].item_id, "child-item");
        assert_eq!(samples[0].model.as_deref(), Some("child-model"));
    }

    #[test]
    fn pending_state_is_bounded_and_no_legacy_agent_message_is_inferred() {
        let now = 1_800_000_100.0;
        let mut assembler = Assembler::default();
        let legacy = line(
            "event_msg",
            serde_json::json!({"type":"agent_message","message":"legacy"}),
            &timestamp(now),
        );
        assert!(assembler.consume_line(&legacy, "thread-a", now).is_empty());
        let turn = "turn-1";
        assembler.consume_line(&context(turn, "gpt-5.5", now), "thread-a", now);
        for index in 0..MAX_PENDING_ITEMS + 5 {
            assembler.consume_line(
                &completed(
                    turn,
                    &format!("item-{index}"),
                    (now - 2.0) * 1000.0,
                    now * 1000.0,
                    now,
                ),
                "thread-a",
                now,
            );
        }
        assert!(assembler.pending.len() <= MAX_PENDING_ITEMS);
    }

    #[test]
    fn reader_detects_same_file_rewrite_that_grows_past_its_cursor() {
        use std::io::Write;

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        let path = std::env::temp_dir().join(format!(
            "completed-body-rewrite-{}.jsonl",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut old_content = Vec::new();
        let header = serde_json::to_vec(&serde_json::json!({
            "type":"session_meta",
            "payload":{"id":"thread-a"}
        }))
        .unwrap();
        old_content.extend_from_slice(&header);
        old_content.push(b'\n');
        for line in [
            context("old-turn", "gpt-5.5", now),
            completed(
                "old-turn",
                "old-item",
                (now - 1.0) * 1_000.0,
                now * 1_000.0,
                now,
            ),
            body("old-turn", "old-item", "old response", now),
        ] {
            old_content.extend_from_slice(&line);
            old_content.push(b'\n');
        }
        for index in 0..200 {
            old_content.extend_from_slice(
                format!("{{\"type\":\"filler\",\"payload\":{{\"n\":{index}}}}}\n").as_bytes(),
            );
        }
        fs::write(&path, &old_content).unwrap();
        let before = fs::metadata(&path).unwrap();
        let identity_before = file_identity(&path, &before);

        let thread = RolloutThread {
            id: "thread-a".into(),
            rollout_path: path.clone(),
            thread_source: "user".into(),
        };
        let mut reader = Reader::default();
        let first = reader.read_thread_files(vec![thread.clone()], now).unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].item_id, "old-item");

        let mut new_content = Vec::new();
        new_content.extend_from_slice(&header);
        new_content.push(b'\n');
        for line in [
            context("new-turn", "gpt-5.5", now),
            completed(
                "new-turn",
                "new-item",
                (now - 1.0) * 1_000.0,
                now * 1_000.0,
                now,
            ),
            body(
                "new-turn",
                "new-item",
                "new response with a shifted body prefix",
                now,
            ),
        ] {
            new_content.extend_from_slice(&line);
            new_content.push(b'\n');
        }
        let new_sample_end = new_content.len();
        for index in 0..500 {
            new_content.extend_from_slice(
                format!("{{\"type\":\"filler\",\"payload\":{{\"n\":{index}}}}}\n").as_bytes(),
            );
        }
        assert!(new_sample_end < old_content.len());
        assert!(new_content.len() > old_content.len());
        assert_ne!(
            &old_content[old_content.len() - BOUNDARY_BYTES..],
            &new_content[old_content.len() - BOUNDARY_BYTES..old_content.len()]
        );
        let mut file = fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&path)
            .unwrap();
        file.write_all(&new_content).unwrap();
        drop(file);
        let after = fs::metadata(&path).unwrap();
        assert_eq!(identity_before, file_identity(&path, &after));

        let second = reader.read_thread_files(vec![thread], now).unwrap();
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].item_id, "new-item");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn forked_synthetic_turn_requires_uuid_context_and_task_start_pair() {
        let now = 1_800_000_100.0;
        let child = "018f0000-0001-7000-8000-000000000000";
        let own_context_turn = "018f0000-0002-7000-8000-000000000000";
        let mut assembler = Assembler::default();
        let header = serde_json::to_vec(&serde_json::json!({
            "type":"session_meta",
            "payload":{
                "id":child,
                "forked_from_id":"parent",
                "history_mode":"paginated"
            }
        }))
        .unwrap();
        assembler.configure(&header);

        let unpaired = ordinal_line(
            "event_msg",
            serde_json::json!({
                "type":"item_completed", "turn_id":"rollout-3",
                "started_at_ms":(now - 2.0) * 1_000.0,
                "completed_at_ms":now * 1_000.0,
                "item":{"type":"AgentMessage", "id":"unpaired-item"}
            }),
            &timestamp(now),
            9,
        );
        assert!(assembler
            .consume_line(&unpaired, "child-thread", now)
            .is_empty());

        let context = ordinal_line(
            "turn_context",
            serde_json::json!({"turn_id":own_context_turn, "model":"gpt-5.5"}),
            &timestamp(now),
            10,
        );
        assembler.consume_line(&context, "child-thread", now);
        let started = ordinal_line(
            "event_msg",
            serde_json::json!({"type":"task_started", "turn_id":"rollout-4"}),
            &timestamp(now),
            11,
        );
        assembler.consume_line(&started, "child-thread", now);
        let complete = ordinal_line(
            "event_msg",
            serde_json::json!({
                "type":"item_completed", "turn_id":"rollout-4",
                "started_at_ms":(now - 2.0) * 1_000.0,
                "completed_at_ms":now * 1_000.0,
                "item":{"type":"AgentMessage", "id":"owned-item"}
            }),
            &timestamp(now),
            12,
        );
        assembler.consume_line(&complete, "child-thread", now);
        let response = ordinal_line(
            "response_item",
            serde_json::json!({
                "type":"message", "role":"assistant", "id":"owned-item",
                "turn_id":"rollout-4",
                "content":[{"type":"output_text", "text":"owned answer"}]
            }),
            &timestamp(now),
            13,
        );
        let samples = assembler.consume_line(&response, "child-thread", now);
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].turn_id, "rollout-4");
        assert_eq!(samples[0].model.as_deref(), Some("unknown"));
    }

    #[test]
    fn stable_id_uses_thread_turn_and_item_identity() {
        let base = stable_id("thread", "turn", "item");
        assert_ne!(base, stable_id("other", "turn", "item"));
        assert_ne!(base, stable_id("thread", "other", "item"));
        assert_ne!(base, stable_id("thread", "turn", "other"));
        assert!(base.len() <= 128);
    }

    #[test]
    fn cached_job_results_are_pruned_after_the_thirty_day_window() {
        let mut samples = VecDeque::from([
            retained_sample("old", 1_199.0),
            retained_sample("boundary", 1_200.0),
            retained_sample("recent", 1_201.0),
        ]);
        prune_job_samples(&mut samples, 1_200.0 + MAX_BACKFILL_SECONDS);
        assert_eq!(
            samples
                .iter()
                .map(|sample| sample.id.as_str())
                .collect::<Vec<_>>(),
            vec!["boundary", "recent"]
        );
    }
}
