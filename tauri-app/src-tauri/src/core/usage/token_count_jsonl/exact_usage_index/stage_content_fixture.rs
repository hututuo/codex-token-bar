//! Faults below touch only the native fixture's isolated source and A stores.
use super::*;
use crate::core::business_store_container::{Container, StoreProof, StoreSpec};
use crate::core::business_store_route as route;

fn proof(path: &Path) -> Result<StoreProof, String> {
    let store = route::exact_store_spec(path)?;
    Container::open_read_only_existing(route::container_path()?, StdDuration::from_secs(1))
        .and_then(|container| container.proof(&store)).map_err(|error| error.to_string())
}

fn store_catalog() -> Result<Vec<StoreSpec>, String> {
    let container = Container::open_read_only_existing(route::container_path()?, StdDuration::from_secs(1))
        .map_err(|error| error.to_string())?;
    let mut statement = container.connection().prepare(
        "SELECT module,source_identity,logical_path FROM tb_stores WHERE module='exact'")
        .map_err(|error| error.to_string())?;
    let rows = statement.query_map([], |row| Ok((row.get::<_, String>(0)?,
        row.get::<_, String>(1)?, row.get::<_, String>(2)?)))
        .map_err(|error| error.to_string())?;
    rows.map(|row| {
        let (module, source, logical) = row.map_err(|error| error.to_string())?;
        StoreSpec::new(module, source, logical).map_err(|error| error.to_string())
    }).collect()
}

