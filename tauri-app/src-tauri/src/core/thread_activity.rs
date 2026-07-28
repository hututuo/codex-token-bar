use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const LIFECYCLE_LEASE: Duration = Duration::from_secs(24 * 60 * 60);
const REVERSE_CHUNK_BYTES: usize = 64 * 1024;
const FORWARD_CHUNK_BYTES: usize = 64 * 1024;
const MAX_JSONL_LINE_BYTES: usize = 2 * 1024 * 1024;
const MAX_LIFECYCLE_PREFIX_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RunningThreadCounts {
    pub main_threads: u32,
    pub subagents: u32,
}

impl RunningThreadCounts {
    pub fn total(self) -> u32 {
        self.main_threads.saturating_add(self.subagents)
    }
}

#[derive(Default)]
pub struct ThreadActivityScanner {
    tracked: HashMap<PathBuf, TrackedSession>,
}

#[derive(Clone, Debug)]
struct TrackedSession {
    signature: FileSignature,
    complete_offset: u64,
    boundary_signature: u64,
    session_id: String,
    lifecycle_known: bool,
    running: bool,
    subagent: bool,
    lifecycle_at: Option<SystemTime>,
    last_activity: SystemTime,
}

#[derive(Clone, Debug)]
struct SessionMetadata {
    id: String,
    subagent: bool,
}

#[derive(Clone, Copy, Debug)]
struct LifecycleObservation {
    running: bool,
    observed_at: Option<SystemTime>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FileIdentity {
    device_id: u64,
    file_id: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FileSignature {
    size: u64,
    modified_ns: u128,
    identity: FileIdentity,
    changed_ns: i128,
}

impl FileSignature {
    fn same_identity(self, other: Self) -> bool {
        self.identity == other.identity
    }
}

impl ThreadActivityScanner {
    pub fn scan(&mut self, codex_home: &Path) -> Result<RunningThreadCounts, String> {
        let canonical_root = fs::canonicalize(codex_home).map_err(|error| {
            format!(
                "无法确认当前 Codex Home 的真实路径：{}（{error}）",
                codex_home.display()
            )
        })?;
        let root_metadata = fs::symlink_metadata(codex_home)
            .map_err(|error| format!("无法读取 Codex Home：{}（{error}）", codex_home.display()))?;
        if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
            return Err("Codex Home 必须是非符号链接目录".into());
        }

        let sessions_root = canonical_root.join("sessions");
        match fs::symlink_metadata(&sessions_root) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() || !metadata.is_dir() {
                    return Err("sessions 必须是 Codex Home 内的非符号链接目录".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                self.tracked.clear();
                return Ok(RunningThreadCounts::default());
            }
            Err(error) => {
                return Err(format!(
                    "无法读取 sessions 目录：{}（{error}）",
                    sessions_root.display()
                ));
            }
        }
        let canonical_sessions = fs::canonicalize(&sessions_root).map_err(|error| {
            format!(
                "无法确认 sessions 目录的真实路径：{}（{error}）",
                sessions_root.display()
            )
        })?;
        if !canonical_sessions.starts_with(&canonical_root) {
            return Err("sessions 目录越过了当前 Codex Home 边界".into());
        }

        let now = SystemTime::now();
        let cutoff = now
            .checked_sub(LIFECYCLE_LEASE)
            .unwrap_or(SystemTime::UNIX_EPOCH);
        let retained_paths = self.tracked.keys().cloned().collect::<Vec<_>>();
        let candidates = collect_recent_session_files(
            &canonical_root,
            &canonical_sessions,
            cutoff,
            self.tracked.is_empty(),
            &retained_paths,
        )?;
        let candidate_set = candidates.iter().cloned().collect::<HashSet<_>>();
        self.tracked.retain(|path, _| candidate_set.contains(path));

        for path in candidates {
            let next = match self.tracked.remove(&path) {
                Some(previous) => refresh_tracked_session(&canonical_root, &path, previous)?,
                None => cold_scan_session(&canonical_root, &path)?,
            };
            self.tracked.insert(path, next);
        }

        let mut preferred_by_id = HashMap::<&str, &TrackedSession>::new();
        for session in self.tracked.values() {
            if session.last_activity < cutoff || session.session_id.is_empty() {
                continue;
            }
            let should_replace = preferred_by_id
                .get(session.session_id.as_str())
                .map_or(true, |current| session_is_newer(session, current));
            if should_replace {
                preferred_by_id.insert(session.session_id.as_str(), session);
            }
        }

        let mut counts = RunningThreadCounts::default();
        for session in preferred_by_id.values().filter(|session| session.running) {
            if session.subagent {
                counts.subagents = counts.subagents.saturating_add(1);
            } else {
                counts.main_threads = counts.main_threads.saturating_add(1);
            }
        }
        Ok(counts)
    }
}

fn collect_recent_session_files(
    canonical_root: &Path,
    sessions_root: &Path,
    cutoff: SystemTime,
    force_fallback_discovery: bool,
    retained_paths: &[PathBuf],
) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    if let Some(database_paths) = recent_database_session_paths(canonical_root, cutoff) {
        for raw_path in database_paths {
            if let Some(path) = trusted_session_path(canonical_root, sessions_root, &raw_path)? {
                files.push(path);
            }
        }
        for raw_path in retained_paths {
            if let Some(path) = trusted_session_path(canonical_root, sessions_root, raw_path)? {
                let modified = fs::metadata(&path)
                    .and_then(|metadata| metadata.modified())
                    .unwrap_or(SystemTime::UNIX_EPOCH);
                if modified >= cutoff {
                    files.push(path);
                }
            }
        }
        files.sort();
        files.dedup();
        if !force_fallback_discovery && !files.is_empty() {
            return Ok(files);
        }
    }

