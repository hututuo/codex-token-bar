//! Missing source text cannot authorize deleting an already imported building
//! generation. These are durable ledger rows, not unvalidated private-stage
//! candidates. Check their database ownership/completeness without requiring
//! the missing external file, then retain them for the ordinary publisher.
use super::*;

fn failure(message: impl std::fmt::Display) -> String {
    format!("缺失原文的待发布历史无法安全接续；已保留原库：{message}")
}

pub(super) fn retain(db: &Connection, source: i64, generation: i64) -> Result<bool, String> {
    if db.is_autocommit() {
        return Err(failure("需要调用方的恢复事务"));
    }
    if metadata_i64(db, "building_generation").map_err(failure)? != Some(generation) {
        return Err(failure("building 代次已被发布或替换"));
    }
    let state: Option<(i64, String)> = db
        .query_row(
            "SELECT target_generation,mode FROM pending_sources WHERE source_id=?1",
            [source],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(failure)?;
    let Some((target, mode)) = state else {
        return Ok(false);
    };
    if target != generation {
        return Err(failure("来源混入其他 building 代次"));
    }
    if mode == "tombstone" {
        // Old releases could leave a durable deletion intent. Its empty case
        // retains the existing published-history compatibility path. Any
        // surviving child history must not be erased by another tombstone.
        let children: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM pending_event_rows WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM pending_fingerprints WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM usage_ledger_pending_bindings WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM pending_chunks WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM pending_enrichment WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM pending_dashboard_source_totals WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM pending_dashboard_source_5m WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM pending_dashboard_turn_candidates WHERE source_id=?1 \
                UNION ALL SELECT 1 FROM pending_dashboard_turn_tombstones WHERE source_id=?1)",
                [source],
                |row| row.get(0),
            )
            .map_err(failure)?;
        if children {
            return Err(failure("旧删除意图仍携带历史记录"));
        }
        return Ok(false);
    }
    if !["full", "delta"].contains(&mode.as_str()) {
        return Err(failure("来源 pending 模式不受支持"));
    }
    verify_pending_history_layout(db).map_err(failure)?;
    let complete: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM pending_sources p JOIN sources s USING(source_id) \
         WHERE p.source_id=?1 AND p.target_generation=?2 AND p.deleted=0 \
           AND typeof(s.path)='text' AND typeof(s.session_id)='text' \
           AND typeof(p.size)='integer' AND p.size>=0 \
           AND typeof(p.prefix_sha256)='blob' AND length(p.prefix_sha256)=32 \
           AND typeof(p.append_ready)='integer' AND p.append_ready=1 \
           AND typeof(p.resume_offset)='integer' AND p.resume_offset BETWEEN 0 AND p.size)",
            params![source, generation],
            |row| row.get(0),
        )
        .map_err(failure)?;
    if !complete {
        return Err(failure("已持久化的来源检查点不完整"));
    }

    let mut invalid = [
        "id",
        "source_id",
        "ordinal",
        "timestamp",
        "tokens",
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "accounting_kind",
    ]
    .map(|column| format!("typeof(e.{column})<>'integer'"))
    .to_vec();
    invalid.push("typeof(e.model) NOT IN('null','text')".into());
    for column in [
        "user_prompt_start",
        "user_prompt_end",
        "assistant_response_start",
        "assistant_response_end",
        "reported_total_tokens",
        "token_source_offset",
        "legacy_tokens",
    ] {
        invalid.push(format!("typeof(e.{column}) NOT IN('null','integer')"));
    }
    // Preserve diagnostic rows, including legacy invalid component evidence.
    // Only counted rows require the component formula; diagnostics stay zero.
    invalid.extend([
        "e.accounting_kind NOT IN(0,1,2,3,4)".into(),
        "(e.accounting_kind<>0 AND e.tokens<>0)".into(),
        "(e.accounting_kind=0 AND (e.input_tokens<0 OR e.output_tokens<0 \
          OR e.cached_input_tokens NOT BETWEEN 0 AND e.input_tokens \
          OR e.reasoning_output_tokens NOT BETWEEN 0 AND e.output_tokens \
          OR e.input_tokens>9223372036854775807-e.output_tokens \
          OR e.tokens<>e.input_tokens+e.output_tokens))"
            .into(),
    ]);
    let malformed: bool = db.query_row(&format!(
        "SELECT EXISTS(SELECT 1 FROM pending_event_rows e WHERE e.source_id=?1 AND ({}) \
         UNION ALL SELECT 1 FROM pending_event_rows e JOIN event_rows old ON old.id=e.id \
            WHERE e.source_id=?1 AND old.source_id<>e.source_id \
         UNION ALL SELECT 1 FROM pending_event_rows e WHERE e.source_id=?1 \
            AND NOT EXISTS(SELECT 1 FROM usage_ledger_pending_bindings b \
                WHERE b.event_id=e.id AND b.source_id=e.source_id) \
            AND NOT EXISTS(SELECT 1 FROM event_rows old JOIN usage_ledger_bindings b ON b.event_id=old.id \
                WHERE old.id=e.id AND old.source_id=e.source_id AND b.source_id=e.source_id) \
         UNION ALL SELECT 1 FROM usage_ledger_pending_bindings b WHERE b.source_id=?1 \
            AND (NOT EXISTS(SELECT 1 FROM pending_event_rows e WHERE e.id=b.event_id AND e.source_id=b.source_id) \
                OR typeof(b.raw_generation)<>'integer' OR b.raw_generation NOT BETWEEN 0 AND ?2 \
                OR typeof(b.available)<>'integer' OR b.available NOT IN(0,1) \
                OR typeof(b.fingerprint) NOT IN('null','blob') \
                OR typeof(b.raw_offset) NOT IN('null','integer') \
                OR typeof(b.user_prompt_start) NOT IN('null','integer') \
                OR typeof(b.user_prompt_end) NOT IN('null','integer') \
                OR typeof(b.assistant_response_start) NOT IN('null','integer') \
                OR typeof(b.assistant_response_end) NOT IN('null','integer')))", invalid.join(" OR ")),
        params![source, generation], |row| row.get(0)).map_err(failure)?;
    if malformed {
        return Err(failure("历史事件或原文绑定不符合已知账本结构"));
    }
    if mode == "full" {
        let missing_published: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM event_rows old WHERE old.source_id=?1 \
                AND NOT EXISTS(SELECT 1 FROM pending_event_rows p WHERE p.id=old.id AND p.source_id=old.source_id))",
            [source], |row| row.get(0)).map_err(failure)?;
        if missing_published {
            return Err(failure("完整候选缺少已有已发布事件的稳定身份"));
        }
    }
    let mut fingerprints = db.prepare(
        "SELECT fingerprint FROM pending_fingerprints WHERE source_id=?1 \
         UNION ALL SELECT fingerprint FROM usage_ledger_pending_bindings WHERE source_id=?1 AND fingerprint IS NOT NULL")
        .map_err(failure)?;
    let mut rows = fingerprints.query([source]).map_err(failure)?;
    while let Some(row) = rows.next().map_err(failure)? {
        match row.get_ref(0).map_err(failure)? {
            rusqlite::types::ValueRef::Blob(bytes)
                if bytes.len() <= 1 + 10 * fingerprint_codec::FINGERPRINT_VALUE_COUNT =>
            {
                fingerprint_codec::decode(bytes).map_err(failure)?;
            }
            _ => return Err(failure("已有去重指纹不是受支持的持久编码")),
        }
    }
    drop(rows);
    drop(fingerprints);

    // Numeric rows, IDs, models, turns, checkpoints, fingerprints and existing
    // enrichment receipts stay untouched. Raw ranges remain as provenance,
    // but no caller may render them as available excerpts after publication.
    db.execute(
        "INSERT OR IGNORE INTO usage_ledger_pending_missing(source_id) VALUES(?1)",
        [source],
    )
    .map_err(failure)?;
    db.execute(
        "UPDATE usage_ledger_pending_bindings SET available=0 WHERE source_id=?1",
        [source],
    )
    .map_err(failure)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn database() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON; CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);").unwrap();
        initialize_index_schema(&db).unwrap();
        install(&db).unwrap();
        set_metadata(&db, "schema_version", &CURRENT_SCHEMA_VERSION.to_string()).unwrap();
        set_metadata(&db, "published_generation", "1").unwrap();
        set_metadata(&db, "building_generation", "2").unwrap();
        db.execute("INSERT INTO sources(source_id,path,session_id,last_seen_generation,size,prefix_sha256,append_ready,resume_offset) VALUES(1,'/missing/source.jsonl','missing',1,100,?1,1,100)",
            params![vec![7_u8; 32]]).unwrap();
        db.execute_batch("INSERT INTO event_rows(id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,user_prompt_start,user_prompt_end) VALUES(1,1,1,1000,120,120,0,0,0,'known-model',10,10); INSERT INTO usage_ledger_sources VALUES(1,1,0); INSERT INTO usage_ledger_bindings VALUES(1,1,1,20,10,10,NULL,NULL,NULL,1);").unwrap();
        db.execute("INSERT INTO pending_sources(source_id,target_generation,mode,size,prefix_sha256,append_ready,resume_offset) VALUES(1,2,'full',200,?1,1,200)",
            params![vec![8_u8; 32]]).unwrap();
        db.execute_batch(&format!("INSERT INTO pending_event_rows({FIELDS}) SELECT {FIELDS} FROM event_rows; \
            INSERT INTO pending_event_rows(id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,user_prompt_start,user_prompt_end) \
                VALUES(2,1,2,1001,55,55,0,0,0,'known-model',30,30); \
            INSERT INTO pending_event_rows(id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind) \
                VALUES(3,1,3,1002,0,0,0,0,0,'known-model',4),(4,1,4,1003,0,-7,0,0,0,'known-model',3); \
            INSERT INTO usage_ledger_pending_bindings({BINDINGS}) \
                SELECT id,source_id,2,20*id,user_prompt_start,user_prompt_end,NULL,NULL,NULL,1 FROM pending_event_rows;")).unwrap();
        for key in 1..=3 {
            let fp = fingerprint_codec::encode(&[key, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0]).unwrap();
            db.execute(
                "INSERT INTO pending_fingerprints VALUES(1,?1)",
                params![&fp],
            )
            .unwrap();
            db.execute(
                "UPDATE usage_ledger_pending_bindings SET fingerprint=?1 WHERE event_id=?2",
                params![fp, key as i64],
            )
            .unwrap();
        }
        db
    }

    fn digest(db: &Connection, table: &str) -> String {
        let count = db
            .prepare(&format!("SELECT * FROM {table} LIMIT 0"))
            .unwrap()
            .column_count();
        let order = (1..=count)
            .map(|value| value.to_string())
            .collect::<Vec<_>>()
            .join(",");
        schema11_query_digest(
            db,
            &format!("SELECT * FROM {table} ORDER BY {order}"),
            [],
            "missing-source proof",
        )
        .unwrap()
    }

    fn protected(db: &Connection) -> Vec<String> {
        [
            "sources",
            "event_rows",
            "pending_sources",
            "pending_event_rows",
            "pending_fingerprints",
            "usage_ledger_pending_bindings",
            "usage_ledger_pending_missing",
        ]
        .iter()
        .map(|table| digest(db, table))
        .collect()
    }

    #[test]
    fn missing_raw_keeps_complete_pending_values_and_zero_diagnostics() {
        let db = database();
        let before = [
            "pending_sources",
            "pending_event_rows",
            "pending_fingerprints",
        ]
        .map(|table| digest(&db, table));
        db.execute_batch("BEGIN IMMEDIATE").unwrap();
        assert!(retain(&db, 1, 2).unwrap());
        assert_eq!(
            [
                "pending_sources",
                "pending_event_rows",
                "pending_fingerprints"
            ]
            .map(|table| digest(&db, table)),
            before
        );
        assert_eq!(
            db.query_row(
                "SELECT COUNT(*),SUM(tokens) FROM pending_event_rows",
                [],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
            )
            .unwrap(),
            (4, 175)
        );
        assert_eq!(
            db.query_row(
                "SELECT SUM(available) FROM usage_ledger_pending_bindings",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
        assert_eq!(event_enrichment_receipt_count(&db).unwrap(), 1);
        db.execute_batch("COMMIT").unwrap();
    }

    #[test]
    fn incomplete_or_malformed_pending_history_is_never_discarded() {
        for mutation in [
            "UPDATE pending_sources SET append_ready=0",
            "UPDATE pending_sources SET prefix_sha256=X'00'",
            "UPDATE pending_sources SET resume_offset=size+1",
            "UPDATE pending_sources SET target_generation=3",
            "DELETE FROM pending_event_rows WHERE id=1",
            "DELETE FROM usage_ledger_pending_bindings WHERE event_id=2",
            "UPDATE pending_event_rows SET tokens=tokens+1 WHERE id=2",
            "UPDATE pending_event_rows SET accounting_kind=99 WHERE id=2",
            "UPDATE pending_event_rows SET model=CAST('known-model' AS BLOB) WHERE id=2",
            "UPDATE usage_ledger_pending_bindings SET raw_generation=99 WHERE event_id=2",
            "UPDATE pending_fingerprints SET fingerprint=X'0000' WHERE fingerprint=(SELECT fingerprint FROM pending_fingerprints LIMIT 1)",
            "ALTER TABLE pending_event_rows ADD COLUMN legacy_extra BLOB; UPDATE pending_event_rows SET legacy_extra=X'010203'",
            "ALTER TABLE usage_ledger_pending_bindings ADD COLUMN legacy_extra BLOB; UPDATE usage_ledger_pending_bindings SET legacy_extra=X'040506'",
        ] {
            let db = database();
            db.execute_batch(mutation).unwrap();
            let before = protected(&db);
            db.execute_batch("BEGIN IMMEDIATE").unwrap();
            assert!(retain(&db, 1, 2).is_err(), "accepted {mutation}");
            assert_eq!(protected(&db), before, "mutated history after {mutation}");
            db.execute_batch("ROLLBACK").unwrap();
        }
    }

    #[test]
    fn complete_delta_keeps_new_history_without_duplicating_published_rows() {
        let db = database();
        db.execute_batch("UPDATE pending_sources SET mode='delta'; DELETE FROM pending_event_rows WHERE id=1; DELETE FROM usage_ledger_pending_bindings WHERE event_id=1; UPDATE usage_ledger_pending_bindings SET raw_generation=1; BEGIN IMMEDIATE").unwrap();
        let pending = digest(&db, "pending_event_rows");
        let published = digest(&db, "event_rows");
        assert!(retain(&db, 1, 2).unwrap());
        assert_eq!(digest(&db, "pending_event_rows"), pending);
        assert_eq!(digest(&db, "event_rows"), published);
        db.execute_batch("ROLLBACK").unwrap();
    }

    #[test]
    fn legacy_tombstone_with_surviving_evidence_is_protected() {
        let db = database();
        db.execute_batch("UPDATE pending_sources SET mode='tombstone'; BEGIN IMMEDIATE")
            .unwrap();
        let before = protected(&db);
        assert!(retain(&db, 1, 2).unwrap_err().contains("旧删除意图"));
        assert_eq!(protected(&db), before);
        db.execute_batch("ROLLBACK; DELETE FROM usage_ledger_pending_bindings; BEGIN IMMEDIATE")
            .unwrap();
        assert!(!retain(&db, 1, 2).unwrap());
        db.execute_batch("ROLLBACK").unwrap();
    }

    #[test]
    fn completion_counts_published_scope_once_and_excludes_new_pending_bounds() {
        let db = database();
        db.execute(
            "INSERT INTO pending_enrichment VALUES(1,?1,?2,200,?3)",
            params![
                EVENT_ENRICHMENT_REVISION,
                STAGED_FULL_REBUILD_PARSER_REVISION,
                vec![8_u8; 32]
            ],
        )
        .unwrap();
        assert_eq!(event_enrichment_receipt_count(&db).unwrap(), 0);
        assert_eq!(event_enrichment_pending_candidates(&db).unwrap().len(), 1);
        db.execute(
            "INSERT INTO source_enrichment VALUES(1,?1,?2,100,?3)",
            params![
                EVENT_ENRICHMENT_REVISION,
                STAGED_FULL_REBUILD_PARSER_REVISION,
                vec![7_u8; 32]
            ],
        )
        .unwrap();
        db.execute(
            "UPDATE pending_enrichment SET completed_size=100,completed_prefix_sha256=?1",
            params![vec![7_u8; 32]],
        )
        .unwrap();
        assert_eq!(event_enrichment_receipt_count(&db).unwrap(), 1);
        assert!(event_enrichment_pending_candidates(&db).unwrap().is_empty());
    }
}
