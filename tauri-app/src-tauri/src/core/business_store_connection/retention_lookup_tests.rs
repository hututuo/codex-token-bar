use super::*;
use crate::core::{app_paths, business_store_route as route};
use rusqlite::params;
use std::fs;

fn setup(root: &Path) -> (std::path::PathBuf, StoreSpec, StoreConnection, Connection) {
    let index = root.join("logical.sqlite3");
    let owner = route::exact_store_spec(&index).unwrap();
    let path = route::container_path().unwrap();
    let container = Container::open(&path).unwrap();
    container.register(&owner).unwrap();
    fs::write(path.with_file_name("codex-ledger.sqlite.initialized"), b"tokenbar-codex-ledger-v1\n").unwrap();
    let writer = Connection::open(&path).unwrap();
    (index, owner.clone(), container.into_store_connection(&owner).unwrap(), writer)
}

#[test]
fn held_retention_lookup_observes_new_receipts_and_rejects_changed_root_and_owner() {
    let root = tempfile::tempdir().unwrap();
    let _guard = app_paths::app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",root.path().to_owned())]);
    let (index, owner, bound, writer) = setup(root.path());
    let key = format!("legacy_exact_migration_v1:{}",owner.id);
    let before = bound.raw.total_changes();
    assert!(!bound.preserves_legacy_exact_migration(&index).unwrap());
    let receipt = serde_json::json!({"version":1,"logicalPath":owner.logical_path}).to_string();
    writer.execute("INSERT INTO tb_container_meta VALUES(?1,?2)",params![key,receipt]).unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).unwrap());
    for invalid in ["{", "{\"version\":999}", "{\"version\":1,\"logicalPath\":\"another\"}"] {
        writer.execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2",params![invalid,key]).unwrap();
        assert!(bound.preserves_legacy_exact_migration(&index).is_err());
        assert!(bound.raw.is_autocommit());
        assert_eq!(writer.query_row("SELECT value FROM tb_container_meta WHERE key=?1",[&key],|r|r.get::<_,String>(0)).unwrap(),invalid);
    }
    writer.execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2",params![receipt,key]).unwrap();
    writer.execute_batch("PRAGMA user_version=999").unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).is_err());
    writer.execute_batch("PRAGMA user_version=1; UPDATE tb_container_meta SET value='999' WHERE key='schema_version'").unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).is_err());
    writer.execute_batch("UPDATE tb_container_meta SET value='1' WHERE key='schema_version'").unwrap();
    assert!(bound.preserves_legacy_exact_migration(&root.path().join("other.sqlite3")).is_err());
    writer.execute("UPDATE tb_stores SET source_identity='changed' WHERE store_id=?1",[&owner.id]).unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).is_err());
    writer.execute("UPDATE tb_stores SET source_identity=?1 WHERE store_id=?2",params![owner.source_identity,owner.id]).unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).unwrap());
    fs::write(route::container_path().unwrap().with_file_name("codex-ledger.sqlite.initialized"),b"invalid").unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).is_err());
    assert_eq!(bound.raw.total_changes(),before);
}

#[test]
fn held_retention_lookup_keeps_the_callers_snapshot_and_transaction() {
    let root=tempfile::tempdir().unwrap();
    let _guard=app_paths::app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",root.path().to_owned())]);
    let (index,owner,bound,writer)=setup(root.path());
    let key=format!("legacy_exact_migration_v1:{}",owner.id);
    writer.execute("INSERT INTO tb_container_meta VALUES(?1,?2)",params![key,serde_json::json!({"version":1,"logicalPath":owner.logical_path}).to_string()]).unwrap();
    bound.raw.execute_batch("BEGIN DEFERRED").unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).unwrap());
    writer.execute("UPDATE tb_container_meta SET value='invalid' WHERE key=?1",[&key]).unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).unwrap());
    assert!(!bound.raw.is_autocommit());
    bound.raw.execute_batch("ROLLBACK").unwrap();
    assert!(bound.preserves_legacy_exact_migration(&index).is_err());
    writer.execute("DELETE FROM tb_container_meta WHERE key=?1",[&key]).unwrap();
    bound.raw.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert!(!bound.preserves_legacy_exact_migration(&index).unwrap());
    assert!(!bound.raw.is_autocommit());
    bound.raw.execute_batch("ROLLBACK").unwrap();
}