    let mut stack = vec![sessions_root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        let entries = fs::read_dir(&directory)
            .map_err(|error| format!("读取会话目录失败：{}（{error}）", directory.display()))?;
        for entry in entries {
            let entry = entry
                .map_err(|error| format!("枚举会话目录失败：{}（{error}）", directory.display()))?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path)
                .map_err(|error| format!("读取会话路径失败：{}（{error}）", path.display()))?;
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                let canonical = fs::canonicalize(&path)
                    .map_err(|error| format!("确认会话目录失败：{}（{error}）", path.display()))?;
                if !canonical.starts_with(canonical_root) {
                    return Err(format!("会话目录越过 Codex Home：{}", path.display()));
                }
                stack.push(canonical);
                continue;
            }
            if !metadata.is_file()
                || path.extension().and_then(|value| value.to_str()) != Some("jsonl")
            {
                continue;
            }
            let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
            // 24 小时只用于淘汰没有任何新文件活动的孤儿运行态；它不是读取
            // JSONL 历史的字节上限。进入候选集后会一直反向读取到最新生命周期。
            if modified < cutoff {
                continue;
            }
            let canonical = fs::canonicalize(&path)
                .map_err(|error| format!("确认会话文件失败：{}（{error}）", path.display()))?;
            if !canonical.starts_with(canonical_root) {
                return Err(format!("会话文件越过 Codex Home：{}", path.display()));
            }
            files.push(canonical);
        }
    }
    files.sort();
    files.dedup();
    Ok(files)
}

fn recent_database_session_paths(
    canonical_root: &Path,
    cutoff: SystemTime,
) -> Option<Vec<PathBuf>> {
    let database_path = canonical_root.join("state_5.sqlite");
    let database_metadata = fs::symlink_metadata(&database_path).ok()?;
    if database_metadata.file_type().is_symlink() || !database_metadata.is_file() {
        return None;
    }
    let canonical_database = fs::canonicalize(&database_path).ok()?;
    if !canonical_database.starts_with(canonical_root) {
        return None;
    }
    let connection =
        crate::core::sqlite::open_read_only(&canonical_database, Duration::from_millis(500))
            .ok()?;
    let mut column_statement = connection.prepare("PRAGMA table_info(threads)").ok()?;
    let columns = column_statement
        .query_map([], |row| row.get::<_, String>(1))
        .ok()?
        .collect::<Result<HashSet<_>, _>>()
        .ok()?;
    if !columns.contains("rollout_path")
        || (!columns.contains("updated_at_ms") && !columns.contains("updated_at"))
    {
        return None;
    }
    let archived = if columns.contains("archived") {
        "COALESCE(archived, 0)"
    } else {
        "0"
    };
    let updated = match (
        columns.contains("updated_at_ms"),
        columns.contains("updated_at"),
    ) {
        (true, true) => {
            "CASE WHEN COALESCE(updated_at_ms, 0) > 0 THEN updated_at_ms ELSE COALESCE(updated_at, 0) * 1000 END"
        }
        (true, false) => "COALESCE(updated_at_ms, 0)",
        (false, true) => "COALESCE(updated_at, 0) * 1000",
        (false, false) => return None,
    };
    let cutoff_ms = cutoff
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64;
    let sql = format!("SELECT rollout_path FROM threads WHERE {archived} = 0 AND {updated} >= ?1");
    let mut statement = connection.prepare(&sql).ok()?;
    let paths = statement
        .query_map([cutoff_ms], |row| row.get::<_, String>(0))
        .ok()?
        .filter_map(Result::ok)
        .filter(|path| !path.trim().is_empty())
        .map(PathBuf::from)
        .collect::<Vec<_>>();
    Some(paths)
}

fn trusted_session_path(
    canonical_root: &Path,
    sessions_root: &Path,
    raw_path: &Path,
) -> Result<Option<PathBuf>, String> {
    let candidate = if raw_path.is_absolute() {
        raw_path.to_path_buf()
    } else {
        canonical_root.join(raw_path)
    };
    if candidate.extension().and_then(|value| value.to_str()) != Some("jsonl") {
        return Ok(None);
    }
    let metadata = match fs::symlink_metadata(&candidate) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "读取数据库登记的会话文件失败：{}（{error}）",
                candidate.display()
            ))
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Ok(None);
    }
    let canonical = fs::canonicalize(&candidate).map_err(|error| {
        format!(
            "确认数据库登记的会话文件失败：{}（{error}）",
            candidate.display()
        )
    })?;
    if !canonical.starts_with(canonical_root) || !canonical.starts_with(sessions_root) {
        return Ok(None);
    }
    Ok(Some(canonical))
}

