use super::session_files::{
    contains_subagent_text, jsonl_files, session_meta_payload, value_contains_subagent,
};
use crate::core::sqlite;
use rusqlite::{params_from_iter, Connection, Result as SqlResult};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::time::Duration;

pub(super) fn read_unread_thread_ids(codex_home: &Path) -> Option<HashSet<String>> {
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
