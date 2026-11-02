//! Preserve a complete artifact when only the requested scan contract changes.
use super::*;

pub(super) fn candidate_path(index: &Path, job: &FullRebuildJob, generation: i64) -> PathBuf {
    let contract = serde_json::json!({
        "path": job.path, "session": job.session_id, "source": job.source_id,
        "base": job.base_generation, "resume": job.base_resume_offset,
        "basePrefix": job.base_prefix_sha256, "target": generation,
        "size": job.signature.size, "modifiedNs": job.signature.modified_ns.to_string(),
        "enrichment": job.event_enrichment, "expectedPrefix": job.expected_published_prefix_sha256,
        "parser": STAGED_FULL_REBUILD_PARSER_REVISION,
        "migration": EVENT_ENRICHMENT_REVISION,
    });
    let digest = Sha256::digest(contract.to_string().as_bytes());
    staging_directory(index).join(format!(
        "{}.candidate-v2-{digest:x}.sqlite3",
        staging_database_digest(&job.path)
    ))
}

/// Validate the artifact against the contract it actually records, including
/// current source bytes, base checkpoint, counts, codec and seal. Success only
/// permits retaining it and building a separate candidate; it never imports or
/// publishes that artifact for the new request.
pub(super) fn valid_for_earlier_request(
    path: &Path,
    requested: &FullRebuildJob,
    generation: i64,
) -> Result<bool, String> {
    let connection = open_read_only_index(path, StdDuration::from_secs(1))?;
    for column in [
        "manifest_schema_version",
        "source_id",
        "base_generation",
        "base_resume_offset",
        "base_prefix_sha256",
        "migration_revision",
        "prefix_sha256",
        "target_building_generation",
    ] {
        if !column_exists_checked(&connection, "manifest", column)? {
            return Ok(false);
        }
    }
    let stored = connection.query_row(
        "SELECT manifest_schema_version,source_id,base_generation,base_resume_offset,base_prefix_sha256,\
         size,modified_ns,target_building_generation,migration_revision,prefix_sha256 \
         FROM manifest WHERE complete=1",
        [], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?,
            row.get::<_, Option<i64>>(3)?, row.get::<_, Option<Vec<u8>>>(4)?, row.get::<_, i64>(5)?,
            row.get::<_, String>(6)?, row.get::<_, i64>(7)?, row.get::<_, String>(8)?, row.get::<_, Vec<u8>>(9)?))
    ).optional().map_err(|error| format!("无法读取暂存保留证明：{error}"))?;
    let Some((
        schema,
        source,
        base,
        resume,
        base_prefix,
        size,
        modified,
        target,
        migration,
        prefix,
    )) = stored
    else {
        return Ok(false);
    };
    if schema != STAGING_MANIFEST_SCHEMA_VERSION
        || source != requested.source_id
        || base < 0
        || target <= base
        || target > generation
        || base > requested.base_generation
    {
        return Ok(false);
    }
    let event_enrichment = match migration.as_str() {
        EVENT_ENRICHMENT_REVISION => true,
        "exact-source-rebuild-v1" => false,
        _ => return Ok(false),
    };
    let (Ok(size), Ok(modified_ns), Ok(prefix)) = (
        u64::try_from(size),
        modified.parse::<u128>(),
        <[u8; 32]>::try_from(prefix),
    ) else {
        return Ok(false);
    };
    let resume = match resume.map(u64::try_from).transpose() {
        Ok(value) => value,
        Err(_) => return Ok(false),
    };
    let base_prefix = match base_prefix.map(<[u8; 32]>::try_from).transpose() {
        Ok(value) => value,
        Err(_) => return Ok(false),
    };
    if target > requested.base_generation
        && (base != requested.base_generation
            || resume != requested.base_resume_offset
            || base_prefix != requested.base_prefix_sha256)
    {
        return Ok(false);
    }
    let own_request = FullRebuildJob {
        source_id: source,
        base_generation: base,
        base_resume_offset: resume,
        base_prefix_sha256: base_prefix,
        signature: FileSignature {
            size,
            modified_ns,
            physical: None,
        },
        event_enrichment,
        expected_published_prefix_sha256: event_enrichment.then_some(prefix),
        ..requested.clone()
    };
    Ok(validated_staged_full_rebuild(&connection, path, &own_request, target, None)?.is_some())
}