fn session_is_newer(candidate: &TrackedSession, current: &TrackedSession) -> bool {
    match (candidate.lifecycle_at, current.lifecycle_at) {
        (Some(candidate_at), Some(current_at)) if candidate_at != current_at => {
            return candidate_at > current_at;
        }
        (Some(_), None) => return true,
        (None, Some(_)) => return false,
        (None, None) if candidate.lifecycle_known != current.lifecycle_known => {
            return candidate.lifecycle_known;
        }
        _ => {}
    }
    candidate.last_activity > current.last_activity
        || (candidate.last_activity == current.last_activity
            && candidate.complete_offset > current.complete_offset)
}

fn refresh_tracked_session(
    canonical_root: &Path,
    path: &Path,
    mut previous: TrackedSession,
) -> Result<TrackedSession, String> {
    let (mut file, signature) = open_verified_session_file(canonical_root, path)?;
    let last_activity = signature_modified_time(signature);
    let requires_cold_scan = !signature.same_identity(previous.signature)
        || signature.size < previous.signature.size
        || (signature.size == previous.signature.size
            && (signature.modified_ns != previous.signature.modified_ns
                || signature.changed_ns != previous.signature.changed_ns))
        || boundary_signature(&mut file, previous.complete_offset)? != previous.boundary_signature;
    if requires_cold_scan {
        return cold_scan_open_file(canonical_root, path, file, signature);
    }

    if signature.size > previous.signature.size {
        let complete_offset = last_complete_line_offset(&mut file, signature.size)?;
        if complete_offset > previous.complete_offset {
            scan_complete_lines_forward(
                &mut file,
                previous.complete_offset,
                complete_offset,
                |line| {
                    if let Some(observation) = lifecycle_state(line) {
                        previous.lifecycle_known = true;
                        previous.running = observation.running;
                        previous.lifecycle_at = observation.observed_at;
                    }
                    false
                },
            )?;
            previous.complete_offset = complete_offset;
            previous.boundary_signature = boundary_signature(&mut file, complete_offset)?;
        }
    }
    validate_open_file_after_read(canonical_root, path, &file, signature)?;
    previous.signature = signature;
    previous.last_activity = last_activity;
    Ok(previous)
}

fn cold_scan_session(canonical_root: &Path, path: &Path) -> Result<TrackedSession, String> {
    let (file, signature) = open_verified_session_file(canonical_root, path)?;
    cold_scan_open_file(canonical_root, path, file, signature)
}

fn cold_scan_open_file(
    canonical_root: &Path,
    path: &Path,
    mut file: fs::File,
    signature: FileSignature,
) -> Result<TrackedSession, String> {
    let complete_offset = last_complete_line_offset(&mut file, signature.size)?;
    let metadata = read_session_metadata(&mut file, complete_offset)?
        .ok_or_else(|| format!("会话文件缺少 session_meta：{}", path.display()))?;
    let lifecycle = latest_lifecycle_state(&mut file, complete_offset)?;
    let boundary_signature = boundary_signature(&mut file, complete_offset)?;
    validate_open_file_after_read(canonical_root, path, &file, signature)?;
    Ok(TrackedSession {
        signature,
        complete_offset,
        boundary_signature,
        session_id: metadata.id,
        lifecycle_known: lifecycle.is_some(),
        running: lifecycle.is_some_and(|observation| observation.running),
        subagent: metadata.subagent,
        lifecycle_at: lifecycle.and_then(|observation| observation.observed_at),
        last_activity: signature_modified_time(signature),
    })
}

fn open_verified_session_file(
    canonical_root: &Path,
    path: &Path,
) -> Result<(fs::File, FileSignature), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("读取会话文件失败：{}（{error}）", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("会话路径不是普通文件：{}", path.display()));
    }
    let canonical = fs::canonicalize(path)
        .map_err(|error| format!("确认会话文件失败：{}（{error}）", path.display()))?;
    if !canonical.starts_with(canonical_root) {
        return Err(format!("会话文件越过 Codex Home：{}", path.display()));
    }
    let file = fs::File::open(path)
        .map_err(|error| format!("打开会话文件失败：{}（{error}）", path.display()))?;
    let signature = file_signature_from_handle(&file, path)?;
    let path_signature = file_signature(path)?;
    if !signature.same_identity(path_signature) {
        return Err(format!("会话文件在打开时已被替换：{}", path.display()));
    }
    Ok((file, signature))
}

fn validate_open_file_after_read(
    canonical_root: &Path,
    path: &Path,
    file: &fs::File,
    start: FileSignature,
) -> Result<(), String> {
    let handle_after = file_signature_from_handle(file, path)?;
    let path_after = file_signature(path)?;
    let canonical_after = fs::canonicalize(path)
        .map_err(|error| format!("重新确认会话文件失败：{}（{error}）", path.display()))?;
    if !canonical_after.starts_with(canonical_root)
        || !handle_after.same_identity(start)
        || !path_after.same_identity(start)
    {
        return Err(format!("会话文件在读取期间发生替换：{}", path.display()));
    }
    if handle_after.size < start.size || path_after.size < start.size {
        return Err(format!("会话文件在读取期间被截断：{}", path.display()));
    }
    Ok(())
}

