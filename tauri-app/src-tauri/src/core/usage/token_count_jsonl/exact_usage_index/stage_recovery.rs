//! Compatibility at the private-stage boundary, never in published accounting.
//! Only a fully verified current-contract prefix can be superseded by a longer
//! reconciliation job. The caller archives it before building the replacement.
use super::*;

pub(super) fn is_superseded_bounded_stage(
    path: &Path,
    job: &FullRebuildJob,
    target_generation: i64,
) -> Result<bool, String> {
    if !job.event_enrichment || job.expected_published_prefix_sha256.is_some() {
        return Ok(false);
    }
    let connection = open_read_only_index(path, StdDuration::from_secs(1))?;
    for column in ["manifest_schema_version", "physical_stamp", "size", "modified_ns", "complete"] {
        if !column_exists_checked(&connection, "manifest", column)? { return Ok(false); }
    }
    let count: i64 = connection.query_row("SELECT COUNT(*) FROM manifest", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    if count != 1 { return Ok(false); }
    let manifest: (i64, i64, String, Option<String>, i64) = connection.query_row(
        "SELECT manifest_schema_version,size,modified_ns,physical_stamp,complete FROM manifest",
        [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))
        .map_err(|e| e.to_string())?;
    if manifest.0 != STAGING_MANIFEST_SCHEMA_VERSION || manifest.4 != 1 { return Ok(false); }
    let (Ok(size), Ok(modified_ns)) = (u64::try_from(manifest.1), manifest.2.parse::<u128>()) else {
        return Ok(false);
    };
    if size >= job.signature.size { return Ok(false); }
    let bounded = FullRebuildJob {
        signature: FileSignature { size, modified_ns,
            physical: manifest.3.as_deref().and_then(PhysicalFileStamp::decode) },
        ..job.clone()
    };
    // Do not relax the validator: it still proves source/accounting identity,
    // target and base generation, bytes, row counts, parser state, fingerprints,
    // chunks and the current source's exact original prefix. A larger source
    // alone is not evidence that an old private artifact is safe to replace.
    Ok(validated_staged_full_rebuild(&connection, path, &bounded, target_generation, None)?.is_some())
}

#[cfg(any(test, feature = "business-store-fixture"))]
pub(super) fn verify_bounded_stage(root: &Path) -> Result<serde_json::Value, String> {
    macro_rules! check { ($v:expr) => { $v.map_err(|e| e.to_string())? }; }
    macro_rules! require { ($v:expr, $m:literal) => { if !$v { return Err($m.into()); } }; }
    check!(fs::create_dir_all(root.join("index")));
    let root = check!(fs::canonicalize(root));
    let source = root.join("recovery.jsonl");
    require!(!source.exists(), "refusing to overwrite a stage recovery source");
    let line = |time: &str, tokens: i64| format!("{}\n", serde_json::json!({
        "timestamp":time,"type":"event_msg","payload":{"type":"token_count",
        "info":{"last_token_usage":{"input_tokens":tokens,"cached_input_tokens":0,
        "output_tokens":0,"total_tokens":tokens}}}}));
    let first = line("2026-06-17T09:00:00Z",120);
    check!(fs::write(&source, &first));
    let bounded_signature = file_signature(&source)?;
    let complete_source = first + &line("2026-06-17T09:01:00Z",55);
    check!(fs::write(&source, &complete_source));
    let index = root.join("index/history.sqlite");
    let job = FullRebuildJob { file: source.clone(), path: source.to_string_lossy().into_owned(),
        session_id: "bounded-recovery".into(), source_id: 42, base_generation: 1,
        base_resume_offset: Some(bounded_signature.size), base_prefix_sha256: Some([0;32]),
        signature: bounded_signature, event_enrichment: true,
        expected_published_prefix_sha256: Some([0;32]) };
    // The production caller prepares the stage family before scheduling jobs.
    // Exercise that same setup in both the raw-file test and the A-route probe.
    ensure_staging_directory(&index)?;
    let mut warnings = Vec::new();
    let explain = |e| match e { StagedFullRebuildError::IncompleteSource(s) | StagedFullRebuildError::Fatal(s) => s };
    let old = stage_or_reuse_full_rebuild(&job, &index, 2, &root, &mut warnings).map_err(explain)?;
    require!(old.event_count == 1, "bounded stage did not commit the original prefix alone");
    let original_artifact = old.artifact_id.clone();
    let replacement = FullRebuildJob { signature: file_signature(&source)?,
        expected_published_prefix_sha256: None, ..job.clone() };
    let new = stage_or_reuse_full_rebuild(&replacement, &index, 2, &root, &mut warnings).map_err(explain)?;
    require!(new.event_count == 2 && new.artifact_id != original_artifact,
        "longer reconciliation did not replace the verified bounded stage");
    require!(check!(fs::read(&source)) == complete_source.as_bytes(), "recovery modified source bytes");
    #[cfg(not(test))]
    {
        let raw = check!(rusqlite::Connection::open(crate::core::business_store_route::container_path()?));
        let found: i64 = check!(raw.query_row("SELECT COUNT(*) FROM tb_stores WHERE logical_path LIKE '%.preserved.%'", [], |r|r.get(0)));
        require!(found > 0, "old private stage was not retained in A");
    }
    #[cfg(test)]
    require!(new.database_path.parent().unwrap().join("preserved").is_dir(), "old private stage was not retained");
    // An unknown/future manifest must not take the supersession path even if
    // its source grows. Preserve both it and the original source for recovery.
    {
        let stage = open_index_connection(&new.database_path, false, false)?;
        check!(stage.execute("UPDATE manifest SET manifest_schema_version=?1", [STAGING_MANIFEST_SCHEMA_VERSION+1]));
    }
    let expanded = complete_source + &line("2026-06-17T09:02:00Z",20);
    check!(fs::write(&source, &expanded));
    let future_job = FullRebuildJob { signature:file_signature(&source)?, ..replacement };
    require!(stage_or_reuse_full_rebuild(&future_job, &index, 2, &root, &mut warnings).is_err(),
        "future stage contract was silently replaced");
    require!(existing_regular_index(&new.database_path)?, "future stage was removed");
    require!(check!(fs::read(&source)) == expanded.as_bytes(), "failed recovery changed source bytes");
    Ok(serde_json::json!({"name":"bounded-stage-replacement","status":"PASS",
        "boundedEvents":1,"replacementEvents":2,"oldStagePreserved":true,
        "futureStageBlocked":true,"sourceBytesUnchanged":true}))
}

#[test]
fn verified_bounded_stage_is_preserved_before_larger_reconciliation_but_future_stage_blocks() {
    let root=std::env::temp_dir().join(format!("tokenbar-bounded-stage-{}",Uuid::new_v4()));
    let result=verify_bounded_stage(&root);
    let _=fs::remove_dir_all(&root);
    result.unwrap();
}
