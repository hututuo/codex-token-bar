//! Exercise late physical evidence through the non-test, bound production path.
use super::*;

pub(super) fn verify(root: &Path) -> Result<serde_json::Value, String> {
    macro_rules! need {
        ($condition:expr, $message:expr) => {
            if !$condition { return Err($message.into()); }
        };
    }
    let existing_opens = crate::core::business_store_container::fixture_existing_open_count;
    let mut cold_reopens = 0;
    for case in ["valid", "invalid-version", "invalid-path"] {
        let home = root.join(format!("late-retention-{case}"));
        fs::create_dir_all(home.join("sessions")).map_err(|e| e.to_string())?;
        let event = serde_json::json!({
            "timestamp":"2026-10-28T00:00:00Z", "type":"event_msg",
            "payload":{"type":"token_count","info":{"last_token_usage":{
                "input_tokens":17,"cached_input_tokens":0,"output_tokens":0,"total_tokens":17}}}
        });
        fs::write(home.join("sessions/late-retention.jsonl"), format!("{event}\n"))
            .map_err(|e| e.to_string())?;
        let home = fs::canonicalize(home).map_err(|e| e.to_string())?;
        let mut index = ExactUsageIndex::open(&home)?;
        index.sync(&home, &mut Vec::new())?;
        let path = database_path(&home)?;
        let physical_paths = schema11_paths_for_namespace(&path, false);
        need!(!path.exists() && !physical_paths.2.exists(), "late retention needs namespace-only input");
        need!(!index.connection.preserves_legacy_exact_migration(&path)?
            && metadata_text(&index.connection, MIGRATION_RETENTION_KEY)?.is_none(),
            "late retention requires both receipts absent");
        record_successful_migration_retention(&index.connection, &path)?;
        need!(active_schema11_paths_on(&index.connection, &path)? == physical_paths,
            "absent legacy evidence selected isolated paths");

        let generation = index.published_generation()?;
        let total = index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?.total_tokens;
        need!(total == 17, "late retention initial accounting mismatch");
        let mut manifest = Schema11CandidateManifest {
            manifest_version: SCHEMA11_CANDIDATE_MANIFEST_VERSION,
            source_path: path.to_string_lossy().into_owned(),
            candidate_path: physical_paths.0.to_string_lossy().into_owned(),
            rollback_path: physical_paths.1.to_string_lossy().into_owned(),
            source_receipt: schema11_source_receipt_from_connection(&path, &index.connection)?,
            source_facts: None,
            phase: Schema11CandidatePhase::Switched,
        };
        if case == "invalid-version" { manifest.manifest_version += 1; }
        if case == "invalid-path" {
            manifest.candidate_path = path.with_file_name("wrong-candidate").to_string_lossy().into_owned();
        }
        schema11_store_manifest(&physical_paths.2, &manifest)?;
        let bytes = fs::read(&physical_paths.2).map_err(|e| e.to_string())?;
        let before = existing_opens();
        let result = record_successful_migration_retention(&index.connection, &path);
        if case == "valid" {
            result?;
            cold_reopens = existing_opens().saturating_sub(before);
            need!(cold_reopens > 0, "late physical manifest bypassed cold admission");
            need!(index.connection.preserves_legacy_exact_migration(&path)?,
                "late manifest did not register a valid owner receipt");
            let before = existing_opens();
            record_successful_migration_retention(&index.connection, &path)?;
            need!(active_schema11_paths_on(&index.connection, &path)? == schema11_paths_for_namespace(&path, true),
                "late manifest did not isolate A migration artifacts");
            need!(existing_opens() == before, "admitted late evidence reopened A on repeat");
        } else {
            need!(result.is_err(), "invalid late manifest was admitted");
            need!(!index.connection.preserves_legacy_exact_migration(&path)?,
                "invalid late manifest registered a preservation receipt");
        }
        need!(fs::read(&physical_paths.2).map_err(|e| e.to_string())? == bytes,
            "late retention rewrote physical legacy evidence");
        need!(metadata_text(&index.connection, MIGRATION_RETENTION_KEY)?.is_none(),
            "physical evidence fabricated a successful A migration receipt");
        need!(index.published_generation()? == generation
            && index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?.total_tokens == total,
            "late retention changed published accounting");
    }
    Ok(serde_json::json!({"sameHandle":true,"coldReopens":cold_reopens,"repeatReopens":0,
        "isolatedPaths":true,"physicalEvidencePreserved":true,"accountingPreserved":true,
        "noFabricatedSuccessReceipt":true,"invalidManifestsRejected":2}))
}
