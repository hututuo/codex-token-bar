use super::*;
use rusqlite::{params, Connection};
use std::fs;
use std::io::Write;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
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
    assert_eq!(snapshot.total_tokens_today, 0);
    assert_eq!(snapshot.requests_today, 0);

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
fn sqlite_tool_argument_deltas_are_distributed_to_avoid_fake_spikes() {
    let root = temp_root("live-rate-sqlite-tool-args-distributed");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "工具输入摊分", 300);
    let large_arguments = "x".repeat(900);
    create_logs_database(&root, |connection, now| {
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "codex_api::sse::responses",
            &format!(
                r#"SSE event: {{"type":"response.function_call_arguments.delta","delta":"{large_arguments}","item_id":"call-a","sequence_number":1,"item":{{"id":"call-a","name":"shell"}}}}"#
            ),
        );
    });

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);
    assert!(
        snapshot.tokens_per_second < 90.0,
        "tool input should be conservatively distributed, got {} tok/s",
        snapshot.tokens_per_second
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_counts_received_message_log_stream_delta() {
    let root = temp_root("live-rate-log-target-received-message");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "log target 会话", 300);
    create_logs_database(&root, |connection, now| {
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "log",
            r#"Received message {"type":"response.output_text.delta","delta":"new codex log target visible stream","item_id":"item-a","sequence_number":1}"#,
        );
    });

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);
    assert_eq!(snapshot.thread_title, "log target 会话");

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
    assert_eq!(snapshot.total_tokens_today, 0);
    assert!(snapshot
        .warnings
        .iter()
        .any(|warning| warning.source == "live_rate_stream"));
    assert!(snapshot
        .warnings
        .iter()
        .any(|warning| warning.source == "live_rate_summary"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_uses_safe_shell_before_precise_cache_exists() {
    let root = temp_root("live-rate-precise-summary");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 9_999_999);
    create_logs_database(&root, |_connection, _now| {});
    write_token_session(&root, 1_000, 40);

    let snapshot = read_snapshot(&root, None);
    assert_eq!(snapshot.total_tokens_today, 0);
    assert_eq!(snapshot.requests_today, 0);
    assert!(snapshot
        .warnings
        .iter()
        .any(|warning| warning.source == "live_rate_summary"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn read_snapshot_backgrounds_precise_summary_after_safe_shell() {
    let root = temp_root("live-rate-background-precise-summary");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 9_999_999);
    create_logs_database(&root, |_connection, _now| {});
    write_token_session(&root, 1_000, 40);

    let first = read_snapshot(&root, None);
    assert_eq!(first.total_tokens_today, 0);

    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(20));
        let snapshot = read_snapshot(&root, None);
        if snapshot.total_tokens_today == 40 {
            assert_eq!(snapshot.requests_today, 1);
            assert_eq!(snapshot.total_tokens, 1_040);
            fs::remove_dir_all(root).unwrap();
            return;
        }
        assert_ne!(snapshot.total_tokens_today, 9_999_999);
    }

    panic!("background precise summary did not become available");
}

#[test]
fn state_token_summary_is_not_used_for_live_totals() {
    let root = temp_root("live-rate-fallback-state-signature");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 10);
    create_logs_database(&root, |_connection, _now| {});

    let first = read_snapshot(&root, None);
    assert_eq!(first.total_tokens_today, 0);

    {
        let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
        connection
            .execute(
                "UPDATE threads SET tokens_used = ?1, updated_at = CAST(strftime('%s', 'now') AS INTEGER) + 1 WHERE id = ?2;",
                params![20, "thread-a"],
            )
            .unwrap();
    }

    let second = read_snapshot(&root, None);
    assert_eq!(second.total_tokens_today, 0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn floating_snapshot_uses_precise_token_summary_when_cached() {
    let root = temp_root("live-rate-cached-precise-summary");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 9_999_999);
    create_logs_database(&root, |_connection, _now| {});
    write_token_session(&root, 1_000, 40);
    crate::core::usage::token_count_jsonl::dashboard_snapshot(&root).unwrap();

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
fn floating_snapshot_rejects_stale_precise_summary_after_session_changes() {
    let root = temp_root("live-rate-stale-precise-summary");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 9_999_999);
    create_logs_database(&root, |_connection, _now| {});
    write_token_session(&root, 1_000, 40);
    crate::core::usage::token_count_jsonl::dashboard_snapshot(&root).unwrap();

    let cached = read_snapshot(&root, None);
    assert_eq!(cached.total_tokens_today, 40);

    append_token_count_to_first_session(&root, 80);
    let changed = read_snapshot(&root, None);
    assert_eq!(
        changed.total_tokens_today, 40,
        "stale precise cache should keep the last safe precise summary instead of falling back to duplicated state summary"
    );

    let floating = read_floating_snapshot_from_live(&root, &changed);
    assert_eq!(floating.total_tokens_label, "总 待读取");
    assert_eq!(floating.today_tokens_label, "今 待读取");
    assert_eq!(floating.requests_label, "次 待读取");

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
fn monitor_keeps_fast_refresh_window_after_recent_activity() {
    let root = temp_root("live-rate-monitor-active-window");
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
    assert!(first.tokens_per_second > 0.0);
    let refreshes_after_first = monitor.test_refresh_count();

    std::thread::sleep(Duration::from_millis(300));
    let _second = monitor.snapshot(None);
    assert_eq!(
        monitor.test_refresh_count(),
        refreshes_after_first + 1,
        "recent activity should keep the monitor on the fast 250ms cadence"
    );

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
    let signatures_after_first = monitor.test_signature_count();
    let second = monitor.snapshot(None);

    assert_eq!(monitor.test_refresh_count(), refreshes_after_first);
    assert_eq!(monitor.test_signature_count(), signatures_after_first);
    assert_eq!(second.tokens_per_second, first.tokens_per_second);

    let floating = monitor.floating_snapshot();
    assert_eq!(monitor.test_refresh_count(), refreshes_after_first);
    assert_eq!(monitor.test_signature_count(), signatures_after_first);
    assert!((floating.tokens_per_second - first.tokens_per_second).abs() < 0.001);

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

    std::thread::sleep(Duration::from_millis(280));
    let _changed = monitor.snapshot(None);
    assert_eq!(monitor.test_refresh_count(), refreshes_after_first + 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn monitor_reset_invalidates_cached_snapshot_immediately() {
    let root = temp_root("live-rate-monitor-reset");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "可重置会话", 300);
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
    let _first = monitor.snapshot(None);
    let refreshes_after_first = monitor.test_refresh_count();
    let signatures_after_first = monitor.test_signature_count();

    {
        let connection = Connection::open(root.join("logs_2.sqlite")).unwrap();
        insert_log(
            &connection,
            2,
            "thread-a",
            current_time_seconds().floor() as i64,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":"new stream text after reset","item_id":"item-a","sequence_number":2}"#,
        );
    }

    monitor.reset();
    let _after_reset = monitor.snapshot(None);
    assert_eq!(monitor.test_refresh_count(), refreshes_after_first + 1);
    assert_eq!(monitor.test_signature_count(), signatures_after_first + 1);

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
fn read_snapshot_counts_agent_message_but_deduplicates_response_item_copy() {
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
fn read_snapshot_counts_rollout_agent_message_when_response_item_is_missing() {
    let root = temp_root("live-rate-rollout-agent-message");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "rollout agent 会话", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    append_rollout_line(
        &rollout_path,
        "event_msg",
        r#"{"type":"agent_message","message":"rollout agent message visible output"}"#,
    );

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);
    assert_eq!(snapshot.thread_title, "rollout agent 会话");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn rollout_token_count_reasoning_does_not_drive_live_rate() {
    let root = temp_root("live-rate-rollout-reasoning-not-live");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "rollout reasoning 会话", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    append_rollout_line(
        &rollout_path,
        "event_msg",
        r#"{"type":"token_count","info":{"last_token_usage":{"reasoning_output_tokens":10000}}}"#,
    );

    let now = current_time_seconds();
    let metrics = rollout::read_rollout_metrics(&root, now);
    let rollup = stream::rollup_metric_events(&metrics, now, None);
    assert!(rollup.breakdown.reasoning > 0);
    assert_eq!(rollup.tokens_per_second, 0.0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn live_rate_display_cap_is_applied_per_session_before_global_sum() {
    let now = current_time_seconds();
    let metrics = vec![
        exact_visible_metric("thread-a", "item-a", now, 100),
        exact_visible_metric("thread-b", "item-b", now, 100),
    ];

    let all = stream::rollup_metric_events(&metrics, now, None);
    let selected = stream::rollup_metric_events(&metrics, now, Some("thread-a"));

    assert_eq!(all.tokens_per_second, 160.0);
    assert_eq!(selected.tokens_per_second, 80.0);
}

#[test]
fn live_rate_unknown_events_are_not_forced_into_one_global_cap_bucket() {
    let now = current_time_seconds();
    let metrics = vec![
        exact_visible_metric_without_thread("item-a", now, 100),
        exact_visible_metric_without_thread("item-b", now, 100),
    ];

    let all = stream::rollup_metric_events(&metrics, now, None);

    assert_eq!(all.tokens_per_second, 160.0);
}

#[test]
fn live_rate_same_thread_still_caps_multiple_items_to_one_session() {
    let now = current_time_seconds();
    let metrics = vec![
        exact_visible_metric("thread-a", "item-a", now, 100),
        exact_visible_metric("thread-a", "item-b", now, 100),
    ];

    let all = stream::rollup_metric_events(&metrics, now, None);

    assert_eq!(all.tokens_per_second, 80.0);
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
fn read_snapshot_counts_subagent_active_rollout_path() {
    let root = temp_root("live-rate-subagent-rollout");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-subagent.jsonl");
    create_state_database(&root, "thread-subagent", "subagent rollout", 300);
    mark_thread_source(&root, "thread-subagent", "subagent");
    set_thread_rollout_path(&root, "thread-subagent", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    append_rollout_line(
        &rollout_path,
        "response_item",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"subagent active rollout should count as real work"}]}"#,
    );

    let snapshot = read_snapshot(&root, None);
    assert!(snapshot.tokens_per_second > 0.0);

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

#[test]
fn unread_acknowledgement_invalidates_live_rate_unread_cache() {
    let root = temp_root("unread-ack-cache");
    let support = root.join("tauri-support");
    fs::create_dir_all(&root).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let thread_id = "019eaaaa-0000-0000-0000-000000000099";
    write_unread_state(&root, &[thread_id]);

    let before = read_snapshot(&root, None);
    assert!(before.unread_summary.active);

    unread::acknowledge_current_unread(&root).unwrap();
    let after = read_snapshot(&root, None);
    assert!(!after.unread_summary.active);

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

struct TauriSupportEnvGuard;

impl TauriSupportEnvGuard {
    fn new(path: &Path) -> Self {
        std::env::set_var("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", path);
        Self
    }
}

impl Drop for TauriSupportEnvGuard {
    fn drop(&mut self) {
        std::env::remove_var("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR");
    }
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

fn mark_thread_source(root: &Path, thread_id: &str, thread_source: &str) {
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    connection
        .execute("ALTER TABLE threads ADD COLUMN thread_source TEXT DEFAULT 'user';", [])
        .unwrap();
    connection
        .execute(
            "UPDATE threads SET thread_source = ?1 WHERE id = ?2;",
            params![thread_source, thread_id],
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

fn append_token_count_to_first_session(root: &Path, today_tokens: u64) {
    let file = fs::read_dir(root.join("sessions"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let now = OffsetDateTime::now_utc();
    let mut output = fs::OpenOptions::new().append(true).open(file).unwrap();
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

fn exact_visible_metric(
    thread_id: &str,
    item_id: &str,
    timestamp: f64,
    tokens: u32,
) -> stream::LiveMetricEvent {
    stream::LiveMetricEvent {
        event_type: "test.visible".into(),
        timestamp,
        thread_id: Some(thread_id.into()),
        item_id: item_id.into(),
        sequence_number: Some(i64::from(tokens)),
        category: stream::LiveTokenCategory::VisibleText,
        delta: String::new(),
        exact_tokens: Some(tokens),
        start_timestamp: None,
        distributed: false,
        dedupe_key: None,
    }
}

fn exact_visible_metric_without_thread(
    item_id: &str,
    timestamp: f64,
    tokens: u32,
) -> stream::LiveMetricEvent {
    stream::LiveMetricEvent {
        event_type: "test.visible".into(),
        timestamp,
        thread_id: None,
        item_id: item_id.into(),
        sequence_number: Some(i64::from(tokens)),
        category: stream::LiveTokenCategory::VisibleText,
        delta: String::new(),
        exact_tokens: Some(tokens),
        start_timestamp: None,
        distributed: false,
        dedupe_key: None,
    }
}
