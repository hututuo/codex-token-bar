use crate::core::sqlite;
use crate::models::UnreadSummary;
use rusqlite::{params_from_iter, Connection, Result as SqlResult};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::time::Duration;

mod recent_completion;
mod session_files;

use session_files::{
    contains_subagent_text, jsonl_files, session_meta_payload, value_contains_subagent,
};

pub fn read_unread_summary(codex_home: &Path) -> UnreadSummary {
    match read_unread_thread_ids(codex_home) {
        Some(thread_ids) => unread_state_summary(thread_ids.len()),
        None => recent_completion::recent_completion_summary(codex_home),
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
    let connection = sqlite::open_read_only(database_path, Duration::from_secs(3))?;
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

fn unread_state_summary(count: usize) -> UnreadSummary {
    let active = count > 0;
    UnreadSummary {
        active,
        count: count as u32,
        label: if active {
            "有未读完成会话".into()
        } else {
            "暂无未读完成会话".into()
        },
        detail: if active {
            format!("{count} 个会话等待查看")
        } else {
            "Codex 未读列表为空。".into()
        },
        source: "codex_unread_state".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use recent_completion::{current_time_seconds, lookback_seconds};
    use std::io::Write;
    use std::path::PathBuf;
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
        let summary = read_unread_summary(&root);
        assert!(summary.active);
        assert_eq!(summary.count, 1);
        assert_eq!(summary.source, "codex_unread_state");

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

        let summary = read_unread_summary(&root);
        assert!(summary.active);
        assert_eq!(summary.count, 1);
        assert_eq!(summary.source, "recent_task_complete");

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

        assert!(!read_unread_summary(&root).active);

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
            current_time_seconds() - lookback_seconds() - 10.0,
        );

        assert!(!read_unread_summary(&root).active);

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
