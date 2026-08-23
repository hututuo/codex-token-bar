use super::exact_usage_index::{
    estimate_precise_scan_total_with_source_revision, integrity_receipt_path_for_testing,
    open_existing_index_for_testing, open_index_for_testing,
    repair_orphaned_index_rows_for_testing, staging_batch_shape_for_testing,
    ExactSyncMode, ORPHAN_REPAIR_REVISION, ORPHAN_REPAIR_REVISION_KEY,
    STAGED_FULL_REBUILD_PARSER_REVISION,
};
use super::session_files::session_id_from_file;
use super::session_parser::{parse_session_file_full_result, EXACT_INDEX_CHUNK_SIZE};
use super::*;
use crate::models::RecentUsagePoint;
use rusqlite::{params, Connection, TransactionBehavior};
use std::fs;
use std::io::{Seek, SeekFrom, Write};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::time::{Duration as StdDuration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[test]
fn staging_budget_batches_cap_workers_artifacts_and_ready_bytes() {
    const MIB: u64 = 1024 * 1024;
    let batches = staging_batch_shape_for_testing(&[
        100 * MIB,
        100 * MIB,
        100 * MIB,
        100 * MIB,
        100 * MIB,
        513 * MIB,
        100 * MIB,
    ]);
    assert!(batches.iter().all(|batch| batch.len() <= 4));
    assert!(batches
        .iter()
        .all(|batch| { batch.len() == 1 || batch.iter().copied().sum::<u64>() <= 512 * MIB }));
    assert!(batches.iter().any(|batch| batch.as_slice() == [513 * MIB]));
}

#[test]
fn future_revision_is_rejected_before_quick_check_or_schema_writes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-future-revision.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();
    let index_path = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES ('fork_replay_boundary_revision', 'future-replay-v99')",
            [],
        )
        .unwrap();
    let schema_before = connection
        .query_row(
            "SELECT value FROM metadata WHERE key = 'schema_version'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    drop(connection);

    ExactUsageIndex::reset_quick_check_count_for_testing();
    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("future revision must be rejected"),
        Err(error) => error,
    };
    assert!(error.contains("需要升级软件"));
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);
    let connection = Connection::open(index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        schema_before
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

struct PreciseRefreshGate {
    permits: Mutex<usize>,
    wake: Condvar,
}

impl PreciseRefreshGate {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            permits: Mutex::new(0),
            wake: Condvar::new(),
        })
    }

    fn acquire(&self) {
        let mut permits = self.permits.lock().unwrap();
        while *permits == 0 {
            permits = self.wake.wait(permits).unwrap();
        }
        *permits -= 1;
    }

    fn release(&self, count: usize) {
        let mut permits = self.permits.lock().unwrap();
        *permits = permits.saturating_add(count);
        self.wake.notify_all();
    }
}

fn install_blocking_precise_refresh_hook(
    homes: &[PathBuf],
) -> (
    mpsc::Receiver<PathBuf>,
    Arc<PreciseRefreshGate>,
    Arc<AtomicU64>,
) {
    let canonical_homes = homes
        .iter()
        .map(|home| fs::canonicalize(home).unwrap())
        .collect::<Vec<_>>();
    let (started_tx, started_rx) = mpsc::channel();
    let gate = PreciseRefreshGate::new();
    let calls = Arc::new(AtomicU64::new(0));
    let gate_for_hook = Arc::clone(&gate);
    let calls_for_hook = Arc::clone(&calls);
    set_precise_refresh_sync_hook_for_testing(Some(Arc::new(move |path| {
        if canonical_homes.iter().any(|home| home == path) {
            calls_for_hook.fetch_add(1, Ordering::SeqCst);
            started_tx
                .send(path.to_path_buf())
                .map_err(|error| format!("sync hook started channel closed: {error}"))?;
            gate_for_hook.acquire();
        }
        Ok(())
    })));
    (started_rx, gate, calls)
}

#[test]
fn attribution_mutation_classifier_ignores_append_but_rejects_delete_rename_and_overflow() {
    use notify::event::{CreateKind, DataChange, Flag, RemoveKind, RenameMode};

    let home = PathBuf::from("/tmp/codex-home-watcher");
    let session = home.join("sessions/2026/07/rollout.jsonl");
    let active_rollout = home.join("active-rollouts/rollout.jsonl");
    let unrelated = home.join("config.toml");
    let append = NotifyEvent::new(NotifyEventKind::Modify(ModifyKind::Data(
        DataChange::Content,
    )))
    .add_path(session.clone());
    let create =
        NotifyEvent::new(NotifyEventKind::Create(CreateKind::File)).add_path(session.clone());
    let delete =
        NotifyEvent::new(NotifyEventKind::Remove(RemoveKind::File)).add_path(session.clone());
    let rename = NotifyEvent::new(NotifyEventKind::Modify(ModifyKind::Name(RenameMode::Both)))
        .add_path(session.clone());
    let unrelated_delete =
        NotifyEvent::new(NotifyEventKind::Remove(RemoveKind::File)).add_path(unrelated);
    let active_rollout_delete =
        NotifyEvent::new(NotifyEventKind::Remove(RemoveKind::File)).add_path(active_rollout);
    let overflow = NotifyEvent::new(NotifyEventKind::Other).set_flag(Flag::Rescan);

    assert!(!mutation_event_requires_continuity_cutover(&home, &append));
    assert!(!mutation_event_requires_continuity_cutover(&home, &create));
    assert!(mutation_event_requires_continuity_cutover(&home, &delete));
    assert!(mutation_event_requires_continuity_cutover(&home, &rename));
    assert!(mutation_event_requires_continuity_cutover(
        &home,
        &active_rollout_delete
    ));
    assert!(!mutation_event_requires_continuity_cutover(
        &home,
        &unrelated_delete
    ));
    assert!(mutation_event_requires_continuity_cutover(&home, &overflow));
}

#[test]
fn attribution_mutation_watcher_covers_transient_state_rollout_outside_sessions() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let active_dir = root.join("active-rollouts");
    fs::create_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&active_dir).unwrap();
    let stable = session_dir.join("rollout-stable.jsonl");
    write_lines(
        &stable,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();
    let marker_path = observer_marker_path(&root).unwrap();
    let watcher = start_attribution_mutation_watcher(&root).unwrap();

    let transient = active_dir.join("rollout-019eoutside-0000-0000-0000-stateonly.jsonl");
    write_lines(
        &transient,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":0,"total_tokens":300}}}}"#,
        ],
    );
    create_state_database_with_rollout(&root, "019eoutside-0000-0000-0000-stateonly", &transient);
    fs::remove_file(&transient).unwrap();
    let deadline = Instant::now() + StdDuration::from_secs(5);
    while !marker_path.exists() && Instant::now() < deadline {
        std::thread::sleep(StdDuration::from_millis(20));
    }
    assert!(
        marker_path.exists(),
        "state rollout JSONL outside sessions must be continuity-covered"
    );

    drop(watcher);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn attribution_mutation_watcher_persists_a_create_consume_delete_gap() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let stable = session_dir.join("rollout-stable.jsonl");
    write_lines(
        &stable,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();
    let marker_path = observer_marker_path(&root).unwrap();
    assert!(!marker_path.exists());
    let watcher = start_attribution_mutation_watcher(&root).unwrap();

    let transient = session_dir.join("rollout-transient.jsonl");
    write_lines(
        &transient,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":0,"total_tokens":300}}}}"#,
        ],
    );
    fs::remove_file(&transient).unwrap();
    let deadline = Instant::now() + StdDuration::from_secs(5);
    while !marker_path.exists() && Instant::now() < deadline {
        std::thread::sleep(StdDuration::from_millis(20));
    }
    assert!(
        marker_path.exists(),
        "create-to-delete between exact polls must durably mark continuity unsafe"
    );
    let marker = precise_observer_identity(&root).unwrap();
    assert!(marker.sequence > 0);
    assert_ne!(marker.epoch, precise_process_observer_identity().epoch);

    drop(watcher);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn attribution_mutation_watcher_rebinds_when_the_same_path_points_to_a_new_directory() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let retired_root = root.with_extension("retired-watch-root");
    fs::create_dir_all(root.join("sessions")).unwrap();
    ensure_attribution_mutation_watcher(&root).unwrap();
    let canonical_home = fs::canonicalize(&root).unwrap();
    let first_identity = attribution_watch_root_physical_identity(&root).unwrap();
    assert_eq!(
        ATTRIBUTION_MUTATION_WATCHERS
            .get()
            .unwrap()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&canonical_home)
            .map(|entry| entry.physical_home_identity.as_str()),
        Some(first_identity.as_str())
    );

    fs::rename(&root, &retired_root).unwrap();
    fs::create_dir_all(root.join("sessions")).unwrap();
    let replacement_identity = attribution_watch_root_physical_identity(&root).unwrap();
    assert_ne!(replacement_identity, first_identity);

    ensure_attribution_mutation_watcher(&root).unwrap();
    let rebound_identity = ATTRIBUTION_MUTATION_WATCHERS
        .get()
        .unwrap()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&canonical_home)
        .map(|entry| entry.physical_home_identity.clone());
    assert_eq!(
        rebound_identity.as_deref(),
        Some(replacement_identity.as_str())
    );
    let marker = precise_observer_identity(&root).unwrap();
    assert!(marker.sequence > 0);
    assert_ne!(marker.epoch, precise_process_observer_identity().epoch);

    let removed = ATTRIBUTION_MUTATION_WATCHERS
        .get()
        .unwrap()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&canonical_home);
    drop(removed);
    clear_attribution_watcher_failure(&canonical_home);
    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(retired_root).unwrap();
}

#[test]
fn precise_refresh_owner_releases_flight_after_panic_and_can_retry() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019erefresh-panic-0000-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    let first = Arc::new(Mutex::new(true));
    let first_for_hook = Arc::clone(&first);
    set_precise_refresh_sync_hook_for_testing(Some(Arc::new(move |_| {
        let should_panic = {
            let mut first = first_for_hook.lock().unwrap();
            let should_panic = *first;
            *first = false;
            should_panic
        };
        if should_panic {
            panic!("injected precise refresh panic");
        }
        Ok(())
    })));

    let error = dashboard_usage_summary(&root).unwrap_err();
    assert!(error.contains("refresh owner 执行异常"));
    set_precise_refresh_sync_hook_for_testing(None);
    assert_eq!(dashboard_usage_summary(&root).unwrap().total_tokens, 120);
    wait_for_usage_summary_refreshes_for_testing();
    assert_eq!(precise_refresh_coordinator_registry_len_for_testing(), 0);
    fs::remove_dir_all(root).unwrap();
}

#[derive(Clone, Copy)]
enum CompletedPreciseRefreshFailure {
    Error,
    Spawn,
    Panic,
}

fn assert_full_retry_after_completed_failure_window(failure: CompletedPreciseRefreshFailure) {
    reset_dashboard_aggregate_build_count_for_testing();
    set_precise_refresh_sync_hook_for_testing(None);
    set_precise_refresh_finish_hook_for_testing(None);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ecompleted-failure-window-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );

    match failure {
        CompletedPreciseRefreshFailure::Error => {
            set_precise_refresh_sync_hook_for_testing(Some(Arc::new(|_| {
                Err("injected completed precise refresh error".into())
            })));
        }
        CompletedPreciseRefreshFailure::Spawn => fail_next_precise_refresh_spawn_for_testing(),
        CompletedPreciseRefreshFailure::Panic => {
            set_precise_refresh_sync_hook_for_testing(Some(Arc::new(|_| {
                panic!("injected completed precise refresh panic")
            })));
        }
    }

    let (finished_tx, finished_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release_rx = Arc::new(Mutex::new(Some(release_rx)));
    let release_rx_for_hook = Arc::clone(&release_rx);
    let first_finish = Arc::new(Mutex::new(true));
    let first_finish_for_hook = Arc::clone(&first_finish);
    set_precise_refresh_finish_hook_for_testing(Some(Arc::new(move || {
        let should_block = {
            let mut first_finish = first_finish_for_hook.lock().unwrap();
            let should_block = *first_finish;
            *first_finish = false;
            should_block
        };
        if !should_block {
            return;
        }
        finished_tx.send(()).unwrap();
        let receiver = release_rx_for_hook
            .lock()
            .unwrap()
            .take()
            .expect("completed failure finish release receiver already consumed");
        receiver.recv().unwrap();
    })));

    let first_root = root.clone();
    let first_handle = std::thread::spawn(move || dashboard_snapshot(&first_root));
    assert!(finished_rx.recv_timeout(StdDuration::from_secs(5)).is_ok());

    set_precise_refresh_sync_hook_for_testing(None);
    set_precise_refresh_finish_hook_for_testing(None);
    let retry = dashboard_snapshot(&root).unwrap();
    assert_eq!(retry.stats.total_tokens, 120);

    release_tx.send(()).unwrap();
    let first_result = first_handle.join().unwrap();
    match failure {
        CompletedPreciseRefreshFailure::Error => assert!(first_result
            .as_ref()
            .is_err_and(|error| error.contains("injected completed precise refresh error"))),
        CompletedPreciseRefreshFailure::Spawn => assert!(first_result
            .as_ref()
            .is_err_and(|error| error.contains("owner 线程启动失败"))),
        CompletedPreciseRefreshFailure::Panic => assert!(first_result
            .as_ref()
            .is_err_and(|error| error.contains("owner 执行异常"))),
    }
    wait_for_usage_summary_refreshes_for_testing();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_refresh_retries_after_completed_error_before_owner_cleanup() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    assert_full_retry_after_completed_failure_window(CompletedPreciseRefreshFailure::Error);
}

#[test]
fn precise_refresh_retries_after_completed_spawn_failure_before_owner_cleanup() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    assert_full_retry_after_completed_failure_window(CompletedPreciseRefreshFailure::Spawn);
}

#[test]
fn precise_refresh_retries_after_completed_panic_before_owner_cleanup() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    assert_full_retry_after_completed_failure_window(CompletedPreciseRefreshFailure::Panic);
}

#[test]
fn precise_refresh_same_home_mixed_requests_share_one_sync() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    let line = serde_json::json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {"last_token_usage": {"total_tokens": 120}}
        }
    })
    .to_string();
    write_lines(
        &session_dir.join("rollout-019emixed-refresh-0000-summary.jsonl"),
        &[line],
    );
    let (started_rx, gate, calls) = install_blocking_precise_refresh_hook(&[root.clone()]);
    let (entered_tx, entered_rx) = mpsc::channel();
    let mut handles = Vec::new();
    for index in 0..20 {
        let root = root.clone();
        let entered_tx = entered_tx.clone();
        handles.push(std::thread::spawn(move || {
            entered_tx.send(()).unwrap();
            if index % 2 == 0 {
                dashboard_usage_summary(&root).map(|summary| summary.total_tokens)
            } else {
                dashboard_snapshot(&root).map(|snapshot| snapshot.stats.total_tokens)
            }
        }));
    }
    drop(entered_tx);

    let all_entered = (0..20).all(|_| entered_rx.recv_timeout(StdDuration::from_secs(5)).is_ok());
    let started = started_rx.recv_timeout(StdDuration::from_secs(5));
    gate.release(20);
    let results = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect::<Vec<_>>();
    set_precise_refresh_sync_hook_for_testing(None);

    assert!(all_entered);
    assert!(started.is_ok());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(results
        .into_iter()
        .all(|result| result.is_ok_and(|total_tokens| total_tokens == 120)));
    wait_for_usage_summary_refreshes_for_testing();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_refresh_summary_promotes_to_full_without_second_sync() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    let line = serde_json::json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {"last_token_usage": {"total_tokens": 120}}
        }
    })
    .to_string();
    write_lines(
        &session_dir.join("rollout-019epromotion-refresh-0000-summary.jsonl"),
        &[line],
    );
    let (started_rx, gate, calls) = install_blocking_precise_refresh_hook(&[root.clone()]);
    let summary_flight = request_precise_refresh(&root, PreciseRefreshIntent::Summary).unwrap();
    let summary_handle = std::thread::spawn(move || summary_flight.wait().summary);
    assert!(started_rx.recv_timeout(StdDuration::from_secs(5)).is_ok());

    let (promoted_tx, promoted_rx) = mpsc::channel();
    set_precise_refresh_promotion_hook_for_testing(Some(Arc::new(move |promoted| {
        promoted_tx
            .send(promoted)
            .map_err(|error| format!("promotion channel closed: {error}"))
    })));
    let full_root = root.clone();
    let full_handle = std::thread::spawn(move || {
        let full_flight = request_precise_refresh(&full_root, PreciseRefreshIntent::Full).unwrap();
        full_flight.wait().full.unwrap()
    });
    let promoted = promoted_rx
        .recv_timeout(StdDuration::from_secs(5))
        .unwrap_or(false);
    gate.release(20);
    let summary = summary_handle.join().unwrap().unwrap();
    let full = full_handle.join().unwrap().unwrap();
    set_precise_refresh_sync_hook_for_testing(None);
    set_precise_refresh_promotion_hook_for_testing(None);

    assert!(promoted);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(summary.total_tokens, 120);
    assert_eq!(full.stats.total_tokens, 120);
    wait_for_usage_summary_refreshes_for_testing();
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn precise_refresh_raw_and_symlink_alias_share_one_canonical_coordinator() {
    use std::os::unix::fs::symlink;

    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let alias = root.with_extension("alias-home");
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    symlink(&root, &alias).unwrap();
    write_lines(
        &session_dir.join("rollout-019ealias-refresh-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );

    let (started_rx, gate, calls) = install_blocking_precise_refresh_hook(&[root.clone()]);
    let summary_root = root.clone();
    let summary_handle = std::thread::spawn(move || dashboard_usage_summary(&summary_root));
    assert!(started_rx.recv_timeout(StdDuration::from_secs(5)).is_ok());

    let (promoted_tx, promoted_rx) = mpsc::channel();
    set_precise_refresh_promotion_hook_for_testing(Some(Arc::new(move |promoted| {
        promoted_tx
            .send(promoted)
            .map_err(|error| format!("alias promotion channel closed: {error}"))
    })));
    let full_alias = alias.clone();
    let full_handle = std::thread::spawn(move || dashboard_snapshot(&full_alias));
    let promoted = promoted_rx
        .recv_timeout(StdDuration::from_secs(5))
        .unwrap_or(false);
    gate.release(20);
    let summary = summary_handle.join().unwrap().unwrap();
    let full = full_handle.join().unwrap().unwrap();
    set_precise_refresh_promotion_hook_for_testing(None);

    assert!(promoted);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(summary.total_tokens, 120);
    assert_eq!(full.stats.total_tokens, 120);
    assert_eq!(dashboard_aggregate_build_count_for_testing(&alias), 1);
    wait_for_usage_summary_refreshes_for_testing();
    fs::remove_file(&alias).unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_refresh_full_after_promotion_cutoff_attaches_without_second_sync() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ecutoff-refresh-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );

    let (cutoff_tx, cutoff_rx) = mpsc::channel();
    let (rejected_tx, rejected_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release_rx = Arc::new(Mutex::new(Some(release_rx)));
    let release_rx_for_hook = Arc::clone(&release_rx);
    set_precise_refresh_after_cutoff_hook_for_testing(Some(Arc::new(move || {
        cutoff_tx
            .send(())
            .map_err(|error| format!("cutoff channel closed: {error}"))?;
        let receiver = release_rx_for_hook
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| "cutoff release receiver already consumed".to_string())?;
        receiver
            .recv()
            .map_err(|error| format!("cutoff release channel closed: {error}"))?;
        Ok(())
    })));

    let summary_flight = request_precise_refresh(&root, PreciseRefreshIntent::Summary).unwrap();
    let summary_handle = std::thread::spawn(move || summary_flight.wait().summary);
    let reached_cutoff = cutoff_rx.recv_timeout(StdDuration::from_secs(5)).is_ok();
    set_precise_refresh_promotion_hook_for_testing(Some(Arc::new(move |promoted| {
        if promoted {
            return Err("cutoff test unexpectedly promoted full request".into());
        }
        rejected_tx
            .send(())
            .map_err(|error| format!("promotion rejection channel closed: {error}"))
    })));

    let full_root = root.clone();
    let full_handle = std::thread::spawn(move || dashboard_snapshot(&full_root));
    let observed_rejection = rejected_rx.recv_timeout(StdDuration::from_secs(5)).is_ok();
    release_tx.send(()).unwrap();
    let summary = summary_handle.join().unwrap();
    let full = full_handle.join().unwrap();
    set_precise_refresh_after_cutoff_hook_for_testing(None);
    set_precise_refresh_promotion_hook_for_testing(None);

    assert!(reached_cutoff);
    assert!(observed_rejection);
    assert_eq!(summary.unwrap().total_tokens, 120);
    assert_eq!(full.unwrap().stats.total_tokens, 120);
    assert_eq!(precise_refresh_sync_call_count_for_testing(), 1);
    wait_for_usage_summary_refreshes_for_testing();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_refresh_different_homes_enter_sync_in_parallel() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let home_a = root.join("home-a");
    let home_b = root.join("home-b");
    fs::create_dir_all(home_a.join("sessions")).unwrap();
    fs::create_dir_all(home_b.join("sessions")).unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    for (home, name, total) in [(&home_a, "a", 120_u64), (&home_b, "b", 30_u64)] {
        let line = serde_json::json!({
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"total_tokens": total}}
            }
        })
        .to_string();
        write_lines(
            &home
                .join("sessions")
                .join(format!("rollout-019eparallel-{name}.jsonl")),
            &[line],
        );
    }
    let (started_rx, gate, calls) =
        install_blocking_precise_refresh_hook(&[home_a.clone(), home_b.clone()]);
    let first_home = home_a.clone();
    let second_home = home_b.clone();
    let first = std::thread::spawn(move || dashboard_usage_summary(&first_home));
    let second = std::thread::spawn(move || dashboard_usage_summary(&second_home));
    let mut started = Vec::new();
    for _ in 0..2 {
        if let Ok(path) = started_rx.recv_timeout(StdDuration::from_secs(5)) {
            started.push(path);
        }
    }
    gate.release(20);
    let first_result = first.join().unwrap();
    let second_result = second.join().unwrap();
    set_precise_refresh_sync_hook_for_testing(None);

    assert_eq!(started.len(), 2);
    assert_ne!(started[0], started[1]);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_eq!(first_result.unwrap().total_tokens, 120);
    assert_eq!(second_result.unwrap().total_tokens, 30);
    wait_for_usage_summary_refreshes_for_testing();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_refresh_owner_error_releases_flight_and_can_retry() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eowner-error-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    let first = Arc::new(Mutex::new(true));
    let first_for_hook = Arc::clone(&first);
    set_precise_refresh_sync_hook_for_testing(Some(Arc::new(move |_| {
        let mut first = first_for_hook.lock().unwrap();
        if *first {
            *first = false;
            return Err("injected precise refresh error".into());
        }
        Ok(())
    })));
    let first_result = dashboard_usage_summary(&root);
    set_precise_refresh_sync_hook_for_testing(None);
    let second_result = dashboard_usage_summary(&root);

    assert!(first_result
        .unwrap_err()
        .contains("injected precise refresh error"));
    assert_eq!(second_result.unwrap().total_tokens, 120);
    wait_for_usage_summary_refreshes_for_testing();
    assert_eq!(precise_refresh_coordinator_registry_len_for_testing(), 0);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_snapshot_returns_cache_before_background_sync_scans_sources() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ecache-first-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    reset_precise_refresh_recency_for_testing();
    reset_dashboard_scan_signature_count_for_testing();
    let (started_rx, gate, calls) = install_blocking_precise_refresh_hook(&[root.clone()]);

    let cached = usage_summary_snapshot(&root);
    schedule_usage_summary_refresh(&root).unwrap();
    let started = started_rx.recv_timeout(StdDuration::from_secs(5));
    let scans_before_release = dashboard_scan_signature_count_for_testing();
    gate.release(20);
    wait_for_usage_summary_refreshes_for_testing();
    set_precise_refresh_sync_hook_for_testing(None);

    assert_eq!(cached.unwrap().unwrap().total_tokens, 120);
    assert!(started.is_ok());
    assert_eq!(scans_before_release, 0);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(dashboard_scan_signature_count_for_testing() > scans_before_release);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_deduplicates_a_replay_after_more_than_4096_unique_snapshots() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eexact-dedupe-0000-0000-0000-index.jsonl");
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    for tokens in 1_u64..=4_097 {
        let line = serde_json::json!({
            "timestamp": "2026-07-20T01:00:00Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": tokens,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                        "total_tokens": tokens
                    },
                    "last_token_usage": {
                        "input_tokens": tokens,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                        "total_tokens": tokens
                    }
                }
            }
        });
        writeln!(handle, "{line}").unwrap();
    }
    let replay = serde_json::json!({
        "timestamp": "2026-07-21T01:00:00Z",
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": 1,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 1
                },
                "last_token_usage": {
                    "input_tokens": 1,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 1
                }
            }
        }
    });
    writeln!(handle, "{replay}").unwrap();
    handle.flush().unwrap();

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, (1_u64..=4_097).sum::<u64>());
    assert_eq!(snapshot.stats.total_calls, 4_097);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_parses_a_valid_jsonl_line_larger_than_the_old_16_mib_limit() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eline-unbounded-0000-0000-0000-index.jsonl");
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    handle.write_all(br#"{"padding":""#).unwrap();
    let chunk = vec![b'x'; 1024 * 1024];
    for _ in 0..17 {
        handle.write_all(&chunk).unwrap();
    }
    handle
        .write_all(
            br#"","timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        )
        .unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert_eq!(snapshot.stats.total_calls, 1);
    assert!(!snapshot
        .warnings
        .iter()
        .any(|warning| warning.source == "usage_precision"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rebuilds_changed_files_and_removes_deleted_files() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let changed_file = session_dir.join("rollout-019eexact-change-0000-0000-0000-index.jsonl");
    let deleted_file = session_dir.join("rollout-019eexact-delete-0000-0000-0000-index.jsonl");
    let initial_changed_timestamp = recent_test_timestamp(10);
    let initial_deleted_timestamp = recent_test_timestamp(9);
    let rewritten_timestamp = recent_test_timestamp(8);
    write_lines(
        &changed_file,
        &[
            format!(r#"{{"timestamp":"{initial_changed_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}}}}}"#),
        ],
    );
    write_lines(
        &deleted_file,
        &[
            format!(r#"{{"timestamp":"{initial_deleted_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}}}}}"#),
        ],
    );

    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 150);
    assert_eq!(initial.stats.total_calls, 2);
    assert_eq!(initial.stats.total_threads, 2);
    let initial_epoch = initial.recent_usage_24h[0]
        .source_contribution_epoch
        .clone()
        .unwrap();
    assert_eq!(attribution_source_tokens(&initial), 150);
    assert!(initial
        .recent_usage_24h
        .iter()
        .flat_map(|point| &point.source_contributions)
        .all(|source| source.source_id.len() == 64));

    write_lines(
        &changed_file,
        &[
            format!(r#"{{"timestamp":"{rewritten_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":50,"cached_input_tokens":10,"output_tokens":15,"total_tokens":75}}}}}}}}"#),
        ],
    );
    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 105);
    assert_eq!(rebuilt.stats.total_calls, 2);
    assert_eq!(rebuilt.stats.total_threads, 2);
    let rebuilt_epoch = rebuilt.recent_usage_24h[0]
        .source_contribution_epoch
        .clone()
        .unwrap();
    assert_ne!(rebuilt_epoch, initial_epoch);
    assert_eq!(attribution_source_tokens(&rebuilt), 105);
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(database).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_5m",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        105,
        "rewriting a file must remove its old bucket contribution"
    );
    drop(connection);

    fs::remove_file(&deleted_file).unwrap();
    let after_delete = dashboard_snapshot(&root).unwrap();
    assert_eq!(after_delete.stats.total_tokens, 75);
    assert_eq!(after_delete.stats.total_calls, 1);
    assert_eq!(after_delete.stats.total_threads, 1);
    assert_eq!(
        after_delete.recent_usage_24h[0]
            .source_contribution_epoch
            .as_deref(),
        Some(rebuilt_epoch.as_str())
    );
    assert_eq!(
        attribution_source_tokens(&after_delete),
        105,
        "deleted sources remain in the durable sparse attribution ledger"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rebuild_recovers_orphaned_events_from_foreign_keys_disabled_storage() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eorphan-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    let canonical_path = fs::canonicalize(&file)
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let connection = Connection::open(&index_path).unwrap();
    let published_generation = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    let orphan_generation = published_generation + 1;
    connection
        .execute_batch("PRAGMA foreign_keys = OFF;")
        .unwrap();
    assert_eq!(
        connection
            .query_row("PRAGMA foreign_keys", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        0
    );
    connection
        .execute(
            r#"
            INSERT INTO events(
                file_generation,
                file_path,
                ordinal,
                timestamp,
                session_id,
                tokens,
                input_tokens,
                cached_input_tokens,
                output_tokens,
                model,
                user_prompt_start,
                user_prompt_end,
                assistant_response_start,
                assistant_response_end
            ) VALUES (?1, ?2, 1, 1, ?3, 120, 100, 20, 20, NULL, NULL, NULL, NULL, NULL)
            "#,
            rusqlite::params![
                orphan_generation,
                canonical_path,
                session_id_from_file(&file),
            ],
        )
        .unwrap();
    assert_eq!(
        connection
            .query_row(
                r#"
                SELECT COUNT(*)
                FROM events e
                LEFT JOIN files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                WHERE f.generation IS NULL
                "#,
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1
    );
    // Simulate a pre-marker legacy index: the orphan was written by an old
    // foreign_keys=OFF connection, so the one-time repair marker is absent.
    connection
        .execute(
            "DELETE FROM metadata WHERE key = ?1",
            params![ORPHAN_REPAIR_REVISION_KEY],
        )
        .unwrap();
    drop(connection);

    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":125,"cached_input_tokens":20,"output_tokens":25,"total_tokens":150}}}}"#,
        ],
    );

    let repaired = dashboard_snapshot(&root).unwrap();
    assert_eq!(repaired.stats.total_tokens, 150);
    assert_eq!(repaired.stats.total_calls, 1);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                r#"
                SELECT COUNT(*)
                FROM events e
                LEFT JOIN files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                WHERE f.generation IS NULL
                "#,
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = ?1",
                params![ORPHAN_REPAIR_REVISION_KEY],
                |row| row.get::<_, String>(0),
            )
            .unwrap()
            .as_str(),
        ORPHAN_REPAIR_REVISION
    );
    drop(connection);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn orphan_repair_marks_a_legacy_index_without_orphans() {
    let root = temp_root();
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(index_path.parent().unwrap()).unwrap();
    let mut connection = open_index_for_testing(&index_path).unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = ?1",
            params![ORPHAN_REPAIR_REVISION_KEY],
        )
        .unwrap();

    repair_orphaned_index_rows_for_testing(&mut connection).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = ?1",
                params![ORPHAN_REPAIR_REVISION_KEY],
                |row| row.get::<_, String>(0),
            )
            .unwrap()
            .as_str(),
        ORPHAN_REPAIR_REVISION
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn orphan_repair_cleans_orphans_and_rewrites_a_wrong_marker() {
    let root = temp_root();
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(index_path.parent().unwrap()).unwrap();
    let mut connection = open_index_for_testing(&index_path).unwrap();
    connection
        .execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES (?1, 'old-revision')",
            params![ORPHAN_REPAIR_REVISION_KEY],
        )
        .unwrap();

    connection
        .execute_batch("PRAGMA foreign_keys = OFF;")
        .unwrap();
    connection
        .execute(
            r#"
            INSERT INTO events(
                file_generation, file_path, ordinal, timestamp, session_id,
                tokens, input_tokens, cached_input_tokens, output_tokens
            ) VALUES (99, '/legacy-orphan.jsonl', 1, 1, 'legacy-orphan', 1, 1, 0, 0)
            "#,
            [],
        )
        .unwrap();
    connection
        .execute(
            r#"
            INSERT INTO file_fingerprints(file_generation, file_path, fingerprint)
            VALUES (99, '/legacy-orphan.jsonl', X'01')
            "#,
            [],
        )
        .unwrap();
    connection
        .execute(
            r#"
            INSERT INTO file_chunks(file_generation, file_path, chunk_index, byte_count, sha256)
            VALUES (99, '/legacy-orphan.jsonl', 0, 1, X'02')
            "#,
            [],
        )
        .unwrap();

    repair_orphaned_index_rows_for_testing(&mut connection).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = ?1",
                params![ORPHAN_REPAIR_REVISION_KEY],
                |row| row.get::<_, String>(0),
            )
            .unwrap()
            .as_str(),
        ORPHAN_REPAIR_REVISION
    );
    for table in ["events", "file_fingerprints", "file_chunks"] {
        let count = connection
            .query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE file_generation = 99"),
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(count, 0, "legacy orphan rows remained in {table}");
    }
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn orphan_repair_marker_hit_skips_writer_upgrade_under_another_immediate_lock() {
    let root = temp_root();
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(index_path.parent().unwrap()).unwrap();
    let mut connection = open_index_for_testing(&index_path).unwrap();
    repair_orphaned_index_rows_for_testing(&mut connection).unwrap();

    let mut holder = open_index_for_testing(&index_path).unwrap();
    let lock = holder
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    repair_orphaned_index_rows_for_testing(&mut connection).unwrap();
    drop(lock);
    drop(holder);
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn orphan_repair_marker_miss_fails_closed_when_writer_upgrade_is_busy() {
    let root = temp_root();
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(index_path.parent().unwrap()).unwrap();
    let mut connection = open_index_for_testing(&index_path).unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = ?1",
            params![ORPHAN_REPAIR_REVISION_KEY],
        )
        .unwrap();
    connection
        .busy_timeout(StdDuration::from_millis(0))
        .unwrap();

    let mut holder = open_index_for_testing(&index_path).unwrap();
    let lock = holder
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    let error = repair_orphaned_index_rows_for_testing(&mut connection).unwrap_err();
    assert!(
        error.contains("database is locked"),
        "unexpected busy error: {error}"
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM metadata WHERE key = ?1",
                params![ORPHAN_REPAIR_REVISION_KEY],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    drop(lock);
    drop(holder);
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn persistent_rewrite_stays_one_unsafe_incident_until_a_clean_generation_is_acknowledged() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019erewrite-1111-4111-8111-persistent000.jsonl");
    let event = |tokens| {
        serde_json::json!({
            "timestamp": "2026-07-20T01:00:00Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": tokens,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                        "total_tokens": tokens,
                    }
                }
            }
        })
        .to_string()
    };
    write_lines(&file, &[event(100)]);
    let initial = dashboard_snapshot(&root).unwrap();
    assert!(!initial.precise_attribution_current_scan_unsafe);
    assert!(initial
        .precise_attribution_unsafe_since_generation
        .is_none());

    write_lines(&file, &[event(200)]);
    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    let first_unsafe = dashboard_snapshot(&root).unwrap();
    assert!(first_unsafe.precise_attribution_current_scan_unsafe);
    let unsafe_epoch = first_unsafe
        .precise_attribution_provenance_epoch
        .clone()
        .unwrap();
    let unsafe_since = first_unsafe
        .precise_attribution_unsafe_since_generation
        .unwrap();
    let unsafe_id = first_unsafe.precise_attribution_unsafe_id.clone().unwrap();

    write_lines(&file, &[event(300)]);
    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    let still_unsafe = dashboard_snapshot(&root).unwrap();
    assert!(still_unsafe.precise_attribution_current_scan_unsafe);
    assert_eq!(
        still_unsafe.precise_attribution_provenance_epoch.as_deref(),
        Some(unsafe_epoch.as_str())
    );
    assert_eq!(
        still_unsafe.precise_attribution_unsafe_since_generation,
        Some(unsafe_since)
    );
    assert_eq!(
        still_unsafe.precise_attribution_unsafe_id.as_deref(),
        Some(unsafe_id.as_str())
    );
    assert!(!acknowledge_attribution_safety(
        &root,
        &unsafe_epoch,
        &unsafe_id,
        still_unsafe.precise_attribution_generation.unwrap(),
    )
    .unwrap());

    let clean = dashboard_snapshot(&root).unwrap();
    assert!(!clean.precise_attribution_current_scan_unsafe);
    assert_eq!(
        clean.precise_attribution_unsafe_id.as_deref(),
        Some(unsafe_id.as_str())
    );
    let clean_generation = clean.precise_attribution_generation.unwrap();
    assert!(!acknowledge_attribution_safety(
        &root,
        &unsafe_epoch,
        &unsafe_id,
        clean_generation.saturating_sub(1),
    )
    .unwrap());
    assert!(!acknowledge_attribution_safety(
        &root,
        &unsafe_epoch,
        &Uuid::new_v4().to_string(),
        clean_generation,
    )
    .unwrap());
    assert!(!acknowledge_attribution_safety(
        &root,
        &unsafe_epoch,
        &unsafe_id,
        clean_generation.saturating_add(1),
    )
    .unwrap());
    assert!(
        acknowledge_attribution_safety(&root, &unsafe_epoch, &unsafe_id, clean_generation,)
            .unwrap()
    );
    let acknowledged = ExactUsageIndex::open(&root)
        .unwrap()
        .attribution_safety_state()
        .unwrap();
    assert!(acknowledged.unsafe_since_generation.is_none());
    assert!(acknowledged.unsafe_id.is_none());

    let post_ack_clean = dashboard_snapshot(&root).unwrap();
    assert!(!post_ack_clean.precise_attribution_current_scan_unsafe);
    assert!(post_ack_clean.precise_attribution_unsafe_id.is_none());

    write_lines(&file, &[event(400)]);
    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    let second_unsafe = dashboard_snapshot(&root).unwrap();
    assert!(second_unsafe.precise_attribution_current_scan_unsafe);
    assert_ne!(
        second_unsafe
            .precise_attribution_provenance_epoch
            .as_deref(),
        Some(unsafe_epoch.as_str()),
        "a later incident after acknowledgement must rotate provenance again"
    );
    let second_unsafe_id = second_unsafe.precise_attribution_unsafe_id.clone().unwrap();
    assert_ne!(second_unsafe_id, unsafe_id);
    reset_dashboard_aggregate_build_count_for_testing();
    let second_clean = dashboard_snapshot(&root).unwrap();
    assert!(!second_clean.precise_attribution_current_scan_unsafe);
    assert_eq!(
        second_clean.precise_attribution_unsafe_id.as_deref(),
        Some(second_unsafe_id.as_str())
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn persistent_duplicate_session_lineage_does_not_rotate_until_it_becomes_clean() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    let first_dir = session_dir.join("first");
    let second_dir = session_dir.join("second");
    fs::create_dir_all(&first_dir).unwrap();
    fs::create_dir_all(&second_dir).unwrap();
    let duplicate_name = "rollout-019eduplicate-1111-4111-8111-000000000001.jsonl";
    let first = first_dir.join(duplicate_name);
    let second = second_dir.join(duplicate_name);
    write_lines(
        &first,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );
    write_lines(
        &second,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":0,"total_tokens":300}}}}"#,
        ],
    );

    let first_unsafe = dashboard_snapshot(&root).unwrap();
    assert!(first_unsafe.precise_attribution_current_scan_unsafe);
    let unsafe_epoch = first_unsafe
        .precise_attribution_provenance_epoch
        .clone()
        .unwrap();
    let unsafe_id = first_unsafe.precise_attribution_unsafe_id.clone().unwrap();
    let repeated = dashboard_snapshot(&root).unwrap();
    assert!(repeated.precise_attribution_current_scan_unsafe);
    assert_eq!(
        repeated.precise_attribution_provenance_epoch.as_deref(),
        Some(unsafe_epoch.as_str())
    );
    assert_eq!(
        repeated.precise_attribution_unsafe_id.as_deref(),
        Some(unsafe_id.as_str())
    );

    fs::remove_file(&second).unwrap();
    reset_dashboard_aggregate_build_count_for_testing();
    let clean = dashboard_snapshot(&root).unwrap();
    assert!(!clean.precise_attribution_current_scan_unsafe);
    assert_eq!(
        clean.precise_attribution_unsafe_id.as_deref(),
        Some(unsafe_id.as_str())
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn missing_session_roots_keep_the_previous_published_generation() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let retained_session_dir = root.join("retained-sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019emissing-root-safe.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 100);
    let connection = Connection::open(&index_path).unwrap();
    let published_before = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    drop(connection);

    fs::rename(&session_dir, &retained_session_dir).unwrap();
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let error = index.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("会话根目录暂时不可用"), "{error}");
    drop(index);

    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        published_before
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COALESCE(SUM(tokens), 0) FROM published_events",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        100
    );
    drop(connection);
    fs::rename(&retained_session_dir, &session_dir).unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn unreadable_primary_session_root_keeps_the_previous_published_generation() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_file = session_dir.join("rollout-019eincomplete-dir-0000-0000-0000-safe.jsonl");
    write_lines(
        &session_file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 100);
    assert!(initial.precise_recent_usage_fresh);
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let connection = Connection::open(&index_path).unwrap();
    let published_before = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    drop(connection);

    let retained_session_dir = root.join("retained-sessions");
    fs::rename(&session_dir, &retained_session_dir).unwrap();
    fs::write(&session_dir, b"not-a-directory").unwrap();
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let error = index.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("会话根目录暂时不可用"), "{error}");
    drop(index);

    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        published_before,
        "an unreadable primary root must not advance the published selector"
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COALESCE(SUM(tokens), 0) FROM published_events",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        100
    );
    drop(connection);

    fs::remove_file(&session_dir).unwrap();
    fs::rename(&retained_session_dir, &session_dir).unwrap();
    let recovered = dashboard_snapshot(&root).unwrap();
    assert_eq!(recovered.stats.total_tokens, 100);
    assert!(recovered.precise_recent_usage_fresh);
    assert!(recovered.precise_recent_usage_covered_at.is_some());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn codex_home_replacement_during_precise_scan_blocks_generation_publish() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let retired_root = root.with_extension("retired-precise-root");
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eroot-swap-0000-0000-0000-safe.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );
    let replacement_root = root.clone();
    let replacement_file_name = file.file_name().unwrap().to_owned();
    let retired_for_hook = retired_root.clone();
    let replacement_hook: Box<dyn FnOnce(&Path) -> Result<(), String> + Send> = Box::new(
        move |_| {
            fs::rename(&replacement_root, &retired_for_hook).map_err(|error| error.to_string())?;
            let replacement_sessions = replacement_root.join("sessions");
            fs::create_dir_all(&replacement_sessions).map_err(|error| error.to_string())?;
            write_lines(
                &replacement_sessions.join(replacement_file_name),
                &[
                    r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":0,"total_tokens":900}}}}"#,
                ],
            );
            Ok(())
        },
    );
    let replacement_hook = Arc::new(Mutex::new(Some(replacement_hook)));
    let replacement_hook_for_refresh = Arc::clone(&replacement_hook);
    set_precise_refresh_sync_hook_for_testing(Some(Arc::new(move |_| {
        if let Some(hook) = replacement_hook_for_refresh.lock().unwrap().take() {
            ExactUsageIndex::set_after_file_commit_hook_for_testing(hook);
        }
        Ok(())
    })));

    let error = dashboard_snapshot(&root).unwrap_err();
    set_precise_refresh_sync_hook_for_testing(None);

    #[cfg(windows)]
    if error.contains("拒绝访问") || error.contains("os error 5") {
        // Windows SQLite handles do not permit renaming their containing
        // Home while the precise owner is still open. The attempted swap is
        // therefore rejected before the replacement hook can complete; the
        // important invariant is still that the scan fails closed and never
        // publishes the replacement source.
        let original_index = super::exact_usage_index::database_path(&root).unwrap();
        let connection = Connection::open(original_index).unwrap();
        assert_eq!(
            connection
                .query_row("SELECT COUNT(*) FROM published_events", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            0,
            "a rejected Windows Home replacement must not publish staged events"
        );
        drop(connection);
        fs::remove_dir_all(root).unwrap();
        return;
    }

    assert!(
        error.contains("已保留上一份可信索引并停止本轮发布"),
        "{error}"
    );

    let retired_index = retired_root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let connection = Connection::open(retired_index).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM published_events", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0,
        "a replaced Home must not publish the staged source from either identity"
    );
    drop(connection);

    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(retired_root).unwrap();
}

