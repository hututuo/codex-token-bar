use super::state::read_recent_rollout_threads;
use super::stream::{LiveMetricEvent, LiveTokenCategory};
use super::LiveRateSourceScope;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const RECENT_ROLLOUT_LIMIT: usize = 20;
const RECENT_ROLLOUT_TTL: Duration = Duration::from_secs(3);
const ROLLOUT_SCOPE_LIMIT: usize = 64;

static ROLLOUT_STATE: OnceLock<Mutex<RolloutState>> = OnceLock::new();

#[derive(Default)]
struct RolloutState {
    next_generation: u64,
    scope_generations: HashMap<LiveRateSourceScope, u64>,
    offsets: HashMap<(LiveRateSourceScope, PathBuf), u64>,
    recent_threads: HashMap<LiveRateSourceScope, CachedRolloutThreads>,
    #[cfg(test)]
    load_counts: HashMap<LiveRateSourceScope, usize>,
}

#[derive(Clone)]
struct CachedRolloutThreads {
    state_signature: StateDatabaseSignature,
    threads: Vec<super::state::RolloutThread>,
    refreshed_at: Instant,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct StateDatabaseSignature {
    main: FileSignature,
    wal: FileSignature,
}

pub(super) fn read_rollout_metrics(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    now: f64,
) -> rusqlite::Result<Vec<LiveMetricEvent>> {
    let (threads, generation) = recent_rollout_threads(codex_home, source_scope)?;
    let mut metrics = Vec::new();

    for thread in threads {
        let path = thread.rollout_path;
        let Some(file_size) = file_size(&path) else {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) == Some(&generation) {
                state.offsets.remove(&(source_scope.clone(), path));
            }
            continue;
        };
        let key = (source_scope.clone(), path.clone());
        let offset = {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) != Some(&generation) {
                return Ok(Vec::new());
            }
            *state.offsets.entry(key.clone()).or_insert(file_size)
        };
        if offset > file_size {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) == Some(&generation) {
                state.offsets.insert(key, file_size);
            }
            continue;
        }

        let (new_offset, lines) = read_new_lines(&path, offset).unwrap_or((offset, Vec::new()));
        {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) != Some(&generation) {
                return Ok(Vec::new());
            }
            state.offsets.insert(key, new_offset);
        }
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

    Ok(metrics)
}

pub(super) fn sync_rollout_offsets_to_current(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
) {
    let Ok((threads, generation)) = recent_rollout_threads(codex_home, source_scope) else {
        return;
    };
    let observed = threads
        .into_iter()
        .map(|thread| (thread.rollout_path.clone(), file_size(&thread.rollout_path)))
        .collect::<Vec<_>>();
    let mut state = rollout_state();
    if state.scope_generations.get(source_scope) != Some(&generation) {
        return;
    }
    for (path, size) in observed {
        let key = (source_scope.clone(), path);
        if let Some(size) = size {
            state.offsets.insert(key, size);
        } else {
            state.offsets.remove(&key);
        }
    }
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
                if cached.state_signature == signature_before
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
        if signature_before != signature_after {
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
            state.offsets.retain(|(scope, path), _| {
                scope != source_scope || valid_paths.contains(path)
            });
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
    state.offsets.retain(|(candidate, _), _| candidate != &scope);
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
pub(super) fn expire_cache_for_test(scope: &LiveRateSourceScope) {
    if let Some(cached) = rollout_state().recent_threads.get_mut(scope) {
        cached.refreshed_at = Instant::now() - RECENT_ROLLOUT_TTL;
    }
}

#[cfg(test)]
pub(super) fn publish_scope_threads_for_test(
    scope: &LiveRateSourceScope,
    thread_id: &str,
) {
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
        .map(|cached| cached.threads.iter().map(|thread| thread.id.clone()).collect())
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
        && payload.get("role").and_then(Value::as_str).unwrap_or("assistant") == "assistant"
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
    File::open(path)
        .and_then(|file| file.metadata().map(|metadata| (file, metadata)))
        .map(|(file, metadata)| FileSignature {
            exists: true,
            regular: metadata.is_file(),
            identity: file_identity(&file),
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct FileSignature {
    exists: bool,
    regular: bool,
    identity: Option<String>,
    len: u64,
    modified_at: Option<SystemTime>,
}