pub(super) fn verify_pending_and_unsealed(
    index: &mut ExactUsageIndex,
    index_path: &Path,
    home: &Path,
    old: &StagedFullRebuild,
    candidate: &StagedFullRebuild,
    generation: i64,
) -> Result<(), String> {
    macro_rules! need { ($value:expr, $message:expr) => { if !$value { return Err($message.into()); } }; }
    let pending_facts = |index: &ExactUsageIndex| -> Result<(i64, i64), String> {
        index.connection.query_row(
            "SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM pending_event_rows WHERE source_id=?1",
            [candidate.job.source_id], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|error| error.to_string())
    };
    let pending_metadata = |index: &ExactUsageIndex| -> Result<(i64, i64), String> {
        index.connection.query_row(
            "SELECT COUNT(*),COUNT(DISTINCT user_prompt_start) FROM pending_event_rows \
             WHERE source_id=?1 AND model='fixture-recovery-model' \
               AND user_prompt_start IS NOT NULL AND user_prompt_end=user_prompt_start",
            [candidate.job.source_id], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|error| error.to_string())
    };
    import_staged_full_rebuild(&mut index.connection, generation, candidate, ExactSyncMode::Full)?;
    need!(pending_facts(index)? == (2, 175) && pending_metadata(index)? == (2, 2)
        && index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?.total_tokens == 120,
        "pending fixture needs a new 55-token event, known models and distinct turns before publication");
    let before_stale_import = proof(index_path)?;
    let stale_import = import_staged_full_rebuild(&mut index.connection, generation, old, ExactSyncMode::Full);
    if stale_import.is_ok() {
        let after = pending_facts(index)?;
        return Err(format!("stale prefix replaced already imported pending history: before=(2,175), after={after:?}"));
    }
    need!(stale_import.is_err_and(|error| error.contains("待发布历史")),
        "stale prefix replaced already imported pending history");
    need!(proof(index_path)? == before_stale_import && pending_facts(index)? == (2, 175),
        "rejected old prefix changed pending IDs, bindings, fingerprints or numeric history");

    // A successful retry of the same complete source must remain possible.
    import_staged_full_rebuild(&mut index.connection, generation, candidate, ExactSyncMode::Full)?;
    need!(pending_facts(index)? == (2, 175) && pending_metadata(index)? == (2, 2),
        "complete candidate retry did not preserve pending history, models or distinct turns");

    // Both artifacts below were built and verified from the real raw source.
    // A late writer replaces the copied 120-token prefix with the complete
    // 175-token candidate between preservation and removal. The older copied
    // proof must not authorize deleting that new artifact.
    let racing_index = index_path.with_extension("preservation-race.sqlite3");
    let racing = staging_database_path(&racing_index, &candidate.job.path);
    let old_proof = route::clone_exact_store(&old.database_path, &racing)?;
    let candidate_proof = proof(&candidate.database_path)?;
    need!(old_proof != candidate_proof, "preservation race requires distinct complete artifacts");
    let mut preserved_copy = None;
    let mut race_calls = 0;
    let preservation = preserve_private_stage_family_with_hook(&racing, |preserved| {
        need!(proof(preserved)? == old_proof, "race hook ran before the old proof was preserved");
        preserved_copy = Some(preserved.to_path_buf());
        route::clone_exact_store(&candidate.database_path, &racing)?;
        race_calls += 1;
        Ok(())
    });
    need!(race_calls == 1, "preservation race writer did not install the complete candidate");
    need!(preservation.is_err_and(|error| error.contains("暂存保留后原分区")),
        "preserving a stage deleted the newer complete artifact written after its copy");
    need!(proof(&racing)? == candidate_proof
        && proof(preserved_copy.as_ref().ok_or("preservation race did not retain its old copy")?)? == old_proof,
        "rejected preservation changed the old copy or newer complete artifact");
    route::remove_exact_store(&racing)?;

    let independent_index = index_path.with_extension("unsealed-fixture.sqlite3");
    let unsigned = staging_database_path(&independent_index, &candidate.job.path);
    route::clone_exact_store(&candidate.database_path, &unsigned)?;
    need!(route::exact_store_observation(&unsigned)?.is_none(),
        "unsealed recovery fixture unexpectedly has a seal");
    let unsigned_proof = proof(&unsigned)?;
    let main_before_faults = proof(index_path)?;
    let bytes = fs::read(&candidate.job.file).map_err(|error| error.to_string())?;
    let modified = fs::metadata(&candidate.job.file).and_then(|value| value.modified())
        .map_err(|error| error.to_string())?;
    for fault in ["truncated", "rewritten", "missing"] {
        match fault {
            "truncated" => fs::write(&candidate.job.file, &bytes[..bytes.len() / 2]),
            "rewritten" => {
                let mut changed = bytes.clone();
                let offset = changed.windows(3).position(|window| window == b"120")
                    .ok_or("fixture source has no 120-token literal")?;
                changed[offset + 2] = b'1';
                fs::write(&candidate.job.file, changed)
            }
            _ => fs::remove_file(&candidate.job.file),
        }.map_err(|error| error.to_string())?;
        need!(stage_or_reuse_full_rebuild(&candidate.job, &independent_index, generation,
            home, &mut Vec::new()).is_err(),
            "unsealed recovery accepted an unproved source prefix");
        need!(proof(&unsigned)? == unsigned_proof
            && route::exact_store_observation(&unsigned)?.is_none()
            && proof(index_path)? == main_before_faults,
            "failed unsealed recovery changed pending or artifact history");
        fs::write(&candidate.job.file, &bytes).map_err(|error| error.to_string())?;
        let source = fs::File::options().write(true).open(&candidate.job.file)
            .map_err(|error| error.to_string())?;
        source.set_times(fs::FileTimes::new().set_modified(modified)).map_err(|error| error.to_string())?;
        source.sync_all().map_err(|error| error.to_string())?;
    }

    let before_catalog = store_catalog()?.into_iter().map(|store| store.id)
        .collect::<std::collections::HashSet<_>>();
    let rebuilt = stage_or_reuse_full_rebuild(&candidate.job, &independent_index, generation,
        home, &mut Vec::new()).map_err(|error| match error {
            StagedFullRebuildError::Fatal(message) | StagedFullRebuildError::IncompleteSource(message) => message,
        })?;
    need!(rebuilt.artifact_id != candidate.artifact_id && rebuilt.event_count == 2
        && route::exact_store_observation(&rebuilt.database_path)?.is_some(),
        "unsealed artifact was signed in place instead of reparsed into a new candidate");
    let container = Container::open_read_only_existing(route::container_path()?, StdDuration::from_secs(1))
        .map_err(|error| error.to_string())?;
    let mut preserved = 0;
    for store in store_catalog()? {
        if !before_catalog.contains(&store.id)
            && container.proof(&store).map_err(|error| error.to_string())? == unsigned_proof {
            preserved += 1;
        }
    }
    need!(preserved == 1 && proof(index_path)? == main_before_faults,
        "unsealed recovery did not preserve its full old namespace independently of A history");
    drop(container);
    import_staged_full_rebuild(&mut index.connection, generation, &rebuilt, ExactSyncMode::Full)?;
    need!(pending_facts(index)? == (2, 175) && pending_metadata(index)? == (2, 2)
        && fs::read(&candidate.job.file).map_err(|error| error.to_string())? == bytes,
        "reparsed unsealed recovery lost the pending 55-token event or changed source bytes");
    route::remove_exact_store(&rebuilt.database_path)?;
    Ok(())
}

