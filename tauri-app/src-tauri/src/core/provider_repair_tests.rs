use super::*;
use rusqlite::{params, Connection};
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

    let discovery = discover_provider_operation_ownership();
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
    let after_first_drop = discover_provider_operation_ownership();
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
    assert!(!discover_provider_operation_ownership()
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
    let snapshot =
        Connection::open(PathBuf::from(&backup.path).join("state_5.sqlite.before")).unwrap();
    let value: String = snapshot
        .query_row("SELECT value FROM committed_rows WHERE id = 1", [], |row| {
            row.get(0)
        })
        .unwrap();
    let integrity: String = snapshot
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .unwrap();

    assert_eq!(value, "committed-in-wal");
    assert_eq!(integrity, "ok");
    drop(snapshot);
    drop(writer);
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
