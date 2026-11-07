//! Preserve a complete artifact when only the requested scan contract changes.
use super::connection::open_read_only_index;
use super::contracts::{FileSignature, FullRebuildJob, EVENT_ENRICHMENT_REVISION,
    STAGED_FULL_REBUILD_PARSER_REVISION};
use super::store_metadata::column_exists_checked;
use super::{staging_database_digest, staging_directory, validated_staged_full_rebuild,
    STAGING_MANIFEST_SCHEMA_VERSION};
use rusqlite::OptionalExtension;
use sha2::{Digest, Sha256};
use std::{path::{Path, PathBuf}, time::Duration as StdDuration};
#[cfg(any(test, feature = "business-store-fixture"))]
use super::connection::open_read_only_source;
#[cfg(any(test, feature = "business-store-fixture"))]
use super::{file_signature, stage_thread_metadata, ThreadMetadataStage};
#[cfg(any(test, feature = "business-store-fixture"))]
use std::fs;
#[cfg(test)]
use super::connection::Connection;
#[cfg(test)]
use uuid::Uuid;
#[cfg(all(feature = "business-store-fixture", not(test)))]
use super::contracts::{ExactSyncMode, StagedFullRebuildError, EVENT_ENRICHMENT_REVISION_KEY,
    PRE_COMPACTION_EVENT_ENRICHMENT_REVISION};
#[cfg(all(feature = "business-store-fixture", not(test)))]
use super::store_metadata::{metadata_i64, metadata_text, set_metadata};
#[cfg(all(feature = "business-store-fixture", not(test)))]
use super::{active_schema11_paths, active_schema11_paths_on, begin_or_resume_generation,
    database_path, open_staging_connection, prepare_scan_temp_tables,
    record_successful_migration_retention, reserve_staging_source,
    schema11_paths_for_namespace, schema11_source_receipt_from_connection,
    schema11_store_manifest, stage_or_reuse_full_rebuild, staging_database_path,
    staging_database_paths, ExactUsageIndex, Schema11CandidateManifest,
    Schema11CandidatePhase, StagedThreadMetadata, MIGRATION_RETENTION_KEY,
    SCHEMA11_CANDIDATE_MANIFEST_VERSION};
#[cfg(all(feature = "business-store-fixture", not(test)))]
use rusqlite::params;
#[cfg(all(feature = "business-store-fixture", not(test)))]
use time::{OffsetDateTime, UtcOffset};

#[cfg(all(feature = "business-store-fixture", not(test)))]
mod retention_fixture;

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
/// Despite the predicate name, the existing production open may prepare the
/// pool/restore a private image or admit a legacy namespace. Validation also
/// reads source bytes. This belongs to the staging recovery owner, not reads.
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
mod tests {
    use super::*;

    #[test]
    fn legacy_state_optional_columns_are_read_without_modifying_the_source() {
        let root = tempfile::tempdir().unwrap();
        let database = root.path().join("state_5.sqlite");
        let writer = Connection::open(&database).unwrap();
        writer.execute_batch("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,updated_at INTEGER); INSERT INTO threads VALUES('legacy','retained title',100);").unwrap();
        let schema_before: String = writer.query_row("SELECT sql FROM sqlite_master WHERE name='threads'", [], |r| r.get(0)).unwrap();
        let mut warnings = Vec::new();
        let ThreadMetadataStage::Updated(snapshot) = stage_thread_metadata(root.path(), (None, None), None, &mut warnings).unwrap()
        else { panic!("known older columns must remain readable"); };
        assert_eq!(snapshot.rows.len(), 1);
        assert_eq!(snapshot.rows[0].0, "legacy");
        assert_eq!(snapshot.rows[0].1, "retained title");
        assert!(warnings.is_empty(), "{warnings:?}");
        let schema_after: String = writer.query_row("SELECT sql FROM sqlite_master WHERE name='threads'", [], |r| r.get(0)).unwrap();
        assert_eq!(schema_before, schema_after);
    }

