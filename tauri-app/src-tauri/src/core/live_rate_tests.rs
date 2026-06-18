use super::*;
use rusqlite::Connection;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn read_snapshot_counts_recent_stream_deltas() {
    let root = temp_root("live-rate-counts");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "实时测速测试", 300);
    create_logs_database(&root, |connection, now| {
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":"hello world from stream","item_id":"item-a","sequence_number":1}"#,
        );
        insert_log(
            connection,
            2,
            "thread-a",
            now,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":" with more text","item_id":"item-a","sequence_number":2}"#,
        );
    });

    let snapshot = read_snapshot(&root);
    assert!(snapshot.tokens_per_second > 0.0);
    assert_eq!(snapshot.thread_title, "实时测速测试");
    assert_eq!(snapshot.total_tokens_today, 300);
    assert_eq!(snapshot.requests_today, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_deduplicates_sse_and_websocket_sequence_events() {
    let root = temp_root("live-rate-dedup");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "重复流去重", 120);
    create_logs_database(&root, |connection, now| {
        let payload = r#"{"type":"response.output_text.delta","delta":"duplicated stream text","item_id":"item-a","sequence_number":1}"#;
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "codex_api::sse::responses",
            &format!("SSE event: {payload}"),
        );
        insert_log(
            connection,
            2,
            "thread-a",
            now,
            "codex_api::endpoint::responses_websocket",
            &format!("websocket event: {payload}"),
        );
    });

    let snapshot = read_snapshot(&root);
    assert!(snapshot.tokens_per_second > 0.0);
    assert!(snapshot.tokens_per_second < 20.0);

    fs::remove_dir_all(root).unwrap();
}

fn temp_root(label: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "codex-token-bar-tauri-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn create_state_database(root: &Path, thread_id: &str, title: &str, tokens: i64) {
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                first_user_message TEXT NOT NULL DEFAULT '',
                preview TEXT NOT NULL DEFAULT '',
                updated_at INTEGER NOT NULL,
                updated_at_ms INTEGER,
                tokens_used INTEGER NOT NULL DEFAULT 0
            );
            "#,
        )
        .unwrap();
    connection
        .execute(
            r#"
            INSERT INTO threads (id, title, updated_at, updated_at_ms, tokens_used)
            VALUES (?1, ?2, CAST(strftime('%s', 'now') AS INTEGER), CAST(strftime('%s', 'now') AS INTEGER) * 1000, ?3);
            "#,
            params![thread_id, title, tokens],
        )
        .unwrap();
}

fn create_logs_database<F>(root: &Path, write_rows: F)
where
    F: FnOnce(&Connection, i64),
{
    let connection = Connection::open(root.join("logs_2.sqlite")).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                ts_nanos INTEGER NOT NULL,
                level TEXT NOT NULL,
                target TEXT NOT NULL,
                feedback_log_body TEXT,
                module_path TEXT,
                file TEXT,
                line INTEGER,
                thread_id TEXT,
                process_uuid TEXT,
                estimated_bytes INTEGER NOT NULL DEFAULT 0
            );
            "#,
        )
        .unwrap();
    let now = current_time_seconds().floor() as i64;
    write_rows(&connection, now);
}

fn insert_log(
    connection: &Connection,
    id: i64,
    thread_id: &str,
    ts: i64,
    target: &str,
    feedback_log_body: &str,
) {
    connection
        .execute(
            r#"
            INSERT INTO logs (id, ts, ts_nanos, level, target, feedback_log_body, thread_id)
            VALUES (?1, ?2, 0, 'INFO', ?3, ?4, ?5);
            "#,
            params![id, ts, target, feedback_log_body, thread_id],
        )
        .unwrap();
}
