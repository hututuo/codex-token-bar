//! Synthetic route regression, also executed by the non-cfg(test) native
//! fixture. These minimal schema-14 tables exercise Exact's real covering
//! proof; this is not a substitute for the released-history/parser fixtures.
use super::*;
use std::fs;
#[cfg(not(test))]
use std::io::Write;

fn check(condition: bool, message: &str) -> Result<(), String> {
    if condition { Ok(()) } else { Err(message.to_owned()) }
}

fn read(path: impl AsRef<Path>) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|error| error.to_string())
}

fn seed_exact(path: &Path) -> Result<(), String> {
    Connection::open(path).map_err(|error| error.to_string())?.execute_batch(
        "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) WITHOUT ROWID;
         INSERT INTO metadata VALUES('schema_version','14'),('codex_home_identity','pending-fixture-home'),('event_id_sequence','1');
         CREATE TABLE sources(source_id INTEGER PRIMARY KEY,path TEXT NOT NULL,session_id TEXT NOT NULL,is_explicit_subagent_fork INTEGER NOT NULL);
         INSERT INTO sources VALUES(7,'synthetic-unavailable-rollout.jsonl','pending-fixture-session',0);
         CREATE TABLE event_rows(id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL,ordinal INTEGER NOT NULL,timestamp INTEGER NOT NULL,tokens INTEGER NOT NULL,input_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,accounting_kind INTEGER NOT NULL,model TEXT);
         INSERT INTO event_rows VALUES(1,7,1,1793494800,105,100,90,5,0,0,'synthetic-model');
         CREATE TABLE retained_usage_revisions(revision_id INTEGER PRIMARY KEY,tokens INTEGER NOT NULL);
         INSERT INTO retained_usage_revisions VALUES(1,105);"
    ).map_err(|error| error.to_string())
}

fn pending_value(container: &Container, store: &StoreSpec) -> Result<String, String> {
    container.connection().query_row(
        "SELECT value FROM tb_container_meta WHERE key=?1",
        [format!("migration_pending_store_v1:{}", store.id)], |row| row.get(0),
    ).map_err(|error| error.to_string())
}

struct Frozen {
    store: StoreSpec,
    source: PathBuf,
    backup: PathBuf,
    digest: String,
    proof: StoreProof,
    journal: String,
    backup_bytes: Vec<u8>,
}

fn prepare_pending(path: &Path, source: &Path, store: StoreSpec) -> Result<Frozen, String> {
    let result = open_store_at_with_hook(path, &store.module, &store.source_identity,
        &store.logical_path, std::slice::from_ref(&source.to_path_buf()), false,
        &|| Err("synthetic interruption after namespace import".into()));
    check(result.err().is_some_and(|error| error.contains("synthetic interruption")),
        "pending fixture did not interrupt after a real namespace import")?;
    let container = Container::open_existing(path).map_err(|error| error.to_string())?;
    let receipt = container.legacy_input_receipt(source).map_err(|error| error.to_string())?
        .ok_or("pending fixture source receipt missing")?;
    Ok(Frozen {
        proof: container.proof(&store).map_err(|error| error.to_string())?,
        journal: pending_value(&container, &store)?,
        source: source.to_path_buf(),
        backup_bytes: read(&receipt.backup_path)?,
        backup: PathBuf::from(receipt.backup_path),
        digest: receipt.source_digest,
        store,
    })
}

fn assert_frozen(path: &Path, frozen: &Frozen, source_bytes: &[u8], backup_bytes: &[u8]) -> Result<(), String> {
    let container = Container::open_read_only_existing(path, std::time::Duration::from_secs(30))
        .map_err(|error| error.to_string())?;
    let receipt = container.legacy_input_receipt(&frozen.source).map_err(|error| error.to_string())?
        .ok_or("frozen pending receipt disappeared")?;
    check(container.proof(&frozen.store).map_err(|error| error.to_string())? == frozen.proof
            && pending_value(&container, &frozen.store)? == frozen.journal
            && receipt.source_digest == frozen.digest && Path::new(&receipt.backup_path) == frozen.backup,
        "incomplete Exact discovery changed its namespace, receipt or pending journal")?;
    check(read(&frozen.source)? == source_bytes && read(&frozen.backup)? == backup_bytes,
        "incomplete Exact discovery changed a source or repaired/quarantined its frozen backup")
}

