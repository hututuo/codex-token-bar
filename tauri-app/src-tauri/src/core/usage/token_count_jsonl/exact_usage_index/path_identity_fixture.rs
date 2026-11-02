//! The normal feature-gated CLI calls this after its production parser has
//! formed a complete sealed stage. Clone that real artifact into identities
//! emitted by the old router; do not manufacture a manifest or token rows.
use super::*;
use crate::core::business_store_container::{Container, StoreSpec};
use crate::core::business_store_route as route;

fn check(condition: bool, message: &str) -> Result<(), String> {
    if condition { Ok(()) } else { Err(message.to_owned()) }
}
fn fail(error: impl std::fmt::Display) -> String { error.to_string() }

fn configured_root(root: &Path) -> Result<PathBuf, String> {
    check(!root.exists(), "path fixture refuses an existing root")?;
    let physical = root.join("physical"); fs::create_dir_all(&physical).map_err(fail)?;
    #[cfg(unix)]
    {
        let alias = root.join("configured-alias");
        std::os::unix::fs::symlink(&physical, &alias).map_err(fail)?;
        Ok(alias)
    }
    #[cfg(windows)]
    {
        // No symlink privilege is necessary on Windows: normal versus
        // canonical verbatim spelling reproduces the released failure.
        let value = physical.to_str().ok_or("path fixture root is not UTF-8")?;
        Ok(PathBuf::from(if let Some(unc) = value.strip_prefix(r"\\?\UNC\") {
            format!(r"\\{unc}")
        } else { value.strip_prefix(r"\\?\").unwrap_or(value).to_owned() }))
    }
    #[cfg(not(any(unix, windows)))]
    { Err("path identity fixture requires a supported Unix or Windows host".into()) }
}

fn legacy_owner(path: &Path, candidate_index: Option<&Path>) -> Result<StoreSpec, String> {
    if let Some(index) = candidate_index {
        let family = route::source_identity("exact", index)?;
        let name = path.file_name().and_then(|name| name.to_str()).ok_or("candidate fixture filename missing")?;
        let mut digest = Sha256::new();
        digest.update(b"tokenbar-exact-stage-candidate-v2\0");
        digest.update(family.as_bytes()); digest.update(b"\0"); digest.update(name.as_bytes());
        StoreSpec::new("exact", format!("{:x}", digest.finalize()),
            format!("exact/staging/{family}/{name}")).map_err(fail)
    } else {
        let identity = route::source_identity("exact", path)?;
        StoreSpec::new("exact", identity.clone(), format!("exact/index/{identity}")).map_err(fail)
    }
}

pub(super) fn verify(
    home: &Path,
    main_index_path: &Path,
    original: &StagedFullRebuild,
    generation: i64,
) -> Result<(), String> {
    let configured = configured_root(&home.join("route-path-identity-fixture"))?;
    let container_path = route::container_path()?;
    let raw_before = fs::read(&original.job.file).map_err(fail)?;
    let source_owner = original.source_validation.as_ref().ok_or("path fixture source proof missing")?.stage.owner.clone();
    let source_proof = Container::open_read_only_existing(&container_path, StdDuration::from_secs(30))
        .map_err(fail)?.proof(&source_owner).map_err(fail)?;
    let main_reader = route::open_exact_registered_read_only(main_index_path, StdDuration::from_secs(1))?
        .ok_or("path fixture original index missing")?;
    let main_owner = main_reader.bound_store_spec().map_err(fail)?; drop(main_reader);
    let main_proof = Container::open_read_only_existing(&container_path, StdDuration::from_secs(30))
        .map_err(fail)?.proof(&main_owner).map_err(fail)?;

    let destination_path = home.join("route-path-identity-fixture/imported.sqlite3");
    route::clone_exact_store(main_index_path, &destination_path)?;
    let mut destination = route::open_exact_store(&destination_path, &[])?;
    for is_candidate in [false, true] {
        let missing = if is_candidate { "missing-candidate" } else { "missing-primary" };
        let index = configured.join(missing).join("cache/index.sqlite3");
        let stage_path = if is_candidate {
            staging_directory(&index).join(format!("{}.candidate-v2-{}.sqlite3",
                staging_database_digest(&original.job.path), "7".repeat(64)))
        } else { staging_database_path(&index, &original.job.path) };
        let legacy = legacy_owner(&stage_path, is_candidate.then_some(index.as_path()))?;
        let mut container = Container::open_existing(&container_path).map_err(fail)?;
        container.clone_store_namespace(&source_owner, &legacy).map_err(fail)?;
        container.seal_store(&legacy, 1_793_491_200.0).map_err(fail)?;
        let retained_proof = container.proof(&legacy).map_err(fail)?;
        check(retained_proof == source_proof, "legacy path fixture clone changed source content")?;
        drop(container);

        fs::create_dir_all(stage_path.parent().ok_or("path fixture parent missing")?).map_err(fail)?;
        let new_address = route::exact_store_spec(&stage_path)?;
        check(new_address.id != legacy.id, "path fixture failed to form the released identity change")?;
        check(!stage_path.exists(), "legacy path fixture unexpectedly has a physical stage")?;
        let witness = rusqlite::Connection::open(&container_path).map_err(fail)?;
        let version = witness.query_row("PRAGMA data_version", [], |row| row.get::<_, i64>(0)).map_err(fail)?;
        let reader = route::open_exact_registered_read_only(&stage_path, StdDuration::from_secs(1))?
            .ok_or("old A-only path namespace disappeared when parents materialized")?;
        check(reader.bound_store_spec().map_err(fail)? == legacy, "read-only lookup changed old store identity")?;
        check(reader.execute("DELETE FROM events", []).is_err(), "path lookup opened a writable connection")?;
        drop(reader);
        check(witness.query_row("PRAGMA data_version", [], |row| row.get::<_, i64>(0)).map_err(fail)? == version,
            "read-only path lookup changed persistent A content")?;
        drop(witness);

        if is_candidate {
            check(route::exact_stage_candidates(&index, &staging_database_digest(&original.job.path))?.contains(&stage_path),
                "legacy candidate family was omitted by the A-only inventory")?;
        }
        let resumed = stage_or_reuse_full_rebuild(&original.job, &index, generation, home, &mut Vec::new())
            .map_err(|error| match error { StagedFullRebuildError::Fatal(value) | StagedFullRebuildError::IncompleteSource(value) => value })?;
        check(resumed.database_path == stage_path && resumed.artifact_id == original.artifact_id,
            "legacy path recovery parsed a replacement instead of resuming the retained stage")?;
        check(resumed.source_validation.as_ref().ok_or("resumed path proof missing")?.stage.owner == legacy,
            "stage validation did not pin the retained namespace identity")?;
        // Make the physical directory disappear after validation. Both the
        // importer and seal CAS must retain the selected StoreSpec.
        fs::remove_dir_all(configured.join(missing)).map_err(fail)?;
        import_staged_full_rebuild(&mut destination, generation, &resumed, ExactSyncMode::Full)?;
        let imported_rows = schema11_query_digest(&destination,
            "SELECT * FROM pending_event_rows ORDER BY id", [], "path fixture pending history")?;
        let imported_ledger = ledger::protected_table_digests(&destination)?;
        import_staged_full_rebuild(&mut destination, generation, &resumed, ExactSyncMode::Full)?;
        check(schema11_query_digest(&destination,
            "SELECT * FROM pending_event_rows ORDER BY id", [], "path fixture repeated pending history")? == imported_rows
            && ledger::protected_table_digests(&destination)? == imported_ledger,
            "repeated recovered stage import changed durable history")?;
        let container = Container::open_read_only_existing(&container_path, StdDuration::from_secs(30)).map_err(fail)?;
        check(container.proof(&legacy).map_err(fail)? == retained_proof && !container.is_registered(&new_address).map_err(fail)?,
            "legacy path recovery rewrote its original or registered an empty competing owner")?;
    }
    drop(destination);
    let container = Container::open_read_only_existing(&container_path, StdDuration::from_secs(30)).map_err(fail)?;
    check(container.proof(&source_owner).map_err(fail)? == source_proof
        && container.proof(&main_owner).map_err(fail)? == main_proof
        && fs::read(&original.job.file).map_err(fail)? == raw_before,
        "path fixture changed original published history, source stage or raw file")
}

/// A stronger formed-state regression. Both inputs come from the production
/// parser in the surrounding fixture: an old complete 120-token prefix and a
/// later complete 175-token prefix. Only the old path-routing outcome is
/// reproduced; no event, manifest, receipt or checkpoint is hand-written.
pub(super) fn verify_competing(
    home: &Path,
    main_index_path: &Path,
    old: &StagedFullRebuild,
    newer: &StagedFullRebuild,
    generation: i64,
) -> Result<(), String> {
    let configured = configured_root(&home.join("route-competing-path-fixture"))?;
    let index = configured.join("missing/cache/index.sqlite3");
    let primary = staging_database_path(&index, &old.job.path);
    let old_routed_owner = legacy_owner(&primary, None)?;
    let old_source_owner = &old.source_validation.as_ref().ok_or("old formed stage proof missing")?.stage.owner;
    let new_source_owner = &newer.source_validation.as_ref().ok_or("new formed stage proof missing")?.stage.owner;
    let a = route::container_path()?;
    let raw = fs::read(&old.job.file).map_err(fail)?;
    let mut container = Container::open_existing(&a).map_err(fail)?;
    let old_proof = container.clone_store_namespace(old_source_owner, &old_routed_owner).map_err(fail)?;
    container.seal_store(&old_routed_owner, 1_793_491_200.0).map_err(fail)?;
    fs::create_dir_all(primary.parent().ok_or("competing stage parent missing")?).map_err(fail)?;
    let new_routed_owner = legacy_owner(&primary, None)?;
    check(old_routed_owner.id != new_routed_owner.id && new_routed_owner == route::exact_store_spec(&primary)?,
        "competing fixture did not reproduce both real legacy router identities")?;
    let new_proof = container.clone_store_namespace(new_source_owner, &new_routed_owner).map_err(fail)?;
    container.seal_store(&new_routed_owner, 1_793_491_201.0).map_err(fail)?;
    check(old_proof != new_proof, "competing fixture requires distinct complete histories")?;
    drop(container);
    for (owner, expected_count, expected_tokens) in [(&old_routed_owner, 1, 120), (&new_routed_owner, 2, 175)] {
        let reader = route::open_registered_store_read_only("exact", &owner.source_identity, &owner.logical_path,
            StdDuration::from_secs(1))?.ok_or("formed stage owner missing")?;
        check(reader.query_row("SELECT COUNT(*),SUM(tokens) FROM events", [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))).map_err(fail)? == (expected_count, expected_tokens),
            "competing fixture did not retain the production 120/175 stage histories")?;
    }
    let destination_path = home.join("route-competing-path-fixture/published.sqlite3");
    route::clone_exact_store(main_index_path, &destination_path)?;
    let mut destination = route::open_exact_store(&destination_path, &[])?;
    let main_owner = destination.bound_store_spec().map_err(fail)?;
    let published_before = schema11_query_digest(&destination,
        "SELECT * FROM event_rows ORDER BY id", [], "competing path published baseline")?;
    let resumed = stage_or_reuse_full_rebuild(&newer.job, &index, generation, home, &mut Vec::new())
        .map_err(|error| match error { StagedFullRebuildError::Fatal(value) | StagedFullRebuildError::IncompleteSource(value) => value })?;
    check(resumed.artifact_id == newer.artifact_id && resumed.database_path == primary
        && resumed.source_validation.as_ref().ok_or("competing stage proof missing")?.stage.owner == new_routed_owner,
        "competing histories were not resumed as the complete production 175-token owner")?;
    fs::remove_dir_all(configured.join("missing")).map_err(fail)?;
    import_staged_full_rebuild(&mut destination, generation, &resumed, ExactSyncMode::Full)?;
    check(schema11_query_digest(&destination, "SELECT * FROM event_rows ORDER BY id", [],
        "competing path retained lastGood")? == published_before,
        "resuming a competing stage changed published history before publication")?;
    let pending_rows = schema11_query_digest(&destination,
        "SELECT * FROM pending_event_rows ORDER BY id", [], "competing path complete pending")?;
    check(destination.query_row("SELECT COUNT(*),SUM(tokens) FROM pending_event_rows", [],
        |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))).map_err(fail)? == (2,175),
        "competing path import discarded one complete consumption observation")?;
    prepare_scan_temp_tables(&destination)?;
    destination.execute("INSERT INTO exact_seen_files(path) VALUES(?1)", [&newer.job.path]).map_err(fail)?;
    finalize_generation(&mut destination, generation, home, &mut Vec::new(),
        ExactScanCompleteness::default(), ExactSyncMode::Full, true)?;
    check(schema11_query_digest(&destination, "SELECT * FROM event_rows ORDER BY id", [],
        "competing path published complete history")? == pending_rows,
        "competing path publication changed typed durable event history")?;
    drop(destination);
    let reader = route::open_registered_store_read_only("exact", &main_owner.source_identity, &main_owner.logical_path,
        StdDuration::from_secs(1))?.ok_or("competing path reopened main owner missing")?;
    check(reader.query_row("SELECT COALESCE(SUM(tokens),0) FROM canonical_usage_events", [],
        |row| row.get::<_, i64>(0)).map_err(fail)? == 175,
        "competing path history is not visible after reopening its published owner")?;
    drop(reader);
    let container = Container::open_read_only_existing(&a, StdDuration::from_secs(30)).map_err(fail)?;
    check(container.proof(&old_routed_owner).map_err(fail)? == old_proof
        && container.proof(&new_routed_owner).map_err(fail)? == new_proof
        && fs::read(&old.job.file).map_err(fail)? == raw,
        "competing path recovery changed either formed original namespace or raw source")
}
