use crate::core::windows_path::extended_length_path_from_wide;
use super::recent_completion::{
    current_time_seconds, lookback_seconds, recent_completion_markers,
};
use super::{
    acknowledge_current_unread, read_unread_summary, read_unread_summary_at,
    try_read_unread_summary, try_read_unread_summary_at_with_parent_sync,
    try_read_unread_summary_at_with_prepare,
    try_read_unread_summary_for_source, write_acknowledgement_at_with_sync,
    AcknowledgementWriteOutcome, UnreadAcknowledgement,
};
use serde::Deserialize;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Barrier};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[test]
fn windows_extended_paths_cover_drive_unc_and_existing_prefixes() {
    let drive = extended_length_path_from_wide(r"C:\Codex Home\ack.json".encode_utf16().collect())
        .unwrap();
    assert_eq!(
        String::from_utf16(&drive[..drive.len() - 1]).unwrap(),
        r"\\?\C:\Codex Home\ack.json"
    );

    let unc = extended_length_path_from_wide(r"\\server\share\ack.json".encode_utf16().collect())
        .unwrap();
    assert_eq!(
        String::from_utf16(&unc[..unc.len() - 1]).unwrap(),
        r"\\?\UNC\server\share\ack.json"
    );

    let prefixed = extended_length_path_from_wide(r"\\?\C:\ack.json".encode_utf16().collect())
        .unwrap();
    assert_eq!(
        String::from_utf16(&prefixed[..prefixed.len() - 1]).unwrap(),
        r"\\?\C:\ack.json"
    );
    assert!(
        extended_length_path_from_wide(r"relative\ack.json".encode_utf16().collect()).is_err()
    );
    assert!(extended_length_path_from_wide(r"\\?\relative".encode_utf16().collect()).is_err());
}

#[test]
fn shared_unread_correctness_sequence() {
    let sequence: UnreadCorrectnessSequence = serde_json::from_str(include_str!(
        "../../../../../TestFixtures/unread-correctness-sequence.json"
    ))
    .unwrap();
    let root = temp_root();
    let support = root.join("tauri-support");
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let session = sessions.join("sequence.jsonl");
    let thread_id = "019eaaaa-0000-0000-0000-0000000000aa";
    write_session_meta(&session, thread_id);
    let base_completed_at = current_time_seconds();

    for step in sequence.steps {
        write_unread_state(&root, &step.native_thread_ids);
        for completion in &step.append_completions {
            assert_eq!(completion.thread_id, thread_id, "{}", step.name);
            assert!(!completion.title.is_empty(), "{}", step.name);
            append_task_complete(
                &session,
                base_completed_at + completion.completed_at_offset_seconds,
                &completion.turn_id,
            );
            let parsed_ids = recent_completion_markers(&root);
            assert!(
                parsed_ids.contains(&completion.expected_canonical_id),
                "{}",
                step.name
            );
        }

        let summary = if step.action == "markAllRead" {
            acknowledge_current_unread(&root).unwrap()
        } else {
            read_unread_summary(&root)
        };
        assert_eq!(summary.count, step.expected_count, "{}", step.name);
    }

    let _ = fs::remove_dir_all(root);
}

