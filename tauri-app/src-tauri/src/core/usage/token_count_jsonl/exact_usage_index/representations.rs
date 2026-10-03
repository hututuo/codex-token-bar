//! Additive storage metadata. Never rewrites events, counters or checkpoints.
use super::*;
const REVISION: &str = "rollout-storage-v1";

pub(super) fn validate(db: &Connection) -> Result<(), String> {
    if metadata_i64(db,"schema_version")? != Some(CURRENT_SCHEMA_VERSION) {return Ok(());}
    if metadata_text(db,"representation_revision")?.as_deref()!=Some(REVISION)
        || !table_exists_checked(db,"source_representations")? {
        return Err("表示层版本与结构不一致，已保留原库".into());
    }
    Ok(())
}
pub(super) fn migrate(db: &mut Connection, index_path: &Path, existed_before: bool) -> Result<(),String> {
    if metadata_i64(db,"schema_version")?==Some(CURRENT_SCHEMA_VERSION) {return validate(db);}
    if metadata_i64(db,"schema_version")?!=Some(ACCOUNTING_SCHEMA_VERSION) {
        return Err("表示层迁移需要已支持的会计结构；已保留原库".into());
    }
    let backup=if existed_before {
        let mut name=index_path.as_os_str().to_os_string();
        name.push(".schema13-before-representations.sqlite");
        let backup=PathBuf::from(name);
        if backup.exists() {
            let saved=sqlite::open_read_only(&backup,StdDuration::from_secs(5)).map_err(|e|e.to_string())?;
            if metadata_i64(&saved,"schema_version")?!=Some(ACCOUNTING_SCHEMA_VERSION) {
                return Err("升级前备份版本不一致，已保留原库与备份".into());
            }
            quick_check_index(&saved,Some(&backup))?;
        } else {
            schema11_migration_capacity(index_path)?;
            let temporary=backup.with_extension(format!("pending-{}",uuid::Uuid::new_v4()));
            let copied=(||{
                schema11_copy_candidate(index_path,&temporary)?;
                fs::rename(&temporary,&backup).map_err(|e|e.to_string())?;
                schema11_sync_parent(&backup)
            })();
            if copied.is_err() {let _=fs::remove_file(&temporary);}
            copied?;
        }
        Some(backup)
    } else {None};
    let tx=db.transaction_with_behavior(TransactionBehavior::Immediate).map_err(|e|e.to_string())?;
    tx.execute_batch(r#"
        CREATE TABLE source_representations(
            source_id INTEGER PRIMARY KEY REFERENCES sources(source_id) ON DELETE CASCADE,
            physical_path TEXT NOT NULL, storage_format TEXT NOT NULL,
            physical_size INTEGER NOT NULL, physical_stamp TEXT NOT NULL,
            logical_size INTEGER NOT NULL, modified_ns TEXT NOT NULL,
            verification TEXT NOT NULL);
    "#).map_err(|e|format!("无法增加会话表示结构：{e}"))?;
    set_metadata(&tx,"representation_revision",REVISION)?;
    if let Some(backup)=backup {set_metadata(&tx,"representation_upgrade_backup",&backup.to_string_lossy())?;}
    set_metadata(&tx,"schema_version",&CURRENT_SCHEMA_VERSION.to_string())?;
    tx.commit().map_err(|e|format!("无法提交会话表示迁移：{e}"))
}

pub(super) fn reuse_complete(
    db: &Connection, path: &str, reader: &RolloutReader, signature: FileSignature,
    generation: i64,
) -> Result<bool,String> {
    if !reader.fast_reuse_supported() {return Ok(false);}
    // Normal current-parser scans need no legacy enrichment receipt. A missing
    // receipt is reusable only after the existing enrichment owner has finished;
    // a present but stale/incomplete receipt must still take the proof path.
    let ready: Option<i64>=db.query_row(
        "SELECT s.source_id FROM sources s WHERE s.path=?1
            AND s.append_ready=1 AND s.resume_offset=s.size
            AND s.size=?2 AND s.modified_ns=?3
            AND NOT EXISTS(SELECT 1 FROM pending_sources p WHERE p.source_id=s.source_id)
            AND (EXISTS(SELECT 1 FROM event_enrichment_sources e WHERE e.path=s.path
                AND e.revision=?4 AND e.parser_revision=?5
                AND e.completed_size=s.size AND e.completed_prefix_sha256=s.prefix_sha256)
                OR (NOT EXISTS(SELECT 1 FROM event_enrichment_sources e WHERE e.path=s.path)
                    AND EXISTS(SELECT 1 FROM metadata WHERE key='event_enrichment_revision' AND value=?4)))",
        params![path,checked_i64(signature.size,"逻辑来源大小")?,signature.modified_ns.to_string(),EVENT_ENRICHMENT_REVISION,STAGED_FULL_REBUILD_PARSER_REVISION],
        |r|r.get(0)).optional().map_err(|e|format!("无法核查压缩来源旧账覆盖：{e}"))?;
    let Some(source)=ready else {return Ok(false);};
    // No guessed new events or blanket availability updates.
    let missing: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM usage_ledger_sources WHERE source_id=?1 AND missing=1)",params![source],|r|r.get(0)).map_err(|e|e.to_string())?;
    let physical=reader.metadata().map_err(|e|e.to_string())?;
    let stamp=signature.physical.map(|s|s.encode()).unwrap_or_default();
    let stable: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM source_representations WHERE source_id=?1 AND physical_path=?2 AND physical_stamp=?3 AND physical_size=?4 AND logical_size=?5)",params![source,reader.physical_path().to_string_lossy(),stamp,checked_i64(physical.len(),"压缩物理大小")?,checked_i64(signature.size,"逻辑来源大小")?],|r|r.get(0)).map_err(|e|e.to_string())?;
    if stable && !missing {return Ok(true);}
    if file_signature(Path::new(path))? != signature {return Err(format!("压缩来源在关联前变化：{path}"));}
    let proved: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM source_observations WHERE path=?1 AND size=?2 AND modified_ns=?3 AND physical_stamp=?4)
        AND NOT EXISTS(SELECT 1 FROM source_representations r JOIN sources s USING(source_id) WHERE s.path=?1 AND r.verification='metadata_only')",
        params![path,checked_i64(signature.size,"逻辑来源大小")?,signature.modified_ns.to_string(),stamp],|r|r.get(0)).map_err(|e|e.to_string())?;
    let verification=if proved {"verified_full"}else{"metadata_only"};
    let tx=db.unchecked_transaction().map_err(|e|e.to_string())?;
    tx.execute("INSERT INTO source_representations VALUES(?1,?2,'zstd',?3,?4,?5,?6,?7)
        ON CONFLICT(source_id) DO UPDATE SET physical_path=excluded.physical_path,storage_format='zstd',
        physical_size=excluded.physical_size,physical_stamp=excluded.physical_stamp,
        logical_size=excluded.logical_size,modified_ns=excluded.modified_ns,verification=excluded.verification",
        params![source,reader.physical_path().to_string_lossy(),checked_i64(physical.len(),"压缩物理大小")?,stamp,checked_i64(signature.size,"逻辑来源大小")?,signature.modified_ns.to_string(),verification]).map_err(|e|e.to_string())?;
    record_source_observation(&tx,path,signature)?;
    if !proved {
        tx.execute("UPDATE usage_ledger_bindings SET available=0 WHERE source_id=?1 AND available<>0",params![source]).map_err(|e|e.to_string())?;
    }
    tx.execute("UPDATE usage_ledger_sources SET missing=0 WHERE source_id=?1 AND missing<>0",params![source]).map_err(|e|e.to_string())?;
    // Preserve the old raw generation/offsets and numeric generation.
    let _=generation;
    tx.commit().map_err(|e|e.to_string())?;
    Ok(true)
}


