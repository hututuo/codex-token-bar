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
mod tests {
    use super::*;

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
            modified_ns: sql!(modified.parse()),
            physical: None,
        },
        event_enrichment: true,
        expected_published_prefix_sha256: Some(bad_prefix),
    };
    let old = stage_or_reuse_full_rebuild(&job, &index_path, generation, &home, &mut Vec::new())
        .map_err(|error| format!("{error:?}"))?;
    need!(
        old.prefix_sha256 != bad_prefix && !old.database_path.exists(),
        "fixture requires a valid namespace-only stage and inconsistent old checkpoint"
    );
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
    .map_err(|error| format!("{error:?}"))?;
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
    .map_err(|error| format!("{error:?}"))?;
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
    Ok(
        serde_json::json!({"name":"runtime-recovery-production-path","status":"PASS",
        "legacyCheckpointMismatch":true,"namespaceCandidateResumed":true,"oldStagePreserved":true,
        "invalidCandidateRejected":true,"tokensAfterReplay":175,"liveStateRefreshed":true,
        "externalStateReadOnly":true}),
    )
}
