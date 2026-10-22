use super::c_curve::RolloutSignal;
use super::cache_reminder::{self, CacheObservation, CacheReminderTracker};
use super::state::read_recent_rollout_threads;
use super::stream::{
    latest_scheduled_timestamp, LiveMetricEvent, LiveTokenCategory, WINDOW_SECONDS,
};
use super::LiveRateSourceScope;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const RECENT_ROLLOUT_LIMIT: usize = 20;
const CONTEXT_TAIL_PROBE_BYTES: usize = 64 * 1024;
// Main/WAL signatures are still checked on each poll and invalidate immediately.
// Only the fallback reload for an unchanged database is infrequent: repeatedly
// sorting the same threads every three seconds adds idle CPU without new data.
const RECENT_ROLLOUT_TTL: Duration = Duration::from_secs(60);
const ROLLOUT_SCOPE_LIMIT: usize = 64;

static ROLLOUT_STATE: OnceLock<Mutex<RolloutState>> = OnceLock::new();

#[derive(Default)]
struct RolloutState {
    next_generation: u64,
    scope_generations: HashMap<LiveRateSourceScope, u64>,
    offsets: HashMap<(LiveRateSourceScope, PathBuf), RolloutOffset>,
    retained_metrics: HashMap<LiveRateSourceScope, Vec<LiveMetricEvent>>,
    cache_reminders: HashMap<LiveRateSourceScope, CacheReminderTracker>,
    recent_threads: HashMap<LiveRateSourceScope, CachedRolloutThreads>,
    #[cfg(test)]
    load_counts: HashMap<LiveRateSourceScope, usize>,
}

#[derive(Clone, Debug)]
struct RolloutOffset {
    offset: u64,
    boundary: Option<Vec<u8>>,
    identity: Option<String>,
    modified_at: Option<SystemTime>,
}

#[derive(Clone)]
struct CachedRolloutThreads {
    state_signature: StateDatabaseSignature,
    threads: Vec<super::state::RolloutThread>,
    refreshed_at: Instant,
}

#[derive(Clone, Debug)]
struct StateDatabaseSignature {
    main: FileSignature,
    wal: FileSignature,
}

impl StateDatabaseSignature {
    fn is_same_as(&self, other: &Self) -> bool {
        self.main.is_same_as(&other.main) && self.wal.is_same_as(&other.wal)
    }
}

pub(super) fn read_rollout_metrics(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    now: f64,
) -> rusqlite::Result<Vec<LiveMetricEvent>> {
    read_rollout_metrics_with_signals(codex_home, source_scope, now).map(|(metrics, _)| metrics)
}

