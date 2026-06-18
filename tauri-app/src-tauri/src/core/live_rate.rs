use crate::core::unread;
use crate::core::sqlite;
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption};
use rusqlite::{params, Connection, Result};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const LOOKBACK_SECONDS: f64 = 8.0;
const WINDOW_SECONDS: f64 = 2.5;
const MINIMUM_RATE_SPAN_SECONDS: f64 = 0.4;
const MAX_TOKENS_PER_SECOND: f64 = 200.0;

pub fn read_snapshot(codex_home: &Path, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
    read_snapshot_result(codex_home, selected_thread_id)
        .unwrap_or_else(|_| idle_snapshot(codex_home, selected_thread_id))
}

pub fn read_floating_snapshot(codex_home: &Path) -> FloatingPanelSnapshot {
    let live = read_snapshot(codex_home, None);
    floating_from_live(codex_home, &live)
}

pub fn read_thread_options(codex_home: &Path) -> Vec<LiveThreadOption> {
    read_thread_options_result(codex_home, 18).unwrap_or_default()
}

pub fn idle_snapshot(codex_home: &Path, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
    let summary = read_usage_summary(codex_home).unwrap_or_default();
    let selected_thread_title = selected_thread_id
        .and_then(|thread_id| read_thread_title(codex_home, thread_id).ok().flatten())
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
    }
}

fn read_snapshot_result(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
) -> Result<LiveRateSnapshot> {
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
    let summary = read_usage_summary(codex_home).unwrap_or_default();
    let thread_title = rollup
        .latest_thread_id
        .as_deref()
        .and_then(|thread_id| read_thread_title(codex_home, thread_id).ok().flatten())
        .unwrap_or_else(|| "等待任意会话输出".into());
    let selected_thread_title = selected_thread_id
        .and_then(|thread_id| read_thread_title(codex_home, thread_id).ok().flatten())
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
    })
}

