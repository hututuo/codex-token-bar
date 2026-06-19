use crate::core::sqlite;
use crate::core::unread;
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption, LocalDataWarning};
use rusqlite::{params, Connection, Result};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use stream::{rollup_stream_rows, LiveRateRollup, LogRow};

const LOOKBACK_SECONDS: f64 = 8.0;
const MAX_TOKENS_PER_SECOND: f64 = 200.0;

mod stream;

pub fn read_snapshot(codex_home: &Path, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
    match try_read_snapshot(codex_home, selected_thread_id) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            let warnings = vec![live_rate_warning(format!(
                "读取实时输出流失败：{}（{}）",
                codex_home.join("logs_2.sqlite").display(),
                error
            ))];
            idle_snapshot_with_warnings(codex_home, selected_thread_id, warnings)
        }
    }
}

pub fn try_read_snapshot(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
) -> Result<LiveRateSnapshot> {
    read_snapshot_result(codex_home, selected_thread_id)
}

pub fn read_floating_snapshot(codex_home: &Path) -> FloatingPanelSnapshot {
    let live = read_snapshot(codex_home, None);
    floating_from_live(codex_home, &live)
}

pub fn try_read_thread_options(codex_home: &Path) -> Result<Vec<LiveThreadOption>> {
    read_thread_options_result(codex_home, 18)
}

fn idle_snapshot_with_warnings(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
    mut warnings: Vec<LocalDataWarning>,
) -> LiveRateSnapshot {
    let summary = read_usage_summary_or_default(codex_home, &mut warnings);
    let selected_thread_title = selected_thread_id
        .and_then(|thread_id| read_thread_title_or_warn(codex_home, thread_id, &mut warnings))
        .unwrap_or_else(|| "选择会话查看单会话速率".into());
    LiveRateSnapshot {
        scope_label: "全会话".into(),
        thread_title: "等待任意会话输出".into(),
        selected_thread_id: selected_thread_id.map(ToOwned::to_owned),
        selected_thread_title,
        selected_tokens_per_second: 0.0,
        tokens_per_second: 0.0,
        total_tokens_today: summary.today_tokens,
        requests_today: summary.today_requests,
        max_tokens_per_second: MAX_TOKENS_PER_SECOND,
        precise_enabled: false,
        warnings,
    }
}

fn read_snapshot_result(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
) -> Result<LiveRateSnapshot> {
    let mut warnings = Vec::new();
    let now = current_time_seconds();
    let logs_connection = open_read_only(&codex_home.join("logs_2.sqlite"))?;

    let rows = read_recent_log_rows(&logs_connection, now - LOOKBACK_SECONDS)?;
    let rollup = rollup_stream_rows(&rows, now, None);
    let selected_rollup = selected_thread_id
        .map(|thread_id| rollup_stream_rows(&rows, now, Some(thread_id)))
        .unwrap_or_else(|| LiveRateRollup {
            tokens_per_second: 0.0,
            latest_thread_id: None,
        });
    let summary = read_usage_summary_or_default(codex_home, &mut warnings);
    let thread_title = rollup
        .latest_thread_id
        .as_deref()
        .and_then(|thread_id| read_thread_title_or_warn(codex_home, thread_id, &mut warnings))
        .unwrap_or_else(|| "等待任意会话输出".into());
    let selected_thread_title = selected_thread_id
        .and_then(|thread_id| read_thread_title_or_warn(codex_home, thread_id, &mut warnings))
        .unwrap_or_else(|| "选择会话查看单会话速率".into());

    Ok(LiveRateSnapshot {
        scope_label: "全会话".into(),
        thread_title,
        selected_thread_id: selected_thread_id.map(ToOwned::to_owned),
        selected_thread_title,
        selected_tokens_per_second: selected_rollup.tokens_per_second,
        tokens_per_second: rollup.tokens_per_second,
        total_tokens_today: summary.today_tokens,
        requests_today: summary.today_requests,
        max_tokens_per_second: MAX_TOKENS_PER_SECOND,
        precise_enabled: false,
        warnings,
    })
}

