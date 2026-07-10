use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn scan_uses_config_provider_and_counts_jsonl_sqlite_index_mismatches() {
    let root = temp_root("provider-config");
    fs::create_dir_all(root.join("sessions/2026/06")).unwrap();
    fs::write(root.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    write_session(
        &root.join("sessions/2026/06/openai.jsonl"),
        "thread-openai",
        "openai",
    );
    write_session(
        &root.join("sessions/2026/06/old.jsonl"),
        "thread-old",
        "codex_local_access",
    );
    create_state_database(
        &root,
        &[
            ("thread-old", "codex_local_access", 0),
            ("thread-openai", "openai", 0),
        ],
    );
    fs::write(
        root.join("session_index.jsonl"),
        r#"{"id":"thread-old","thread_name":"old","updated_at":"2026-06-18T00:00:00Z"}"#,
    )
    .unwrap();

    let snapshot = scan_provider_repair(&root);
    assert_eq!(snapshot.detected_provider, "openai");
    assert_eq!(snapshot.provider_source, "config.toml");
    assert_eq!(snapshot.session_files_found, 2);
    assert_eq!(snapshot.inconsistent_count, 3);
    assert!(snapshot.status.contains("JSONL 1"));
    assert!(snapshot.status.contains("SQLite 1"));
    assert!(snapshot.status.contains("索引 1"));
    assert!(!snapshot.steps[0].healthy);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn scan_falls_back_to_latest_sqlite_provider_when_config_is_missing() {
    let root = temp_root("provider-sqlite");
    fs::create_dir_all(root.join("sessions")).unwrap();
    write_session(
        &root.join("sessions/old.jsonl"),
        "thread-old",
        "codex_local_access",
    );
    create_state_database(
        &root,
        &[
            ("thread-old", "codex_local_access", 0),
            ("thread-new", "openai", 0),
        ],
    );
    fs::write(
        root.join("session_index.jsonl"),
        r#"{"id":"thread-new","thread_name":"new","updated_at":"2026-06-18T00:00:00Z"}"#,
    )
    .unwrap();

    let snapshot = scan_provider_repair(&root);
    assert_eq!(snapshot.detected_provider, "openai");
    assert_eq!(snapshot.provider_source, "SQLite 最新会话");
    assert_eq!(snapshot.session_files_found, 1);
    assert_eq!(snapshot.inconsistent_count, 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn scan_ignores_empty_latest_sqlite_provider_and_uses_newest_jsonl() {
    let root = temp_root("provider-empty-sqlite-jsonl");
    fs::create_dir_all(root.join("sessions")).unwrap();
    fs::write(root.join("config.toml"), "# no top-level target provider\n").unwrap();
    write_session(
        &root.join("sessions/openai.jsonl"),
        "thread-openai",
        "openai",
    );
    create_state_database(
        &root,
        &[("thread-openai", "openai", 0), ("thread-empty", "", 0)],
    );

    let snapshot = scan_provider_repair(&root);
    assert_eq!(snapshot.detected_provider, "openai");
    assert_eq!(snapshot.provider_source, "最新 JSONL");
    assert_ne!(snapshot.detected_provider, "(missing)");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn config_provider_accepts_only_non_empty_top_level_toml_values() {
    let cases = [
        (
            "double-quoted",
            r#"model_provider = "codex_local_access""#,
            "codex_local_access",
            "config.toml",
        ),
        (
            "single-quoted",
            "model_provider = 'custom_provider'",
            "custom_provider",
            "config.toml",
        ),
        (
            "backup-lookalike",
            r#"model_provider_backup = "codex_local_access""#,
            "openai",
            "默认 openai",
        ),
        (
            "table-local-lookalike",
            r#"[profile]
model_provider = "codex_local_access""#,
            "openai",
            "默认 openai",
        ),
        (
            "commented-lookalike",
            r#"# model_provider = "codex_local_access""#,
            "openai",
            "默认 openai",
        ),
        (
            "blank-double-quoted",
            r#"model_provider = """#,
            "openai",
            "默认 openai",
        ),
        (
            "blank-single-quoted",
            "model_provider = ''",
            "openai",
            "默认 openai",
        ),
        (
            "malformed-toml",
            r#"model_provider = "codex_local_access"
["#,
            "openai",
            "默认 openai",
        ),
    ];

    for (label, config, expected_provider, expected_source) in cases {
        let root = temp_root(label);
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("config.toml"), format!("{config}\n")).unwrap();

        let snapshot = scan_provider_repair(&root);
        assert_eq!(snapshot.detected_provider, expected_provider, "{label}");
        assert_eq!(snapshot.provider_source, expected_source, "{label}");

        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn scan_does_not_select_missing_jsonl_provider() {
    let root = temp_root("provider-missing-jsonl");
    fs::create_dir_all(root.join("sessions")).unwrap();
    fs::write(
        root.join("sessions/missing.jsonl"),
        r#"{"type":"session_meta","payload":{"id":"thread-missing"}}"#,
    )
    .unwrap();

    let snapshot = scan_provider_repair(&root);
    assert_eq!(snapshot.detected_provider, "openai");
    assert_eq!(snapshot.provider_source, "默认 openai");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn sqlite_sync_rejects_invalid_provider_before_mutation() {
    let root = temp_root("provider-invalid-mutation");
    fs::create_dir_all(&root).unwrap();
    create_state_database(&root, &[("thread-openai", "openai", 0)]);

    for provider in ["", "   ", "(missing)"] {
        let error = sync_sqlite_provider(&root, provider).unwrap_err();
        assert!(error.contains("provider"), "{provider:?}: {error}");
    }

    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    let provider: String = connection
        .query_row(
            "SELECT model_provider FROM threads WHERE id = 'thread-openai';",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(provider, "openai");

    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn sqlite_sync_rehashes_published_snapshot_before_live_mutation() {
    let root = temp_root("provider-snapshot-rehash-live");
    let snapshot_root = temp_root("provider-snapshot-rehash-source");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&snapshot_root).unwrap();
    create_state_database(&root, &[("thread-live", "openai", 0)]);
    create_state_database(&snapshot_root, &[("thread-snapshot", "openai", 0)]);

    let snapshot = snapshot_root.join("state_5.sqlite");
    let original = fs::read(&snapshot).unwrap();
    let expected_size = u64::try_from(original.len()).unwrap();
    let expected_checksum = format!("{:x}", Sha256::digest(&original));
    let connection = Connection::open(&snapshot).unwrap();
    connection
        .execute(
            "UPDATE threads SET model_provider = 'vertex' WHERE id = 'thread-snapshot';",
            [],
        )
        .unwrap();
    drop(connection);
    assert_eq!(fs::metadata(&snapshot).unwrap().len(), expected_size);

    let pinned_home = PinnedHome::open(&root).unwrap();
    let error = sqlite_state::sync_sqlite_provider_from_snapshot_in(
        &pinned_home,
        "codex_local_access",
        &snapshot,
        expected_size,
        &expected_checksum,
    )
    .unwrap_err();
    assert!(error.contains("SHA-256"), "{error}");
    assert!(
        error.contains(snapshot.to_string_lossy().as_ref()),
        "{error}"
    );

    let live = Connection::open(root.join("state_5.sqlite")).unwrap();
    let provider: String = live
        .query_row(
            "SELECT model_provider FROM threads WHERE id = 'thread-live';",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(provider, "openai");

    drop(live);
    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(snapshot_root).unwrap();
}

#[test]
fn canonical_home_lease_rejects_concurrent_mutation_until_owner_exits() {
    let root = temp_root("provider-operation-lease");
    fs::create_dir_all(&root).unwrap();
    let owner_operation_id = operation_id(&root, "owner");
    let second_operation_id = operation_id(&root, "second");
    let after_operation_id = operation_id(&root, "after");
    let owner_home = root.clone();
    let thread_owner_operation_id = owner_operation_id.clone();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();

    let owner = thread::spawn(move || {
        run_provider_mutation(&owner_home, &thread_owner_operation_id, |_| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        })
    });

    entered_rx.recv().unwrap();
    let alias = root.join(".");
    let second = run_provider_mutation(&alias, &second_operation_id, |_| Ok(()));
    assert!(matches!(
        second,
        Err(ProviderOperationError::Busy {
            active_operation_id,
            ..
        }) if active_operation_id == owner_operation_id
    ));
    assert_eq!(
        read_provider_operation_status(&owner_operation_id).lifecycle,
        ProviderOperationLifecycle::Active
    );
    assert_eq!(
        read_provider_operation_status(&second_operation_id).lifecycle,
        ProviderOperationLifecycle::NotStarted
    );

    release_tx.send(()).unwrap();
    owner.join().unwrap().unwrap();
    assert_eq!(
        read_provider_operation_status(&owner_operation_id).lifecycle,
        ProviderOperationLifecycle::Finished
    );
    run_provider_mutation(&root, &after_operation_id, |_| Ok(())).unwrap();

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn provider_operation_pins_canonical_home_when_alias_is_retargeted() {
    use std::os::unix::fs::symlink;

    let fixture = temp_root("provider-operation-alias-retarget");
    let home_a = fixture.join("home-a");
    let home_b = fixture.join("home-b");
    let alias = fixture.join("selected-home");
    fs::create_dir_all(&home_a).unwrap();
    fs::create_dir_all(&home_b).unwrap();
    symlink(&home_a, &alias).unwrap();
    let operation = operation_id(&fixture, "retarget");

    run_provider_mutation(&alias, &operation, |canonical_home| {
        assert_eq!(canonical_home, home_a.canonicalize().unwrap());
        fs::remove_file(&alias).unwrap();
        symlink(&home_b, &alias).unwrap();
        fs::write(canonical_home.join("pinned.txt"), "home-a").unwrap();
        Ok(())
    })
    .unwrap();

    assert_eq!(
        fs::read_to_string(home_a.join("pinned.txt")).unwrap(),
        "home-a"
    );
    assert!(!home_b.join("pinned.txt").exists());
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(unix)]
#[test]
fn sync_and_automatic_restore_keep_using_the_original_home_after_root_swap() {
    use std::os::unix::fs::symlink;

    let fixture = temp_root("provider-sync-root-swap");
    let home = fixture.join("home");
    let held_home = fixture.join("held-home");
    let outside = fixture.join("outside");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::create_dir_all(outside.join("sessions")).unwrap();
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    let original_session = home.join("sessions/thread.jsonl");
    write_session(&original_session, "thread", "legacy-provider");
    create_state_database(&home, &[("thread", "legacy-provider", 0)]);
    fs::write(
        outside.join("config.toml"),
        "model_provider = \"outside-provider\"\n",
    )
    .unwrap();
    write_session(
        &outside.join("sessions/thread.jsonl"),
        "outside-thread",
        "outside-provider",
    );
    let outside_before = fs::read_to_string(outside.join("sessions/thread.jsonl")).unwrap();
    let mut swapped = false;

    let error = sync_provider_history_transaction_at_with_backup_hook(
        &home,
        &backup_root,
        scan_provider_repair_result,
        |phase, _| {
            if phase == backups::BackupPublicationPhase::SyncBackupRoot && !swapped {
                fs::rename(&home, &held_home).unwrap();
                symlink(&outside, &home).unwrap();
                swapped = true;
            }
            Ok(())
        },
    )
    .unwrap_err();

    assert!(swapped);
    assert!(error.contains("已自动恢复"), "{error}");
    assert!(fs::read_to_string(held_home.join("sessions/thread.jsonl"))
        .unwrap()
        .contains("legacy-provider"));
    assert_eq!(
        sqlite_provider_for_thread(&held_home, "thread"),
        "legacy-provider"
    );
    assert_eq!(
        fs::read_to_string(outside.join("sessions/thread.jsonl")).unwrap(),
        outside_before
    );
    assert!(!outside.join("state_5.sqlite").exists());
    fs::remove_file(&home).unwrap();
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(unix)]
#[test]
fn session_traversal_skips_directory_symlink_cycles() {
    use std::os::unix::fs::symlink;

    let root = temp_root("provider-session-symlink-cycle");
    let sessions = root.join("sessions/2026/07");
    fs::create_dir_all(&sessions).unwrap();
    write_session(&sessions.join("inside.jsonl"), "inside", "openai");
    symlink(root.join("sessions"), sessions.join("cycle")).unwrap();

    let files = find_session_files(&root, true).unwrap();

    assert_eq!(
        files,
        vec![sessions.join("inside.jsonl").canonicalize().unwrap()]
    );
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn session_traversal_rejects_candidates_outside_canonical_home() {
    use std::os::unix::fs::symlink;

    let root = temp_root("provider-session-root-containment");
    let outside = temp_root("provider-session-outside");
    fs::create_dir_all(root.join("sessions")).unwrap();
    fs::create_dir_all(&outside).unwrap();
    write_session(&outside.join("outside.jsonl"), "outside", "openai");
    symlink(&outside, root.join("sessions/outside-link")).unwrap();

    let files = find_session_files(&root, true).unwrap();

    assert!(files.is_empty());
    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside).unwrap();
}

#[cfg(unix)]
#[test]
fn session_rewrite_rejects_a_symlinked_parent_outside_canonical_home() {
    use std::os::unix::fs::symlink;

    let root = temp_root("provider-session-rewrite-root");
    let outside = temp_root("provider-session-rewrite-outside");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&outside).unwrap();
    let outside_session = outside.join("thread.jsonl");
    write_session(&outside_session, "outside", "codex_local_access");
    symlink(&outside, root.join("sessions")).unwrap();

    let error =
        rewrite_session_provider(&root, &root.join("sessions/thread.jsonl"), "openai").unwrap_err();

    assert!(
        error.contains("Codex Home") || error.contains("符号链接"),
        "{error}"
    );
    assert!(fs::read_to_string(&outside_session)
        .unwrap()
        .contains("codex_local_access"));
    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside).unwrap();
}

#[test]
fn operation_status_keeps_home_a_active_after_selected_source_changes_to_home_b() {
    let home_a = temp_root("provider-operation-home-a");
    let home_b = temp_root("provider-operation-home-b");
    fs::create_dir_all(&home_a).unwrap();
    fs::create_dir_all(&home_b).unwrap();
    let operation_a = operation_id(&home_a, "operation-a");
    let operation_b = operation_id(&home_b, "operation-b");
    let thread_operation_a = operation_a.clone();
    let thread_home_a = home_a.clone();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();

    assert_eq!(
        read_provider_operation_status(&operation_a).lifecycle,
        ProviderOperationLifecycle::NotStarted
    );

    let owner = thread::spawn(move || {
        run_provider_mutation(&thread_home_a, &thread_operation_a, |_| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        })
    });
    entered_rx.recv().unwrap();

    run_provider_mutation(&home_b, &operation_b, |_| Ok(())).unwrap();
    assert_eq!(
        read_provider_operation_status(&operation_b).lifecycle,
        ProviderOperationLifecycle::Finished
    );
    assert_eq!(
        read_provider_operation_status(&operation_a).lifecycle,
        ProviderOperationLifecycle::Active
    );

    release_tx.send(()).unwrap();
    owner.join().unwrap().unwrap();
    assert_eq!(
        read_provider_operation_status(&operation_a).lifecycle,
        ProviderOperationLifecycle::Finished
    );

    fs::remove_dir_all(home_a).unwrap();
    fs::remove_dir_all(home_b).unwrap();
}

#[test]
fn discovery_reports_active_provider_owners_without_operation_ids() {
    let home_a = temp_root("provider-operation-discovery-a");
    let home_b = temp_root("provider-operation-discovery-b");
    fs::create_dir_all(&home_a).unwrap();
    fs::create_dir_all(&home_b).unwrap();
    let operation_a = operation_id(&home_a, "operation-a");
    let operation_b = operation_id(&home_b, "operation-b");
    let canonical_home_a = canonical_codex_home(&home_a).unwrap();
    let canonical_home_b = canonical_codex_home(&home_b).unwrap();
    let lease_a = acquire_provider_operation_lease(&home_a, &operation_a).unwrap();
    let lease_b = acquire_provider_operation_lease(&home_b, &operation_b).unwrap();
    let recovery_status = ProviderRecoveryState::default().snapshot();

    let discovery = discover_provider_operation_ownership(recovery_status.clone());
    assert!(discovery.recovery_status.blocked);
    let discovered_owners = discovery
        .active_operations
        .into_iter()
        .filter(|owner| owner.operation_id == operation_a || owner.operation_id == operation_b)
        .collect::<Vec<_>>();
    assert_eq!(
        discovered_owners,
        vec![
            ProviderOperationOwnership {
                operation_id: operation_a.clone(),
                canonical_home: canonical_home_a,
            },
            ProviderOperationOwnership {
                operation_id: operation_b.clone(),
                canonical_home: canonical_home_b.clone(),
            },
        ]
    );

    drop(lease_a);
    let after_first_drop = discover_provider_operation_ownership(recovery_status.clone());
    assert!(!after_first_drop
        .active_operations
        .iter()
        .any(|owner| owner.operation_id == operation_a));
    assert!(
        after_first_drop
            .active_operations
            .iter()
            .any(|owner| owner.operation_id == operation_b
                && owner.canonical_home == canonical_home_b)
    );

    drop(lease_b);
    assert!(!discover_provider_operation_ownership(recovery_status)
        .active_operations
        .iter()
        .any(|owner| owner.operation_id == operation_a || owner.operation_id == operation_b));
    fs::remove_dir_all(home_a).unwrap();
    fs::remove_dir_all(home_b).unwrap();
}

#[test]
fn provider_operation_lease_releases_after_mutation_error() {
    let root = temp_root("provider-operation-error-release");
    fs::create_dir_all(&root).unwrap();
    let failed_operation_id = operation_id(&root, "failed");
    let after_operation_id = operation_id(&root, "after");

    let failure = run_provider_mutation::<()>(&root, &failed_operation_id, |_| {
        Err("fixture mutation failed".into())
    });
    assert!(matches!(
        failure,
        Err(ProviderOperationError::Failed { message }) if message == "fixture mutation failed"
    ));
    assert_eq!(
        read_provider_operation_status(&failed_operation_id).lifecycle,
        ProviderOperationLifecycle::Finished
    );
    run_provider_mutation(&root, &after_operation_id, |_| Ok(())).unwrap();

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dropping_stale_owner_does_not_erase_replacement_owner() {
    let root = temp_root("provider-operation-replacement-owner");
    fs::create_dir_all(&root).unwrap();
    let stale_operation_id = operation_id(&root, "stale");
    let replacement_operation_id = operation_id(&root, "replacement");
    let stale_lease = acquire_provider_operation_lease(&root, &stale_operation_id).unwrap();
    let canonical_home = canonical_codex_home(&root).unwrap();

    {
        let mut registry = provider_operation_registry()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.replace_owner_for_test(canonical_home, replacement_operation_id.clone());
    }

    drop(stale_lease);
    assert_eq!(
        read_provider_operation_status(&replacement_operation_id).lifecycle,
        ProviderOperationLifecycle::Active
    );

    {
        let mut registry = provider_operation_registry()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.finish(&replacement_operation_id);
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn finished_operation_tombstones_are_bounded_and_pruned_oldest_first() {
    let root = temp_root("provider-operation-tombstones");
    let canonical_home = root.join("canonical-home");
    let mut registry = ProviderOperationRegistry::default();
    let total = MAX_FINISHED_PROVIDER_OPERATIONS + 1;

    for index in 0..total {
        let operation_id = format!("operation-{index}");
        registry
            .acquire(canonical_home.join(index.to_string()), &operation_id)
            .unwrap();
        registry.finish(&operation_id);
    }

    assert_eq!(registry.finished_count(), MAX_FINISHED_PROVIDER_OPERATIONS);
    assert_eq!(
        registry.status("operation-0").lifecycle,
        ProviderOperationLifecycle::NotStarted
    );
    assert_eq!(
        registry
            .status(&format!("operation-{}", total - 1))
            .lifecycle,
        ProviderOperationLifecycle::Finished
    );
}

#[test]
fn provider_busy_error_serializes_as_typed_frontend_payload() {
    let value = serde_json::to_value(ProviderOperationError::Busy {
        active_operation_id: "operation-a".into(),
        message: "busy".into(),
    })
    .unwrap();

    assert_eq!(value["kind"], "busy");
    assert_eq!(value["activeOperationId"], "operation-a");
    assert_eq!(value["message"], "busy");
}

#[test]
fn provider_recovery_blocked_error_serializes_diagnostic_status() {
    let value = serde_json::to_value(ProviderOperationError::RecoveryBlocked {
        code: "accountIdentityMismatch".into(),
        message: "blocked".into(),
        recovery_path: Some(PathBuf::from("/tmp/recovery")),
    })
    .unwrap();

    assert_eq!(value["kind"], "recoveryBlocked");
    assert_eq!(value["code"], "accountIdentityMismatch");
    assert_eq!(value["message"], "blocked");
    assert_eq!(value["recoveryPath"], "/tmp/recovery");
    assert!(value.get("recovery_path").is_none());
}

#[test]
fn provider_operation_lifecycle_serializes_for_frontend_reconciliation() {
    let value = serde_json::to_value(ProviderOperationStatus {
        operation_id: "operation-a".into(),
        lifecycle: ProviderOperationLifecycle::Active,
    })
    .unwrap();

    assert_eq!(value["operationId"], "operation-a");
    assert_eq!(value["lifecycle"], "active");
}

#[test]
fn running_codex_backend_probe_rejects_sync_and_rollback_under_the_home_lease() {
    for operation in ["同步", "回滚"] {
        let root = temp_root(&format!("provider-running-guard-{operation}"));
        fs::create_dir_all(&root).unwrap();
        let operation_id = operation_id(&root, operation);
        let mut mutation_started = false;

        let result = run_provider_mutation_with_running_probe(
            &root,
            &operation_id,
            operation,
            || Ok(true),
            |_| {
                mutation_started = true;
                Ok(())
            },
        );

        assert!(
            matches!(result, Err(ProviderOperationError::Failed { ref message })
            if message.contains("Codex 正在运行") && message.contains(operation))
        );
        assert!(!mutation_started, "{operation}");
        assert_eq!(
            read_provider_operation_status(&operation_id).lifecycle,
            ProviderOperationLifecycle::Finished
        );
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn running_codex_guard_does_not_block_scan_verify_or_explicit_backup_paths() {
    let root = temp_root("provider-running-read-only");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("config.toml"), "model_provider = \"openai\"\n").unwrap();

    let scan = scan_provider_repair(&root);
    let verify = verify_provider_repair(&root);
    let operation = operation_id(&root, "backup");
    let backup_path_available = run_provider_mutation(&root, &operation, |_| Ok(true)).unwrap();

    assert_eq!(scan.detected_provider, "openai");
    assert_eq!(verify.snapshot.detected_provider, "openai");
    assert!(backup_path_available);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn sync_core_logic_rewrites_sources_and_repairs_index() {
    let root = temp_root("provider-sync-core");
    fs::create_dir_all(root.join("sessions/2026/06")).unwrap();
    fs::write(root.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    let old_session = root.join("sessions/2026/06/old.jsonl");
    write_session(&old_session, "thread-old", "codex_local_access");
    write_session(
        &root.join("sessions/2026/06/openai.jsonl"),
        "thread-openai",
        "openai",
    );
    create_state_database(
        &root,
        &[
            ("thread-old", "codex_local_access", 0),
            ("thread-openai", "openai", 0),
        ],
    );

    let before = scan_provider_repair(&root);
    assert_eq!(before.inconsistent_count, 3);

    let report = scan_provider_repair_result(&root).unwrap();
    for file in find_session_files(&root, true).unwrap() {
        rewrite_session_provider(&root, &file, &report.target.provider).unwrap();
    }
    let changed_rows = sync_sqlite_provider(&root, &report.target.provider).unwrap();
    let index_changed = repair_session_index(&root).unwrap();

    assert_eq!(changed_rows, 1);
    assert!(index_changed);
    assert!(fs::read_to_string(old_session)
        .unwrap()
        .contains(r#""model_provider":"openai""#));
    assert!(fs::read_to_string(root.join("session_index.jsonl"))
        .unwrap()
        .contains("thread-openai"));
    let after = scan_provider_repair(&root);
    assert_eq!(after.inconsistent_count, 0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn sync_transaction_creates_and_returns_a_fresh_backup() {
    let fixture = temp_root("provider-sync-fresh-backup");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    write_session(
        &home.join("sessions/thread.jsonl"),
        "thread",
        "codex_local_access",
    );
    create_state_database(&home, &[("thread", "codex_local_access", 0)]);
    let stale = backups::create_provider_backup_files_at(&backup_root, &home, "codex_local_access")
        .unwrap();

    let outcome =
        sync_provider_history_transaction_at(&home, &backup_root, scan_provider_repair_result)
            .unwrap();

    assert_ne!(outcome.backup.id, stale.id);
    assert_eq!(outcome.backup.target_provider, "openai");
    assert_eq!(outcome.snapshot.inconsistent_count, 0);
    assert!(PathBuf::from(&outcome.backup.path)
        .join("manifest.json")
        .exists());
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn verification_error_automatically_restores_the_fresh_backup() {
    let fixture = temp_root("provider-sync-verification-error");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    let session = home.join("sessions/thread.jsonl");
    write_session(&session, "thread", "codex_local_access");
    create_state_database(&home, &[("thread", "codex_local_access", 0)]);

    let error = sync_provider_history_transaction_at(&home, &backup_root, |_home| {
        Err("fixture verification threw".into())
    })
    .unwrap_err();

    assert!(error.contains("fixture verification threw"), "{error}");
    assert!(error.contains("自动恢复"), "{error}");
    assert!(fs::read_to_string(&session)
        .unwrap()
        .contains("codex_local_access"));
    assert_eq!(
        sqlite_provider_for_thread(&home, "thread"),
        "codex_local_access"
    );
    assert_eq!(completed_backup_count(&backup_root), 1);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn verification_mismatch_after_all_writes_automatically_restores() {
    let fixture = temp_root("provider-sync-verification-mismatch");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    let session = home.join("sessions/thread.jsonl");
    write_session(&session, "thread", "codex_local_access");
    create_state_database(&home, &[("thread", "codex_local_access", 0)]);

    let error = sync_provider_history_transaction_at(&home, &backup_root, |canonical_home| {
        write_session(
            &canonical_home.join("sessions/thread.jsonl"),
            "thread",
            "verification-mismatch",
        );
        scan_provider_repair_result(canonical_home)
    })
    .unwrap_err();

    assert!(error.contains("验证"), "{error}");
    assert!(error.contains("自动恢复"), "{error}");
    assert!(fs::read_to_string(&session)
        .unwrap()
        .contains("codex_local_access"));
    assert_eq!(
        sqlite_provider_for_thread(&home, "thread"),
        "codex_local_access"
    );
    assert_eq!(completed_backup_count(&backup_root), 1);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn backup_scope_validation_rejects_other_codex_home() {
    let source = temp_root("provider-backup-source");
    let other = temp_root("provider-backup-other");
    fs::create_dir_all(&source).unwrap();
    fs::create_dir_all(&other).unwrap();
    let backup = backup_info_for_home(&source);

    assert!(ensure_backup_matches_codex_home(&backup, &source).is_ok());
    let mismatch = ensure_backup_matches_codex_home(&backup, &other).unwrap_err();
    assert!(mismatch.contains("备份属于"));

    let mut legacy = backup_info_for_home(&source);
    legacy.codex_home_fingerprint.clear();
    let legacy_error = ensure_backup_matches_codex_home(&legacy, &source).unwrap_err();
    assert!(legacy_error.contains("缺少 Codex Home"));

    fs::remove_dir_all(source).unwrap();
    fs::remove_dir_all(other).unwrap();
}

#[test]
fn same_second_backups_use_distinct_create_new_directories() {
    let fixture = temp_root("provider-backup-unique-id");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    write_session(&home.join("sessions/thread.jsonl"), "thread", "openai");
    create_state_database(&home, &[("thread", "openai", 0)]);

    let first = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    let second = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();

    assert_ne!(first.id, second.id);
    assert!(PathBuf::from(first.path).join("manifest.json").is_file());
    assert!(PathBuf::from(second.path).join("manifest.json").is_file());
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn sqlite_backup_preserves_committed_wal_rows_and_integrity() {
    let fixture = temp_root("provider-backup-wal");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    let database_path = home.join("state_5.sqlite");
    let writer = Connection::open(&database_path).unwrap();
    writer
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE committed_rows (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA wal_checkpoint(TRUNCATE);
            INSERT INTO committed_rows (value) VALUES ('committed-in-wal');
            "#,
        )
        .unwrap();
    assert!(
        fs::metadata(database_path.with_extension("sqlite-wal"))
            .unwrap()
            .len()
            > 0
    );

    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    let snapshot_path = PathBuf::from(&backup.path).join("state_5.sqlite.before");
    assert!(!PathBuf::from(format!("{}-wal", snapshot_path.display())).exists());
    assert!(!PathBuf::from(format!("{}-shm", snapshot_path.display())).exists());
    writer
        .execute(
            "UPDATE committed_rows SET value = 'mutated-after-backup' WHERE id = 1",
            [],
        )
        .unwrap();
    #[cfg(windows)]
    drop(writer);
    backups::restore_provider_backup_files_at(&home, &backup).unwrap();
    #[cfg(not(windows))]
    drop(writer);

    let restored = Connection::open(&database_path).unwrap();
    let value: String = restored
        .query_row("SELECT value FROM committed_rows WHERE id = 1", [], |row| {
            row.get(0)
        })
        .unwrap();
    let integrity: String = restored
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .unwrap();

    assert_eq!(value, "committed-in-wal");
    assert_eq!(integrity, "ok");
    drop(restored);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn later_restore_failure_with_active_wal_uses_verified_sqlite_compensation() {
    let fixture = temp_root("provider-restore-wal-compensation");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    fs::write(home.join("session_index.jsonl"), "backup-index").unwrap();
    let database_path = home.join("state_5.sqlite");
    let writer = Connection::open(&database_path).unwrap();
    writer
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE committed_rows (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA wal_checkpoint(TRUNCATE);
            INSERT INTO committed_rows (value) VALUES ('backup-value');
            "#,
        )
        .unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    writer
        .execute(
            "UPDATE committed_rows SET value = 'live-before-restore' WHERE id = 1",
            [],
        )
        .unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    fs::write(home.join("session_index.jsonl"), "live-index").unwrap();

    let error = backups::restore_provider_backup_files_at_with_hook(
        &home,
        &backup,
        |phase, _index, relative_path| {
            if phase == backups::RestorePhase::Apply
                && relative_path == Path::new("session_index.jsonl")
            {
                Err("fixture later non-SQLite restore failure".into())
            } else {
                Ok(())
            }
        },
    )
    .unwrap_err();

    #[cfg(windows)]
    {
        assert!(error.contains("state_5.sqlite-wal"), "{error}");
        assert!(error.contains("恢复材料保留于"), "{error}");
        assert_eq!(
            writer
                .query_row("SELECT value FROM committed_rows WHERE id = 1", [], |row| {
                    row.get::<_, String>(0)
                },)
                .unwrap(),
            "live-before-restore"
        );
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            "live-config"
        );
        assert_eq!(
            fs::read_to_string(home.join("session_index.jsonl")).unwrap(),
            "live-index"
        );
        drop(writer);
    }
    #[cfg(not(windows))]
    {
        drop(writer);
        assert!(error.contains("已补偿"), "{error}");
        assert_eq!(
            sqlite_text_value(
                &database_path,
                "SELECT value FROM committed_rows WHERE id = 1"
            ),
            "live-before-restore"
        );
        assert_eq!(sqlite_integrity(&database_path), "ok");
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            "live-config"
        );
    }
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn v2_manifest_requires_the_exact_member_schema_before_mutation() {
    let cases = [
        "empty",
        "missing-sidecar",
        "extra-member",
        "duplicate-source",
        "duplicate-sqlite-kind",
    ];

    for case in cases {
        let fixture = temp_root(&format!("provider-manifest-{case}"));
        let home = fixture.join("home");
        let backup_root = fixture.join("backups");
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join("config.toml"), "same-bytes").unwrap();
        fs::write(home.join("session_index.jsonl"), "same-bytes").unwrap();
        create_state_database(&home, &[("thread", "openai", 0)]);
        let backup =
            backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
        fs::write(home.join("config.toml"), "live-must-remain").unwrap();
        rewrite_backup_manifest(&backup, |manifest| {
            let members = manifest["members"].as_array_mut().unwrap();
            match case {
                "empty" => members.clear(),
                "missing-sidecar" => {
                    members.retain(|member| member["relative_path"] != "state_5.sqlite-wal")
                }
                "extra-member" => members.push(serde_json::json!({
                    "kind": "fixed",
                    "relative_path": "unexpected.toml",
                    "backup_path": null,
                    "present": false,
                    "size": 0,
                    "checksum_sha256": null
                })),
                "duplicate-source" => {
                    let config = members
                        .iter()
                        .find(|member| member["relative_path"] == "config.toml")
                        .unwrap()
                        .clone();
                    let index = members
                        .iter_mut()
                        .find(|member| member["relative_path"] == "session_index.jsonl")
                        .unwrap();
                    index["backup_path"] = config["backup_path"].clone();
                    index["size"] = config["size"].clone();
                    index["checksum_sha256"] = config["checksum_sha256"].clone();
                }
                "duplicate-sqlite-kind" => {
                    let sqlite = members
                        .iter()
                        .find(|member| member["kind"] == "sqlite")
                        .unwrap()
                        .clone();
                    members.push(sqlite);
                }
                _ => unreachable!(),
            }
        });

        let error = backups::restore_provider_backup_files_at(&home, &backup).unwrap_err();
        assert!(error.contains("manifest"), "{case}: {error}");
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            "live-must-remain",
            "{case}"
        );
        fs::remove_dir_all(fixture).unwrap();
    }
}

#[test]
fn legacy_v1_backup_is_listed_read_only_and_rejected_for_v2_restore() {
    let fixture = temp_root("provider-legacy-v1-list");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    let backup_path = backup_root.join("legacy-v1");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&backup_path).unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    fs::write(
        backup_path.join("manifest.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "id": "legacy-v1",
            "created_at": "2026-07-01T00:00:00Z",
            "codex_home": backups::codex_home_identity(&home),
            "codex_home_fingerprint": backups::codex_home_fingerprint(&home),
            "target_provider": "openai",
            "session_files": 2,
            "state_database": true,
            "session_index": true
        }))
        .unwrap(),
    )
    .unwrap();

    let listed = backups::list_provider_backups_at(&backup_root).unwrap();
    assert_eq!(listed.len(), 1);
    let legacy = &listed[0];
    assert_eq!(
        legacy.restore_status,
        crate::models::ProviderRepairBackupRestoreStatus::LegacyUnsupported
    );
    assert_eq!(legacy.path, backup_path.display().to_string());
    assert!(legacy
        .restore_unsupported_reason
        .as_deref()
        .unwrap()
        .contains("v1"));
    let api_value = serde_json::to_value(legacy).unwrap();
    assert_eq!(api_value["restoreStatus"], "legacyUnsupported");
    assert!(api_value["restoreUnsupportedReason"]
        .as_str()
        .unwrap()
        .contains("v1"));

    let error = backups::restore_provider_backup_files_at(&home, legacy).unwrap_err();
    assert!(error.contains("v2"), "{error}");
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "live-config"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn restore_capture_failure_cleans_partial_recovery_staging() {
    let fixture = temp_root("provider-restore-capture-cleanup");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    fs::write(home.join("session_index.jsonl"), "backup-index").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();

    let error =
        backups::restore_provider_backup_files_at_with_hook(&home, &backup, |phase, index, _| {
            if phase == backups::RestorePhase::Capture && index == 1 {
                Err("fixture capture failure".into())
            } else {
                Ok(())
            }
        })
        .unwrap_err();

    assert!(error.contains("fixture capture failure"), "{error}");
    assert_no_recovery_staging(&backup_root);
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "live-config"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn recovery_manifest_publication_failure_cleans_staging_before_apply() {
    let fixture = temp_root("provider-recovery-manifest-cleanup");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();

    let error =
        backups::restore_provider_backup_files_at_with_hook(&home, &backup, |phase, _, _| {
            if phase == backups::RestorePhase::PublishRecoveryManifest {
                Err("fixture recovery manifest publication failure".into())
            } else {
                Ok(())
            }
        })
        .unwrap_err();

    assert!(error.contains("publication failure"), "{error}");
    assert_no_recovery_staging(&backup_root);
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "live-config"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn restore_temp_validation_failure_removes_staged_temp_file() {
    let fixture = temp_root("provider-restore-temp-cleanup");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();

    let error = backups::restore_provider_backup_files_at_with_hook(
        &home,
        &backup,
        |phase, _, relative| {
            if phase == backups::RestorePhase::ValidateTemp && relative == Path::new("config.toml")
            {
                Err("fixture temp metadata failure".into())
            } else {
                Ok(())
            }
        },
    )
    .unwrap_err();

    assert!(error.contains("temp metadata failure"), "{error}");
    assert!(!fs::read_dir(&home)
        .unwrap()
        .flatten()
        .any(|entry| { entry.file_name().to_string_lossy().contains(".restore-") }));
    assert_no_recovery_staging(&backup_root);
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "live-config"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn successful_restore_cleanup_failure_quarantines_and_reports_recovery_material() {
    let fixture = temp_root("provider-restore-cleanup-quarantine");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();

    let error =
        backups::restore_provider_backup_files_at_with_hook(&home, &backup, |phase, _, _| {
            if phase == backups::RestorePhase::Cleanup {
                Err("fixture cleanup failure".into())
            } else {
                Ok(())
            }
        })
        .unwrap_err();

    assert!(error.contains("fixture cleanup failure"), "{error}");
    assert!(error.contains(".restore-quarantine-"), "{error}");
    assert!(fs::read_dir(&backup_root).unwrap().flatten().any(|entry| {
        entry
            .file_name()
            .to_string_lossy()
            .starts_with(".restore-quarantine-")
    }));
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "backup-config"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn publication_sync_failure_aborts_sync_before_any_live_write() {
    let fixture = temp_root("provider-publication-sync-failure");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    let session = home.join("sessions/thread.jsonl");
    write_session(&session, "thread", "codex_local_access");
    create_state_database(&home, &[("thread", "codex_local_access", 0)]);

    let error = sync_provider_history_transaction_at_with_backup_hook(
        &home,
        &backup_root,
        scan_provider_repair_result,
        |phase, _| {
            if phase == backups::BackupPublicationPhase::SyncBackupRoot {
                Err("fixture backup root sync failure".into())
            } else {
                Ok(())
            }
        },
    )
    .unwrap_err();

    assert!(error.contains("root sync failure"), "{error}");
    assert!(fs::read_to_string(&session)
        .unwrap()
        .contains("codex_local_access"));
    assert_eq!(
        sqlite_provider_for_thread(&home, "thread"),
        "codex_local_access"
    );
    assert_eq!(completed_backup_count(&backup_root), 0);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn failed_post_restore_verification_compensates_before_recovery_cleanup() {
    let fixture = temp_root("provider-post-restore-verification");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    create_state_database(&home, &[("thread", "backup-provider", 0)]);
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    let connection = Connection::open(home.join("state_5.sqlite")).unwrap();
    connection
        .execute(
            "UPDATE threads SET model_provider = 'live-provider' WHERE id = 'thread'",
            [],
        )
        .unwrap();
    drop(connection);

    let error = backups::restore_provider_backup_files_at_with_verification_and_hook(
        &home,
        &backup,
        |_, _, _| Ok(()),
        |_| Err("fixture post-restore provider verification failure".into()),
    )
    .unwrap_err();

    assert!(error.contains("provider verification failure"), "{error}");
    assert!(error.contains("已补偿"), "{error}");
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "live-config"
    );
    assert_eq!(sqlite_provider_for_thread(&home, "thread"), "live-provider");
    assert_eq!(sqlite_integrity(&home.join("state_5.sqlite")), "ok");
    assert_no_recovery_staging(&backup_root);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn final_restore_verification_rehashes_every_installed_member_before_cleanup() {
    let fixture = temp_root("provider-final-installed-member-verification");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    let session = home.join("sessions/thread.jsonl");
    fs::create_dir_all(session.parent().unwrap()).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    fs::write(
        &session,
        concat!(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\",\"model_provider\":\"openai\"}}\n",
            "{\"type\":\"event\",\"payload\":\"backup-body\"}\n"
        ),
    )
    .unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    let live_before_restore = concat!(
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\",\"model_provider\":\"openai\"}}\n",
        "{\"type\":\"event\",\"payload\":\"live-body\"}\n"
    );
    fs::write(&session, live_before_restore).unwrap();

    let error = backups::restore_provider_backup_files_at_with_verification_and_hook(
        &home,
        &backup,
        |phase, _, _| {
            if phase == backups::RestorePhase::Verify {
                fs::write(
                    &session,
                    concat!(
                        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread\",\"model_provider\":\"openai\"}}\n",
                        "{\"type\":\"event\",\"payload\":\"tampered-after-apply\"}\n"
                    ),
                )
                .unwrap();
            }
            Ok(())
        },
        |restored_home| verify_restored_provider_backup(restored_home, &backup).map(|_| ()),
    )
    .unwrap_err();

    assert!(
        error.contains("SHA-256") || error.contains("大小"),
        "{error}"
    );
    assert!(error.contains("已补偿"), "{error}");
    assert_eq!(fs::read_to_string(&session).unwrap(), live_before_restore);
    assert_no_recovery_staging(&backup_root);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn failed_sqlite_snapshot_never_publishes_a_manifest() {
    let fixture = temp_root("provider-backup-incomplete");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("state_5.sqlite"), b"not a sqlite database").unwrap();

    let error =
        backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap_err();

    assert!(error.contains("SQLite"), "{error}");
    let published_manifests = fs::read_dir(&backup_root)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.path().join("manifest.json").exists())
        .count();
    assert_eq!(published_manifests, 0);
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(unix)]
#[test]
fn backup_rejects_a_dangling_symlink_instead_of_recording_it_absent() {
    use std::os::unix::fs::symlink;

    let fixture = temp_root("provider-backup-dangling-symlink");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    symlink(fixture.join("missing-config"), home.join("config.toml")).unwrap();

    let error =
        backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap_err();

    assert!(error.contains("符号链接"), "{error}");
    assert_eq!(completed_backup_count(&backup_root), 0);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn restore_rejects_same_length_backup_member_corruption() {
    let fixture = temp_root("provider-restore-member-checksum");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("config.toml"), "AAAA").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(
        PathBuf::from(&backup.path).join("config.toml.before"),
        "BBBB",
    )
    .unwrap();
    fs::write(home.join("config.toml"), "LIVE").unwrap();

    let error = backups::restore_provider_backup_files_at(&home, &backup).unwrap_err();

    assert!(error.contains("校验"), "{error}");
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "LIVE"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn restore_revalidates_member_bytes_immediately_before_replacement() {
    let fixture = temp_root("provider-restore-member-toctou");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "AAAA").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "LIVE").unwrap();
    let backup_config = PathBuf::from(&backup.path).join("config.toml.before");

    let error = backups::restore_provider_backup_files_at_with_hook(
        &home,
        &backup,
        |phase, index, _relative_path| {
            if phase == backups::RestorePhase::Apply && index == 0 {
                fs::write(&backup_config, "BBBB").unwrap();
            }
            Ok(())
        },
    )
    .unwrap_err();

    assert!(error.contains("SHA-256"), "{error}");
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "LIVE"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn atomic_replace_repeatedly_overwrites_an_existing_destination() {
    let root = temp_root("provider-atomic-replace");
    fs::create_dir_all(&root).unwrap();
    let destination = root.join("session.jsonl");
    fs::write(&destination, "version-0").unwrap();

    for version in 1..=3 {
        let replacement = root.join(format!("replacement-{version}.tmp"));
        fs::write(&replacement, format!("version-{version}")).unwrap();
        session_files::replace_file_atomically(&replacement, &destination).unwrap();
        assert_eq!(
            fs::read_to_string(&destination).unwrap(),
            format!("version-{version}")
        );
        assert!(!replacement.exists());
    }

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn restore_rejects_manifest_member_outside_canonical_home() {
    let fixture = temp_root("provider-restore-member-scope");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    let outside = fixture.join("outside.jsonl");
    fs::create_dir_all(home.join("sessions")).unwrap();
    write_session(&home.join("sessions/thread.jsonl"), "thread", "openai");
    fs::write(&outside, "outside-original").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    let manifest_path = PathBuf::from(&backup.path).join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    let session_member = manifest["members"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|member| member["kind"] == "session")
        .unwrap();
    session_member["relative_path"] = serde_json::Value::String("../outside.jsonl".into());
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();

    let error = backups::restore_provider_backup_files_at(&home, &backup).unwrap_err();

    assert!(error.contains("成员") || error.contains("路径"), "{error}");
    assert_eq!(fs::read_to_string(&outside).unwrap(), "outside-original");
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn later_restore_failure_compensates_to_the_pre_restore_state() {
    let fixture = temp_root("provider-restore-compensation");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    fs::write(home.join("session_index.jsonl"), "backup-index").unwrap();
    write_session(&home.join("sessions/thread.jsonl"), "thread", "openai");
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    fs::write(home.join("session_index.jsonl"), "live-index").unwrap();
    fs::write(home.join("sessions/thread.jsonl"), "live-session").unwrap();

    let error = backups::restore_provider_backup_files_at_with_hook(
        &home,
        &backup,
        |phase, index, _relative_path| {
            if phase == backups::RestorePhase::Apply && index == 2 {
                Err("fixture later apply failure".into())
            } else {
                Ok(())
            }
        },
    )
    .unwrap_err();

    assert!(error.contains("fixture later apply failure"), "{error}");
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "live-config"
    );
    assert_eq!(
        fs::read_to_string(home.join("session_index.jsonl")).unwrap(),
        "live-index"
    );
    assert_eq!(
        fs::read_to_string(home.join("sessions/thread.jsonl")).unwrap(),
        "live-session"
    );
    assert!(PathBuf::from(&backup.path).join("manifest.json").exists());
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn incomplete_restore_compensation_retains_recovery_material() {
    let fixture = temp_root("provider-restore-compensation-failure");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    fs::write(home.join("session_index.jsonl"), "backup-index").unwrap();
    write_session(&home.join("sessions/thread.jsonl"), "thread", "openai");
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    fs::write(home.join("session_index.jsonl"), "live-index").unwrap();

    let error = backups::restore_provider_backup_files_at_with_hook(
        &home,
        &backup,
        |phase, index, _relative_path| match phase {
            backups::RestorePhase::Apply if index == 2 => Err("fixture apply failure".into()),
            backups::RestorePhase::Compensate => Err("fixture compensation failure".into()),
            _ => Ok(()),
        },
    )
    .unwrap_err();

    assert!(error.contains("恢复材料"), "{error}");
    assert!(PathBuf::from(&backup.path).join("manifest.json").exists());
    let retained = fs::read_dir(&backup_root).unwrap().flatten().any(|entry| {
        entry
            .file_name()
            .to_string_lossy()
            .contains("restore-recovery")
    });
    assert!(retained);
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn manifest_rejects_dot_and_repeated_separator_aliases_before_mutation() {
    for alias in ["sessions/./thread.jsonl", "sessions//thread.jsonl"] {
        let fixture = temp_root("provider-manifest-normalized-alias");
        let home = fixture.join("home");
        let backup_root = fixture.join("backups");
        fs::create_dir_all(home.join("sessions")).unwrap();
        write_session(&home.join("sessions/thread.jsonl"), "thread", "openai");
        let backup =
            backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
        fs::write(home.join("sessions/thread.jsonl"), "live-must-remain\n").unwrap();
        rewrite_backup_manifest(&backup, |manifest| {
            let members = manifest["members"].as_array_mut().unwrap();
            let mut duplicate = members
                .iter()
                .find(|member| member["relative_path"] == "sessions/thread.jsonl")
                .unwrap()
                .clone();
            duplicate["relative_path"] = alias.into();
            duplicate["backup_path"] = format!("session-jsonl/{alias}").into();
            members.push(duplicate);
        });

        let error = backups::restore_provider_backup_files_at(&home, &backup).unwrap_err();

        assert!(error.contains("非规范序列化"), "{alias}: {error}");
        assert_eq!(
            fs::read_to_string(home.join("sessions/thread.jsonl")).unwrap(),
            "live-must-remain\n"
        );
        fs::remove_dir_all(fixture).unwrap();
    }
}

#[cfg(any(target_os = "macos", windows))]
#[test]
fn manifest_rejects_case_folded_session_aliases_before_mutation() {
    let fixture = temp_root("provider-manifest-case-alias");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    write_session(&home.join("sessions/thread.jsonl"), "thread", "openai");
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("sessions/thread.jsonl"), "live-must-remain\n").unwrap();
    rewrite_backup_manifest(&backup, |manifest| {
        let members = manifest["members"].as_array_mut().unwrap();
        let mut duplicate = members
            .iter()
            .find(|member| member["relative_path"] == "sessions/thread.jsonl")
            .unwrap()
            .clone();
        duplicate["relative_path"] = "sessions/THREAD.jsonl".into();
        duplicate["backup_path"] = "session-jsonl/sessions/THREAD.jsonl".into();
        members.push(duplicate);
    });

    let error = backups::restore_provider_backup_files_at(&home, &backup).unwrap_err();

    assert!(error.contains("大小写逻辑重复"), "{error}");
    assert_eq!(
        fs::read_to_string(home.join("sessions/thread.jsonl")).unwrap(),
        "live-must-remain\n"
    );
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn startup_reconciliation_handles_each_durable_restore_phase() {
    use crate::commands::startup::initialize_provider_recovery_at;
    use backups::RestoreCrashPoint::{Committed, MidApply, Prepared, Verified};

    for (label, crash_point, expected_after_reconcile) in [
        ("prepared", Prepared, "live-config"),
        ("mid-apply", MidApply, "live-config"),
        ("verified", Verified, "live-config"),
        ("committed", Committed, "backup-config"),
    ] {
        let fixture = temp_root(&format!("provider-restart-{label}"));
        let home = fixture.join("home");
        let backup_root = fixture.join("backups");
        fs::create_dir_all(&home).unwrap();
        write_test_auth_subject(&home, "startup-account");
        fs::write(home.join("config.toml"), "backup-config").unwrap();
        let backup =
            backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
        fs::write(home.join("config.toml"), "live-config").unwrap();

        let recovery_path =
            backups::simulate_restore_crash_at(&home, &backup, crash_point).unwrap();
        assert!(recovery_path.join("recovery-manifest.json").is_file());
        if crash_point == Committed {
            fs::write(
                recovery_path.join("live/config.toml"),
                "corrupt-but-committed",
            )
            .unwrap();
        }

        let recovery_state = ProviderRecoveryState::default();
        let status = initialize_provider_recovery_at(
            &recovery_state,
            &home,
            &backup_root,
            || Ok(false),
        );

        assert!(!status.blocked, "{label}: {status:?}");
        assert!(!recovery_state.snapshot().blocked, "{label}");
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            expected_after_reconcile,
            "{label}"
        );
        assert_no_recovery_staging(&backup_root);

        let second = initialize_provider_recovery_at(
            &recovery_state,
            &home,
            &backup_root,
            || Ok(false),
        );
        assert!(!second.blocked, "second startup {label}: {second:?}");
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            expected_after_reconcile,
            "idempotent {label}"
        );
        fs::remove_dir_all(fixture).unwrap();
    }
}

#[test]
fn failed_startup_reconciliation_retains_and_names_exact_recovery_path() {
    let fixture = temp_root("provider-restart-reconcile-failure");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "reconcile-failure-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    let recovery_path =
        backups::simulate_restore_crash_at(&home, &backup, backups::RestoreCrashPoint::MidApply)
            .unwrap();
    fs::write(recovery_path.join("live/config.toml"), "corrupt-recovery").unwrap();

    let error =
        backups::reconcile_unfinished_restore_transactions_at(&backup_root, &home).unwrap_err();

    assert!(
        error.contains(&recovery_path.display().to_string()),
        "{error}"
    );
    assert!(recovery_path.exists());
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn startup_running_or_probe_failure_blocks_without_writing() {
    use crate::commands::startup::initialize_provider_recovery_at;

    for (label, probe_fails, expected_code) in [
        ("running", false, "codexRunning"),
        ("probe-failure", true, "runningProbeFailed"),
    ] {
        let fixture = temp_root(&format!("provider-restart-{label}"));
        let home = fixture.join("home");
        let backup_root = fixture.join("backups");
        fs::create_dir_all(&home).unwrap();
        write_test_auth_subject(&home, "blocked-startup-account");
        fs::write(home.join("config.toml"), "backup-config").unwrap();
        let backup =
            backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
        fs::write(home.join("config.toml"), "live-config").unwrap();
        let recovery_path = backups::simulate_restore_crash_at(
            &home,
            &backup,
            backups::RestoreCrashPoint::Prepared,
        )
        .unwrap();
        let home_before = fs::read(home.join("config.toml")).unwrap();
        let journal_before = fs::read(recovery_path.join("recovery-manifest.json")).unwrap();
        let recovery_state = ProviderRecoveryState::default();

        let status = initialize_provider_recovery_at(
            &recovery_state,
            &home,
            &backup_root,
            || {
                if probe_fails {
                    Err("probe unavailable".into())
                } else {
                    Ok(true)
                }
            },
        );

        assert!(status.blocked, "{label}: {status:?}");
        assert_eq!(status.code.as_deref(), Some(expected_code), "{label}");
        assert_eq!(status.recovery_path.as_deref(), Some(recovery_path.as_path()));
        assert!(matches!(
            recovery_state.guard_destructive_action(),
            Err(ProviderOperationError::RecoveryBlocked { .. })
        ));
        assert_eq!(fs::read(home.join("config.toml")).unwrap(), home_before);
        assert_eq!(
            fs::read(recovery_path.join("recovery-manifest.json")).unwrap(),
            journal_before
        );
        fs::remove_dir_all(fixture).unwrap();
    }
}

#[test]
fn startup_same_path_new_home_generation_is_blocked_without_compensation() {
    use crate::commands::startup::initialize_provider_recovery_at;

    let fixture = temp_root("provider-restart-new-generation");
    let home = fixture.join("home");
    let old_home = fixture.join("old-home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "generation-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    let recovery_path =
        backups::simulate_restore_crash_at(&home, &backup, backups::RestoreCrashPoint::Prepared)
            .unwrap();
    fs::rename(&home, &old_home).unwrap();
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "generation-account");
    fs::write(home.join("config.toml"), "new-generation-sentinel").unwrap();
    let recovery_state = ProviderRecoveryState::default();

    let status = initialize_provider_recovery_at(
        &recovery_state,
        &home,
        &backup_root,
        || Ok(false),
    );

    assert!(status.blocked, "{status:?}");
    assert_eq!(status.code.as_deref(), Some("homeGenerationMismatch"));
    assert_eq!(status.recovery_path.as_deref(), Some(recovery_path.as_path()));
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "new-generation-sentinel"
    );
    assert!(recovery_path.exists());
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn startup_same_home_different_account_or_unknown_account_is_blocked() {
    use crate::commands::startup::initialize_provider_recovery_at;

    for (label, replacement_subject, expected_code) in [
        ("different", Some("account-b"), "accountIdentityMismatch"),
        ("unknown", None, "accountIdentityUnknown"),
    ] {
        let fixture = temp_root(&format!("provider-restart-account-{label}"));
        let home = fixture.join("home");
        let backup_root = fixture.join("backups");
        fs::create_dir_all(&home).unwrap();
        write_test_auth_subject(&home, "account-a");
        fs::write(home.join("config.toml"), "backup-config").unwrap();
        let backup =
            backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
        fs::write(home.join("config.toml"), "live-config").unwrap();
        let recovery_path = backups::simulate_restore_crash_at(
            &home,
            &backup,
            backups::RestoreCrashPoint::Prepared,
        )
        .unwrap();
        match replacement_subject {
            Some(subject) => write_test_auth_subject(&home, subject),
            None => fs::remove_file(home.join("auth.json")).unwrap(),
        }
        let recovery_state = ProviderRecoveryState::default();

        let status = initialize_provider_recovery_at(
            &recovery_state,
            &home,
            &backup_root,
            || Ok(false),
        );

        assert!(status.blocked, "{label}: {status:?}");
        assert_eq!(status.code.as_deref(), Some(expected_code), "{label}");
        assert_eq!(status.recovery_path.as_deref(), Some(recovery_path.as_path()));
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            "live-config"
        );
        assert!(recovery_path.exists());
        fs::remove_dir_all(fixture).unwrap();
    }
}

#[test]
fn startup_wrong_source_backup_id_or_path_is_blocked() {
    use crate::commands::startup::initialize_provider_recovery_at;

    for field in ["source_backup_id", "source_backup_path"] {
        let fixture = temp_root(&format!("provider-restart-wrong-{field}"));
        let home = fixture.join("home");
        let backup_root = fixture.join("backups");
        fs::create_dir_all(&home).unwrap();
        write_test_auth_subject(&home, "source-account");
        fs::write(home.join("config.toml"), "backup-config").unwrap();
        let backup =
            backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
        fs::write(home.join("config.toml"), "live-config").unwrap();
        let recovery_path = backups::simulate_restore_crash_at(
            &home,
            &backup,
            backups::RestoreCrashPoint::Prepared,
        )
        .unwrap();
        rewrite_recovery_journal(&recovery_path, |journal| {
            journal[field] = match field {
                "source_backup_id" => "wrong-backup-id".into(),
                "source_backup_path" => backup_root.join("wrong-backup-path").display().to_string().into(),
                _ => unreachable!(),
            };
        });
        let recovery_state = ProviderRecoveryState::default();

        let status = initialize_provider_recovery_at(
            &recovery_state,
            &home,
            &backup_root,
            || Ok(false),
        );

        assert!(status.blocked, "{field}: {status:?}");
        assert_eq!(status.code.as_deref(), Some("sourceBackupMismatch"));
        assert_eq!(status.recovery_path.as_deref(), Some(recovery_path.as_path()));
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            "live-config"
        );
        assert!(recovery_path.exists());
        fs::remove_dir_all(fixture).unwrap();
    }
}

#[test]
fn restore_durability_events_precede_apply_and_follow_destination_and_cleanup_changes() {
    let fixture = temp_root("provider-restore-durability-order");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    let mut events = Vec::<(backups::RestorePhase, PathBuf)>::new();

    backups::restore_provider_backup_files_at_with_hook(&home, &backup, |phase, _, path| {
        events.push((phase, path.to_path_buf()));
        Ok(())
    })
    .unwrap();

    let position = |phase, path: Option<&Path>| {
        events
            .iter()
            .position(|(candidate, candidate_path)| {
                *candidate == phase && path.is_none_or(|path| candidate_path == path)
            })
            .unwrap_or_else(|| panic!("missing {phase:?} for {path:?}: {events:?}"))
    };
    let publish = position(backups::RestorePhase::PublishRecoveryManifest, None);
    let prepared = position(backups::RestorePhase::JournalPrepared, None);
    let recovery_root = position(backups::RestorePhase::SyncRecoveryRoot, None);
    let applying = position(backups::RestorePhase::JournalApplying, None);
    let apply = position(backups::RestorePhase::Apply, Some(Path::new("config.toml")));
    let file_sync = position(
        backups::RestorePhase::SyncDestinationFile,
        Some(Path::new("config.toml")),
    );
    let parent_sync = position(
        backups::RestorePhase::SyncDestinationParent,
        Some(Path::new("config.toml")),
    );
    let verify = position(backups::RestorePhase::Verify, None);
    let verified = position(backups::RestorePhase::JournalVerified, None);
    let committed = position(backups::RestorePhase::JournalCommitted, None);
    let cleanup = position(backups::RestorePhase::Cleanup, None);
    let cleanup_root = position(backups::RestorePhase::SyncCleanupRoot, None);

    assert!(publish < prepared && prepared < recovery_root && recovery_root < applying);
    assert!(applying < apply && apply < file_sync && file_sync < parent_sync);
    assert!(parent_sync < verify && verify < verified && verified < committed);
    assert!(committed < cleanup && cleanup < cleanup_root);
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(unix)]
#[test]
fn restore_component_swap_cannot_replace_a_file_outside_the_pinned_home() {
    use std::os::unix::fs::symlink;

    let fixture = temp_root("provider-restore-component-swap");
    let home = fixture.join("home");
    let held_home = fixture.join("held-home");
    let outside = fixture.join("outside");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(&home).unwrap();
    write_test_auth_subject(&home, "fixture-account");
    fs::create_dir_all(&outside).unwrap();
    fs::write(home.join("config.toml"), "backup-config").unwrap();
    fs::write(outside.join("config.toml"), "outside-sentinel").unwrap();
    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    fs::write(home.join("config.toml"), "live-config").unwrap();
    let mut swapped = false;

    backups::restore_provider_backup_files_at_with_hook(&home, &backup, |phase, _, relative| {
        if phase == backups::RestorePhase::BeforeReplace
            && relative == Path::new("config.toml")
            && !swapped
        {
            let temp = fs::read_dir(&home)
                .unwrap()
                .flatten()
                .map(|entry| entry.path())
                .find(|path| {
                    path.file_name().is_some_and(|name| {
                        name.to_string_lossy().contains(".config.toml.restore-")
                    })
                })
                .expect("restore temp must exist before replacement");
            fs::copy(&temp, outside.join(temp.file_name().unwrap())).unwrap();
            fs::rename(&home, &held_home).unwrap();
            symlink(&outside, &home).unwrap();
            swapped = true;
        }
        Ok(())
    })
    .unwrap();

    assert!(swapped);
    assert_eq!(
        fs::read_to_string(outside.join("config.toml")).unwrap(),
        "outside-sentinel"
    );
    assert_eq!(
        fs::read_to_string(held_home.join("config.toml")).unwrap(),
        "backup-config"
    );
    fs::remove_file(&home).unwrap();
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(unix)]
#[test]
fn session_rewrite_component_swap_cannot_replace_a_file_outside_the_pinned_home() {
    use std::os::unix::fs::symlink;

    let fixture = temp_root("provider-session-component-swap");
    let home = fixture.join("home");
    let sessions = home.join("sessions");
    let held_sessions = fixture.join("held-sessions");
    let outside = fixture.join("outside");
    let session = sessions.join("thread.jsonl");
    fs::create_dir_all(&sessions).unwrap();
    fs::create_dir_all(&outside).unwrap();
    write_session(&session, "thread", "legacy-provider");
    write_session(&outside.join("thread.jsonl"), "outside", "outside-sentinel");
    let outside_before = fs::read_to_string(outside.join("thread.jsonl")).unwrap();
    let mut swapped = false;

    let changed =
        session_files::rewrite_session_provider_with_hook(&home, &session, "openai", |phase, _| {
            if phase == session_files::SessionRewritePhase::BeforeTempCreate && !swapped {
                fs::rename(&sessions, &held_sessions).unwrap();
                symlink(&outside, &sessions).unwrap();
                swapped = true;
            }
            Ok(())
        })
        .unwrap();

    assert!(changed && swapped);
    assert_eq!(
        fs::read_to_string(outside.join("thread.jsonl")).unwrap(),
        outside_before
    );
    assert!(fs::read_to_string(held_sessions.join("thread.jsonl"))
        .unwrap()
        .contains("openai"));
    fs::remove_file(&sessions).unwrap();
    fs::remove_dir_all(fixture).unwrap();
}

#[test]
fn windows_handle_relative_mutation_is_enabled() {
    assert!(safe_fs::provider_mutation_support_for_platform("windows").is_ok());
    assert!(safe_fs::provider_mutation_support_for_platform("unix").is_ok());
}

#[cfg(windows)]
#[test]
fn windows_disposable_home_backup_sync_rollback_roundtrip() {
    let fixture = temp_root("provider-windows-roundtrip");
    let home = fixture.join("home");
    let backup_root = fixture.join("backups");
    fs::create_dir_all(home.join("sessions")).unwrap();
    fs::write(home.join("config.toml"), "model_provider = \"openai\"\n").unwrap();
    let session = home.join("sessions/thread.jsonl");
    write_session(&session, "thread", "legacy-provider");
    let original_session = fs::read(&session).unwrap();
    create_state_database(&home, &[("thread", "legacy-provider", 0)]);

    let backup = backups::create_provider_backup_files_at(&backup_root, &home, "openai").unwrap();
    let outcome =
        sync_provider_history_transaction_at(&home, &backup_root, scan_provider_repair_result)
            .unwrap();
    assert_eq!(outcome.snapshot.inconsistent_count, 0);
    assert!(fs::read_to_string(&session).unwrap().contains("openai"));

    backups::restore_provider_backup_files_at(&home, &backup).unwrap();
    assert_eq!(fs::read(&session).unwrap(), original_session);
    let connection = Connection::open(home.join("state_5.sqlite")).unwrap();
    let provider: String = connection
        .query_row(
            "SELECT model_provider FROM threads WHERE id = 'thread';",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(provider, "legacy-provider");

    drop(connection);
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(windows)]
#[test]
fn windows_pinned_home_repeatedly_replaces_an_existing_destination() {
    let root = temp_root("provider-windows-existing-destination");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("session.jsonl"), "version-0").unwrap();
    let pinned_home = PinnedHome::open(&root).unwrap();

    for version in 1..=3 {
        let replacement = format!("version-{version}").into_bytes();
        pinned_home
            .install_atomically(
                Path::new("session.jsonl"),
                None,
                None,
                |target| {
                    std::io::Write::write_all(target, &replacement)
                        .map_err(|error| error.to_string())
                },
                |_, _| Ok(()),
            )
            .unwrap();
        assert_eq!(
            fs::read_to_string(root.join("session.jsonl")).unwrap(),
            format!("version-{version}")
        );
    }

    drop(pinned_home);
    fs::remove_dir_all(root).unwrap();
}

#[cfg(windows)]
#[test]
fn windows_root_reparse_swap_fails_closed_and_keeps_outside_untouched() {
    let fixture = temp_root("provider-windows-root-reparse");
    let home = fixture.join("home");
    let held_home = fixture.join("held-home");
    let outside = fixture.join("outside");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(home.join("config.toml"), "home-original").unwrap();
    fs::write(outside.join("config.toml"), "outside-sentinel").unwrap();
    let pinned_home = PinnedHome::open(&home).unwrap();
    let mut swapped = false;

    let error = pinned_home
        .install_atomically(
            Path::new("config.toml"),
            None,
            None,
            |target| {
                std::io::Write::write_all(target, b"replacement").map_err(|error| error.to_string())
            },
            |phase, _| {
                if phase == safe_fs::AtomicInstallPhase::BeforeTempCreate && !swapped {
                    fs::rename(&home, &held_home).unwrap();
                    create_windows_junction(&home, &outside);
                    swapped = true;
                }
                Ok(())
            },
        )
        .unwrap_err();

    assert!(swapped);
    assert!(
        error.contains("Codex Home") || error.contains("重解析"),
        "{error}"
    );
    assert_eq!(
        fs::read_to_string(held_home.join("config.toml")).unwrap(),
        "home-original"
    );
    assert_eq!(
        fs::read_to_string(outside.join("config.toml")).unwrap(),
        "outside-sentinel"
    );
    drop(pinned_home);
    remove_windows_junction(&home);
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(windows)]
#[test]
fn windows_intermediate_directory_replacement_fails_closed() {
    let fixture = temp_root("provider-windows-intermediate-directory");
    let home = fixture.join("home");
    let sessions = home.join("sessions");
    let held_sessions = fixture.join("held-sessions");
    fs::create_dir_all(&sessions).unwrap();
    fs::write(sessions.join("thread.jsonl"), "session-original").unwrap();
    let pinned_home = PinnedHome::open(&home).unwrap();
    let mut swapped = false;

    let error = pinned_home
        .install_atomically(
            Path::new("sessions/thread.jsonl"),
            None,
            None,
            |target| {
                std::io::Write::write_all(target, b"replacement")
                    .map_err(|error| error.to_string())
            },
            |phase, _| {
                if phase == safe_fs::AtomicInstallPhase::BeforeTempCreate && !swapped {
                    fs::rename(&sessions, &held_sessions).unwrap();
                    fs::create_dir_all(&sessions).unwrap();
                    fs::write(sessions.join("thread.jsonl"), "replacement-sentinel").unwrap();
                    swapped = true;
                }
                Ok(())
            },
        )
        .unwrap_err();

    assert!(swapped);
    assert!(error.contains("父目录") || error.contains("身份变化"), "{error}");
    assert_eq!(
        fs::read_to_string(held_sessions.join("thread.jsonl")).unwrap(),
        "session-original"
    );
    assert_eq!(
        fs::read_to_string(sessions.join("thread.jsonl")).unwrap(),
        "replacement-sentinel"
    );
    drop(pinned_home);
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(windows)]
#[test]
fn windows_intermediate_reparse_swap_fails_closed_and_keeps_outside_untouched() {
    let fixture = temp_root("provider-windows-intermediate-reparse");
    let home = fixture.join("home");
    let sessions = home.join("sessions");
    let held_sessions = fixture.join("held-sessions");
    let outside = fixture.join("outside");
    fs::create_dir_all(&sessions).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(sessions.join("thread.jsonl"), "session-original").unwrap();
    fs::write(outside.join("thread.jsonl"), "outside-sentinel").unwrap();
    let pinned_home = PinnedHome::open(&home).unwrap();
    let mut swapped = false;

    let error = pinned_home
        .install_atomically(
            Path::new("sessions/thread.jsonl"),
            None,
            None,
            |target| {
                std::io::Write::write_all(target, b"replacement")
                    .map_err(|error| error.to_string())
            },
            |phase, _| {
                if phase == safe_fs::AtomicInstallPhase::BeforeTempCreate && !swapped {
                    fs::rename(&sessions, &held_sessions).unwrap();
                    create_windows_junction(&sessions, &outside);
                    swapped = true;
                }
                Ok(())
            },
        )
        .unwrap_err();

    assert!(swapped);
    assert!(error.contains("重解析") || error.contains("父目录"), "{error}");
    assert_eq!(
        fs::read_to_string(held_sessions.join("thread.jsonl")).unwrap(),
        "session-original"
    );
    assert_eq!(
        fs::read_to_string(outside.join("thread.jsonl")).unwrap(),
        "outside-sentinel"
    );
    drop(pinned_home);
    remove_windows_junction(&sessions);
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(windows)]
#[test]
fn windows_destination_reparse_swap_fails_closed_and_keeps_target_untouched() {
    let fixture = temp_root("provider-windows-destination-reparse");
    let home = fixture.join("home");
    let outside = fixture.join("outside");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(home.join("config.toml"), "home-original").unwrap();
    fs::write(outside.join("sentinel.txt"), "outside-sentinel").unwrap();
    let pinned_home = PinnedHome::open(&home).unwrap();
    let destination = home.join("config.toml");
    let mut swapped = false;

    let error = pinned_home
        .install_atomically(
            Path::new("config.toml"),
            None,
            None,
            |target| {
                std::io::Write::write_all(target, b"replacement").map_err(|error| error.to_string())
            },
            |phase, _| {
                if phase == safe_fs::AtomicInstallPhase::BeforeReplace && !swapped {
                    fs::remove_file(&destination).unwrap();
                    create_windows_junction(&destination, &outside);
                    swapped = true;
                }
                Ok(())
            },
        )
        .unwrap_err();

    assert!(swapped);
    assert!(
        error.contains("重解析") || error.contains("普通文件"),
        "{error}"
    );
    assert_eq!(
        fs::read_to_string(outside.join("sentinel.txt")).unwrap(),
        "outside-sentinel"
    );
    remove_windows_junction(&destination);
    drop(pinned_home);
    fs::remove_dir_all(fixture).unwrap();
}

#[cfg(windows)]
#[test]
fn windows_pinned_home_rejects_parent_and_absolute_targets() {
    let fixture = temp_root("provider-windows-outside-target");
    let home = fixture.join("home");
    let outside = fixture.join("outside.txt");
    fs::create_dir_all(&home).unwrap();
    fs::write(&outside, "outside-sentinel").unwrap();
    let pinned_home = PinnedHome::open(&home).unwrap();

    for invalid in [PathBuf::from("../outside.txt"), outside.clone()] {
        let error = pinned_home
            .install_atomically(
                &invalid,
                None,
                None,
                |target| {
                    std::io::Write::write_all(target, b"replacement")
                        .map_err(|error| error.to_string())
                },
                |_, _| Ok(()),
            )
            .unwrap_err();
        assert!(
            error.contains("相对路径") || error.contains("无效"),
            "{error}"
        );
    }
    assert_eq!(fs::read_to_string(&outside).unwrap(), "outside-sentinel");

    drop(pinned_home);
    fs::remove_dir_all(fixture).unwrap();
}

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "codex-token-bar-tauri-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn write_test_auth_subject(home: &Path, subject: &str) {
    let payload = URL_SAFE_NO_PAD.encode(format!(r#"{{"sub":"{subject}"}}"#));
    let auth = serde_json::json!({
        "tokens": {
            "id_token": format!("header.{payload}.signature")
        }
    });
    fs::write(home.join("auth.json"), serde_json::to_vec(&auth).unwrap()).unwrap();
}

fn rewrite_recovery_journal(
    recovery_path: &Path,
    mutate: impl FnOnce(&mut serde_json::Value),
) {
    let path = recovery_path.join("recovery-manifest.json");
    let mut journal: serde_json::Value =
        serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    mutate(&mut journal);
    fs::write(path, serde_json::to_vec_pretty(&journal).unwrap()).unwrap();
}

#[cfg(windows)]
fn create_windows_junction(link: &Path, target: &Path) {
    let output = std::process::Command::new("cmd.exe")
        .args(["/D", "/C", "mklink", "/J"])
        .arg(link)
        .arg(target)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "mklink failed: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[cfg(windows)]
fn remove_windows_junction(path: &Path) {
    fs::remove_dir(path).unwrap();
}

fn operation_id(root: &Path, suffix: &str) -> String {
    format!("{}-{suffix}", root.file_name().unwrap().to_string_lossy())
}

fn backup_info_for_home(root: &Path) -> crate::models::ProviderRepairBackupInfo {
    crate::models::ProviderRepairBackupInfo {
        id: "backup".into(),
        created_at: "2026-06-18T00:00:00Z".into(),
        path: "/tmp/backup".into(),
        codex_home: codex_home_identity(root),
        codex_home_fingerprint: codex_home_fingerprint(root),
        target_provider: "openai".into(),
        session_files: 0,
        state_database: true,
        session_index: true,
        restore_status: crate::models::ProviderRepairBackupRestoreStatus::Supported,
        restore_unsupported_reason: None,
    }
}

fn write_session(path: &Path, thread_id: &str, provider: &str) {
    let line = format!(
        r#"{{"type":"session_meta","payload":{{"id":"{thread_id}","model_provider":"{provider}"}}}}"#
    );
    fs::write(path, format!("{line}\n")).unwrap();
}

fn create_state_database(root: &Path, rows: &[(&str, &str, i64)]) {
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                model_provider TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL,
                updated_at_ms INTEGER
            );
            "#,
        )
        .unwrap();
    for (index, (thread_id, provider, archived)) in rows.iter().enumerate() {
        let updated = 1_781_760_000_000_i64 + index as i64;
        connection
            .execute(
                r#"
                INSERT INTO threads (id, model_provider, archived, updated_at, updated_at_ms)
                VALUES (?1, ?2, ?3, ?4 / 1000, ?4);
                "#,
                params![thread_id, provider, archived, updated],
            )
            .unwrap();
    }
    drop(connection);
}

fn sqlite_provider_for_thread(root: &Path, thread_id: &str) -> String {
    let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
    connection
        .query_row(
            "SELECT model_provider FROM threads WHERE id = ?1",
            [thread_id],
            |row| row.get(0),
        )
        .unwrap()
}

fn completed_backup_count(backup_root: &Path) -> usize {
    fs::read_dir(backup_root)
        .unwrap()
        .flatten()
        .filter(|entry| entry.path().join("manifest.json").exists())
        .count()
}

fn rewrite_backup_manifest(
    backup: &crate::models::ProviderRepairBackupInfo,
    mutate: impl FnOnce(&mut serde_json::Value),
) {
    let manifest_path = PathBuf::from(&backup.path).join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    mutate(&mut manifest);
    fs::write(manifest_path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
}

fn assert_no_recovery_staging(backup_root: &Path) {
    assert!(!fs::read_dir(backup_root).unwrap().flatten().any(|entry| {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        name.starts_with(".restore-recovery-") || name.starts_with(".restore-quarantine-")
    }));
}

fn sqlite_text_value(database_path: &Path, query: &str) -> String {
    Connection::open(database_path)
        .unwrap()
        .query_row(query, [], |row| row.get(0))
        .unwrap()
}

fn sqlite_integrity(database_path: &Path) -> String {
    sqlite_text_value(database_path, "PRAGMA integrity_check")
}
