use crate::core::sqlite;
use crate::models::LiveThreadOption;
use rusqlite::{params, Connection, Result};
use std::path::Path;
use std::time::Duration;

#[derive(Default)]
pub(super) struct UsageSummary {
    pub(super) total_tokens: u64,
    pub(super) today_tokens: u64,
    pub(super) today_requests: u32,
}

pub(super) fn read_usage_summary(codex_home: &Path) -> Result<UsageSummary> {
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;
    connection.query_row(
        r#"
        SELECT
          COALESCE(SUM(tokens_used), 0),
          COALESCE(SUM(
            CASE
              WHEN date(
                CASE
                  WHEN COALESCE(updated_at_ms, updated_at) > 9999999999
                    THEN COALESCE(updated_at_ms, updated_at) / 1000
                  ELSE COALESCE(updated_at_ms, updated_at)
                END,
                'unixepoch',
                'localtime'
              ) = date('now', 'localtime') THEN tokens_used
              ELSE 0
            END
          ), 0),
          COALESCE(SUM(
            CASE
              WHEN date(
                CASE
                  WHEN COALESCE(updated_at_ms, updated_at) > 9999999999
                    THEN COALESCE(updated_at_ms, updated_at) / 1000
                  ELSE COALESCE(updated_at_ms, updated_at)
                END,
                'unixepoch',
                'localtime'
              ) = date('now', 'localtime') THEN 1
              ELSE 0
            END
          ), 0)
        FROM threads;
        "#,
        [],
        |row| {
            let total_tokens: i64 = row.get(0)?;
            let today_tokens: i64 = row.get(1)?;
            let today_requests: i64 = row.get(2)?;
            Ok(UsageSummary {
                total_tokens: u64::try_from(total_tokens).unwrap_or(0),
                today_tokens: u64::try_from(today_tokens).unwrap_or(0),
                today_requests: u32::try_from(today_requests).unwrap_or(0),
            })
        },
    )
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

fn open_read_only(path: &Path) -> Result<Connection> {
    sqlite::open_read_only(path, Duration::from_millis(100))
}