fn read_session_metadata(
    file: &mut fs::File,
    complete_offset: u64,
) -> Result<Option<SessionMetadata>, String> {
    let mut metadata = None;
    scan_complete_lines_forward(file, 0, complete_offset, |line| {
        let Some(value) = parse_json_object(line) else {
            return false;
        };
        if value.get("type").and_then(Value::as_str) != Some("session_meta") {
            return false;
        }
        let payload = value.get("payload").unwrap_or(&value);
        let Some(id) = payload
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.trim().is_empty())
        else {
            return true;
        };
        metadata = Some(SessionMetadata {
            id: id.to_string(),
            subagent: session_meta_is_subagent(&value),
        });
        true
    })?;
    Ok(metadata)
}

fn session_meta_is_subagent(session_meta: &Value) -> bool {
    let payload = session_meta.get("payload").unwrap_or(session_meta);
    for container in [session_meta, payload] {
        let thread_source = container
            .get("thread_source")
            .or_else(|| container.get("threadSource"));
        if thread_source.is_some_and(value_mentions_subagent) {
            return true;
        }
        if container.get("source").is_some_and(value_mentions_subagent) {
            return true;
        }
    }
    false
}

fn value_mentions_subagent(value: &Value) -> bool {
    match value {
        Value::String(value) => value.trim().eq_ignore_ascii_case("subagent"),
        Value::Array(values) => values.iter().any(value_mentions_subagent),
        Value::Object(values) => values.iter().any(|(key, value)| {
            key.eq_ignore_ascii_case("subagent") || value_mentions_subagent(value)
        }),
        _ => false,
    }
}

fn lifecycle_state(line: &[u8]) -> Option<LifecycleObservation> {
    let Some(value) = parse_json_object(line) else {
        return lifecycle_state_from_prefix(line);
    };
    if value.get("type").and_then(Value::as_str) != Some("event_msg") {
        return None;
    }
    let payload = value.get("payload")?;
    let running = match payload.get("type")?.as_str()? {
        "task_started" => true,
        "task_complete" | "turn_aborted" | "thread_rolled_back" => false,
        _ => return None,
    };
    Some(LifecycleObservation {
        running,
        observed_at: lifecycle_timestamp(&value, payload, running),
    })
}

fn lifecycle_timestamp(event: &Value, payload: &Value, running: bool) -> Option<SystemTime> {
    if let Some(timestamp) = event
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_system_time)
    {
        return Some(timestamp);
    }
    let numeric = if running {
        payload.get("started_at")
    } else {
        payload
            .get("completed_at")
            .or_else(|| payload.get("started_at"))
    }
    .and_then(Value::as_f64);
    if let Some(seconds) = numeric
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0 && *seconds < u64::MAX as f64)
    {
        let whole_seconds = seconds.floor() as u64;
        let nanos =
            ((seconds - whole_seconds as f64) * 1_000_000_000.0).clamp(0.0, 999_999_999.0) as u32;
        return SystemTime::UNIX_EPOCH.checked_add(Duration::new(whole_seconds, nanos));
    }
    None
}

fn parse_rfc3339_system_time(timestamp: &str) -> Option<SystemTime> {
    let parsed = OffsetDateTime::parse(timestamp, &Rfc3339).ok()?;
    let nanos = parsed.unix_timestamp_nanos();
    if nanos < 0 {
        return None;
    }
    let seconds = (nanos / 1_000_000_000).min(u64::MAX as i128) as u64;
    let subsecond = (nanos % 1_000_000_000) as u32;
    SystemTime::UNIX_EPOCH.checked_add(Duration::new(seconds, subsecond))
}

fn lifecycle_state_from_prefix(line: &[u8]) -> Option<LifecycleObservation> {
    let prefix = String::from_utf8_lossy(&line[..line.len().min(MAX_LIFECYCLE_PREFIX_BYTES)]);
    let payload_index = prefix.find("\"payload\"")?;
    let header = &prefix[..payload_index];
    if first_json_string_value(header, "type").as_deref() != Some("event_msg") {
        return None;
    }
    let payload = &prefix[payload_index..];
    let running = match first_json_string_value(payload, "type")?.as_str() {
        "task_started" => true,
        "task_complete" | "turn_aborted" | "thread_rolled_back" => false,
        _ => return None,
    };
    let observed_at = first_json_string_value(header, "timestamp")
        .as_deref()
        .and_then(parse_rfc3339_system_time);
    Some(LifecycleObservation {
        running,
        observed_at,
    })
}

fn first_json_string_value(text: &str, key: &str) -> Option<String> {
    let key_index = text.find(&format!("\"{key}\""))?;
    let after_key = &text[key_index + key.len() + 2..];
    let colon_index = after_key.find(':')?;
    let value = after_key[colon_index + 1..].trim_start();
    let quoted = value.strip_prefix('"')?;
    let closing_quote = quoted.find('"')?;
    Some(quoted[..closing_quote].to_string())
}

fn parse_json_object(line: &[u8]) -> Option<Value> {
    serde_json::from_slice::<Value>(line).ok()
}