#[cfg(not(test))]
fn quota_rows(path: &Path, store: &StoreSpec) -> Result<i64, String> {
    Container::open_read_only_existing(path, std::time::Duration::from_secs(30))
        .map_err(|error| error.to_string())?.into_store_connection(store)
        .map_err(|error| error.to_string())?.query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .map_err(|error| error.to_string())
}

fn quarantine_files(backup: &Path) -> Result<Vec<PathBuf>, String> {
    let mut paths = fs::read_dir(backup.parent().ok_or("fixture backup parent missing")?)
        .map_err(|error| error.to_string())?.map(|entry| entry.map_err(|error| error.to_string()))
        .collect::<Result<Vec<_>, _>>()?.into_iter()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with(".tokenbar-backup-quarantine-"))
        .map(|entry| entry.path()).collect::<Vec<_>>();
    paths.sort();
    Ok(paths)
}

#[cfg(not(test))]
pub(crate) fn verify(root: &Path) -> Result<serde_json::Value, String> {
    let path = container_path()?;
    check(!initialized_marker_path(&path).exists(), "pending fixture requires an unactivated A")?;
    // The entry point already validated all app overrides and the isolation
    // root. Refuse an existing case directory rather than touching its data.
    fs::create_dir(root).map_err(|error| error.to_string())?;
    let append_source = root.join("retired-layout-appended.sqlite3");
    let backup_source = root.join("retired-layout-frozen.sqlite3");
    seed_exact(&append_source)?;
    seed_exact(&backup_source)?;
    let appended = prepare_pending(&path, &append_source, exact_store_spec(&append_source)?)?;
    let damaged = prepare_pending(&path, &backup_source, exact_store_spec(&backup_source)?)?;
    Connection::open(&append_source).map_err(|error| error.to_string())?.execute_batch(
        "INSERT INTO event_rows VALUES(2,7,2,1793494860,120,110,80,10,3,0,'synthetic-model');
         UPDATE metadata SET value='2' WHERE key='event_id_sequence';"
    ).map_err(|error| error.to_string())?;
    let appended_bytes = read(&append_source)?;
    let identical_bytes = read(&backup_source)?;
    let corrupt_backup = b"synthetic interrupted backup bytes";
    fs::write(&damaged.backup, corrupt_backup).map_err(|error| error.to_string())?;
    let quarantines_before = quarantine_files(&damaged.backup)?;

    let quota_source = root.join("retired-layout-quota.sqlite");
    Connection::open(&quota_source).map_err(|error| error.to_string())?.execute_batch(
        "CREATE TABLE events(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO events VALUES(1,'old');"
    ).map_err(|error| error.to_string())?;
    let quota = prepare_pending(&path, &quota_source,
        StoreSpec::new("quota_history", "pending-fixture-quota", "quota/pending-fixture")
            .map_err(|error| error.to_string())?)?;
    Connection::open(&quota_source).map_err(|error| error.to_string())?.execute(
        "INSERT INTO events VALUES(2,'late committed quota history')", [],
    ).map_err(|error| error.to_string())?;
    let quota_bytes = read(&quota_source)?;

    let exact_root = app_paths::usage_history_dir().ok_or("Exact fixture root unavailable")?;
    fs::create_dir_all(&exact_root).map_err(|error| error.to_string())?;
    let manifest = exact_root.join("pending-fixture-bad.sqlite3.schema11-migration.json");
    let bad_manifest = b"synthetic malformed migration manifest";
    fs::OpenOptions::new().write(true).create_new(true).open(&manifest)
        .and_then(|mut file| file.write_all(bad_manifest)).map_err(|error| error.to_string())?;
    // Both retries must fail on the same complete-discovery boundary while
    // independently recovering the non-Exact journal. The source append and
    // corrupt-backup cases catch mutations in resume AND final verification.
    for _ in 0..2 {
        let error = bootstrap().err().ok_or("bad Exact manifest did not block activation")?;
        check(error.contains("pending-fixture-bad.sqlite3.schema11-migration.json"),
            "bootstrap did not retain the discovery failure in its complete diagnosis")?;
        check(!initialized_marker_path(&path).exists(), "failed Exact discovery activated A")?;
        assert_frozen(&path, &appended, &appended_bytes, &appended.backup_bytes)?;
        assert_frozen(&path, &damaged, &identical_bytes, corrupt_backup)?;
        check(quarantine_files(&damaged.backup)? == quarantines_before,
            "read-only Exact verification quarantined a backup")?;
        check(quota_rows(&path, &quota.store)? == 2,
            "Exact failure prevented independent pending quota history from recovering")?;
        check(read(&manifest)? == bad_manifest && read(&quota_source)? == quota_bytes,
            "failed preparation modified a legacy source or manifest")?;
    }
    // Remove only the deliberately created malformed fixture manifest. The
    // real application never deletes a user's failed discovery evidence.
    fs::remove_file(&manifest).map_err(|error| error.to_string())?;
    bootstrap()?;
    check(initialized_marker_path(&path).is_file(), "complete recovery did not activate A")?;
    let container = Container::open_existing(&path).map_err(|error| error.to_string())?;
    let recovered_proof = container.proof(&appended.store).map_err(|error| error.to_string())?;
    let rows = container.into_store_connection(&appended.store).map_err(|error| error.to_string())?;
    let facts: (i64, i64, i64) = rows.query_row(
        "SELECT COUNT(*),SUM(tokens),(SELECT SUM(tokens) FROM retained_usage_revisions) FROM event_rows",
        [], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    ).map_err(|error| error.to_string())?;
    check(facts == (2, 225, 105), "complete Exact discovery did not recover both original and appended history")?;
    drop(rows);
    check(Container::snapshot_digest_path(&damaged.backup).map_err(|error| error.to_string())? == damaged.digest,
        "complete discovery did not repair the backup from its identical live source")?;
    check(quarantine_files(&damaged.backup)?.iter().any(|file| read(file).ok().as_deref() == Some(corrupt_backup)),
        "backup repair did not preserve the corrupt bytes in quarantine")?;
    for _ in 0..2 {
        bootstrap()?;
        let container = Container::open_existing(&path).map_err(|error| error.to_string())?;
        check(container.proof(&appended.store).map_err(|error| error.to_string())? == recovered_proof
                && container.proof(&damaged.store).map_err(|error| error.to_string())? == damaged.proof,
            "repeated successful bootstrap changed recovered Exact history")?;
    }
    check(read(&append_source)? == appended_bytes && read(&backup_source)? == identical_bytes
            && read(&quota_source)? == quota_bytes && read(&appended.backup)? == appended.backup_bytes,
        "recovery changed a legacy source or its original frozen history")?;
    Ok(serde_json::json!({
        "name":"bootstrap","status":"PASS",
        "incompleteExactDiscoveryFrozen":true,
        "incompleteExactSnapshotUnchanged":true,
        "independentPendingImportRecovered":true,
        "completeDiscoveryResumesExactHistory":true,
        "recoveryRetryPreservesHistory":true,
        "pendingRecoveryScope":"Synthetic schema-14 numeric history through real pending import, coverage and bootstrap routes"
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inspect_only_exact_pending_checks_preserve_v1_and_v2_sources_and_backups() {
        // cfg(test) intentionally skips bootstrap's physical Exact discovery.
        // This test exercises the recovery policies directly; verify() above
        // is separately required in the native fixture to prove real manifest
        // discovery supplies that policy to the complete bootstrap chain.
        for version in [1, 2] {
            let fixture = tempfile::tempdir().unwrap();
            let path = fixture.path().join("codex-ledger.sqlite");
            let append_source = fixture.path().join("appended.sqlite3");
            let backup_source = fixture.path().join("frozen.sqlite3");
            seed_exact(&append_source).unwrap();
            seed_exact(&backup_source).unwrap();
            let mut appended = prepare_pending(&path, &append_source,
                StoreSpec::new("exact", "appended", "exact/appended").unwrap()).unwrap();
            let mut damaged = prepare_pending(&path, &backup_source,
                StoreSpec::new("exact", "damaged", "exact/damaged").unwrap()).unwrap();
            if version == 1 {
                let container = Container::open_existing(&path).unwrap();
                for frozen in [&mut appended, &mut damaged] {
                    frozen.journal = serde_json::json!({"sources":[frozen.source],"bootstrap":true,"replace_uncommitted":true}).to_string();
                    container.connection().execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2",
                        rusqlite::params![frozen.journal,format!("migration_pending_store_v1:{}", frozen.store.id)]).unwrap();
                }
            }
            Connection::open(&append_source).unwrap().execute_batch(
                "INSERT INTO event_rows VALUES(2,7,2,1793494860,120,110,80,10,3,0,'synthetic-model');
                 UPDATE metadata SET value='2' WHERE key='event_id_sequence';"
            ).unwrap();
            let appended_bytes = read(&append_source).unwrap();
            let identical_bytes = read(&backup_source).unwrap();
            let corrupt = b"incomplete frozen backup";
            fs::write(&damaged.backup, corrupt).unwrap();
            let before = quarantine_files(&damaged.backup).unwrap();
            for _ in 0..2 {
                let error = resume_pending_bootstrap_imports(&path, PendingRecovery::InspectOnly).unwrap_err();
                assert!(error.contains(damaged.backup.to_str().unwrap()), "v{version}: {error}");
                let container = Container::open_read_only_existing(&path, std::time::Duration::from_secs(30)).unwrap();
                let error = verify_bootstrap_pending_inputs(&container, PendingRecovery::InspectOnly).unwrap_err();
                assert!(error.contains(damaged.backup.to_str().unwrap())
                    && error.contains(append_source.to_str().unwrap()), "v{version}: {error}");
                assert_frozen(&path, &appended, &appended_bytes, &appended.backup_bytes).unwrap();
                assert_frozen(&path, &damaged, &identical_bytes, corrupt).unwrap();
                assert_eq!(quarantine_files(&damaged.backup).unwrap(), before);
            }
            resume_pending_bootstrap_imports(&path, PendingRecovery::Resume).unwrap();
            let container = Container::open_existing(&path).unwrap();
            verify_bootstrap_pending_inputs(&container, PendingRecovery::Resume).unwrap();
            let rows = container.into_store_connection(&appended.store).unwrap();
            assert_eq!(rows.query_row("SELECT SUM(tokens) FROM event_rows", [], |row| row.get::<_,i64>(0)).unwrap(), 225);
            assert_eq!(Container::snapshot_digest_path(&damaged.backup).unwrap(), damaged.digest);
            assert!(!initialized_marker_path(&path).exists(), "module recovery cannot activate A");
        }
    }

    #[test]
    fn inconsistent_pending_ownership_cannot_enable_backup_repair_in_inspect_only_mode() {
        for corrupt_catalog in [false, true] {
            let fixture = tempfile::tempdir().unwrap();
            let path = fixture.path().join("codex-ledger.sqlite");
            let source = fixture.path().join("legacy-exact.sqlite3");
            seed_exact(&source).unwrap();
            let store = StoreSpec::new("exact", "pending-owner", "exact/pending-owner").unwrap();
            let frozen = prepare_pending(&path, &source, store).unwrap();
            let wrong_store = StoreSpec::new("quota_history", &frozen.store.source_identity,
                &frozen.store.logical_path).unwrap();
            let wrong_backup = backup_path(&path, &wrong_store, &source, &frozen.digest);
            let corrupt_bytes = b"must not repair a mismatched owner's backup";
            fs::write(&wrong_backup, corrupt_bytes).unwrap();
            let before = quarantine_files(&wrong_backup).unwrap();
            let container = Container::open_existing(&path).unwrap();
            let mut journal: PendingLegacyImport = serde_json::from_str(&frozen.journal).unwrap();
            journal.snapshots[0].backup = wrong_backup.clone();
            container.connection().execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2",
                rusqlite::params![serde_json::to_string(&journal).unwrap(),
                    format!("migration_pending_store_v1:{}", frozen.store.id)]).unwrap();
            container.connection().execute("UPDATE tb_legacy_inputs SET module=?1,backup_path=?2 WHERE source_path=?3",
                rusqlite::params![wrong_store.module, wrong_backup.to_string_lossy(), source.to_string_lossy()]).unwrap();
            if corrupt_catalog {
                container.connection().execute("UPDATE tb_stores SET module=?1 WHERE store_id=?2",
                    rusqlite::params![wrong_store.module, frozen.store.id]).unwrap();
            }
            drop(container);
            let before_container = Container::snapshot_digest_path(&path).unwrap();
            assert!(resume_pending_bootstrap_imports(&path, PendingRecovery::InspectOnly).is_err());
            let container = Container::open_read_only_existing(&path, std::time::Duration::from_secs(30)).unwrap();
            assert!(verify_bootstrap_pending_inputs(&container, PendingRecovery::InspectOnly).is_err());
            // Include the intentionally inconsistent catalog/receipt in this
            // proof instead of repairing it just to open the namespace.
            assert_eq!(Container::snapshot_digest_path(&path).unwrap(), before_container);
            assert_eq!(read(&wrong_backup).unwrap(), corrupt_bytes);
            assert_eq!(quarantine_files(&wrong_backup).unwrap(), before);
            assert_eq!(read(&frozen.backup).unwrap(), frozen.backup_bytes);
        }
    }
}
