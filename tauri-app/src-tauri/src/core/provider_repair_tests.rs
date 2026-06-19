use super::*;
use rusqlite::{params, Connection};
use std::fs;
use std::path::PathBuf;
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
}