fn latest_lifecycle_state(
    file: &mut fs::File,
    complete_offset: u64,
) -> Result<Option<LifecycleObservation>, String> {
    let mut cursor = complete_offset;
    let mut suffix = Vec::<u8>::new();
    let mut suffix_oversized = false;
    let mut chunk = vec![0_u8; REVERSE_CHUNK_BYTES];

    while cursor > 0 {
        let start = cursor.saturating_sub(REVERSE_CHUNK_BYTES as u64);
        let length = (cursor - start) as usize;
        file.seek(SeekFrom::Start(start))
            .map_err(|error| format!("定位会话文件失败：{error}"))?;
        file.read_exact(&mut chunk[..length])
            .map_err(|error| format!("反向读取会话文件失败：{error}"))?;
        cursor = start;

        let chunk_slice = &chunk[..length];
        let chunk_has_newline = chunk_slice.contains(&b'\n');
        let mut data = Vec::with_capacity(length.saturating_add(if suffix_oversized {
            1
        } else {
            suffix.len()
        }));
        data.extend_from_slice(chunk_slice);
        if suffix_oversized {
            data.push(b'\n');
        } else {
            data.extend_from_slice(&suffix);
        }

        let newline_positions = data
            .iter()
            .enumerate()
            .filter_map(|(index, byte)| (*byte == b'\n').then_some(index))
            .collect::<Vec<_>>();
        for line_index in (0..newline_positions.len()).rev() {
            if cursor > 0 && line_index == 0 {
                continue;
            }
            let line_start = if line_index == 0 {
                0
            } else {
                newline_positions[line_index - 1] + 1
            };
            let line_end = newline_positions[line_index];
            if suffix_oversized && line_index + 1 == newline_positions.len() {
                if let Some(observation) = lifecycle_state_from_prefix(&data[line_start..line_end])
                {
                    return Ok(Some(observation));
                }
                continue;
            }
            if line_end.saturating_sub(line_start) > MAX_JSONL_LINE_BYTES {
                continue;
            }
            if let Some(observation) = lifecycle_state(&data[line_start..line_end]) {
                return Ok(Some(observation));
            }
        }

        if cursor == 0 {
            break;
        }
        if chunk_has_newline {
            let first_newline = chunk_slice
                .iter()
                .position(|byte| *byte == b'\n')
                .expect("checked above");
            if first_newline > MAX_JSONL_LINE_BYTES {
                suffix.clear();
                suffix_oversized = true;
            } else {
                suffix.clear();
                suffix.extend_from_slice(&chunk_slice[..=first_newline]);
                suffix_oversized = false;
            }
        } else if suffix_oversized || length.saturating_add(suffix.len()) > MAX_JSONL_LINE_BYTES + 1
        {
            suffix.clear();
            suffix_oversized = true;
        } else {
            let mut joined = Vec::with_capacity(length + suffix.len());
            joined.extend_from_slice(chunk_slice);
            joined.extend_from_slice(&suffix);
            suffix = joined;
        }
    }
    Ok(None)
}

fn scan_complete_lines_forward(
    file: &mut fs::File,
    start: u64,
    end: u64,
    mut visit: impl FnMut(&[u8]) -> bool,
) -> Result<(), String> {
    if end <= start {
        return Ok(());
    }
    file.seek(SeekFrom::Start(start))
        .map_err(|error| format!("定位会话文件失败：{error}"))?;
    let mut remaining = end - start;
    let mut buffer = vec![0_u8; FORWARD_CHUNK_BYTES];
    let mut line = Vec::new();
    let mut discarding_oversized_line = false;
    while remaining > 0 {
        let requested = remaining.min(FORWARD_CHUNK_BYTES as u64) as usize;
        file.read_exact(&mut buffer[..requested])
            .map_err(|error| format!("读取会话文件失败：{error}"))?;
        remaining -= requested as u64;
        for byte in &buffer[..requested] {
            if *byte == b'\n' {
                if visit(&line) {
                    return Ok(());
                }
                line.clear();
                discarding_oversized_line = false;
            } else if !discarding_oversized_line {
                if line.len() < MAX_JSONL_LINE_BYTES {
                    line.push(*byte);
                } else {
                    discarding_oversized_line = true;
                }
            }
        }
    }
    Ok(())
}

fn last_complete_line_offset(file: &mut fs::File, size: u64) -> Result<u64, String> {
    let mut cursor = size;
    let mut buffer = vec![0_u8; REVERSE_CHUNK_BYTES];
    while cursor > 0 {
        let start = cursor.saturating_sub(REVERSE_CHUNK_BYTES as u64);
        let length = (cursor - start) as usize;
        file.seek(SeekFrom::Start(start))
            .map_err(|error| format!("定位会话文件尾部失败：{error}"))?;
        file.read_exact(&mut buffer[..length])
            .map_err(|error| format!("读取会话文件尾部失败：{error}"))?;
        if let Some(index) = buffer[..length].iter().rposition(|byte| *byte == b'\n') {
            return Ok(start + index as u64 + 1);
        }
        cursor = start;
    }
    Ok(0)
}

