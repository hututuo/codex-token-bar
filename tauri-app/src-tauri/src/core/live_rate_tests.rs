use super::*;
use rusqlite::{params, Connection};
use std::fs;
use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

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
fn floating_snapshot_uses_precise_token_summary_when_available() {
    let root = temp_root("live-rate-precise-summary");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 9_999_999);
    create_logs_database(&root, |_connection, _now| {});
    write_token_session(&root, 1_000, 40);

    let snapshot = read_snapshot(&root, None);
    assert_eq!(snapshot.total_tokens_today, 40);
    assert_eq!(snapshot.requests_today, 1);

    let floating = read_floating_snapshot_from_live(&root, &snapshot);
    assert_eq!(floating.total_tokens_label, "总 1040");
    assert_eq!(floating.today_tokens_label, "今 40");
    assert_eq!(floating.requests_label, "次 1");

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

#[test]
fn monitor_reuses_snapshot_until_logs_change() {
    let root = temp_root("live-rate-monitor-cache");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "共享监控会话", 300);
    create_logs_database(&root, |connection, now| {
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":"first stream text","item_id":"item-a","sequence_number":1}"#,
        );
    });

    let monitor = LiveRateMonitorService::new(root.clone());
    let first = monitor.snapshot(None);
    let refreshes_after_first = monitor.test_refresh_count();
    let second = monitor.snapshot(None);

    assert_eq!(monitor.test_refresh_count(), refreshes_after_first);
    assert_eq!(second.tokens_per_second, first.tokens_per_second);

    {
        let connection = Connection::open(root.join("logs_2.sqlite")).unwrap();
        insert_log(
            &connection,
            2,
            "thread-a",
            current_time_seconds().floor() as i64,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":"new stream text after change","item_id":"item-a","sequence_number":2}"#,
        );
    }

    let _changed = monitor.snapshot(None);
    assert_eq!(monitor.test_refresh_count(), refreshes_after_first + 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_falls_back_to_rollout_assistant_message_when_logs_have_no_new_rows() {
    let root = temp_root("live-rate-rollout-fallback");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "rollout 实时会话", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let idle = read_snapshot(&root, None);
    assert_eq!(idle.tokens_per_second, 0.0);

    append_rollout_line(
        &rollout_path,
        "response_item",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"rollout fallback visible output keeps moving"}]}"#,
    );

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);
    assert_eq!(snapshot.thread_title, "rollout 实时会话");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_ignores_agent_message_duplicate_and_distributes_assistant_message() {
    let root = temp_root("live-rate-rollout-duplicate-message");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "rollout 去重会话", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    let long_text = "assistant completion payload ".repeat(1200);
    append_rollout_line(
        &rollout_path,
        "event_msg",
        &format!(r#"{{"type":"agent_message","message":"{long_text}"}}"#),
    );
    append_rollout_line(
        &rollout_path,
        "response_item",
        &format!(
            r#"{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{long_text}"}}]}}"#
        ),
    );

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);
    assert!(
        snapshot.tokens_per_second < 1_000.0,
        "assistant completion payload should be distributed, got {} tok/s",
        snapshot.tokens_per_second
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_excludes_large_rollout_tool_output_from_live_rate() {
    let root = temp_root("live-rate-rollout-tool-output");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "rollout 工具输出会话", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    let large_output = "x".repeat(40_000);
    append_rollout_line(
        &rollout_path,
        "response_item",
        &format!(r#"{{"type":"function_call_output","call_id":"call-a","output":"{large_output}"}}"#),
    );
    let now = current_time_seconds();
    let metrics = rollout::read_rollout_metrics(&root, now);
    let rollup = stream::rollup_metric_events(&metrics, now, None);
    assert!(rollup.breakdown.tool_output > 0);
    assert_eq!(rollup.tokens_per_second, 0.0);

    append_rollout_line(
        &rollout_path,
        "response_item",
        r#"{"type":"function_call","call_id":"call-b","name":"shell","arguments":"model generated tool arguments"}"#,
    );
    let tool_arguments = read_snapshot(&root, None);
    assert!(tool_arguments.tokens_per_second > 0.0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_prefers_sqlite_stream_rows_without_double_counting_rollout() {
    let root = temp_root("live-rate-rollout-priority");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "sqlite 优先会话", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();
    let sqlite_text = "sqlite stream output should be counted once";
    create_logs_database(&root, |connection, now| {
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "codex_api::endpoint::responses_websocket",
            &format!(
                r#"websocket event: {{"type":"response.output_text.delta","delta":"{sqlite_text}","item_id":"item-a","sequence_number":1}}"#
            ),
        );
    });
    append_rollout_line(
        &rollout_path,
        "response_item",
        &format!(
            r#"{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{sqlite_text}"}}]}}"#
        ),
    );

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);
    assert!(snapshot.tokens_per_second < 25.0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_aggregates_multiple_rollout_paths() {
    let root = temp_root("live-rate-rollout-multiple");
    fs::create_dir_all(&root).unwrap();
    let rollout_a = root.join("sessions/rollout-thread-a.jsonl");
    let rollout_b = root.join("sessions/rollout-thread-b.jsonl");
    create_state_database(&root, "thread-a", "rollout A", 300);
    insert_state_thread(&root, "thread-b", "rollout B", 200);
    set_thread_rollout_path(&root, "thread-a", &rollout_a);
    set_thread_rollout_path(&root, "thread-b", &rollout_b);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_a.parent().unwrap()).unwrap();
    fs::File::create(&rollout_a).unwrap();
    fs::File::create(&rollout_b).unwrap();

    let _ = read_snapshot(&root, None);
    append_rollout_line(
        &rollout_a,
        "response_item",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first rollout message"}]}"#,
    );
    append_rollout_line(
        &rollout_b,
        "response_item",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second rollout message with more text"}]}"#,
    );

    let snapshot = read_snapshot(&root, Some("thread-a"));
    assert!(snapshot.tokens_per_second > snapshot.selected_tokens_per_second);
    assert!(snapshot.selected_tokens_per_second > 0.0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_handles_missing_or_truncated_rollout_files() {
    let root = temp_root("live-rate-rollout-missing");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "rollout 缺失会话", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});

    let missing = read_snapshot(&root, None);
    assert_eq!(missing.tokens_per_second, 0.0);

    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::write(&rollout_path, "partial line without newline").unwrap();
    let partial = read_snapshot(&root, None);
    assert_eq!(partial.tokens_per_second, 0.0);

    fs::write(&rollout_path, "").unwrap();
    let truncated = read_snapshot(&root, None);
    assert_eq!(truncated.tokens_per_second, 0.0);

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
                rollout_path TEXT,
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

fn set_thread_rollout_path(root: &Path, thread_id: &str, rollout_path: &Path) {
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    connection
        .execute(
            "UPDATE threads SET rollout_path = ?1 WHERE id = ?2;",
            params![rollout_path.to_string_lossy(), thread_id],
        )
        .unwrap();
}

fn append_rollout_line(path: &Path, record_type: &str, payload_json: &str) {
    let mut output = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    writeln!(
        output,
        r#"{{"timestamp":"{timestamp}","type":"{record_type}","payload":{payload_json}}}"#
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

fn write_token_session(root: &Path, yesterday_tokens: u64, today_tokens: u64) {
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let now = OffsetDateTime::now_utc();
    let yesterday = now - time::Duration::days(1);
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    let mut output = fs::File::create(file).unwrap();
    writeln!(
        output,
        r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":{yesterday_tokens}}}}}}}}}"#,
        yesterday.format(&Rfc3339).unwrap()
    )
    .unwrap();
    writeln!(
        output,
        r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":{today_tokens}}}}}}}}}"#,
        now.format(&Rfc3339).unwrap()
    )
    .unwrap();
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
