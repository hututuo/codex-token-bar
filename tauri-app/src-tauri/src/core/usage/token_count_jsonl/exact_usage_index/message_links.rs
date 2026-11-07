//! A resumable marker-only repair for indexes built without response_item
//! message support. Never changes numeric ledger fields or parser revisions.
use super::connection::ManagedIndexConnection;
use super::contracts::DASHBOARD_REVISION_KEY;
use super::projections::refresh_dashboard_turn_candidates_for_session;
use super::store_metadata::{metadata_i64, set_metadata, table_exists_checked};
use super::sources::{canonical_codex_home, lightweight_file_signature,
    resolve_file_within_codex_home, ResolvedSessionFile};
use super::{excerpt_warning, rollout_source};
use crate::models::LocalDataWarning;
use rusqlite::{params, TransactionBehavior};
use std::{collections::HashMap, path::Path};
#[cfg(test)]
use super::connection::Connection;
use super::super::session_parser::scan_message_links;

const PENDING_SOURCES_SQL: &str = r#"
        WITH message_repair_candidates AS MATERIALIZED (
            SELECT s.source_id,s.path,s.session_id,s.size,s.modified_ns,l.raw_generation
            FROM sources s JOIN usage_ledger_sources l USING(source_id)
            WHERE s.deleted=0 AND l.missing=0 AND NOT EXISTS(
                SELECT 1 FROM usage_ledger_message_receipts r
                WHERE r.source_id=s.source_id AND r.raw_generation=l.raw_generation AND r.revision=1)
        )
        SELECT p.source_id,p.path,p.session_id,p.size,p.modified_ns,p.raw_generation
        FROM message_repair_candidates p
        WHERE EXISTS(
            SELECT 1 FROM usage_ledger_bindings b JOIN event_rows e ON e.id=b.event_id
            WHERE b.source_id=p.source_id AND b.available=1 AND b.raw_generation=p.raw_generation
              AND b.raw_offset IS NOT NULL AND e.user_prompt_start IS NULL)
        ORDER BY p.modified_ns DESC
    "#;

pub(super) fn repair(db: &mut ManagedIndexConnection, home: &Path, warnings: &mut Vec<LocalDataWarning>) -> Result<(), String> {
    if !table_exists_checked(db, "usage_ledger_message_receipts")? {
        db.mark_receipt_dirty();
        db.execute_batch("CREATE TABLE usage_ledger_message_receipts(source_id INTEGER PRIMARY KEY,raw_generation INTEGER NOT NULL,revision INTEGER NOT NULL);").map_err(|e| e.to_string())?;
        db.mark_receipt_eligible();
    }
    let pending: Vec<(i64,String,String,u64,String,i64)> = db.prepare(PENDING_SOURCES_SQL).map_err(|e|e.to_string())?.query_map([],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)))
        .map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
    if pending.is_empty() { return Ok(()); }
    let canonical_home = canonical_codex_home(home)?;
    for (position,(source,path,session,size,modified,generation)) in pending.iter().enumerate() {
        let ResolvedSessionFile::Accepted(file) = resolve_file_within_codex_home(&canonical_home,Path::new(path),"缓存排行轮次补全",warnings) else { continue; };
        if !rollout_source::physical_path(&file).is_ok_and(|physical| !rollout_source::is_compressed(&physical)) { continue; }
        let Ok(Some(before)) = lightweight_file_signature(&file, None) else { continue; };
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
            || lightweight_file_signature(&file, None).ok().flatten().as_ref()!=Some(&before) { continue; }
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


#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE sources(source_id INTEGER PRIMARY KEY,path TEXT,session_id TEXT,size INTEGER,modified_ns TEXT,deleted INTEGER);
            CREATE TABLE usage_ledger_sources(source_id INTEGER PRIMARY KEY,raw_generation INTEGER NOT NULL,missing INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE usage_ledger_message_receipts(source_id INTEGER PRIMARY KEY,raw_generation INTEGER NOT NULL,revision INTEGER NOT NULL);
            CREATE TABLE usage_ledger_bindings(event_id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL,raw_generation INTEGER NOT NULL,raw_offset INTEGER,available INTEGER NOT NULL DEFAULT 1);
            CREATE INDEX usage_ledger_binding_raw ON usage_ledger_bindings(source_id,raw_generation,raw_offset);
            CREATE TABLE event_rows(id INTEGER PRIMARY KEY,user_prompt_start INTEGER);").unwrap();
        db
    }

    fn pending(db: &Connection) -> (Vec<i64>, i32) {
        let mut statement = db.prepare(PENDING_SOURCES_SQL).unwrap();
        let rows = statement.query_map([], |row| row.get(0)).unwrap()
            .collect::<rusqlite::Result<Vec<_>>>().unwrap();
        (rows, statement.get_status(rusqlite::StatementStatus::VmStep))
    }

    #[test]
    fn completed_message_receipts_do_not_rescan_event_payloads() {
        let db = fixture();
        db.execute_batch("INSERT INTO sources VALUES(1,'fixture','session',100,'10',0);
            INSERT INTO usage_ledger_sources VALUES(1,7,0);
            INSERT INTO usage_ledger_message_receipts VALUES(1,7,1);").unwrap();
        let small_steps = pending(&db).1;
        // All events already have prompt associations. A receipt must avoid
        // the event existence scan, including when there is no first match.
        db.execute_batch("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<50000)
            INSERT INTO event_rows SELECT x,x FROM n;
            INSERT INTO usage_ledger_bindings SELECT id,1,7,id,1 FROM event_rows;").unwrap();
        let (rows, large_steps) = pending(&db);
        assert!(rows.is_empty());
        assert!(large_steps <= small_steps + 100,
            "Completed sources must not scale with event rows: {small_steps} -> {large_steps}");
        // An obsolete generation is not an authorization to skip the scan.
        db.execute("UPDATE usage_ledger_message_receipts SET raw_generation=6", []).unwrap();
        db.execute("UPDATE event_rows SET user_prompt_start=NULL WHERE id=50000", []).unwrap();
        assert_eq!(pending(&db).0, vec![1]);
    }

    #[test]
    fn pending_message_repairs_respect_current_receipts_and_binding_availability() {
        let db = fixture();
        db.execute_batch("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10)
            INSERT INTO sources SELECT x,'path-'||x,'session-'||x,100,printf('%02d',x),0 FROM n;
            INSERT INTO usage_ledger_sources SELECT source_id,7,0 FROM sources;
            INSERT INTO event_rows SELECT source_id,NULL FROM sources;
            INSERT INTO usage_ledger_bindings SELECT id,id,7,id,1 FROM event_rows;
            INSERT INTO usage_ledger_message_receipts VALUES(1,7,1),(2,6,1),(3,7,0);
            UPDATE sources SET deleted=1 WHERE source_id=4;
            UPDATE usage_ledger_sources SET missing=1 WHERE source_id=5;
            UPDATE usage_ledger_bindings SET available=0 WHERE source_id=6;
            UPDATE usage_ledger_bindings SET raw_offset=NULL WHERE source_id=7;
            UPDATE event_rows SET user_prompt_start=1 WHERE id=8;
            UPDATE usage_ledger_bindings SET raw_generation=6 WHERE source_id=9;").unwrap();
        assert_eq!(pending(&db).0, vec![10,3,2]);
        db.execute_batch("INSERT OR REPLACE INTO usage_ledger_message_receipts VALUES(10,7,1),(3,7,1),(2,7,1)").unwrap();
        assert!(pending(&db).0.is_empty());
    }
}
