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
        &[("thread-old", "codex_local_access", 0), ("thread-openai", "openai", 0)],
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
    write_session(&root.join("sessions/old.jsonl"), "thread-old", "codex_local_access");
    create_state_database(
        &root,
        &[("thread-old", "codex_local_access", 0), ("thread-new", "openai", 0)],
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
    write_session(&root.join("sessions/openai.jsonl"), "thread-openai", "openai");
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
    let owner_home = root.clone();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();

    let owner = thread::spawn(move || {
        run_provider_mutation(&owner_home, "operation-a", || {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        })
    });

    entered_rx.recv().unwrap();
    let alias = root.join(".");
    let second = run_provider_mutation(&alias, "operation-b", || Ok(()));
    assert!(matches!(
        second,
        Err(ProviderOperationError::Busy {
            active_operation_id,
            ..
        }) if active_operation_id == "operation-a"
    ));
    assert!(read_provider_operation_status(&alias, "operation-a")
        .unwrap()
        .active);
    assert!(!read_provider_operation_status(&alias, "operation-b")
        .unwrap()
        .active);

    release_tx.send(()).unwrap();
    owner.join().unwrap().unwrap();
    assert!(!read_provider_operation_status(&root, "operation-a")
        .unwrap()
        .active);
    run_provider_mutation(&root, "operation-c", || Ok(())).unwrap();

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn provider_operation_lease_releases_after_mutation_error() {
    let root = temp_root("provider-operation-error-release");
    fs::create_dir_all(&root).unwrap();

    let failure = run_provider_mutation::<()>(&root, "operation-error", || {
        Err("fixture mutation failed".into())
    });
    assert!(matches!(
        failure,
        Err(ProviderOperationError::Failed { message }) if message == "fixture mutation failed"
    ));
    assert!(!read_provider_operation_status(&root, "operation-error")
        .unwrap()
        .active);
    run_provider_mutation(&root, "operation-after-error", || Ok(())).unwrap();

    fs::remove_dir_all(root).unwrap();
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
        &[("thread-old", "codex_local_access", 0), ("thread-openai", "openai", 0)],
    );

    let before = scan_provider_repair(&root);
    assert_eq!(before.inconsistent_count, 3);

    let report = scan_provider_repair_result(&root).unwrap();
    for file in find_session_files(&root, true) {
        rewrite_session_provider(&file, &report.target.provider).unwrap();
    }
    let changed_rows = sync_sqlite_provider(&root, &report.target.provider).unwrap();
    let index_changed = repair_session_index(&root).unwrap();

    assert_eq!(changed_rows, 1);
    assert!(index_changed);
    assert!(fs::read_to_string(old_session).unwrap().contains(r#""model_provider":"openai""#));
    assert!(fs::read_to_string(root.join("session_index.jsonl"))
        .unwrap()
        .contains("thread-openai"));
    let after = scan_provider_repair(&root);
    assert_eq!(after.inconsistent_count, 0);

    fs::remove_dir_all(root).unwrap();
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
