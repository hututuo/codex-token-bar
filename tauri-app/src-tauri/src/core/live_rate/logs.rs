use super::stream::LogRow;
use rusqlite::{params, Connection, Result};
use std::path::Path;
use std::time::Duration;

pub(super) fn read_recent_log_rows(codex_home: &Path, since: f64) -> Result<Vec<LogRow>> {
    let connection = open_read_only(&codex_home.join("logs_2.sqlite"))?;
    read_recent_log_rows_from_connection(&connection, since)
}

fn read_recent_log_rows_from_connection(connection: &Connection, since: f64) -> Result<Vec<LogRow>> {
    let since_seconds = since.floor() as i64;
    let index_hint = if logs_ts_index_exists(connection) {
        " INDEXED BY idx_logs_ts"
    } else {
        ""
    };
    let sql = format!(
        r#"
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM (
          SELECT id, thread_id, ts, ts_nanos, target, COALESCE(feedback_log_body, '') AS feedback_log_body
          FROM logs{index_hint}
          WHERE ts >= ?1
            AND (
              (
                target = 'codex_api::sse::responses'
                AND feedback_log_body LIKE 'SSE event:%'
              )
              OR (
                target = 'codex_api::endpoint::responses_websocket'
                AND feedback_log_body LIKE '%websocket event:%'
              )
              OR (
                target = 'log'
                AND feedback_log_body LIKE 'Received message %'
              )
            )
            AND (
              feedback_log_body LIKE '%"type":"response.output_text.delta"%'
              OR feedback_log_body LIKE '%"type":"response.function_call_arguments.delta"%'
              OR feedback_log_body LIKE '%"type":"response.custom_tool_call_input.delta"%'
            )
          ORDER BY id DESC
          LIMIT 2000
        ) recent_useful
        ORDER BY id ASC;
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

fn open_read_only(path: &Path) -> Result<Connection> {
    crate::core::sqlite::open_read_only(path, Duration::from_millis(100))
}
