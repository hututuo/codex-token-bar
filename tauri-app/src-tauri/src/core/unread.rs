use rusqlite::{params_from_iter, Connection, OpenFlags, Result as SqlResult};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const RECENT_COMPLETION_LOOKBACK_SECONDS: f64 = 30.0;
const RECENT_COMPLETION_FILE_LIMIT: usize = 64;
const RECENT_COMPLETION_TAIL_BYTE_LIMIT: u64 = 4 * 1024 * 1024;

pub fn has_unread_threads(codex_home: &Path) -> bool {
    match read_unread_thread_ids(codex_home) {
        Some(thread_ids) => !thread_ids.is_empty(),
        None => has_recent_completed_user_task(codex_home),
    }
}

fn read_unread_thread_ids(codex_home: &Path) -> Option<HashSet<String>> {
    let path = codex_home.join(".codex-global-state.json");
    let data = fs::read(path).ok()?;
    let object: Value = serde_json::from_slice(&data).ok()?;
    let Some(unread_state) = unread_state_value(&object) else {
        return Some(HashSet::new());
    };
    let thread_ids = collect_thread_ids(unread_state);
    Some(visible_user_thread_ids(&thread_ids, codex_home))
}

fn unread_state_value(object: &Value) -> Option<&Value> {
    object
        .get("electron-persisted-atom-state")
        .and_then(|state| state.get("unread-thread-ids-by-host-v1"))
        .or_else(|| object.get("unread-thread-ids-by-host-v1"))
}

fn collect_thread_ids(value: &Value) -> HashSet<String> {
    let mut ids = HashSet::new();
    collect_thread_ids_into(value, &mut ids);
    ids
}

fn collect_thread_ids_into(value: &Value, ids: &mut HashSet<String>) {
    match value {
        Value::String(text) if looks_like_thread_id(text) => {
            ids.insert(text.trim().to_string());
        }
        Value::Array(items) => {
            for item in items {
                collect_thread_ids_into(item, ids);
            }
        }
        Value::Object(map) => {
            for item in map.values() {
                collect_thread_ids_into(item, ids);
            }
        }
        _ => {}
    }
}

fn looks_like_thread_id(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.len() >= 24 && trimmed.contains('-')
}

fn visible_user_thread_ids(thread_ids: &HashSet<String>, codex_home: &Path) -> HashSet<String> {
    if thread_ids.is_empty() {
        return HashSet::new();
    }

    let database_path = codex_home.join("state_5.sqlite");
    if !database_path.exists() {
        return visible_or_unresolved_thread_ids(thread_ids, codex_home);
    }

    match read_visible_user_thread_ids(thread_ids, &database_path, codex_home) {
        Ok(ids) => ids,
        Err(_) => session_visible_thread_ids(thread_ids, codex_home).visible_ids,
    }
}

fn read_visible_user_thread_ids(
    thread_ids: &HashSet<String>,
    database_path: &Path,
    codex_home: &Path,
) -> SqlResult<HashSet<String>> {
    let connection = Connection::open_with_flags(
        database_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    connection.busy_timeout(std::time::Duration::from_secs(3))?;
    let columns = read_thread_columns(&connection)?;

    let archived = if columns.contains("archived") {
        "COALESCE(archived, 0)"
    } else {
        "0"
    };
    let thread_source = if columns.contains("thread_source") {
        "COALESCE(thread_source, 'user')"
    } else {
        "'user'"
    };
    let source = if columns.contains("source") {
        "COALESCE(source, '')"
    } else {
        "''"
    };
    let preview = if columns.contains("preview") {
        "COALESCE(preview, '')"
    } else {
        "'legacy'"
    };

    let sorted_ids: Vec<String> = thread_ids.iter().cloned().collect();
    let placeholders = std::iter::repeat_n("?", sorted_ids.len()).collect::<Vec<_>>().join(",");
    let sql = format!(
        "SELECT id, {archived}, {thread_source}, {source}, {preview} FROM threads WHERE id IN ({placeholders});"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params_from_iter(sorted_ids.iter()), |row| {
        Ok(ThreadVisibilityRow {
            id: row.get(0)?,
            archived: row.get::<_, i64>(1)? != 0,
            thread_source: row.get(2)?,
            source: row.get(3)?,
            preview: row.get(4)?,
        })
    })?;

    let mut matched = HashSet::new();
    let mut visible = HashSet::new();
    for row in rows.flatten() {
        matched.insert(row.id.clone());
        if row.is_visible_user_thread() {
            visible.insert(row.id);
        }
    }

    let unresolved: HashSet<String> = thread_ids.difference(&matched).cloned().collect();
    if !unresolved.is_empty() {
        let session_visibility = session_visible_thread_ids(&unresolved, codex_home);
        visible.extend(session_visibility.visible_ids);
        visible.extend(unresolved.difference(&session_visibility.found_ids).cloned());
    }
    Ok(visible)
}

fn read_thread_columns(connection: &Connection) -> SqlResult<HashSet<String>> {
    let mut statement = connection.prepare("PRAGMA table_info(threads);")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(1))?;
    Ok(rows.filter_map(Result::ok).collect())
}