fn boundary_signature(file: &mut fs::File, end_offset: u64) -> Result<u64, String> {
    const FNV_OFFSET: u64 = 14_695_981_039_346_656_037;
    const FNV_PRIME: u64 = 1_099_511_628_211;
    let sample_size = end_offset.min(128) as usize;
    if sample_size == 0 {
        return Ok(FNV_OFFSET);
    }
    file.seek(SeekFrom::Start(end_offset - sample_size as u64))
        .map_err(|error| format!("定位会话边界失败：{error}"))?;
    let mut sample = [0_u8; 128];
    file.read_exact(&mut sample[..sample_size])
        .map_err(|error| format!("读取会话边界失败：{error}"))?;
    Ok(sample[..sample_size].iter().fold(FNV_OFFSET, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(FNV_PRIME)
    }))
}

fn signature_modified_time(signature: FileSignature) -> SystemTime {
    let seconds = (signature.modified_ns / 1_000_000_000).min(u64::MAX as u128) as u64;
    let nanos = (signature.modified_ns % 1_000_000_000) as u32;
    SystemTime::UNIX_EPOCH + Duration::new(seconds, nanos)
}

fn file_signature(path: &Path) -> Result<FileSignature, String> {
    let file = fs::File::open(path)
        .map_err(|error| format!("打开会话文件失败：{}（{error}）", path.display()))?;
    file_signature_from_handle(&file, path)
}

fn file_signature_from_handle(file: &fs::File, path: &Path) -> Result<FileSignature, String> {
    let metadata = file
        .metadata()
        .map_err(|error| format!("读取会话文件元数据失败：{}（{error}）", path.display()))?;
    let modified_ns = metadata
        .modified()
        .unwrap_or(SystemTime::UNIX_EPOCH)
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (identity, changed_ns) = platform_file_identity(file, &metadata, path)?;
    Ok(FileSignature {
        size: metadata.len(),
        modified_ns,
        identity,
        changed_ns,
    })
}

#[cfg(unix)]
fn platform_file_identity(
    _file: &fs::File,
    metadata: &fs::Metadata,
    _path: &Path,
) -> Result<(FileIdentity, i128), String> {
    use std::os::unix::fs::MetadataExt;

    Ok((
        FileIdentity {
            device_id: metadata.dev(),
            file_id: metadata.ino(),
        },
        i128::from(metadata.ctime())
            .saturating_mul(1_000_000_000)
            .saturating_add(i128::from(metadata.ctime_nsec())),
    ))
}

