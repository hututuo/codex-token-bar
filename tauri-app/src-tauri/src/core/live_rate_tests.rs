use super::*;
use crate::core::unread::test_fixtures::write_initialized_sidebar_state;
use rusqlite::{params, Connection};
use std::fs;
use std::io::Write;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
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
    let _test_state = crate::core::app_paths::app_path_test_env_guard(&[]);
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
fn live_rate_ticks_leave_precise_summary_rebuild_to_usage_refresh() {
    let _test_state = crate::core::app_paths::app_path_test_env_guard(&[]);
    let root = temp_root("live-rate-background-precise-summary");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 9_999_999);
    create_logs_database(&root, |_connection, _now| {});
    write_token_session(&root, 1_000, 40);

    let first = read_snapshot(&root, None);
    assert_eq!(first.total_tokens_today, 0);
    crate::core::usage::token_count_jsonl::reset_dashboard_aggregate_build_count_for_testing();

    for _ in 0..5 {
        let snapshot = read_snapshot(&root, None);
        assert_eq!(snapshot.total_tokens_today, 0);
        assert_ne!(snapshot.total_tokens_today, 9_999_999);
    }
    assert_eq!(
        crate::core::usage::token_count_jsonl::dashboard_aggregate_build_count_for_testing(&root),
        0,
        "live-rate ticks must not start precise dashboard rebuilds"
    );
    assert_eq!(
        crate::core::usage::token_count_jsonl::dashboard_scan_signature_count_for_testing(),
        0,
        "live-rate ticks must not scan the session tree"
    );

    assert!(crate::core::usage::token_count_jsonl::usage_summary_snapshot(&root).is_err());
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(20));
        if let Ok(summary) = crate::core::usage::token_count_jsonl::usage_summary_snapshot(&root) {
            assert_eq!(summary.today_tokens, 40);
            assert_eq!(summary.today_requests, 1);
            assert_eq!(summary.total_tokens, 1_040);
            fs::remove_dir_all(root).unwrap();
            return;
        }
    }

    panic!("usage refresh did not make the precise summary available");
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
    let _test_state = crate::core::app_paths::app_path_test_env_guard(&[]);
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
fn floating_snapshot_keeps_same_scope_precise_summary_without_live_tick_rescan() {
    let _test_state = crate::core::app_paths::app_path_test_env_guard(&[]);
    let root = temp_root("live-rate-stale-precise-summary");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "旧大会话今天更新", 9_999_999);
    create_logs_database(&root, |_connection, _now| {});
    write_token_session(&root, 1_000, 40);
    crate::core::usage::token_count_jsonl::dashboard_snapshot(&root).unwrap();

    let cached = read_snapshot(&root, None);
    assert_eq!(cached.total_tokens_today, 40);

    crate::core::usage::token_count_jsonl::reset_dashboard_scan_signature_count_for_testing();
    append_token_count_to_first_session(&root, 80);
    let mut changed = read_snapshot(&root, None);
    for _ in 0..4 {
        changed = read_snapshot(&root, None);
        let _ = read_floating_snapshot_from_live(&root, &changed);
    }
    assert_eq!(
        crate::core::usage::token_count_jsonl::dashboard_scan_signature_count_for_testing(),
        0,
        "live-rate and floating reads must not rescan the session tree to validate totals"
    );
    assert_eq!(
        changed.total_tokens_today, 40,
        "stale precise cache should keep the last safe precise summary instead of falling back to duplicated state summary"
    );
    assert!(
        changed
            .warnings
            .iter()
            .all(|warning| warning.source != "live_rate_summary"),
        "same-scope stale-safe totals must not be presented as a preparation state"
    );

    let floating = read_floating_snapshot_from_live(&root, &changed);
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
fn slow_refresh_does_not_block_reset_or_publish_after_reset() {
    let root = temp_root("live-rate-monitor-reset-during-refresh");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "A", 1);
    create_logs_database(&root, |_connection, _now| {});
    let monitor = Arc::new(LiveRateMonitorService::new(root.clone()));
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let slow_monitor = Arc::clone(&monitor);
    let slow = std::thread::spawn(move || {
        slow_monitor.test_snapshot_after_claim(None, || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        })
    });
    started_rx.recv().unwrap();

    monitor.reset();
    assert_eq!(monitor.test_refresh_count(), 0);
    release_tx.send(()).unwrap();
    let _ = slow.join().unwrap();
    assert_eq!(monitor.test_refresh_count(), 0);

    let _ = monitor.snapshot(None);
    assert_eq!(monitor.test_refresh_count(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cold_concurrent_monitor_refresh_is_single_flight() {
    let root = temp_root("live-rate-monitor-cold-single-flight");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "A", 1);
    create_logs_database(&root, |_connection, _now| {});
    let monitor = Arc::new(LiveRateMonitorService::new(root.clone()));
    let claims = Arc::new(AtomicUsize::new(0));
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();

    let first_monitor = Arc::clone(&monitor);
    let first_claims = Arc::clone(&claims);
    let first = std::thread::spawn(move || {
        first_monitor.test_snapshot_after_claim(None, || {
            first_claims.fetch_add(1, Ordering::Relaxed);
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        })
    });
    started_rx.recv().unwrap();
    let second_monitor = Arc::clone(&monitor);
    let second_claims = Arc::clone(&claims);
    let second = std::thread::spawn(move || {
        second_monitor.test_snapshot_after_claim(None, || {
            second_claims.fetch_add(1, Ordering::Relaxed);
        })
    });
    release_tx.send(()).unwrap();
    let _ = first.join().unwrap();
    let _ = second.join().unwrap();

    assert_eq!(claims.load(Ordering::Relaxed), 1);
    assert_eq!(monitor.test_refresh_count(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn panic_after_refresh_claim_releases_cold_waiter() {
    let root = temp_root("live-rate-monitor-panic-claim");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "A", 1);
    create_logs_database(&root, |_connection, _now| {});
    let monitor = Arc::new(LiveRateMonitorService::new(root.clone()));

    let panicking_monitor = Arc::clone(&monitor);
    let panic_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        panicking_monitor.test_snapshot_after_claim(None, || panic!("injected refresh panic"));
    }));
    assert!(panic_result.is_err());

    let (done_tx, done_rx) = mpsc::channel();
    let next_monitor = Arc::clone(&monitor);
    std::thread::spawn(move || {
        let _ = next_monitor.snapshot(None);
        done_tx.send(()).unwrap();
    });
    done_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("panic claim must not strand the next cold snapshot");
    assert_eq!(monitor.test_refresh_count(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn old_panic_guard_cannot_clear_reset_replacement_claim() {
    let root = temp_root("live-rate-monitor-panic-reset-race");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "A", 1);
    create_logs_database(&root, |_connection, _now| {});
    let monitor = Arc::new(LiveRateMonitorService::new(root.clone()));
    let (old_started_tx, old_started_rx) = mpsc::channel();
    let (panic_tx, panic_rx) = mpsc::channel();
    let old_monitor = Arc::clone(&monitor);
    let old = std::thread::spawn(move || {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            old_monitor.test_snapshot_after_claim(None, || {
                old_started_tx.send(()).unwrap();
                panic_rx.recv().unwrap();
                panic!("old claim panic");
            });
        }))
    });
    old_started_rx.recv().unwrap();
    monitor.reset();

    let (new_started_tx, new_started_rx) = mpsc::channel();
    let (release_new_tx, release_new_rx) = mpsc::channel();
    let new_monitor = Arc::clone(&monitor);
    let new = std::thread::spawn(move || {
        new_monitor.test_snapshot_after_claim(None, || {
            new_started_tx.send(()).unwrap();
            release_new_rx.recv().unwrap();
        })
    });
    new_started_rx.recv().unwrap();
    panic_tx.send(()).unwrap();
    assert!(old.join().unwrap().is_err());
    release_new_tx.send(()).unwrap();
    let _ = new.join().unwrap();

    assert_eq!(monitor.test_refresh_count(), 1);
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
fn trace_only_log_rows_do_not_block_rollout_fallback() {
    let root = temp_root("live-rate-trace-only-rollout-fallback");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "trace-only fallback", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    let connection = Connection::open(root.join("logs_2.sqlite")).unwrap();
    let now = current_time_seconds().floor() as i64;
    insert_log(
        &connection,
        1,
        "thread-a",
        now,
        "codex_api::sse::responses",
        "session_loop{thread.id=thread-a}: unhandled responses event: response.in_progress",
    );
    append_rollout_line(
        &rollout_path,
        "response_item",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"rollout output must survive trace-only database rows"}]}"#,
    );

    let snapshot = read_snapshot(&root, None);
    assert!(
        snapshot.tokens_per_second > 0.0,
        "trace-only rows must not suppress the rollout source"
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn stale_stream_rows_do_not_block_current_rollout_fallback() {
    let root = temp_root("live-rate-stale-stream-rollout-fallback");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "stale stream fallback", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    let connection = Connection::open(root.join("logs_2.sqlite")).unwrap();
    let stale_timestamp = current_time_seconds().floor() as i64 - 4;
    insert_log(
        &connection,
        1,
        "thread-a",
        stale_timestamp,
        "codex_api::sse::responses",
        r#"SSE event: {"type":"response.output_text.delta","delta":"stale stream output","item_id":"item-old","sequence_number":1}"#,
    );
    append_rollout_line(
        &rollout_path,
        "response_item",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"current rollout output must win over stale stream rows"}]}"#,
    );

    let snapshot = read_snapshot(&root, None);
    assert!(
        snapshot.tokens_per_second > 0.0,
        "stream rows outside the rolling window must not suppress current rollout output"
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn live_rate_unstarted_rollout_completion_stays_active_through_forward_schedule_window() {
    let root = temp_root("live-rate-unstarted-completion-window");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "forward completion", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();
    let scope = LiveRateSourceScope::new(root.display().to_string(), "forward-window");
    let event_time = fixed_rollout_time();
    let t0 = event_time.unix_timestamp() as f64;

    let _ = rollout::read_rollout_metrics(&root, &scope, t0 - 1.0).unwrap();
    let completion = "x".repeat(650);
    append_rollout_line_at(
        &rollout_path,
        event_time,
        "response_item",
        &format!(
            r#"{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{completion}"}}]}}"#
        ),
    );

    for offset in [0.5, 2.75, 5.25] {
        let metrics = rollout::read_rollout_metrics(&root, &scope, t0 + offset).unwrap();
        let rollup = stream::rollup_metric_events(&metrics, t0 + offset, None);
        assert_eq!(rollup.breakdown.visible_text, 155);
        assert_eq!(rollup.latest_thread_id.as_deref(), Some("thread-a"));
        assert!(
            rollup.tokens_per_second > 0.0,
            "155-token completion should remain active at t0+{offset:.2}s"
        );
    }

    let expired = rollout::read_rollout_metrics(&root, &scope, t0 + 5.5).unwrap();
    assert_eq!(
        stream::rollup_metric_events(&expired, t0 + 5.5, None).tokens_per_second,
        0.0
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn live_rate_two_completion_timeline_has_at_most_two_consecutive_zero_samples() {
    let root = temp_root("live-rate-two-completion-timeline");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "completion timeline", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();
    let scope = LiveRateSourceScope::new(root.display().to_string(), "completion-timeline");
    let first_time = fixed_rollout_time();
    let t0 = first_time.unix_timestamp() as f64;

    let _ = rollout::read_rollout_metrics(&root, &scope, t0 - 1.0).unwrap();
    let first_completion = "x".repeat(650);
    append_rollout_line_at(
        &rollout_path,
        first_time,
        "response_item",
        &format!(
            r#"{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{first_completion}"}}]}}"#
        ),
    );

    let mut consecutive_zero_samples = 0;
    let mut maximum_consecutive_zero_samples = 0;
    for sample in 0..=43 {
        if sample == 22 {
            let second_completion = "y".repeat(650);
            append_rollout_line_at(
                &rollout_path,
                first_time + time::Duration::milliseconds(5_500),
                "response_item",
                &format!(
                    r#"{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{second_completion}"}}]}}"#
                ),
            );
        }
        let now = t0 + f64::from(sample) * 0.25;
        let metrics = rollout::read_rollout_metrics(&root, &scope, now).unwrap();
        let rate = stream::rollup_metric_events(&metrics, now, None).tokens_per_second;
        if rate > 0.0 {
            consecutive_zero_samples = 0;
        } else {
            consecutive_zero_samples += 1;
            maximum_consecutive_zero_samples =
                maximum_consecutive_zero_samples.max(consecutive_zero_samples);
        }
    }

    assert!(
        maximum_consecutive_zero_samples <= 2,
        "250ms timeline contained {maximum_consecutive_zero_samples} consecutive zero samples"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn live_rate_explicit_start_completion_still_ends_at_event_time() {
    let t0 = fixed_rollout_time().unix_timestamp() as f64;
    let metric = stream::LiveMetricEvent {
        event_type: "test.explicit-start".into(),
        timestamp: t0,
        thread_id: Some("thread-a".into()),
        item_id: "item-a".into(),
        sequence_number: None,
        category: stream::LiveTokenCategory::VisibleText,
        delta: String::new(),
        exact_tokens: Some(155),
        start_timestamp: Some(t0 - 4.0),
        distributed: true,
        spreads_forward: false,
        dedupe_key: None,
    };

    assert!(
        stream::rollup_metric_events(&[metric.clone()], t0 - 1.0, None).tokens_per_second > 0.0
    );
    assert!(
        stream::rollup_metric_events(&[metric.clone()], t0 + 2.5, None).tokens_per_second > 0.0
    );
    assert_eq!(
        stream::rollup_metric_events(&[metric], t0 + 2.75, None).tokens_per_second,
        0.0
    );
}

#[test]
fn live_rate_rollup_is_independent_of_cross_file_event_order() {
    let t0 = fixed_rollout_time().unix_timestamp() as f64;
    let older = stream::LiveMetricEvent {
        event_type: "test.older".into(),
        timestamp: t0,
        thread_id: Some("thread-a".into()),
        item_id: "item-older".into(),
        sequence_number: None,
        category: stream::LiveTokenCategory::VisibleText,
        delta: String::new(),
        exact_tokens: Some(10),
        start_timestamp: None,
        distributed: false,
        spreads_forward: false,
        dedupe_key: Some("older".into()),
    };
    let newer = stream::LiveMetricEvent {
        event_type: "test.newer".into(),
        timestamp: t0 + 1.9,
        thread_id: Some("thread-a".into()),
        item_id: "item-newer".into(),
        sequence_number: None,
        category: stream::LiveTokenCategory::VisibleText,
        delta: String::new(),
        exact_tokens: Some(10),
        start_timestamp: None,
        distributed: false,
        spreads_forward: false,
        dedupe_key: Some("newer".into()),
    };

    let chronological = stream::rollup_metric_events(
        &[older.clone(), newer.clone()],
        t0 + 2.0,
        None,
    );
    let reversed = stream::rollup_metric_events(&[newer, older], t0 + 2.0, None);

    assert_eq!(reversed.tokens_per_second, chronological.tokens_per_second);
    assert_eq!(chronological.tokens_per_second, 10.0);
}

#[test]
fn live_rate_stream_tick_keeps_rollout_warm_for_selected_and_empty_handoff() {
    let root = temp_root("live-rate-stream-rollout-warm-handoff");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "rollout selected", 300);
    insert_state_thread(&root, "thread-b", "stream global", 200);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();
    let scope = LiveRateSourceScope::new(root.display().to_string(), "warm-handoff");
    let event_time = fixed_rollout_time();
    let t0 = event_time.unix_timestamp() as f64;

    let _ = read_snapshot_result_at(&root, &scope, Some("thread-a"), t0 - 1.0).unwrap();
    let completion = "x".repeat(650);
    append_rollout_line_at(
        &rollout_path,
        event_time,
        "response_item",
        &format!(
            r#"{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{completion}"}}]}}"#
        ),
    );
    let connection = Connection::open(root.join("logs_2.sqlite")).unwrap();
    insert_log(
        &connection,
        1,
        "thread-b",
        t0 as i64,
        "codex_api::sse::responses",
        r#"SSE event: {"type":"response.output_text.delta","delta":"stream source stays globally preferred","item_id":"item-b","sequence_number":1}"#,
    );

    let stream_tick = read_snapshot_result_at(&root, &scope, Some("thread-a"), t0 + 0.5).unwrap();
    assert!(stream_tick.tokens_per_second > 0.0);
    assert!(
        stream_tick.selected_tokens_per_second > 0.0,
        "selected thread should independently fall back to its rollout"
    );

    connection.execute("DELETE FROM logs", []).unwrap();
    let handoff = read_snapshot_result_at(&root, &scope, Some("thread-a"), t0 + 0.75).unwrap();
    assert!(
        handoff.tokens_per_second > 0.0,
        "empty stream should hand off to the rollout retained during the positive stream tick"
    );
    assert!(handoff.selected_tokens_per_second > 0.0);

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn rollout_fallback_retains_recent_metrics_across_poll_ticks() {
    let root = temp_root("live-rate-rollout-retained-window");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "retained rollout", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    create_logs_database(&root, |_connection, _now| {});
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();

    let _ = read_snapshot(&root, None);
    append_rollout_line(
        &rollout_path,
        "response_item",
        r#"{"type":"custom_tool_call","call_id":"call-a","name":"exec","input":"a retained tool input that should keep the speed bar moving"}"#,
    );

    let first = read_snapshot(&root, None);
    let second = read_snapshot(&root, None);
    assert!(first.tokens_per_second > 0.0);
    assert!(
        second.tokens_per_second > 0.0,
        "the next poll must reuse metrics still inside the rolling window"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn rollout_fallback_expires_metrics_after_the_rolling_window() {
    let root = temp_root("live-rate-rollout-expired-window");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/rollout-thread-a.jsonl");
    create_state_database(&root, "thread-a", "expired rollout", 300);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();
    let scope = LiveRateSourceScope::legacy(&root);

    let _ = rollout::read_rollout_metrics(&root, &scope, current_time_seconds()).unwrap();
    append_rollout_line(
        &rollout_path,
        "response_item",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"this retained event must expire"}]}"#,
    );
    let now = current_time_seconds();
    let current = rollout::read_rollout_metrics(&root, &scope, now).unwrap();
    assert!(!current.is_empty());

    let expired = rollout::read_rollout_metrics(&root, &scope, now + 4.0).unwrap();
    assert!(expired.is_empty());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn useful_stream_rows_are_not_evicted_by_diagnostic_tail_noise() {
    let root = temp_root("live-rate-useful-row-before-noise");
    fs::create_dir_all(&root).unwrap();
    create_logs_database(&root, |connection, now| {
        connection
            .execute_batch(
                "CREATE INDEX idx_logs_ts ON logs(ts DESC, ts_nanos DESC, id DESC); BEGIN;",
            )
            .unwrap();
        insert_log(
            connection,
            1,
            "thread-a",
            now,
            "codex_api::sse::responses",
            r#"SSE event: {"type":"response.output_text.delta","delta":"useful stream row","item_id":"item-a","sequence_number":1}"#,
        );
        for id in 2..=5_001 {
            insert_log(
                connection,
                id,
                "thread-a",
                now,
                "codex_app_server::outgoing_message",
                "diagnostic noise",
            );
        }
        connection.execute_batch("COMMIT;").unwrap();
    });

    let rows = logs::read_recent_log_rows(&root, current_time_seconds() - 1.0).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn useful_stream_row_limit_keeps_the_newest_activity() {
    let root = temp_root("live-rate-useful-row-limit");
    fs::create_dir_all(&root).unwrap();
    create_logs_database(&root, |connection, now| {
        connection.execute_batch("BEGIN;").unwrap();
        for id in 1..=2_500 {
            insert_log(
                connection,
                id,
                "thread-a",
                now,
                "codex_api::sse::responses",
                &format!(
                    r#"SSE event: {{"type":"response.output_text.delta","delta":"chunk-{id}","item_id":"item-a","sequence_number":{id}}}"#
                ),
            );
        }
        connection.execute_batch("COMMIT;").unwrap();
    });

    let rows = logs::read_recent_log_rows(&root, current_time_seconds() - 1.0).unwrap();
    assert_eq!(rows.len(), 2_000);
    assert_eq!(rows.first().map(|row| row.id), Some(501));
    assert_eq!(rows.last().map(|row| row.id), Some(2_500));

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
    let metrics = rollout::read_rollout_metrics(
        &root,
        &LiveRateSourceScope::legacy(&root),
        now,
    )
    .unwrap();
    let rollup = stream::rollup_metric_events(&metrics, now, None);
    assert!(rollup.breakdown.reasoning > 0);
    assert_eq!(rollup.tokens_per_second, 0.0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn rollout_offsets_are_isolated_by_physical_source_scope() {
    let path = PathBuf::from("/same/home/sessions/rollout.jsonl");
    let scope_a = LiveRateSourceScope::new("/same/home", "physical-a");
    let scope_b = LiveRateSourceScope::new("/same/home", "physical-b");

    assert_ne!(
        rollout::offset_key_for_test(&scope_a, &path),
        rollout::offset_key_for_test(&scope_b, &path),
    );
}

#[test]
fn new_physical_scope_initializes_rollout_offset_from_eof() {
    let root = temp_root("live-rate-rollout-physical-offset");
    fs::create_dir_all(&root).unwrap();
    let rollout_path = root.join("sessions/thread-a.jsonl");
    create_state_database(&root, "thread-a", "A", 1);
    set_thread_rollout_path(&root, "thread-a", &rollout_path);
    fs::create_dir_all(rollout_path.parent().unwrap()).unwrap();
    fs::File::create(&rollout_path).unwrap();
    let scope_a = LiveRateSourceScope::new(root.display().to_string(), "physical-a");
    let scope_b = LiveRateSourceScope::new(root.display().to_string(), "physical-b");
    let now = current_time_seconds();

    assert!(rollout::read_rollout_metrics(&root, &scope_a, now)
        .unwrap()
        .is_empty());
    append_rollout_line(
        &rollout_path,
        "event_msg",
        r#"{"type":"agent_message","message":"new for A"}"#,
    );
    assert!(!rollout::read_rollout_metrics(&root, &scope_a, now)
        .unwrap()
        .is_empty());
    assert!(
        rollout::read_rollout_metrics(&root, &scope_b, now)
            .unwrap()
            .is_empty(),
        "B must initialize at its own EOF instead of inheriting A's consumed offset"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn delayed_a_cache_publish_cannot_overwrite_b_scope() {
    let scope_a = LiveRateSourceScope::new("/same/home", "physical-a-delayed");
    let scope_b = LiveRateSourceScope::new("/same/home", "physical-b-current");

    rollout::publish_scope_threads_for_test(&scope_b, "thread-b");
    rollout::publish_scope_threads_for_test(&scope_a, "thread-a-late");

    assert_eq!(
        rollout::cached_scope_thread_ids_for_test(&scope_b),
        vec!["thread-b"]
    );
}

#[test]
fn recent_rollout_threads_refresh_on_wal_change_and_ttl() {
    let root = temp_root("live-rate-rollout-wal-cache");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, "thread-a", "A", 1);
    let rollout_a = root.join("sessions/thread-a.jsonl");
    fs::create_dir_all(rollout_a.parent().unwrap()).unwrap();
    fs::write(&rollout_a, "").unwrap();
    set_thread_rollout_path(&root, "thread-a", &rollout_a);
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    connection.pragma_update(None, "journal_mode", "WAL").unwrap();
    connection.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
    let scope = LiveRateSourceScope::new(root.display().to_string(), "physical-a");

    let first = rollout::recent_thread_ids_for_test(&root, &scope).unwrap();
    assert_eq!(first, vec!["thread-a"]);
    assert_eq!(rollout::cache_load_count_for_test(&scope), 1);
    let cached = rollout::recent_thread_ids_for_test(&root, &scope).unwrap();
    assert_eq!(cached, first);
    assert_eq!(rollout::cache_load_count_for_test(&scope), 1);

    connection
        .execute(
            r#"INSERT INTO threads (id, title, rollout_path, updated_at, updated_at_ms, tokens_used)
               VALUES ('thread-b', 'B', ?1, 9999999999, 9999999999000, 1)"#,
            [root.join("sessions/thread-b.jsonl").to_string_lossy().as_ref()],
        )
        .unwrap();
    let changed = rollout::recent_thread_ids_for_test(&root, &scope).unwrap();
    assert_eq!(changed[0], "thread-b");
    assert_eq!(rollout::cache_load_count_for_test(&scope), 2);

    rollout::expire_cache_for_test(&scope);
    let _ = rollout::recent_thread_ids_for_test(&root, &scope).unwrap();
    assert_eq!(rollout::cache_load_count_for_test(&scope), 3);
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn slow_old_sqlite_read_cannot_overwrite_newer_same_scope_cache() {
    let root = temp_root("live-rate-rollout-same-scope-race");
    fs::create_dir_all(root.join("sessions")).unwrap();
    create_state_database(&root, "thread-a", "A", 1);
    let rollout_a = root.join("sessions/thread-a.jsonl");
    fs::write(&rollout_a, "").unwrap();
    set_thread_rollout_path(&root, "thread-a", &rollout_a);
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    connection.pragma_update(None, "journal_mode", "WAL").unwrap();
    connection.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
    let scope = LiveRateSourceScope::new(root.display().to_string(), "physical-race");
    let (read_tx, read_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let slow_root = root.clone();
    let slow_scope = scope.clone();
    let slow = std::thread::spawn(move || {
        rollout::recent_thread_ids_after_read_hook_for_test(&slow_root, &slow_scope, || {
            read_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        })
        .unwrap()
    });
    read_rx.recv().unwrap();

    let rollout_b = root.join("sessions/thread-b.jsonl");
    fs::write(&rollout_b, "").unwrap();
    connection
        .execute(
            r#"INSERT INTO threads (id, title, rollout_path, updated_at, updated_at_ms, tokens_used)
               VALUES ('thread-b', 'B', ?1, 9999999999, 9999999999000, 1)"#,
            [rollout_b.to_string_lossy().as_ref()],
        )
        .unwrap();
    let current = rollout::recent_thread_ids_for_test(&root, &scope).unwrap();
    assert_eq!(current[0], "thread-b");
    release_tx.send(()).unwrap();
    assert_eq!(slow.join().unwrap(), vec!["thread-a"]);
    assert_eq!(
        rollout::cached_scope_thread_ids_for_test(&scope)[0],
        "thread-b"
    );

    drop(connection);
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
    let metrics = rollout::read_rollout_metrics(
        &root,
        &LiveRateSourceScope::legacy(&root),
        now,
    )
    .unwrap();
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
    write_visible_session_meta(&root, thread_id);
    write_initialized_sidebar_state(&root, &[thread_id]);

    let before = read_snapshot(&root, None);
    assert!(before.unread_summary.active);

    unread::acknowledge_current_unread(&root).unwrap();
    let after = read_snapshot(&root, None);
    assert!(!after.unread_summary.active);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn scoped_monitor_snapshot_does_not_mutate_canonical_unread_baseline() {
    let root = temp_root("scoped-unread-no-canonical-write");
    let support = root.join("tauri-support");
    fs::create_dir_all(&root).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let thread_id = "019eaaaa-0000-0000-0000-000000000299";
    write_visible_session_meta(&root, thread_id);
    write_initialized_sidebar_state(&root, &[thread_id]);
    unread::acknowledge_current_unread(&root).unwrap();
    let acknowledgement_path = support.join("unread-acknowledgement.json");
    let before = fs::read(&acknowledgement_path).unwrap();
    write_initialized_sidebar_state(&root, &[]);

    let monitor = LiveRateMonitorService::new(root.clone());
    let injected = UnreadSummary {
        active: false,
        count: 0,
        label: "暂无未读完成会话".into(),
        detail: "physical scope B".into(),
        source: "codex_unread_state".into(),
    };
    let snapshot = monitor.snapshot_with_unread(None, injected.clone());
    let floating = monitor.floating_snapshot_with_unread(injected);

    assert_eq!(snapshot.unread_summary.count, 0);
    assert_eq!(snapshot.unread_summary.detail, "physical scope B");
    assert_eq!(floating.unread_summary.count, 0);
    assert!(!floating.unread);
    assert_eq!(fs::read(&acknowledgement_path).unwrap(), before);
    let _ = fs::remove_dir_all(root);
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

fn write_visible_session_meta(root: &Path, thread_id: &str) {
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    fs::write(
        sessions.join(format!("{thread_id}.jsonl")),
        format!(
            r#"{{"type":"session_meta","payload":{{"id":"{thread_id}","thread_source":"user","source":"desktop"}}}}"#
        ),
    )
    .unwrap();
}

struct TauriSupportEnvGuard {
    _state: crate::core::usage::cache_lifecycle::UsageCacheTestStateGuard,
}

impl TauriSupportEnvGuard {
    fn new(path: &Path) -> Self {
        Self {
            _state: crate::core::usage::cache_lifecycle::usage_cache_test_state_guard(&[
                ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", path.to_path_buf()),
            ]),
        }
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
    // Existing fallback tests sample after the first forward-scheduled chunk without sleeping.
    append_rollout_line_at(
        path,
        OffsetDateTime::now_utc() - time::Duration::seconds(1),
        record_type,
        payload_json,
    );
}

fn append_rollout_line_at(
    path: &Path,
    timestamp: OffsetDateTime,
    record_type: &str,
    payload_json: &str,
) {
    let mut output = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    let timestamp = timestamp.format(&Rfc3339).unwrap();
    writeln!(
        output,
        r#"{{"timestamp":"{timestamp}","type":"{record_type}","payload":{payload_json}}}"#
    )
    .unwrap();
}

fn fixed_rollout_time() -> OffsetDateTime {
    OffsetDateTime::parse("2026-07-15T00:00:00Z", &Rfc3339).unwrap()
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
        spreads_forward: false,
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
        spreads_forward: false,
        dedupe_key: None,
    }
}