fn floating_from_live(codex_home: &Path, live: &LiveRateSnapshot) -> FloatingPanelSnapshot {
    let summary = read_usage_summary(codex_home).unwrap_or_default();
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
        unread: unread::has_unread_threads(codex_home),
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

fn rollup_stream_rows(
    rows: &[LogRow],
    now: f64,
    selected_thread_id: Option<&str>,
) -> LiveRateRollup {
    let mut seen = HashSet::<String>::new();
    let mut text_by_key = HashMap::<String, String>::new();
    let mut tokens_by_key = HashMap::<String, u32>::new();
    let mut rolling_deltas = Vec::<(f64, u32)>::new();
    let mut latest_thread_id = None;
    let window_start = now - WINDOW_SECONDS;

    for row in rows {
        let Some(event) = stream_event(row) else {
            continue;
        };
        let Some(metric) = metric_event(event, row) else {
            continue;
        };
        if let Some(selected_thread_id) = selected_thread_id {
            if metric.thread_id.as_deref() != Some(selected_thread_id) {
                continue;
            }
        }
        let fingerprint = metric.fingerprint(row);
        if !seen.insert(fingerprint) {
            continue;
        }

        let key = format!(
            "{}:{}:{}",
            metric.thread_id.as_deref().unwrap_or(""),
            metric.item_id,
            metric.category.key()
        );
        let text = text_by_key.entry(key.clone()).or_default();
        text.push_str(&metric.delta);

        let previous_tokens = *tokens_by_key.get(&key).unwrap_or(&0);
        let next_tokens = estimate_token_count(text, metric.category);
        tokens_by_key.insert(key, next_tokens);

        let delta_tokens = next_tokens.saturating_sub(previous_tokens);
        if delta_tokens > 0 && metric.timestamp >= window_start && metric.timestamp <= now + 0.25 {
            rolling_deltas.push((metric.timestamp, delta_tokens));
            if let Some(thread_id) = metric.thread_id {
                latest_thread_id = Some(thread_id);
            }
        }
    }

    let tokens_per_second = rolling_rate(&rolling_deltas, now);
    LiveRateRollup {
        tokens_per_second,
        latest_thread_id: if tokens_per_second > 0.0 {
            latest_thread_id
        } else {
            None
        },
    }
}

fn stream_event(row: &LogRow) -> Option<ResponseStreamEvent> {
    let marker = match row.target.as_str() {
        "codex_api::sse::responses" => "SSE event: ",
        "codex_api::endpoint::responses_websocket" => "websocket event: ",
        _ => return None,
    };
    let (_, json_text) = row.feedback_log_body.split_once(marker)?;
    serde_json::from_str(json_text).ok()
}

fn metric_event(event: ResponseStreamEvent, row: &LogRow) -> Option<LiveMetricEvent> {
    let delta = event.delta?;
    if delta.is_empty() {
        return None;
    }

    let category = match event.event_type.as_str() {
        "response.output_text.delta" => LiveTokenCategory::VisibleText,
        "response.function_call_arguments.delta" | "response.custom_tool_call_input.delta" => {
            let item_name = event.item.as_ref().and_then(|item| item.name.as_deref());
            if item_name == Some("apply_patch") {
                LiveTokenCategory::PatchInput
            } else {
                LiveTokenCategory::ToolArguments
            }
        }
        _ => return None,
    };

    let item_id = event
        .item_id
        .or_else(|| event.item.as_ref().and_then(|item| item.id.clone()))
        .unwrap_or_else(|| "unknown".into());

    Some(LiveMetricEvent {
        event_type: event.event_type,
        timestamp: row.timestamp(),
        thread_id: row.thread_id.clone(),
        item_id,
        sequence_number: event.sequence_number,
        category,
        delta,
    })
}

fn rolling_rate(rolling_deltas: &[(f64, u32)], now: f64) -> f64 {
    let visible: Vec<(f64, u32)> = rolling_deltas
        .iter()
        .copied()
        .filter(|(time, _)| *time <= now && now - *time <= WINDOW_SECONDS)
        .collect();
    let Some((first_time, _)) = visible.first() else {
        return 0.0;
    };
    let span = (now - first_time)
        .min(WINDOW_SECONDS)
        .max(MINIMUM_RATE_SPAN_SECONDS);
    let tokens: u32 = visible.iter().map(|(_, tokens)| *tokens).sum();
    f64::from(tokens) / span
}

fn estimate_token_count(text: &str, category: LiveTokenCategory) -> u32 {
    let mut tokens = 0.0;
    let mut ascii_run = 0_u32;
    let ascii_divisor = if category == LiveTokenCategory::VisibleText {
        4.2
    } else {
        3.0
    };

    fn flush_ascii(tokens: &mut f64, ascii_run: &mut u32, divisor: f64) {
        if *ascii_run > 0 {
            *tokens += (f64::from(*ascii_run) / divisor).max(1.0);
            *ascii_run = 0;
        }
    }

    for character in text.chars() {
        if character.is_ascii() && !character.is_ascii_whitespace() {
            ascii_run += 1;
        } else {
            flush_ascii(&mut tokens, &mut ascii_run, ascii_divisor);
            if !character.is_whitespace() {
                tokens += non_ascii_token_weight(character, category);
            }
        }
    }
    flush_ascii(&mut tokens, &mut ascii_run, ascii_divisor);

    tokens.round() as u32
}

fn non_ascii_token_weight(character: char, category: LiveTokenCategory) -> f64 {
    if is_cjk(character) {
        return if category == LiveTokenCategory::VisibleText {
            0.58
        } else {
            0.8
        };
    }
    if !character.is_alphanumeric() {
        return if category == LiveTokenCategory::VisibleText {
            0.35
        } else {
            0.7
        };
    }
    if category == LiveTokenCategory::VisibleText {
        0.8
    } else {
        1.0
    }
}

fn is_cjk(character: char) -> bool {
    matches!(
        character as u32,
        0x3400..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2EBEF
    )
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
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC
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

#[derive(Debug)]
struct LogRow {
    id: i64,
    thread_id: Option<String>,
    ts: i64,
    ts_nanos: i64,
    target: String,
    feedback_log_body: String,
}

impl LogRow {
    fn timestamp(&self) -> f64 {
        self.ts as f64 + self.ts_nanos as f64 / 1_000_000_000.0
    }
}

#[derive(Debug, Deserialize)]
struct ResponseStreamEvent {
    #[serde(rename = "type")]
    event_type: String,
    delta: Option<String>,
    #[serde(rename = "item_id")]
    item_id: Option<String>,
    #[serde(rename = "sequence_number")]
    sequence_number: Option<i64>,
    item: Option<ResponseStreamItem>,
}

#[derive(Debug, Deserialize)]
struct ResponseStreamItem {
    id: Option<String>,
    name: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LiveTokenCategory {
    VisibleText,
    ToolArguments,
    PatchInput,
}

impl LiveTokenCategory {
    fn key(self) -> &'static str {
        match self {
            LiveTokenCategory::VisibleText => "visibleText",
            LiveTokenCategory::ToolArguments => "toolArguments",
            LiveTokenCategory::PatchInput => "patchInput",
        }
    }
}

#[derive(Debug)]
struct LiveMetricEvent {
    event_type: String,
    timestamp: f64,
    thread_id: Option<String>,
    item_id: String,
    sequence_number: Option<i64>,
    category: LiveTokenCategory,
    delta: String,
}

impl LiveMetricEvent {
    fn fingerprint(&self, row: &LogRow) -> String {
        if let Some(sequence_number) = self.sequence_number {
            format!(
                "{}:{}:{}:{}",
                self.event_type, self.item_id, sequence_number, self.delta
            )
        } else {
            format!("row:{}:{}:{}", row.id, self.event_type, self.delta)
        }
    }
}

#[derive(Default)]
struct UsageSummary {
    total_tokens: u64,
    today_tokens: u64,
    today_requests: u32,
}

struct LiveRateRollup {
    tokens_per_second: f64,
    latest_thread_id: Option<String>,
}

#[cfg(test)]
#[path = "live_rate_tests.rs"]
mod live_rate_tests;