#[derive(Debug)]
struct ThreadVisibilityRow {
    id: String,
    archived: bool,
    thread_source: String,
    source: String,
    preview: String,
}

impl ThreadVisibilityRow {
    fn is_visible_user_thread(&self) -> bool {
        !self.archived
            && !self.preview.trim().is_empty()
            && !contains_subagent_text(&self.thread_source)
            && !contains_subagent_text(&self.source)
    }
}

#[derive(Default)]
struct SessionVisibility {
    visible_ids: HashSet<String>,
    found_ids: HashSet<String>,
}

fn visible_or_unresolved_thread_ids(
    thread_ids: &HashSet<String>,
    codex_home: &Path,
) -> HashSet<String> {
    let session_visibility = session_visible_thread_ids(thread_ids, codex_home);
    let unresolved = thread_ids.difference(&session_visibility.found_ids).cloned();
    session_visibility.visible_ids.into_iter().chain(unresolved).collect()
}

fn session_visible_thread_ids(
    thread_ids: &HashSet<String>,
    codex_home: &Path,
) -> SessionVisibility {
    let mut visibility = SessionVisibility::default();
    scan_session_metas(
        &codex_home.join("sessions"),
        false,
        thread_ids,
        &mut visibility,
    );
    scan_session_metas(
        &codex_home.join("archived_sessions"),
        true,
        thread_ids,
        &mut visibility,
    );
    visibility
}

fn scan_session_metas(
    root: &Path,
    archived: bool,
    thread_ids: &HashSet<String>,
    visibility: &mut SessionVisibility,
) {
    if visibility.found_ids.len() >= thread_ids.len() {
        return;
    }
    for file in jsonl_files(root) {
        if visibility.found_ids.len() >= thread_ids.len() {
            return;
        }
        let Some(payload) = session_meta_payload(&file) else {
            continue;
        };
        let Some(id) = payload.get("id").and_then(Value::as_str) else {
            continue;
        };
        if !thread_ids.contains(id) {
            continue;
        }
        visibility.found_ids.insert(id.to_string());

        let thread_source = payload
            .get("thread_source")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let source = payload.get("source");
        if !archived && !contains_subagent_text(thread_source) && !value_contains_subagent(source) {
            visibility.visible_ids.insert(id.to_string());
        }
    }
}

fn jsonl_files(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_jsonl_files(root, &mut files);
    files
}

fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_jsonl_files(&path, files);
        } else if path.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(path);
        }
    }
}

fn session_meta_payload(file: &Path) -> Option<Value> {
    let line = first_line(file)?;
    let object: Value = serde_json::from_str(&line).ok()?;
    if object.get("type")?.as_str()? != "session_meta" {
        return None;
    }
    object.get("payload").cloned()
}

fn first_line(file: &Path) -> Option<String> {
    let handle = fs::File::open(file).ok()?;
    let mut reader = BufReader::new(handle.take(262_144));
    let mut line = String::new();
    let bytes = reader.read_line(&mut line).ok()?;
    if bytes == 0 {
        None
    } else {
        Some(line.trim_end_matches(['\r', '\n']).to_string())
    }
}

fn has_recent_completed_user_task(codex_home: &Path) -> bool {
    let now = current_time_seconds();
    recent_session_files(&codex_home.join("sessions"), now)
        .into_iter()
        .any(|file| file_has_recent_completed_user_task(&file, now))
}

fn recent_session_files(root: &Path, now: f64) -> Vec<PathBuf> {
    let cutoff = now - RECENT_COMPLETION_LOOKBACK_SECONDS;
    let mut files = Vec::<(PathBuf, f64)>::new();
    for file in jsonl_files(root) {
        let modified_at = fs::metadata(&file)
            .ok()
            .and_then(|metadata| metadata.modified().ok())
            .and_then(system_time_seconds)
            .unwrap_or(0.0);
        if modified_at >= cutoff {
            files.push((file, modified_at));
        }
    }
    files.sort_by(|left, right| right.1.total_cmp(&left.1));
    files
        .into_iter()
        .take(RECENT_COMPLETION_FILE_LIMIT)
        .map(|(file, _)| file)
        .collect()
}