#[test]
fn missing_active_rollout_marks_the_scan_unsafe_without_losing_session_totals() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eincomplete-state-0000-0000-0000-safe.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":0,"output_tokens":0,"total_tokens":120}}}}"#,
        ],
    );
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);

    let missing_rollout = root
        .join("active-rollouts")
        .join("rollout-019emissing-active-0000-0000-0000.jsonl");
    create_state_database_with_rollout(
        &root,
        "019emissing-active-0000-0000-0000-rollout",
        &missing_rollout,
    );
    let incomplete = dashboard_snapshot(&root).unwrap();
    assert_eq!(incomplete.stats.total_tokens, 120);
    assert!(!incomplete.precise_recent_usage_fresh);
    assert!(incomplete.precise_attribution_current_scan_unsafe);
    assert!(incomplete.warnings.iter().any(|warning| {
        warning.source == "jsonl_scan"
            && warning
                .message
                .contains("无法确认 active rollout 会话文件边界")
    }));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn staged_jsonl_open_failure_is_a_structured_incomplete_scan() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019estage-open-stable-0000-0000-0000.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 100);

    let disappearing = session_dir.join("rollout-019estage-open-new-0000-0000-0000.jsonl");
    let mut handle = std::io::BufWriter::new(fs::File::create(&disappearing).unwrap());
    handle.write_all(br#"{"padding":""#).unwrap();
    handle
        .write_all(&vec![b'p'; EXACT_INDEX_CHUNK_SIZE as usize])
        .unwrap();
    handle.write_all(b"\"}\n").unwrap();
    writeln!(
        handle,
        "{}",
        r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":0,"total_tokens":300}}}}"#
    )
    .unwrap();
    handle.flush().unwrap();
    drop(handle);
    ExactUsageIndex::set_before_staging_open_hook_for_testing(
        fs::canonicalize(&disappearing).unwrap(),
        |path| fs::remove_file(path).unwrap(),
    );

    let incomplete = dashboard_snapshot(&root).unwrap();
    assert_eq!(incomplete.stats.total_tokens, 100);
    assert!(!incomplete.precise_recent_usage_fresh);
    assert!(incomplete.precise_attribution_current_scan_unsafe);
    assert!(incomplete.warnings.iter().any(|warning| {
        warning.source == "jsonl_scan" && warning.message.contains("暂存读取不完整")
    }));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn compact_sync_preserves_a_source_deleted_before_the_next_full_snapshot() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let stable_file = session_dir.join("rollout-019eledger-stable-0000-0000-0000.jsonl");
    let transient_file = session_dir.join("rollout-019eledger-transient-0000-0000-0000.jsonl");
    let stable_timestamp = recent_test_timestamp(10);
    let transient_timestamp = recent_test_timestamp(9);
    write_lines(
        &stable_file,
        &[
            format!(r#"{{"timestamp":"{stable_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}}}}}"#),
        ],
    );
    let initial = dashboard_snapshot(&root).unwrap();
    let epoch = initial.recent_usage_24h[0]
        .source_contribution_epoch
        .clone()
        .unwrap();
    assert_eq!(attribution_source_tokens(&initial), 100);

    write_lines(
        &transient_file,
        &[
            format!(r#"{{"timestamp":"{transient_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":300,"cached_input_tokens":0,"output_tokens":0,"total_tokens":300}}}}}}}}"#),
        ],
    );
    assert_eq!(dashboard_usage_summary(&root).unwrap().total_tokens, 400);
    fs::remove_file(&transient_file).unwrap();
    assert_eq!(dashboard_usage_summary(&root).unwrap().total_tokens, 100);

    let after_delete = dashboard_snapshot(&root).unwrap();
    assert_eq!(after_delete.stats.total_tokens, 100);
    assert_eq!(attribution_source_tokens(&after_delete), 400);
    assert_eq!(
        after_delete.recent_usage_24h[0]
            .source_contribution_epoch
            .as_deref(),
        Some(epoch.as_str())
    );

    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .execute(
                "DELETE FROM attribution_source_buckets WHERE tokens = 300",
                [],
            )
            .unwrap(),
        1
    );
    drop(connection);
    let after_missing_row = dashboard_snapshot(&root).unwrap();
    assert_ne!(
        after_missing_row.recent_usage_24h[0]
            .source_contribution_epoch
            .as_deref(),
        Some(epoch.as_str()),
        "a logically missing durable ledger row must rotate provenance instead of understating local use"
    );
    assert_eq!(attribution_source_tokens(&after_missing_row), 100);

    fs::remove_dir_all(root).unwrap();
}

fn attribution_source_tokens(snapshot: &DashboardSnapshot) -> u64 {
    snapshot
        .recent_usage_24h
        .iter()
        .flat_map(|point| &point.source_contributions)
        .map(|source| source.tokens)
        .sum()
}

#[test]
fn exact_index_prunes_superseded_file_versions_on_the_next_streaming_scan() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eversion-gc-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101,"cached_input_tokens":20,"output_tokens":20,"total_tokens":121}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 121);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM files", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        2
    );
    drop(connection);

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 121);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM files", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1,
        "obsolete file generations must not accumulate without bound"
    );
    drop(connection);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_includes_archived_sessions_outside_active_state() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let sessions_dir = root.join("sessions");
    let archived_dir = root.join("archived_sessions");
    fs::create_dir_all(&sessions_dir).unwrap();
    fs::create_dir_all(&archived_dir).unwrap();
    write_lines(
        &sessions_dir.join("rollout-019eexact-active-0000-0000-0000-index.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &archived_dir.join("rollout-019eexact-archived-0000-0000-0000-index.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 150);
    assert_eq!(snapshot.stats.total_calls, 2);
    assert_eq!(snapshot.stats.total_threads, 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_scans_more_than_20_000_session_files_without_truncation() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    for index in 0..20_000 {
        fs::File::create(session_dir.join(format!("empty-{index:05}.jsonl"))).unwrap();
    }
    write_lines(
        &session_dir.join("rollout-019efile-count-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let summary = usage_summary(&root).unwrap();

    assert_eq!(summary.total_tokens, 120);
    assert_eq!(summary.today_requests, 0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_retries_an_incomplete_tail_after_the_jsonl_line_is_completed() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019epartial-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        write!(
            handle,
            "{}",
            r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40"#
        )
        .unwrap();
    }

    let incomplete = dashboard_snapshot(&root).unwrap();
    assert_eq!(incomplete.stats.total_tokens, 120);
    assert_eq!(incomplete.stats.total_calls, 1);

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            "{}",
            r#","cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#
        )
        .unwrap();
    }
    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    let completed = dashboard_snapshot(&root).unwrap();
    assert_eq!(completed.stats.total_tokens, 170);
    assert_eq!(completed.stats.total_calls, 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_commits_the_scan_start_prefix_while_the_active_file_appends() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-prefix-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let expected_file = fs::canonicalize(&file).unwrap();
    let prefix_rehashes = Arc::new(AtomicU64::new(0));
    let prefix_rehashes_for_hook = Arc::clone(&prefix_rehashes);
    let prefix_hook: Box<dyn FnOnce(&Path) + Send> = Box::new(move |scanned_file| {
        prefix_rehashes_for_hook.fetch_add(1, Ordering::SeqCst);
        assert_eq!(scanned_file, expected_file);
        let mut handle = fs::OpenOptions::new()
            .append(true)
            .open(scanned_file)
            .unwrap();
        writeln!(
            handle,
            "{}",
            r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#
        )
        .unwrap();
        handle.flush().unwrap();
    });
    let prefix_hook = Arc::new(Mutex::new(Some(prefix_hook)));
    let prefix_hook_for_refresh = Arc::clone(&prefix_hook);
    set_precise_refresh_sync_hook_for_testing(Some(Arc::new(move |_| {
        if let Some(hook) = prefix_hook_for_refresh.lock().unwrap().take() {
            ExactUsageIndex::set_after_prefix_scan_hook_for_testing(hook);
        }
        Ok(())
    })));

    let old_timepoint = dashboard_snapshot(&root).unwrap();
    set_precise_refresh_sync_hook_for_testing(None);
    assert_eq!(old_timepoint.stats.total_tokens, 120);
    assert_eq!(old_timepoint.stats.total_calls, 1);
    assert!(!old_timepoint.precise_attribution_current_scan_unsafe);
    assert_eq!(
        prefix_rehashes.load(Ordering::SeqCst),
        1,
        "an active append must still revalidate the complete scan-start prefix"
    );

    let after_append = dashboard_snapshot(&root).unwrap();
    assert_eq!(after_append.stats.total_tokens, 170);
    assert_eq!(after_append.stats.total_calls, 2);
    assert!(!after_append.precise_attribution_current_scan_unsafe);
    assert_eq!(
        prefix_rehashes.load(Ordering::SeqCst),
        1,
        "a stable follow-up scan must not rehash an unchanged file"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_discovery_remains_a_usable_candidate_hint_after_file_metadata_drifts() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019ediscovery-drift-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );

    let discovery =
        estimate_precise_scan_total_with_source_revision(&root, StdDuration::from_secs(2), 1)
            .unwrap();
    assert_eq!(discovery.candidate_total, 1);

    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(handle, "{{\"metadata\":\"appended after discovery\"}}").unwrap();
    handle.flush().unwrap();

    assert!(
        discovery.is_usable(&root),
        "a stale candidate signature must be revalidated by the formal scan, not discard the plan"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_scan_plan_defers_files_created_after_discovery_until_next_plan() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let first = session_dir.join("rollout-019ediscovery-first-0000-0000-0000-exact.jsonl");
    write_lines(
        &first,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
        ],
    );
    let discovery =
        estimate_precise_scan_total_with_source_revision(&root, StdDuration::from_secs(2), 1)
            .unwrap();
    assert_eq!(discovery.candidate_total, 1);

    let second = session_dir.join("rollout-019ediscovery-second-0000-0000-0000-exact.jsonl");
    write_lines(
        &second,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"total_tokens":200}}}}"#,
        ],
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    index
        .sync_with_scan_plan(&root, &mut warnings, Some(discovery), Some(1))
        .unwrap();
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        100,
        "the formal pass must consume only the discovery candidates"
    );

    let next_discovery =
        estimate_precise_scan_total_with_source_revision(&root, StdDuration::from_secs(2), 2)
            .unwrap();
    index
        .sync_with_scan_plan(
            &root,
            &mut warnings,
            Some(next_discovery.clone()),
            Some(next_discovery.candidate_total),
        )
        .unwrap();
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        300,
        "the next discovery must pick up the file created after the prior plan"
    );
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_append_scan_reads_only_the_tail_chunk_and_new_suffix() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-bytes-0000-0000-0000-exact.jsonl");
    let initial_timestamp = recent_test_timestamp(10);
    let appended_timestamp = recent_test_timestamp(9);
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    handle.write_all(br#"{"padding":""#).unwrap();
    let padding = vec![b'x'; 1024 * 1024];
    for _ in 0..12 {
        handle.write_all(&padding).unwrap();
    }
    handle.write_all(b"\"}\n").unwrap();
    handle
        .write_all(
            format!(r#"{{"timestamp":"{initial_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}}}}}"#).as_bytes(),
        )
        .unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);
    let initial_size = fs::metadata(&file).unwrap().len();

    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    assert_eq!(attribution_source_tokens(&initial), 120);
    let initial_epoch = initial.recent_usage_24h[0]
        .source_contribution_epoch
        .clone()
        .unwrap();
    let (cold_bytes, append_bytes_before) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(cold_bytes, initial_size);
    assert_eq!(append_bytes_before, 0);

    let appended = format!(r#"{{"timestamp":"{appended_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}}}}}"#);
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    handle.write_all(appended.as_bytes()).unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);

    let refreshed = dashboard_snapshot(&root).unwrap();
    assert_eq!(refreshed.stats.total_tokens, 150);
    assert_eq!(refreshed.stats.total_calls, 2);
    assert_eq!(attribution_source_tokens(&refreshed), 150);
    assert_eq!(
        refreshed.recent_usage_24h[0]
            .source_contribution_epoch
            .as_deref(),
        Some(initial_epoch.as_str()),
        "a proven append must keep the same attribution provenance epoch"
    );
    let (full_bytes_after, append_bytes_after) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(
        full_bytes_after, cold_bytes,
        "a pure append must not trigger another complete source parse"
    );
    assert!(
        append_bytes_after <= EXACT_INDEX_CHUNK_SIZE + appended.len() as u64 + 1,
        "append parser read {append_bytes_after} bytes instead of one tail chunk plus the suffix"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_append_reuses_checkpoint_when_open_line_crosses_chunk_boundary() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-cross-0000-0000-0000-exact.jsonl");

    let first_line = br#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let second_line = br#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#;

    // 让未完成的第二条 token 行行首落在第二个块内、行尾越过 4 MiB 块边界：
    // 续扫应从检查点所在块起点重新 hash，而不是回退到文件头。
    let open_line_start = EXACT_INDEX_CHUNK_SIZE * 2 - 100;
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    handle.write_all(first_line).unwrap();
    handle.write_all(b"\n").unwrap();
    let pad_prefix = br#"{"padding":""#;
    let pad_suffix = b"\"}\n";
    let written = first_line.len() as u64 + 1;
    let pad_body =
        usize::try_from(open_line_start - written).unwrap() - pad_prefix.len() - pad_suffix.len();
    handle.write_all(pad_prefix).unwrap();
    handle.write_all(&vec![b'x'; pad_body]).unwrap();
    handle.write_all(pad_suffix).unwrap();
    let split = 150usize;
    handle.write_all(&second_line[..split]).unwrap();
    handle.flush().unwrap();
    drop(handle);
    assert!(fs::metadata(&file).unwrap().len() > EXACT_INDEX_CHUNK_SIZE);

    // 首轮：只统计完整行，检查点固化在未完成行行首（块边界之前）。
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    // 补完该行：即使未完成行跨 chunk，也应局部续扫。
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    handle.write_all(&second_line[split..]).unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);

    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let refreshed = dashboard_snapshot(&root).unwrap();
    assert_eq!(refreshed.stats.total_tokens, 150);
    assert_eq!(refreshed.stats.total_calls, 2);
    let (full_bytes, append_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert!(append_bytes > 0, "追加路径必须读取检查点后的必要范围");
    assert_eq!(full_bytes, 0, "纯追加不能触发单文件全量重建");
    assert!(
        append_bytes < fs::metadata(&file).unwrap().len(),
        "跨 chunk 追加只应从检查点所在 chunk 读取，而不是重读文件头"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_append_at_chunk_boundary_keeps_previous_tail_validation_local() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-boundary-0000-0000-0000-exact.jsonl");
    let first_line = br#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let second_line = br#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#;
    let pad_prefix = br#"{"padding":""#;
    let pad_suffix = b"\"}\n";
    let first_line_size = first_line.len() as u64 + 1;
    let pad_body = usize::try_from(
        EXACT_INDEX_CHUNK_SIZE
            .saturating_mul(2)
            .saturating_sub(first_line_size)
            .saturating_sub(pad_prefix.len() as u64)
            .saturating_sub(pad_suffix.len() as u64),
    )
    .unwrap();
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    handle.write_all(pad_prefix).unwrap();
    handle.write_all(&vec![b'x'; pad_body]).unwrap();
    handle.write_all(pad_suffix).unwrap();
    handle.write_all(first_line).unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);
    assert_eq!(
        fs::metadata(&file).unwrap().len(),
        EXACT_INDEX_CHUNK_SIZE * 2
    );

    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    handle.write_all(second_line).unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);

    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let refreshed = dashboard_snapshot(&root).unwrap();
    assert_eq!(refreshed.stats.total_tokens, 150);
    let (full_bytes, append_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(full_bytes, 0);
    assert!(append_bytes >= EXACT_INDEX_CHUNK_SIZE);
    assert!(append_bytes < fs::metadata(&file).unwrap().len());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rolling_audit_falls_back_to_full_rebuild_after_middle_rewrite_and_append() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaudit-rewrite-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    writeln!(handle, "{original}").unwrap();
    handle.write_all(br#"{"padding":""#).unwrap();
    let padding = vec![b'z'; 1024 * 1024];
    for _ in 0..9 {
        handle.write_all(&padding).unwrap();
    }
    handle.write_all(b"\"}\n").unwrap();
    handle.flush().unwrap();
    drop(handle);
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let before = fs::read_to_string(&file).unwrap();
    let rewritten = before.replacen("\"total_tokens\":120", "\"total_tokens\":121", 1);
    assert_eq!(before.len(), rewritten.len());
    fs::write(&file, rewritten).unwrap();
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(
        handle,
        "{}",
        r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#
    )
    .unwrap();
    handle.flush().unwrap();
    drop(handle);
    ExactUsageIndex::reset_scan_bytes_for_testing();

    let refreshed = dashboard_snapshot(&root).unwrap();

    assert_eq!(refreshed.stats.total_tokens, 151);
    assert_eq!(refreshed.stats.total_calls, 2);
    let (full_bytes, append_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(full_bytes, fs::metadata(&file).unwrap().len());
    assert_eq!(
        append_bytes, 0,
        "the rolling audit must reject the append checkpoint before suffix parsing"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_stable_cold_scan_does_not_read_the_complete_prefix_twice() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_prefix_rehash_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019estable-prefix-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert_eq!(
        ExactUsageIndex::prefix_rehash_count_for_testing(),
        0,
        "stable files should trust the hash produced by the parsing pass"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_parallel_stages_large_cold_files() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let padding = vec![b'p'; EXACT_INDEX_CHUNK_SIZE as usize];
    let mut expected_total = 0_u64;
    for index in 0_u64..4 {
        let file = session_dir.join(format!(
            "rollout-019eparallel-{index:04}-0000-0000-exact.jsonl"
        ));
        let mut handle = std::io::BufWriter::new(fs::File::create(file).unwrap());
        handle.write_all(br#"{"padding":""#).unwrap();
        handle.write_all(&padding).unwrap();
        handle.write_all(b"\"}\n").unwrap();
        let total = 120 + index;
        expected_total += total;
        writeln!(
            handle,
            "{}",
            serde_json::json!({
                "timestamp": "2026-07-20T01:00:00Z",
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {
                            "input_tokens": 100 + index,
                            "cached_input_tokens": 20,
                            "output_tokens": 20,
                            "total_tokens": total
                        },
                        "last_token_usage": {
                            "input_tokens": 100 + index,
                            "cached_input_tokens": 20,
                            "output_tokens": 20,
                            "total_tokens": total
                        }
                    }
                }
            })
        )
        .unwrap();
        handle.flush().unwrap();
    }
    ExactUsageIndex::reset_stage_concurrency_for_testing(75);

    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();

    assert!(
        ExactUsageIndex::stage_peak_concurrency_for_testing() >= 2,
        "large cold files must be parsed by more than one staging worker"
    );
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        expected_total
    );
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_parallel_stage_uses_worker_open_boundary_without_second_owner() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let active_file = session_dir.join("rollout-019eprestage-active-0000-0000-exact.jsonl");
    let stable_file = session_dir.join("rollout-019eprestage-stable-0000-0000-exact.jsonl");
    let write_large_total = |file: &Path, padding: u8, total: u64| {
        let mut handle = std::io::BufWriter::new(fs::File::create(file).unwrap());
        handle.write_all(br#"{"padding":""#).unwrap();
        handle
            .write_all(&vec![padding; EXACT_INDEX_CHUNK_SIZE as usize])
            .unwrap();
        handle.write_all(b"\"}\n").unwrap();
        writeln!(
            handle,
            "{}",
            serde_json::json!({
                "timestamp": "2026-07-20T01:00:00Z",
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {
                            "input_tokens": total,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                            "total_tokens": total
                        },
                        "last_token_usage": {
                            "input_tokens": total,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                            "total_tokens": total
                        }
                    }
                }
            })
        )
        .unwrap();
        handle.flush().unwrap();
    };
    write_large_total(&active_file, b'a', 120);
    write_large_total(&stable_file, b's', 30);
    let active_start_size = fs::metadata(&active_file).unwrap().len();
    let stable_start_size = fs::metadata(&stable_file).unwrap().len();
    let appended_line = serde_json::json!({
        "timestamp": "2026-07-20T01:05:00Z",
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": 170,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 170
                },
                "last_token_usage": {
                    "input_tokens": 50,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 50
                }
            }
        }
    })
    .to_string();
    let appended_bytes = appended_line.len() as u64 + 1;
    ExactUsageIndex::set_before_staging_open_hook_for_testing(
        fs::canonicalize(&active_file).unwrap(),
        move |active_file| {
            let mut append = fs::OpenOptions::new()
                .append(true)
                .open(active_file)
                .unwrap();
            writeln!(append, "{appended_line}").unwrap();
            append.flush().unwrap();
        },
    );
    ExactUsageIndex::reset_stage_concurrency_for_testing(75);

    let first = dashboard_snapshot(&root).unwrap();
    assert_eq!(first.stats.total_tokens, 200);
    assert_eq!(first.stats.total_calls, 3);
    assert_eq!(first.stats.total_threads, 2);
    assert!(
        ExactUsageIndex::stage_peak_concurrency_for_testing() >= 2,
        "the active and stable large files must overlap in staging workers"
    );
    let (full_bytes, append_scan_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(
        full_bytes,
        active_start_size + appended_bytes + stable_start_size
    );
    assert_eq!(append_scan_bytes, 0);
    let mut first_index = ExactUsageIndex::open(&root).unwrap();
    assert!(
        !first_index.sources_changed(&root, &mut Vec::new()).unwrap(),
        "the worker-open formal boundary must include bytes appended before the file is opened"
    );
    drop(first_index);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    ExactUsageIndex::reset_stage_concurrency_for_testing(0);
    let second = dashboard_snapshot(&root).unwrap();
    assert_eq!(second.stats.total_tokens, 200);
    assert_eq!(second.stats.total_calls, 3);
    assert_eq!(second.stats.total_threads, 2);
    let (full_bytes, append_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(full_bytes, 0, "the no-op follow-up must not rebuild files");
    assert_eq!(
        append_bytes, 0,
        "the no-op follow-up must not reread JSONL tails"
    );
    let mut second_index = ExactUsageIndex::open(&root).unwrap();
    assert!(
        !second_index
            .sources_changed(&root, &mut Vec::new())
            .unwrap(),
        "the second generation must catch up completely"
    );
    drop(second_index);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_reuses_private_staging_after_an_interrupted_import() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let mut staging_path = index_path.as_os_str().to_os_string();
    staging_path.push(".staging");
    let staging_path = PathBuf::from(staging_path);
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019estage-recovery-0000-0000-exact.jsonl");
    let secret_question = "SECRET_STAGING_PROMPT_MUST_NOT_PERSIST_314159";
    let secret_answer = "SECRET_STAGING_ANSWER_MUST_NOT_PERSIST_271828";
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    writeln!(
        handle,
        r#"{{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{{"type":"user_message","message":"{secret_question}"}}}}"#
    )
    .unwrap();
    writeln!(
        handle,
        r#"{{"timestamp":"2026-07-20T01:00:20Z","type":"event_msg","payload":{{"type":"agent_message","message":"{secret_answer}"}}}}"#
    )
    .unwrap();
    handle.write_all(br#"{"padding":""#).unwrap();
    handle
        .write_all(&vec![b's'; EXACT_INDEX_CHUNK_SIZE as usize])
        .unwrap();
    handle.write_all(b"\"}\n").unwrap();
    writeln!(
        handle,
        "{}",
        serde_json::json!({
            "timestamp": "2026-07-20T01:01:00Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 20,
                        "total_tokens": 120
                    },
                    "last_token_usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 20,
                        "total_tokens": 120
                    }
                }
            }
        })
    )
    .unwrap();
    handle.flush().unwrap();
    drop(handle);

    ExactUsageIndex::fail_after_staging_once_for_testing();
    let mut interrupted = ExactUsageIndex::open(&root).unwrap();
    let error = interrupted.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("injected interruption"), "{error}");
    drop(interrupted);

    let mut inspected_stage = false;
    for entry in fs::read_dir(&staging_path).unwrap() {
        let path = entry.unwrap().path();
        if !path.is_file() {
            continue;
        }
        inspected_stage = true;
        let bytes = fs::read(path).unwrap();
        assert!(!bytes
            .windows(secret_question.len())
            .any(|window| window == secret_question.as_bytes()));
        assert!(!bytes
            .windows(secret_answer.len())
            .any(|window| window == secret_answer.as_bytes()));
    }
    assert!(
        inspected_stage,
        "the interrupted build must leave a durable stage"
    );
    let staged_database = fs::read_dir(&staging_path)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.is_file())
        .expect("the interrupted build must leave a staged database");
    let staged_connection = Connection::open(&staged_database).unwrap();
    assert_eq!(
        staged_connection
            .query_row(
                "SELECT parser_revision FROM manifest WHERE complete = 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        STAGED_FULL_REBUILD_PARSER_REVISION,
        "staged manifests must bind the exact parser semantics revision"
    );
    drop(staged_connection);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let mut resumed = ExactUsageIndex::open(&root).unwrap();
    resumed.sync(&root, &mut Vec::new()).unwrap();

    assert_eq!(
        ExactUsageIndex::scan_bytes_for_testing().0,
        0,
        "the retry must reuse the complete stage instead of rereading the source"
    );
    assert_eq!(
        resumed
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    assert!(
        !staging_path.exists(),
        "successful publication must remove stale staging databases"
    );
    drop(resumed);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rebuilds_staging_when_parser_revision_is_missing_or_mismatched() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    for (case_name, legacy_manifest) in [("legacy", true), ("mismatched", false)] {
        let root = temp_root();
        let session_dir = root.join("sessions");
        let index_path = root
            .join(".codex-token-bar-test-cache")
            .join("exact-token-index.sqlite3");
        fs::create_dir_all(&session_dir).unwrap();
        let file = session_dir.join(format!(
            "rollout-019estage-revision-{case_name}-0000-0000-exact.jsonl"
        ));
        let mut source = std::io::BufWriter::new(fs::File::create(&file).unwrap());
        source.write_all(br#"{"padding":""#).unwrap();
        source
            .write_all(&vec![b'p'; EXACT_INDEX_CHUNK_SIZE as usize])
            .unwrap();
        source.write_all(b"\"}\n").unwrap();
        writeln!(
            source,
            "{}",
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#
        )
        .unwrap();
        source.flush().unwrap();
        drop(source);

        ExactUsageIndex::fail_after_staging_once_for_testing();
        let mut interrupted = ExactUsageIndex::open(&root).unwrap();
        let error = interrupted.sync(&root, &mut Vec::new()).unwrap_err();
        assert!(error.contains("injected interruption"), "{error}");
        drop(interrupted);

        let mut staging_path = index_path.as_os_str().to_os_string();
        staging_path.push(".staging");
        let staging_path = PathBuf::from(staging_path);
        let staged_database = fs::read_dir(&staging_path)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| path.extension().and_then(|value| value.to_str()) == Some("sqlite3"))
            .expect("the interrupted build must leave a staged database");
        let staged_connection = Connection::open(&staged_database).unwrap();
        staged_connection
            .execute(
                "UPDATE events SET tokens = 999, input_tokens = 999, cached_input_tokens = 0, output_tokens = 999",
                [],
            )
            .unwrap();
        if legacy_manifest {
            staged_connection
                .execute_batch(
                    r#"
                    BEGIN IMMEDIATE;
                    ALTER TABLE manifest RENAME TO manifest_with_revision;
                    CREATE TABLE manifest (
                        complete INTEGER PRIMARY KEY CHECK(complete = 1),
                        path TEXT NOT NULL,
                        session_id TEXT NOT NULL,
                        size INTEGER NOT NULL,
                        modified_ns TEXT NOT NULL,
                        device_id TEXT NOT NULL,
                        file_id TEXT NOT NULL,
                        changed_ns TEXT NOT NULL,
                        prefix_sha256 BLOB NOT NULL,
                        resume_offset INTEGER NOT NULL,
                        previous_total_tokens INTEGER,
                        fork_replay_started_ns TEXT,
                        fork_replay_active INTEGER NOT NULL,
                        is_explicit_subagent_fork INTEGER NOT NULL,
                        last_skipped_fork_replay_token_ns TEXT,
                        current_model TEXT,
                        current_user_prompt_start INTEGER,
                        current_user_prompt_end INTEGER,
                        assistant_response_start INTEGER,
                        assistant_response_end INTEGER,
                        event_count INTEGER NOT NULL,
                        fingerprint_count INTEGER NOT NULL,
                        chunk_count INTEGER NOT NULL
                    ) WITHOUT ROWID;
                    INSERT INTO manifest(
                        complete,
                        path,
                        session_id,
                        size,
                        modified_ns,
                        device_id,
                        file_id,
                        changed_ns,
                        prefix_sha256,
                        resume_offset,
                        previous_total_tokens,
                        fork_replay_started_ns,
                        fork_replay_active,
                        is_explicit_subagent_fork,
                        last_skipped_fork_replay_token_ns,
                        current_model,
                        current_user_prompt_start,
                        current_user_prompt_end,
                        assistant_response_start,
                        assistant_response_end,
                        event_count,
                        fingerprint_count,
                        chunk_count
                    )
                    SELECT
                        complete,
                        path,
                        session_id,
                        size,
                        modified_ns,
                        device_id,
                        file_id,
                        changed_ns,
                        prefix_sha256,
                        resume_offset,
                        previous_total_tokens,
                        fork_replay_started_ns,
                        fork_replay_active,
                        is_explicit_subagent_fork,
                        last_skipped_fork_replay_token_ns,
                        current_model,
                        current_user_prompt_start,
                        current_user_prompt_end,
                        assistant_response_start,
                        assistant_response_end,
                        event_count,
                        fingerprint_count,
                        chunk_count
                    FROM manifest_with_revision;
                    DROP TABLE manifest_with_revision;
                    COMMIT;
                    "#,
                )
                .unwrap();
        } else {
            staged_connection
                .execute(
                    "UPDATE manifest SET parser_revision = ?1 WHERE complete = 1",
                    ["legacy-parser-revision"],
                )
                .unwrap();
        }
        drop(staged_connection);

        ExactUsageIndex::reset_scan_bytes_for_testing();
        let mut resumed = ExactUsageIndex::open(&root).unwrap();
        resumed.sync(&root, &mut Vec::new()).unwrap();
        assert!(
            ExactUsageIndex::scan_bytes_for_testing().0 > 0,
            "{case_name} staging must be rebuilt from the source"
        );
        assert_eq!(
            resumed
                .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
                .unwrap()
                .total_tokens,
            120,
            "{case_name} staging events must not be imported"
        );
        drop(resumed);
        assert!(
            !staging_path.exists(),
            "{case_name} staging and its sidecars must be removed after rebuild"
        );
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
#[ignore = "set CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST=1 for the local full-history scan"]
fn live_exact_index_cold_and_warm_scans_when_explicitly_enabled() {
    assert_eq!(
        std::env::var("CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST").as_deref(),
        Ok("1"),
        "set CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST=1"
    );
    let root = PathBuf::from(
        std::env::var("CODEX_TOKEN_BAR_LIVE_CODEX_HOME")
            .expect("CODEX_TOKEN_BAR_LIVE_CODEX_HOME must point to the frozen snapshot"),
    );
    assert!(root.join("sessions").is_dir(), "{}", root.display());
    let _test_state = app_paths::app_path_test_env_guard(&[]);

    let cold_started = Instant::now();
    let mut cold_index = ExactUsageIndex::open(&root).unwrap();
    let cold_revision = cold_index.sync(&root, &mut Vec::new()).unwrap();
    let cold = cold_index
        .dashboard_data(
            &root,
            OffsetDateTime::now_utc(),
            UtcOffset::UTC,
            &mut Vec::new(),
        )
        .unwrap();
    let cold_elapsed = cold_started.elapsed();
    println!(
        "LIVE_EXACT_INDEX_COLD_RESULT elapsed_seconds={:.3} revision={} total_tokens={} total_calls={} total_threads={}",
        cold_elapsed.as_secs_f64(),
        cold_revision,
        cold.stats.total_tokens,
        cold.stats.total_calls,
        cold.stats.total_threads
    );
    drop(cold_index);

    let warm_started = Instant::now();
    let mut warm_index = ExactUsageIndex::open(&root).unwrap();
    let warm_revision = warm_index.sync(&root, &mut Vec::new()).unwrap();
    let warm = warm_index
        .dashboard_data(
            &root,
            OffsetDateTime::now_utc(),
            UtcOffset::UTC,
            &mut Vec::new(),
        )
        .unwrap();
    let warm_elapsed = warm_started.elapsed();
    assert_eq!(warm_revision, cold_revision);
    assert_eq!(warm.stats.total_tokens, cold.stats.total_tokens);
    assert_eq!(warm.stats.total_calls, cold.stats.total_calls);
    assert_eq!(warm.stats.total_threads, cold.stats.total_threads);
    println!(
        "LIVE_EXACT_INDEX_WARM_RESULT elapsed_seconds={:.3} revision={} total_tokens={} total_calls={} total_threads={}",
        warm_elapsed.as_secs_f64(),
        warm_revision,
        warm.stats.total_tokens,
        warm.stats.total_calls,
        warm.stats.total_threads
    );
}

#[test]
fn exact_index_migrates_github_v6_and_v7_with_one_enrichment_pass() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019emigrate-v6-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T00:59:59Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":7,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    let before = connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM published_events), (SELECT COUNT(*) FROM published_files), (SELECT COUNT(*) FROM file_fingerprints ff JOIN published_files f ON f.generation = ff.file_generation AND f.path = ff.file_path), (SELECT COUNT(*) FROM file_chunks fc JOIN published_files f ON f.generation = fc.file_generation AND f.path = fc.file_path), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation')",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            },
        )
        .unwrap();
    drop(connection);

    for (legacy_version, missing_columns) in [
        (
            6_i64,
            vec![
                ("files", "current_model"),
                ("files", "is_explicit_subagent_fork"),
                ("events", "model"),
                ("events", "reasoning_output_tokens"),
            ],
        ),
        (
            7_i64,
            vec![
                ("files", "is_explicit_subagent_fork"),
                ("events", "reasoning_output_tokens"),
            ],
        ),
    ] {
        let connection = Connection::open(&index_path).unwrap();
        for (table, column) in missing_columns {
            connection
                .execute(&format!("ALTER TABLE {table} DROP COLUMN {column}"), [])
                .unwrap();
        }
        connection
            .execute(
                "UPDATE metadata SET value = ?1 WHERE key = 'schema_version'",
                [legacy_version],
            )
            .unwrap();
        connection
            .execute(
                "DELETE FROM metadata WHERE key = 'event_enrichment_revision'",
                [],
            )
            .unwrap();
        connection
            .execute("DELETE FROM event_enrichment_sources", [])
            .unwrap();
        connection
            .execute(
                "DELETE FROM metadata WHERE key = 'codex_home_physical_identity'",
                [],
            )
            .unwrap();
        let model_column_exists = connection
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('events') WHERE name = 'model'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
            > 0;
        if model_column_exists {
            connection
                .execute("UPDATE events SET model = NULL", [])
                .unwrap();
        }
        drop(connection);

        ExactUsageIndex::reset_scan_bytes_for_testing();
        let structural = ExactUsageIndex::open(&root).unwrap();
        drop(structural);
        assert_eq!(
            ExactUsageIndex::scan_bytes_for_testing(),
            (0, 0),
            "v{legacy_version} structural migration must not read JSONL bodies"
        );
        let structurally_migrated = Connection::open(&index_path).unwrap();
        assert!(
            structurally_migrated
                .query_row(
                    "SELECT value FROM metadata WHERE key = 'codex_home_physical_identity'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .unwrap()
                .len()
                > 0,
            "the public legacy index must bind its missing physical Home identity in place"
        );
        assert_eq!(
            structurally_migrated
                .query_row(
                    "SELECT value FROM metadata WHERE key = 'schema_version'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            legacy_version.to_string(),
            "the final schema marker must wait for historical enrichment"
        );
        assert_eq!(
            structurally_migrated
                .query_row(
                    "SELECT model, reasoning_output_tokens FROM published_events",
                    [],
                    |row| Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<i64>>(1)?
                    )),
                )
                .unwrap(),
            (None, None),
            "structure-only migration must preserve unknown historical fields as NULL"
        );
        drop(structurally_migrated);

        ExactUsageIndex::reset_scan_bytes_for_testing();
        assert_eq!(
            dashboard_snapshot(&root).unwrap().stats.total_tokens,
            120,
            "v{legacy_version} migration must leave the published dashboard immediately readable"
        );
        let (full_scan_bytes, append_scan_bytes) = ExactUsageIndex::scan_bytes_for_testing();
        assert_eq!(append_scan_bytes, 0);
        assert_eq!(
            full_scan_bytes,
            fs::metadata(&file).unwrap().len(),
            "v{legacy_version} must enrich the old published watermark exactly once"
        );
        let connection = Connection::open(&index_path).unwrap();
        let after = connection
            .query_row(
                "SELECT (SELECT COUNT(*) FROM published_events), (SELECT COUNT(*) FROM published_files), (SELECT COUNT(*) FROM file_fingerprints ff JOIN published_files f ON f.generation = ff.file_generation AND f.path = ff.file_path), (SELECT COUNT(*) FROM file_chunks fc JOIN published_files f ON f.generation = fc.file_generation AND f.path = fc.file_path), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation')",
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(
            (after.0, after.1, after.2, after.3),
            (before.0, before.1, before.2, before.3),
            "v{legacy_version} migration changed published event/file identity"
        );
        assert!(
            after.4 > before.4,
            "enrichment must publish one new generation"
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT value FROM metadata WHERE key = 'schema_version'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "9"
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT value FROM metadata WHERE key = 'event_enrichment_revision'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "model-reasoning-v1"
        );
        assert_eq!(
            connection
                .query_row("SELECT model FROM published_events", [], |row| {
                    row.get::<_, Option<String>>(0)
                })
                .unwrap(),
            Some("gpt-5.6-sol".into())
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT reasoning_output_tokens FROM published_events",
                    [],
                    |row| row.get::<_, Option<i64>>(0),
                )
                .unwrap(),
            Some(7)
        );
        for (table, column) in [
            ("files", "current_model"),
            ("files", "is_explicit_subagent_fork"),
            ("events", "model"),
            ("events", "reasoning_output_tokens"),
        ] {
            let exists = connection
                .query_row(
                    &format!(
                        "SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = '{column}'"
                    ),
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap();
            assert_eq!(
                exists, 1,
                "v{legacy_version} migration must add {table}.{column}"
            );
        }
        drop(connection);

        ExactUsageIndex::reset_scan_bytes_for_testing();
        assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
        assert_eq!(
            ExactUsageIndex::scan_bytes_for_testing(),
            (0, 0),
            "completed enrichment must not reread historical JSONL"
        );
    }

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_enrichment_publishes_an_appended_tail_in_the_same_snapshot() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eenrichment-tail-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T00:59:59Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":7,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN model", [])
        .unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN reasoning_output_tokens", [])
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '6' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'event_enrichment_revision'",
            [],
        )
        .unwrap();
    connection
        .execute("DELETE FROM event_enrichment_sources", [])
        .unwrap();
    drop(connection);
    let published_prefix_size = fs::metadata(&file).unwrap().len();

    let appended = r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}"#;
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(handle, "{appended}").unwrap();
    drop(handle);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let refreshed = dashboard_snapshot(&root).unwrap();
    assert_eq!(refreshed.stats.total_tokens, 170);
    let (full_scan_bytes, append_scan_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(
        full_scan_bytes,
        published_prefix_size,
        "enrichment must read the old published prefix once"
    );
    assert!(append_scan_bytes > 0, "the same owner must publish the appended tail");

    ExactUsageIndex::reset_scan_bytes_for_testing();
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 170);
    assert_eq!(
        ExactUsageIndex::scan_bytes_for_testing(),
        (0, 0),
        "the next dashboard refresh must not reread the published body"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_event_enrichment_resumes_private_staging_without_reread() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eenrichment-resume.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T00:59:59Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":9,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN model", [])
        .unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN reasoning_output_tokens", [])
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '6' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'event_enrichment_revision'",
            [],
        )
        .unwrap();
    connection
        .execute("DELETE FROM event_enrichment_sources", [])
        .unwrap();
    drop(connection);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let mut interrupted = ExactUsageIndex::open(&root).unwrap();
    ExactUsageIndex::fail_after_staging_once_for_testing();
    let error = interrupted.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("injected interruption"), "{error}");
    assert_eq!(
        ExactUsageIndex::scan_bytes_for_testing(),
        (fs::metadata(&file).unwrap().len(), 0)
    );
    drop(interrupted);

    let interrupted_database = Connection::open(&index_path).unwrap();
    assert_eq!(
        interrupted_database
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "6"
    );
    assert_eq!(
        interrupted_database
            .query_row(
                "SELECT COALESCE(SUM(tokens), 0) FROM published_events",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        120
    );
    drop(interrupted_database);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let mut resumed = ExactUsageIndex::open(&root).unwrap();
    resumed.sync(&root, &mut Vec::new()).unwrap();
    assert_eq!(
        ExactUsageIndex::scan_bytes_for_testing(),
        (0, 0),
        "the durable private stage must be reused after interruption"
    );
    drop(resumed);

    let completed = Connection::open(&index_path).unwrap();
    assert_eq!(
        completed
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "9"
    );
    assert_eq!(
        completed
            .query_row("SELECT model FROM published_events", [], |row| {
                row.get::<_, Option<String>>(0)
            })
            .unwrap(),
        Some("gpt-5.6-luna".into())
    );
    assert_eq!(
        completed
            .query_row(
                "SELECT reasoning_output_tokens FROM published_events",
                [],
                |row| row.get::<_, Option<i64>>(0),
            )
            .unwrap(),
        Some(9)
    );
    drop(completed);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_event_enrichment_resumes_a_durable_missing_source_tombstone() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eenrichment-missing-resume.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T00:59:59Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"reasoning_output_tokens":9,"total_tokens":100}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 100);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN model", [])
        .unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN reasoning_output_tokens", [])
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '6' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'event_enrichment_revision'",
            [],
        )
        .unwrap();
    connection
        .execute("DELETE FROM event_enrichment_sources", [])
        .unwrap();
    let published_before = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    drop(connection);
    let canonical_file = fs::canonicalize(&file).unwrap();
    fs::remove_file(&file).unwrap();

    let mut interrupted = ExactUsageIndex::open(&root).unwrap();
    ExactUsageIndex::fail_after_staging_once_for_testing();
    let error = interrupted.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("injected interruption"), "{error}");
    drop(interrupted);

    let interrupted_database = Connection::open(&index_path).unwrap();
    let building = interrupted_database
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'building_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert!(building > published_before);
    assert_eq!(
        interrupted_database
            .query_row(
                "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        published_before,
        "the interrupted enrichment must keep the previous published selector"
    );
    assert_eq!(
        interrupted_database
            .query_row(
                "SELECT COALESCE(SUM(tokens), 0) FROM published_events",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        100,
        "the previous complete generation must stay readable until resume publishes"
    );
    assert_eq!(
        interrupted_database
            .query_row(
                "SELECT deleted FROM files WHERE generation = ?1 AND path = ?2",
                params![building, canonical_file.to_string_lossy().as_ref()],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1,
        "the missing source tombstone must be durable before publication"
    );
    assert_eq!(
        interrupted_database
            .query_row(
                "SELECT file_generation FROM event_enrichment_sources WHERE path = ?1 AND revision = 'model-reasoning-v1'",
                [canonical_file.to_string_lossy().as_ref()],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        building,
        "the enrichment receipt must point at the durable tombstone generation"
    );
    drop(interrupted_database);

    let mut resumed = ExactUsageIndex::open(&root).unwrap();
    resumed.sync(&root, &mut Vec::new()).unwrap();
    drop(resumed);

    let completed = Connection::open(&index_path).unwrap();
    assert_eq!(
        completed
            .query_row("SELECT COUNT(*) FROM published_events", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0,
        "resume must publish the durable tombstone instead of resurrecting the missing source"
    );
    assert_eq!(
        completed
            .query_row(
                "SELECT value FROM metadata WHERE key = 'event_enrichment_revision'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "model-reasoning-v1"
    );
    drop(completed);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn event_enrichment_keeps_the_previous_published_generation_until_every_source_completes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let first = session_dir.join("rollout-019eenrichment-atomic-a.jsonl");
    let second = session_dir.join("rollout-019eenrichment-atomic-b.jsonl");
    let first_lines = [
        r#"{"timestamp":"2026-07-20T00:59:59Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"reasoning_output_tokens":7,"total_tokens":100}}}}"#,
    ];
    let second_lines = [
        r#"{"timestamp":"2026-07-20T01:00:59Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
        r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"reasoning_output_tokens":9,"total_tokens":50}}}}"#,
    ];
    write_lines(&first, &first_lines);
    write_lines(&second, &second_lines);
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN model", [])
        .unwrap();
    connection
        .execute("ALTER TABLE events DROP COLUMN reasoning_output_tokens", [])
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '6' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'event_enrichment_revision'",
            [],
        )
        .unwrap();
    connection
        .execute("DELETE FROM event_enrichment_sources", [])
        .unwrap();
    let published_before = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    drop(connection);

    let canonical_second = fs::canonicalize(&second).unwrap();
    ExactUsageIndex::set_before_staging_open_hook_for_testing(canonical_second, |path| {
        fs::remove_file(path).unwrap();
    });
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let revision_before = index.revision().unwrap();
    assert_eq!(index.sync(&root, &mut Vec::new()).unwrap(), revision_before);
    let progress = precise_dashboard_progress(&root);
    assert_eq!(progress.phase, "backfillingModel");
    assert_eq!(progress.completed, 1);
    assert_eq!(progress.total, Some(2));

    let interrupted = Connection::open(&index_path).unwrap();
    assert_eq!(
        interrupted
            .query_row(
                "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        published_before,
        "partial enrichment must not advance the published selector"
    );
    assert_eq!(
        interrupted
            .query_row(
                "SELECT COALESCE(SUM(tokens), 0) FROM published_events",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        150,
        "readers must keep the complete previous generation"
    );
    assert_eq!(
        interrupted
            .query_row(
                "SELECT COUNT(*) FROM event_enrichment_sources WHERE revision = 'model-reasoning-v1'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1,
        "the completed source receipt must remain durable for resume"
    );
    assert_eq!(
        interrupted
            .query_row(
                "SELECT COUNT(*) FROM metadata WHERE key = 'event_enrichment_revision'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    drop(interrupted);

    write_lines(&second, &second_lines);
    assert!(index.sync(&root, &mut Vec::new()).unwrap() > revision_before);
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        150
    );
    drop(index);
    let completed = Connection::open(&index_path).unwrap();
    assert_eq!(
        completed
            .query_row(
                "SELECT value FROM metadata WHERE key = 'event_enrichment_revision'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "model-reasoning-v1"
    );
    drop(completed);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_refuses_unknown_future_schema_without_overwriting_it() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efuture-schema-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    let before = connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM files), (SELECT COUNT(*) FROM file_fingerprints), (SELECT COUNT(*) FROM file_chunks), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation')",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            },
        )
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '999' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    drop(connection);

    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("future schema must fail closed"),
        Err(error) => error,
    };
    assert!(error.contains("高于当前支持版本"), "{error}");
    let connection = Connection::open(&index_path).unwrap();
    let after = connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM files), (SELECT COUNT(*) FROM file_fingerprints), (SELECT COUNT(*) FROM file_chunks), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation')",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(after, before);
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "999"
    );
    drop(connection);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = 'future-v9' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    drop(connection);
    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("non-numeric future schema must fail closed"),
        Err(error) => error,
    };
    assert!(error.contains("未知或损坏"), "{error}");
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "future-v9"
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn confirmed_future_index_rebuild_removes_only_tauri_derived_storage() {
    let root = temp_root();
    let aggregate_cache = root.join("tauri-derived").join("dashboard-aggregate.json");
    let _test_state = app_paths::app_path_test_env_guard(&[(
        "CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH",
        aggregate_cache.clone(),
    )]);
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let raw_jsonl = session_dir.join("rollout-rebuild-boundary.jsonl");
    write_lines(
        &raw_jsonl,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    let state_db = root.join("state_5.sqlite");
    let settings = root.join("settings.json");
    let quota = root.join("quota-history.sqlite");
    let radar = root.join("radar-cache.json");
    for path in [&state_db, &settings, &quota, &radar] {
        fs::write(path, b"must-survive").unwrap();
    }

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let index_path = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '999' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    drop(connection);

    let mut staging_name = index_path.as_os_str().to_os_string();
    staging_name.push(".staging");
    let staging = PathBuf::from(staging_name);
    fs::create_dir_all(&staging).unwrap();
    fs::write(staging.join("ready.sqlite3"), b"derived").unwrap();
    let receipt = integrity_receipt_path_for_testing(&root).unwrap();
    fs::write(&receipt, b"derived receipt").unwrap();

    let upgrade = precise_index_upgrade_required(&root)
        .expect("read-only assessment")
        .expect("future schema should require upgrade");
    assert_eq!(upgrade.stored, "999");
    rebuild_precise_index_for_current_version(&root).unwrap();

    assert!(!index_path.exists());
    assert!(!staging.exists());
    assert!(!receipt.exists());
    assert!(!aggregate_cache.exists(), "bound numeric cache is derived");
    for path in [&raw_jsonl, &state_db, &settings, &quota, &radar] {
        assert!(
            path.exists(),
            "source/user data must survive: {}",
            path.display()
        );
    }
    assert_eq!(fs::read(&raw_jsonl).unwrap().is_empty(), false);
    for path in [&state_db, &settings, &quota, &radar] {
        assert_eq!(fs::read(path).unwrap(), b"must-survive");
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_refuses_unknown_event_enrichment_revision_before_migration_writes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019efuture-enrichment.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    let before = connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM files), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation')",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?)),
        )
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = 'model-reasoning-v999' WHERE key = 'event_enrichment_revision'",
            [],
        )
        .unwrap();
    drop(connection);

    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("unknown enrichment revision must fail closed"),
        Err(error) => error,
    };
    assert!(error.contains("历史字段补全版本"), "{error}");
    assert!(error.contains("已拒绝覆盖"), "{error}");

    let connection = Connection::open(&index_path).unwrap();
    let after = connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM files), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation')",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?)),
        )
        .unwrap();
    assert_eq!(after, before);
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'event_enrichment_revision'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "model-reasoning-v999"
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_restores_a_missing_marker_for_the_known_session_catalog_shape() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eknown-unmarked-catalog.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "INSERT OR REPLACE INTO session_catalog_files(path, archived, thread_id, cwd, source, session_id, forked_from_id, parent_thread_id, size, modified_ns, created_ns, modified_at, created_at, stat_device_id, stat_file_id, stat_changed_ns, device_id, file_id, changed_ns, first_line_bytes, first_line_sha256, last_seen_generation) VALUES (?1, 0, 'known-thread', '/known', 'known', NULL, NULL, NULL, 0, '0', '0', NULL, NULL, 'known-device', 'known-file', '0', 'known-device', 'known-file', '0', 0, X'00', 7)",
            ["/known/catalog.jsonl"],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'session_catalog_schema_version'",
            [],
        )
        .unwrap();
    drop(connection);

    let index = ExactUsageIndex::open(&root).unwrap();
    drop(index);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'session_catalog_schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "1"
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT thread_id FROM session_catalog_files WHERE path = '/known/catalog.jsonl'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "known-thread"
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_refuses_unmarked_unknown_session_catalog_shape_without_dropping_it() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eunmarked-future-catalog.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "ALTER TABLE session_catalog_files ADD COLUMN future_marker TEXT",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE session_catalog_files SET future_marker = 'keep-me'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'session_catalog_schema_version'",
            [],
        )
        .unwrap();
    drop(connection);

    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("an unmarked unknown catalog shape must fail closed"),
        Err(error) => error,
    };
    assert!(error.contains("缺少 schema 标记"), "{error}");
    assert!(error.contains("已拒绝删除或覆盖"), "{error}");

    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('session_catalog_files') WHERE name = 'future_marker'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_refuses_future_session_catalog_without_dropping_table_or_rows() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019efuture-catalog-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "ALTER TABLE session_catalog_files ADD COLUMN future_marker TEXT",
            [],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO session_catalog_files(path, archived, thread_id, cwd, source, session_id, forked_from_id, parent_thread_id, size, modified_ns, created_ns, modified_at, created_at, stat_device_id, stat_file_id, stat_changed_ns, device_id, file_id, changed_ns, first_line_bytes, first_line_sha256, last_seen_generation, future_marker) VALUES (?1, 0, 'future-thread', '/future', 'future', NULL, NULL, NULL, 0, '0', '0', NULL, NULL, 'future-device', 'future-file', '0', 'future-device', 'future-file', '0', 0, X'00', 0, 'keep-me')",
            ["/future/catalog.jsonl"],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '999' WHERE key = 'session_catalog_schema_version'",
            [],
        )
        .unwrap();
    drop(connection);

    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("future session catalog must fail closed"),
        Err(error) => error,
    };
    assert!(error.contains("会话目录 schema 版本"), "{error}");
    assert!(error.contains("高于当前支持版本"), "{error}");

    let connection = Connection::open(&index_path).unwrap();
    let future_column = connection
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('session_catalog_files') WHERE name = 'future_marker'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(future_column, 1);
    assert_eq!(
        connection
            .query_row(
                "SELECT future_marker FROM session_catalog_files WHERE path = '/future/catalog.jsonl'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "keep-me"
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'session_catalog_schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "999"
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_migration_marks_only_explicit_replay_for_targeted_replacement() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019etargeted-replay-0000-0000-luna.jsonl");
    let unrelated_file = session_dir.join("rollout-019etargeted-replay-0000-0000-other.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"id":"019etargeted-replay-0000-0000-luna","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker","agent_path":"/root/luna_worker","source":{"subagent":{"thread_spawn":{"parent_thread_id":"origin-session","agent_role":"luna_worker"}}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120},"last_token_usage":{"total_tokens":120}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:03.600Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":180},"last_token_usage":{"total_tokens":60}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":260},"last_token_usage":{"total_tokens":80}}}}"#,
        ],
    );
    write_lines(
        &unrelated_file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":25}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 165);

    let relative_file = fs::canonicalize(&file).unwrap().display().to_string();
    let relative_unrelated_file = fs::canonicalize(&unrelated_file)
        .unwrap()
        .display()
        .to_string();

    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM events", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        3
    );
    connection
        .execute(
            "DELETE FROM events WHERE file_path = ?1 AND tokens = 60",
            params![relative_file],
        )
        .unwrap();
    let before = connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM file_fingerprints), (SELECT COUNT(*) FROM file_chunks), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'), (SELECT changed_ns FROM files WHERE deleted = 0 LIMIT 1)",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, String>(4)?,
                ))
            },
        )
        .unwrap();
    let unrelated_checkpoint_before = connection
        .query_row(
            "SELECT append_ready, resume_offset FROM files WHERE path = ?1 AND deleted = 0 ORDER BY generation DESC LIMIT 1",
            params![relative_unrelated_file],
            |row| Ok((row.get::<_, bool>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '6' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE files SET fork_replay_active = 1, is_explicit_subagent_fork = 0 WHERE path = ?1",
            params![relative_file],
        )
        .unwrap();
    drop(connection);

    let mut migrated = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(
        migrated
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        105
    );
    let connection = Connection::open(&index_path).unwrap();
    let after = connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM file_fingerprints), (SELECT COUNT(*) FROM file_chunks), (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'), (SELECT is_explicit_subagent_fork FROM files WHERE path = ?1 AND deleted = 0 LIMIT 1), (SELECT append_ready FROM files WHERE path = ?1 AND deleted = 0 LIMIT 1), (SELECT resume_offset FROM files WHERE path = ?1 AND deleted = 0 LIMIT 1), (SELECT changed_ns FROM files WHERE path = ?1 AND deleted = 0 LIMIT 1)",
            params![relative_file],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, bool>(4)?,
                    row.get::<_, bool>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                    row.get::<_, String>(7)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(after.0, before.0);
    assert_eq!(after.1, before.1);
    assert_eq!(after.2, before.2);
    assert_eq!(after.3, before.3);
    assert!(after.4);
    assert!(!after.5);
    assert_eq!(after.6, None);
    assert!(after.7.starts_with("migration:"));
    drop(connection);

    assert_eq!(
        migrated
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        105
    );
    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            "{}",
            r#"{"timestamp":"2026-06-18T01:00:07Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300},"last_token_usage":{"total_tokens":40}}}}"#
        )
        .unwrap();
    }
    assert_eq!(
        migrated
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        105
    );
    ExactUsageIndex::reset_scan_bytes_for_testing();
    migrated.sync(&root, &mut Vec::new()).unwrap();
    let (full_scan_bytes, append_scan_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert!(full_scan_bytes > 0);
    assert_eq!(append_scan_bytes, 0);
    assert_eq!(
        migrated
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        205
    );
    let connection = Connection::open(&index_path).unwrap();
    let explicit_tokens = connection
        .prepare("SELECT tokens FROM published_events WHERE file_path = ?1 ORDER BY ordinal")
        .unwrap()
        .query_map(params![relative_file], |row| row.get::<_, i64>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(explicit_tokens, vec![60, 80, 40]);
    let unrelated_tokens = connection
        .prepare("SELECT tokens FROM published_events WHERE file_path = ?1 ORDER BY ordinal")
        .unwrap()
        .query_map(params![relative_unrelated_file], |row| row.get::<_, i64>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(unrelated_tokens, vec![25]);
    let unrelated_checkpoint_after = connection
        .query_row(
            "SELECT append_ready, resume_offset FROM files WHERE path = ?1 AND deleted = 0 ORDER BY generation DESC LIMIT 1",
            params![relative_unrelated_file],
            |row| Ok((row.get::<_, bool>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .unwrap();
    assert_eq!(unrelated_checkpoint_after, unrelated_checkpoint_before);
    drop(connection);
    drop(migrated);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_retries_unresolved_replay_candidate_without_persisting_marker() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019ereplay-retry-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '6' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE files SET fork_replay_active = 1, is_explicit_subagent_fork = 0",
            [],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'fork_replay_boundary_revision'",
            [],
        )
        .unwrap();
    drop(connection);

    let mut oversized_first_line = String::from(
        r#"{"type":"session_meta","payload":{"forked_from_id":"origin-session","agent_path":""#,
    );
    oversized_first_line.push_str(&"x".repeat(256 * 1024));
    oversized_first_line.push_str("\"}");
    fs::write(&file, oversized_first_line).unwrap();

    let unresolved = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(
        unresolved
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM metadata WHERE key = 'fork_replay_boundary_revision'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT is_explicit_subagent_fork FROM files WHERE deleted = 0 LIMIT 1",
                [],
                |row| row.get::<_, bool>(0),
            )
            .unwrap(),
        false
    );
    drop(connection);

    let valid_first_line = r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"id":"019ereplay-retry-0000-0000-exact","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker"}}"#;
    fs::write(&file, format!("{valid_first_line}\n")).unwrap();
    let retried = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(
        retried
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT is_explicit_subagent_fork FROM files WHERE deleted = 0 LIMIT 1",
                [],
                |row| row.get::<_, bool>(0),
            )
            .unwrap(),
        true
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'fork_replay_boundary_revision'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "explicit-subagent-delayed-context-v3"
    );
    drop(connection);
    drop(retried);
    drop(unresolved);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn snapshots_differing_only_in_reasoning_tokens_are_distinct_events() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ereasoning-fp-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":120}}}}"#,
            r#"{"timestamp":"2026-07-20T01:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":7,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":7,"total_tokens":120}}}}"#,
        ],
    );

    // 跨端契约（review §3.10 4a）：与 Swift 的 11 字段指纹对齐，仅 reasoning 不同
    // 的两条 snapshot 是两次独立计费；9 字段指纹会把第二条误判为重放丢弃。
    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 240);
    assert_eq!(snapshot.stats.total_calls, 2);

    let index_path = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(index_path).unwrap();
    let reasoning = connection
        .prepare("SELECT reasoning_output_tokens FROM published_events ORDER BY ordinal")
        .unwrap()
        .query_map([], |row| row.get::<_, Option<i64>>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(reasoning, vec![Some(0), Some(7)]);

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn fork_replay_exit_grace_boundary_requires_strictly_more_than_two_seconds() {
    // 跨端契约（review §3.10 4b）：恰好等于 2s 宽限的 user_message 仍视为重放，
    // 严格大于 2s 才退出（两端统一为 >，Swift 端同界测试对应修改）。
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();

    let at_boundary = session_dir.join("rollout-019efork-grace-at-0000-0000-exact.jsonl");
    write_lines(
        &at_boundary,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500},"last_token_usage":{"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:12Z","type":"event_msg","payload":{"type":"user_message","message":"恰在宽限边界的提问"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:13Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":620},"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &at_boundary,
        "019efork-grace-at-0000-0000-exact",
        &mut warnings,
    );
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        0,
        "恰好 2s 仍在宽限内，必须继续按重放跳过"
    );
    assert!(parsed.fork_replay_active);

    let past_boundary = session_dir.join("rollout-019efork-grace-past-0000-0000-exact.jsonl");
    write_lines(
        &past_boundary,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500},"last_token_usage":{"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:12.001Z","type":"event_msg","payload":{"type":"user_message","message":"刚越过宽限边界的提问"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:13Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":620},"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    let parsed = parse_session_file_full_result(
        &past_boundary,
        "019efork-grace-past-0000-0000-exact",
        &mut warnings,
    );
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        120,
        "超过 2s 必须退出重放并正常计费"
    );
    assert!(!parsed.fork_replay_active);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_cold_scan_resumes_committed_files_without_publishing_partial_totals() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eresume-a-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &session_dir.join("rollout-019eresume-b-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );

    let committed_path = Arc::new(Mutex::new(None::<PathBuf>));
    let committed_path_for_hook = Arc::clone(&committed_path);
    ExactUsageIndex::set_after_file_commit_hook_for_testing(move |path| {
        *committed_path_for_hook.lock().unwrap() = Some(path.to_path_buf());
        Err("injected interruption after durable file commit".into())
    });
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let initial_revision = index.revision().unwrap();
    let error = index.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("injected interruption"), "{error}");
    drop(index);

    let connection = Connection::open(&index_path).unwrap();
    let building_generation = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'building_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM files WHERE generation = ?1 AND deleted = 0",
                [building_generation],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1,
        "the completed file must be durable before the full generation publishes"
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM published_events", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0,
        "cold-start readers must not see staged event rows"
    );
    drop(connection);

    let index = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(index.revision().unwrap(), initial_revision);
    assert!(index.is_empty().unwrap());
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        0
    );
    drop(index);
    assert!(cached_dashboard_usage_summary(&root).is_none());

    let resumed_parse = Arc::new(Mutex::new(None::<PathBuf>));
    let resumed_parse_for_hook = Arc::clone(&resumed_parse);
    ExactUsageIndex::set_after_prefix_scan_hook_for_testing(move |path| {
        *resumed_parse_for_hook.lock().unwrap() = Some(path.to_path_buf());
    });
    let mut resumed = ExactUsageIndex::open(&root).unwrap();
    let completed_revision = resumed.sync(&root, &mut Vec::new()).unwrap();
    assert!(completed_revision > initial_revision);
    assert_eq!(
        resumed
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        150
    );
    assert!(resumed_parse.lock().unwrap().is_some());
    assert!(committed_path.lock().unwrap().is_some());
    assert_ne!(
        resumed_parse.lock().unwrap().as_ref(),
        committed_path.lock().unwrap().as_ref(),
        "resume must skip the file whose current signature was already committed"
    );
    let connection = Connection::open(&index_path).unwrap();
    assert!(connection
        .query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM metadata WHERE key = 'building_generation')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .unwrap());
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM published_files", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        2
    );
    drop(connection);
    drop(resumed);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_resumed_building_generation_appends_without_full_rescan() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eresume-append-0000-0000-0000-exact.jsonl");
    // 超过一个 4 MiB 块的大文件，让"整文件重扫 vs 尾块追加"在扫描字节数上可区分。
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    handle.write_all(br#"{"padding":""#).unwrap();
    let padding = vec![b'x'; 1024 * 1024];
    for _ in 0..12 {
        handle.write_all(&padding).unwrap();
    }
    handle.write_all(b"\"}\n").unwrap();
    handle
        .write_all(
            br#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        )
        .unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);

    // 第一轮：该文件提交后注入中断，building 代次带着本代次内的追加检查点留在原地。
    ExactUsageIndex::set_after_file_commit_hook_for_testing(|_| {
        Err("injected interruption after durable file commit".into())
    });
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let error = index.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("injected interruption"), "{error}");

    // 追加少量数据后复用同一 building 代次续扫：检查点代次 == 当前代次。
    let appended = br#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#;
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    handle.write_all(appended).unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    index.sync(&root, &mut Vec::new()).unwrap();
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        150
    );
    let (full_bytes, append_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(full_bytes, 0, "恢复代次内的纯追加不得退化为整文件重扫");
    assert!(
        append_bytes > 0 && append_bytes <= EXACT_INDEX_CHUNK_SIZE + appended.len() as u64 + 1,
        "append parser read {append_bytes} bytes instead of one tail chunk plus the suffix"
    );
    drop(index);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_installs_the_published_summary_covering_index() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-covering-index-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    drop(index);

    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let connection = Connection::open(index_path).unwrap();
    let columns = connection
        .prepare("PRAGMA index_info('events_file_summary_idx')")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(2))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(
        columns,
        ["file_generation", "file_path", "timestamp", "tokens"],
        "the status summary must stay on a semantics-preserving covering index"
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn p1_1_noop_sync_does_not_allocate_generation_revision_or_wal() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ep1-noop-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let wal_path = index_path.with_extension("sqlite3-wal");
    let connection = Connection::open(&index_path).unwrap();
    let read_state = |connection: &Connection| {
        connection
            .query_row(
                r#"
                SELECT
                    CAST((SELECT value FROM metadata WHERE key = 'revision') AS INTEGER),
                    CAST((SELECT value FROM metadata WHERE key = 'published_generation') AS INTEGER),
                    CAST((SELECT value FROM metadata WHERE key = 'building_generation') AS INTEGER),
                    (SELECT COALESCE(MAX(generation), 0) FROM files),
                    (SELECT COUNT(*) FROM files),
                    (SELECT COUNT(*) FROM events),
                    (SELECT COUNT(*) FROM dashboard_file_totals),
                    (SELECT COUNT(*) FROM dashboard_file_5m),
                    (SELECT COUNT(*) FROM dashboard_5m),
                    (SELECT COUNT(*) FROM dashboard_turn_candidates)
                "#,
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Option<i64>>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, i64>(8)?,
                        row.get::<_, i64>(9)?,
                    ))
                },
            )
            .unwrap()
    };
    let before = read_state(&connection);
    let wal_before = fs::read(&wal_path).ok();

    let revision = index.sync(&root, &mut Vec::new()).unwrap();

    assert_eq!(revision, u64::try_from(before.0).unwrap());
    assert_eq!(read_state(&connection), before);
    assert_eq!(fs::read(&wal_path).ok(), wal_before);

    drop(connection);
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn p1_4_failed_thread_metadata_staging_keeps_published_rows_and_signature() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019ep1-metadata-failure-0000-0000-000000000001";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    create_state_database(
        &root,
        session_id,
        "019ep1-metadata-other-0000-0000-000000000002",
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let read_published_metadata = |connection: &Connection| {
        let rows = connection
            .prepare(
                "SELECT session_id, title, updated_at FROM session_metadata ORDER BY session_id",
            )
            .unwrap()
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        rows
    };
    let connection = Connection::open(&index_path).unwrap();
    let before_revision = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'revision'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    let before_signature = connection
        .query_row(
            "SELECT (SELECT value FROM metadata WHERE key = 'state_size'), (SELECT value FROM metadata WHERE key = 'state_modified_ns')",
            [],
            |row| Ok((row.get::<_, Option<String>>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .unwrap();
    let before_metadata = read_published_metadata(&connection);
    let wal_path = index_path.with_extension("sqlite3-wal");
    let wal_before = fs::read(&wal_path).ok();

    // Keep a valid SQLite container so source discovery can still prove that
    // there are no active rollout paths, but omit the columns required by the
    // metadata reader. The read-only staging must fail before touching the
    // published rows or their state signature.
    let state_database = root.join("state_5.sqlite");
    fs::remove_file(&state_database).unwrap();
    let malformed = Connection::open(&state_database).unwrap();
    malformed
        .execute_batch("CREATE TABLE threads (id TEXT PRIMARY KEY);")
        .unwrap();
    drop(malformed);

    let mut warnings = Vec::new();
    let revision = index.sync(&root, &mut warnings).unwrap();
    assert_eq!(revision, u64::try_from(before_revision).unwrap());
    assert!(warnings.iter().any(|warning| {
        warning.source == "thread_info" && warning.message.contains("读取会话标题索引结构失败")
    }));

    let after_revision = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'revision'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    let after_signature = connection
        .query_row(
            "SELECT (SELECT value FROM metadata WHERE key = 'state_size'), (SELECT value FROM metadata WHERE key = 'state_modified_ns')",
            [],
            |row| Ok((row.get::<_, Option<String>>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .unwrap();
    assert_eq!(after_revision, before_revision);
    assert_eq!(after_signature, before_signature);
    assert_eq!(read_published_metadata(&connection), before_metadata);
    assert_eq!(fs::read(&wal_path).ok(), wal_before);

    drop(connection);
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_interrupted_refresh_keeps_the_previous_complete_revision_and_aggregate() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let original_file = session_dir.join("rollout-019epublished-a-0000-0000-0000-exact.jsonl");
    write_lines(
        &original_file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let published_revision = ExactUsageIndex::open(&root).unwrap().revision().unwrap();
    let read_attribution_state = || {
        let connection = Connection::open(&index_path).unwrap();
        let epoch = connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'attribution_provenance_epoch'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        let tokens = connection
            .query_row(
                "SELECT COALESCE(SUM(tokens), 0) FROM attribution_source_buckets WHERE provenance_epoch = ?1",
                [&epoch],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        (epoch, tokens)
    };
    let (published_epoch, published_attribution_tokens) = read_attribution_state();
    assert_eq!(published_attribution_tokens, 120);

    write_lines(
        &original_file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101,"cached_input_tokens":20,"output_tokens":20,"total_tokens":121}}}}"#,
        ],
    );
    write_lines(
        &session_dir.join("rollout-019epublished-b-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );
    ExactUsageIndex::set_after_file_commit_hook_for_testing(|_| {
        Err("injected interruption with a published generation".into())
    });
    let mut interrupted = ExactUsageIndex::open(&root).unwrap();
    assert!(interrupted.sync(&root, &mut Vec::new()).is_err());
    assert_eq!(interrupted.revision().unwrap(), published_revision);
    assert_eq!(
        interrupted
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120,
        "staged rows must never pollute the prior published total"
    );
    assert_eq!(
        cached_dashboard_usage_summary(&root).unwrap().total_tokens,
        120,
        "the UI-facing aggregate must remain on the last complete revision"
    );
    assert_eq!(
        read_attribution_state(),
        (published_epoch.clone(), 120),
        "an interrupted rewrite must not publish its new epoch or attribution ledger"
    );

    let completed_revision = interrupted.sync(&root, &mut Vec::new()).unwrap();
    assert!(completed_revision > published_revision);
    assert_eq!(
        interrupted
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        151
    );
    let (completed_epoch, completed_attribution_tokens) = read_attribution_state();
    assert_ne!(completed_epoch, published_epoch);
    assert_eq!(completed_attribution_tokens, 151);
    drop(interrupted);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rolls_back_when_the_scanned_prefix_is_rewritten() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019erewrite-prefix-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let appended = r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#;
    write_lines(&file, &[original]);
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    let before_revision = ExactUsageIndex::open(&root).unwrap().revision().unwrap();

    write_lines(&file, &[original, appended]);
    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    let prefix_hook: Box<dyn FnOnce(&Path) + Send> = Box::new(|scanned_file| {
        let before = fs::read_to_string(scanned_file).unwrap();
        let after = before.replacen("\"total_tokens\":30", "\"total_tokens\":31", 1);
        assert_eq!(before.len(), after.len());
        fs::write(scanned_file, after).unwrap();
    });
    let prefix_hook = Arc::new(Mutex::new(Some(prefix_hook)));
    let prefix_hook_for_refresh = Arc::clone(&prefix_hook);
    set_precise_refresh_sync_hook_for_testing(Some(Arc::new(move |_| {
        if let Some(hook) = prefix_hook_for_refresh.lock().unwrap().take() {
            ExactUsageIndex::set_after_prefix_scan_hook_for_testing(hook);
        }
        Ok(())
    })));

    let error = dashboard_snapshot(&root).unwrap_err();
    set_precise_refresh_sync_hook_for_testing(None);
    assert!(error.contains("非追加变化"), "{error}");
    assert!(error.contains("既有字节被改写"), "{error}");
    let index = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(index.revision().unwrap(), before_revision);
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    drop(index);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_detects_an_equal_length_rewrite_after_mtime_is_restored() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019ectime-rewrite-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let rewritten = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101,"cached_input_tokens":20,"output_tokens":20,"total_tokens":121}}}}"#;
    assert_eq!(original.len(), rewritten.len());
    write_lines(&file, &[original]);
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    let initial_epoch = initial.recent_usage_24h[0]
        .source_contribution_epoch
        .clone()
        .unwrap();
    let original_modified = fs::metadata(&file).unwrap().modified().unwrap();

    #[cfg(windows)]
    std::thread::sleep(std::time::Duration::from_millis(25));
    write_lines(&file, &[rewritten]);
    fs::File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(original_modified))
        .unwrap();
    assert_eq!(
        fs::metadata(&file).unwrap().modified().unwrap(),
        original_modified
    );

    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 121);
    assert_eq!(rebuilt.stats.total_calls, 1);
    assert_ne!(
        rebuilt.recent_usage_24h[0]
            .source_contribution_epoch
            .as_deref(),
        Some(initial_epoch.as_str()),
        "a same-size rewrite with restored mtime must rotate attribution provenance"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_quick_check_rejects_corrupt_database_without_deleting_it() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019ecorrupt-index-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    write_lines(&file, &[original]);
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let index_metadata = fs::metadata(&index_path).unwrap();
    #[cfg(unix)]
    let original_identity = (index_metadata.dev(), index_metadata.ino());
    let index_size = fs::metadata(&index_path).unwrap().len();
    let mut index_file = fs::OpenOptions::new()
        .write(true)
        .open(&index_path)
        .unwrap();
    index_file.seek(SeekFrom::Start(100)).unwrap();
    index_file.write_all(&[0]).unwrap();
    index_file.flush().unwrap();
    drop(index_file);
    assert_eq!(fs::metadata(&index_path).unwrap().len(), index_size);

    reset_dashboard_aggregate_build_count_for_testing();
    let error = dashboard_snapshot(&root).unwrap_err();
    assert!(error.contains("已保留原索引并拒绝自动重建"), "{error}");
    let preserved_metadata = fs::metadata(&index_path).unwrap();
    assert_eq!(preserved_metadata.len(), index_size);
    #[cfg(unix)]
    assert_eq!(
        (preserved_metadata.dev(), preserved_metadata.ino()),
        original_identity,
        "a corrupt index must remain available for recovery instead of being silently replaced"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_transient_quick_check_failure_preserves_published_database() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019etransient-check-0000-0000-fast.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let index_path = super::exact_usage_index::database_path(&root).unwrap();
    let receipt = integrity_receipt_path_for_testing(&root).unwrap();
    let before = fs::metadata(&index_path).unwrap();
    #[cfg(unix)]
    let before_identity = (before.dev(), before.ino());
    fs::remove_file(receipt).unwrap();
    ExactUsageIndex::clear_integrity_signature_for_testing(&root);
    ExactUsageIndex::fail_next_quick_check_query_for_testing();

    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("transient quick_check failure must not be accepted as a clean open"),
        Err(error) => error,
    };
    assert!(error.contains("暂时失败"), "{error}");
    assert!(error.contains("已保留原索引并拒绝自动重建"), "{error}");
    let after = fs::metadata(&index_path).unwrap();
    assert_eq!(after.len(), before.len());
    #[cfg(unix)]
    assert_eq!((after.dev(), after.ino()), before_identity);

    drop(ExactUsageIndex::open(&root).unwrap());
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM events", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_existing_open_never_recreates_a_missing_database() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let path = root.join("exact-token-index.sqlite3");

    let error = open_existing_index_for_testing(&path).unwrap_err();
    assert!(error.contains("无法打开精确 token 索引"), "{error}");
    assert!(
        !path.exists(),
        "an existing-index reopen must fail closed if the file disappears instead of creating an empty replacement"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_replaces_plaintext_v1_storage_and_keeps_only_source_offsets() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_dir = root.join(".codex-token-bar-test-cache");
    let index_path = index_dir.join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&index_dir).unwrap();

    let secret_question = "SECRET_PROMPT_EXACT_INDEX_MUST_NOT_PERSIST_7E2B";
    let secret_answer = "SECRET_ANSWER_EXACT_INDEX_MUST_NOT_PERSIST_91FC";
    {
        let legacy = Connection::open(&index_path).unwrap();
        legacy
            .execute_batch(
                r#"
                PRAGMA journal_mode = WAL;
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO metadata(key, value) VALUES ('schema_version', '1');
                CREATE TABLE legacy_events (
                    user_prompt TEXT NOT NULL,
                    assistant_response TEXT NOT NULL
                );
                "#,
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO legacy_events(user_prompt, assistant_response) VALUES (?1, ?2)",
                rusqlite::params![secret_question, secret_answer],
            )
            .unwrap();
    }

    let user_line = format!(
        r#"{{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{{"type":"user_message","message":"{secret_question}"}}}}"#
    );
    let assistant_line = format!(
        r#"{{"timestamp":"2026-07-20T01:00:20Z","type":"event_msg","payload":{{"type":"agent_message","message":"{secret_answer}"}}}}"#
    );
    write_lines(
        &session_dir.join("rollout-019eprivacy-0000-0000-0000-offsets.jsonl"),
        &[
            user_line.as_str(),
            assistant_line.as_str(),
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.cache_usage.turns[0].user_prompt, secret_question);
    assert_eq!(
        snapshot.cache_usage.turns[0].assistant_response,
        secret_answer
    );

    let connection = Connection::open(&index_path).unwrap();
    let columns = connection
        .prepare("PRAGMA table_info(events)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(!columns.iter().any(|column| column == "user_prompt"));
    assert!(!columns.iter().any(|column| column == "assistant_response"));
    assert!(columns.iter().any(|column| column == "user_prompt_start"));
    assert!(columns
        .iter()
        .any(|column| column == "assistant_response_end"));
    connection
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            INSERT OR REPLACE INTO metadata(key, value) VALUES ('privacy_test_probe', '1');
            "#,
        )
        .unwrap();

    for path in [
        index_path.clone(),
        PathBuf::from(format!("{}-wal", index_path.display())),
        PathBuf::from(format!("{}-shm", index_path.display())),
    ] {
        let bytes = fs::read(&path)
            .unwrap_or_else(|error| panic!("failed to scan {}: {error}", path.display()));
        assert!(
            !bytes
                .windows(secret_question.len())
                .any(|window| window == secret_question.as_bytes()),
            "{} retained the prompt plaintext",
            path.display()
        );
        assert!(
            !bytes
                .windows(secret_answer.len())
                .any(|window| window == secret_answer.as_bytes()),
            "{} retained the answer plaintext",
            path.display()
        );
    }
    drop(connection);

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn exact_index_rejects_a_session_symlink_that_escapes_selected_codex_home() {
    use std::os::unix::fs::symlink;

    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let outside_root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&outside_root).unwrap();
    write_lines(
        &session_dir.join("rollout-019eboundary-valid-0000-0000-0000-home.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let outside_file = outside_root.join("rollout-019eboundary-outside.jsonl");
    write_lines(
        &outside_file,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":99,"total_tokens":999}}}}"#,
        ],
    );
    symlink(&outside_file, session_dir.join("escaped-session.jsonl")).unwrap();

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(snapshot.warnings.iter().any(|warning| {
        warning.source == "jsonl_scan" && warning.message.contains("Codex Home 外")
    }));

    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside_root).unwrap();
}

#[cfg(unix)]
#[test]
fn exact_index_skips_an_unreadable_session_file_and_keeps_published_stats() {
    use std::os::unix::fs::PermissionsExt;

    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eunreadable-a-0000-0000-0000-keep.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let locked = session_dir.join("rollout-019eunreadable-b-0000-0000-0000-lock.jsonl");
    write_lines(
        &locked,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );
    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    let total = |index: &ExactUsageIndex| {
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens
    };
    assert_eq!(total(&index), 150);

    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let mut warnings = Vec::new();
    index.sync(&root, &mut warnings).unwrap();
    assert_eq!(
        total(&index),
        150,
        "跳过不可读文件必须保留其已发布统计，不得打删除墓碑"
    );
    assert!(warnings.iter().any(|warning| {
        warning.source == "jsonl_scan"
            && warning.message.contains("读取会话文件失败，本轮跳过该文件")
    }));

    fs::set_permissions(&locked, fs::Permissions::from_mode(0o644)).unwrap();
    let mut handle = fs::OpenOptions::new().append(true).open(&locked).unwrap();
    writeln!(
        handle,
        "{}",
        r#"{"timestamp":"2026-07-20T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":10,"total_tokens":50}}}}"#
    )
    .unwrap();
    handle.flush().unwrap();
    drop(handle);
    index.sync(&root, &mut Vec::new()).unwrap();
    assert_eq!(
        total(&index),
        200,
        "文件恢复可读后必须自动续上，不需要人工干预"
    );
    drop(index);

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn exact_index_skips_an_unreadable_directory_without_tombstoning_published_files() {
    use std::os::unix::fs::PermissionsExt;

    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let locked_dir = session_dir.join("2026");
    fs::create_dir_all(&locked_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019elockdir-a-0000-0000-0000-keep.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &locked_dir.join("rollout-019elockdir-b-0000-0000-0000-deep.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );
    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    let total = |index: &ExactUsageIndex| {
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens
    };
    assert_eq!(total(&index), 150);

    fs::set_permissions(&locked_dir, fs::Permissions::from_mode(0o000)).unwrap();
    let mut warnings = Vec::new();
    index.sync(&root, &mut warnings).unwrap();
    assert_eq!(
        total(&index),
        150,
        "不可读目录下的已发布会话不得被当作已删除打墓碑"
    );
    assert!(warnings.iter().any(|warning| {
        warning.source == "jsonl_scan"
            && (warning.message.contains("本轮跳过该目录")
                || warning.message.contains("无法确认会话目录边界"))
    }));

    fs::set_permissions(&locked_dir, fs::Permissions::from_mode(0o755)).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    assert_eq!(total(&index), 150);
    drop(index);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rejects_an_absolute_state_rollout_outside_selected_codex_home() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let outside_root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&outside_root).unwrap();
    write_lines(
        &session_dir.join("rollout-019estate-valid-0000-0000-0000-home.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let outside_file = outside_root.join("rollout-019estate-outside.jsonl");
    write_lines(
        &outside_file,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":99,"total_tokens":999}}}}"#,
        ],
    );
    create_state_database_with_rollout(
        &root,
        "019estate-outside-0000-0000-0000-rollout",
        &outside_file,
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(snapshot.warnings.iter().any(|warning| {
        warning.source == "jsonl_scan" && warning.message.contains("Codex Home 外")
    }));

    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside_root).unwrap();
}

#[test]
fn parses_token_count_totals_as_deltas() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions").join("2026").join("06").join("18");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    let first_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(10))
        .format(&Rfc3339)
        .unwrap();
    let second_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(5))
        .format(&Rfc3339)
        .unwrap();
    let first_line = format!(
        r#"{{"timestamp":"{first_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"total_tokens":13}},"last_token_usage":{{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"total_tokens":13}}}}}}}}"#
    );
    let second_line = format!(
        r#"{{"timestamp":"{second_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":20,"cached_input_tokens":5,"output_tokens":8,"total_tokens":28}},"last_token_usage":{{"input_tokens":10,"cached_input_tokens":3,"output_tokens":5,"total_tokens":15}}}}}}}}"#
    );
    write_lines(
        &file,
        &[
            r#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#.to_string(),
            first_line,
            r#"{"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#.to_string(),
            second_line,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 28);
    assert_eq!(snapshot.stats.total_calls, 2);
    assert_eq!(snapshot.stats.total_threads, 1);
    assert_eq!(snapshot.stats.model_breakdowns.len(), 2);
    assert!(snapshot
        .stats
        .model_breakdowns
        .iter()
        .any(|row| { row.model.as_deref() == Some("gpt-5.6-sol") && row.breakdown.calls == 1 }));
    assert!(snapshot
        .stats
        .model_breakdowns
        .iter()
        .any(|row| { row.model.as_deref() == Some("gpt-5.6-terra") && row.breakdown.calls == 1 }));
    let active_day = snapshot
        .activity_days
        .iter()
        .find(|day| day.tokens == 28)
        .unwrap();
    assert_eq!(active_day.model_breakdowns.len(), 2);
    assert!(active_day
        .model_breakdowns
        .iter()
        .any(|row| { row.model.as_deref() == Some("gpt-5.6-sol") && row.breakdown.calls == 1 }));
    assert!(active_day
        .model_breakdowns
        .iter()
        .any(|row| { row.model.as_deref() == Some("gpt-5.6-terra") && row.breakdown.calls == 1 }));
    assert_eq!(snapshot.recent_usage_24h.len(), 30 * 24 * 12);
    assert_eq!(snapshot.recent_usage_7d.len(), 30 * 24);
    assert_eq!(snapshot.recent_usage_30d.len(), 120);
    assert_eq!(
        snapshot
            .recent_usage_7d
            .iter()
            .map(|point| point.input_tokens)
            .sum::<u64>(),
        20
    );
    assert_eq!(
        snapshot
            .recent_usage_7d
            .iter()
            .map(|point| point.cached_input_tokens)
            .sum::<u64>(),
        5
    );
    assert_eq!(
        snapshot
            .recent_usage_7d
            .iter()
            .map(|point| point.output_tokens)
            .sum::<u64>(),
        8
    );
    assert!(snapshot
        .recent_usage_7d
        .windows(2)
        .all(|window| window[1].start_unix - window[0].start_unix == 60 * 60));
    assert!(snapshot
        .recent_usage_30d
        .windows(2)
        .all(|window| window[1].start_unix - window[0].start_unix == 6 * 60 * 60));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn interleaved_cumulative_streams_use_unique_last_usage_snapshots() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019finterleaved-0000-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-22T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718279305,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718279305},"last_token_usage":{"input_tokens":157910,"cached_input_tokens":0,"output_tokens":0,"total_tokens":157910}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2583955090,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2583955090},"last_token_usage":{"input_tokens":113621,"cached_input_tokens":0,"output_tokens":0,"total_tokens":113621}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:20Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718279305,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718279305},"last_token_usage":{"input_tokens":157910,"cached_input_tokens":0,"output_tokens":0,"total_tokens":157910}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:30Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2584078056,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2584078056},"last_token_usage":{"input_tokens":122966,"cached_input_tokens":0,"output_tokens":0,"total_tokens":122966}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:40Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718437623,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718437623},"last_token_usage":{"input_tokens":158318,"cached_input_tokens":0,"output_tokens":0,"total_tokens":158318}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:50Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718437623,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718437623},"last_token_usage":{"input_tokens":77777,"cached_input_tokens":0,"output_tokens":0,"total_tokens":77777}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &file,
        "019finterleaved-0000-0000-eeeeffffffff",
        &mut warnings,
    );

    assert_eq!(parsed.events.len(), 5);
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        630_592
    );
    assert_eq!(
        parsed
            .events
            .iter()
            .map(|event| event.input_tokens)
            .sum::<u64>(),
        630_592
    );
    assert_eq!(parsed.previous_total_tokens, Some(2_718_437_623));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn recent_usage_24h_series_keeps_thirty_days_of_five_minute_history() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019erecent-history-0000-0000-000000000001.jsonl");
    let older_timestamp = (OffsetDateTime::now_utc() - time::Duration::days(2))
        .format(&Rfc3339)
        .unwrap();
    let recent_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(5))
        .format(&Rfc3339)
        .unwrap();
    write_lines(
        &file,
        &[
            format!(
                r#"{{"timestamp":"{older_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":10,"output_tokens":20,"total_tokens":120}}}}}}}}"#
            ),
            format!(
                r#"{{"timestamp":"{recent_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":200,"cached_input_tokens":20,"output_tokens":30,"total_tokens":230}}}}}}}}"#
            ),
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.recent_usage_24h.len(), 30 * 24 * 12);
    assert!(snapshot
        .recent_usage_24h
        .iter()
        .any(|point| point.tokens == 120));
    assert!(snapshot
        .recent_usage_24h
        .iter()
        .any(|point| point.tokens == 230));
    assert!(snapshot
        .recent_usage_24h
        .windows(2)
        .all(|window| window[1].start_unix - window[0].start_unix == 5 * 60));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_temp_view_keeps_one_wal_snapshot_across_all_sections() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(5))
        .format(&Rfc3339)
        .unwrap();
    write_lines(
        &session_dir.join("rollout-019edashboard-snapshot-0000-0000-fast.jsonl"),
        &[format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}}}}}"#
        )],
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    index.sync(&root, &mut warnings).unwrap();
    let database_path = super::exact_usage_index::database_path(&root).unwrap();
    ExactUsageIndex::set_after_dashboard_snapshot_hook_for_testing(move || {
        let writer = Connection::open(&database_path).unwrap();
        writer.busy_timeout(StdDuration::from_secs(1)).unwrap();
        writer
            .execute(
                "UPDATE events SET tokens = 999, input_tokens = 900, cached_input_tokens = 0, output_tokens = 99",
                [],
            )
            .unwrap();
    });

    let data = index
        .dashboard_data(
            &root,
            OffsetDateTime::now_utc(),
            UtcOffset::UTC,
            &mut warnings,
        )
        .unwrap();
    assert_eq!(data.summary.total_tokens, 120);
    assert_eq!(data.stats.total_tokens, 120);
    assert_eq!(data.stats.total_input_tokens, 100);
    assert_eq!(data.stats.total_output_tokens, 20);

    let writer = Connection::open(super::exact_usage_index::database_path(&root).unwrap()).unwrap();
    assert_eq!(
        writer
            .query_row("SELECT tokens FROM events LIMIT 1", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        999,
        "the concurrent writer must have committed while the dashboard retained its earlier read snapshot"
    );
    drop(writer);
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn recent_usage_downsample_preserves_model_breakdowns_and_cache_rates() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let now = OffsetDateTime::parse("2026-06-18T12:34:56Z", &Rfc3339).unwrap();

    let events = [
        (
            "019edownsample-0000-0000-000000000001",
            "2026-06-18T12:01:00Z",
            "gpt-a",
            100_u64,
            20_u64,
            20_u64,
            120_u64,
        ),
        (
            "019edownsample-0000-0000-000000000002",
            "2026-06-18T12:04:00Z",
            "gpt-a",
            70,
            10,
            10,
            80,
        ),
        (
            "019edownsample-0000-0000-000000000003",
            "2026-06-18T12:07:00Z",
            "gpt-b",
            50,
            40,
            10,
            60,
        ),
        (
            "019edownsample-0000-0000-000000000004",
            "2026-06-18T11:02:00Z",
            "gpt-b",
            30,
            5,
            5,
            40,
        ),
    ];
    for (session_id, timestamp, model, input_tokens, cached_input_tokens, output_tokens, tokens) in
        events
    {
        let model_line = serde_json::json!({
            "type": "turn_context",
            "payload": {"model": model},
        })
        .to_string();
        let token_line = serde_json::json!({
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": input_tokens,
                        "cached_input_tokens": cached_input_tokens,
                        "output_tokens": output_tokens,
                        "total_tokens": tokens,
                    },
                },
            },
        })
        .to_string();
        write_lines(
            &session_dir.join(format!("{session_id}.jsonl")),
            &[model_line, token_line],
        );
    }

    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    index.sync(&root, &mut warnings).unwrap();
    let data = index
        .dashboard_data(&root, now, UtcOffset::UTC, &mut warnings)
        .unwrap();
    let temp_objects = index.dashboard_temp_object_types_for_testing().unwrap();
    assert_eq!(
        temp_objects.get("published_events").map(String::as_str),
        Some("view")
    );
    assert!(
        !temp_objects.contains_key("dashboard_turn_positions"),
        "turn positions must be calculated only for selected candidates, not materialized for every event"
    );

    assert_eq!(data.summary.total_tokens, 300);
    assert_eq!(data.summary.today_tokens, 300);
    assert_eq!(data.summary.today_requests, 4);

    let align_bin =
        |timestamp: i64, interval_seconds: i64| timestamp - (timestamp % interval_seconds);
    let five_minute_12 = align_bin(now.unix_timestamp() - 34 * 60, 300);
    let five_minute_11 = align_bin(now.unix_timestamp() - 94 * 60, 300);
    let hour_12 = align_bin(now.unix_timestamp() - 34 * 60, 3_600);
    let hour_11 = align_bin(now.unix_timestamp() - 94 * 60, 3_600);
    let six_hour_12 = align_bin(now.unix_timestamp() - 34 * 60, 21_600);
    let six_hour_06 = align_bin(now.unix_timestamp() - 394 * 60, 21_600);

    let assert_point = |point: &RecentUsagePoint,
                        tokens: u64,
                        calls: u32,
                        input_tokens: u64,
                        cached_input_tokens: u64,
                        output_tokens: u64,
                        models: &[(&str, u64, u32, u64, u64, u64)]| {
        assert_eq!(point.tokens, tokens);
        assert_eq!(point.calls, calls);
        assert_eq!(point.input_tokens, input_tokens);
        assert_eq!(point.cached_input_tokens, cached_input_tokens);
        assert_eq!(point.output_tokens, output_tokens);
        if input_tokens == 0 {
            assert!(point.cache_hit_rate.is_none());
        } else {
            let expected_rate = cached_input_tokens as f64 / input_tokens as f64;
            assert!((point.cache_hit_rate.unwrap() - expected_rate).abs() < 1e-12);
        }
        assert_eq!(point.model_breakdowns.len(), models.len());
        for (model, model_tokens, model_calls, model_input, model_cached, model_output) in models {
            let breakdown = point
                .model_breakdowns
                .iter()
                .find(|candidate| candidate.model.as_deref() == Some(*model))
                .unwrap();
            assert_eq!(breakdown.breakdown.total_tokens, *model_tokens);
            assert_eq!(breakdown.breakdown.calls, *model_calls);
            assert_eq!(breakdown.breakdown.input_tokens, *model_input);
            assert_eq!(breakdown.breakdown.cached_input_tokens, *model_cached);
            assert_eq!(breakdown.breakdown.output_tokens, *model_output);
        }
    };

    fn point_at<'a>(series: &'a [RecentUsagePoint], start: i64) -> &'a RecentUsagePoint {
        series
            .iter()
            .find(|point| point.start_unix == start)
            .unwrap()
    }
    let assert_zero_points = |series: &[RecentUsagePoint], nonzero_starts: &[i64]| {
        for point in series {
            if nonzero_starts.contains(&point.start_unix) {
                continue;
            }
            assert_eq!(point.tokens, 0);
            assert_eq!(point.calls, 0);
            assert_eq!(point.input_tokens, 0);
            assert_eq!(point.cached_input_tokens, 0);
            assert_eq!(point.output_tokens, 0);
            assert!(point.cache_hit_rate.is_none());
            assert!(point.model_breakdowns.is_empty());
        }
    };

    let five_minute_12_point = point_at(&data.recent_usage_24h, five_minute_12);
    assert_point(
        five_minute_12_point,
        200,
        2,
        170,
        30,
        30,
        &[("gpt-a", 200, 2, 170, 30, 30)],
    );
    assert!(five_minute_12_point.source_contribution_epoch.is_some());
    assert_eq!(
        five_minute_12_point
            .source_contributions
            .iter()
            .map(|contribution| contribution.tokens)
            .sum::<u64>(),
        200
    );
    assert_point(
        point_at(&data.recent_usage_24h, five_minute_11),
        40,
        1,
        30,
        5,
        5,
        &[("gpt-b", 40, 1, 30, 5, 5)],
    );
    assert_point(
        point_at(&data.recent_usage_24h, five_minute_12 + 300),
        60,
        1,
        50,
        40,
        10,
        &[("gpt-b", 60, 1, 50, 40, 10)],
    );
    assert_zero_points(
        &data.recent_usage_24h,
        &[five_minute_11, five_minute_12, five_minute_12 + 300],
    );

    assert_point(
        point_at(&data.recent_usage_7d, hour_12),
        260,
        3,
        220,
        70,
        40,
        &[("gpt-a", 200, 2, 170, 30, 30), ("gpt-b", 60, 1, 50, 40, 10)],
    );
    assert_point(
        point_at(&data.recent_usage_7d, hour_11),
        40,
        1,
        30,
        5,
        5,
        &[("gpt-b", 40, 1, 30, 5, 5)],
    );
    assert!(point_at(&data.recent_usage_7d, hour_12)
        .source_contribution_epoch
        .is_none());
    assert!(point_at(&data.recent_usage_7d, hour_12)
        .source_contributions
        .is_empty());
    assert_zero_points(&data.recent_usage_7d, &[hour_11, hour_12]);

    assert_point(
        point_at(&data.recent_usage_30d, six_hour_12),
        260,
        3,
        220,
        70,
        40,
        &[("gpt-a", 200, 2, 170, 30, 30), ("gpt-b", 60, 1, 50, 40, 10)],
    );
    assert_point(
        point_at(&data.recent_usage_30d, six_hour_06),
        40,
        1,
        30,
        5,
        5,
        &[("gpt-b", 40, 1, 30, 5, 5)],
    );
    assert_zero_points(&data.recent_usage_30d, &[six_hour_06, six_hour_12]);

    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn skips_pure_fork_replay_even_after_thirty_seconds() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#,
            r#"{"timestamp":"2026-06-18T01:05:40Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300},"last_token_usage":{"total_tokens":200}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let events = parse_session_file_full_result(
        &file,
        "019eaaaa-bbbb-cccc-dddd-eeeeffffffff",
        &mut warnings,
    );
    assert_eq!(
        events.events.iter().map(|event| event.tokens).sum::<u64>(),
        0
    );
    assert_eq!(events.previous_total_tokens, Some(300));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn keeps_fork_replay_active_for_replayed_user_message_near_token_counts() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-copy-0000-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500},"last_token_usage":{"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:11Z","type":"event_msg","payload":{"type":"user_message","message":"父会话复制问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:12Z","type":"event_msg","payload":{"type":"agent_message","message":"父会话复制回答"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:13Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":620},"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &file,
        "019efork-copy-0000-0000-eeeeffffffff",
        &mut warnings,
    );
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        0
    );
    assert_eq!(parsed.previous_total_tokens, Some(620));
    assert!(parsed.events.is_empty());
    assert!(parsed.fork_replay_active);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn fork_replay_with_multiple_session_meta_skips_dense_replayed_history_until_later_prompt() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-dense-replay-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-09T10:57:40.602Z","type":"session_meta","payload":{"id":"019efork-dense-replay-0000-eeeeffffffff","forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-07-09T10:57:40.603Z","type":"session_meta","payload":{"id":"019efork-dense-replay-0000-eeeeffffffff","forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-07-09T10:57:40.603Z","type":"event_msg","payload":{"type":"user_message","message":"你去看下 finderpeek 项目文件夹，你来接手开发"}}"#,
            r#"{"timestamp":"2026-07-09T10:57:40.604Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":315509847,"cached_input_tokens":295499520,"output_tokens":1303586,"total_tokens":316813433},"last_token_usage":{"input_tokens":207117,"cached_input_tokens":191360,"output_tokens":88,"total_tokens":207205}}}}"#,
            r#"{"timestamp":"2026-07-09T10:57:42.921Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":316572989,"cached_input_tokens":296540800,"output_tokens":1306838,"total_tokens":317879827},"last_token_usage":{"input_tokens":221820,"cached_input_tokens":210304,"output_tokens":2428,"total_tokens":224248}}}}"#,
            r#"{"timestamp":"2026-07-09T10:58:08.319Z","type":"event_msg","payload":{"type":"user_message","message":"请对当前项目做一轮业务逻辑与核心技术债审查"}}"#,
            r#"{"timestamp":"2026-07-09T10:58:17.090Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":316601495,"cached_input_tokens":296540800,"output_tokens":1306838,"total_tokens":317908333},"last_token_usage":{"input_tokens":28506,"cached_input_tokens":0,"output_tokens":0,"total_tokens":28506}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 28_506);
    assert_eq!(snapshot.stats.total_calls, 1);

    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &file,
        "019efork-dense-replay-0000-eeeeffffffff",
        &mut warnings,
    );
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        28_506
    );
    assert_eq!(parsed.previous_total_tokens, Some(317_908_333));
    assert_eq!(
        parsed.events[0].user_prompt,
        "请对当前项目做一轮业务逻辑与核心技术债审查"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn counts_new_call_after_fork_replay_user_message() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-new-0000-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500},"last_token_usage":{"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:10:00Z","type":"event_msg","payload":{"type":"user_message","message":"新分支问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:10:30Z","type":"event_msg","payload":{"type":"agent_message","message":"新分支回答"}}"#,
            r#"{"timestamp":"2026-06-18T01:11:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":20,"output_tokens":30,"total_tokens":620},"last_token_usage":{"input_tokens":90,"cached_input_tokens":20,"output_tokens":30,"total_tokens":120}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 120);
    assert_eq!(snapshot.stats.total_calls, 1);

    let mut warnings = Vec::new();
    let parsed =
        parse_session_file_full_result(&file, "019efork-new-0000-0000-eeeeffffffff", &mut warnings);
    assert_eq!(parsed.events[0].user_prompt, "新分支问题");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn counts_explicit_subagent_after_child_turn_context_and_preserves_model() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019esubagent-boundary-0000-0000-luna.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"id":"019esubagent-boundary-0000-0000-luna","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker","agent_path":"/root/luna_worker","source":{"subagent":{"thread_spawn":{"parent_thread_id":"origin-session","agent_role":"luna_worker"}}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00.200Z","type":"session_meta","payload":{"id":"inherited-parent-meta-1","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker","agent_path":"/root/luna_worker"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00.300Z","type":"session_meta","payload":{"id":"inherited-parent-meta-2","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker","agent_path":"/root/luna_worker"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"Child task"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"total_tokens":120}}}}"#,
            r#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01.200Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01.300Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130,"cached_input_tokens":85,"output_tokens":25,"total_tokens":150},"last_token_usage":{"input_tokens":30,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":90,"output_tokens":30,"total_tokens":200},"last_token_usage":{"input_tokens":60,"cached_input_tokens":10,"output_tokens":10,"total_tokens":80}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:03.600Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":40,"total_tokens":260},"last_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":60}}}}"#,
        ],
    );

    let first = dashboard_snapshot(&root).unwrap();
    assert_eq!(first.stats.total_tokens, 60);
    assert_eq!(first.stats.total_calls, 1);
    assert_eq!(first.stats.model_breakdowns.len(), 1);
    assert_eq!(
        first.stats.model_breakdowns[0].model.as_deref(),
        Some("gpt-5.6-luna")
    );
    assert_eq!(first.stats.model_breakdowns[0].breakdown.total_tokens, 60);

    let mut append = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":110,"output_tokens":50,"total_tokens":320},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":10,"total_tokens":60}}}}"#
    )
    .unwrap();
    append.flush().unwrap();

    let second = dashboard_snapshot(&root).unwrap();
    assert_eq!(second.stats.total_tokens, 120);
    assert_eq!(second.stats.total_calls, 2);
    assert_eq!(second.stats.model_breakdowns.len(), 1);
    assert_eq!(
        second.stats.model_breakdowns[0].model.as_deref(),
        Some("gpt-5.6-luna")
    );
    assert_eq!(second.stats.model_breakdowns[0].breakdown.total_tokens, 120);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn explicit_subagent_fork_persists_replay_identity_across_incremental_append() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019esubagent-incremental-0000-0000-luna.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"id":"019esubagent-incremental-0000-0000-luna","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker","agent_path":"/root/luna_worker","source":{"subagent":{"thread_spawn":{"parent_thread_id":"origin-session","agent_role":"luna_worker"}}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    index.sync(&root, &mut warnings).unwrap();

    let mut append = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:00.800Z","type":"session_meta","payload":{"id":"inherited-parent-meta-1","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker","agent_path":"/root/luna_worker"}}"#
    )
    .unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:00.900Z","type":"session_meta","payload":{"id":"inherited-parent-meta-2","forked_from_id":"origin-session","thread_source":"subagent","agent_role":"luna_worker","agent_path":"/root/luna_worker"}}"#
    )
    .unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
    )
    .unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:01.200Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
    )
    .unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:01.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130,"cached_input_tokens":85,"output_tokens":25,"total_tokens":150},"last_token_usage":{"input_tokens":30,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#
    )
    .unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:03.600Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#
    )
    .unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":190,"cached_input_tokens":95,"output_tokens":35,"total_tokens":230},"last_token_usage":{"input_tokens":60,"cached_input_tokens":10,"output_tokens":10,"total_tokens":80}}}}"#
    )
    .unwrap();
    append.flush().unwrap();

    index.sync(&root, &mut warnings).unwrap();
    let data = index
        .dashboard_data(
            &root,
            OffsetDateTime::now_utc(),
            UtcOffset::UTC,
            &mut warnings,
        )
        .unwrap();
    assert_eq!(data.stats.total_tokens, 80);
    assert_eq!(data.stats.total_calls, 1);
    assert_eq!(data.stats.model_breakdowns.len(), 1);
    assert_eq!(
        data.stats.model_breakdowns[0].model.as_deref(),
        Some("gpt-5.6-luna")
    );

    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ordinary_fork_turn_context_does_not_end_replay() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eordinary-fork-boundary-0000-0000-sol.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"id":"019eordinary-fork-boundary-0000-0000-sol","forked_from_id":"origin-session"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120},"last_token_usage":{"total_tokens":120}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200},"last_token_usage":{"total_tokens":80}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:03.600Z","type":"event_msg","payload":{"type":"user_message","message":"Actual prompt"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:03.700Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250},"last_token_usage":{"total_tokens":50}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 50);
    assert_eq!(snapshot.stats.total_calls, 1);
    assert_eq!(snapshot.stats.model_breakdowns.len(), 1);
    assert_eq!(
        snapshot.stats.model_breakdowns[0].model.as_deref(),
        Some("gpt-5.6-sol")
    );
    assert_eq!(
        snapshot.stats.model_breakdowns[0].breakdown.total_tokens,
        50
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ordinary_fork_does_not_persist_an_explicit_replay_boundary_across_incremental_append() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eordinary-incremental-0000-0000-sol.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"id":"019eordinary-incremental-0000-0000-sol","forked_from_id":"origin-session"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120},"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    index.sync(&root, &mut warnings).unwrap();

    let mut append = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
    )
    .unwrap();
    writeln!(
        append,
        "{}",
        r#"{"timestamp":"2026-06-18T01:00:01.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200},"last_token_usage":{"total_tokens":80}}}}"#
    )
    .unwrap();
    append.flush().unwrap();

    index.sync(&root, &mut warnings).unwrap();
    assert!(index.is_empty().unwrap());

    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn parent_thread_without_forked_from_id_still_counts() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eparent-0000-0000-0000-count.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"parent_thread_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 42);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn active_state_rollout_counts_subagent_parent_thread_without_forked_from_id() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let active_dir = root.join("active-rollouts");
    fs::create_dir_all(&active_dir).unwrap();
    let rollout_path = active_dir.join("rollout-019esubagent-0000-0000-0000-stateonly.jsonl");
    write_lines(
        &rollout_path,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"parent_thread_id":"parent-thread","source":"subagent"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":5,"output_tokens":10,"total_tokens":60}}}}"#,
        ],
    );
    create_state_database_with_rollout_source(
        &root,
        "019esubagent-0000-0000-0000-stateonly",
        &rollout_path,
        "subagent",
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 60);
    assert_eq!(snapshot.stats.total_calls, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_counts_today_from_token_events_not_thread_updated_at() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let now = OffsetDateTime::now_utc();
    let yesterday = now - time::Duration::days(1);
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            &format!(
                r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":1000}}}}}}}}"#,
                yesterday.format(&Rfc3339).unwrap()
            ),
            &format!(
                r#"{{"timestamp":"{}","type":"turn_context","payload":{{"model":"gpt-5.6-sol"}}}}"#,
                (now - time::Duration::seconds(1)).format(&Rfc3339).unwrap()
            ),
            &format!(
                r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":30,"cached_input_tokens":20,"output_tokens":10,"total_tokens":40}}}}}}}}"#,
                now.format(&Rfc3339).unwrap()
            ),
        ],
    );

    let summary = usage_summary(&root).unwrap();
    assert_eq!(summary.total_tokens, 1040);
    assert_eq!(summary.today_tokens, 40);
    assert_eq!(summary.today_requests, 1);
    assert_eq!(summary.today_model_breakdowns.len(), 1);
    assert_eq!(
        summary.today_model_breakdowns[0].model.as_deref(),
        Some("gpt-5.6-sol")
    );
    assert_eq!(summary.today_model_breakdowns[0].breakdown.input_tokens, 30);
    assert_eq!(
        summary.today_model_breakdowns[0]
            .breakdown
            .cached_input_tokens,
        20
    );
    assert_eq!(
        summary.today_model_breakdowns[0].breakdown.output_tokens,
        10
    );
    assert_eq!(summary.today_model_breakdowns[0].breakdown.total_tokens, 40);
    assert_eq!(summary.today_model_breakdowns[0].breakdown.calls, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_usage_summary_matches_dashboard_snapshot_metrics() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let now = OffsetDateTime::now_utc();
    let yesterday = now - time::Duration::days(1);
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            &format!(
                r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":1000}}}}}}}}"#,
                yesterday.format(&Rfc3339).unwrap()
            ),
            &format!(
                r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":40}}}}}}}}"#,
                now.format(&Rfc3339).unwrap()
            ),
        ],
    );

    let dashboard = dashboard_snapshot(&root).unwrap();
    let summary = dashboard_usage_summary(&root).unwrap();
    let today = dashboard.activity_days.last().unwrap();

    assert_eq!(summary.total_tokens, dashboard.stats.total_tokens);
    assert_eq!(summary.today_tokens, today.tokens);
    assert_eq!(summary.today_requests, today.calls);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn live_cached_usage_summary_miss_does_not_open_exact_index() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019elive-cache-miss-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );

    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    drop(index);

    // Force a subsequent ExactUsageIndex::open to perform its integrity check.
    // The live-facing helper must return a cache miss without opening the index
    // or consuming this startup-only work.
    let receipt = integrity_receipt_path_for_testing(&root).unwrap();
    let _ = fs::remove_file(receipt);
    ExactUsageIndex::clear_integrity_signature_for_testing(&root);
    ExactUsageIndex::reset_quick_check_count_for_testing();
    assert!(cached_dashboard_usage_summary(&root).is_none());
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_scan_signature_changes_when_local_date_changes() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let offset = UtcOffset::from_hms(8, 0, 0).unwrap();
    let before_midnight = OffsetDateTime::parse("2026-06-18T15:59:59Z", &Rfc3339).unwrap();
    let after_midnight = OffsetDateTime::parse("2026-06-18T16:00:01Z", &Rfc3339).unwrap();

    let before = dashboard_scan_signature_at(&root, 42, before_midnight, offset);
    let after = dashboard_scan_signature_at(&root, 42, after_midnight, offset);

    assert_ne!(before, after);
    assert_eq!(before.local_date, "2026-06-18");
    assert_eq!(after.local_date, "2026-06-19");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_includes_active_state_rollout_path() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    fs::create_dir_all(root.join("sessions")).unwrap();
    let active_dir = root.join("active-rollouts");
    fs::create_dir_all(&active_dir).unwrap();
    let rollout_path = active_dir.join("rollout-019eactive-0000-0000-0000-stateonly.jsonl");
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &rollout_path,
        &[format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":70,"cached_input_tokens":20,"output_tokens":7,"total_tokens":77}}}}}}}}"#
        )],
    );
    create_state_database_with_rollout(&root, "019eactive-0000-0000-0000-stateonly", &rollout_path);

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 77);
    assert_eq!(snapshot.stats.total_calls, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_deduplicates_rollout_path_already_under_sessions() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let rollout_path = session_dir.join("rollout-019ededup-0000-0000-0000-samefile.jsonl");
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &rollout_path,
        &[format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":70,"cached_input_tokens":20,"output_tokens":7,"total_tokens":77}}}}}}}}"#
        )],
    );
    create_state_database_with_rollout(&root, "019ededup-0000-0000-0000-samefile", &rollout_path);

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 77);
    assert_eq!(snapshot.stats.total_calls, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ranks_sessions_by_low_cache_hit_rate_with_thread_titles() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let low_id = "019elow0-0000-0000-0000-000000000001";
    let high_id = "019ehigh-0000-0000-0000-000000000002";
    write_lines(
        &session_dir.join(format!("rollout-{low_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":300,"output_tokens":50,"total_tokens":1250}}}}"#,
            r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":40,"total_tokens":1040}}}}"#,
        ],
    );
    write_lines(
        &session_dir.join(format!("rollout-{high_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1100,"output_tokens":50,"total_tokens":1250}}}}"#,
            r#"{"timestamp":"2026-06-18T02:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":40,"total_tokens":1040}}}}"#,
        ],
    );
    create_state_database(&root, low_id, high_id);

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.cache_hit_ranking.len(), 2);
    assert_eq!(snapshot.cache_hit_ranking[0].rank, 1);
    assert_eq!(snapshot.cache_hit_ranking[0].title, "低命中会话");
    assert_eq!(snapshot.cache_hit_ranking[0].input_tokens, 2_200);
    assert_eq!(snapshot.cache_hit_ranking[0].cached_tokens, 500);
    assert!(snapshot.cache_hit_ranking[0].hit_rate < snapshot.cache_hit_ranking[1].hit_rate);
    assert!(snapshot.cache_hit_ranking[0].subtitle.contains("2 轮"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_session_rollup_combines_multiple_published_files_for_one_session() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let sessions_dir = root.join("sessions");
    let archived_dir = root.join("archived_sessions");
    fs::create_dir_all(&sessions_dir).unwrap();
    fs::create_dir_all(&archived_dir).unwrap();
    let session_id = "019emulti-0000-0000-0000-000000000001";
    write_lines(
        &sessions_dir.join(format!("rollout-2026-06-18T01-00-00-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":200,"output_tokens":50,"total_tokens":1250}}}}"#,
        ],
    );
    write_lines(
        &archived_dir.join(format!("rollout-2026-06-18T02-00-00-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1400,"cached_input_tokens":300,"output_tokens":70,"total_tokens":1470}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    let session = snapshot
        .cache_usage
        .sessions
        .iter()
        .find(|session| session.id == session_id)
        .unwrap();
    assert_eq!(snapshot.stats.total_threads, 1);
    assert_eq!(session.breakdown.calls, 2);
    assert_eq!(session.breakdown.total_tokens, 2_720);
    assert_eq!(session.breakdown.input_tokens, 2_600);
    assert_eq!(session.breakdown.cached_input_tokens, 500);
    assert_eq!(session.breakdown.output_tokens, 120);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exposes_cache_usage_sessions_and_turns_with_message_excerpts() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eturn-0000-0000-0000-000000000003";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"第一轮问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:20Z","type":"event_msg","payload":{"type":"agent_message","message":"第一轮回答"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
            r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"user_message","message":"第二轮\n问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:05:20Z","type":"event_msg","payload":{"type":"agent_message","message":"第二轮回答\t补充"}}"#,
            r#"{"timestamp":"2026-06-18T01:06:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1300,"cached_input_tokens":600,"output_tokens":80,"total_tokens":1380}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.cache_usage.sessions.len(), 1);
    assert_eq!(snapshot.cache_usage.sessions[0].breakdown.calls, 2);
    assert_eq!(snapshot.cache_usage.turns.len(), 2);
    let second_turn = snapshot
        .cache_usage
        .turns
        .iter()
        .find(|turn| turn.turn_index_in_session == 2)
        .unwrap();
    assert_eq!(second_turn.user_prompt, "第二轮 问题");
    assert_eq!(second_turn.assistant_response, "第二轮回答 补充");
    assert_eq!(second_turn.breakdown.input_tokens, 1300);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cache_usage_keeps_latest_candidates_beyond_low_hit_cutoff() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let base_time = OffsetDateTime::now_utc() - time::Duration::days(10);

    for index in 0..45 {
        let session_id = format!("019elowlatest-{index:04}-0000-0000-000000000001");
        let first_timestamp = (base_time + time::Duration::minutes(i64::from(index * 2)))
            .format(&Rfc3339)
            .unwrap();
        let second_timestamp = (base_time + time::Duration::minutes(i64::from(index * 2 + 1)))
            .format(&Rfc3339)
            .unwrap();
        write_lines(
            &session_dir.join(format!("rollout-{session_id}.jsonl")),
            &[
                format!(
                    r#"{{"timestamp":"{first_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":0,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
                ),
                format!(
                    r#"{{"timestamp":"{second_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":0,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
                ),
            ],
        );
    }

    let latest_id = "019elatest-high-0000-0000-000000000099";
    let first_latest = (OffsetDateTime::now_utc() - time::Duration::minutes(2))
        .format(&Rfc3339)
        .unwrap();
    let second_latest = (OffsetDateTime::now_utc() - time::Duration::minutes(1))
        .format(&Rfc3339)
        .unwrap();
    write_lines(
        &session_dir.join(format!("rollout-{latest_id}.jsonl")),
        &[
            format!(
                r#"{{"timestamp":"{first_latest}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":1390,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
            ),
            format!(
                r#"{{"timestamp":"{second_latest}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":1390,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
            ),
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert!(snapshot
        .cache_usage
        .sessions
        .iter()
        .any(|session| session.id == latest_id));
    assert!(snapshot
        .cache_usage
        .turns
        .iter()
        .any(|turn| turn.session_id == latest_id && turn.turn_index_in_session == 2));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cache_usage_latest_accepts_sub_1000_and_aggregate_upgrade_rebuilds_only_derived_rows() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019esub1000-latest-0000-0000-000000000001";
    let first_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(2))
        .format(&Rfc3339)
        .unwrap();
    let second_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(1))
        .format(&Rfc3339)
        .unwrap();
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            format!(
                r#"{{"timestamp":"{first_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":400,"cached_input_tokens":200,"output_tokens":50,"total_tokens":450}}}}}}}}"#
            ),
            format!(
                r#"{{"timestamp":"{second_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":400,"cached_input_tokens":200,"output_tokens":50,"total_tokens":450}}}}}}}}"#
            ),
        ],
    );

    let first = dashboard_snapshot(&root).unwrap();
    let session = first
        .cache_usage
        .sessions
        .iter()
        .find(|session| session.id == session_id)
        .expect("latest session with sub-1000 input must be visible");
    assert_eq!(session.breakdown.calls, 2);
    assert_eq!(session.breakdown.input_tokens, 800);
    assert_eq!(
        first
            .cache_usage
            .turns
            .iter()
            .filter(|turn| turn.session_id == session_id)
            .count(),
        2,
        "latest turns with sub-1000 input must be visible"
    );
    assert!(first
        .cache_usage
        .turns
        .iter()
        .filter(|turn| turn.session_id == session_id)
        .all(|turn| turn.breakdown.input_tokens < 1_000));
    assert!(
        first.cache_hit_ranking.is_empty(),
        "low-hit ranking must retain the 1000-input cutoff"
    );

    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    let event_count_before = connection
        .query_row("SELECT COUNT(*) FROM events", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM dashboard_turn_candidates",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        2
    );
    connection
        .execute("DELETE FROM dashboard_turn_candidates", [])
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '3' WHERE key = 'dashboard_aggregate_schema_version'",
            [],
        )
        .unwrap();
    drop(connection);

    reset_dashboard_aggregate_build_count_for_testing();
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let upgraded = dashboard_snapshot(&root).unwrap();
    assert_eq!(ExactUsageIndex::scan_bytes_for_testing(), (0, 0));
    assert!(upgraded
        .cache_usage
        .sessions
        .iter()
        .any(|session| session.id == session_id));
    assert_eq!(
        upgraded
            .cache_usage
            .turns
            .iter()
            .filter(|turn| turn.session_id == session_id)
            .count(),
        2
    );
    assert!(upgraded.cache_hit_ranking.is_empty());

    let connection = Connection::open(database).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM events", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        event_count_before
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM dashboard_turn_candidates",
                [],
                |row| { row.get::<_, i64>(0) }
            )
            .unwrap(),
        2
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'dashboard_aggregate_schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "4"
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_reuses_cached_aggregate_when_session_signatures_are_unchanged() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eaaaa-bbbb-cccc-dddd-incremental";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    reset_dashboard_aggregate_build_count_for_testing();

    let first = dashboard_snapshot(&root).unwrap();
    let build_count_after_first_load = dashboard_aggregate_build_count_for_testing(&root);
    let second = dashboard_snapshot(&root).unwrap();

    assert_eq!(first.stats.total_tokens, 120);
    assert_eq!(second.stats.total_tokens, 120);
    assert!(build_count_after_first_load >= 1);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        build_count_after_first_load
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_reuses_numeric_cache_after_thread_metadata_changes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eaaaa-bbbb-cccc-dddd-state-churn";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    create_state_database(&root, session_id, "019ehigh-0000-0000-0000-state-churn2");
    reset_dashboard_aggregate_build_count_for_testing();

    let first = dashboard_snapshot(&root).unwrap();
    let build_count_after_first_load = dashboard_aggregate_build_count_for_testing(&root);
    let before_metadata_change = ExactUsageIndex::open(&root).unwrap();
    let before_revision = before_metadata_change.revision().unwrap();
    let before_dashboard_revision = before_metadata_change.dashboard_revision().unwrap();
    let before_published_generation = before_metadata_change.published_generation().unwrap();
    drop(before_metadata_change);
    {
        let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
        connection
            .execute(
                "UPDATE threads SET title = '重命名后的标题', updated_at = updated_at + 1, updated_at_ms = updated_at_ms + 1000 WHERE id = ?1;",
                [session_id],
            )
            .unwrap();
    }
    let second = dashboard_snapshot(&root).unwrap();
    let after_metadata_change = ExactUsageIndex::open(&root).unwrap();

    assert_eq!(first.stats.total_tokens, 120);
    assert_eq!(second.stats.total_tokens, 120);
    assert!(build_count_after_first_load >= 1);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        build_count_after_first_load,
        "thread metadata churn must not rebuild the numeric dashboard aggregate"
    );
    assert!(after_metadata_change.revision().unwrap() > before_revision);
    assert_eq!(
        after_metadata_change.dashboard_revision().unwrap(),
        before_dashboard_revision,
        "thread metadata must not advance the numeric dashboard lineage"
    );
    assert_eq!(
        after_metadata_change.published_generation().unwrap(),
        before_published_generation,
        "thread metadata must not advance exact attribution generation"
    );
    drop(after_metadata_change);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_revision_advances_for_event_append() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session = session_dir.join("rollout-019e-dashboard-revision-append.jsonl");
    write_lines(
        &session,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    reset_dashboard_aggregate_build_count_for_testing();
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let before = ExactUsageIndex::open(&root).unwrap();
    let before_dashboard_revision = before.dashboard_revision().unwrap();
    drop(before);

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&session).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 170);
    let after = ExactUsageIndex::open(&root).unwrap();
    assert!(after.dashboard_revision().unwrap() > before_dashboard_revision);
    drop(after);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_revision_backfills_without_rebuilding_a_legacy_index() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019e-dashboard-revision-legacy.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    dashboard_snapshot(&root).unwrap();
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let before = ExactUsageIndex::open(&root).unwrap();
    let revision = before.revision().unwrap();
    drop(before);
    Connection::open(&database)
        .unwrap()
        .execute("DELETE FROM metadata WHERE key = 'dashboard_revision'", [])
        .unwrap();

    let upgraded = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(upgraded.revision().unwrap(), revision);
    assert_eq!(upgraded.dashboard_revision().unwrap(), revision);
    drop(upgraded);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn negative_dashboard_revision_is_rejected_instead_of_clamped() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019e-dashboard-revision-negative.jsonl"),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#],
    );
    let _ = dashboard_snapshot(&root).unwrap();
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '-1' WHERE key = 'dashboard_revision'",
            [],
        )
        .unwrap();
    drop(connection);

    let index = ExactUsageIndex::open(&root).unwrap();
    let error = index.dashboard_revision().unwrap_err();
    assert!(error.contains("dashboard_revision") || error.contains("无效"));

    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_v1_upgrade_keeps_older_file_generations_without_jsonl_reads() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let changed = session_dir.join("rollout-019e-dashboard-v1-changed.jsonl");
    let unchanged = session_dir.join("rollout-019e-dashboard-v1-unchanged.jsonl");
    write_lines(
        &changed,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &unchanged,
        &[
            r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);
    {
        let mut append = fs::OpenOptions::new().append(true).open(&changed).unwrap();
        writeln!(
            append,
            r#"{{"timestamp":"2026-06-18T01:04:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 200);

    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    let published_generation = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    let distinct_visible_generations = connection
        .query_row(
            "SELECT COUNT(DISTINCT generation) FROM published_files",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert!(
        distinct_visible_generations > 1,
        "fixture must retain an unchanged file from an older exact generation"
    );
    connection.execute("DELETE FROM dashboard_5m", []).unwrap();
    connection
        .execute(
            "INSERT INTO metadata(key, value) VALUES ('dashboard_aggregate_schema_version', '1') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )
        .unwrap();
    drop(connection);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let upgraded = dashboard_snapshot(&root).unwrap();
    assert_eq!(ExactUsageIndex::scan_bytes_for_testing(), (0, 0));
    assert_eq!(upgraded.stats.total_tokens, 200);
    assert_eq!(
        upgraded
            .stats
            .model_breakdowns
            .iter()
            .map(|row| row.breakdown.total_tokens)
            .sum::<u64>(),
        200,
        "global five-minute upgrade must include unchanged older file generations"
    );
    let connection = Connection::open(database).unwrap();
    let aggregate_generation = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'dashboard_aggregate_exact_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(aggregate_generation, published_generation);
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(DISTINCT file_generation) FROM dashboard_5m",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn lifetime_model_breakdown_reads_all_published_file_generations() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019e-lifetime-model-sol.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":20,"total_tokens":100}}}}"#,
        ],
    );
    write_lines(
        &session_dir.join("rollout-019e-lifetime-model-luna.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:02:00Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            r#"{"timestamp":"2026-06-18T01:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    let mut by_model = snapshot
        .stats
        .model_breakdowns
        .iter()
        .filter_map(|row| row.model.as_ref().map(|model| (model.as_str(), row.breakdown.total_tokens)))
        .collect::<std::collections::HashMap<_, _>>();
    assert_eq!(snapshot.stats.total_tokens, 150);
    assert_eq!(by_model.remove("gpt-5.6-sol"), Some(100));
    assert_eq!(by_model.remove("gpt-5.6-luna"), Some(50));
    assert_eq!(snapshot.stats.model_breakdowns.iter().map(|row| row.breakdown.total_tokens).sum::<u64>(), 150);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn summary_generation_full_aggregate_repair_keeps_unchanged_files() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let changed = session_dir.join("rollout-019e-summary-aggregate-changed.jsonl");
    let unchanged = session_dir.join("rollout-019e-summary-aggregate-unchanged.jsonl");
    write_lines(
        &changed,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    write_lines(
        &unchanged,
        &[r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);

    {
        let mut append = fs::OpenOptions::new().append(true).open(&changed).unwrap();
        writeln!(
            append,
            r#"{{"timestamp":"2026-06-18T01:04:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }

    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    index
        .sync_with_scan_plan_mode(&root, &mut warnings, None, None, ExactSyncMode::Summary)
        .unwrap();
    index.ensure_dashboard_aggregates(&root).unwrap();
    let data = index
        .dashboard_data_with_system_timezone(&root, OffsetDateTime::now_utc(), &mut warnings)
        .unwrap();

    assert_eq!(data.stats.total_tokens, 200);
    assert_eq!(
        data.stats
            .model_breakdowns
            .iter()
            .map(|row| row.breakdown.total_tokens)
            .sum::<u64>(),
        200
    );
    assert!(warnings.is_empty(), "unexpected warnings: {warnings:?}");
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn current_dashboard_aggregate_truncation_self_repairs_without_jsonl_body_reads() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019e-dashboard-integrity-old.jsonl"),
        &[r#"{"timestamp":"2026-06-17T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":20,"total_tokens":100}}}}"#],
    );
    write_lines(
        &session_dir.join("rollout-019e-dashboard-integrity-new.jsonl"),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}"#],
    );

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    let rows_before = connection
        .query_row("SELECT COUNT(*) FROM dashboard_5m", [], |row| row.get::<_, i64>(0))
        .unwrap();
    assert!(rows_before >= 2);
    connection
        .execute(
            r#"
            DELETE FROM dashboard_5m
            WHERE bucket_start = (SELECT MIN(bucket_start) FROM dashboard_5m)
            "#,
            [],
        )
        .unwrap();
    drop(connection);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);
    assert_eq!(ExactUsageIndex::scan_bytes_for_testing(), (0, 0));
    let index = ExactUsageIndex::open(&root).unwrap();
    assert!(index.dashboard_5m_projection_is_complete().unwrap());
    drop(index);
    let connection = Connection::open(database).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM dashboard_5m", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        rows_before
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn full_generation_after_summary_copies_the_last_aggregate_generation_not_the_newer_event_generation() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let changed = session_dir.join("rollout-019e-summary-gap-changed.jsonl");
    let unchanged = session_dir.join("rollout-019e-summary-gap-unchanged.jsonl");
    write_lines(
        &changed,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    write_lines(
        &unchanged,
        &[r#"{"timestamp":"2026-06-17T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);

    {
        let mut append = fs::OpenOptions::new().append(true).open(&changed).unwrap();
        writeln!(
            append,
            r#"{{"timestamp":"2026-06-18T01:04:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    index
        .sync_with_scan_plan_mode(&root, &mut warnings, None, None, ExactSyncMode::Summary)
        .unwrap();
    let summary_generation = index.published_generation().unwrap();
    let aggregate_generation = index
        .dashboard_aggregate_identity()
        .unwrap()
        .exact_generation
        .unwrap();
    assert!(summary_generation > aggregate_generation);
    drop(index);

    {
        let mut append = fs::OpenOptions::new().append(true).open(&changed).unwrap();
        writeln!(
            append,
            r#"{{"timestamp":"2026-06-18T01:08:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":60,"cached_input_tokens":15,"output_tokens":10,"total_tokens":70}}}}}}}}"#
        )
        .unwrap();
    }

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 270);
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(database).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_5m",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        270
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT MIN(bucket_start) FROM dashboard_5m",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        OffsetDateTime::parse("2026-06-17T01:00:00Z", &Rfc3339)
            .unwrap()
            .unix_timestamp()
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn lightweight_summary_reuses_unchanged_file_contributions() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let changed = session_dir.join("rollout-019e-summary-delta-changed.jsonl");
    let unchanged = session_dir.join("rollout-019e-summary-delta-unchanged.jsonl");
    write_lines(
        &changed,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    write_lines(
        &unchanged,
        &[r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#],
    );
    dashboard_snapshot(&root).unwrap();

    let now = OffsetDateTime::parse("2026-06-18T12:00:00Z", &Rfc3339).unwrap();
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let (before, mut contributions) = index
        .summary_with_file_contributions(now, None)
        .unwrap();
    assert_eq!(before.total_tokens, 150);
    let unchanged_path = fs::canonicalize(&unchanged).unwrap().to_string_lossy().into_owned();
    let unchanged_generation = contributions
        .get(&unchanged_path)
        .map(|contribution| contribution.generation)
        .unwrap();

    let mut append = fs::OpenOptions::new().append(true).open(&changed).unwrap();
    writeln!(
        append,
        r#"{{"timestamp":"2026-06-18T01:04:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
    )
    .unwrap();
    drop(append);
    let mut warnings = Vec::new();
    index
        .sync_with_scan_plan_mode(&root, &mut warnings, None, None, ExactSyncMode::Summary)
        .unwrap();
    let (after, updated) = index
        .summary_with_file_contributions(now, Some(&contributions))
        .unwrap();
    contributions = updated;

    assert_eq!(after.total_tokens, 200);
    assert_eq!(
        contributions
            .get(&unchanged_path)
            .map(|contribution| contribution.generation),
        Some(unchanged_generation)
    );
    assert!(warnings.is_empty(), "unexpected warnings: {warnings:?}");
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_global_bucket_append_retains_unchanged_file_contributions() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    reset_dashboard_aggregate_build_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let changed = session_dir.join("rollout-019e-global-bucket-changed.jsonl");
    let unchanged = session_dir.join("rollout-019e-global-bucket-unchanged.jsonl");
    write_lines(
        &changed,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &unchanged,
        &[
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);

    {
        let mut append = fs::OpenOptions::new().append(true).open(&changed).unwrap();
        writeln!(
            append,
            r#"{{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }

    reset_dashboard_aggregate_build_count_for_testing();
    let updated = dashboard_snapshot(&root).unwrap();
    assert_eq!(updated.stats.total_tokens, 200);
    assert_eq!(
        updated
            .stats
            .model_breakdowns
            .iter()
            .map(|row| row.breakdown.total_tokens)
            .sum::<u64>(),
        200
    );
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(database).unwrap();
    assert_eq!(
        connection
            .query_row(
                r#"
                SELECT COALESCE(SUM(total_tokens), 0)
                FROM dashboard_5m
                WHERE file_generation = (
                    SELECT CAST(value AS INTEGER)
                    FROM metadata
                    WHERE key = 'published_generation'
                )
                "#,
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        200
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn future_dashboard_aggregate_version_fails_closed_without_rewriting_rows() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019e-dashboard-aggregate-future.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    let rows_before = connection
        .query_row("SELECT COUNT(*) FROM dashboard_5m", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '99' WHERE key = 'dashboard_aggregate_schema_version'",
            [],
        )
        .unwrap();
    drop(connection);
    reset_dashboard_aggregate_build_count_for_testing();

    let error = dashboard_snapshot(&root).unwrap_err();
    assert!(error.contains("高于当前支持版本"), "{error}");
    let connection = Connection::open(database).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM dashboard_5m", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        rows_before
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'dashboard_aggregate_schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "99"
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn unknown_dashboard_pricing_revision_fails_closed_without_rewriting_rows() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019e-dashboard-pricing-future.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    let rows_before = connection
        .query_row("SELECT COUNT(*) FROM dashboard_5m", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = 'future-price-v2' WHERE key = 'dashboard_aggregate_pricing_revision'",
            [],
        )
        .unwrap();
    drop(connection);

    let error = dashboard_snapshot(&root).unwrap_err();
    assert!(error.contains("计价契约"), "{error}");
    let connection = Connection::open(database).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM dashboard_5m", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        rows_before
    );

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_cache_does_not_persist_conversation_text() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let secret_question = "不要写进缓存的问题";
    let secret_answer = "不要写进缓存的回答";
    let user_line = format!(
        r#"{{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{{"type":"user_message","message":"{secret_question}"}}}}"#
    );
    let assistant_line = format!(
        r#"{{"timestamp":"2026-06-18T01:00:20Z","type":"event_msg","payload":{{"type":"agent_message","message":"{secret_answer}"}}}}"#
    );
    write_lines(
        &session_dir.join("rollout-019esecret-0000-0000-0000-cachetext.jsonl"),
        &[
            user_line.as_str(),
            assistant_line.as_str(),
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.cache_usage.turns[0].user_prompt, secret_question);
    let cache_text = app_paths::token_aggregate_cache_path()
        .and_then(|path| fs::read_to_string(path).ok())
        .unwrap_or_default();
    assert!(!cache_text.contains(secret_question));
    assert!(!cache_text.contains(secret_answer));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_persists_a_compact_startup_snapshot_then_rebuilds_full_details() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eslim-aggregate.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"prompt"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:20Z","type":"event_msg","payload":{"type":"agent_message","message":"answer"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
        ],
    );

    let full = dashboard_snapshot(&root).unwrap();
    assert!(!full.recent_usage_24h.is_empty());
    assert!(!full.cache_usage.turns.is_empty());
    assert!(full.precise_recent_usage_fresh);
    assert!(full.precise_recent_usage_covered_at.is_some());
    assert!(full.settled_through.is_some());
    let persisted = fs::read(&cache_path).unwrap();
    assert!(
        persisted.len() < 4 * 1024 * 1024,
        "numeric aggregate was {} bytes",
        persisted.len()
    );
    let json: serde_json::Value = serde_json::from_slice(&persisted).unwrap();
    assert_eq!(json["version"], 20);
    assert!(json.get("snapshot").is_none());
    let persisted_text = String::from_utf8_lossy(&persisted);
    assert!(!persisted_text.contains("sourceContribution"));
    assert!(!persisted_text.contains("cacheHitRanking"));
    assert!(!persisted_text.contains("cacheUsage"));
    assert!(!persisted_text.contains("preciseObserver"));
    assert_eq!(
        json["recentUsage24h"].as_array().unwrap().len(),
        full.recent_usage_24h.len()
    );
    assert!(json.get("preciseRecentUsageFresh").is_none());
    assert_eq!(
        json["coverageAt"].as_str(),
        full.precise_recent_usage_covered_at.as_deref()
    );
    assert_eq!(
        json["settledThrough"].as_str(),
        full.settled_through.as_deref()
    );
    assert!(json.get("account").is_none());
    assert!(json.get("quota").is_none());
    assert!(json.get("cacheHitRanking").is_none());
    assert!(json.get("cacheUsage").is_none());
    assert!(json.get("warnings").is_none());
    assert!(json.get("diagnostics").is_none());
    assert!(json.get("preciseObserverEpoch").is_none());

    reset_dashboard_aggregate_build_count_for_testing();
    let integrity_receipt = integrity_receipt_path_for_testing(&root).unwrap();
    fs::remove_file(&integrity_receipt).unwrap();
    ExactUsageIndex::clear_integrity_signature_for_testing(&root);
    ExactUsageIndex::reset_quick_check_count_for_testing();
    let startup = cached_dashboard_snapshot_for_startup(&root).unwrap();
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);
    assert!(!integrity_receipt.exists());
    assert_eq!(startup.recent_usage_24h.len(), full.recent_usage_24h.len());
    assert!(startup.cache_usage.turns.is_empty());
    assert!(!startup.precise_recent_usage_fresh);
    assert_eq!(
        startup.precise_recent_usage_covered_at,
        full.precise_recent_usage_covered_at
    );
    assert_eq!(startup.settled_through, full.settled_through);
    let compact_index = ExactUsageIndex::open(&root).unwrap();
    let compact_signature = dashboard_index_signature(&root, compact_index.revision().unwrap());
    drop(compact_index);
    let compact_summary = cached_dashboard_usage_summary(&root).unwrap();
    store_usage_summary(compact_signature.clone(), compact_summary);
    assert!(
        cached_dashboard_snapshot(&compact_signature).is_none(),
        "a compact persisted snapshot must never be promoted to full exact coverage"
    );
    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert!(!rebuilt.recent_usage_24h.is_empty());
    assert!(!rebuilt.cache_usage.turns.is_empty());
    assert!(rebuilt.precise_recent_usage_fresh);
    assert!(rebuilt.precise_recent_usage_covered_at.is_some());
    assert_eq!(dashboard_aggregate_build_count_for_testing(&root), 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn v20_startup_accepts_stale_last_good_after_monotonic_index_advance_without_open() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ev19-monotonic-startup.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();

    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    for key in ["revision", "published_generation"] {
        let current = connection
            .query_row(
                "SELECT value FROM metadata WHERE key = ?1",
                params![key],
                |row| row.get::<_, String>(0),
            )
            .unwrap()
            .parse::<u64>()
            .unwrap();
        connection
            .execute(
                "UPDATE metadata SET value = ?2 WHERE key = ?1",
                params![key, current.saturating_add(1).to_string()],
            )
            .unwrap();
    }
    drop(connection);

    let receipt = integrity_receipt_path_for_testing(&root).unwrap();
    let receipt_before = fs::read(&receipt).unwrap();
    reset_dashboard_aggregate_build_count_for_testing();
    ExactUsageIndex::clear_integrity_signature_for_testing(&root);
    ExactUsageIndex::reset_quick_check_count_for_testing();
    let stale = cached_dashboard_snapshot_for_startup(&root)
        .expect("same-provenance monotonic advance should retain stale V20 numerics");

    assert_eq!(stale.stats.total_tokens, 120);
    assert!(!stale.precise_recent_usage_fresh);
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);
    assert_eq!(fs::read(receipt).unwrap(), receipt_before);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn v18_sensitive_snapshot_is_sanitized_again_before_startup_use() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let signature = dashboard_scan_signature_at(
        &root,
        7,
        OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap(),
        UtcOffset::UTC,
    );
    let summary = TokenUsageSummary {
        total_tokens: 42,
        today_tokens: 42,
        today_requests: 1,
        today_model_breakdowns: Vec::new(),
    };
    let mut snapshot = persistent_numeric_test_snapshot(&summary);
    snapshot.account.display_name = "secret-account".into();
    snapshot.account.plan_label = "secret-plan".into();
    snapshot
        .cache_hit_ranking
        .push(crate::models::CacheHitRankingItem {
            rank: 1,
            title: "secret-title".into(),
            subtitle: "secret-subtitle".into(),
            hit_rate: 0.5,
            input_tokens: 100,
            cached_tokens: 50,
        });
    snapshot
        .cache_usage
        .sessions
        .push(crate::models::SessionCacheUsage {
            id: "secret-session".into(),
            title: "secret-session-title".into(),
            last_updated: None,
            breakdown: Default::default(),
        });
    snapshot
        .cache_usage
        .turns
        .push(crate::models::TurnCacheUsage {
            id: "secret-turn".into(),
            session_id: "secret-session".into(),
            session_title: "secret-session-title".into(),
            timestamp: "2026-06-18T01:00:00Z".into(),
            turn_index_in_session: 1,
            user_prompt: "secret-prompt".into(),
            assistant_response: "secret-answer".into(),
            breakdown: Default::default(),
        });
    snapshot.warnings.push(LocalDataWarning {
        source: "secret-warning-source".into(),
        message: "secret-warning".into(),
    });
    snapshot.diagnostics.push(crate::models::QuotaDiagnostic {
        source: "secret-diagnostic-source".into(),
        category: "secret-category".into(),
        severity: "error".into(),
        message: "secret-diagnostic".into(),
        raw_cause: Some("secret-cause".into()),
        underlying_category: None,
        attempts: Some(1),
        http_status: Some(500),
        retryable: false,
        occurred_at: "2026-06-18T01:00:00Z".into(),
        stale_data_displayed: true,
    });
    snapshot.precise_recent_usage_fresh = true;
    snapshot.precise_observer_epoch = Some("secret-observer".into());
    snapshot.precise_attribution_provenance_epoch = Some("secret-provenance".into());
    snapshot
        .recent_usage_24h
        .push(crate::models::RecentUsagePoint {
            label: "01:00".into(),
            start_unix: 1_781_715_600,
            tokens: 42,
            calls: 1,
            input_tokens: 40,
            cached_input_tokens: 4,
            output_tokens: 2,
            model_breakdowns: Vec::new(),
            cache_hit_rate: Some(0.1),
            five_hour_remaining_percent: None,
            seven_day_remaining_percent: None,
            source_contribution_epoch: Some("secret-source-epoch".into()),
            source_contributions: vec![crate::models::RecentUsageSourceContribution {
                source_id: "secret-source-id".into(),
                tokens: 42,
                calls: 1,
                input_tokens: 40,
                cached_input_tokens: 4,
                output_tokens: 2,
            }],
        });

    let legacy = PersistentDashboardAggregateCache {
        version: LEGACY_DASHBOARD_AGGREGATE_CACHE_VERSION,
        signature,
        snapshot: Some(snapshot),
        summary,
    };
    let decoded = decode_persistent_dashboard_aggregate(&serde_json::to_vec(&legacy).unwrap())
        .expect("V18 cache should remain readable as stale data");
    let restored = decoded
        .snapshot
        .expect("legacy snapshot should be retained");
    assert_eq!(restored.account.display_name, "账户待读取");
    assert_eq!(restored.account.plan_label, "计划待读取");
    assert!(restored.cache_hit_ranking.is_empty());
    assert!(restored.cache_usage.sessions.is_empty());
    assert!(restored.cache_usage.turns.is_empty());
    assert!(restored.warnings.is_empty());
    assert!(restored.diagnostics.is_empty());
    assert!(!restored.precise_recent_usage_fresh);
    assert!(restored.precise_observer_epoch.is_none());
    assert!(restored.precise_attribution_provenance_epoch.is_none());
    assert!(restored.recent_usage_24h[0]
        .source_contribution_epoch
        .is_none());
    assert!(restored.recent_usage_24h[0].source_contributions.is_empty());
    fs::remove_dir_all(root).unwrap();
}

/// Build an envelope with the exact field surface used by the public v0.8.3
/// tag (ee557fd1a47fe4cf35485cfd7f613db98f2fa1a0), then apply only the fields
/// introduced by the later v17/v18 members. This keeps the compatibility test
/// tied to the shipped DashboardSnapshot family instead of a hand-written
/// replacement schema.
fn public_legacy_dashboard_fixture(
    version: u32,
    signature: DashboardScanSignature,
    snapshot: &DashboardSnapshot,
    summary: TokenUsageSummary,
) -> Vec<u8> {
    let mut envelope = serde_json::to_value(PersistentDashboardAggregateCache {
        version,
        signature,
        snapshot: Some(snapshot.clone()),
        summary,
    })
    .unwrap();
    let snapshot = envelope
        .get_mut("snapshot")
        .and_then(serde_json::Value::as_object_mut)
        .expect("legacy fixture snapshot object");

    // v17 added attribution fields; v16 is the public v0.8.3 shape and has
    // none of them. V18 retains this envelope and adds model breakdowns.
    if version == LEGACY_DASHBOARD_AGGREGATE_CACHE_V16 {
        for field in [
            "preciseRecentUsageCoveredAt",
            "preciseRecentUsageFresh",
            "preciseObserverEpoch",
            "preciseObserverStartedAtUnixMicros",
            "preciseObserverSequence",
            "preciseAttributionProvenanceEpoch",
            "preciseAttributionGeneration",
            "preciseAttributionUnsafeSinceGeneration",
            "preciseAttributionUnsafeId",
            "preciseAttributionCurrentScanUnsafe",
        ] {
            snapshot.remove(field);
        }
    }
    if version <= LEGACY_DASHBOARD_AGGREGATE_CACHE_V17 {
        snapshot
            .get_mut("stats")
            .and_then(serde_json::Value::as_object_mut)
            .expect("legacy fixture stats object")
            .remove("modelBreakdowns");
        snapshot
            .get_mut("activityDays")
            .and_then(serde_json::Value::as_array_mut)
            .expect("legacy fixture activity array")
            .iter_mut()
            .filter_map(serde_json::Value::as_object_mut)
            .for_each(|day| {
                day.remove("modelBreakdowns");
            });
        for field in ["recentUsage24h", "recentUsage7d", "recentUsage30d"] {
            snapshot
                .get_mut(field)
                .and_then(serde_json::Value::as_array_mut)
                .expect("legacy fixture recent usage array")
                .iter_mut()
                .filter_map(serde_json::Value::as_object_mut)
                .for_each(|point| {
                    point.remove("modelBreakdowns");
                });
        }
    }
    if version == LEGACY_DASHBOARD_AGGREGATE_CACHE_V16 {
        for field in ["recentUsage24h", "recentUsage7d", "recentUsage30d"] {
            snapshot
                .get_mut(field)
                .and_then(serde_json::Value::as_array_mut)
                .expect("legacy fixture recent usage array")
                .iter_mut()
                .filter_map(serde_json::Value::as_object_mut)
                .for_each(|point| {
                    point.remove("sourceContributionEpoch");
                    point.remove("sourceContributions");
                });
        }
    }
    serde_json::to_vec(&envelope).unwrap()
}

#[test]
fn legacy_dashboard_envelope_accepts_public_v16_v17_v18_and_sanitizes_stale_restore() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let signature = dashboard_scan_signature_at(
        &root,
        7,
        OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap(),
        UtcOffset::UTC,
    );
    let summary = TokenUsageSummary {
        total_tokens: 42,
        today_tokens: 42,
        today_requests: 1,
        today_model_breakdowns: Vec::new(),
    };
    let mut snapshot = persistent_numeric_test_snapshot(&summary);
    snapshot.account.display_name = "legacy-secret-account".into();
    snapshot.quota.pace_label = "legacy-secret-quota".into();
    snapshot
        .cache_hit_ranking
        .push(crate::models::CacheHitRankingItem {
            rank: 1,
            title: "legacy-secret-title".into(),
            subtitle: "legacy-secret-subtitle".into(),
            hit_rate: 0.5,
            input_tokens: 100,
            cached_tokens: 50,
        });
    snapshot
        .cache_usage
        .turns
        .push(crate::models::TurnCacheUsage {
            id: "legacy-secret-turn".into(),
            session_id: "legacy-secret-session".into(),
            session_title: "legacy-secret-session-title".into(),
            timestamp: "2026-06-18T01:00:00Z".into(),
            turn_index_in_session: 1,
            user_prompt: "legacy-secret-prompt".into(),
            assistant_response: "legacy-secret-answer".into(),
            breakdown: Default::default(),
        });
    snapshot.warnings.push(LocalDataWarning {
        source: "legacy-secret-warning".into(),
        message: "legacy-secret-warning-message".into(),
    });
    snapshot
        .recent_usage_24h
        .push(crate::models::RecentUsagePoint {
            label: "01:00".into(),
            start_unix: 1_781_715_600,
            tokens: 42,
            calls: 1,
            input_tokens: 40,
            cached_input_tokens: 4,
            output_tokens: 2,
            model_breakdowns: vec![crate::models::ModelTokenBreakdown {
                model: Some("legacy-model".into()),
                breakdown: Default::default(),
            }],
            cache_hit_rate: Some(0.1),
            five_hour_remaining_percent: None,
            seven_day_remaining_percent: None,
            source_contribution_epoch: Some("legacy-source-epoch".into()),
            source_contributions: vec![crate::models::RecentUsageSourceContribution {
                source_id: "legacy-source-id".into(),
                tokens: 42,
                calls: 1,
                input_tokens: 40,
                cached_input_tokens: 4,
                output_tokens: 2,
            }],
        });

    for version in [
        LEGACY_DASHBOARD_AGGREGATE_CACHE_V16,
        LEGACY_DASHBOARD_AGGREGATE_CACHE_V17,
        LEGACY_DASHBOARD_AGGREGATE_CACHE_VERSION,
    ] {
        let decoded = decode_persistent_dashboard_aggregate(&public_legacy_dashboard_fixture(
            version,
            signature.clone(),
            &snapshot,
            summary.clone(),
        ))
        .expect("public v16-v18 DashboardSnapshot envelope must decode");
        assert_eq!(decoded.persistent_version, version);
        let restored = decoded.snapshot.expect("legacy snapshot");
        assert_eq!(restored.account.display_name, "账户待读取");
        assert_eq!(restored.quota.pace_label, "额度待读取");
        assert!(restored.cache_hit_ranking.is_empty());
        assert!(restored.cache_usage.sessions.is_empty());
        assert!(restored.cache_usage.turns.is_empty());
        assert!(restored.warnings.is_empty());
        assert!(!restored.precise_recent_usage_fresh);
        assert!(restored.precise_observer_epoch.is_none());
        assert!(restored
            .recent_usage_24h
            .iter()
            .all(|point| point.source_contribution_epoch.is_none()
                && point.source_contributions.is_empty()));
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn public_v16_schema6_keeps_startup_last_good_then_enriches_once() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019epublic-v16-upgrade.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let full = dashboard_snapshot(&root).unwrap();
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let index = ExactUsageIndex::open(&root).unwrap();
    let signature = dashboard_index_signature(&root, index.revision().unwrap());
    drop(index);
    fs::write(
        &cache_path,
        public_legacy_dashboard_fixture(
            LEGACY_DASHBOARD_AGGREGATE_CACHE_V16,
            signature,
            &full,
            TokenUsageSummary {
                total_tokens: 120,
                today_tokens: 120,
                today_requests: 1,
                today_model_breakdowns: Vec::new(),
            },
        ),
    )
    .unwrap();

    // Recreate the public v0.8.3 exact schema6 shape. Startup may keep the
    // trusted last-good envelope while the normal owner performs one measured
    // model/reasoning enrichment pass over the old published watermark.
    let connection = Connection::open(&index_path).unwrap();
    for (table, column) in [
        ("files", "current_model"),
        ("files", "is_explicit_subagent_fork"),
        ("events", "model"),
        ("events", "reasoning_output_tokens"),
    ] {
        connection
            .execute(&format!("ALTER TABLE {table} DROP COLUMN {column}"), [])
            .unwrap();
    }
    connection
        .execute(
            "UPDATE metadata SET value = '6' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key = 'event_enrichment_revision'",
            [],
        )
        .unwrap();
    connection
        .execute("DELETE FROM event_enrichment_sources", [])
        .unwrap();
    drop(connection);

    reset_dashboard_aggregate_build_count_for_testing();
    assert!(
        cached_dashboard_snapshot_for_startup(&root).is_some(),
        "a supported old schema must keep its trusted startup last-good during enrichment"
    );

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 120);
    assert_eq!(
        ExactUsageIndex::scan_bytes_for_testing(),
        (
            fs::metadata(session_dir.join("rollout-019epublic-v16-upgrade.jsonl"))
                .unwrap()
                .len(),
            0
        )
    );
    let upgraded: serde_json::Value =
        serde_json::from_slice(&fs::read(&cache_path).unwrap()).unwrap();
    assert_eq!(upgraded["version"], DASHBOARD_AGGREGATE_CACHE_VERSION);
    assert!(upgraded.get("snapshot").is_none());
    assert!(fs::read_dir(cache_path.parent().unwrap())
        .unwrap()
        .flatten()
        .all(|entry| !entry
            .file_name()
            .to_string_lossy()
            .starts_with(".dashboard-aggregate.json.codex-token-bar-")));
    let connection = Connection::open(index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "9"
    );
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn v18_cache_is_automatically_upgraded_by_the_next_successful_full_refresh() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ev18-upgrade.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let full = dashboard_snapshot(&root).unwrap();
    let current =
        serde_json::from_slice::<serde_json::Value>(&fs::read(&cache_path).unwrap()).unwrap();
    let signature = serde_json::from_value::<DashboardScanSignature>(current["signature"].clone())
        .expect("current signature should remain decodable by the legacy adapter");
    let legacy = PersistentDashboardAggregateCache {
        version: LEGACY_DASHBOARD_AGGREGATE_CACHE_VERSION,
        signature,
        snapshot: Some(full),
        summary: TokenUsageSummary {
            total_tokens: 120,
            today_tokens: 120,
            today_requests: 1,
            today_model_breakdowns: Vec::new(),
        },
    };
    fs::write(&cache_path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    reset_dashboard_aggregate_build_count_for_testing();
    assert!(cached_dashboard_snapshot_for_startup(&root).is_some());
    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 120);
    let upgraded =
        serde_json::from_slice::<serde_json::Value>(&fs::read(&cache_path).unwrap()).unwrap();
    assert_eq!(upgraded["version"], DASHBOARD_AGGREGATE_CACHE_VERSION);
    assert!(upgraded.get("snapshot").is_none());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn legacy_startup_requires_exact_home_and_revision_signature() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let home_a = root.join("home-a");
    let home_b = root.join("home-b");
    fs::create_dir_all(&home_a).unwrap();
    fs::create_dir_all(&home_b).unwrap();

    let index_a = ExactUsageIndex::open(&home_a).unwrap();
    let signature_a = dashboard_index_signature(&home_a, index_a.revision().unwrap());
    let safety_a = index_a.attribution_safety_state().unwrap();
    let physical_a = attribution_watch_root_physical_identity(&home_a).unwrap();
    drop(index_a);
    let snapshot = persistent_numeric_test_snapshot(&TokenUsageSummary {
        total_tokens: 42,
        today_tokens: 42,
        today_requests: 1,
        today_model_breakdowns: Vec::new(),
    });
    fs::write(
        &cache_path,
        public_legacy_dashboard_fixture(
            LEGACY_DASHBOARD_AGGREGATE_CACHE_V16,
            signature_a.clone(),
            &snapshot,
            TokenUsageSummary {
                total_tokens: 42,
                today_tokens: 42,
                today_requests: 1,
                today_model_breakdowns: Vec::new(),
            },
        ),
    )
    .unwrap();

    // Deliberately keep date, offset, and revision equal while changing Home.
    // Legacy startup must not treat a stale envelope from home A as home B.
    let index_b = ExactUsageIndex::open(&home_b).unwrap();
    let safety_b = index_b.attribution_safety_state().unwrap();
    let physical_b = attribution_watch_root_physical_identity(&home_b).unwrap();
    let mut other_home_signature = signature_a.clone();
    other_home_signature.codex_home = home_b.clone();
    assert!(cached_dashboard_startup_snapshot(
        &other_home_signature,
        &home_b,
        &safety_b,
        &physical_b,
        None,
    )
    .is_none());
    drop(index_b);

    // A matching Home/date/offset with a different revision must also miss.
    let mut other_revision_signature = signature_a.clone();
    other_revision_signature.index_revision =
        other_revision_signature.index_revision.saturating_add(1);
    assert!(cached_dashboard_startup_snapshot(
        &other_revision_signature,
        &home_a,
        &safety_a,
        &physical_a,
        None,
    )
    .is_none());
    assert!(
        cached_dashboard_startup_snapshot(&signature_a, &home_a, &safety_a, &physical_a, None,)
            .is_some()
    );

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn legacy_alias_startup_matches_raw_signature_but_uses_only_canonical_index() {
    use std::os::unix::fs::symlink;

    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let canonical_home = root.join("canonical-home");
    let alias_home = root.join("alias-home");
    fs::create_dir_all(&canonical_home).unwrap();
    symlink(&canonical_home, &alias_home).unwrap();

    let index = ExactUsageIndex::open(&canonical_home).unwrap();
    let revision = index.revision().unwrap();
    drop(index);
    let raw_signature = dashboard_index_signature(&alias_home, revision);
    let snapshot = persistent_numeric_test_snapshot(&TokenUsageSummary {
        total_tokens: 42,
        today_tokens: 42,
        today_requests: 1,
        today_model_breakdowns: Vec::new(),
    });
    fs::write(
        &cache_path,
        public_legacy_dashboard_fixture(
            LEGACY_DASHBOARD_AGGREGATE_CACHE_V16,
            raw_signature,
            &snapshot,
            TokenUsageSummary {
                total_tokens: 42,
                today_tokens: 42,
                today_requests: 1,
                today_model_breakdowns: Vec::new(),
            },
        ),
    )
    .unwrap();

    let restored = cached_dashboard_snapshot_for_startup(&alias_home)
        .expect("matching raw alias signature should restore stale numerics");
    assert!(!restored.precise_recent_usage_fresh);

    let canonical_index_path = canonical_home
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let alias_index_path = alias_home
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    assert!(canonical_index_path.exists());
    assert_eq!(
        fs::canonicalize(&canonical_index_path).unwrap(),
        fs::canonicalize(&alias_index_path).unwrap(),
        "alias must resolve to the canonical index, not create a second database"
    );
    assert!(fs::symlink_metadata(&alias_home)
        .unwrap()
        .file_type()
        .is_symlink());

    fs::remove_file(&alias_home).unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn v20_startup_rejects_binding_signature_and_corrupt_cache_mismatches() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ev19-mismatch.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();
    let baseline = serde_json::from_slice::<serde_json::Value>(&fs::read(&cache_path).unwrap())
        .expect("full dashboard should publish V20 JSON");
    assert_eq!(baseline["version"], DASHBOARD_AGGREGATE_CACHE_VERSION);

    {
        let assert_miss = |candidate: serde_json::Value| {
            fs::write(&cache_path, serde_json::to_vec(&candidate).unwrap()).unwrap();
            reset_dashboard_aggregate_build_count_for_testing();
            assert!(
                cached_dashboard_snapshot_for_startup(&root).is_none(),
                "mismatched V20 binding must not hydrate startup numerics: {candidate}"
            );
        };

        let mut revision = baseline.clone();
        revision["signature"]["index_revision"] = serde_json::json!(u64::MAX);
        assert_miss(revision);
        let mut local_date = baseline.clone();
        local_date["signature"]["local_date"] = serde_json::json!("2099-01-01");
        assert_miss(local_date);
        let mut utc_offset = baseline.clone();
        utc_offset["signature"]["utc_offset_seconds"] = serde_json::json!(9 * 60 * 60);
        assert_miss(utc_offset);
        let mut canonical_home = baseline.clone();
        canonical_home["canonicalHome"] = serde_json::json!(root.join("other-home"));
        assert_miss(canonical_home);
        let mut physical_home = baseline.clone();
        physical_home["physicalHomeIdentity"] = serde_json::json!("not-the-same-home");
        assert_miss(physical_home);
        let mut provenance = baseline.clone();
        provenance["preciseAttributionProvenanceEpoch"] =
            serde_json::json!(Uuid::new_v4().to_string());
        assert_miss(provenance);
        assert_miss(serde_json::json!({"version": 20, "truncated": true}));
        fs::write(&cache_path, b"{").unwrap();
        reset_dashboard_aggregate_build_count_for_testing();
        assert!(cached_dashboard_snapshot_for_startup(&root).is_none());
    }

    fs::write(&cache_path, serde_json::to_vec(&baseline).unwrap()).unwrap();
    let database = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(&database).unwrap();
    connection
        .execute(
            "INSERT OR REPLACE INTO metadata (key, value) VALUES ('fork_replay_boundary_revision', 'wrong-parser')",
            [],
        )
        .unwrap();
    drop(connection);
    reset_dashboard_aggregate_build_count_for_testing();
    ExactUsageIndex::reset_quick_check_count_for_testing();
    assert!(cached_dashboard_snapshot_for_startup(&root).is_none());
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);

    let connection = Connection::open(&database).unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = ?1 WHERE key = 'fork_replay_boundary_revision'",
            params![STAGED_FULL_REBUILD_PARSER_REVISION],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '7' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    drop(connection);
    reset_dashboard_aggregate_build_count_for_testing();
    assert!(
        cached_dashboard_snapshot_for_startup(&root).is_some(),
        "a supported v7 index upgrade must keep the trusted last-good cache visible"
    );
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn v20_startup_rejects_symlink_cache_without_following_it() {
    use std::os::unix::fs::symlink;

    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let target_path = root.join("real-cache.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ev19-symlink.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();
    let baseline = fs::read(&cache_path).unwrap();
    fs::rename(&cache_path, &target_path).unwrap();
    symlink(&target_path, &cache_path).unwrap();
    reset_dashboard_aggregate_build_count_for_testing();
    assert!(load_persistent_dashboard_aggregate().is_err());
    assert!(cached_dashboard_snapshot_for_startup(&root).is_none());
    assert_eq!(fs::read(&target_path).unwrap(), baseline);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_does_not_poison_dashboard_aggregate_cache() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-0000-0000-0000-cache.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let summary = usage_summary(&root).unwrap();
    assert_eq!(summary.total_tokens, 120);
    assert!(!aggregate_cache_text().contains(r#""snapshot":null"#));

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(aggregate_cache_text().contains(r#""stats":{"#));

    reset_dashboard_aggregate_build_count_for_testing();
    let summary_after_restart = usage_summary(&root).unwrap();
    assert_eq!(summary_after_restart.total_tokens, 120);
    assert!(aggregate_cache_text().contains(r#""stats":{"#));
    assert!(!aggregate_cache_text().contains(r#""snapshot":null"#));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_rejects_v11_and_reuses_rebuilt_v20_dashboard_aggregate() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("token-aggregate-cache.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaggregate-stale-v11-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let signature = dashboard_index_signature(&root, 0);
    fs::write(
        &cache_path,
        serde_json::json!({
            "version": 11,
            "signature": signature,
            "snapshot": null,
            "summary": {
                "totalTokens": 999,
                "todayTokens": 999,
                "todayRequests": 9
            }
        })
        .to_string(),
    )
    .unwrap();

    let summary = usage_summary(&root).unwrap();

    assert_eq!(summary.total_tokens, 120);
    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(aggregate_cache_text().contains(r#""version":20"#));
    assert!(aggregate_cache_text().contains(r#""totalTokens":120"#));

    reset_dashboard_aggregate_build_count_for_testing();
    let reused = usage_summary(&root).unwrap();
    assert_eq!(reused.total_tokens, 120);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        0,
        "current v20 aggregate should be reused after memory state is cleared"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cached_usage_summary_is_scoped_to_codex_home() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let home_a = root.join("codex-a");
    let home_b = root.join("codex-b");
    let session_dir_a = home_a.join("sessions");
    let session_dir_b = home_b.join("sessions");
    fs::create_dir_all(&session_dir_a).unwrap();
    fs::create_dir_all(&session_dir_b).unwrap();
    write_lines(
        &session_dir_a.join("rollout-019ehome-a-0000-0000-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &session_dir_b.join("rollout-019ehome-b-0000-0000-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":10,"total_tokens":30}}}}"#,
        ],
    );

    let snapshot_a = dashboard_snapshot(&home_a).unwrap();
    assert_eq!(snapshot_a.stats.total_tokens, 120);
    assert_eq!(
        cached_dashboard_usage_summary(&home_a)
            .expect("home A should have a trusted cached summary")
            .total_tokens,
        120
    );
    assert!(
        cached_dashboard_usage_summary(&home_b).is_none(),
        "home A aggregate must not become a trusted compact summary for home B"
    );
    reset_dashboard_aggregate_build_count_for_testing();
    assert_eq!(
        cached_dashboard_snapshot_for_startup(&home_a)
            .expect("home A should restore its own V20 startup numerics")
            .stats
            .total_tokens,
        120
    );
    assert!(
        cached_dashboard_snapshot_for_startup(&home_b).is_none(),
        "home B must not hydrate home A's one-file V20 cache"
    );

    let snapshot_b = dashboard_snapshot(&home_b).unwrap();

    assert_eq!(snapshot_b.stats.total_tokens, 30);
    assert_eq!(
        usage_summary_snapshot(&home_b)
            .unwrap()
            .unwrap()
            .total_tokens,
        30,
        "home B should use its own rebuilt precise aggregate"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cached_usage_summary_scope_rejects_date_and_offset_changes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let now = OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap();
    let offset = UtcOffset::from_hms(8, 0, 0).unwrap();
    let signature = dashboard_scan_signature_at(&root, 0, now, offset);
    store_dashboard_aggregate(
        signature,
        None,
        TokenUsageSummary {
            total_tokens: 120,
            today_tokens: 120,
            today_requests: 1,
            today_model_breakdowns: Vec::new(),
        },
    );
    assert_eq!(
        cached_dashboard_usage_summary_at(&root, now, offset)
            .expect("cache read should succeed")
            .expect("matching lightweight scope should reuse the trusted summary")
            .total_tokens,
        120
    );
    assert!(
        cached_dashboard_usage_summary_at(&root, now + time::Duration::days(1), offset,)
            .unwrap()
            .is_none()
    );
    assert!(
        cached_dashboard_usage_summary_at(&root, now, UtcOffset::from_hms(9, 0, 0).unwrap(),)
            .unwrap()
            .is_none()
    );
    assert!(
        cached_dashboard_usage_summary_at(&root.join("other-home"), now, offset)
            .unwrap()
            .is_none()
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn active_rollout_fork_replay_aggregate_reuse_invalidates_after_append() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let active_dir = root.join("active-rollouts");
    fs::create_dir_all(&active_dir).unwrap();
    let rollout_path = active_dir.join("rollout-019efork-active-0000-0000-cache.jsonl");
    write_lines(
        &rollout_path,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":100,"total_tokens":500},"last_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":100,"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:10:00Z","type":"event_msg","payload":{"type":"user_message","message":"新分支问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:11:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":120,"total_tokens":620},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    create_state_database_with_rollout(&root, "019efork-active-0000-0000-cache", &rollout_path);

    let first = dashboard_snapshot(&root).unwrap();
    assert_eq!(first.stats.total_tokens, 120);
    assert_eq!(
        usage_summary_snapshot(&root).unwrap().unwrap().total_tokens,
        120
    );

    reset_dashboard_aggregate_build_count_for_testing();
    assert_eq!(
        usage_summary_snapshot(&root).unwrap().unwrap().total_tokens,
        120
    );
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        0,
        "unchanged active rollout should reuse the trusted aggregate summary"
    );

    let (started_rx, gate, calls) = install_blocking_precise_refresh_hook(&[root.clone()]);
    {
        let mut handle = fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:12:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":620,"cached_input_tokens":10,"output_tokens":140,"total_tokens":760}},"last_token_usage":{{"input_tokens":120,"cached_input_tokens":10,"output_tokens":20,"total_tokens":140}}}}}}}}"#
        )
        .unwrap();
    }

    assert_eq!(
        cached_dashboard_usage_summary(&root)
            .expect("same-scope append should retain the last trusted summary")
            .total_tokens,
        120
    );
    assert_eq!(
        usage_summary_snapshot(&root).unwrap().unwrap().total_tokens,
        120,
        "signature drift should retain the stale-safe trusted totals"
    );
    schedule_usage_summary_refresh(&root).unwrap();
    schedule_usage_summary_refresh(&root).unwrap();
    schedule_usage_summary_refresh(&root).unwrap();
    assert!(started_rx.recv_timeout(StdDuration::from_secs(5)).is_ok());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    gate.release(1);
    set_precise_refresh_sync_hook_for_testing(None);

    for _ in 0..100 {
        std::thread::sleep(std::time::Duration::from_millis(20));
        if usage_summary_snapshot(&root)
            .is_ok_and(|summary| summary.is_some_and(|summary| summary.total_tokens == 260))
        {
            assert_eq!(
                dashboard_aggregate_build_count_for_testing(&root),
                0,
                "compact summary refresh must not rebuild the full dashboard aggregate"
            );
            wait_for_usage_summary_refreshes_for_testing();
            fs::remove_dir_all(root).unwrap();
            return;
        }
    }

    panic!("stale-safe usage summary background refresh did not finish");
}

#[test]
fn dashboard_aggregate_cache_save_does_not_clobber_existing_temp_file() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("token-aggregate-cache.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    fs::create_dir_all(&root).unwrap();
    let legacy_temp_path = cache_path.with_extension("json.tmp");
    fs::write(&legacy_temp_path, "other save").unwrap();
    let signature = dashboard_scan_signature_at(
        &root,
        0,
        OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap(),
        UtcOffset::UTC,
    );

    store_dashboard_aggregate(
        signature.clone(),
        None,
        TokenUsageSummary {
            total_tokens: 10,
            today_tokens: 10,
            today_requests: 1,
            today_model_breakdowns: Vec::new(),
        },
    );
    age_file(&cache_path, StdDuration::from_secs(16 * 60));
    let second_warning = store_dashboard_aggregate(
        signature,
        None,
        TokenUsageSummary {
            total_tokens: 20,
            today_tokens: 20,
            today_requests: 2,
            today_model_breakdowns: Vec::new(),
        },
    );
    assert!(second_warning.is_none(), "{second_warning:?}");

    assert_eq!(
        fs::read_to_string(&legacy_temp_path).unwrap(),
        "other save",
        "aggregate cache should use a unique temp path instead of overwriting another save"
    );
    assert!(cache_path.exists());
    assert_eq!(
        load_persistent_dashboard_aggregate()
            .unwrap()
            .unwrap()
            .summary
            .total_tokens,
        20
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_checkpoints_same_revision_at_most_every_fifteen_minutes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    fs::create_dir_all(&root).unwrap();
    let now = OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap();
    let mut first_signature = dashboard_scan_signature_at(&root, 0, now, UtcOffset::UTC);
    first_signature.index_revision = 100;
    store_dashboard_aggregate(
        first_signature.clone(),
        None,
        TokenUsageSummary {
            total_tokens: 100,
            today_tokens: 100,
            today_requests: 1,
            today_model_breakdowns: Vec::new(),
        },
    );
    let initial = fs::read(&cache_path).unwrap();
    let mut next_day_signature = first_signature.clone();
    next_day_signature.local_date = "2026-06-19".into();
    assert!(aggregate_checkpoint_due(
        &cache_path,
        &next_day_signature,
        SystemTime::now()
    ));

    let mut active_signature = first_signature;
    active_signature.index_revision = 110;
    age_file(&cache_path, StdDuration::from_secs(30));
    store_dashboard_aggregate(
        active_signature.clone(),
        None,
        TokenUsageSummary {
            total_tokens: 110,
            today_tokens: 110,
            today_requests: 2,
            today_model_breakdowns: Vec::new(),
        },
    );
    assert_ne!(fs::read(&cache_path).unwrap(), initial);
    assert_eq!(
        cached_dashboard_aggregate(&active_signature)
            .unwrap()
            .summary
            .total_tokens,
        110,
        "memory must update immediately while the startup checkpoint is throttled"
    );

    age_file(&cache_path, StdDuration::from_secs(16 * 60));
    store_dashboard_aggregate(
        active_signature,
        None,
        TokenUsageSummary {
            total_tokens: 120,
            today_tokens: 120,
            today_requests: 3,
            today_model_breakdowns: Vec::new(),
        },
    );
    assert_ne!(fs::read(&cache_path).unwrap(), initial);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_cache_skips_an_identical_payload() {
    let root = temp_root();
    let path = root.join("dashboard-aggregate.json");
    fs::create_dir_all(&root).unwrap();
    fs::write(&path, b"same aggregate").unwrap();
    let mut writes = 0;

    super::write_aggregate_if_changed(&path, b"same aggregate", |_, _| {
        writes += 1;
        Ok(())
    })
    .unwrap();
    assert_eq!(writes, 0);

    super::write_aggregate_if_changed(&path, b"changed aggregate", |_, _| {
        writes += 1;
        Ok(())
    })
    .unwrap();
    assert_eq!(writes, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn aggregate_persistence_failure_keeps_memory_snapshot_with_one_warning() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let blocked_parent = root.join("blocked-parent");
    fs::create_dir_all(&root).unwrap();
    fs::write(&blocked_parent, b"not a directory").unwrap();
    let _cache_env = AggregateCacheEnvGuard::new(blocked_parent.join("dashboard-aggregate.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &session_dir.join("rollout-019eaggregate-persistence-warning.jsonl"),
        &[&format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}}}}}"#
        )],
    );

    let first = dashboard_snapshot(&root).unwrap();
    let second = dashboard_snapshot(&root).unwrap();
    for snapshot in [first, second] {
        assert_eq!(snapshot.stats.total_tokens, 120);
        assert_eq!(
            snapshot
                .warnings
                .iter()
                .filter(|warning| warning.source == "usage-cache-persistence")
                .count(),
            1
        );
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn v20_atomic_replace_failure_keeps_last_good_cache_bytes() {
    let root = temp_root();
    let path = root.join("dashboard-aggregate.json");
    fs::create_dir_all(&root).unwrap();
    fs::write(&path, b"last-good-v19").unwrap();
    let result =
        crate::core::atomic_file::write_atomically_with_hook(&path, b"new-v19", |stage, _| {
            if stage == crate::core::atomic_file::AtomicWriteStage::Replace {
                Err("injected replace failure".into())
            } else {
                Ok(())
            }
        });
    assert!(result.is_err());
    assert_eq!(fs::read(&path).unwrap(), b"last-good-v19");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn marker_failure_warning_is_deduplicated_for_fresh_and_cached_snapshots() {
    let root = temp_root();
    let blocked_support = root.join("blocked-support");
    fs::create_dir_all(&root).unwrap();
    fs::write(&blocked_support, b"not a directory").unwrap();
    let _state = cache_lifecycle::usage_cache_test_state_guard(&[(
        "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
        blocked_support.clone(),
    )]);
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &session_dir.join("rollout-019emarker-warning-fresh-cached.jsonl"),
        &[&format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":42}}}}}}}}"#
        )],
    );

    let fresh = dashboard_snapshot(&root).unwrap();
    let cached = dashboard_snapshot(&root).unwrap();
    for snapshot in [fresh, cached] {
        assert_eq!(
            snapshot
                .warnings
                .iter()
                .filter(|warning| warning.source == "usage-cache-marker-persistence")
                .count(),
            1
        );
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_source_change_check_detects_append_and_delete() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session = session_dir.join("rollout-019esource-change-0000-0000-fast.jsonl");
    write_lines(
        &session,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    dashboard_snapshot(&root).unwrap();
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let mut warnings = Vec::new();
    assert!(!index.sources_changed(&root, &mut warnings).unwrap());

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&session).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }
    assert!(index.sources_changed(&root, &mut warnings).unwrap());
    drop(index);

    dashboard_snapshot(&root).unwrap();
    let mut index = ExactUsageIndex::open(&root).unwrap();
    fs::remove_file(&session).unwrap();
    assert!(index.sources_changed(&root, &mut warnings).unwrap());
    drop(index);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn precise_dashboard_source_probe_reports_metadata_only_changes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session = session_dir.join("rollout-019esource-probe-0000-0000-fast.jsonl");
    write_lines(
        &session,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    dashboard_snapshot(&root).unwrap();
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let unchanged = precise_dashboard_source_probe(&root).unwrap();
    assert_eq!(unchanged.state, "unchanged");
    assert!(!unchanged.published_generation.is_empty());
    let index = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(
        unchanged.published_generation,
        index.published_generation().unwrap().to_string()
    );
    assert_ne!(
        unchanged.published_generation,
        index.revision().unwrap().to_string(),
        "the probe lineage must use published_generation, not revision"
    );
    drop(index);
    assert_eq!(ExactUsageIndex::scan_bytes_for_testing(), (0, 0));

    let mut handle = fs::OpenOptions::new().append(true).open(&session).unwrap();
    writeln!(
        handle,
        r#"{{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
    )
    .unwrap();
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let changed = precise_dashboard_source_probe(&root).unwrap();
    assert_eq!(changed.state, "changed");
    assert_eq!(changed.published_generation, unchanged.published_generation);
    assert_eq!(ExactUsageIndex::scan_bytes_for_testing(), (0, 0));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn compatible_exact_index_reopen_skips_migration_ddl_and_write_transactions() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ecompatible-reopen-0000-0000-fast.jsonl"),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#],
    );
    dashboard_snapshot(&root).unwrap();

    ExactUsageIndex::reset_open_work_counters_for_testing();
    ExactUsageIndex::reset_receipt_write_count_for_testing();
    let probe = precise_dashboard_source_probe(&root).unwrap();
    assert_eq!(probe.state, "unchanged");
    drop(ExactUsageIndex::open(&root).unwrap());
    assert_eq!(
        ExactUsageIndex::open_work_counters_for_testing(),
        (0, 0, 0),
        "a compatible reopen must skip migration, DDL, and write transactions"
    );
    assert_eq!(
        ExactUsageIndex::receipt_write_count_for_testing(),
        0,
        "a compatible reopen must not rewrite its integrity receipt"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_integrity_check_is_reused_and_trusted_sync_refreshes_its_signature() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session = session_dir.join("rollout-019eintegrity-cache-0000-0000-fast.jsonl");
    write_lines(
        &session,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();

    // Force the first post-restart open down the strict path. The successful
    // close below must recreate the receipt, after which a state reset can
    // reuse it without another quick_check.
    let receipt = integrity_receipt_path_for_testing(&root).unwrap();
    fs::remove_file(receipt).unwrap();
    ExactUsageIndex::clear_integrity_signature_for_testing(&root);
    ExactUsageIndex::reset_quick_check_count_for_testing();
    std::thread::scope(|scope| {
        let first = scope.spawn(|| drop(ExactUsageIndex::open(&root).unwrap()));
        let second = scope.spawn(|| drop(ExactUsageIndex::open(&root).unwrap()));
        first.join().unwrap();
        second.join().unwrap();
    });
    drop(ExactUsageIndex::open(&root).unwrap());
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 1);

    ExactUsageIndex::clear_integrity_signature_for_testing(&root);
    ExactUsageIndex::reset_quick_check_count_for_testing();
    drop(ExactUsageIndex::open(&root).unwrap());
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);

    let mut active_index = ExactUsageIndex::open(&root).unwrap();
    {
        let mut handle = fs::OpenOptions::new().append(true).open(&session).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }
    let mut warnings = Vec::new();
    active_index.sync(&root, &mut warnings).unwrap();
    drop(ExactUsageIndex::open(&root).unwrap());
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);
    drop(active_index);
    drop(ExactUsageIndex::open(&root).unwrap());
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_integrity_receipt_corruption_or_mismatch_rechecks_without_deleting_db() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    for (label, corrupt) in [("corrupt", true), ("mismatch", false)] {
        let root = temp_root();
        let session_dir = root.join("sessions");
        fs::create_dir_all(&session_dir).unwrap();
        write_lines(
            &session_dir.join(format!("rollout-019ereceipt-{label}-0000-0000-fast.jsonl")),
            &[
                r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
            ],
        );
        dashboard_snapshot(&root).unwrap();
        let receipt = integrity_receipt_path_for_testing(&root).unwrap();
        let original = fs::read(&receipt).unwrap();
        if corrupt {
            fs::write(&receipt, b"{not-json").unwrap();
        } else {
            let mut json: serde_json::Value = serde_json::from_slice(&original).unwrap();
            json["publishedGeneration"] = serde_json::json!(u64::MAX);
            fs::write(&receipt, serde_json::to_vec(&json).unwrap()).unwrap();
        }
        ExactUsageIndex::clear_integrity_signature_for_testing(&root);
        ExactUsageIndex::reset_quick_check_count_for_testing();
        drop(ExactUsageIndex::open(&root).unwrap());
        assert_eq!(
            ExactUsageIndex::quick_check_count_for_testing(),
            1,
            "{label}"
        );
        assert!(root
            .join(".codex-token-bar-test-cache/exact-token-index.sqlite3")
            .is_file());
        let repaired_receipt: serde_json::Value =
            serde_json::from_slice(&fs::read(&receipt).unwrap()).unwrap();
        assert!(repaired_receipt.get("sessions").is_none());
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn exact_index_integrity_checks_for_different_paths_do_not_share_gate() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root_a = temp_root();
    let root_b = temp_root();
    for (root, id) in [(&root_a, "a"), (&root_b, "b")] {
        let session_dir = root.join("sessions");
        fs::create_dir_all(&session_dir).unwrap();
        write_lines(
            &session_dir.join(format!("rollout-019egate-{id}-0000-0000-fast.jsonl")),
            &[
                r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
            ],
        );
        dashboard_snapshot(root).unwrap();
        fs::remove_file(integrity_receipt_path_for_testing(root).unwrap()).unwrap();
        ExactUsageIndex::clear_integrity_signature_for_testing(root);
    }

    let path_a = super::exact_usage_index::database_path(&root_a).unwrap();
    let path_b = super::exact_usage_index::database_path(&root_b).unwrap();
    ExactUsageIndex::reset_quick_check_count_for_testing();
    let barrier = Arc::new(std::sync::Barrier::new(2));
    ExactUsageIndex::set_quick_check_barrier_for_testing(Some((
        Arc::clone(&barrier),
        [path_a, path_b].into_iter().collect(),
    )));
    std::thread::scope(|scope| {
        let first = scope.spawn(|| drop(ExactUsageIndex::open(&root_a).unwrap()));
        let second = scope.spawn(|| drop(ExactUsageIndex::open(&root_b).unwrap()));
        first.join().unwrap();
        second.join().unwrap();
    });
    ExactUsageIndex::set_quick_check_barrier_for_testing(None);
    assert_eq!(ExactUsageIndex::quick_check_count_for_testing(), 2);

    fs::remove_dir_all(root_a).unwrap();
    fs::remove_dir_all(root_b).unwrap();
}

#[test]
fn exact_index_close_publishes_state_before_a_waiting_open_can_enter() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019estate-gate-0000-0000-fast.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();

    let path = super::exact_usage_index::database_path(&root).unwrap();
    let mut index = ExactUsageIndex::open(&root).unwrap();
    // Model a connection whose work was not safe to publish. Its close must
    // still decrement the active count while retaining the path gate.
    index.mark_receipt_dirty_for_testing();

    let (gate_enter_tx, gate_enter_rx) = mpsc::channel::<usize>();
    let enter_target = path.clone();
    ExactUsageIndex::set_integrity_gate_enter_hook_for_testing(Some(Box::new(move |candidate| {
        if candidate == enter_target {
            gate_enter_tx
                .send(ExactUsageIndex::active_integrity_connections_for_testing(
                    candidate,
                ))
                .unwrap();
        }
    })));

    let (gate_release_tx, gate_release_rx) = mpsc::channel::<usize>();
    let release_target = path.clone();
    ExactUsageIndex::set_integrity_gate_release_hook_for_testing(Some(Box::new(
        move |candidate| {
            if candidate == release_target {
                gate_release_tx
                    .send(ExactUsageIndex::active_integrity_connections_for_testing(
                        candidate,
                    ))
                    .unwrap();
            }
        },
    )));

    let (finish_started_tx, finish_started_rx) = mpsc::channel::<()>();
    let (finish_release_tx, finish_release_rx) = mpsc::channel::<()>();
    let finish_first = Arc::new(Mutex::new(true));
    let finish_first_for_hook = Arc::clone(&finish_first);
    let finish_release = Arc::new(Mutex::new(Some(finish_release_rx)));
    let finish_release_for_hook = Arc::clone(&finish_release);
    let finish_target = path.clone();
    ExactUsageIndex::set_before_finish_index_connection_hook_for_testing(Some(Box::new(
        move |candidate| {
            if candidate != finish_target {
                return;
            }
            let first = {
                let mut first = finish_first_for_hook.lock().unwrap();
                let first_call = *first;
                *first = false;
                first_call
            };
            if !first {
                return;
            }
            finish_started_tx.send(()).unwrap();
            let receiver = finish_release_for_hook.lock().unwrap().take().unwrap();
            receiver.recv().unwrap();
        },
    )));

    let drop_thread = std::thread::spawn(move || drop(index));
    assert_eq!(gate_enter_rx.recv().unwrap(), 1);
    finish_started_rx.recv().unwrap();

    let (attempt_tx, attempt_rx) = mpsc::channel::<()>();
    let (start_open_tx, start_open_rx) = mpsc::channel::<()>();
    let open_root = root.clone();
    let open_thread = std::thread::spawn(move || {
        attempt_tx.send(()).unwrap();
        start_open_rx.recv().unwrap();
        drop(ExactUsageIndex::open(&open_root).unwrap());
    });
    attempt_rx.recv().unwrap();
    start_open_tx.send(()).unwrap();
    finish_release_tx.send(()).unwrap();

    let state_at_gate_release = gate_release_rx.recv().unwrap();
    let state_seen_by_waiting_open = gate_enter_rx.recv().unwrap();
    drop_thread.join().unwrap();
    open_thread.join().unwrap();
    ExactUsageIndex::set_before_finish_index_connection_hook_for_testing(None);
    ExactUsageIndex::set_integrity_gate_release_hook_for_testing(None);
    ExactUsageIndex::set_integrity_gate_enter_hook_for_testing(None);

    assert_eq!(state_at_gate_release, 0);
    assert_eq!(state_seen_by_waiting_open, 0);
    assert_eq!(
        ExactUsageIndex::active_integrity_connections_for_testing(&path),
        0
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_readonly_reopen_does_not_rewrite_identical_integrity_receipt() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019ereceipt-idempotent-0000-0000-fast.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    dashboard_snapshot(&root).unwrap();

    // Normalize one ordinary open/close cycle before capturing the receipt.
    drop(ExactUsageIndex::open(&root).unwrap());

    let receipt = integrity_receipt_path_for_testing(&root).unwrap();
    let before_bytes = fs::read(&receipt).unwrap();
    let before_metadata = fs::metadata(&receipt).unwrap();
    #[cfg(unix)]
    let before_identity = (before_metadata.dev(), before_metadata.ino());

    ExactUsageIndex::clear_integrity_signature_for_testing(&root);
    ExactUsageIndex::reset_receipt_write_count_for_testing();
    drop(ExactUsageIndex::open(&root).unwrap());

    assert_eq!(ExactUsageIndex::receipt_write_count_for_testing(), 0);
    let after_bytes = fs::read(&receipt).unwrap();
    let after_metadata = fs::metadata(&receipt).unwrap();
    assert_eq!(after_bytes, before_bytes);
    assert_eq!(
        after_metadata.modified().unwrap(),
        before_metadata.modified().unwrap()
    );
    #[cfg(unix)]
    assert_eq!(
        (after_metadata.dev(), after_metadata.ino()),
        before_identity
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_snapshot_cache_miss_schedules_one_lightweight_background_refresh() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-0000-0000-0000-background.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    reset_dashboard_aggregate_build_count_for_testing();
    assert!(matches!(usage_summary_snapshot(&root), Ok(None)));
    schedule_usage_summary_refresh(&root).unwrap();
    schedule_usage_summary_refresh(&root).unwrap();
    schedule_usage_summary_refresh(&root).unwrap();

    for _ in 0..100 {
        std::thread::sleep(std::time::Duration::from_millis(20));
        if let Ok(Some(summary)) = usage_summary_snapshot(&root) {
            assert_eq!(summary.total_tokens, 120);
            assert_eq!(
                dashboard_aggregate_build_count_for_testing(&root),
                0,
                "compact summary refresh must not build rankings, charts, or excerpts"
            );
            wait_for_usage_summary_refreshes_for_testing();
            let completed_scans = dashboard_scan_signature_count_for_testing();
            schedule_usage_summary_refresh(&root).unwrap();
            schedule_usage_summary_refresh(&root).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(50));
            assert_eq!(
                dashboard_scan_signature_count_for_testing(),
                completed_scans,
                "compact surfaces inside one refresh window must reuse the same background sync"
            );
            fs::remove_dir_all(root).unwrap();
            return;
        }
    }

    panic!("usage summary background build did not finish");
}

#[test]
fn refreshed_usage_summary_snapshot_waits_for_the_lightweight_publication() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let rollout = session_dir.join("rollout-019esummary-immediate-0000-0000.jsonl");
    write_lines(
        &rollout,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    reset_dashboard_aggregate_build_count_for_testing();
    let summary = refreshed_usage_summary_snapshot_with_interval(&root, Some(60))
        .unwrap()
        .expect("the completed lightweight owner must be returned immediately");
    assert_eq!(summary.total_tokens, 120);
    assert!(!summary.checked_at.is_empty());
    assert!(summary.data_updated_at.is_some());
    assert_eq!(dashboard_aggregate_build_count_for_testing(&root), 0);
    wait_for_usage_summary_refreshes_for_testing();
    assert_eq!(
        precise_dashboard_progress(&root).phase,
        "idle",
        "a summary-only owner must not publish the full precise complete phase"
    );

    let forced_calls = Arc::new(AtomicU64::new(0));
    let forced_calls_for_hook = Arc::clone(&forced_calls);
    set_precise_refresh_sync_hook_for_testing(Some(Arc::new(move |_| {
        forced_calls_for_hook.fetch_add(1, Ordering::SeqCst);
        Ok(())
    })));
    let forced = refreshed_usage_summary_snapshot_with_interval(&root, Some(0))
        .unwrap()
        .expect("wake refresh must bypass the ordinary cadence reuse window");
    set_precise_refresh_sync_hook_for_testing(None);
    assert_eq!(forced.total_tokens, 120);
    assert_eq!(forced_calls.load(Ordering::SeqCst), 1);
    assert_eq!(dashboard_aggregate_build_count_for_testing(&root), 0);
    wait_for_usage_summary_refreshes_for_testing();
    assert_eq!(precise_dashboard_progress(&root).phase, "idle");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn promoted_full_owner_releases_summary_waiters_before_full_completion() {
    let flight =
        PreciseRefreshFlight::new(PreciseRefreshIntent::Summary, false, None, None, 0, None);
    assert!(flight.request_full());
    let waiter = Arc::clone(&flight);
    let (tx, rx) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        tx.send(waiter.wait_summary()).unwrap();
    });

    let summary = TokenUsageSummary {
        total_tokens: 120,
        today_tokens: 120,
        today_requests: 1,
        today_model_breakdowns: Vec::new(),
    };
    flight.publish_summary(&Ok(summary));
    let published = rx
        .recv_timeout(StdDuration::from_secs(1))
        .expect("summary waiter must not wait for the promoted full dashboard")
        .unwrap();
    assert_eq!(published.total_tokens, 120);
    assert!(!flight.is_done());
    thread.join().unwrap();
}

#[test]
fn summary_only_success_is_not_a_full_precise_completion() {
    let summary = TokenUsageSummary {
        total_tokens: 120,
        today_tokens: 120,
        today_requests: 1,
        today_model_breakdowns: Vec::new(),
    };
    let summary_only = PreciseRefreshResult {
        summary: Ok(summary.clone()),
        full: None,
        migration_pending: false,
    };
    assert_eq!(
        summary_only.terminal_progress(),
        PreciseRefreshTerminalProgress::SummaryOnlySuccess
    );

    let full = PreciseRefreshResult {
        summary: Ok(summary),
        full: Some(Ok(persistent_numeric_test_snapshot(
            &TokenUsageSummary::default(),
        ))),
        migration_pending: false,
    };
    assert_eq!(
        full.terminal_progress(),
        PreciseRefreshTerminalProgress::FullSuccess
    );
}

fn temp_root() -> PathBuf {
    let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "codex-token-bar-tauri-jsonl-{}-{}-{}",
        std::process::id(),
        sequence,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn write_lines<S: AsRef<str>>(path: &Path, lines: &[S]) {
    let mut file = fs::File::create(path).unwrap();
    for line in lines {
        writeln!(file, "{}", line.as_ref()).unwrap();
    }
}

fn recent_test_timestamp(minutes_ago: i64) -> String {
    (OffsetDateTime::now_utc() - time::Duration::minutes(minutes_ago))
        .format(&Rfc3339)
        .unwrap()
}

fn age_file(path: &Path, age: StdDuration) {
    let file = fs::OpenOptions::new().write(true).open(path).unwrap();
    let times = fs::FileTimes::new().set_modified(SystemTime::now() - age);
    file.set_times(times).unwrap();
}

struct AggregateCacheEnvGuard {
    original: Option<std::ffi::OsString>,
}

impl AggregateCacheEnvGuard {
    fn new(path: PathBuf) -> Self {
        reset_dashboard_aggregate_build_count_for_testing();
        let _ = fs::remove_file(&path);
        let original = std::env::var_os("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH");
        std::env::set_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH", path);
        Self { original }
    }
}

impl Drop for AggregateCacheEnvGuard {
    fn drop(&mut self) {
        match &self.original {
            Some(value) => std::env::set_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH", value),
            None => std::env::remove_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH"),
        }
        reset_dashboard_aggregate_build_count_for_testing();
    }
}

fn aggregate_cache_text() -> String {
    app_paths::token_aggregate_cache_path()
        .and_then(|path| fs::read_to_string(path).ok())
        .unwrap_or_default()
}

fn create_state_database(root: &Path, low_id: &str, high_id: &str) {
    let db_path = root.join("state_5.sqlite");
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                first_user_message TEXT,
                preview TEXT,
                updated_at INTEGER NOT NULL,
                updated_at_ms INTEGER
            );
            "#,
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO threads (id, title, first_user_message, preview, updated_at, updated_at_ms) VALUES (?1, '低命中会话', '', '', 1781715600, 1781715600000);",
            [low_id],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO threads (id, title, first_user_message, preview, updated_at, updated_at_ms) VALUES (?1, '高命中会话', '', '', 1781719200, 1781719200000);",
            [high_id],
        )
        .unwrap();
}

fn create_state_database_with_rollout(root: &Path, thread_id: &str, rollout_path: &Path) {
    create_state_database_with_rollout_source(root, thread_id, rollout_path, "user");
}

fn create_state_database_with_rollout_source(
    root: &Path,
    thread_id: &str,
    rollout_path: &Path,
    thread_source: &str,
) {
    let db_path = root.join("state_5.sqlite");
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                first_user_message TEXT,
                preview TEXT,
                rollout_path TEXT,
                updated_at INTEGER NOT NULL,
                updated_at_ms INTEGER,
                archived INTEGER DEFAULT 0,
                thread_source TEXT DEFAULT 'user'
            );
            "#,
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO threads (id, title, first_user_message, preview, rollout_path, updated_at, updated_at_ms, archived, thread_source) VALUES (?1, '活跃会话', '', '', ?2, 1781715600, 1781715600000, 0, ?3);",
            rusqlite::params![thread_id, rollout_path.to_string_lossy(), thread_source],
        )
        .unwrap();
}
