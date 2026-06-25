use super::state::read_recent_rollout_threads;
use super::stream::{LiveMetricEvent, LiveTokenCategory};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const RECENT_ROLLOUT_LIMIT: usize = 20;

static ROLLOUT_OFFSETS: OnceLock<Mutex<HashMap<PathBuf, u64>>> = OnceLock::new();
static RECENT_ROLLOUT_THREADS: OnceLock<Mutex<Option<CachedRolloutThreads>>> = OnceLock::new();

#[derive(Clone)]
struct CachedRolloutThreads {
    codex_home: PathBuf,
    state_signature: StateDatabaseSignature,
    threads: Vec<super::state::RolloutThread>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct StateDatabaseSignature {
    len: u64,
    modified_at: Option<SystemTime>,
}

pub(super) fn read_rollout_metrics(codex_home: &Path, now: f64) -> Vec<LiveMetricEvent> {
    let Ok(threads) = recent_rollout_threads(codex_home) else {
        return Vec::new();
    };
    let offsets = ROLLOUT_OFFSETS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut offsets = offsets
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut metrics = Vec::new();

    for thread in threads {
        let path = thread.rollout_path;
        let Some(file_size) = file_size(&path) else {
            offsets.remove(&path);
            continue;
        };
        let offset = offsets.entry(path.clone()).or_insert(file_size);
        if *offset > file_size {
            *offset = file_size;
            continue;
        }

        let (new_offset, lines) = read_new_lines(&path, *offset).unwrap_or((*offset, Vec::new()));
        *offset = new_offset;
        let mut call_starts = HashMap::new();
        for (line_index, line) in lines.iter().enumerate() {
            metrics.extend(rollout_line_metrics(
                &thread.id,
                &path,
                line_index,
                line,
                now,
                &mut call_starts,
            ));
        }
    }

    metrics
}

pub(super) fn sync_rollout_offsets_to_current(codex_home: &Path) {
    let Ok(threads) = recent_rollout_threads(codex_home) else {
        return;
    };
    let offsets = ROLLOUT_OFFSETS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut offsets = offsets
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    for thread in threads {
        if let Some(size) = file_size(&thread.rollout_path) {
            offsets.insert(thread.rollout_path, size);
        } else {
            offsets.remove(&thread.rollout_path);
        }
    }
}

pub(super) fn rollout_file_signatures(codex_home: &Path) -> Vec<RolloutFileSignature> {
    let Ok(threads) = recent_rollout_threads(codex_home) else {
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

fn recent_rollout_threads(codex_home: &Path) -> rusqlite::Result<Vec<super::state::RolloutThread>> {
    let state_signature = state_database_signature(codex_home);
    let cache = RECENT_ROLLOUT_THREADS.get_or_init(|| Mutex::new(None));
    if let Ok(guard) = cache.lock() {
        if let Some(cached) = guard.as_ref() {
            if cached.codex_home == codex_home && cached.state_signature == state_signature {
                return Ok(cached.threads.clone());
            }
        }
    }

    let threads = read_recent_rollout_threads(codex_home, RECENT_ROLLOUT_LIMIT)?;
    if let Ok(mut guard) = cache.lock() {
        *guard = Some(CachedRolloutThreads {
            codex_home: codex_home.to_path_buf(),
            state_signature,
            threads: threads.clone(),
        });
    }
    Ok(threads)
}

fn state_database_signature(codex_home: &Path) -> StateDatabaseSignature {
    let signature = file_signature(&codex_home.join("state_5.sqlite"));
    StateDatabaseSignature {
        len: signature.len,
        modified_at: signature.modified_at,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RolloutFileSignature {
    pub(super) path: PathBuf,
    pub(super) len: u64,
    pub(super) modified_at: Option<SystemTime>,
}

fn read_new_lines(path: &Path, offset: u64) -> std::io::Result<(u64, Vec<String>)> {
    let mut file = fs::File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    if bytes.is_empty() {
        return Ok((offset, Vec::new()));
    }

    let text = String::from_utf8_lossy(&bytes);
    let Some(last_newline) = text.rfind('\n') else {
        return Ok((offset, Vec::new()));
    };
    let consumed_text = &text[..=last_newline];
    let new_offset = offset + consumed_text.as_bytes().len() as u64;
    let lines = consumed_text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(ToOwned::to_owned)
        .collect();
    Ok((new_offset, lines))
}

fn rollout_line_metrics(
    thread_id: &str,
    path: &Path,
    line_index: usize,
    line: &str,
    now: f64,
    call_starts: &mut HashMap<String, f64>,
) -> Vec<LiveMetricEvent> {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    let Some(payload) = value.get("payload").and_then(Value::as_object) else {
        return Vec::new();
    };
    let timestamp = parse_timestamp(value.get("timestamp").and_then(Value::as_str)).unwrap_or(now);
    let record_type = value.get("type").and_then(Value::as_str).unwrap_or_default();
    let payload_type = payload.get("type").and_then(Value::as_str).unwrap_or_default();
    let key_prefix = payload
        .get("call_id")
        .or_else(|| payload.get("id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("{}:{line_index}", path.display()));

    if record_type == "response_item" && payload_type == "function_call" {
        call_starts.insert(key_prefix.clone(), timestamp);
        let name = payload.get("name").and_then(Value::as_str);
        let arguments = payload.get("arguments").and_then(Value::as_str).unwrap_or("");
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
        return Vec::new();
    }

    if record_type == "response_item"
        && (payload_type == "message" || payload_type == "assistant")
        && payload.get("role").and_then(Value::as_str).unwrap_or("assistant") == "assistant"
    {
        let text = message_text(&Value::Object(payload.clone()));
        if text.is_empty() {
            return Vec::new();
        }
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.assistant_message",
            key_prefix,
            LiveTokenCategory::VisibleText,
            text,
            true,
            None,
            None,
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
        dedupe_key: Some(dedupe_key),
    }
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
    fs::metadata(path).ok().map(|metadata| metadata.len())
}

fn file_signature(path: &Path) -> FileSignature {
    fs::metadata(path)
        .map(|metadata| FileSignature {
            len: metadata.len(),
            modified_at: metadata.modified().ok(),
        })
        .unwrap_or(FileSignature {
            len: 0,
            modified_at: None,
        })
}

struct FileSignature {
    len: u64,
    modified_at: Option<SystemTime>,
}