fn floating_from_live(codex_home: &Path, live: &LiveRateSnapshot) -> FloatingPanelSnapshot {
    let mut warnings = Vec::new();
    let summary = read_usage_summary_or_default(codex_home, &mut warnings);
    let unread_summary = unread::read_unread_summary(codex_home);
    FloatingPanelSnapshot {
        tokens_per_second: live.tokens_per_second,
        trend_label: if live.tokens_per_second > 0.05 {
            "输出中".into()
        } else {
            "待输出".into()
        },
        total_tokens_label: format!("总 {}", compact_tokens(summary.total_tokens)),
        today_tokens_label: format!("今 {}", compact_tokens(live.total_tokens_today)),
        requests_label: format!("次 {}", live.requests_today),
        five_hour_label: "5h 待读取".into(),
        seven_day_label: "7d 待读取".into(),
        unread: unread_summary.active,
        unread_summary,
    }
}

fn live_rate_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "live_rate_stream".into(),
        message,
    }
}

fn live_rate_summary_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "live_rate_summary".into(),
        message,
    }
}

fn live_rate_thread_title_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "live_rate_thread_title".into(),
        message,
    }
}

fn read_usage_summary_or_default(
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> UsageSummary {
    match read_usage_summary(codex_home) {
        Ok(summary) => summary,
        Err(error) => {
            warnings.push(live_rate_summary_warning(format!(
                "读取实时速率汇总失败：{}（{}）",
                codex_home.join("state_5.sqlite").display(),
                error
            )));
            UsageSummary::default()
        }
    }
}

fn read_thread_title_or_warn(
    codex_home: &Path,
    thread_id: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> Option<String> {
    match read_thread_title(codex_home, thread_id) {
        Ok(title) => title,
        Err(error) => {
            warnings.push(live_rate_thread_title_warning(format!(
                "读取实时速率会话标题失败：{}（{}）",
                thread_id,
                error
            )));
            None
        }
    }
}

fn read_recent_log_rows(connection: &Connection, since: f64) -> Result<Vec<LogRow>> {
    let since_seconds = since.floor() as i64;
    let index_hint = if logs_ts_index_exists(connection) {
        " INDEXED BY idx_logs_ts"
    } else {
        ""
    };
    let sql = format!(
        r#"
        SELECT id, thread_id, ts, ts_nanos, target, COALESCE(feedback_log_body, '')
        FROM (
          SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
          FROM logs{index_hint}
          WHERE ts >= ?1
          ORDER BY ts DESC, ts_nanos DESC, id DESC
          LIMIT 5000
        ) recent
        WHERE
          (
            target = 'codex_api::sse::responses'
            AND (
              feedback_log_body LIKE 'SSE event:%'
              OR feedback_log_body LIKE '%thread.id=%'
              OR feedback_log_body LIKE '%thread_id=%'
              OR feedback_log_body LIKE '%conversation.id=%'
            )
          )
          OR (
            target = 'codex_api::endpoint::responses_websocket'
            AND feedback_log_body LIKE '%websocket event:%'
          )
        ORDER BY id ASC
        LIMIT 2000;
        "#,
    );
    let mut statement = connection.prepare(&sql)?;

    let rows = statement.query_map(params![since_seconds], |row| {
        Ok(LogRow {
            id: row.get(0)?,
            thread_id: row.get(1)?,
            ts: row.get(2)?,
            ts_nanos: row.get(3)?,
            target: row.get(4)?,
            feedback_log_body: row.get(5)?,
        })
    })?;

    rows.collect()
}

fn logs_ts_index_exists(connection: &Connection) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_logs_ts' LIMIT 1;",
            [],
            |_| Ok(()),
        )
        .is_ok()
}

fn read_usage_summary(codex_home: &Path) -> Result<UsageSummary> {
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

fn read_thread_options_result(codex_home: &Path, limit: usize) -> Result<Vec<LiveThreadOption>> {
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

fn read_thread_title(codex_home: &Path, thread_id: &str) -> Result<Option<String>> {
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

fn current_time_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0)
}

fn compact_tokens(value: u64) -> String {
    if value >= 100_000_000 {
        format!("{:.1}亿", value as f64 / 100_000_000.0)
    } else if value >= 10_000 {
        format!("{:.1}万", value as f64 / 10_000.0)
    } else {
        value.to_string()
    }
}

#[derive(Default)]
struct UsageSummary {
    total_tokens: u64,
    today_tokens: u64,
    today_requests: u32,
}

#[cfg(test)]
#[path = "live_rate_tests.rs"]
mod live_rate_tests;