#[test]
fn completion_rearm_persists_after_lookback_until_next_acknowledgement() {
    let root = temp_root();
    let support = root.join("tauri-support");
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let session = sessions.join("persistent-rearm.jsonl");
    let thread_id = "019eaaaa-0000-0000-0000-0000000000dd";
    let now = current_time_seconds();
    write_session_meta(&session, thread_id);
    write_unread_state(&root, &[thread_id.to_string()]);

    assert_eq!(read_unread_summary_at(&root, now).unwrap().count, 1);
    assert_eq!(acknowledge_current_unread(&root).unwrap().count, 0);

    append_task_complete(&session, now + 1.0, "turn-rearm");
    assert_eq!(
        read_unread_summary_at(&root, now + 1.0).unwrap().count,
        1
    );
    let persisted = fs::read_to_string(support.join("unread-acknowledgement.json")).unwrap();
    assert!(!persisted.contains(thread_id));

    let after_lookback = now + lookback_seconds() + 5.0;
    assert_eq!(
        read_unread_summary_at(&root, after_lookback)
            .unwrap()
            .count,
        1
    );

    assert_eq!(acknowledge_current_unread(&root).unwrap().count, 0);
    assert_eq!(
        read_unread_summary_at(&root, after_lookback)
            .unwrap()
            .count,
        0
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn rearm_write_failure_returns_error_and_preserves_previous_file() {
    let root = temp_root();
    let support = root.join("tauri-support");
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let session = sessions.join("write-failure.jsonl");
    let thread_id = "019eaaaa-0000-0000-0000-0000000000ee";
    let now = current_time_seconds();
    write_session_meta(&session, thread_id);
    write_unread_state(&root, &[thread_id.to_string()]);
    assert_eq!(acknowledge_current_unread(&root).unwrap().count, 0);
    let acknowledgement_path = support.join("unread-acknowledgement.json");
    let before = fs::read(&acknowledgement_path).unwrap();

    append_task_complete(&session, now + 1.0, "turn-write-failure");
    let error = try_read_unread_summary_at_with_prepare(
        &root,
        now + 1.0,
        &|_, _| Err("injected unread write failure".into()),
    )
    .unwrap_err();

    assert!(error.contains("injected unread write failure"));
    assert_eq!(fs::read(&acknowledgement_path).unwrap(), before);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn corrupt_acknowledgement_is_reported_and_never_overwritten() {
    let root = temp_root();
    let support = root.join("tauri-support");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&support).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let path = support.join("unread-acknowledgement.json");
    write_unread_state(
        &root,
        &["019eaaaa-0000-0000-0000-0000000000ff".to_string()],
    );
    assert_eq!(read_unread_summary(&root).count, 1);
    let corrupt = b"{not-json";
    fs::write(&path, corrupt).unwrap();

    assert!(try_read_unread_summary(&root).unwrap_err().contains("JSON"));
    assert!(acknowledge_current_unread(&root).unwrap_err().contains("JSON"));
    let retained = read_unread_summary(&root);
    assert_eq!(retained.count, 1);
    assert!(retained.source.ends_with("_stale"));
    assert!(retained.detail.contains("保留上次可信结果"));
    assert_eq!(fs::read(&path).unwrap(), corrupt);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn concurrent_home_acknowledgements_preserve_both_records() {
    let support = temp_root();
    let home_a = temp_root();
    let home_b = temp_root();
    fs::create_dir_all(&home_a).unwrap();
    fs::create_dir_all(&home_b).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    write_unread_state(
        &home_a,
        &["019eaaaa-0000-0000-0000-000000000101".to_string()],
    );
    write_unread_state(
        &home_b,
        &["019eaaaa-0000-0000-0000-000000000102".to_string()],
    );
    let barrier = Arc::new(Barrier::new(3));

    let handles = [home_a.clone(), home_b.clone()].map(|home| {
        let barrier = barrier.clone();
        std::thread::spawn(move || {
            barrier.wait();
            acknowledge_current_unread(&home).unwrap();
        })
    });
    barrier.wait();
    for handle in handles {
        handle.join().unwrap();
    }

    let data = fs::read(support.join("unread-acknowledgement.json")).unwrap();
    let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
    let records = value["byCodexHome"].as_object().unwrap();
    assert_eq!(records.len(), 2);

    let _ = fs::remove_dir_all(support);
    let _ = fs::remove_dir_all(home_a);
    let _ = fs::remove_dir_all(home_b);
}

#[test]
fn slow_prepare_does_not_hold_global_lock_and_cas_replays_without_lost_updates() {
    let support = temp_root();
    fs::create_dir_all(&support).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let (prepare_entered_tx, prepare_entered_rx) = mpsc::channel();
    let prepare_release = Arc::new(Barrier::new(2));
    let first_prepare = Arc::new(AtomicBool::new(true));

    let handle_a = {
        let prepare_release = prepare_release.clone();
        let first_prepare = first_prepare.clone();
        std::thread::spawn(move || {
            let prepare = |path: &Path, acknowledgement: &UnreadAcknowledgement| {
                if first_prepare.swap(false, Ordering::SeqCst) {
                    prepare_entered_tx.send(()).unwrap();
                    prepare_release.wait();
                }
                super::prepare_acknowledgement_at(path, acknowledgement)
            };
            write_test_acknowledgement(
                "prepare-home-a",
                "thread-a",
                &prepare,
                |_| Ok(()),
            )
        })
    };
    prepare_entered_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("first transaction never reached slow prepare");

    let (home_b_done_tx, home_b_done_rx) = mpsc::channel();
    let handle_b = std::thread::spawn(move || {
        let result = write_test_acknowledgement(
            "prepare-home-b",
            "thread-b",
            &super::prepare_acknowledgement_at,
            |_| Ok(()),
        );
        home_b_done_tx.send(result).unwrap();
    });
    let home_b_result = home_b_done_rx.recv_timeout(Duration::from_secs(5));
    prepare_release.wait();
    let home_a_result = handle_a.join().unwrap();
    handle_b.join().unwrap();

    home_a_result.unwrap();
    home_b_result
        .expect("another transaction was blocked by slow temp-file preparation")
        .unwrap();
    assert_acknowledgement_homes(&support, &["prepare-home-a", "prepare-home-b"]);
    let _ = fs::remove_dir_all(support);
}

#[test]
fn parent_directory_sync_runs_after_releasing_global_lock() {
    let support = temp_root();
    fs::create_dir_all(&support).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let (sync_entered_tx, sync_entered_rx) = mpsc::channel();
    let sync_release = Arc::new(Barrier::new(2));

    let handle_a = {
        let sync_release = sync_release.clone();
        std::thread::spawn(move || {
            write_test_acknowledgement(
                "sync-home-a",
                "thread-a",
                &super::prepare_acknowledgement_at,
                move |_| {
                    sync_entered_tx.send(()).unwrap();
                    sync_release.wait();
                    Ok(())
                },
            )
        })
    };
    sync_entered_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("first transaction never reached parent-directory sync");

    let (home_b_done_tx, home_b_done_rx) = mpsc::channel();
    let handle_b = std::thread::spawn(move || {
        let result = write_test_acknowledgement(
            "sync-home-b",
            "thread-b",
            &super::prepare_acknowledgement_at,
            |_| Ok(()),
        );
        home_b_done_tx.send(result).unwrap();
    });
    let home_b_result = home_b_done_rx.recv_timeout(Duration::from_secs(5));
    sync_release.wait();
    let home_a_result = handle_a.join().unwrap();
    handle_b.join().unwrap();

    home_a_result.unwrap();
    home_b_result
        .expect("another transaction was blocked by parent-directory fsync")
        .unwrap();
    assert_acknowledgement_homes(&support, &["sync-home-a", "sync-home-b"]);
    let _ = fs::remove_dir_all(support);
}

#[test]
fn cross_process_acknowledgement_lock_fails_closed_without_overwriting() {
    let support = temp_root();
    fs::create_dir_all(&support).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    write_test_acknowledgement(
        "locked-home-a",
        "thread-a",
        &super::prepare_acknowledgement_at,
        |_| Ok(()),
    )
    .unwrap();
    let path = support.join("unread-acknowledgement.json");
    let before = fs::read(&path).unwrap();
    let lock = crate::core::cross_process_lock::CrossProcessFileLock::acquire(
        &super::acknowledgement_lock_path(&path),
        "测试未读基线事务",
    )
    .unwrap();

    let error = write_test_acknowledgement(
        "locked-home-b",
        "thread-b",
        &super::prepare_acknowledgement_at,
        |_| Ok(()),
    )
    .unwrap_err();

    assert!(error.contains("正在由另一个 Token Bar 进程执行"));
    assert_eq!(fs::read(&path).unwrap(), before);
    drop(lock);
    assert!(
        !fs::read_dir(&support)
            .unwrap()
            .flatten()
            .any(|entry| entry.file_name().to_string_lossy().ends_with(".tmp")),
        "contended transaction must clean its prepared file"
    );
    let _ = fs::remove_dir_all(support);
}

#[test]
fn existing_acknowledgement_target_is_atomically_replaced() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let path = root.join("unread-acknowledgement.json");
    fs::write(&path, b"old").unwrap();

    let outcome = write_acknowledgement_at_with_sync(
        &path,
        &UnreadAcknowledgement::default(),
        |_| Ok(()),
    )
    .unwrap();

    assert!(matches!(outcome, AcknowledgementWriteOutcome::Durable));
    assert_ne!(fs::read(&path).unwrap(), b"old");
    serde_json::from_slice::<serde_json::Value>(&fs::read(&path).unwrap()).unwrap();
    let _ = fs::remove_dir_all(root);
}

fn write_test_acknowledgement<P, S>(
    source_scope_key: &str,
    thread_id: &str,
    prepare: &P,
    sync_parent: S,
) -> Result<crate::models::UnreadSummary, String>
where
    P: Fn(
            &Path,
            &UnreadAcknowledgement,
        ) -> Result<crate::core::atomic_file::PreparedAtomicWrite, String>
        + ?Sized,
    S: FnOnce(&Path) -> Result<(), String>,
{
    super::acknowledgement_transaction_with_io(
        prepare,
        sync_parent,
        || Ok(()),
        |acknowledgement| {
            let home = acknowledgement
                .by_codex_home
                .entry(source_scope_key.to_string())
                .or_default();
            let changed = home.unread_thread_ids.insert(thread_id.to_string());
            Ok((super::unread_state_summary(0), changed))
        },
    )
}

fn assert_acknowledgement_homes(support: &Path, expected: &[&str]) {
    let data = fs::read(support.join("unread-acknowledgement.json")).unwrap();
    let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
    let homes = value["byCodexHome"].as_object().unwrap();
    assert_eq!(homes.len(), expected.len());
    for source_scope_key in expected {
        assert!(homes.contains_key(*source_scope_key));
    }
}

#[test]
fn post_commit_directory_sync_failure_reports_committed_summary() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let path = root.join("unread-acknowledgement.json");

    let outcome = write_acknowledgement_at_with_sync(
        &path,
        &UnreadAcknowledgement::default(),
        |_| Err("injected parent sync failure".into()),
    )
    .unwrap();

    assert!(matches!(
        outcome,
        AcknowledgementWriteOutcome::CommittedDurabilityUncertain(ref error)
            if error.contains("injected parent sync failure")
    ));
    assert!(path.exists(), "replacement is the commit point");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_commit_failure_publishes_new_summary_with_durability_diagnostic() {
    let root = temp_root();
    let support = root.join("tauri-support");
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let session = sessions.join("post-commit.jsonl");
    let thread_id = "019eaaaa-0000-0000-0000-000000000188";
    let now = current_time_seconds();
    write_session_meta(&session, thread_id);
    write_unread_state(&root, &[thread_id.to_string()]);
    acknowledge_current_unread(&root).unwrap();
    append_task_complete(&session, now + 1.0, "turn-post-commit");

    let summary = try_read_unread_summary_at_with_parent_sync(
        &root,
        now + 1.0,
        |_| Err("injected parent sync failure".into()),
    )
    .unwrap();

    assert_eq!(summary.count, 1);
    assert!(summary.source.ends_with("_durability_uncertain"));
    assert!(summary.detail.contains("已提交"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn physical_source_scope_does_not_inherit_acknowledgement_at_same_path() {
    let root = temp_root();
    let support = root.join("tauri-support");
    fs::create_dir_all(&root).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let thread_id = "019eaaaa-0000-0000-0000-000000000199";
    write_unread_state(&root, &[thread_id.to_string()]);

    super::acknowledge_current_unread_for_source(&root, "same-path|physical-a", || Ok(()))
        .unwrap();
    let summary = try_read_unread_summary_for_source(
        &root,
        "same-path|physical-b",
        || Ok(()),
    )
    .unwrap();

    assert_eq!(summary.count, 1);
    let persisted = fs::read_to_string(support.join("unread-acknowledgement.json")).unwrap();
    assert!(persisted.contains("same-path|physical-a"));
    assert!(!persisted.contains("same-path|physical-b"));
    let _ = fs::remove_dir_all(root);
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnreadCorrectnessSequence {
    steps: Vec<UnreadCorrectnessStep>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnreadCorrectnessStep {
    name: String,
    #[serde(rename = "nativeThreadIDs")]
    native_thread_ids: Vec<String>,
    append_completions: Vec<UnreadCorrectnessCompletion>,
    action: String,
    expected_count: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnreadCorrectnessCompletion {
    #[serde(rename = "expectedCanonicalID")]
    expected_canonical_id: String,
    #[serde(rename = "threadID")]
    thread_id: String,
    #[serde(rename = "turnID")]
    turn_id: String,
    completed_at_offset_seconds: f64,
    title: String,
}

fn temp_root() -> PathBuf {
    let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "codex-token-bar-unread-sequence-{}-{sequence}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn write_unread_state(root: &Path, ids: &[String]) {
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

fn write_session_meta(path: &Path, thread_id: &str) {
    let mut file = fs::File::create(path).unwrap();
    writeln!(
        file,
        r#"{{"type":"session_meta","payload":{{"id":"{thread_id}","thread_source":"user","source":"desktop"}}}}"#
    )
    .unwrap();
}

fn append_task_complete(path: &Path, completed_at: f64, turn_id: &str) {
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    writeln!(
        file,
        r#"{{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{{"type":"task_complete","turn_id":"{turn_id}","completed_at":{completed_at},"duration_ms":2000}}}}"#
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