#[cfg(test)]
thread_local! {
    static AFTER_METADATA_READ_HOOK: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
pub(super) fn run_after_metadata_read_hook() {
    AFTER_METADATA_READ_HOOK.with(|slot| {
        if let Some(hook) = slot.borrow_mut().take() { hook(); }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_state_cache_observes_wal_only_commits_and_invalidates_frozen_reader_cache() {
        let root = std::env::temp_dir().join(format!("tokenbar-wal-source-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let database = root.join("state_5.sqlite");
        let writer = Connection::open(&database).unwrap();
        writer.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,first_user_message TEXT,preview TEXT,updated_at INTEGER,updated_at_ms INTEGER); INSERT INTO threads VALUES('fixture','first',NULL,NULL,100,NULL);").unwrap();
        let mut warnings = Vec::new();
        let ThreadMetadataStage::Updated(first) =
            stage_thread_metadata(&root, (None, None), None, &mut warnings).unwrap()
        else {
            panic!("first state read did not produce metadata: {warnings:?}");
        };
        assert_eq!(first.rows[0].1, "first");
        writer
            .execute("UPDATE threads SET title='second',updated_at=200", [])
            .unwrap();
        let main = file_signature(&database).unwrap();
        assert_eq!(
            first.signature,
            Some((main.size.to_string(), main.modified_ns.to_string()))
        );
        let ThreadMetadataStage::Updated(second) = stage_thread_metadata(
            &root,
            first.signature.clone().unzip(),
            first.source_signature,
            &mut Vec::new(),
        )
        .unwrap() else {
            panic!("a committed WAL change was hidden by the unchanged main-file stat");
        };
        assert_eq!(second.rows[0].1, "second");
        // A WAL can reuse its allocation, so metadata alone must not freeze
        // this live source. Re-reading also must tolerate SQLite's own ctime
        // changes when a read-only connection opens an existing WAL.
        let mut warnings = Vec::new();
        let ThreadMetadataStage::Updated(repeated) = stage_thread_metadata(
            &root, second.signature.clone().unzip(), second.source_signature.clone(), &mut warnings,
        ).unwrap() else { panic!("live WAL repeat was not read: {warnings:?}"); };
        assert_eq!(repeated.rows, second.rows);
        assert!(warnings.is_empty());
        assert!(matches!(
            stage_thread_metadata(
                &root,
                second.signature.clone().unzip(),
                None,
                &mut Vec::new()
            )
            .unwrap(),
            ThreadMetadataStage::Updated(_)
        ));
        let reader = open_read_only_source(&database, StdDuration::from_secs(1)).unwrap();
        assert!(reader
            .execute("UPDATE threads SET updated_at=999", [])
            .is_err());
        drop(reader);

        // Checkpoint without truncating, then reuse the preallocated WAL with
        // its original mtime. A size/mtime-only fast path would miss this commit.
        writer.execute_batch("PRAGMA wal_checkpoint(PASSIVE);").unwrap();
        let ThreadMetadataStage::Updated(checkpointed) = stage_thread_metadata(
            &root, repeated.signature.unzip(), repeated.source_signature, &mut warnings,
        ).unwrap() else { panic!("checkpointed WAL was not read: {warnings:?}"); };
        let wal = sqlite_sidecar_path(&database, "-wal");
        let wal_before = fs::metadata(&wal).unwrap();
        let main_before = fs::read(&database).unwrap();
        writer.execute("UPDATE threads SET title='third',updated_at=300", []).unwrap();
        assert_eq!(fs::metadata(&wal).unwrap().len(), wal_before.len());
        fs::File::options().write(true).open(&wal).unwrap()
            .set_times(fs::FileTimes::new().set_modified(wal_before.modified().unwrap())).unwrap();
        assert_eq!(fs::read(&database).unwrap(), main_before);
        let ThreadMetadataStage::Updated(reused) = stage_thread_metadata(
            &root, checkpointed.signature.unzip(), checkpointed.source_signature, &mut warnings,
        ).unwrap() else { panic!("same-size reused WAL was hidden: {warnings:?}"); };
        assert_eq!(reused.rows[0].1, "third");
        assert!(warnings.is_empty());

        writer.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
        let ThreadMetadataStage::Updated(truncated) = stage_thread_metadata(
            &root, reused.signature.unzip(), reused.source_signature, &mut warnings,
        ).unwrap() else { panic!("truncated WAL was not read: {warnings:?}"); };
        assert_eq!(truncated.rows[0].1, "third");
        assert!(matches!(stage_thread_metadata(
            &root, truncated.signature.clone().unzip(), truncated.source_signature.clone(), &mut warnings,
        ).unwrap(), ThreadMetadataStage::Unchanged));
        drop(writer);
        assert!(!wal.exists());
        assert!(matches!(stage_thread_metadata(
            &root, truncated.signature.unzip(), truncated.source_signature, &mut warnings,
        ).unwrap(), ThreadMetadataStage::Unchanged));
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn live_state_cache_rejects_same_size_same_mtime_main_database_replacement() {
        let root = std::env::temp_dir().join(format!("tokenbar-state-replaced-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let database = root.join("state_5.sqlite");
        let replacement = root.join("replacement.sqlite");
        for (path, title) in [(&database, "before"), (&replacement, "after!")] {
            let db = Connection::open(path).unwrap();
            db.execute_batch("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,updated_at INTEGER);").unwrap();
            db.execute("INSERT INTO threads VALUES('one',?1,100)", [title]).unwrap();
        }
        let mut warnings = Vec::new();
        let ThreadMetadataStage::Updated(first) = stage_thread_metadata(&root, (None,None), None, &mut warnings).unwrap()
        else { panic!("initial standalone metadata failed: {warnings:?}"); };
        let old = fs::metadata(&database).unwrap();
        assert_eq!(fs::metadata(&replacement).unwrap().len(), old.len());
        fs::File::options().write(true).open(&replacement).unwrap()
            .set_times(fs::FileTimes::new().set_modified(old.modified().unwrap())).unwrap();
        fs::rename(&replacement, &database).unwrap();
        let ThreadMetadataStage::Updated(second) = stage_thread_metadata(
            &root, first.signature.unzip(), first.source_signature, &mut warnings,
        ).unwrap() else { panic!("replacement inherited old title cache: {warnings:?}"); };
        assert_eq!(second.rows[0].1, "after!");
        assert!(warnings.is_empty());
        fs::remove_dir_all(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn live_state_read_rejects_main_or_wal_inode_replacement_during_read() {
        for suffix in ["", "-wal"] {
            let root = std::env::temp_dir().join(format!("tokenbar-state-race-{}", Uuid::new_v4()));
            fs::create_dir_all(&root).unwrap();
            let database = root.join("state_5.sqlite");
            let writer = Connection::open(&database).unwrap();
            writer.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,updated_at INTEGER); INSERT INTO threads VALUES('one','title',100);").unwrap();
            let target = sqlite_sidecar_path(&database, suffix);
            let replacement = root.join("replacement");
            fs::copy(&target, &replacement).unwrap();
            let original_modified = fs::metadata(&target).unwrap().modified().unwrap();
            fs::File::options().write(true).open(&replacement).unwrap()
                .set_times(fs::FileTimes::new().set_modified(original_modified)).unwrap();
            AFTER_METADATA_READ_HOOK.with(|slot| *slot.borrow_mut() = Some(Box::new(move || {
                fs::rename(&replacement, &target).unwrap();
            })));
            let mut warnings = Vec::new();
            assert!(matches!(stage_thread_metadata(&root, (None,None), None, &mut warnings).unwrap(),
                ThreadMetadataStage::Failed), "replacement during {suffix:?} read was accepted");
            assert!(warnings.iter().any(|warning| warning.message.contains("读取期间发生变化")));
            drop(writer);
            fs::remove_dir_all(&root).unwrap();
        }
    }
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
fn verify_startup_readers(home: &Path, index_path: &Path) -> Result<(), String> {
    use crate::core::business_store_route as route;
    macro_rules! sql { ($value:expr) => { $value.map_err(|error| error.to_string())? }; }
    macro_rules! need { ($value:expr, $message:expr) => {
        if !$value { return Err($message.into()); }
    }; }
    need!(!index_path.exists(), "startup fixture must exercise a namespace without a physical index");
    peek_startup_identity(home)?
        .ok_or("startup reader lost the A-only published index identity")?;
    let catalog = sql!(rusqlite::Connection::open_with_flags(
        route::container_path()?, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ));
    let store_count = || catalog.query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row.get::<_, i64>(0))
        .map_err(|error| error.to_string());
    let count_before = store_count()?;

    // Exercise the public startup cache owner too. A bucket boundary may
    // legitimately expire its time axis between calls; one fresh owner pass
    // retries that boundary without bypassing any cache-validity predicate.
    let mut restored = false;
    for _ in 0..2 {
        if let Some(snapshot) = super::super::cached_dashboard_snapshot_for_startup(home) {
            need!(snapshot.stats.total_tokens == 120 && !snapshot.precise_recent_usage_fresh,
                "startup snapshot lost last-good numerics or claimed fresh attribution");
            restored = true;
            break;
        }
        super::super::dashboard_snapshot(home)?;
    }
    need!(restored, "A-only startup cache did not restore the numeric last-good snapshot");
    let baseline = peek_startup_identity(home)?.ok_or("startup identity disappeared after numeric hydration")?;

    let reader = open_startup_identity_read_only(home)?.ok_or("A-only startup reader disappeared")?;
    let denied = reader.execute("UPDATE metadata SET value='999999' WHERE key='revision'", [])
        .err().ok_or("A-only startup reader accepted a main-database write")?;
    need!(denied.sqlite_error_code() == Some(rusqlite::ErrorCode::ReadOnly),
        "startup reader did not enforce SQLite read-only mode");
    drop(reader);

    let spec = route::exact_store_spec(index_path)?;
    let writer = route::open_store("exact", &spec.source_identity, &spec.logical_path, &[])?;
    sql!(writer.execute_batch("BEGIN IMMEDIATE; UPDATE metadata SET value='999999' WHERE key='revision';"));
    let checked = (|| -> Result<(), String> {
        need!(peek_startup_identity(home)? == Some(baseline.clone()),
            "startup reader blocked on the writer or exposed its uncommitted identity");
        need!(store_count()? == count_before, "startup reader registered another store");
        Ok(())
    })();
    let rollback = writer.execute_batch("ROLLBACK;");
    checked?;
    sql!(rollback);
    drop(writer);

    // A Home whose legacy file has not yet been imported still has a safe
    // read-only identity path. Reading it must never import/register it in A.
    let legacy_home = home.join("startup-legacy-home");
    need!(!legacy_home.exists(), "startup fixture refuses an existing legacy Home");
    sql!(fs::create_dir_all(&legacy_home));
    let legacy_home = sql!(fs::canonicalize(legacy_home));
    let legacy_path = app_paths::tauri_usage_cache_dir()
        .ok_or("legacy startup fixture cache root unavailable")?
        .join("exact-token-index").join(format!("{}.sqlite3", stable_path_fingerprint(&legacy_home)));
    need!(!legacy_path.exists(), "startup fixture refuses an existing legacy index");
    route::export_store_to_path(&spec.source_identity, "exact", &spec.logical_path, &legacy_path)?;
    let legacy = sql!(rusqlite::Connection::open(&legacy_path));
    sql!(legacy.execute("UPDATE metadata SET value=?1 WHERE key='codex_home_identity'",
        [legacy_home.to_string_lossy().as_ref()]));
    drop(legacy);
    let original_bytes = sql!(fs::read(&legacy_path));
    need!(peek_startup_identity(&legacy_home)? == Some(baseline),
        "unimported legacy startup identity was not preserved");
    let reader = open_startup_identity_read_only(&legacy_home)?.ok_or("legacy startup reader disappeared")?;
    let denied = reader.execute("UPDATE metadata SET value='999999' WHERE key='revision'", [])
        .err().ok_or("legacy startup reader accepted a database write")?;
    need!(denied.sqlite_error_code() == Some(rusqlite::ErrorCode::ReadOnly),
        "legacy startup reader did not enforce SQLite read-only mode");
    drop(reader);
    need!(store_count()? == count_before
        && !route::exact_store_exists(&database_path(&legacy_home)?)?
        && !route::exact_store_exists(&legacy_path)?,
        "startup-only inspection imported or registered a legacy index");
    need!(sql!(fs::read(&legacy_path)) == original_bytes,
        "startup-only inspection rewrote the legacy database");
    Ok(())
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn verify_fixture(home: &Path) -> Result<serde_json::Value, String> {
    use crate::core::business_store_route as route;
    use std::io::Write;
    fn staging_error(error: StagedFullRebuildError) -> String {
        match error {
            StagedFullRebuildError::IncompleteSource(message)
            | StagedFullRebuildError::Fatal(message) => message,
        }
    }
    macro_rules! sql {
        ($value:expr) => {
            $value.map_err(|error| error.to_string())?
        };
    }
    macro_rules! need {
        ($value:expr, $message:expr) => {
            if !$value {
                return Err($message.into());
            }
        };
    }
    let event = |time: &str, tokens: i64| {
        format!(
            "{}\n{}\n{}\n",
            serde_json::json!({"timestamp": time, "type": "turn_context",
                "payload": {"model": "fixture-recovery-model"}}),
            serde_json::json!({"timestamp": time, "type": "event_msg",
                "payload": {"type": "user_message", "message": "fixture recovery turn"}}),
            serde_json::json!({
                "timestamp": time, "type": "event_msg", "payload": {"type": "token_count",
                "info": {"last_token_usage": {"input_tokens":tokens,"cached_input_tokens":0,
                "output_tokens":0,"total_tokens":tokens}}}
            })
        )
    };
    sql!(fs::create_dir_all(home.join("sessions")));
    let file = home.join("sessions/runtime-source.jsonl");
    need!(!file.exists(), "runtime fixture refuses an existing source");
    sql!(fs::write(&file, event("2026-10-28T00:00:00Z", 120)));
    need!(
        super::super::dashboard_snapshot(home)?.stats.total_tokens == 120,
        "runtime initial accounting mismatch"
    );
    let home = sql!(fs::canonicalize(home));
    let index_path = database_path(&home)?;
    verify_startup_readers(&home, &index_path)?;
    let mut index = ExactUsageIndex::open(&home)?;
    index.connection.mark_receipt_dirty();
    let published = metadata_i64(&index.connection, "published_generation")?
        .ok_or("missing published generation")?;
    let (path, session_id, size, modified): (String, String, i64, String) =
        sql!(index.connection.query_row(
            "SELECT path,session_id,size,modified_ns FROM sources WHERE deleted=0",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        ));
    let bad_prefix = [0x5a_u8; 32];
    sql!(index.connection.execute(
        "UPDATE sources SET prefix_sha256=?1 WHERE path=?2",
        params![bad_prefix.as_slice(), path]
    ));
    set_metadata(
        &index.connection,
        EVENT_ENRICHMENT_REVISION_KEY,
        PRE_COMPACTION_EVENT_ENRICHMENT_REVISION,
    )?;
    let base = reserve_staging_source(&index.connection, &path, &session_id)?;
    prepare_scan_temp_tables(&index.connection)?;
    let generation = begin_or_resume_generation(&mut index.connection, ExactSyncMode::Full)?;
    let job = FullRebuildJob {
        file: PathBuf::from(&path),
        path,
        session_id,
        source_id: base.source_id,
        base_generation: base.generation,
        base_resume_offset: base.resume_offset,
        base_prefix_sha256: base.prefix_sha256,
        signature: FileSignature {
            size: sql!(u64::try_from(size)),
            modified_ns: sql!(modified.parse::<u128>()),
            physical: None,
        },
        event_enrichment: true,
        expected_published_prefix_sha256: Some(bad_prefix),
    };
    let old = stage_or_reuse_full_rebuild(&job, &index_path, generation, &home, &mut Vec::new())
        .map_err(staging_error)?;
    need!(
        old.prefix_sha256 != bad_prefix && !old.database_path.exists(),
        "fixture requires a valid namespace-only stage and inconsistent old checkpoint"
    );
    let original_proof = route::exact_store_observation(&old.database_path)?;
    // A retained artifact's persisted seal is not evidence of its current
    // rows. Keep the row count and source bytes unchanged while modifying a
    // same-shaped numeric value, as a damaged artifact can do after sealing.
    let damaged_contract = Sha256::digest(b"fixture-damaged-seal-v1");
    let damaged_path = staging_directory(&index_path).join(format!(
        "{}.candidate-v2-{damaged_contract:x}.sqlite3", staging_database_digest(&job.path)
    ));
    route::clone_exact_store(&old.database_path, &damaged_path)?;
    route::seal_exact_store(&damaged_path)?;
    let verified_before_damage = reusable_staged_full_rebuild(&damaged_path, &job, generation)?
        .ok_or("undamaged cloned stage did not validate")?;
    let seal_before_damage = route::exact_store_observation(&damaged_path)?;
    let stage_raw_digest = Sha256::digest(sql!(fs::read(&file)));
    let main_store = route::exact_store_spec(&index_path)?;
    let main_proof = || {
        crate::core::business_store_container::Container::open_read_only_existing(
            route::container_path()?, StdDuration::from_secs(1))
            .and_then(|container| container.proof(&main_store)).map_err(|error| error.to_string())
    };
    let main_before_damage = main_proof()?;
    let damaged = open_staging_connection(&damaged_path)?;
    need!(
        sql!(damaged.execute("UPDATE events SET tokens=tokens+1,input_tokens=input_tokens+1", [])) == 1,
        "damaged-seal fixture requires exactly one event"
    );
    quick_check_staged(&damaged)?;
    drop(damaged);
    need!(route::exact_store_observation(&damaged_path)? == seal_before_damage,
        "damaged-seal fixture unexpectedly changed the persisted seal");
    need!(reusable_staged_full_rebuild(&damaged_path, &job, generation).is_err(),
        "retained stage numeric corruption bypassed its unchanged seal");
    need!(import_staged_full_rebuild(&mut index.connection, generation,
        &verified_before_damage, ExactSyncMode::Full).is_err(),
        "previously validated stage accepted changed numeric content before import");
    // Restore only this fixture's known original values. Its unchanged old
    // seal must match again before testing the later publication boundary.
    let restored = open_staging_connection(&damaged_path)?;
    sql!(restored.execute("UPDATE events SET tokens=tokens-1,input_tokens=input_tokens-1", []));
    drop(restored);
    let verified_before_publish = reusable_staged_full_rebuild(&damaged_path, &job, generation)?
        .ok_or("restored fixture values did not match their original seal")?;
    let mut mutation_calls = 0;
    let before_publish = import_staged_full_rebuild_with_hook(&mut index.connection, generation,
        &verified_before_publish, ExactSyncMode::Full, || {
            let changed = open_staging_connection(&damaged_path)?;
            need!(sql!(changed.execute(
                "UPDATE events SET tokens=tokens+1,input_tokens=input_tokens+1", [])) == 1,
                "publication-boundary fixture did not mutate its single stage row");
            mutation_calls += 1;
            Ok(())
        });
    need!(mutation_calls == 1 && before_publish.is_err_and(|error| error.contains("封存内容不一致")),
        "stage mutation after validation reached the import write transaction unchecked");
    need!(route::exact_store_exists(&damaged_path)?
        && route::exact_store_observation(&damaged_path)? == seal_before_damage
        && main_proof()? == main_before_damage
        && Sha256::digest(sql!(fs::read(&file))) == stage_raw_digest
        && metadata_i64(&index.connection, "published_generation")? == Some(published)
        && index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?.total_tokens == 120,
        "bad-stage rejection changed the retained artifact or published history");
    // Re-sealing a changed artifact cannot redefine an existing owner's
    // already-verified proof, even when artifact ID and byte count match.
    route::seal_exact_store(&damaged_path)?;
    let resealed = route::exact_store_observation(&damaged_path)?;
    let replaced = import_staged_full_rebuild(&mut index.connection, generation,
        &verified_before_publish, ExactSyncMode::Full);
    need!(replaced.is_err_and(|error| error.contains("封存证明在校验后发生变化"))
        && route::exact_store_observation(&damaged_path)? == resealed
        && main_proof()? == main_before_damage,
        "re-sealing changed content replaced the existing owner's proof");

    let restored = open_staging_connection(&damaged_path)?;
    sql!(restored.execute("UPDATE events SET tokens=120,input_tokens=120,output_tokens=0", []));
    drop(restored);
    route::seal_exact_store(&damaged_path)?;
    let schema_seal = route::exact_store_observation(&damaged_path)?;
    let stage_store = route::exact_store_spec(&damaged_path)?;
    let stage_proof = || {
        crate::core::business_store_container::Container::open_read_only_existing(
            route::container_path()?, StdDuration::from_secs(1))
            .and_then(|container| container.proof(&stage_store)).map_err(|error| error.to_string())
    };
    let schema_before = stage_proof()?;
    let swap_columns = || -> Result<(), String> {
        open_staging_connection(&damaged_path)?.execute_batch(
            "ALTER TABLE events RENAME COLUMN input_tokens TO swapped_tokens;
             ALTER TABLE events RENAME COLUMN output_tokens TO input_tokens;
             ALTER TABLE events RENAME COLUMN swapped_tokens TO output_tokens;")
            .map_err(|error| error.to_string())
    };
    swap_columns()?;
    let schema_after = stage_proof()?;
    need!(schema_before.rows_digest == schema_after.rows_digest
        && schema_before.row_count == schema_after.row_count
        && schema_before.schema_digest != schema_after.schema_digest
        && route::exact_store_observation(&damaged_path)? == schema_seal,
        "schema fixture must leave row digest/count and persisted seal unchanged");
    need!(reusable_staged_full_rebuild(&damaged_path, &job, generation).is_err(),
        "retained stage column-role mutation bypassed the content proof");
    swap_columns()?;
    let verified_before_schema_publish = reusable_staged_full_rebuild(&damaged_path, &job, generation)?
        .ok_or("restored schema did not match the producer contract")?;
    let mut schema_mutation_calls = 0;
    let schema_publish = import_staged_full_rebuild_with_hook(&mut index.connection, generation,
        &verified_before_schema_publish, ExactSyncMode::Full, || {
            swap_columns()?;
            schema_mutation_calls += 1;
            Ok(())
        });
    need!(schema_mutation_calls == 1
        && schema_publish.is_err_and(|error| error.contains("封存内容不一致"))
        && route::exact_store_observation(&damaged_path)? == schema_seal
        && main_proof()? == main_before_damage,
        "schema mutation after validation reached publication unchecked");

    swap_columns()?;
    let damaged = open_staging_connection(&damaged_path)?;
    sql!(damaged.execute("UPDATE events SET tokens=121,input_tokens=121", []));
    drop(damaged);
    let physical = sql!(crate::core::business_store_container::Container::open_existing(route::container_path()?));
    sql!(physical.connection().execute("DELETE FROM tb_store_seals WHERE store_id=?1", [&stage_store.id]));
    drop(physical);
    let unsigned_reader = open_read_only_index(&damaged_path, StdDuration::from_secs(1))?;
    need!(sql!(unsigned_reader.store_state(&stage_store))
            == crate::core::business_store_container::StoreState::Sealed
        && stage_content_proof::can_rebuild_unsealed(&unsigned_reader, &damaged_path, &job, generation)
            .is_err(),
        "missing seal turned a previously sealed artifact into a rebuildable unsigned stage");
    drop(unsigned_reader);
    need!(reusable_staged_full_rebuild(&damaged_path, &job, generation).is_err()
        && route::exact_store_observation(&damaged_path)?.is_none()
        && main_proof()? == main_before_damage,
        "previously sealed stage with a missing seal was re-signed during restart");
    // Only this synthetic fixture-owned artifact is removed so the existing
    // successful restart/replay scenarios below can continue independently.
    route::remove_exact_store(&damaged_path)?;
    let mut append = sql!(fs::OpenOptions::new().append(true).open(&file));
    sql!(append.write_all(event("2026-10-28T00:01:00Z", 55).as_bytes()));
    sql!(append.sync_all());
    drop(append);
    let source_digest = Sha256::digest(sql!(fs::read(&file)));
    let replacement = FullRebuildJob {
        signature: file_signature(&job.file)?,
        expected_published_prefix_sha256: None,
        ..job.clone()
    };
    let candidate = stage_or_reuse_full_rebuild(
        &replacement,
        &index_path,
        generation,
        &home,
        &mut Vec::new(),
    )
    .map_err(staging_error)?;
    super::stage_content_fixture::verify_pending_and_unsealed(
        &mut index, &index_path, &home, &old, &candidate, generation)?;
    need!(
        candidate.database_path != old.database_path && !candidate.database_path.exists(),
        "replacement overwrote the old stage or escaped namespace storage"
    );
    need!(
        metadata_i64(&index.connection, "published_generation")? == Some(published),
        "candidate creation published prematurely"
    );
    let artifact = candidate.artifact_id.clone();
    let candidate_spec = route::exact_store_spec(&candidate.database_path)?;
    sql!(fs::create_dir_all(staging_directory(&index_path)));
    need!(
        route::exact_store_spec(&candidate.database_path)? == candidate_spec,
        "candidate identity depends on physical directory existence"
    );
    drop(index); // interruption after durable staging, before import/publication
    let mut index = ExactUsageIndex::open(&home)?;
    need!(
        staging_database_paths(&index_path, &job.path)?.contains(&candidate.database_path),
        "namespace candidate was not recovered from the catalog"
    );
    let resumed = stage_or_reuse_full_rebuild(
        &replacement,
        &index_path,
        generation,
        &home,
        &mut Vec::new(),
    )
    .map_err(staging_error)?;
    need!(
        resumed.artifact_id == artifact,
        "restart reparsed instead of resuming the durable candidate"
    );
    index.synchronize_event_enrichment(&home, &index_path, &mut Vec::new(), ExactSyncMode::Full)?;
    need!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?
            .total_tokens
            == 175,
        "enrichment lost or double-counted usage"
    );
    index.sync(&home, &mut Vec::new())?;
    need!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?
            .total_tokens
            == 175,
        "enrichment replay was not idempotent"
    );
    need!(
        route::exact_store_exists(&old.database_path)?
            && route::exact_store_observation(&old.database_path)? == original_proof,
        "old complete stage or manifest was changed"
    );
    need!(
        Sha256::digest(sql!(fs::read(&file))) == source_digest,
        "runtime recovery rewrote its source"
    );

    // A corrupt candidate still fails closed, retaining the published ledger.
    let published_after = metadata_i64(&index.connection, "published_generation")?;
    let base = reserve_staging_source(&index.connection, &job.path, &job.session_id)?;
    let future = FullRebuildJob {
        base_generation: base.generation,
        base_resume_offset: base.resume_offset,
        base_prefix_sha256: base.prefix_sha256,
        event_enrichment: false,
        ..replacement.clone()
    };
    let future_generation = published_after.ok_or("missing final generation")? + 1;
    let bad = candidate_path(&index_path, &future, future_generation);
    route::clone_exact_store(&old.database_path, &bad)?;
    let bad_connection = open_staging_connection(&bad)?;
    sql!(bad_connection.execute(
        "UPDATE manifest SET parser_revision='unsupported-fixture-parser'",
        []
    ));
    drop(bad_connection);
    need!(
        stage_or_reuse_full_rebuild(
            &future,
            &index_path,
            future_generation,
            &home,
            &mut Vec::new()
        )
        .is_err(),
        "invalid candidate bypassed validation"
    );
    need!(
        route::exact_store_exists(&bad)?
            && metadata_i64(&index.connection, "published_generation")? == published_after,
        "invalid candidate changed published accounting"
    );
    drop(index);

    super::stage_content_fixture::verify_missing_pending_source(&home.join("pending-missing-home"))?;

    let state = home.join("state_5.sqlite");
    let writer = sql!(rusqlite::Connection::open(&state));
    sql!(writer.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,first_user_message TEXT,preview TEXT,updated_at INTEGER,updated_at_ms INTEGER); INSERT INTO threads VALUES('fixture-thread','fixture-title-one',NULL,NULL,100,NULL);"));
    let read_state = |previous, previous_source| -> Result<StagedThreadMetadata, String> {
        let mut warnings = Vec::new();
        match stage_thread_metadata(&home, previous, previous_source, &mut warnings)? {
            ThreadMetadataStage::Updated(rows) => Ok(rows),
            _ => Err(format!("live thread metadata fixture could not read the source: {warnings:?}")),
        }
    };
    let first = read_state((None, None), None)?;
    need!(
        first.rows.first().map(|row| row.1.as_str()) == Some("fixture-title-one"),
        "initial live state read failed"
    );
    sql!(writer.execute(
        "UPDATE threads SET title='fixture-title-two',updated_at=200",
        []
    ));
    let main_signature = file_signature(&state)?;
    need!(
        first.signature.as_ref()
            == Some(&(
                main_signature.size.to_string(),
                main_signature.modified_ns.to_string()
            )),
        "WAL fixture unexpectedly changed the main database signature"
    );
    let second = read_state(first.signature.clone().unzip(), first.source_signature)?;
    need!(
        second.rows.first().map(|row| row.1.as_str()) == Some("fixture-title-two"),
        "live state was read from a frozen legacy import"
    );
    let repeated = read_state(second.signature.clone().unzip(), second.source_signature.clone())?;
    need!(repeated.rows == second.rows, "live WAL re-read changed unchanged metadata");
    sql!(writer.execute_batch("PRAGMA wal_checkpoint(PASSIVE);"));
    let checkpointed = read_state(repeated.signature.unzip(), repeated.source_signature)?;
    let wal = sqlite_sidecar_path(&state, "-wal");
    let wal_before = sql!(fs::metadata(&wal));
    let main_before = sql!(fs::read(&state));
    sql!(writer.execute("UPDATE threads SET title='fixture-title-three',updated_at=300", []));
    need!(sql!(fs::metadata(&wal)).len() == wal_before.len(), "WAL reuse fixture grew the allocation");
    sql!(sql!(fs::File::options().write(true).open(&wal))
        .set_times(fs::FileTimes::new().set_modified(sql!(wal_before.modified()))));
    need!(sql!(fs::read(&state)) == main_before, "WAL reuse fixture changed the main database");
    let reused = read_state(checkpointed.signature.unzip(), checkpointed.source_signature)?;
    need!(reused.rows.first().map(|row| row.1.as_str()) == Some("fixture-title-three"),
        "same-size same-mtime reused WAL inherited stale metadata");
    sql!(writer.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);"));
    let inactive = read_state(reused.signature.unzip(), reused.source_signature)?;
    need!(matches!(stage_thread_metadata(&home, inactive.signature.unzip(), inactive.source_signature,
        &mut Vec::new())?, ThreadMetadataStage::Unchanged), "inactive WAL did not retain its cache fast path");
    let reader = open_read_only_source(&state, StdDuration::from_secs(1))?;
    need!(
        reader
            .execute("UPDATE threads SET updated_at=999", [])
            .is_err(),
        "external state connection accepted a write"
    );
    need!(
        !route::exact_store_exists(&state)?,
        "external state was imported as an Exact store"
    );
    Ok(
        serde_json::json!({"name":"runtime-recovery-production-path","status":"PASS",
        "legacyCheckpointMismatch":true,"namespaceCandidateResumed":true,"oldStagePreserved":true,
        "invalidCandidateRejected":true,"tokensAfterReplay":175,"liveStateRefreshed":true,
        "retainedStageContentVerified":true,"changedStageImportRejected":true,
        "stageMutationBeforePublicationRejected":true,
        "sealedStageMissingSealRejected":true,"resealedStageImportRejected":true,
        "stageSchemaMutationRejected":true,"stageSchemaMutationBeforePublicationRejected":true,
        "unsealedStageRebuiltFromSource":true,"pendingHistoryOverwriteRejected":true,
        "unsealedPreservationMutationRejected":true,
        "missingSourcePendingHistoryPublished":true,
        "nonemptyWalReread":true,"walAllocationReuseObserved":true,"inactiveWalCache":true,
        "startupNamespaceOnlyIdentity":true,"startupLastGoodRestored":true,
        "startupConcurrentPublisherRead":true,"startupLegacySourceUnchanged":true,
        "startupLegacyNotImported":true,"startupSqliteWriteRefused":true,
        "externalStateReadOnly":true}),
    )
}