pub(super) fn read_rollout_metrics_with_signals(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    now: f64,
) -> rusqlite::Result<(Vec<LiveMetricEvent>, Vec<RolloutSignal>)> {
    let (threads, generation) = recent_rollout_threads(codex_home, source_scope)?;
    let mut metrics = Vec::new();
    let mut signals = Vec::new();
    let mut cache_observations = Vec::new();
    for thread in threads {
        let include_cache_reminder = cache_reminder::CACHE_MISS_REMINDER_ENABLED
            && thread.thread_source != "guardian_review";
        if cache_reminder::CACHE_MISS_REMINDER_ENABLED && !include_cache_reminder {
            cache_observations.push((thread.id.clone(), CacheObservation::Reset));
        }
        let path = thread.rollout_path;
        let signature = file_signature(&path);
        if !signature.exists || !signature.regular {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) == Some(&generation) {
                state.offsets.remove(&(source_scope.clone(), path));
                if let Some(reminders) = state.cache_reminders.get_mut(source_scope) {
                    reminders.reset_thread(&thread.id);
                }
            }
            continue;
        }
        let file_size = signature.len;
        let key = (source_scope.clone(), path.clone());
        let (offset, reset_for_rewrite, probe_context_tail) = {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) != Some(&generation) {
                return Ok((Vec::new(), Vec::new()));
            }
            if let Some(previous) = state.offsets.get(&key).cloned() {
                let identity_changed = matches!(
                    (&previous.identity, &signature.identity),
                    (Some(previous), Some(current)) if previous != current
                );
                let same_length_rewrite =
                    previous.offset == file_size && previous.modified_at != signature.modified_at;
                let boundary_changed = (previous.modified_at != signature.modified_at
                    || previous.offset != file_size)
                    && previous.boundary.as_ref().is_some_and(|expected| {
                        read_boundary(&path, previous.offset).as_ref() != Some(expected)
                    });
                let reset = previous.offset > file_size
                    || identity_changed
                    || same_length_rewrite
                    || boundary_changed;
                if reset {
                    state.offsets.insert(
                        key.clone(),
                        RolloutOffset {
                            offset: file_size,
                            boundary: read_boundary(&path, file_size),
                            identity: signature.identity.clone(),
                            modified_at: signature.modified_at,
                        },
                    );
                    (file_size, true, true)
                } else {
                    (previous.offset, false, false)
                }
            } else {
                state.offsets.insert(
                    key.clone(),
                    RolloutOffset {
                        offset: file_size,
                        boundary: read_boundary(&path, file_size),
                        identity: signature.identity.clone(),
                        modified_at: signature.modified_at,
                    },
                );
                (file_size, false, true)
            }
        };
        let tail_boundary = (include_cache_reminder && probe_context_tail)
            .then(|| context_history_boundary(&path, file_size))
            .flatten();
        if let Some(boundary) = tail_boundary {
            let observation = match boundary {
                ContextHistoryBoundary::ExplicitContextReset => CacheObservation::ContextReset,
                ContextHistoryBoundary::ValidTokenCount => CacheObservation::EstablishedContext,
            };
            cache_observations.push((thread.id.clone(), observation));
        }
        if reset_for_rewrite {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) == Some(&generation) {
                if let Some(reminders) = state.cache_reminders.get_mut(source_scope) {
                    reminders.reset_thread(&thread.id);
                }
            }
            continue;
        }

        let (new_offset, lines) = match read_new_lines(&path, offset) {
            Ok(result) => result,
            Err(_) => {
                if include_cache_reminder {
                    cache_observations.push((thread.id.clone(), CacheObservation::Reset));
                }
                continue;
            }
        };
        {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) != Some(&generation) {
                return Ok((Vec::new(), Vec::new()));
            }
            let boundary = if new_offset != offset {
                read_boundary(&path, new_offset)
            } else {
                state
                    .offsets
                    .get(&key)
                    .and_then(|previous| previous.boundary.clone())
            };
            state.offsets.insert(
                key,
                RolloutOffset {
                    offset: new_offset,
                    boundary,
                    identity: signature.identity.clone(),
                    modified_at: signature.modified_at,
                },
            );
        }
        let mut call_starts = HashMap::new();
        for line in lines {
            let thread_id = thread.id.clone();
            if let Some(signal) = rollout_signal(&thread_id, &line.text, now) {
                signals.push(signal);
            }
            let mut observe = |observation| {
                if include_cache_reminder {
                    cache_observations.push((thread_id.clone(), observation));
                }
            };
            metrics.extend(rollout_line_metrics(
                &thread.id,
                &path,
                line.offset,
                &line.text,
                now,
                &mut call_starts,
                &mut observe,
            ));
        }
    }

    let mut state = rollout_state();
    if state.scope_generations.get(source_scope) != Some(&generation) {
        return Ok((Vec::new(), Vec::new()));
    }
    if cache_reminder::CACHE_MISS_REMINDER_ENABLED {
        let reminders = state
            .cache_reminders
            .entry(source_scope.clone())
            .or_default();
        reminders.begin_poll(now, Instant::now());
        for (thread_id, observation) in cache_observations {
            reminders.observe(&thread_id, observation, now, Instant::now());
        }
    } else {
        state.cache_reminders.remove(source_scope);
    }
    let retained = state
        .retained_metrics
        .entry(source_scope.clone())
        .or_default();
    retained.retain(|metric| now - latest_scheduled_timestamp(metric) <= WINDOW_SECONDS);
    let mut fingerprints = retained
        .iter()
        .map(LiveMetricEvent::fingerprint)
        .collect::<HashSet<_>>();
    retained.extend(
        metrics
            .into_iter()
            .filter(|metric| fingerprints.insert(metric.fingerprint())),
    );
    Ok((retained.clone(), signals))
}

