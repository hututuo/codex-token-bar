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