    #[test]
    fn missing_required_state_columns_do_not_publish_successful_empty_metadata() {
        let root = tempfile::tempdir().unwrap();
        let writer = Connection::open(root.path().join("state_5.sqlite")).unwrap();
        writer.execute_batch("CREATE TABLE threads(id TEXT PRIMARY KEY,preview TEXT); INSERT INTO threads VALUES('legacy','retained');").unwrap();
        let mut warnings = Vec::new();
        assert!(matches!(stage_thread_metadata(root.path(), (None, None), None, &mut warnings).unwrap(), ThreadMetadataStage::Failed));
        assert_eq!(warnings.len(), 1);
        assert_eq!(writer.query_row("SELECT COUNT(*) FROM threads", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
    }

    #[test]
    fn live_state_cache_observes_wal_only_commits_and_invalidates_frozen_reader_cache() {
        let root = std::env::temp_dir().join(format!("tokenbar-wal-source-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let database = root.join("state_5.sqlite");
        let writer = Connection::open(&database).unwrap();
        writer.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,first_user_message TEXT,preview TEXT,updated_at INTEGER,updated_at_ms INTEGER); INSERT INTO threads VALUES('fixture','first',NULL,NULL,100,NULL);").unwrap();
        let ThreadMetadataStage::Updated(first) =
            stage_thread_metadata(&root, (None, None), None, &mut Vec::new()).unwrap()
        else {
            panic!("first state read did not produce metadata");
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
        assert!(matches!(
            stage_thread_metadata(
                &root,
                second.signature.clone().unzip(),
                second.source_signature.clone(),
                &mut Vec::new()
            )
            .unwrap(),
            ThreadMetadataStage::Unchanged
        ));
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
    }
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
            "{}\n",
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
    let mut index = ExactUsageIndex::open(&home)?;
    // The fresh index has no completed migration receipt. Its normal success
    // path must still resolve migration ownership without reopening A each time.
    need!(metadata_text(&index.connection, MIGRATION_RETENTION_KEY)?.is_none(),
        "retention fixture requires an uncached absent receipt");
    let existing_opens = crate::core::business_store_container::fixture_existing_open_count;
    let opens_before = existing_opens();
    for _ in 0..3 {
        record_successful_migration_retention(&index.connection, &index_path)?;
    }
    let retention_reopens = existing_opens().saturating_sub(opens_before);
    need!(retention_reopens == 0, "steady retention lookup reopened A");
    let held_paths = active_schema11_paths_on(&index.connection, &index_path)?;
    let before_control = existing_opens();
    let cold_paths = active_schema11_paths(&index_path)?;
    let fresh_control = existing_opens().saturating_sub(before_control);
    need!(fresh_control >= 1 && held_paths == cold_paths,
        "retention lookup needs an executed fresh-open control with equal routing");
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
    let mut old = stage_or_reuse_full_rebuild(&job, &index_path, generation, &home, &mut Vec::new())
        .map_err(staging_error)?;
    need!(
        old.prefix_sha256 != bad_prefix && !old.database_path.exists(),
        "fixture requires a valid namespace-only stage and inconsistent old checkpoint"
    );
    // Keep the original PR7 legacy-artifact recovery assertion after new
    // production writers move to the fixed pool. Form a real old-style stage
    // from the parser's typed rows; only this disposable producer writes it.
    let pool=stage_pool::Pool::current()?;
    let old_job=pool.lookup(&old.database_path)?.ok_or("fixture missing old pool job")?;
    let raw=pool.restore(&old_job)?;
    let legacy=staging_database_path(&index_path,&job.path);
    sql!(fs::create_dir_all(staging_directory(&index_path)));
    let mut destination=sql!(rusqlite::Connection::open(&legacy));
    {let backup=sql!(rusqlite::backup::Backup::new(&raw,&mut destination));sql!(backup.run_to_completion(128,StdDuration::from_millis(1),None));}
    drop(destination);drop(raw);
    let spec=route::exact_store_spec(&legacy)?;
    drop(route::open_store("exact",&spec.source_identity,&spec.logical_path,&[legacy.clone()])?);
    route::seal_exact_store(&legacy)?;
    old.database_path=legacy;
    old.source_validation=None;
    let original_proof = route::exact_store_observation(&old.database_path)?;
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
    need!(
        candidate.database_path != old.database_path && !candidate.database_path.exists(),
        "replacement overwrote the old stage or escaped namespace storage"
    );
    need!(
        metadata_i64(&index.connection, "published_generation")? == Some(published),
        "candidate creation published prematurely"
    );
    let artifact = candidate.artifact_id.clone();
    let candidate_spec = pool.lookup(&candidate.database_path)?.ok_or("fixture missing candidate job")?.id;
    sql!(fs::create_dir_all(staging_directory(&index_path)));
    need!(
        pool.lookup(&candidate.database_path)?.ok_or("fixture lost candidate")?.id == candidate_spec,
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

    let state = home.join("state_5.sqlite");
    let writer = sql!(rusqlite::Connection::open(&state));
    sql!(writer.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,first_user_message TEXT,preview TEXT,updated_at INTEGER,updated_at_ms INTEGER); INSERT INTO threads VALUES('fixture-thread','fixture-title-one',NULL,NULL,100,NULL);"));
    let read_state = |previous, previous_source| -> Result<StagedThreadMetadata, String> {
        match stage_thread_metadata(&home, previous, previous_source, &mut Vec::new())? {
            ThreadMetadataStage::Updated(rows) => Ok(rows),
            _ => Err("live thread metadata fixture could not read the source".into()),
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
    need!(
        matches!(
            stage_thread_metadata(
                &home,
                second.signature.clone().unzip(),
                second.source_signature,
                &mut Vec::new()
            )?,
            ThreadMetadataStage::Unchanged
        ),
        "unchanged WAL state bypassed the cache"
    );
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
    // Also execute the older optional-column projection through this non-test
    // production build; cfg(test) direct connections are not sufficient proof.
    let legacy_home = home.join("legacy-state-reader-fixture");
    sql!(fs::create_dir_all(&legacy_home));
    let legacy_state = legacy_home.join("state_5.sqlite");
    let legacy_writer = sql!(rusqlite::Connection::open(&legacy_state));
    sql!(legacy_writer.execute_batch("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,updated_at INTEGER); INSERT INTO threads VALUES('legacy-thread','legacy-title',300);"));
    let original_schema: String = sql!(legacy_writer.query_row("SELECT sql FROM sqlite_master WHERE name='threads'", [], |r| r.get(0)));
    let ThreadMetadataStage::Updated(legacy_metadata) = stage_thread_metadata(&legacy_home, (None, None), None, &mut Vec::new())?
    else { return Err("production external reader rejected known legacy state columns".into()); };
    need!(legacy_metadata.rows.len() == 1 && legacy_metadata.rows[0].1 == "legacy-title",
        "legacy state rows were lost or replaced with an empty success");
    let retained_schema: String = sql!(legacy_writer.query_row("SELECT sql FROM sqlite_master WHERE name='threads'", [], |r| r.get(0)));
    need!(original_schema == retained_schema && !route::exact_store_exists(&legacy_state)?,
        "legacy external state was altered or registered as a ledger");
    let fixed_pool=stage_pool::verify_fixture()?;
    let late_retention = retention_fixture::verify(&home)?;
    Ok(
        serde_json::json!({"name":"runtime-recovery-production-path","status":"PASS",
        "legacyCheckpointMismatch":true,"namespaceCandidateResumed":true,"oldStagePreserved":true,
        "invalidCandidateRejected":true,"tokensAfterReplay":175,"liveStateRefreshed":true,
        "externalStateReadOnly":true,"legacyStateColumnsReadWithoutImport":true,"fixedPool":fixed_pool,
        "steadyRetention":{"calls":3,"reopens":retention_reopens,"freshOpenControl":fresh_control,"samePaths":true},
        "lateRetention":late_retention}),
    )
}