#[cfg(windows)]
fn platform_file_identity(
    file: &fs::File,
    _metadata: &fs::Metadata,
    path: &Path,
) -> Result<(FileIdentity, i128), String> {
    use std::mem::MaybeUninit;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::Storage::FileSystem::{
        FileBasicInfo, GetFileInformationByHandle, GetFileInformationByHandleEx,
        BY_HANDLE_FILE_INFORMATION, FILE_BASIC_INFO,
    };

    let raw_handle = file.as_raw_handle() as HANDLE;
    let mut identity = MaybeUninit::<BY_HANDLE_FILE_INFORMATION>::zeroed();
    if unsafe { GetFileInformationByHandle(raw_handle, identity.as_mut_ptr()) } == 0 {
        return Err(format!(
            "读取 Windows 会话文件身份失败：{}（{}）",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let identity = unsafe { identity.assume_init() };
    let mut basic = MaybeUninit::<FILE_BASIC_INFO>::zeroed();
    if unsafe {
        GetFileInformationByHandleEx(
            raw_handle,
            FileBasicInfo,
            basic.as_mut_ptr().cast(),
            std::mem::size_of::<FILE_BASIC_INFO>() as u32,
        )
    } == 0
    {
        return Err(format!(
            "读取 Windows 会话文件变更时间失败：{}（{}）",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let basic = unsafe { basic.assume_init() };
    Ok((
        FileIdentity {
            device_id: u64::from(identity.dwVolumeSerialNumber),
            file_id: (u64::from(identity.nFileIndexHigh) << 32) | u64::from(identity.nFileIndexLow),
        },
        i128::from(basic.ChangeTime).saturating_mul(100),
    ))
}

#[cfg(not(any(unix, windows)))]
fn platform_file_identity(
    _file: &fs::File,
    metadata: &fs::Metadata,
    _path: &Path,
) -> Result<(FileIdentity, i128), String> {
    Ok((
        FileIdentity {
            device_id: 0,
            file_id: 0,
        },
        metadata
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH)
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            .min(i128::MAX as u128) as i128,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    struct TestHome {
        root: PathBuf,
    }

    impl TestHome {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "codex-token-bar-thread-activity-{}",
                uuid::Uuid::new_v4()
            ));
            fs::create_dir_all(root.join("sessions/2026/07/28")).unwrap();
            Self { root }
        }

        fn session(&self) -> PathBuf {
            self.root.join("sessions/2026/07/28/rollout-test.jsonl")
        }
    }

    impl Drop for TestHome {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn meta(source: &str) -> String {
        format!(
            "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"one\",\"source\":{source}}}}}\n"
        )
    }

    fn event(kind: &str) -> String {
        format!("{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"{kind}\"}}}}\n")
    }

    #[test]
    fn latest_lifecycle_event_is_authoritative() {
        let home = TestHome::new();
        fs::write(
            home.session(),
            format!(
                "{}{}{}",
                meta("\"cli\""),
                event("task_started"),
                event("task_complete")
            ),
        )
        .unwrap();
        let counts = ThreadActivityScanner::default().scan(&home.root).unwrap();
        assert_eq!(counts.total(), 0);
    }

    #[test]
    fn nested_subagent_source_is_classified_but_fork_id_alone_is_main() {
        let subagent_home = TestHome::new();
        fs::write(
            subagent_home.session(),
            format!(
                "{}{}",
                meta("{\"bridge\":{\"source\":{\"subagent\":{\"kind\":\"review\"}}}}"),
                event("task_started")
            ),
        )
        .unwrap();
        let subagent = ThreadActivityScanner::default()
            .scan(&subagent_home.root)
            .unwrap();
        assert_eq!(subagent.subagents, 1);
        assert_eq!(subagent.main_threads, 0);

        let fork_home = TestHome::new();
        fs::write(
            fork_home.session(),
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"two\",\"source\":\"cli\",",
                "\"forked_from_id\":\"parent\"}}\n",
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
            ),
        )
        .unwrap();
        let fork = ThreadActivityScanner::default()
            .scan(&fork_home.root)
            .unwrap();
        assert_eq!(fork.main_threads, 1);
        assert_eq!(fork.subagents, 0);

        let negative_marker_home = TestHome::new();
        fs::write(
            negative_marker_home.session(),
            format!(
                "{}{}",
                meta("{\"note\":\"not_subagent\"}"),
                event("task_started")
            ),
        )
        .unwrap();
        let negative_marker = ThreadActivityScanner::default()
            .scan(&negative_marker_home.root)
            .unwrap();
        assert_eq!(negative_marker.main_threads, 1);
        assert_eq!(negative_marker.subagents, 0);
    }

    #[test]
    fn partial_tail_is_ignored_then_incrementally_applied() {
        let home = TestHome::new();
        fs::write(
            home.session(),
            format!(
                "{}{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_started\"}}}}",
                meta("\"cli\"")
            ),
        )
        .unwrap();
        let mut scanner = ThreadActivityScanner::default();
        assert_eq!(scanner.scan(&home.root).unwrap().total(), 0);

        let mut file = fs::OpenOptions::new()
            .append(true)
            .open(home.session())
            .unwrap();
        file.write_all(b"\n").unwrap();
        file.sync_all().unwrap();
        assert_eq!(scanner.scan(&home.root).unwrap().main_threads, 1);

        file.write_all(event("turn_aborted").as_bytes()).unwrap();
        file.sync_all().unwrap();
        assert_eq!(scanner.scan(&home.root).unwrap().total(), 0);
    }

    #[test]
    fn truncation_rebuilds_state_instead_of_reusing_old_tail() {
        let home = TestHome::new();
        fs::write(
            home.session(),
            format!("{}{}", meta("\"cli\""), event("task_started")),
        )
        .unwrap();
        let mut scanner = ThreadActivityScanner::default();
        assert_eq!(scanner.scan(&home.root).unwrap().main_threads, 1);

        fs::write(
            home.session(),
            format!("{}{}", meta("\"cli\""), event("thread_rolled_back")),
        )
        .unwrap();
        assert_eq!(scanner.scan(&home.root).unwrap().total(), 0);
    }

    #[test]
    fn duplicate_paths_for_one_session_id_are_counted_once() {
        let home = TestHome::new();
        let first = home.session();
        let second = first.with_file_name("rollout-copy.jsonl");
        fs::write(
            &first,
            format!("{}{}", meta("\"cli\""), event("task_started")),
        )
        .unwrap();
        fs::write(
            &second,
            format!("{}{}", meta("\"cli\""), event("task_started")),
        )
        .unwrap();

        let counts = ThreadActivityScanner::default().scan(&home.root).unwrap();
        assert_eq!(counts.total(), 1);
    }

    #[test]
    fn duplicate_without_lifecycle_cannot_hide_timestamped_running_state() {
        let home = TestHome::new();
        let known = home.session();
        let unknown = known.with_file_name("rollout-newer-without-lifecycle.jsonl");
        fs::write(
            &known,
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"duplicate\",\"source\":\"cli\"}}\n",
                "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-28T02:00:00Z\",",
                "\"payload\":{\"type\":\"task_started\"}}\n"
            ),
        )
        .unwrap();
        fs::write(
            &unknown,
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"duplicate\",\"source\":\"cli\"}}\n",
                "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}\n"
            ),
        )
        .unwrap();

        let counts = ThreadActivityScanner::default().scan(&home.root).unwrap();
        assert_eq!(counts.main_threads, 1);
        assert_eq!(counts.total(), 1);
    }

    #[test]
    fn duplicate_without_lifecycle_cannot_hide_untimestamped_terminal_state() {
        let home = TestHome::new();
        let known = home.session();
        let unknown = known.with_file_name("rollout-newer-unknown.jsonl");
        fs::write(
            &known,
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"duplicate-idle\",\"source\":\"cli\"}}\n",
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n"
            ),
        )
        .unwrap();
        fs::write(
            &unknown,
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"duplicate-idle\",\"source\":\"cli\"}}\n",
                "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}\n"
            ),
        )
        .unwrap();

        let mut scanner = ThreadActivityScanner::default();
        let counts = scanner.scan(&home.root).unwrap();
        assert_eq!(counts.total(), 0);
        let known_session = scanner
            .tracked
            .get(&fs::canonicalize(known).unwrap())
            .unwrap();
        let unknown_session = scanner
            .tracked
            .get(&fs::canonicalize(unknown).unwrap())
            .unwrap();
        assert!(known_session.lifecycle_known);
        assert!(!unknown_session.lifecycle_known);
        assert!(session_is_newer(known_session, unknown_session));
        assert!(!session_is_newer(unknown_session, known_session));
    }

    #[test]
    fn append_with_a_rewritten_prefix_forces_a_cold_rebuild() {
        let home = TestHome::new();
        fs::write(
            home.session(),
            format!("{}{}", meta("\"cli\""), event("task_started")),
        )
        .unwrap();
        let mut scanner = ThreadActivityScanner::default();
        assert_eq!(scanner.scan(&home.root).unwrap().main_threads, 1);

        fs::write(
            home.session(),
            format!(
                "{}{}{}\n",
                meta("\"cli\""),
                event("turn_aborted"),
                "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}"
            ),
        )
        .unwrap();
        assert_eq!(scanner.scan(&home.root).unwrap().total(), 0);
    }

    #[test]
    fn reverse_scan_has_no_total_history_byte_cap() {
        let home = TestHome::new();
        let mut content = format!("{}{}", meta("\"cli\""), event("task_started"));
        // Cross several reverse-read chunks so this test cannot pass by only
        // inspecting the final 64 KiB.
        for _ in 0..4096 {
            content.push_str(
                "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"padding\"}}\n",
            );
        }
        fs::write(home.session(), content).unwrap();

        assert_eq!(
            ThreadActivityScanner::default()
                .scan(&home.root)
                .unwrap()
                .main_threads,
            1
        );
    }

    #[test]
    fn cold_scan_includes_recent_session_missing_from_nonempty_database() {
        let home = TestHome::new();
        let registered = home.session();
        let unregistered = registered.with_file_name("rollout-unregistered.jsonl");
        fs::write(
            &registered,
            format!("{}{}", meta("\"cli\""), event("task_complete")),
        )
        .unwrap();
        fs::write(
            &unregistered,
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"unregistered\",",
                "\"source\":\"cli\"}}\n",
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
            ),
        )
        .unwrap();

        let connection = rusqlite::Connection::open(home.root.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                "
                CREATE TABLE threads (
                    rollout_path TEXT,
                    updated_at INTEGER,
                    archived INTEGER
                );
                ",
            )
            .unwrap();
        let updated_at = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        connection
            .execute(
                "INSERT INTO threads (rollout_path, updated_at, archived) VALUES (?1, ?2, 0)",
                rusqlite::params![registered.to_string_lossy(), updated_at],
            )
            .unwrap();

        let counts = ThreadActivityScanner::default().scan(&home.root).unwrap();
        assert_eq!(counts.main_threads, 1);
        assert_eq!(counts.total(), 1);
    }

    #[test]
    fn oversized_terminal_lifecycle_line_still_closes_the_thread() {
        let home = TestHome::new();
        let oversized_complete = [
            concat!(
                "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-28T01:00:00Z\",",
                "\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\""
            ),
            &"x".repeat(MAX_JSONL_LINE_BYTES + REVERSE_CHUNK_BYTES),
            "\"}}\n",
        ]
        .concat();
        fs::write(
            home.session(),
            format!(
                "{}{}{}",
                meta("\"cli\""),
                event("task_started"),
                oversized_complete
            ),
        )
        .unwrap();
        assert_eq!(
            ThreadActivityScanner::default()
                .scan(&home.root)
                .unwrap()
                .total(),
            0
        );

        fs::write(
            home.session(),
            format!("{}{}", meta("\"cli\""), event("task_started")),
        )
        .unwrap();
        let mut scanner = ThreadActivityScanner::default();
        assert_eq!(scanner.scan(&home.root).unwrap().main_threads, 1);
        let mut file = fs::OpenOptions::new()
            .append(true)
            .open(home.session())
            .unwrap();
        file.write_all(oversized_complete.as_bytes()).unwrap();
        file.sync_all().unwrap();
        assert_eq!(scanner.scan(&home.root).unwrap().total(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_session_file_cannot_escape_the_source_root() {
        use std::os::unix::fs::symlink;

        let home = TestHome::new();
        let outside = home.root.with_file_name(format!(
            "codex-token-bar-thread-outside-{}",
            uuid::Uuid::new_v4()
        ));
        fs::write(
            &outside,
            format!("{}{}", meta("\"cli\""), event("task_started")),
        )
        .unwrap();
        symlink(&outside, home.session()).unwrap();

        let counts = ThreadActivityScanner::default().scan(&home.root).unwrap();
        assert_eq!(counts.total(), 0);
        let _ = fs::remove_file(outside);
    }
}