fn file_has_recent_completed_user_task(file: &Path, now: f64) -> bool {
    let Some(payload) = session_meta_payload(file) else {
        return false;
    };
    let thread_source = payload
        .get("thread_source")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if contains_subagent_text(thread_source) || value_contains_subagent(payload.get("source")) {
        return false;
    }

    let cutoff = now - RECENT_COMPLETION_LOOKBACK_SECONDS;
    tail_lines(file)
        .into_iter()
        .any(|line| recent_task_complete_timestamp(&line).is_some_and(|time| time >= cutoff))
}

fn tail_lines(file: &Path) -> Vec<String> {
    let Ok(mut handle) = fs::File::open(file) else {
        return Vec::new();
    };
    let size = handle.metadata().map(|metadata| metadata.len()).unwrap_or(0);
    let start = size.saturating_sub(RECENT_COMPLETION_TAIL_BYTE_LIMIT);
    if handle.seek(SeekFrom::Start(start)).is_err() {
        return Vec::new();
    }
    let mut data = Vec::new();
    if handle.read_to_end(&mut data).is_err() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&data);
    let mut lines = text.lines();
    if start > 0 {
        let _ = lines.next();
    }
    lines.map(str::to_string).collect()
}

fn recent_task_complete_timestamp(line: &str) -> Option<f64> {
    if !line.contains("event_msg") || !line.contains("task_complete") {
        return None;
    }
    let object: Value = serde_json::from_str(line).ok()?;
    if object.get("type")?.as_str()? != "event_msg" {
        return None;
    }
    let payload = object.get("payload")?;
    if payload.get("type")?.as_str()? != "task_complete" {
        return None;
    }
    number(payload.get("completed_at"))
        .or_else(|| parse_timestamp(object.get("timestamp")?.as_str()?))
}

fn number(value: Option<&Value>) -> Option<f64> {
    match value {
        Some(Value::Number(number)) => number.as_f64(),
        Some(Value::String(text)) => text.parse::<f64>().ok(),
        _ => None,
    }
}

fn parse_timestamp(value: &str) -> Option<f64> {
    OffsetDateTime::parse(value, &Rfc3339)
        .ok()
        .map(|date| date.unix_timestamp() as f64 + f64::from(date.nanosecond()) / 1_000_000_000.0)
}

fn current_time_seconds() -> f64 {
    system_time_seconds(SystemTime::now()).unwrap_or(0.0)
}

fn system_time_seconds(value: SystemTime) -> Option<f64> {
    value
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs_f64())
}

fn contains_subagent_text(value: &str) -> bool {
    value.to_ascii_lowercase().contains("subagent")
}

