use crate::core::sqlite;
use crate::models::LiveThreadOption;
use rusqlite::{params, Connection, Result};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Default)]
pub(super) struct UsageSummary {
    pub(super) total_tokens: u64,
    pub(super) today_tokens: u64,
    pub(super) today_requests: u32,
}

#[derive(Clone, Debug)]
pub(super) struct RolloutThread {
    pub(super) id: String,
    pub(super) rollout_path: PathBuf,
}

pub(super) fn read_thread_options_result(
    codex_home: &Path,
    limit: usize,
) -> Result<Vec<LiveThreadOption>> {
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;

    let archived_filter = if column_exists(&connection, "threads", "archived") {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let source_filter = if column_exists(&connection, "threads", "thread_source") {
        "COALESCE(thread_source, 'user') != 'subagent'"
    } else {
        "1 = 1"
    };
    let sql = format!(
        r#"
        SELECT id, title, first_user_message, preview,
               strftime(
                 '%m/%d %H:%M',
                 CASE
                   WHEN COALESCE(updated_at_ms, updated_at) > 9999999999
                     THEN COALESCE(updated_at_ms, updated_at) / 1000
                   ELSE COALESCE(updated_at_ms, updated_at)
                 END,
                 'unixepoch',
                 'localtime'
               ) AS updated_label,
               tokens_used
        FROM threads
        WHERE {archived_filter}
          AND {source_filter}
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC, id ASC
        LIMIT ?1;
        "#,
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![limit as i64], |row| {
        let id: String = row.get(0)?;
        let title: String = row.get(1)?;
        let first_message: String = row.get(2)?;
        let preview: String = row.get(3)?;
        let updated_at: String = row.get(4)?;
        let tokens_used: i64 = row.get(5)?;
        Ok(LiveThreadOption {
            id,
            title: best_thread_label(&[&title, &first_message, &preview]),
            subtitle: best_thread_subtitle(&title, &first_message, &preview),
            updated_at,
            tokens_used: u64::try_from(tokens_used).unwrap_or(0),
        })
    })?;

    rows.collect()
}

pub(super) fn read_recent_rollout_threads(
    codex_home: &Path,
    limit: usize,
) -> Result<Vec<RolloutThread>> {
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;
    if !column_exists(&connection, "threads", "rollout_path") {
        return Ok(Vec::new());
    }

    let archived_filter = if column_exists(&connection, "threads", "archived") {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let sql = format!(
        r#"
        SELECT id, rollout_path
        FROM threads
        WHERE {archived_filter}
          AND rollout_path IS NOT NULL
          AND rollout_path <> ''
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC, id ASC
        LIMIT ?1;
        "#,
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![limit as i64], |row| {
        let id: String = row.get(0)?;
        let rollout_path: String = row.get(1)?;
        Ok(RolloutThread {
            id,
            rollout_path: normalize_rollout_path(codex_home, rollout_path),
        })
    })?;

    rows.collect()
}

pub(super) fn read_thread_title(codex_home: &Path, thread_id: &str) -> Result<Option<String>> {
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;
    let mut statement = connection.prepare(
        r#"
        SELECT title, first_user_message, preview
        FROM threads
        WHERE id = ?1
        LIMIT 1;
        "#,
    )?;
    let mut rows = statement.query(params![thread_id])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };

    for index in 0..3 {
        let value: String = row.get(index)?;
        let cleaned = compact_title(&value);
        if !cleaned.is_empty() {
            return Ok(Some(cleaned));
        }
    }
    Ok(None)
}

fn column_exists(connection: &Connection, table: &str, column: &str) -> bool {
    let Ok(mut statement) = connection.prepare(&format!("PRAGMA table_info({table})")) else {
        return false;
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(1)) else {
        return false;
    };

    let exists = rows.filter_map(|row| row.ok()).any(|name| name == column);
    exists
}

fn best_thread_label(values: &[&str]) -> String {
    values
        .iter()
        .map(|value| compact_title(value))
        .find(|value| !value.is_empty())
        .unwrap_or_else(|| "无标题会话".into())
}

fn best_thread_subtitle(title: &str, first_message: &str, preview: &str) -> String {
    let title = compact_title(title);
    for value in [first_message, preview] {
        let cleaned = compact_title(value);
        if !cleaned.is_empty() && cleaned != title {
            return cleaned;
        }
    }
    "最近会话".into()
}

fn compact_title(value: &str) -> String {
    let mut title = value.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_CHARS: usize = 88;
    if title.chars().count() > MAX_CHARS {
        title = title.chars().take(MAX_CHARS).collect::<String>();
        title.push('…');
    }
    title
}

fn normalize_rollout_path(codex_home: &Path, rollout_path: String) -> PathBuf {
    let path = PathBuf::from(rollout_path);
    if path.is_absolute() {
        path
    } else {
        codex_home.join(path)
    }
}

fn open_read_only(path: &Path) -> Result<Connection> {
    sqlite::open_read_only(path, Duration::from_millis(100))
}