fn rollout_signal(thread_id: &str, line: &str, now: f64) -> Option<RolloutSignal> {
    let value = serde_json::from_str::<Value>(line).ok()?;
    let payload = value.get("payload")?.as_object()?;
    let record_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let payload_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let turn_id = payload
        .get("turn_id")
        .and_then(Value::as_str)
        .filter(|turn_id| !turn_id.is_empty() && turn_id.len() <= 512)
        .map(ToOwned::to_owned);
    let timestamp = parse_timestamp(value.get("timestamp").and_then(Value::as_str))
        .filter(|timestamp| timestamp.is_finite())
        .unwrap_or(now);
    match (record_type, payload_type) {
        ("turn_context", _) => Some(RolloutSignal::Context {
            thread_id: thread_id.to_owned(),
            turn_id,
            model: payload
                .get("model")
                .and_then(Value::as_str)
                .filter(|model| model.len() <= 256 && !model.is_empty() && *model != "unknown")
                .map(ToOwned::to_owned),
            at: timestamp,
        }),
        ("event_msg", "task_started") => Some(RolloutSignal::TurnStarted {
            thread_id: thread_id.to_owned(),
            turn_id,
            at: parse_event_timestamp(payload.get("started_at")).unwrap_or(timestamp),
        }),
        ("event_msg", "task_complete") => Some(RolloutSignal::TurnCompleted {
            thread_id: thread_id.to_owned(),
            turn_id,
            failed: payload.get("error").is_some_and(|error| !error.is_null()),
            at: parse_event_timestamp(payload.get("completed_at")).unwrap_or(timestamp),
        }),
        ("event_msg", "task_aborted" | "turn_aborted") => Some(RolloutSignal::TurnCompleted {
            thread_id: thread_id.to_owned(),
            turn_id,
            failed: true,
            at: parse_event_timestamp(payload.get("completed_at"))
                .or_else(|| parse_event_timestamp(payload.get("aborted_at")))
                .unwrap_or(timestamp),
        }),
        ("event_msg", "item_completed") => {
            let item = payload.get("item").and_then(Value::as_object);
            let item_id = item
                .and_then(|item| item.get("id"))
                .and_then(Value::as_str)
                .or_else(|| payload.get("item_id").and_then(Value::as_str))
                .filter(|item_id| !item_id.is_empty() && item_id.len() <= 512)
                .unwrap_or("unknown")
                .to_owned();
            let item_type = item
                .and_then(|item| item.get("type"))
                .and_then(Value::as_str);
            let completed_ms =
                parse_event_timestamp(payload.get("completed_at_ms")).or_else(|| {
                    item.and_then(|item| parse_event_timestamp(item.get("completed_at_ms")))
                });
            let item_completed_at = completed_ms
                .map(|milliseconds| milliseconds / 1_000.0)
                .unwrap_or(timestamp);
            if !item_type.is_some_and(|item_type| item_type.eq_ignore_ascii_case("reasoning")) {
                return Some(RolloutSignal::ItemCompleted {
                    thread_id: thread_id.to_owned(),
                    turn_id,
                    item_id,
                    at: item_completed_at,
                });
            }
            let started = parse_event_timestamp(payload.get("started_at_ms")).or_else(|| {
                item.and_then(|item| parse_event_timestamp(item.get("started_at_ms")))
            })? / 1_000.0;
            let completed = completed_ms? / 1_000.0;
            if !started.is_finite() || !completed.is_finite() {
                return None;
            }
            let duration_seconds = (completed - started).max(0.0);
            if !duration_seconds.is_finite() {
                return None;
            }
            Some(RolloutSignal::ReasoningCompleted {
                thread_id: thread_id.to_owned(),
                turn_id,
                item_id,
                duration_seconds,
                at: completed,
            })
        }
        (_, "token_usage_record") => {
            let usage = payload.get("usage")?.as_object()?;
            Some(RolloutSignal::UsageSettled {
                thread_id: thread_id.to_owned(),
                turn_id,
                output_tokens: usage
                    .get("output_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                reasoning_tokens: usage
                    .get("reasoning_output_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                at: timestamp,
            })
        }
        _ => None,
    }
}

pub(super) fn latest_cache_advice(
    source_scope: &LiveRateSourceScope,
    now: f64,
) -> Option<crate::models::CacheAdvice> {
    let state = rollout_state();
    cache_reminder::latest(state.cache_reminders.get(source_scope), now)
}

pub(super) fn clear_cache_advice(source_scope: &LiveRateSourceScope) {
    rollout_state().cache_reminders.remove(source_scope);
}

pub(super) fn rollout_file_signatures(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
) -> Vec<RolloutFileSignature> {
    let Ok((threads, _)) = recent_rollout_threads(codex_home, source_scope) else {
        return Vec::new();
    };
    threads
        .into_iter()
        .map(|thread| {
            let signature = file_signature(&thread.rollout_path);
            RolloutFileSignature {
                path: thread.rollout_path,
                len: signature.len,
                modified_at: signature.modified_at,
            }
        })
        .collect()
}

fn recent_rollout_threads(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
) -> rusqlite::Result<(Vec<super::state::RolloutThread>, u64)> {
    recent_rollout_threads_with_reader(codex_home, source_scope, || {
        read_recent_rollout_threads(codex_home, RECENT_ROLLOUT_LIMIT)
    })
}

fn recent_rollout_threads_with_reader(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    mut read_threads: impl FnMut() -> rusqlite::Result<Vec<super::state::RolloutThread>>,
) -> rusqlite::Result<(Vec<super::state::RolloutThread>, u64)> {
    for attempt in 0..2 {
        let signature_before = state_database_signature(codex_home);
        let refresh_nonce = {
            let mut state = rollout_state();
            if !state.scope_generations.contains_key(source_scope) {
                evict_oldest_scope_if_needed(&mut state);
            }
            if let Some(cached) = state.recent_threads.get(source_scope) {
                if cached.state_signature.is_same_as(&signature_before)
                    && cached.refreshed_at.elapsed() < RECENT_ROLLOUT_TTL
                {
                    return Ok((
                        cached.threads.clone(),
                        *state.scope_generations.get(source_scope).unwrap_or(&0),
                    ));
                }
            }
            state.next_generation = state.next_generation.saturating_add(1);
            let nonce = state.next_generation;
            state.scope_generations.insert(source_scope.clone(), nonce);
            nonce
        };

        let threads = read_threads()?;
        let signature_after = state_database_signature(codex_home);
        if !signature_before.is_same_as(&signature_after) {
            if rollout_state().scope_generations.get(source_scope) != Some(&refresh_nonce) {
                return Ok((threads, refresh_nonce));
            }
            if attempt == 0 {
                continue;
            }
            return Ok((threads, refresh_nonce));
        }

        let valid_paths = threads
            .iter()
            .map(|thread| thread.rollout_path.clone())
            .collect::<std::collections::HashSet<_>>();
        let valid_thread_ids = threads
            .iter()
            .map(|thread| thread.id.clone())
            .collect::<HashSet<_>>();
        let mut state = rollout_state();
        if state.scope_generations.get(source_scope) == Some(&refresh_nonce) {
            #[cfg(test)]
            {
                *state.load_counts.entry(source_scope.clone()).or_default() += 1;
            }
            state.recent_threads.insert(
                source_scope.clone(),
                CachedRolloutThreads {
                    state_signature: signature_after,
                    threads: threads.clone(),
                    refreshed_at: Instant::now(),
                },
            );
            state
                .offsets
                .retain(|(scope, path), _| scope != source_scope || valid_paths.contains(path));
            if let Some(reminders) = state.cache_reminders.get_mut(source_scope) {
                reminders.retain_threads(&valid_thread_ids);
            }
        }
        return Ok((threads, refresh_nonce));
    }
    unreachable!("bounded rollout signature retry")
}

fn evict_oldest_scope_if_needed(state: &mut RolloutState) {
    if state.scope_generations.len() < ROLLOUT_SCOPE_LIMIT {
        return;
    }
    let Some(scope) = state
        .recent_threads
        .iter()
        .min_by_key(|(_, cached)| cached.refreshed_at)
        .map(|(scope, _)| scope.clone())
        .or_else(|| state.scope_generations.keys().next().cloned())
    else {
        return;
    };
    state.scope_generations.remove(&scope);
    state.recent_threads.remove(&scope);
    state.retained_metrics.remove(&scope);
    state.cache_reminders.remove(&scope);
    state
        .offsets
        .retain(|(candidate, _), _| candidate != &scope);
    #[cfg(test)]
    state.load_counts.remove(&scope);
}

fn state_database_signature(codex_home: &Path) -> StateDatabaseSignature {
    StateDatabaseSignature {
        main: file_signature(&codex_home.join("state_5.sqlite")),
        wal: file_signature(&codex_home.join("state_5.sqlite-wal")),
    }
}

fn rollout_state() -> std::sync::MutexGuard<'static, RolloutState> {
    ROLLOUT_STATE
        .get_or_init(|| Mutex::new(RolloutState::default()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
pub(super) fn offset_key_for_test(
    scope: &LiveRateSourceScope,
    path: &Path,
) -> (LiveRateSourceScope, PathBuf) {
    (scope.clone(), path.to_path_buf())
}

#[cfg(test)]
pub(super) fn recent_thread_ids_for_test(
    codex_home: &Path,
    scope: &LiveRateSourceScope,
) -> rusqlite::Result<Vec<String>> {
    recent_rollout_threads(codex_home, scope)
        .map(|(threads, _)| threads.into_iter().map(|thread| thread.id).collect())
}

#[cfg(test)]
pub(super) fn cache_load_count_for_test(scope: &LiveRateSourceScope) -> usize {
    rollout_state().load_counts.get(scope).copied().unwrap_or(0)
}

#[cfg(test)]
pub(super) fn age_cache_for_test(scope: &LiveRateSourceScope, age: Duration) {
    if let Some(cached) = rollout_state().recent_threads.get_mut(scope) {
        cached.refreshed_at = Instant::now() - age;
    }
}

#[cfg(test)]
pub(super) fn expire_cache_for_test(scope: &LiveRateSourceScope) {
    if let Some(cached) = rollout_state().recent_threads.get_mut(scope) {
        cached.refreshed_at = Instant::now() - RECENT_ROLLOUT_TTL;
    }
}

#[cfg(test)]
pub(super) fn publish_scope_threads_for_test(scope: &LiveRateSourceScope, thread_id: &str) {
    let mut state = rollout_state();
    if !state.scope_generations.contains_key(scope) {
        state.next_generation = state.next_generation.saturating_add(1);
        let generation = state.next_generation;
        state.scope_generations.insert(scope.clone(), generation);
    }
    state.recent_threads.insert(
        scope.clone(),
        CachedRolloutThreads {
            state_signature: StateDatabaseSignature {
                main: file_signature(Path::new("")),
                wal: file_signature(Path::new("")),
            },
            threads: vec![super::state::RolloutThread {
                id: thread_id.into(),
                rollout_path: PathBuf::new(),
                thread_source: "user".into(),
            }],
            refreshed_at: Instant::now(),
        },
    );
}

#[cfg(test)]
pub(super) fn cached_scope_thread_ids_for_test(scope: &LiveRateSourceScope) -> Vec<String> {
    rollout_state()
        .recent_threads
        .get(scope)
        .map(|cached| {
            cached
                .threads
                .iter()
                .map(|thread| thread.id.clone())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
pub(super) fn recent_thread_ids_after_read_hook_for_test(
    codex_home: &Path,
    scope: &LiveRateSourceScope,
    after_first_read: impl FnOnce(),
) -> rusqlite::Result<Vec<String>> {
    let mut hook = Some(after_first_read);
    recent_rollout_threads_with_reader(codex_home, scope, || {
        let threads = read_recent_rollout_threads(codex_home, RECENT_ROLLOUT_LIMIT)?;
        if let Some(hook) = hook.take() {
            hook();
        }
        Ok(threads)
    })
    .map(|(threads, _)| threads.into_iter().map(|thread| thread.id).collect())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RolloutFileSignature {
    pub(super) path: PathBuf,
    pub(super) len: u64,
    pub(super) modified_at: Option<SystemTime>,
}

struct RolloutLine {
    offset: u64,
    text: String,
}

// A bounded tail read used only on initial file binding, rewrite, or cursor guards.
fn read_tail(path: &Path, end_offset: u64, max_bytes: usize) -> Option<Vec<u8>> {
    let count = end_offset.min(max_bytes as u64) as usize;
    let mut file = File::open(path).ok()?;
    file.seek(SeekFrom::Start(end_offset - count as u64)).ok()?;
    let mut bytes = vec![0; count];
    file.read_exact(&mut bytes).ok()?;
    Some(bytes)
}

// A bounded cursor guard, read only on binding or a changed file, never an idle poll.
fn read_boundary(path: &Path, offset: u64) -> Option<Vec<u8>> {
    read_tail(path, offset, 256)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ContextHistoryBoundary {
    ExplicitContextReset,
    ValidTokenCount,
}

fn context_history_boundary(path: &Path, end_offset: u64) -> Option<ContextHistoryBoundary> {
    let bytes = read_tail(path, end_offset, CONTEXT_TAIL_PROBE_BYTES)?;
    // A concurrently appended or crash-truncated record is not a complete
    // rollout event. Ignore that suffix while still honoring the latest full
    // record available within the bounded tail.
    let complete_len = bytes.iter().rposition(|byte| *byte == b'\n')? + 1;
    let complete_bytes = &bytes[..complete_len];

    let starts_at_file_head = end_offset <= CONTEXT_TAIL_PROBE_BYTES as u64;
    let mut lines = complete_bytes
        .split(|byte| *byte == b'\n')
        .collect::<Vec<_>>();
    if lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    if !starts_at_file_head && !lines.is_empty() {
        lines.remove(0);
    }

    for line in lines.into_iter().rev() {
        let Ok(line) = std::str::from_utf8(line) else {
            continue;
        };
        let line = line.trim_end_matches('\r');
        match history_marker(line) {
            Some(ContextHistoryBoundary::ExplicitContextReset) => {
                return Some(ContextHistoryBoundary::ExplicitContextReset);
            }
            Some(ContextHistoryBoundary::ValidTokenCount) => {
                return Some(ContextHistoryBoundary::ValidTokenCount);
            }
            None => {}
        }
    }
    None
}

fn history_marker(line: &str) -> Option<ContextHistoryBoundary> {
    let value = serde_json::from_str::<Value>(line).ok()?;
    let payload = value.get("payload")?.as_object()?;
    let record_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let payload_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let timestamp = parse_timestamp(value.get("timestamp").and_then(Value::as_str));
    match cache_reminder::parse_observation(&value, payload, record_type, payload_type, timestamp)?
    {
        CacheObservation::ContextReset => Some(ContextHistoryBoundary::ExplicitContextReset),
        CacheObservation::Sample(sample) if cache_reminder::is_valid_history_sample(&sample) => {
            Some(ContextHistoryBoundary::ValidTokenCount)
        }
        _ => None,
    }
}

fn read_new_lines(path: &Path, offset: u64) -> std::io::Result<(u64, Vec<RolloutLine>)> {
    let mut file = fs::File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    if bytes.is_empty() {
        return Ok((offset, Vec::new()));
    }

    let Some(last_newline) = bytes.iter().rposition(|byte| *byte == b'\n') else {
        return Ok((offset, Vec::new()));
    };
    let consumed = &bytes[..=last_newline];
    let new_offset = offset + consumed.len() as u64;
    let mut lines = Vec::new();
    let mut line_offset = offset;
    for line in consumed.split_inclusive(|byte| *byte == b'\n') {
        let text = String::from_utf8_lossy(line);
        let line_text = text.trim_end_matches(['\r', '\n']);
        if !line_text.trim().is_empty() {
            lines.push(RolloutLine {
                offset: line_offset,
                text: line_text.to_owned(),
            });
        }
        line_offset += line.len() as u64;
    }
    Ok((new_offset, lines))
}

fn parse_event_timestamp(value: Option<&Value>) -> Option<f64> {
    let timestamp = match value? {
        Value::String(text) => parse_timestamp(Some(text))?,
        Value::Number(number) => number.as_f64()?,
        _ => return None,
    };
    let microseconds = timestamp * 1_000_000.0;
    if !microseconds.is_finite()
        || microseconds <= i64::MIN as f64
        || microseconds >= i64::MAX as f64
    {
        return None;
    }
    Some(microseconds.round() / 1_000_000.0)
}

#[cfg(test)]
mod rollout_reader_tests {
    use super::*;

    fn history_sample(cumulative: u64, request_total: u64) -> CacheObservation {
        let value = serde_json::json!({
            "timestamp": "2026-10-22T00:00:00Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": 153566,
                        "cached_input_tokens": 0,
                        "total_tokens": request_total
                    },
                    "total_token_usage": {"total_tokens": cumulative}
                }
            }
        });
        cache_reminder::parse_observation(
            &value,
            value["payload"].as_object().unwrap(),
            "event_msg",
            "token_count",
            Some(1_792_627_200.0),
        )
        .unwrap()
    }

    #[test]
    fn same_thread_id_keeps_source_scope_history_isolated() {
        let unique = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
            .to_string();
        let restored_scope = LiveRateSourceScope::new(
            format!("cache-reminder-restored-{unique}"),
            format!("cache-reminder-restored-physical-{unique}"),
        );
        let fresh_scope = LiveRateSourceScope::new(
            format!("cache-reminder-fresh-{unique}"),
            format!("cache-reminder-fresh-physical-{unique}"),
        );
        let monotonic = Instant::now();
        let mut restored = CacheReminderTracker::default();
        restored.observe(
            "same-thread",
            history_sample(29_374_965, 154_786),
            1_792_627_200.0,
            monotonic,
        );
        let mut fresh = CacheReminderTracker::default();
        fresh.observe(
            "same-thread",
            history_sample(154_786, 154_786),
            1_792_627_200.0,
            monotonic,
        );

        {
            let mut state = rollout_state();
            state
                .cache_reminders
                .insert(restored_scope.clone(), restored);
            state.cache_reminders.insert(fresh_scope.clone(), fresh);
        }
        assert!(
            latest_cache_advice(&restored_scope, 1_792_627_200.0)
                .unwrap()
                .low
        );
        assert!(
            !latest_cache_advice(&fresh_scope, 1_792_627_200.0)
                .unwrap()
                .low
        );
        let mut state = rollout_state();
        state.cache_reminders.remove(&restored_scope);
        state.cache_reminders.remove(&fresh_scope);
    }

    #[test]
    fn invalid_utf8_does_not_shift_byte_cursor() {
        let path = std::env::temp_dir().join(format!(
            "rollout-offset-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, [0xff, b'\n', b'{', b'}', b'\n', b'x']).unwrap();
        let (offset, lines) = read_new_lines(&path, 0).unwrap();
        assert_eq!(offset, 5);
        assert_eq!(lines[1].offset, 2);
        assert!(read_new_lines(&path, offset).unwrap().1.is_empty());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn same_inode_rewrite_changes_boundary() {
        let path = std::env::temp_dir().join(format!(
            "rollout-boundary-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, b"original\n").unwrap();
        let original = read_boundary(&path, 9).unwrap();
        fs::write(&path, b"rewritten and longer\n").unwrap();
        assert_ne!(read_boundary(&path, 9).unwrap(), original);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn startup_tail_probe_finds_latest_reset_or_request_without_replaying_history() {
        let path = std::env::temp_dir().join(format!(
            "rollout-context-tail-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let previous_request = r#"{"timestamp":"2026-10-22T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":153566,"cached_input_tokens":0,"total_tokens":154786},"total_token_usage":{"total_tokens":29374965}}}}"#;
        let compacted = r#"{"timestamp":"2026-10-22T00:01:00Z","type":"compacted","payload":{"type":"compacted"}}"#;
        fs::write(&path, format!("{previous_request}\n{compacted}\n")).unwrap();

        let initial_size = fs::metadata(&path).unwrap().len();
        assert_eq!(
            context_history_boundary(&path, initial_size),
            Some(ContextHistoryBoundary::ExplicitContextReset)
        );
        let (offset, old_lines) = read_new_lines(&path, initial_size).unwrap();
        assert_eq!(offset, initial_size);
        assert!(old_lines.is_empty(), "startup must not replay old requests");

        let after_reset_request = r#"{"timestamp":"2026-10-22T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20000,"cached_input_tokens":0,"total_tokens":20100},"total_token_usage":{"total_tokens":29475065}}}}"#;
        use std::io::Write as _;
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(file, "{after_reset_request}").unwrap();
        drop(file);

        let current_size = fs::metadata(&path).unwrap().len();
        assert_eq!(
            context_history_boundary(&path, current_size),
            Some(ContextHistoryBoundary::ValidTokenCount),
            "a valid request after compaction supersedes the old cold-context marker"
        );
        let (new_offset, new_lines) = read_new_lines(&path, initial_size).unwrap();
        assert_eq!(new_offset, current_size);
        assert_eq!(new_lines.len(), 1);
    }

    #[test]
    fn startup_tail_probe_is_bounded_and_ignores_partial_or_out_of_window_markers() {
        use std::io::Write as _;

        let path = std::env::temp_dir().join(format!(
            "rollout-context-tail-bound-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let compacted = r#"{"timestamp":"2026-10-22T00:00:00Z","type":"compacted","payload":{"type":"compacted"}}"#;
        let filler = r#"{"timestamp":"2026-10-22T00:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#;
        let repetitions = CONTEXT_TAIL_PROBE_BYTES / filler.len() + 4;
        let body = format!("{compacted}\n{}", format!("{filler}\n").repeat(repetitions));
        fs::write(&path, &body).unwrap();
        let size = fs::metadata(&path).unwrap().len();
        assert!(size > CONTEXT_TAIL_PROBE_BYTES as u64);
        assert_eq!(
            read_tail(&path, size, CONTEXT_TAIL_PROBE_BYTES)
                .unwrap()
                .len(),
            CONTEXT_TAIL_PROBE_BYTES
        );
        assert_eq!(
            context_history_boundary(&path, size),
            None,
            "a reset marker older than the bounded tail must remain unknown"
        );

        fs::write(&path, format!("{compacted}\n")).unwrap();
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(b"{\"timestamp\":\"2026-10-22T00:00:02Z\"")
            .unwrap();
        drop(file);
        let partial_size = fs::metadata(&path).unwrap().len();
        assert_eq!(
            context_history_boundary(&path, partial_size),
            Some(ContextHistoryBoundary::ExplicitContextReset),
            "an unterminated tail record must not hide the latest complete marker"
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn parser_reads_actual_event_msg_reasoning_milliseconds_and_abort_events() {
        let timestamp = OffsetDateTime::parse("2026-10-20T00:00:00Z", &Rfc3339).unwrap();
        let start_ms = (timestamp.unix_timestamp() - 1) * 1_000;
        let end_ms = timestamp.unix_timestamp() * 1_000;
        let line = format!(
            r#"{{"timestamp":"2026-10-20T00:00:00Z","type":"event_msg","payload":{{"type":"item_completed","thread_id":"thread-a","turn_id":"turn-a","started_at_ms":{start_ms},"completed_at_ms":{end_ms},"item":{{"type":"Reasoning","id":"reason-a"}}}}}}"#
        );
        let signal = rollout_signal("thread-a", &line, timestamp.unix_timestamp() as f64);
        assert!(matches!(
            signal,
            Some(RolloutSignal::ReasoningCompleted {
                duration_seconds,
                item_id,
                ..
            }) if duration_seconds == 1.0 && item_id == "reason-a"
        ));

        let aborted = r#"{"timestamp":"2026-10-20T00:00:00Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}"#;
        assert!(matches!(
            rollout_signal("thread-a", aborted, timestamp.unix_timestamp() as f64),
            Some(RolloutSignal::TurnCompleted { failed: true, .. })
        ));
    }
}

fn rollout_line_metrics(
    thread_id: &str,
    path: &Path,
    line_offset: u64,
    line: &str,
    now: f64,
    call_starts: &mut HashMap<String, f64>,
    observe_cache: &mut impl FnMut(CacheObservation),
) -> Vec<LiveMetricEvent> {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    let Some(payload) = value.get("payload").and_then(Value::as_object) else {
        return Vec::new();
    };
    let parsed_timestamp = parse_timestamp(value.get("timestamp").and_then(Value::as_str));
    let timestamp = parsed_timestamp.unwrap_or(now);
    let record_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let payload_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if cache_reminder::CACHE_MISS_REMINDER_ENABLED {
        if let Some(observation) = cache_reminder::parse_observation(
            &value,
            payload,
            record_type,
            payload_type,
            parsed_timestamp,
        ) {
            observe_cache(observation);
        }
    }
    let key_prefix = payload
        .get("call_id")
        .or_else(|| payload.get("id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("{}:{line_offset}", path.display()));

    if record_type == "response_item" && payload_type == "function_call" {
        call_starts.insert(key_prefix.clone(), timestamp);
        let name = payload.get("name").and_then(Value::as_str);
        let arguments = payload
            .get("arguments")
            .and_then(Value::as_str)
            .unwrap_or("");
        if arguments.is_empty() {
            return Vec::new();
        }
        let category = if name == Some("apply_patch") {
            LiveTokenCategory::PatchInput
        } else {
            LiveTokenCategory::ToolArguments
        };
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.function_call",
            format!("{key_prefix}:{}", category.key()),
            category,
            arguments.to_owned(),
            true,
            None,
            None,
        )];
    }

    if record_type == "response_item" && payload_type == "custom_tool_call" {
        call_starts.insert(key_prefix.clone(), timestamp);
        let name = payload.get("name").and_then(Value::as_str);
        let input = payload.get("input").and_then(Value::as_str).unwrap_or("");
        if input.is_empty() {
            return Vec::new();
        }
        let category = if name == Some("apply_patch") {
            LiveTokenCategory::PatchInput
        } else {
            LiveTokenCategory::ToolArguments
        };
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.custom_tool_call",
            format!("{key_prefix}:{}", category.key()),
            category,
            input.to_owned(),
            true,
            None,
            None,
        )];
    }

    if record_type == "event_msg" && payload_type == "agent_message" {
        let text = message_text(&Value::Object(payload.clone()));
        if text.is_empty() {
            return Vec::new();
        }
        return vec![metric_with_dedupe(
            thread_id,
            timestamp,
            "rollout.agent_message",
            key_prefix,
            LiveTokenCategory::VisibleText,
            text.clone(),
            true,
            None,
            None,
            visible_text_dedupe_key(thread_id, timestamp, &text),
        )];
    }

    if record_type == "response_item"
        && (payload_type == "message" || payload_type == "assistant")
        && payload
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or("assistant")
            == "assistant"
    {
        let text = message_text(&Value::Object(payload.clone()));
        if text.is_empty() {
            return Vec::new();
        }
        return vec![metric_with_dedupe(
            thread_id,
            timestamp,
            "rollout.assistant_message",
            key_prefix,
            LiveTokenCategory::VisibleText,
            text.clone(),
            true,
            None,
            None,
            visible_text_dedupe_key(thread_id, timestamp, &text),
        )];
    }

    if record_type == "response_item"
        && (payload_type == "function_call_output" || payload_type == "custom_tool_call_output")
    {
        let output = payload.get("output").and_then(Value::as_str).unwrap_or("");
        if output.is_empty() {
            return Vec::new();
        }
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.tool_output",
            format!("{key_prefix}:toolOutput"),
            LiveTokenCategory::ToolOutput,
            output.to_owned(),
            true,
            None,
            call_starts.get(&key_prefix).copied(),
        )];
    }

    if record_type == "event_msg" && payload_type == "patch_apply_end" {
        let text = payload
            .get("changes")
            .and_then(Value::as_object)
            .map(|changes| {
                changes
                    .values()
                    .filter_map(|change| {
                        change
                            .get("content")
                            .or_else(|| change.get("unified_diff"))
                            .and_then(Value::as_str)
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default();
        if text.is_empty() {
            return Vec::new();
        }
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.patch_apply_end",
            format!("{key_prefix}:patchApplied"),
            LiveTokenCategory::PatchApplied,
            text,
            true,
            None,
            call_starts.get(&key_prefix).copied(),
        )];
    }

    if record_type == "event_msg" && payload_type == "token_count" {
        let usage = payload
            .get("info")
            .and_then(|info| info.get("last_token_usage"));
        let reasoning = usage
            .and_then(|usage| usage.get("reasoning_output_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if reasoning == 0 {
            return Vec::new();
        }
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.token_count",
            format!("{key_prefix}:reasoning"),
            LiveTokenCategory::Reasoning,
            String::new(),
            true,
            Some(reasoning.min(u64::from(u32::MAX)) as u32),
            None,
        )];
    }

    Vec::new()
}

fn metric(
    thread_id: &str,
    timestamp: f64,
    event_type: &str,
    item_id: String,
    category: LiveTokenCategory,
    delta: String,
    distributed: bool,
    exact_tokens: Option<u32>,
    start_timestamp: Option<f64>,
) -> LiveMetricEvent {
    let dedupe_key = format!("{event_type}:{thread_id}:{item_id}:{timestamp:.6}:{delta}");
    metric_with_dedupe(
        thread_id,
        timestamp,
        event_type,
        item_id,
        category,
        delta.clone(),
        distributed,
        exact_tokens,
        start_timestamp,
        dedupe_key,
    )
}

fn metric_with_dedupe(
    thread_id: &str,
    timestamp: f64,
    event_type: &str,
    item_id: String,
    category: LiveTokenCategory,
    delta: String,
    distributed: bool,
    exact_tokens: Option<u32>,
    start_timestamp: Option<f64>,
    dedupe_key: String,
) -> LiveMetricEvent {
    LiveMetricEvent {
        event_type: event_type.into(),
        timestamp,
        thread_id: Some(thread_id.into()),
        item_id,
        sequence_number: None,
        category,
        delta,
        exact_tokens,
        start_timestamp,
        distributed,
        spreads_forward: start_timestamp.is_none(),
        dedupe_key: Some(dedupe_key),
    }
}

fn visible_text_dedupe_key(thread_id: &str, timestamp: f64, text: &str) -> String {
    let bucket = timestamp.floor() as i64;
    format!("rollout.visible:{thread_id}:{bucket}:{}", fnv1a64(text))
}

fn fnv1a64(text: &str) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn message_text(value: &Value) -> String {
    if let Some(text) = value.get("text").and_then(Value::as_str) {
        return text.to_owned();
    }
    if let Some(message) = value.get("message").and_then(Value::as_str) {
        return message.to_owned();
    }
    let Some(content) = value.get("content") else {
        return String::new();
    };
    if let Some(text) = content.as_str() {
        return text.to_owned();
    }
    content
        .as_array()
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default()
}

fn parse_timestamp(text: Option<&str>) -> Option<f64> {
    let text = text?;
    let parsed = OffsetDateTime::parse(text, &Rfc3339).ok()?;
    Some(parsed.unix_timestamp() as f64 + f64::from(parsed.nanosecond()) / 1_000_000_000.0)
}

fn file_size(path: &Path) -> Option<u64> {
    fs::metadata(path)
        .ok()
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
}

fn file_signature(path: &Path) -> FileSignature {
    file_signature_with_identity(path, file_identity)
}

fn file_signature_with_identity(
    path: &Path,
    identity_reader: impl FnOnce(&File) -> Option<String>,
) -> FileSignature {
    File::open(path)
        .and_then(|file| file.metadata().map(|metadata| (file, metadata)))
        .map(|(file, metadata)| FileSignature {
            exists: true,
            regular: metadata.is_file(),
            identity: identity_reader(&file),
            len: metadata.len(),
            modified_at: metadata.modified().ok(),
        })
        .unwrap_or(FileSignature {
            exists: false,
            regular: false,
            identity: None,
            len: 0,
            modified_at: None,
        })
}

#[cfg(unix)]
fn file_identity(file: &File) -> Option<String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata().ok()?;
    Some(format!("{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn file_identity(file: &File) -> Option<String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
    };
    let mut info = FILE_ID_INFO::default();
    let succeeded = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileIdInfo,
            (&mut info as *mut FILE_ID_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_ID_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if succeeded == 0 {
        return None;
    }
    let file_id = info
        .FileId
        .Identifier
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Some(format!("{}:{file_id}", info.VolumeSerialNumber))
}

#[cfg(not(any(unix, windows)))]
fn file_identity(_file: &File) -> Option<String> {
    None
}

#[cfg(test)]
#[test]
fn windows_file_identity_source_uses_stable_handle_api() {
    let source = include_str!("rollout.rs");
    assert!(source.contains("GetFileInformationByHandleEx"));
    assert!(source.contains("FileIdInfo"));
    assert!(source.contains("FILE_ID_INFO::default()"));
    assert!(!source.contains(&["std::os::windows::fs::", "MetadataExt"].concat()));
    assert!(!source.contains(&["volume_serial_", "number()"].concat()));
    assert!(!source.contains(&["file_", "index()"].concat()));
}

#[derive(Clone, Debug)]
struct FileSignature {
    exists: bool,
    regular: bool,
    identity: Option<String>,
    len: u64,
    modified_at: Option<SystemTime>,
}

impl FileSignature {
    fn is_same_as(&self, other: &Self) -> bool {
        if !self.exists || !other.exists {
            return self.exists == other.exists;
        }
        self.regular == other.regular
            && self.len == other.len
            && self.modified_at == other.modified_at
            && matches!(
                (&self.identity, &other.identity),
                (Some(left), Some(right)) if left == right
            )
    }
}

#[cfg(test)]
#[test]
fn file_signatures_fail_closed_when_identity_is_unavailable() {
    let path = std::env::temp_dir().join(format!(
        "codex-token-bar-rollout-signature-{}",
        std::process::id()
    ));
    fs::write(&path, b"stable metadata").unwrap();

    let unavailable_a = file_signature_with_identity(&path, |_| None);
    let unavailable_b = file_signature_with_identity(&path, |_| None);
    assert!(!unavailable_a.is_same_as(&unavailable_b));

    let known_a = file_signature_with_identity(&path, |_| Some("volume:file".into()));
    let known_b = file_signature_with_identity(&path, |_| Some("volume:file".into()));
    assert!(known_a.is_same_as(&known_b));

    let missing = path.with_extension("missing");
    let absent_a = file_signature_with_identity(&missing, |_| None);
    let absent_b = file_signature_with_identity(&missing, |_| None);
    assert!(absent_a.is_same_as(&absent_b));

    fs::remove_file(path).unwrap();
}