fn value_contains_subagent(value: Option<&Value>) -> bool {
    match value {
        Some(Value::String(text)) => contains_subagent_text(text),
        Some(Value::Array(items)) => items.iter().any(|item| value_contains_subagent(Some(item))),
        Some(Value::Object(map)) => {
            map.keys().any(|key| contains_subagent_text(key))
                || map.values().any(|item| value_contains_subagent(Some(item)))
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn reads_unread_state_and_filters_non_user_visible_threads() {
        let root = temp_root("sqlite-filter");
        fs::create_dir_all(&root).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000001";
        let archived = "019eaaaa-0000-0000-0000-000000000002";
        let subagent = "019eaaaa-0000-0000-0000-000000000003";
        let empty_preview = "019eaaaa-0000-0000-0000-000000000004";
        write_unread_state(&root, &[visible, archived, subagent, empty_preview]);
        create_state_database(&root, visible, archived, subagent, empty_preview);

        let ids = read_unread_thread_ids(&root).unwrap();
        assert_eq!(ids, HashSet::from([visible.to_string()]));
        assert!(has_unread_threads(&root));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn falls_back_to_session_meta_visibility_when_sqlite_is_missing() {
        let root = temp_root("session-fallback");
        let sessions = root.join("sessions");
        let archived_sessions = root.join("archived_sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::create_dir_all(&archived_sessions).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000005";
        let subagent = "019eaaaa-0000-0000-0000-000000000006";
        let archived = "019eaaaa-0000-0000-0000-000000000007";
        write_unread_state(&root, &[visible, subagent, archived]);
        write_session_meta(&sessions.join("visible.jsonl"), visible, false);
        write_session_meta(&sessions.join("subagent.jsonl"), subagent, true);
        write_session_meta(&archived_sessions.join("archived.jsonl"), archived, false);

        let ids = read_unread_thread_ids(&root).unwrap();
        assert_eq!(ids, HashSet::from([visible.to_string()]));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn falls_back_to_recent_task_complete_when_unread_state_is_unavailable() {
        let root = temp_root("task-complete-fallback");
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000008";
        write_session_complete(
            &sessions.join("visible.jsonl"),
            visible,
            false,
            current_time_seconds() - 3.0,
        );

        assert!(has_unread_threads(&root));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn does_not_use_task_complete_fallback_when_unread_state_is_available() {
        let root = temp_root("task-complete-state-priority");
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000009";
        write_unread_state(&root, &[]);
        write_session_complete(
            &sessions.join("visible.jsonl"),
            visible,
            false,
            current_time_seconds() - 3.0,
        );

        assert!(!has_unread_threads(&root));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_complete_fallback_filters_subagents_and_old_completions() {
        let root = temp_root("task-complete-filter");
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        write_session_complete(
            &sessions.join("subagent.jsonl"),
            "019eaaaa-0000-0000-0000-000000000010",
            true,
            current_time_seconds() - 3.0,
        );
        write_session_complete(
            &sessions.join("old.jsonl"),
            "019eaaaa-0000-0000-0000-000000000011",
            false,
            current_time_seconds() - RECENT_COMPLETION_LOOKBACK_SECONDS - 10.0,
        );

        assert!(!has_unread_threads(&root));

        let _ = fs::remove_dir_all(root);
    }

    fn temp_root(label: &str) -> PathBuf {
        let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "codex-token-bar-unread-{label}-{}-{sequence}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn write_unread_state(root: &Path, ids: &[&str]) {
        let values = ids
            .iter()
            .map(|id| format!(r#""{id}""#))
            .collect::<Vec<_>>()
            .join(",");
        fs::write(
            root.join(".codex-global-state.json"),
            format!(
                r#"{{"electron-persisted-atom-state":{{"unread-thread-ids-by-host-v1":{{"localhost":[{values}]}}}}}}"#
            ),
        )
        .unwrap();
    }

    fn create_state_database(
        root: &Path,
        visible: &str,
        archived: &str,
        subagent: &str,
        empty_preview: &str,
    ) {
        let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    archived INTEGER,
                    thread_source TEXT,
                    source TEXT,
                    preview TEXT
                );
                "#,
            )
            .unwrap();
        insert_thread(&connection, visible, 0, "user", "desktop", "hello");
        insert_thread(&connection, archived, 1, "user", "desktop", "archived");
        insert_thread(&connection, subagent, 0, "subagent", "desktop", "subagent");
        insert_thread(&connection, empty_preview, 0, "user", "desktop", "");
    }

    fn insert_thread(
        connection: &Connection,
        id: &str,
        archived: i64,
        thread_source: &str,
        source: &str,
        preview: &str,
    ) {
        connection
            .execute(
                "INSERT INTO threads (id, archived, thread_source, source, preview) VALUES (?1, ?2, ?3, ?4, ?5);",
                (id, archived, thread_source, source, preview),
            )
            .unwrap();
    }

    fn write_session_meta(path: &Path, id: &str, subagent: bool) {
        let mut file = fs::File::create(path).unwrap();
        let source = if subagent { r#""subagent""# } else { r#""desktop""# };
        writeln!(
            file,
            r#"{{"type":"session_meta","payload":{{"id":"{id}","thread_source":{},"source":{source}}}}}"#,
            if subagent { r#""subagent""# } else { r#""user""# }
        )
        .unwrap();
    }

    fn write_session_complete(path: &Path, id: &str, subagent: bool, completed_at: f64) {
        let mut file = fs::File::create(path).unwrap();
        let source = if subagent { r#""subagent""# } else { r#""desktop""# };
        writeln!(
            file,
            r#"{{"type":"session_meta","payload":{{"id":"{id}","thread_source":{},"source":{source}}}}}"#,
            if subagent { r#""subagent""# } else { r#""user""# }
        )
        .unwrap();
        writeln!(
            file,
            r#"{{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{{"type":"task_complete","turn_id":"turn-{id}","completed_at":{completed_at},"duration_ms":2000}}}}"#
        )
        .unwrap();
    }
}
