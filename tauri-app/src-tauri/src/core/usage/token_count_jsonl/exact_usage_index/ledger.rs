//! Published event_rows remain the sole numeric ledger. Full scans reconcile
//! into pending rows before projections are built; publication and raw bindings
//! commit together. Missing source text never authorizes removing consumption.
use super::*;
use rusqlite::types::Value;

const REVISION: &str = "1";
const FIELDS: &str = "id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,accounting_kind,reported_total_tokens,token_source_offset,legacy_tokens";
const BINDINGS: &str = "event_id,source_id,raw_generation,raw_offset,user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,fingerprint,available";
const GROUP_BASE: i64 = 1_i64 << 62;

pub(super) fn validate(db: &Connection) -> Result<(),String> {
    if !table_exists_checked(db,"usage_ledger_meta")? {
        if table_exists_checked(db,"metadata")? && metadata_i64(db,"schema_version")? == Some(13) {
            return Err("历史账本标记与结构不一致，已保留原库；不会从当前原文覆盖重建".into());
        }
        return Ok(());
    }
    let revision: Option<String> = db.query_row("SELECT value FROM usage_ledger_meta WHERE key='revision'",[],|r|r.get(0)).optional().map_err(|e|e.to_string())?;
    if revision.as_deref()!=Some(REVISION) { return Err("历史账本版本高于或不符合当前支持范围，已保留原库".into()); }
    for table in ["usage_ledger_sources","usage_ledger_bindings","usage_ledger_pending_bindings","usage_ledger_pending_missing","usage_ledger_unresolved","usage_ledger_turns","usage_ledger_corrections"] {
        if !table_exists_checked(db,table)? { return Err(format!("历史账本缺少 {table}，已保留原库")); }
    }
    Ok(())
}