// Metadata is sufficient for old numeric history, never for displaying old raw text.
pub(super) fn verify_excerpt_source(db: &Connection, path: &Path) -> Result<bool,String> {
    let row: Option<(i64,u64,String,String)> = db.query_row(
        "SELECT s.source_id,s.size,s.modified_ns,r.verification FROM sources s JOIN source_representations r USING(source_id) WHERE s.path=?1",
        params![path.to_string_lossy()], |r| Ok((r.get(0)?,nonnegative_u64(r.get::<_,i64>(1)?),r.get(2)?,r.get(3)?))
    ).optional().map_err(|e|e.to_string())?;
    let Some((source,size,modified,verification))=row else {return Ok(true);};
    if verification!="metadata_only" {return Ok(true);}
    let mut reader=RolloutReader::open(path).map_err(|e|e.to_string())?;
    let before=file_signature_from_handle(&reader,path)?;
    if !before.matches_stored(size,&modified) {return Ok(false);}
    let mut stmt=db.prepare("SELECT chunk_index,byte_count,sha256 FROM source_chunks WHERE source_id=?1 ORDER BY chunk_index").map_err(|e|e.to_string())?;
    let chunks=stmt.query_map(params![source],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?,r.get::<_,Vec<u8>>(2)?))).map_err(|e|e.to_string())?
        .collect::<Result<Vec<_>,_>>().map_err(|e|e.to_string())?;
    if chunks.len() as u64 != size.div_ceil(EXACT_INDEX_CHUNK_SIZE) {return Ok(false);}
    for (expected_index,(index,bytes,hash)) in chunks.iter().enumerate() {
        if *index!=expected_index as i64 || *bytes<=0 {return Ok(false);}
        let expected_bytes=(size.saturating_sub(expected_index as u64 * EXACT_INDEX_CHUNK_SIZE)).min(EXACT_INDEX_CHUNK_SIZE);
        if *bytes as u64 != expected_bytes {return Ok(false);}
        if hash_file_chunk(&mut reader,path,*index as u64,*bytes as u64)?.sha256.as_slice()!=hash.as_slice() {return Ok(false);}
    }
    reader.validate_decoded_end(size).map_err(|e|e.to_string())?;
    if file_signature_from_handle(&reader,path)?!=before || file_signature(path)?!=before {return Ok(false);}
    let tx=db.unchecked_transaction().map_err(|e|e.to_string())?;
    tx.execute("UPDATE source_representations SET verification='verified_full' WHERE source_id=?1",params![source]).map_err(|e|e.to_string())?;
    tx.execute("UPDATE usage_ledger_bindings SET available=1 WHERE source_id=?1 AND raw_generation=(SELECT raw_generation FROM usage_ledger_sources WHERE source_id=?1 AND missing=0)",params![source]).map_err(|e|e.to_string())?;
    tx.commit().map_err(|e|e.to_string())?;
    Ok(true)
}
