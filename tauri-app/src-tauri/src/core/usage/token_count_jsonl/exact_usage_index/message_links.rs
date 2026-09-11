//! A resumable marker-only repair for indexes built without response_item
//! message support. Never changes numeric ledger fields or parser revisions.
use super::*;
use super::super::session_parser::scan_message_links;

pub(super) fn repair(db: &mut ManagedIndexConnection, home: &Path, warnings: &mut Vec<LocalDataWarning>) -> Result<(), String> {
    if !table_exists_checked(db, "usage_ledger_message_receipts")? {
        db.mark_receipt_dirty();
        db.execute_batch("CREATE TABLE usage_ledger_message_receipts(source_id INTEGER PRIMARY KEY,raw_generation INTEGER NOT NULL,revision INTEGER NOT NULL);").map_err(|e| e.to_string())?;
        db.mark_receipt_eligible();
    }
    let pending: Vec<(i64,String,String,u64,String,i64)> = db.prepare(r#"
        SELECT s.source_id,s.path,s.session_id,s.size,s.modified_ns,l.raw_generation
        FROM sources s JOIN usage_ledger_sources l USING(source_id)
        LEFT JOIN usage_ledger_message_receipts r ON r.source_id=s.source_id AND r.raw_generation=l.raw_generation AND r.revision=1
        WHERE s.deleted=0 AND l.missing=0 AND r.source_id IS NULL AND EXISTS(
            SELECT 1 FROM usage_ledger_bindings b JOIN event_rows e ON e.id=b.event_id
            WHERE b.source_id=s.source_id AND b.available=1 AND b.raw_generation=l.raw_generation
              AND b.raw_offset IS NOT NULL AND e.user_prompt_start IS NULL)
        ORDER BY s.modified_ns DESC
    "#).map_err(|e|e.to_string())?.query_map([],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)))
        .map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
    if pending.is_empty() { return Ok(()); }
    let canonical_home = canonical_codex_home(home)?;
    for (position,(source,path,session,size,modified,generation)) in pending.iter().enumerate() {
        let ResolvedSessionFile::Accepted(file) = resolve_file_within_codex_home(&canonical_home,Path::new(path),"缓存排行轮次补全",warnings) else { continue; };
        let Ok(before) = file_signature(&file) else { continue; };
        if !before.matches_stored(*size,modified) { continue; }
        let bindings: HashMap<u64,i64> = db.prepare("SELECT b.raw_offset,b.event_id FROM usage_ledger_bindings b JOIN event_rows e ON e.id=b.event_id WHERE b.source_id=?1 AND b.available=1 AND b.raw_generation=?2 AND b.raw_offset IS NOT NULL AND e.user_prompt_start IS NULL")
            .map_err(|e|e.to_string())?.query_map(params![source,generation],|r|Ok((r.get(0)?,r.get(1)?)))
            .map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
        super::super::update_precise_dashboard_progress(home,"backfillingModel","正在补全缓存排行榜的轮次关联；保留原有用量",position as u64,Some(pending.len() as u64));
        let scan = match scan_message_links(&file,*size,&bindings.keys().copied().collect()) {
            Ok(scan) => scan,
            Err(error) => { warnings.push(excerpt_warning(format!("缓存排行明细暂未补全：{error}"))); continue; }
        };
        // Incremental appends keep complete chunk proofs; the legacy whole-prefix
        // hash may describe an earlier checkpoint, so it is not an append proof.
        let stored: Vec<(u64,u64,Vec<u8>)> = db.prepare("SELECT chunk_index,byte_count,sha256 FROM source_chunks WHERE source_id=?1 ORDER BY chunk_index")
            .map_err(|e|e.to_string())?.query_map(params![source],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))
            .map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
        if stored.len()!=scan.chunks.len() || !stored.iter().zip(&scan.chunks).all(|((index,count,hash),chunk)|
            *index==chunk.index && *count==chunk.byte_count && hash.as_slice()==chunk.sha256.as_slice())
            || file_signature(&file).ok().as_ref()!=Some(&before) { continue; }
        db.mark_receipt_dirty();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate).map_err(|e|e.to_string())?;
        for (raw,prompt,assistant) in &scan.links {
            let Some(event) = bindings.get(raw) else { continue; };
            tx.execute("INSERT OR IGNORE INTO usage_ledger_turns VALUES(?1,?2,?3,?4)",params![source,generation,prompt.start,(1_i64<<62)+event]).map_err(|e|e.to_string())?;
            let turn: i64 = tx.query_row("SELECT turn_id FROM usage_ledger_turns WHERE source_id=?1 AND raw_generation=?2 AND raw_prompt=?3",params![source,generation,prompt.start],|r|r.get(0)).map_err(|e|e.to_string())?;
            tx.execute("UPDATE event_rows SET user_prompt_start=?1,user_prompt_end=?1,assistant_response_start=COALESCE(assistant_response_start,?2),assistant_response_end=COALESCE(assistant_response_end,?3) WHERE id=?4 AND user_prompt_start IS NULL",params![turn,assistant.map(|a|a.start),assistant.map(|a|a.end),event]).map_err(|e|e.to_string())?;
            tx.execute("UPDATE usage_ledger_bindings SET user_prompt_start=?1,user_prompt_end=?2,assistant_response_start=?3,assistant_response_end=?4 WHERE event_id=?5 AND available=1 AND raw_generation=?6",params![prompt.start,prompt.end,assistant.map(|a|a.start),assistant.map(|a|a.end),event,generation]).map_err(|e|e.to_string())?;
        }
        tx.execute("UPDATE sources SET current_user_prompt_start=?1,current_user_prompt_end=?2,assistant_response_start=?3,assistant_response_end=?4 WHERE source_id=?5",params![scan.prompt.map(|p|p.start),scan.prompt.map(|p|p.end),scan.assistant.map(|p|p.start),scan.assistant.map(|p|p.end),source]).map_err(|e|e.to_string())?;
        if !scan.links.is_empty() {
            let published = metadata_i64(&tx,"published_generation")?.unwrap_or(0);
            refresh_dashboard_turn_candidates_for_session(&tx,published,published,Some(session))?;
            let previous_revision = metadata_i64(&tx,"revision")?.unwrap_or(0);
            let revision = previous_revision.saturating_add(1);
            set_metadata(&tx,"revision",&revision.to_string())?;
            let dashboard_revision = metadata_i64(&tx,DASHBOARD_REVISION_KEY)?.unwrap_or(previous_revision).saturating_add(1);
            set_metadata(&tx,DASHBOARD_REVISION_KEY,&dashboard_revision.to_string())?;
        }
        tx.execute("INSERT OR REPLACE INTO usage_ledger_message_receipts VALUES(?1,?2,1)",params![source,generation]).map_err(|e|e.to_string())?;
        tx.commit().map_err(|e|e.to_string())?;
        db.mark_receipt_eligible();
    }
    Ok(())
}