pub(super) fn install(db: &Connection) -> Result<(),String> {
    validate(db)?;
    if table_exists_checked(db,"usage_ledger_meta")? { return Ok(()); }
    let raw = if column_exists_checked(db,"event_rows","token_source_offset")? { "e.token_source_offset" } else { "NULL" };
    let tx = db.unchecked_transaction().map_err(|e|e.to_string())?;
    tx.execute_batch(&format!(r#"
        CREATE TABLE usage_ledger_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE usage_ledger_corrections(source_id INTEGER NOT NULL,event_id INTEGER NOT NULL,
            generation INTEGER NOT NULL,raw_offset INTEGER NOT NULL,parser_revision TEXT NOT NULL,
            old_tokens INTEGER NOT NULL,new_tokens INTEGER NOT NULL,reason TEXT NOT NULL,
            PRIMARY KEY(source_id,event_id,generation)) WITHOUT ROWID;
        CREATE TABLE usage_ledger_sources(source_id INTEGER PRIMARY KEY,raw_generation INTEGER NOT NULL,missing INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE usage_ledger_bindings(
            event_id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL,raw_generation INTEGER NOT NULL,raw_offset INTEGER,
            user_prompt_start INTEGER,user_prompt_end INTEGER,assistant_response_start INTEGER,assistant_response_end INTEGER,
            fingerprint BLOB,available INTEGER NOT NULL DEFAULT 1);
        CREATE INDEX usage_ledger_binding_identity ON usage_ledger_bindings(source_id,fingerprint);
        CREATE INDEX usage_ledger_binding_raw ON usage_ledger_bindings(source_id,raw_generation,raw_offset);
        CREATE TABLE usage_ledger_pending_missing(source_id INTEGER PRIMARY KEY REFERENCES pending_sources(source_id) ON DELETE CASCADE);
        CREATE TABLE usage_ledger_pending_bindings(
            event_id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL REFERENCES pending_sources(source_id) ON DELETE CASCADE,
            raw_generation INTEGER NOT NULL,raw_offset INTEGER,user_prompt_start INTEGER,user_prompt_end INTEGER,
            assistant_response_start INTEGER,assistant_response_end INTEGER,fingerprint BLOB,available INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE usage_ledger_unresolved(
            source_id INTEGER NOT NULL,generation INTEGER NOT NULL,raw_position INTEGER NOT NULL,
            timestamp INTEGER NOT NULL,tokens INTEGER NOT NULL,input_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER,model TEXT,accounting_kind INTEGER NOT NULL,
            reported_total_tokens INTEGER,legacy_tokens INTEGER,fingerprint BLOB,reason TEXT NOT NULL,
            PRIMARY KEY(source_id,generation,raw_position)) WITHOUT ROWID;
        CREATE INDEX usage_ledger_unresolved_identity ON usage_ledger_unresolved(source_id,fingerprint);
        CREATE TABLE usage_ledger_turns(source_id INTEGER NOT NULL,raw_generation INTEGER NOT NULL,raw_prompt INTEGER NOT NULL,turn_id INTEGER NOT NULL,
            PRIMARY KEY(source_id,raw_generation,raw_prompt)) WITHOUT ROWID;
        INSERT INTO usage_ledger_sources SELECT source_id,last_seen_generation,deleted FROM sources;
        INSERT INTO usage_ledger_bindings({BINDINGS})
        SELECT e.id,e.source_id,s.last_seen_generation,{raw},e.user_prompt_start,e.user_prompt_end,
            e.assistant_response_start,e.assistant_response_end,NULL,1 FROM event_rows e JOIN sources s USING(source_id);
        INSERT INTO usage_ledger_pending_bindings({BINDINGS})
        SELECT e.id,e.source_id,p.target_generation,{raw},e.user_prompt_start,e.user_prompt_end,
            e.assistant_response_start,e.assistant_response_end,NULL,1 FROM pending_event_rows e JOIN pending_sources p USING(source_id);
        INSERT OR IGNORE INTO usage_ledger_turns SELECT e.source_id,s.last_seen_generation,e.user_prompt_start,e.user_prompt_start
            FROM event_rows e JOIN sources s USING(source_id) WHERE e.user_prompt_start IS NOT NULL;
        INSERT INTO usage_ledger_meta VALUES('revision','{REVISION}');
    "#)).map_err(|e|format!("无法安装持久用量账本：{e}"))?;
    tx.commit().map_err(|e|e.to_string())
}

fn read_values(row: &rusqlite::Row<'_>) -> rusqlite::Result<Vec<Value>> {
    (0..18).map(|i|row.get(i)).collect()
}
fn number(row: &[Value],i: usize) -> Result<i64,String> {
    match row.get(i) { Some(Value::Integer(v))=>Ok(*v),_=>Err(format!("账本字段 {i} 不是整数")) }
}
fn optional(row: &[Value],i: usize) -> Option<i64> {
    match row.get(i) { Some(Value::Integer(v))=>Some(*v),_=>None }
}
fn write_pending(db: &Connection,row: &[Value]) -> Result<(),String> {
    db.execute(&format!("INSERT INTO pending_event_rows({FIELDS}) VALUES ({})",vec!["?";18].join(",")),rusqlite::params_from_iter(row.iter())).map_err(|e|format!("无法写入对账后的事件：{e}"))?;
    Ok(())
}
fn bind_pending(db: &Connection,row: &[Value],event_id: i64,generation: i64,fp: Option<&[u8]>) -> Result<(),String> {
    db.execute(&format!("INSERT INTO usage_ledger_pending_bindings({BINDINGS}) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,1) ON CONFLICT(event_id) DO UPDATE SET raw_generation=excluded.raw_generation,raw_offset=excluded.raw_offset,user_prompt_start=excluded.user_prompt_start,user_prompt_end=excluded.user_prompt_end,assistant_response_start=excluded.assistant_response_start,assistant_response_end=excluded.assistant_response_end,fingerprint=COALESCE(excluded.fingerprint,usage_ledger_pending_bindings.fingerprint),available=1"),params![event_id,number(row,1)?,generation,optional(row,16),optional(row,10),optional(row,11),optional(row,12),optional(row,13),fp]).map_err(|e|e.to_string())?;
    Ok(())
}
fn assign_turn(db: &Connection,row: &mut [Value],generation: i64) -> Result<(),String> {
    let Some(prompt)=optional(row,10) else { return Ok(()); };
    let source=number(row,1)?;
    let event=number(row,0)?;
    let group=GROUP_BASE.checked_add(event).ok_or("账本调用分组溢出")?;
    db.execute("INSERT OR IGNORE INTO usage_ledger_turns VALUES(?1,?2,?3,?4)",params![source,generation,prompt,group]).map_err(|e|e.to_string())?;
    let group: i64 = db.query_row("SELECT turn_id FROM usage_ledger_turns WHERE source_id=?1 AND raw_generation=?2 AND raw_prompt=?3",params![source,generation,prompt],|r|r.get(0)).map_err(|e|e.to_string())?;
    row[10]=Value::Integer(group);
    row[11]=Value::Integer(group); // query grouping key, never a raw excerpt range
    Ok(())
}

pub(super) fn record_append(db: &Connection,path: &str,ordinal: u64,event: &ExactTokenEvent) -> Result<(),String> {
    let mut row=db.query_row(&format!("SELECT {FIELDS} FROM pending_event_rows WHERE source_id=(SELECT source_id FROM sources WHERE path=?1) AND ordinal=?2"),params![path,checked_i64(ordinal,"append ordinal")?],read_values).map_err(|e|format!("无法关联增量事件：{e}"))?;
    let source=number(&row,1)?;
    let generation: i64=db.query_row("SELECT CASE WHEN p.mode='full' THEN p.target_generation ELSE l.raw_generation END FROM pending_sources p LEFT JOIN usage_ledger_sources l USING(source_id) WHERE p.source_id=?1",params![source],|r|r.get(0)).map_err(|e|e.to_string())?;
    bind_pending(db,&row,number(&row,0)?,generation,event.usage_fingerprint.as_deref())?;
    assign_turn(db,&mut row,generation)?;
    db.execute("UPDATE pending_event_rows SET user_prompt_start=?1,user_prompt_end=?2 WHERE id=?3",params![&row[10],&row[11],&row[0]]).map_err(|e|e.to_string())?;
    Ok(())
}

fn full_prefix_matches(db: &Connection,staged: &StagedFullRebuild) -> Result<bool,String> {
    let source=staged.job.source_id;
    let old: Vec<(i64,i64,Vec<u8>)> = db.prepare("SELECT chunk_index,byte_count,sha256 FROM source_chunks WHERE source_id=?1 ORDER BY chunk_index").map_err(|e|e.to_string())?
        .query_map(params![source],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
    if old.is_empty() { return Ok(false); }
    let mut offset=0u64;
    for (position,(index,count,hash)) in old.iter().enumerate() {
        if *index!=position as i64 || *count<=0 { return Ok(false); }
        let new: Option<(i64,Vec<u8>)>=db.query_row("SELECT byte_count,sha256 FROM exact_stage_import.chunks WHERE chunk_index=?1",params![index],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|e|e.to_string())?;
        match new {
            Some((new_count,new_hash)) if new_count==*count && new_hash==*hash => {},
            Some((new_count,_)) if position+1==old.len() && new_count>*count => {
                let mut file=fs::File::open(&staged.job.file).map_err(|e|e.to_string())?;
                file.seek(SeekFrom::Start(offset)).map_err(|e|e.to_string())?;
                let mut bytes=vec![0u8;usize::try_from(*count).map_err(|e|e.to_string())?];
                file.read_exact(&mut bytes).map_err(|e|e.to_string())?;
                if Sha256::digest(&bytes).as_slice()!=hash.as_slice() { return Ok(false); }
            },
            _=>return Ok(false)
        }
        offset+=*count as u64;
    }
    Ok(true)
}

pub(super) fn reconcile_full(db: &Connection,staged: &StagedFullRebuild) -> Result<(),String> {
    let source=staged.job.source_id;
    let generation: i64=db.query_row("SELECT target_generation FROM pending_sources WHERE source_id=?1",params![source],|r|r.get(0)).map_err(|e|e.to_string())?;
    let has_any: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM event_rows WHERE source_id=?1)",params![source],|r|r.get(0)).map_err(|e|e.to_string())?;
    let columns: Vec<String>=db.prepare("PRAGMA exact_stage_import.table_info(events)").map_err(|e|e.to_string())?.query_map([],|r|r.get(1)).map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
    let has_fp=columns.iter().any(|c|c=="usage_fingerprint");
    if !has_any {
        // A fresh source has no old consumption to reconcile. Keep cold scans
        // set-based: no per-file temporary table and no per-event SQL loop.
        let fingerprint=if has_fp { "stage.usage_fingerprint" } else { "NULL" };
        db.execute(&format!("INSERT INTO usage_ledger_pending_bindings({BINDINGS}) SELECT e.id,e.source_id,?2,e.token_source_offset,e.user_prompt_start,e.user_prompt_end,e.assistant_response_start,e.assistant_response_end,{fingerprint},1 FROM pending_event_rows e JOIN exact_stage_import.events stage ON stage.ordinal=e.ordinal WHERE e.source_id=?1"),params![source,generation]).map_err(|e|e.to_string())?;
        db.execute("INSERT OR IGNORE INTO usage_ledger_turns SELECT source_id,?2,user_prompt_start,?3+MIN(id) FROM pending_event_rows WHERE source_id=?1 AND user_prompt_start IS NOT NULL GROUP BY user_prompt_start",params![source,generation,GROUP_BASE]).map_err(|e|e.to_string())?;
        db.execute("UPDATE pending_event_rows SET ordinal=?3+id,user_prompt_start=(SELECT turn_id FROM usage_ledger_turns t WHERE t.source_id=?1 AND t.raw_generation=?2 AND t.raw_prompt=pending_event_rows.user_prompt_start),user_prompt_end=(SELECT turn_id FROM usage_ledger_turns t WHERE t.source_id=?1 AND t.raw_generation=?2 AND t.raw_prompt=pending_event_rows.user_prompt_start) WHERE source_id=?1",params![source,generation,GROUP_BASE]).map_err(|e|e.to_string())?;
        return Ok(());
    }
    let old_generation: Option<i64>=db.query_row("SELECT raw_generation FROM usage_ledger_sources WHERE source_id=?1",params![source],|r|r.get(0)).optional().map_err(|e|e.to_string())?;
    let has_old: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM event_rows WHERE source_id=?1 AND tokens>0)",params![source],|r|r.get(0)).map_err(|e|e.to_string())?;
    let unchanged=full_prefix_matches(db,staged)?;
    let paginated={
        let mut bytes=Vec::new();
        fs::File::open(&staged.job.file).map_err(|e|e.to_string())?.take(65536).read_to_end(&mut bytes).map_err(|e|e.to_string())?;
        let header=bytes.split(|b|*b==b'\n').next().unwrap_or(&[]);
        serde_json::from_slice::<serde_json::Value>(header).ok().is_some_and(|v|v["type"]=="session_meta" && v["payload"]["history_mode"]=="paginated")
    };

    // SQLite temp_store=FILE bounds memory even for a very large single
    // session. Preserve the incoming rows while pending is rewritten, then
    // stream them; never collect an entire source into a Rust Vec.
    db.execute("CREATE TEMP TABLE usage_ledger_incoming AS SELECT * FROM pending_event_rows WHERE source_id=?1",params![source]).map_err(|e|e.to_string())?;
    db.execute("DELETE FROM pending_event_rows WHERE source_id=?1",params![source]).map_err(|e|e.to_string())?;
    let mut incoming=db.prepare(&format!("SELECT {FIELDS} FROM usage_ledger_incoming ORDER BY ordinal")).map_err(|e|e.to_string())?;
    let mut rows=incoming.query([]).map_err(|e|e.to_string())?;
    while let Some(row)=rows.next().map_err(|e|e.to_string())? {
        let raw=read_values(row).map_err(|e|e.to_string())?;
        let ordinal=number(&raw,2)?;
        let fp: Option<Vec<u8>>=if has_fp { db.query_row("SELECT usage_fingerprint FROM exact_stage_import.events WHERE ordinal=?1",params![ordinal],|r|r.get(0)).map_err(|e|e.to_string())? } else { None };
        let mut existing: Option<i64>=if let Some(fp)=&fp { db.query_row("SELECT event_id FROM usage_ledger_bindings WHERE source_id=?1 AND fingerprint=?2 ORDER BY event_id LIMIT 1",params![source,fp],|r|r.get(0)).optional().map_err(|e|e.to_string())? } else { None };
        let mut ambiguous_legacy_identity=false;
        if existing.is_none() && unchanged {
            existing=db.query_row("SELECT e.id FROM event_rows e JOIN usage_ledger_bindings b ON b.event_id=e.id WHERE e.source_id=?1 AND b.raw_generation=?2 AND b.raw_offset IS NOT NULL AND b.raw_offset=?3",params![source,old_generation,optional(&raw,16)],|r|r.get(0)).optional().map_err(|e|e.to_string())?;
            if existing.is_none() {
                // Release schema 9 has no byte location. Ordinals can change
                // when an ownership fix admits an earlier child call. A
                // verified unchanged prefix plus a unique observation on both
                // sides is required; ordinal equality alone is not proof.
                let old_match: (i64,Option<i64>)=db.query_row("SELECT COUNT(*),MIN(e.id) FROM event_rows e JOIN usage_ledger_bindings b ON b.event_id=e.id WHERE e.source_id=?1 AND b.raw_offset IS NULL AND e.timestamp=?2 AND e.input_tokens=?3 AND e.cached_input_tokens=?4 AND e.output_tokens=?5",params![source,&raw[3],&raw[5],&raw[6],&raw[7]],|r|Ok((r.get(0)?,r.get(1)?))).map_err(|e|e.to_string())?;
                if old_match.0==1 {
                    let new_count:i64=db.query_row("SELECT COUNT(*) FROM exact_stage_import.events WHERE timestamp=?1 AND input_tokens=?2 AND cached_input_tokens=?3 AND output_tokens=?4",params![&raw[3],&raw[5],&raw[6],&raw[7]],|r|r.get(0)).map_err(|e|e.to_string())?;
                    if new_count==1 { existing=old_match.1; }
                    else { ambiguous_legacy_identity=true; }
                } else if old_match.0>1 { ambiguous_legacy_identity=true; }
            }
        }
        if let Some(id)=existing {
            let old=db.query_row(&format!("SELECT {FIELDS} FROM event_rows WHERE id=?1"),params![id],read_values).optional().map_err(|e|e.to_string())?;
            if let Some(mut old)=old {
                let same=(4..8).chain(std::iter::once(14)).all(|i|old[i]==raw[i])
                    && (old[8]==raw[8] || (unchanged && staged.job.event_enrichment));
                let verified_location=unchanged && db.query_row("SELECT EXISTS(SELECT 1 FROM usage_ledger_bindings WHERE source_id=?1 AND event_id=?2 AND raw_generation=?3 AND raw_offset=?4)",params![source,id,old_generation,optional(&raw,16)],|r|r.get::<_,bool>(0)).map_err(|e|e.to_string())?;
                if !same && verified_location {
                    db.execute("INSERT OR IGNORE INTO usage_ledger_corrections VALUES(?1,?2,?3,?4,?5,?6,?7,'verified-prefix-reparse')",params![source,id,generation,optional(&raw,16),STAGED_FULL_REBUILD_PARSER_REVISION,&old[4],&raw[4]]).map_err(|e|e.to_string())?;
                    for i in (4..9).chain([14,15]) { old[i]=raw[i].clone(); }
                }
                if same || verified_location {
                    if old[9]==Value::Null { old[9]=raw[9].clone(); }
                    if unchanged && staged.job.event_enrichment { old[8]=raw[8].clone(); }
                    if old[10] == Value::Null && raw[10] != Value::Null {
                        let mut linked = raw.clone();
                        linked[0] = old[0].clone();
                        assign_turn(db, &mut linked, generation)?;
                        for i in 10..14 { old[i] = linked[i].clone(); }
                    }
                    let already: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM pending_event_rows WHERE id=?1)",params![id],|r|r.get(0)).map_err(|e|e.to_string())?;
                    if !already { write_pending(db,&old)?; }
                    bind_pending(db,&raw,id,generation,fp.as_deref())?;
                    if let (Some(prompt),Some(group))=(optional(&raw,10),optional(&old,10)) {
                        db.execute("INSERT OR IGNORE INTO usage_ledger_turns VALUES(?1,?2,?3,?4)",params![source,generation,prompt,group]).map_err(|e|e.to_string())?;
                    }
                    continue;
                }
            }
        }
        let held: bool=if let Some(fp)=&fp { db.query_row("SELECT EXISTS(SELECT 1 FROM usage_ledger_unresolved WHERE source_id=?1 AND fingerprint=?2)",params![source,fp],|r|r.get(0)).map_err(|e|e.to_string())? } else {false};
        let new_snapshot=if let Some(fp)=&fp {
            let values=fingerprint_codec::decode(fp).map_err(|e|e.to_string())?;
            let complete=values[5]==1 || values[6..].iter().all(|n|*n==0);
            complete && !db.query_row("SELECT EXISTS(SELECT 1 FROM source_fingerprints WHERE source_id=?1 AND fingerprint=?2)",params![source,fp],|r|r.get::<_,bool>(0)).map_err(|e|e.to_string())?
        } else { false };
        if existing.is_some() || held || ambiguous_legacy_identity || (has_old && !unchanged && !(paginated && new_snapshot)) {
            db.execute("INSERT OR IGNORE INTO usage_ledger_unresolved VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",params![source,generation,optional(&raw,16).unwrap_or(-ordinal),&raw[3],&raw[4],&raw[5],&raw[6],&raw[7],&raw[8],&raw[9],&raw[14],&raw[15],&raw[17],fp,if existing.is_some(){"identity-conflict"}else{"unproved-rewrite-observation"}]).map_err(|e|e.to_string())?;
            continue;
        }
        let mut admitted=raw.clone();
        admitted[2]=Value::Integer(GROUP_BASE.checked_add(number(&raw,0)?).ok_or("账本事件序号溢出")?);
        assign_turn(db,&mut admitted,generation)?;
        write_pending(db,&admitted)?;
        bind_pending(db,&raw,number(&raw,0)?,generation,fp.as_deref())?;
    }
    drop(rows);
    drop(incoming);
    db.execute_batch("DROP TABLE usage_ledger_incoming").map_err(|e|e.to_string())?;
    db.execute(&format!("INSERT OR IGNORE INTO pending_event_rows({FIELDS}) SELECT {FIELDS} FROM event_rows WHERE source_id=?1"),params![source]).map_err(|e|format!("无法继承旧账：{e}"))?;
    Ok(())
}

pub(super) fn publish_bindings(db: &Connection,generation: i64) -> Result<(),String> {
    db.execute_batch(&format!(r#"
        UPDATE usage_ledger_bindings SET available=0 WHERE source_id IN(SELECT source_id FROM pending_sources WHERE mode<>'delta' UNION SELECT source_id FROM usage_ledger_pending_missing);
        INSERT INTO usage_ledger_sources(source_id,raw_generation,missing)
        SELECT source_id,CASE WHEN mode='delta' THEN COALESCE((SELECT raw_generation FROM usage_ledger_sources l WHERE l.source_id=p.source_id),target_generation) ELSE target_generation END,CASE WHEN EXISTS(SELECT 1 FROM usage_ledger_pending_missing m WHERE m.source_id=p.source_id) THEN 1 ELSE deleted END
        FROM pending_sources p WHERE target_generation={generation}
        ON CONFLICT(source_id) DO UPDATE SET raw_generation=excluded.raw_generation,missing=excluded.missing;
        INSERT INTO usage_ledger_bindings({BINDINGS}) SELECT {BINDINGS} FROM usage_ledger_pending_bindings WHERE 1
        ON CONFLICT(event_id) DO UPDATE SET raw_generation=excluded.raw_generation,raw_offset=excluded.raw_offset,
            user_prompt_start=excluded.user_prompt_start,user_prompt_end=excluded.user_prompt_end,
            assistant_response_start=excluded.assistant_response_start,assistant_response_end=excluded.assistant_response_end,
            fingerprint=COALESCE(excluded.fingerprint,usage_ledger_bindings.fingerprint),available=excluded.available;
    "#)).map_err(|e|format!("无法发布账本原文关联：{e}"))
}

/// Converts the previous release's durable deletion intent to a raw-source
/// absence. Published events stay visible until this pending delta commits.
pub(super) fn preserve_pending_missing(db: &Connection) -> Result<(),String> {
    let ids: Vec<i64>=db.prepare("SELECT source_id FROM pending_sources WHERE mode='tombstone' AND EXISTS(SELECT 1 FROM event_rows e WHERE e.source_id=pending_sources.source_id)").map_err(|e|e.to_string())?.query_map([],|r|r.get(0)).map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
    let fields="size,modified_ns,prefix_sha256,append_ready,resume_offset,previous_total_tokens,fork_replay_started_ns,fork_replay_active,is_explicit_subagent_fork,last_skipped_fork_replay_token_ns,current_model,current_user_prompt_start,current_user_prompt_end,assistant_response_start,assistant_response_end,audit_chunk_index,accounting_state";
    for source in ids {
        db.execute(&format!("UPDATE pending_sources SET mode='delta',deleted=0,({fields})=(SELECT {fields} FROM sources WHERE source_id=?1) WHERE source_id=?1"),params![source]).map_err(|e|e.to_string())?;
        db.execute("INSERT OR IGNORE INTO usage_ledger_pending_missing VALUES(?1)",params![source]).map_err(|e|e.to_string())?;
    }
    Ok(())
}

/// Typed row proofs include retained evidence, unresolved observations and raw
/// bindings. Run only for candidate migration, never as a warm-scan checksum.
pub(super) fn protected_table_digests(db: &Connection) -> Result<std::collections::BTreeMap<String,String>,String> {
    let tables:Vec<String>=db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND (name GLOB 'retained_usage_*' OR name GLOB 'usage_ledger_*') AND name NOT LIKE '%_meta' ORDER BY name").map_err(|e|e.to_string())?
        .query_map([],|r|r.get(0)).map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
    let mut result=std::collections::BTreeMap::new();
    for table in tables {
        let quoted=format!("\"{}\"",table.replace('"',"\"\""));
        let count=db.prepare(&format!("SELECT * FROM {quoted} LIMIT 0")).map_err(|e|e.to_string())?.column_count();
        let order=(1..=count).map(|n|n.to_string()).collect::<Vec<_>>().join(",");
        result.insert(table,schema11_query_digest(db,&format!("SELECT * FROM {quoted} ORDER BY {order}"),[],"持久历史证据")?);
    }
    Ok(result)
}
