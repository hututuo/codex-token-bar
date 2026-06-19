use super::*;
use rusqlite::{params, Connection};
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

    let snapshot = read_snapshot(&root, None);
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

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);
    assert!(snapshot.tokens_per_second < 20.0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_includes_selected_thread_rate() {
    let root = temp_root("live-rate-selected-thread");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "被选中的会话", 300);
    insert_state_thread(&root, "thread-b", "另一个会话", 200);
    create_logs_database(&root, |connection, now| {
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":"selected thread stream text","item_id":"item-a","sequence_number":1}"#,
        );
        insert_log(
            connection,
            2,
            "thread-b",
            now,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":"other thread has much more stream text than selected one","item_id":"item-b","sequence_number":1}"#,
        );
    });

    let all_snapshot = read_snapshot(&root, None);
    let selected_snapshot = read_snapshot(&root, Some("thread-a"));
    assert!(all_snapshot.tokens_per_second > selected_snapshot.selected_tokens_per_second);
    assert!(selected_snapshot.selected_tokens_per_second > 0.0);
    assert_eq!(selected_snapshot.selected_thread_id.as_deref(), Some("thread-a"));
    assert_eq!(selected_snapshot.selected_thread_title, "被选中的会话");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_keeps_idle_state_with_warning_when_logs_database_is_missing() {
    let root = temp_root("live-rate-missing-logs");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "缺少实时日志", 300);

    let snapshot = read_snapshot(&root, None);

    assert_eq!(snapshot.tokens_per_second, 0.0);
    assert_eq!(snapshot.total_tokens_today, 300);
    assert!(snapshot
        .warnings
        .iter()
        .any(|warning| warning.source == "live_rate_stream"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_thread_options_works_with_minimal_thread_schema() {
    let root = temp_root("live-thread-options");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "最近会话", 300);
    insert_state_thread(&root, "thread-b", "稍早会话", 200);

    let options = try_read_thread_options(&root).unwrap();
    assert_eq!(options.len(), 2);
    assert_eq!(options[0].title, "最近会话");
    assert_eq!(options[0].tokens_used, 300);

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

fn insert_state_thread(root: &Path, thread_id: &str, title: &str, tokens: i64) {
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
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
