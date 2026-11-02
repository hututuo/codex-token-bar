//! The legacy seal stores row bytes but not their schema. Bind those bytes to
//! exact producer contracts before accepting them. Unsigned artifacts are
//! preserved and rebuilt from a proven source; they are never signed in place.
use super::*;

struct SchemaContracts {
    current: String,
    accepted: Vec<String>,
}

fn contracts() -> Result<&'static SchemaContracts, String> {
    static CONTRACTS: std::sync::OnceLock<Result<SchemaContracts, String>> = std::sync::OnceLock::new();
    CONTRACTS.get_or_init(|| {
        #[derive(serde::Deserialize)]
        struct History { version: u32, schemas: Vec<Producer> }
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Producer { ddl_sha256: String, ddl: String }
        let historical: History = serde_json::from_str(include_str!("legacy_stage_schemas.json"))
            .map_err(|error| format!("精确 token 暂存格式契约无效：{error}"))?;
        if historical.version != 1 || historical.schemas.len() != 6 {
            return Err("精确 token 暂存格式契约版本无效".into());
        }
        let schema_digest = crate::core::business_store_container::schema_digest_for_ddl;
        let current = schema_digest(&staging_schema_sql(false)).map_err(|error| error.to_string())?;
        let mut accepted = vec![current.clone()];
        for producer in historical.schemas {
            if format!("{:x}", Sha256::digest(producer.ddl.as_bytes())) != producer.ddl_sha256 {
                return Err("精确 token 历史暂存格式契约摘要不匹配".into());
            }
            let digest = schema_digest(&producer.ddl).map_err(|error| error.to_string())?;
            if !accepted.contains(&digest) { accepted.push(digest); }
        }
        Ok(SchemaContracts { current, accepted })
    }).as_ref().map_err(Clone::clone)
}

pub(super) fn current_schema_digest() -> Result<String, String> {
    Ok(contracts()?.current.clone())
}

pub(super) fn accepted_schema_digests() -> Result<&'static [String], String> {
    Ok(&contracts()?.accepted)
}

#[cfg(not(test))]
pub(super) fn can_rebuild_unsealed(
    connection: &Connection,
    path: &Path,
    job: &FullRebuildJob,
    target_generation: i64,
) -> Result<bool, String> {
    use crate::core::business_store_container::StoreState;
    let store = crate::core::business_store_route::exact_store_spec(path)?;
    let snapshot = connection.unchecked_transaction().map_err(|error| error.to_string())?;
    let state = snapshot.store_state(&store).map_err(|error| error.to_string())?;
    let seal = snapshot.store_seal_observation(&store).map_err(|error| error.to_string())?;
    if state == StoreState::Sealed {
        if seal.is_none() {
            return Err("精确 token 已封存暂存缺少原封存证明；已保留暂存".into());
        }
        return Ok(false);
    }
    if seal.is_some() {
        return Err("精确 token 暂存状态与原封存证明矛盾；已保留暂存".into());
    }
    let proof = snapshot.store_proof_in_transaction(&store).map_err(|error| error.to_string())?;
    if !accepted_schema_digests()?.contains(&proof.schema_digest) { return Ok(false); }
    quick_check_staged(&snapshot)?;
    let count: i64 = snapshot.query_row("SELECT COUNT(*) FROM manifest", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    if count != 1 { return Ok(false); }
    let (source, session, parser, migration, target, size, modified, prefix):
        (String, String, String, String, i64, i64, String, Vec<u8>) = snapshot.query_row(
        "SELECT path,session_id,parser_revision,migration_revision,target_building_generation,size,modified_ns,prefix_sha256 FROM manifest",
        [], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?,
            row.get(4)?, row.get(5)?, row.get(6)?, row.get(7)?)))
        .map_err(|error| error.to_string())?;
    if source != job.path || session != job.session_id || target <= 0 || target > target_generation
        || ![STAGED_FULL_REBUILD_PARSER_REVISION, EXACT_SESSION_PARSER_REVISION,
            LEGACY_STAGED_PARSER_REVISION, LEGACY_SESSION_PARSER_REVISION,
            PAGINATED_V4_STAGED_REVISION, PAGINATED_V4_PARSER_REVISION,
            PAGINATED_V5_STAGED_REVISION, PAGINATED_V5_PARSER_REVISION,
            PRE_COMPACTION_STAGED_PARSER_REVISION,
            PRE_COMPACTION_SESSION_PARSER_REVISION].contains(&parser.as_str())
        || ![EVENT_ENRICHMENT_REVISION, PRE_COMPACTION_EVENT_ENRICHMENT_REVISION,
            "exact-source-rebuild-v1"].contains(&migration.as_str()) {
        return Ok(false);
    }
    if column_exists_checked(&snapshot, "manifest", "source_id")? {
        let (source_id, base): (i64, i64) = snapshot.query_row(
            "SELECT source_id,base_generation FROM manifest", [], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|error| error.to_string())?;
        if source_id != job.source_id || base < 0 || base > job.base_generation || target <= base {
            return Ok(false);
        }
    }
    let (Ok(size), Ok(modified_ns), Ok(prefix_sha256)) =
        (u64::try_from(size), modified.parse::<u128>(), <[u8; 32]>::try_from(prefix)) else {
        return Ok(false);
    };
    let signature = FileSignature { size, modified_ns, physical: None };
    let mut source = match RolloutReader::open(&job.file) {
        Ok(source) => source,
        Err(_) => return Ok(false),
    };
    // Rebuilding may only rely on the original prefix still being present.
    // The existing artifact itself remains preserved, including bad values.
    Ok(validate_same_file_prefix(&job.file, &mut source, signature, prefix_sha256).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn producer_schema_contracts_reject_semantic_column_swaps() {
        let source: serde_json::Value = serde_json::from_str(include_str!("legacy_stage_schemas.json")).unwrap();
        let contracts = accepted_schema_digests().unwrap();
        assert_eq!(contracts.len(), 6);
        for producer in source["schemas"].as_array().unwrap() {
            let ddl = producer["ddl"].as_str().unwrap();
            let expected = crate::core::business_store_container::schema_digest_for_ddl(ddl).unwrap();
            assert!(contracts.contains(&expected));
            let changed = format!("{ddl}\nALTER TABLE events RENAME COLUMN input_tokens TO swapped_tokens;\nALTER TABLE events RENAME COLUMN output_tokens TO input_tokens;\nALTER TABLE events RENAME COLUMN swapped_tokens TO output_tokens;");
            let actual = crate::core::business_store_container::schema_digest_for_ddl(&changed).unwrap();
            assert!(!contracts.contains(&actual), "changed schema matched producer {}", producer["firstProducer"]);
        }
        assert!(contracts.contains(&current_schema_digest().unwrap()));
    }
}