/// A crash can leave a complete imported pending generation whose raw source
/// later disappears. Exercise ordinary enrichment and restart publication;
/// retaining a private artifact or returning a protection error is not enough.
pub(super) fn verify_missing_pending_source(home: &Path) -> Result<(), String> {
    verify_missing_pending_source_case(&home.join("enrichment"), true)?;
    verify_missing_pending_source_case(&home.join("ordinary-sync"), false)
}

fn verify_missing_pending_source_case(home: &Path, enrichment: bool) -> Result<(), String> {
    use std::io::Write;
    macro_rules! need { ($value:expr, $message:expr) => { if !$value { return Err($message.into()); } }; }
    let event = |time: &str, tokens: i64| format!("{}\n{}\n{}\n{}\n",
        serde_json::json!({"timestamp": time, "type": "turn_context",
            "payload": {"model": "fixture-missing-model"}}),
        serde_json::json!({"timestamp": time, "type": "event_msg",
            "payload": {"type": "user_message", "message": "durable missing-source turn"}}),
        serde_json::json!({"timestamp": time, "type": "event_msg",
            "payload": {"type": "agent_message", "message": "durable missing-source answer"}}),
        serde_json::json!({"timestamp": time, "type": "event_msg", "payload": {"type": "token_count",
            "info": {"last_token_usage": {"input_tokens":tokens,"cached_input_tokens":0,
                "output_tokens":0,"total_tokens":tokens}}}}));
    need!(!home.exists(), "missing pending fixture refuses an existing Home");
    fs::create_dir_all(home.join("sessions")).map_err(|error| error.to_string())?;
    let home = fs::canonicalize(home).map_err(|error| error.to_string())?;
    let file = home.join("sessions/durable-pending.jsonl");
    fs::write(&file, event("2026-10-28T01:00:00Z", 120)).map_err(|error| error.to_string())?;
    need!(super::super::dashboard_snapshot(&home)?.stats.total_tokens == 120,
        "missing pending fixture did not publish its initial history");
    let index_path = database_path(&home)?;
    let mut index = ExactUsageIndex::open(&home)?;
    index.connection.mark_receipt_dirty();
    let (path, session): (String, String) = index.connection.query_row(
        "SELECT path,session_id FROM sources WHERE deleted=0", [], |row| Ok((row.get(0)?, row.get(1)?)))
        .map_err(|error| error.to_string())?;
    let base = reserve_staging_source(&index.connection, &path, &session)?;
    // Preserve the real parser's IDs, numeric facts and source checkpoint;
    // mimic only metadata associations absent from the previous parser. The
    // following production reparse must fill these before the raw disappears.
    if enrichment {
        index.connection.execute_batch("UPDATE event_rows SET model=NULL,user_prompt_start=NULL,user_prompt_end=NULL,assistant_response_start=NULL,assistant_response_end=NULL; \
        UPDATE usage_ledger_bindings SET user_prompt_start=NULL,user_prompt_end=NULL,assistant_response_start=NULL,assistant_response_end=NULL; \
        DELETE FROM usage_ledger_turns; DELETE FROM dashboard_turn_candidates_current; \
        UPDATE sources SET current_model=NULL,current_user_prompt_start=NULL,current_user_prompt_end=NULL,assistant_response_start=NULL,assistant_response_end=NULL;")
            .map_err(|error| error.to_string())?;
        // This is the legitimate partially-completed enrichment state left while
        // upgrading the previous parser revision; numeric history is unchanged.
        set_metadata(&index.connection, EVENT_ENRICHMENT_REVISION_KEY, PRE_COMPACTION_EVENT_ENRICHMENT_REVISION)?;
        index.connection.execute("UPDATE source_enrichment SET revision=?1,parser_revision=?2",
            params![PRE_COMPACTION_EVENT_ENRICHMENT_REVISION, PRE_COMPACTION_STAGED_PARSER_REVISION])
            .map_err(|error| error.to_string())?;
    }
    let mut append = fs::OpenOptions::new().append(true).open(&file).map_err(|error| error.to_string())?;
    append.write_all(event("2026-10-28T01:01:00Z", 55).as_bytes()).map_err(|error| error.to_string())?;
    append.sync_all().map_err(|error| error.to_string())?;
    drop(append);
    prepare_scan_temp_tables(&index.connection)?;
    let generation = begin_or_resume_generation(&mut index.connection, ExactSyncMode::Full)?;
    let job = FullRebuildJob { file: file.clone(), path: path.clone(), session_id: session,
        source_id: base.source_id, base_generation: base.generation,
        base_resume_offset: base.resume_offset, base_prefix_sha256: base.prefix_sha256,
        signature: file_signature(&file)?, event_enrichment: enrichment,
        expected_published_prefix_sha256: None };
    let staged = stage_or_reuse_full_rebuild(&job, &index_path, generation, &home, &mut Vec::new())
        .map_err(|error| match error {
            StagedFullRebuildError::Fatal(message) | StagedFullRebuildError::IncompleteSource(message) => message,
        })?;
    import_staged_full_rebuild(&mut index.connection, generation, &staged, ExactSyncMode::Full)?;
    let pending: (i64, i64) = index.connection.query_row(
        "SELECT COUNT(*),SUM(tokens) FROM pending_event_rows WHERE source_id=?1", [job.source_id],
        |row| Ok((row.get(0)?, row.get(1)?))).map_err(|error| error.to_string())?;
    let receipt: bool = index.connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM pending_enrichment e JOIN pending_sources p USING(source_id) \
         WHERE p.source_id=?1 AND p.target_generation=?2 AND e.completed_size=p.size \
           AND e.completed_prefix_sha256=p.prefix_sha256)", params![job.source_id, generation], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    let declared_mode = if enrichment {
        event_enrichment_receipt_count(&index.connection)? == 0
            && event_enrichment_pending_candidates(&index.connection)?.iter().any(|candidate| candidate.path == path)
    } else {
        // Cold scans made by the current parser need no historical enrichment
        // receipt. The global current marker selects the ordinary sync path.
        metadata_text(&index.connection, EVENT_ENRICHMENT_REVISION_KEY)?.as_deref() == Some(EVENT_ENRICHMENT_REVISION)
    };
    need!(pending == (2, 175) && receipt == enrichment && declared_mode
        && index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?.total_tokens == 120,
        "missing-source fault requires complete pending175, published120 and the declared enrichment receipt state");
    let enriched: i64 = index.connection.query_row(
        "SELECT COUNT(*) FROM pending_event_rows WHERE source_id=?1 AND model='fixture-missing-model' \
         AND user_prompt_start IS NOT NULL AND user_prompt_end=user_prompt_start \
         AND assistant_response_start IS NOT NULL AND assistant_response_end>=assistant_response_start",
        [job.source_id], |row| row.get(0)).map_err(|error| error.to_string())?;
    need!(enriched == 2, "missing-source fixture did not actually fill both old and new model/turn/answer associations");
    let event_fields = "id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,accounting_kind,reported_total_tokens,token_source_offset,legacy_tokens";
    let events = schema11_query_digest(&index.connection,
        &format!("SELECT {event_fields} FROM pending_event_rows WHERE source_id=?1 ORDER BY id"),
        [job.source_id], "missing pending events")?;
    let binding_fields = "event_id,source_id,raw_generation,raw_offset,user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,fingerprint";
    let bindings = schema11_query_digest(&index.connection,
        &format!("SELECT {binding_fields} FROM usage_ledger_pending_bindings WHERE source_id=?1 ORDER BY event_id"),
        [job.source_id], "missing pending bindings")?;
    fs::remove_file(&file).map_err(|error| error.to_string())?;
    if !enrichment {
        for table in ["pending_event_rows", "usage_ledger_pending_bindings"] {
            index.connection.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN legacy_extra BLOB; \
                UPDATE {table} SET legacy_extra=X'010203';"))
                .map_err(|error| error.to_string())?;
            let unknown_before = proof(&index_path)?;
            let rejected = validate_building_generation_commit_scope(&mut index.connection, generation, &home);
            need!(rejected.is_err_and(|error| error.contains("未知字段布局"))
                && proof(&index_path)? == unknown_before,
                "missing-source publication discarded or changed an unknown durable historical field");
            index.connection.execute_batch(&format!("ALTER TABLE {table} DROP COLUMN legacy_extra"))
                .map_err(|error| error.to_string())?;
        }
    }
    if enrichment {
        index.synchronize_event_enrichment(&home, &index_path, &mut Vec::new(), ExactSyncMode::Full)?;
    } else {
        index.sync(&home, &mut Vec::new())?;
    }
    let after: (i64, i64) = index.connection.query_row(
        "SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM event_rows WHERE source_id=?1", [job.source_id],
        |row| Ok((row.get(0)?, row.get(1)?))).map_err(|error| error.to_string())?;
    if after != (2, 175) {
        return Err(format!("missing-source enrichment discarded durable pending history: before=(2,175), publishedAfter={after:?}"));
    }
    need!(schema11_query_digest(&index.connection,
        &format!("SELECT {event_fields} FROM event_rows WHERE source_id=?1 ORDER BY id"),
        [job.source_id], "published missing events")? == events,
        "missing-source publication changed numeric IDs, known model or turn history");
    need!(schema11_query_digest(&index.connection,
        &format!("SELECT {binding_fields} FROM usage_ledger_bindings WHERE source_id=?1 ORDER BY event_id"),
        [job.source_id], "published missing bindings")? == bindings,
        "missing-source publication lost its durable raw binding identities");
    let unavailable: bool = index.connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM usage_ledger_sources WHERE source_id=?1 AND missing=1) \
         AND NOT EXISTS(SELECT 1 FROM usage_ledger_bindings WHERE source_id=?1 AND available<>0)",
        [job.source_id], |row| row.get(0)).map_err(|error| error.to_string())?;
    need!(unavailable && !file.exists(),
        format!("missing source still exposed an available excerpt binding after {}", if enrichment { "enrichment" } else { "ordinary sync" }));
    drop(index);
    let mut restarted = ExactUsageIndex::open(&home)?;
    restarted.sync(&home, &mut Vec::new())?;
    need!(restarted.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?.total_tokens == 175
        && schema11_query_digest(&restarted.connection,
            &format!("SELECT {event_fields} FROM event_rows WHERE source_id=?1 ORDER BY id"),
            [job.source_id], "restarted missing events")? == events,
        "missing-source history was not usable and stable after an ordinary restart");
    Ok(())
}
