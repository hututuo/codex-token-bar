//! An imported building generation is already durable history. Snapshot its
//! pending rows before replacement and require one-to-one coverage by the
//! reconciled replacement, in the same IMMEDIATE transaction. Merely keeping
//! a private artifact elsewhere does not keep these observations usable.
//!
//! Canonical event IDs, validated fingerprints, or a verified unchanged raw
//! prefix plus an unambiguous observation establish identity. Newly allocated
//! pending IDs and ledger ordinals do not. Known numeric/accounting/model/link
//! values cannot disappear or change; only absent model/location data may grow.
//! Unsupported legitimate corrections remain protected rather than guessed.
//! SQLite TEMP tables/indexes bound memory; no complete source is collected in
//! Rust. The caller MUST roll back its import on either function's error.
use super::*;
use rusqlite::types::ValueRef;

const OLD_EVENTS: &str = "usage_pending_import_old_events";
const OLD_BINDINGS: &str = "usage_pending_import_old_bindings";
const OLD_FINGERPRINTS: &str = "usage_pending_import_old_fingerprints";
const CONTEXT: &str = "usage_pending_import_context";
const NEW_EVENTS: &str = "usage_pending_import_new_events";
const NEW_BINDINGS: &str = "usage_pending_import_new_bindings";
const MATCHES: &str = "usage_pending_import_matches";

fn failure(message: impl std::fmt::Display) -> String {
    format!("待发布历史保全校验失败；已停止替换：{message}")
}

pub(super) fn snapshot(db: &Connection, source: i64, generation: i64) -> Result<bool, String> {
    if db.is_autocommit() {
        return Err(failure("需要调用方的导入事务"));
    }
    // Normal fresh/backfill jobs have no pending source yet. This indexed
    // lookup avoids allocating TEMP objects or scanning other sources' binds.
    let previous: Option<i64> = db.query_row(
        "SELECT target_generation FROM pending_sources WHERE source_id=?1",
        params![source], |row| row.get(0),
    ).optional().map_err(failure)?;
    let Some(previous) = previous else { return Ok(false); };
    if previous != generation {
        return Err(failure("旧来源与导入目标代次不一致"));
    }
    for (table, expected) in [("pending_event_rows", FIELDS), ("usage_ledger_pending_bindings", BINDINGS)] {
        let mut columns = db.prepare(&format!("PRAGMA table_info({table})")).map_err(failure)?;
        let mut rows = columns.query([]).map_err(failure)?;
        let mut wanted = expected.split(',');
        while let Some(row) = rows.next().map_err(failure)? {
            if wanted.next() != Some(row.get::<_, String>(1).map_err(failure)?.as_str()) {
                return Err(failure(format!("{table} 含未知字段布局，不能替换旧记录")));
            }
        }
        if wanted.next().is_some() { return Err(failure(format!("{table} 缺少旧记录字段"))); }
    }
    db.execute(&format!("CREATE TEMP TABLE {CONTEXT} AS \
        SELECT p.source_id,p.target_generation,p.size AS raw_size, \
               p.prefix_sha256 AS raw_prefix,p.resume_offset AS raw_resume,s.path,s.session_id \
        FROM pending_sources p JOIN sources s USING(source_id) WHERE p.source_id=?1"),
        params![source]).map_err(failure)?;
    db.execute(&format!("CREATE TEMP TABLE {OLD_EVENTS} AS \
        SELECT p.*,EXISTS(SELECT 1 FROM event_rows e WHERE e.id=p.id AND e.source_id=p.source_id) AS canonical \
        FROM pending_event_rows p WHERE p.source_id=?1"), params![source]).map_err(failure)?;
    db.execute(&format!("CREATE TEMP TABLE {OLD_BINDINGS} AS \
        SELECT * FROM usage_ledger_pending_bindings WHERE source_id=?1"), params![source]).map_err(failure)?;
    db.execute(&format!("CREATE TEMP TABLE {OLD_FINGERPRINTS} AS \
        SELECT * FROM pending_fingerprints WHERE source_id=?1"), params![source]).map_err(failure)?;
    db.execute_batch(&format!("CREATE UNIQUE INDEX usage_pending_import_old_event_id ON {OLD_EVENTS}(id); \
        CREATE UNIQUE INDEX usage_pending_import_old_binding_id ON {OLD_BINDINGS}(event_id);"))
        .map_err(failure)?;
    let malformed: bool = db.query_row(&format!("SELECT \
        (SELECT COUNT(*) FROM {CONTEXT})<>1 \
        OR EXISTS(SELECT 1 FROM {OLD_BINDINGS} b LEFT JOIN {OLD_EVENTS} e ON e.id=b.event_id \
                  WHERE e.id IS NULL OR e.source_id IS NOT b.source_id \
                    OR typeof(b.raw_generation)<>'integer' OR typeof(b.available)<>'integer' \
                    OR b.available NOT IN(0,1))"), [], |row| row.get(0)).map_err(failure)?;
    if malformed { return Err(failure("旧来源身份或原文绑定不完整")); }
    Ok(true)
}

fn same(left: &str, right: &str, column: &str) -> String {
    format!("(typeof({left}.{column})=typeof({right}.{column}) \
        AND {left}.{column} IS {right}.{column} COLLATE BINARY)")
}

fn additive(left: &str, right: &str, column: &str, kind: &str) -> String {
    format!("(({left}.{column} IS NULL AND typeof({right}.{column}) IN('null','{kind}')) \
        OR {})", same(left, right, column))
}

fn facts() -> String {
    let mut checks = ["source_id", "timestamp", "tokens", "input_tokens", "cached_input_tokens",
        "output_tokens", "reasoning_output_tokens", "accounting_kind", "reported_total_tokens", "legacy_tokens"]
        .map(|field| same("o", "n", field)).to_vec();
    checks.push(additive("o", "n", "model", "text"));
    for field in ["user_prompt_start", "user_prompt_end", "assistant_response_start", "assistant_response_end", "token_source_offset"] {
        checks.push(additive("o", "n", field, "integer"));
    }
    let mut bindings = vec!["nb.event_id IS NOT NULL".to_string(), same("ob", "nb", "source_id"),
        "typeof(nb.raw_generation)='integer' AND (nb.raw_generation=ob.raw_generation \
            OR nb.raw_generation=(SELECT target_generation FROM usage_pending_import_context))".into(),
        "typeof(nb.available)='integer' AND nb.available IN(0,1) AND nb.available>=ob.available".into(),
        additive("ob", "nb", "fingerprint", "blob")];
    for field in ["raw_offset", "user_prompt_start", "user_prompt_end", "assistant_response_start", "assistant_response_end"] {
        bindings.push(additive("ob", "nb", field, "integer"));
    }
    checks.push(format!("(ob.event_id IS NULL OR ({}))", bindings.join(" AND ")));
    checks.join(" AND ")
}

/// A weak legacy identity needs cryptographic prefix coverage, not matching
/// ordinal/row counts. Equal full-prefix receipts need no additional file I/O;
/// an appended candidate requires hashing the old prefix from a stable source.
fn verify_legacy_prefix(db: &Connection) -> Result<(), String> {
    let (size, resume, digest, path, session): (i64, Option<i64>, Option<Vec<u8>>, String, String) = db.query_row(
        &format!("SELECT raw_size,raw_resume,CASE WHEN typeof(raw_prefix)='blob' AND length(raw_prefix)=32 \
            THEN raw_prefix ELSE NULL END,path,session_id FROM {CONTEXT}"), [],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
    ).map_err(failure)?;
    let digest: [u8; 32] = digest.and_then(|value| value.try_into().ok())
        .ok_or_else(|| failure("旧检查点没有可验证的前缀证明"))?;
    if size <= 0 || resume.is_some_and(|offset| offset < 0 || offset > size) {
        return Err(failure("旧检查点范围不可信"));
    }
    let (new_size, new_resume, new_digest, new_path, new_session): (i64, i64, Vec<u8>, String, String) = db.query_row(
        "SELECT size,resume_offset,prefix_sha256,path,session_id FROM exact_stage_import.manifest WHERE complete=1",
        [], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
    ).map_err(failure)?;
    if new_path != path || new_session != session || new_size < size || new_resume < resume.unwrap_or(size) {
        return Err(failure("候选没有覆盖旧来源的已提交前缀"));
    }
    if new_size == size {
        return if new_digest.as_slice() == digest.as_slice() { Ok(()) }
            else { Err(failure("同长候选的原文前缀与旧检查点不一致")) };
    }
    let path = Path::new(&path);
    let mut reader = RolloutReader::open(path).map_err(failure)?;
    let before = file_signature_from_handle(&reader, path).map_err(failure)?;
    let path_before = file_signature(path).map_err(failure)?;
    if before != path_before || before.size < new_size as u64 {
        return Err(failure("前缀验证期间原文身份或长度不一致"));
    }
    let actual = hash_file_prefix(&mut reader, size as u64, path).map_err(failure)?;
    if actual != digest || file_signature_from_handle(&reader, path).map_err(failure)? != before
        || file_signature(path).map_err(failure)? != path_before {
        return Err(failure("旧原文前缀已改变或验证期间发生变化"));
    }
    Ok(())
}

fn verify_inner(db: &Connection, source: i64) -> Result<(), String> {
    let context_matches: bool = db.query_row(&format!("SELECT EXISTS( \
        SELECT 1 FROM {CONTEXT} o JOIN pending_sources p ON p.source_id=o.source_id \
        JOIN sources s ON s.source_id=o.source_id WHERE o.source_id=?1 \
          AND p.target_generation=o.target_generation AND s.path IS o.path COLLATE BINARY \
          AND s.session_id IS o.session_id COLLATE BINARY)"), params![source], |row| row.get(0)).map_err(failure)?;
    if !context_matches { return Err(failure("替换改变了来源或目标代次")); }
    db.execute(&format!("CREATE TEMP TABLE {NEW_EVENTS} AS SELECT * FROM pending_event_rows WHERE source_id=?1"),
        params![source]).map_err(failure)?;
    db.execute(&format!("CREATE TEMP TABLE {NEW_BINDINGS} AS SELECT * FROM usage_ledger_pending_bindings WHERE source_id=?1"),
        params![source]).map_err(failure)?;
    db.execute_batch(&format!("CREATE UNIQUE INDEX usage_pending_import_new_event_id ON {NEW_EVENTS}(id); \
        CREATE INDEX usage_pending_import_new_facts ON {NEW_EVENTS}(timestamp,input_tokens,cached_input_tokens,output_tokens); \
        CREATE UNIQUE INDEX usage_pending_import_new_binding_id ON {NEW_BINDINGS}(event_id); \
        CREATE INDEX usage_pending_import_new_fingerprint ON {NEW_BINDINGS}(fingerprint); \
        CREATE INDEX usage_pending_import_new_offset ON {NEW_BINDINGS}(raw_offset,raw_generation); \
        CREATE TEMP TABLE {MATCHES}(old_id INTEGER PRIMARY KEY,new_id INTEGER NOT NULL UNIQUE) WITHOUT ROWID;"))
        .map_err(failure)?;
    let preserved = facts();
    let canonical = format!("FROM {OLD_EVENTS} o JOIN {NEW_EVENTS} n ON n.id=o.id \
        LEFT JOIN {OLD_BINDINGS} ob ON ob.event_id=o.id LEFT JOIN {NEW_BINDINGS} nb ON nb.event_id=n.id");
    let fingerprint = format!("FROM {OLD_EVENTS} o JOIN {OLD_BINDINGS} ob ON ob.event_id=o.id \
        JOIN {NEW_BINDINGS} nb ON nb.fingerprint=ob.fingerprint \
        JOIN {NEW_EVENTS} n ON n.id=nb.event_id");
    let location = format!("FROM {OLD_EVENTS} o JOIN {OLD_BINDINGS} ob ON ob.event_id=o.id \
        JOIN {NEW_BINDINGS} nb ON nb.raw_offset=ob.raw_offset \
        JOIN {NEW_EVENTS} n ON n.id=nb.event_id");
    let weak = format!("FROM {OLD_EVENTS} o JOIN {NEW_EVENTS} n ON n.timestamp=o.timestamp \
        AND n.input_tokens=o.input_tokens AND n.cached_input_tokens=o.cached_input_tokens AND n.output_tokens=o.output_tokens \
        LEFT JOIN {OLD_BINDINGS} ob ON ob.event_id=o.id LEFT JOIN {NEW_BINDINGS} nb ON nb.event_id=n.id");
    let mut prefix_verified = false;
    {
        let mut old = db.prepare(&format!("SELECT o.id,o.canonical,b.fingerprint,b.raw_offset,c.raw_size,c.raw_resume \
            FROM {OLD_EVENTS} o LEFT JOIN {OLD_BINDINGS} b ON b.event_id=o.id \
            CROSS JOIN {CONTEXT} c ORDER BY o.id")).map_err(failure)?;
        let mut rows = old.query([]).map_err(failure)?;
        while let Some(row) = rows.next().map_err(failure)? {
            let id: i64 = row.get(0).map_err(failure)?;
            let is_canonical: bool = row.get(1).map_err(failure)?;
            let encoded = row.get_ref(2).map_err(failure)?;
            let has_fingerprint = match encoded {
                ValueRef::Null => false,
                ValueRef::Blob(bytes) if bytes.len() <= 1 + 10 * fingerprint_codec::FINGERPRINT_VALUE_COUNT => {
                    fingerprint_codec::decode(bytes).map_err(failure)?;
                    true
                }
                _ => return Err(failure(format!("事件 {id} 的原身份指纹无效"))),
            };
            let join = if is_canonical { &canonical } else if has_fingerprint { &fingerprint } else {
                if !prefix_verified { verify_legacy_prefix(db)?; prefix_verified = true; }
                if let Some(offset) = row.get::<_, Option<i64>>(3).map_err(failure)? {
                    let size: i64 = row.get(4).map_err(failure)?;
                    let resume: Option<i64> = row.get(5).map_err(failure)?;
                    if offset < 0 || offset >= resume.unwrap_or(size) {
                        return Err(failure(format!("事件 {id} 的弱原文位置不在已证明的旧前缀内")));
                    }
                    &location
                } else { &weak }
            };
            let (count, matched): (i64, Option<i64>) = db.query_row(
                &format!("SELECT COUNT(*),MIN(n.id) {join} WHERE o.id=?1 AND {preserved}"),
                params![id], |row| Ok((row.get(0)?, row.get(1)?)),
            ).map_err(failure)?;
            if count != 1 { return Err(failure(format!("事件 {id} 未获唯一且完整的接续（匹配 {count}）"))); }
            db.execute(&format!("INSERT INTO {MATCHES}(old_id,new_id) VALUES(?1,?2)"), params![id, matched])
                .map_err(|error| failure(format!("多个旧事件不能共用同一候选事件：{error}")))?;
        }
    }
    let lost_fingerprint: bool = db.query_row(&format!("SELECT EXISTS(SELECT 1 FROM {OLD_FINGERPRINTS} o \
        WHERE NOT EXISTS(SELECT 1 FROM pending_fingerprints n WHERE n.source_id=o.source_id \
          AND typeof(n.fingerprint)=typeof(o.fingerprint) AND n.fingerprint IS o.fingerprint COLLATE BINARY))"),
        [], |row| row.get(0)).map_err(failure)?;
    if lost_fingerprint { return Err(failure("候选遗失已有去重身份")); }
    Ok(())
}

pub(super) fn verify(db: &Connection, source: i64, had_snapshot: bool) -> Result<(), String> {
    if !had_snapshot { return Ok(()); }
    if db.is_autocommit() { return Err(failure("校验已离开原导入事务")); }
    let result = verify_inner(db, source);
    let cleanup = [MATCHES, NEW_BINDINGS, NEW_EVENTS, OLD_FINGERPRINTS, OLD_BINDINGS, OLD_EVENTS, CONTEXT]
        .into_iter().try_for_each(|table| db.execute_batch(&format!("DROP TABLE IF EXISTS temp.{table}"))
            .map_err(failure));
    match (result, cleanup) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn database() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        let fields = "id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL,ordinal INTEGER NOT NULL, \
            timestamp INTEGER NOT NULL,tokens INTEGER NOT NULL,input_tokens INTEGER NOT NULL, \
            cached_input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL, \
            model TEXT,user_prompt_start INTEGER,user_prompt_end INTEGER,assistant_response_start INTEGER, \
            assistant_response_end INTEGER,accounting_kind INTEGER NOT NULL,reported_total_tokens INTEGER, \
            token_source_offset INTEGER,legacy_tokens INTEGER";
        db.execute_batch(&format!("CREATE TABLE event_rows({fields}); CREATE TABLE pending_event_rows({fields}); \
            CREATE TABLE sources(source_id INTEGER PRIMARY KEY,path TEXT,session_id TEXT); \
            INSERT INTO sources VALUES(1,'/fixture-source.jsonl','fixture'); \
            CREATE TABLE pending_sources(source_id INTEGER PRIMARY KEY,target_generation INTEGER,size INTEGER,prefix_sha256 BLOB,resume_offset INTEGER); \
            CREATE TABLE usage_ledger_pending_bindings(event_id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL,raw_generation INTEGER NOT NULL,raw_offset INTEGER, \
                user_prompt_start INTEGER,user_prompt_end INTEGER,assistant_response_start INTEGER,assistant_response_end INTEGER,fingerprint BLOB,available INTEGER NOT NULL); \
            CREATE TABLE pending_fingerprints(source_id INTEGER NOT NULL,fingerprint BLOB NOT NULL,PRIMARY KEY(source_id,fingerprint)) WITHOUT ROWID;"))
            .unwrap();
        db.execute("INSERT INTO pending_sources VALUES(1,2,512,?1,512)", params![vec![7_u8; 32]]).unwrap();
        db
    }

    fn add(db: &Connection, id: i64, key: i64, tokens: i64, model: Option<&str>) {
        let fp = fingerprint_codec::encode(&[key as u64, 0, 0, 0, 0, 1, tokens as u64, 0, 0, 0, tokens as u64]).unwrap();
        db.execute("INSERT INTO pending_event_rows VALUES(?1,1,?2,?3,?4,?4,0,0,0,?5,NULL,NULL,NULL,NULL,0,NULL,?6,NULL)",
            params![id, GROUP_BASE + id, 1000 + key, tokens, model, 100 * key]).unwrap();
        db.execute("INSERT INTO usage_ledger_pending_bindings VALUES(?1,1,2,?2,NULL,NULL,NULL,NULL,?3,1)",
            params![id, 100 * key, &fp]).unwrap();
        db.execute("INSERT OR IGNORE INTO pending_fingerprints VALUES(1,?1)", params![fp]).unwrap();
    }

    fn clear_pending(db: &Connection) {
        db.execute_batch("DELETE FROM pending_event_rows; DELETE FROM usage_ledger_pending_bindings; DELETE FROM pending_fingerprints;").unwrap();
    }

    fn begin(db: &Connection) {
        db.execute_batch("BEGIN IMMEDIATE").unwrap();
        assert!(snapshot(db, 1, 2).unwrap());
    }

    fn temporary_count(db: &Connection) -> i64 {
        db.query_row("SELECT COUNT(*) FROM sqlite_temp_master WHERE type='table' AND name GLOB 'usage_pending_import_*'", [], |row| row.get(0)).unwrap()
    }

    #[test]
    fn pending_prefix_replacement_rolls_back_the_unpublished_append() {
        let db = database();
        add(&db, 1, 1, 120, None);
        add(&db, 2, 2, 55, None);
        db.execute_batch("INSERT INTO event_rows SELECT * FROM pending_event_rows WHERE id=1").unwrap();
        begin(&db);
        clear_pending(&db);
        add(&db, 1, 1, 120, None);
        assert!(verify(&db, 1, true).unwrap_err().contains("待发布历史"));
        assert_eq!(temporary_count(&db), 0);
        db.execute_batch("ROLLBACK").unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*),SUM(tokens) FROM pending_event_rows", [], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))).unwrap(), (2,175));
    }

    #[test]
    fn equivalent_reimport_may_allocate_a_new_private_id_but_keeps_canonical_id() {
        let db = database();
        add(&db, 1, 1, 120, None);
        add(&db, 2, 2, 55, None);
        db.execute_batch("INSERT INTO event_rows SELECT * FROM pending_event_rows WHERE id=1").unwrap();
        begin(&db);
        clear_pending(&db);
        add(&db, 1, 1, 120, Some("known-model"));
        add(&db, 9, 2, 55, Some("known-model"));
        verify(&db, 1, true).unwrap();
        assert_eq!(temporary_count(&db), 0);
        db.execute_batch("COMMIT").unwrap();
        assert_eq!(db.query_row("SELECT SUM(tokens) FROM pending_event_rows", [], |row| row.get::<_, i64>(0)).unwrap(), 175);
    }

    #[test]
    fn canonical_identity_cannot_be_replaced_even_by_an_equal_private_copy() {
        let db = database();
        add(&db, 1, 1, 120, None);
        db.execute_batch("INSERT INTO event_rows SELECT * FROM pending_event_rows").unwrap();
        begin(&db);
        clear_pending(&db);
        add(&db, 9, 1, 120, None);
        assert!(verify(&db, 1, true).is_err());
        db.execute_batch("ROLLBACK").unwrap();
    }

    #[test]
    fn known_model_links_fingerprints_and_numeric_types_cannot_disappear() {
        for change in ["UPDATE pending_event_rows SET model=NULL",
            "UPDATE usage_ledger_pending_bindings SET raw_offset=NULL",
            "DELETE FROM pending_fingerprints",
            "UPDATE pending_event_rows SET reasoning_output_tokens=1",
            "UPDATE pending_event_rows SET reported_total_tokens=0",
            "UPDATE pending_event_rows SET tokens=CAST('120' AS BLOB)"] {
            let db = database();
            add(&db, 1, 1, 120, Some("keep-model"));
            begin(&db);
            db.execute_batch(change).unwrap();
            assert!(verify(&db, 1, true).is_err(), "accepted {change}");
            db.execute_batch("ROLLBACK").unwrap();
        }
    }

    #[test]
    fn zero_token_diagnostic_is_history_even_when_the_sum_does_not_change() {
        let db = database();
        add(&db, 1, 1, 120, None);
        add(&db, 2, 2, 0, None);
        db.execute("UPDATE pending_event_rows SET accounting_kind=4 WHERE id=2", []).unwrap();
        begin(&db);
        db.execute("DELETE FROM pending_event_rows WHERE id=2", []).unwrap();
        db.execute("DELETE FROM usage_ledger_pending_bindings WHERE event_id=2", []).unwrap();
        assert!(verify(&db, 1, true).is_err());
        db.execute_batch("ROLLBACK").unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM pending_event_rows WHERE accounting_kind=4", [], |row| row.get::<_, i64>(0)).unwrap(), 1);
    }

    #[test]
    fn duplicate_private_identity_cannot_collapse_two_observations_to_one() {
        let db = database();
        add(&db, 1, 1, 120, None);
        add(&db, 2, 1, 120, None);
        begin(&db);
        clear_pending(&db);
        add(&db, 9, 1, 120, None);
        assert!(verify(&db, 1, true).is_err());
        db.execute_batch("ROLLBACK").unwrap();
    }

    #[test]
    fn weak_legacy_identity_needs_matching_prefix_and_unique_complete_observation() {
        for (same_prefix, duplicate) in [(true,false),(false,false),(true,true)] {
            let db = database();
            db.execute_batch("ATTACH DATABASE ':memory:' AS exact_stage_import; \
                CREATE TABLE exact_stage_import.manifest(complete INTEGER,size INTEGER,resume_offset INTEGER,prefix_sha256 BLOB,path TEXT,session_id TEXT)").unwrap();
            db.execute("INSERT INTO exact_stage_import.manifest VALUES(1,512,512,?1,'/fixture-source.jsonl','fixture')",
                params![vec![if same_prefix { 7_u8 } else { 8_u8 }; 32]]).unwrap();
            add(&db, 1, 1, 120, None);
            db.execute_batch("UPDATE usage_ledger_pending_bindings SET fingerprint=NULL,raw_offset=NULL; UPDATE pending_event_rows SET token_source_offset=NULL;").unwrap();
            begin(&db);
            clear_pending(&db);
            add(&db, 9, 1, 120, Some("filled-model"));
            if duplicate { add(&db, 10, 1, 120, Some("filled-model")); }
            db.execute_batch("UPDATE usage_ledger_pending_bindings SET fingerprint=NULL,raw_offset=NULL; UPDATE pending_event_rows SET token_source_offset=NULL;").unwrap();
            assert_eq!(verify(&db, 1, true).is_ok(), same_prefix && !duplicate);
            db.execute_batch("ROLLBACK").unwrap();
        }
    }

    #[test]
    fn weak_raw_location_must_be_inside_the_frozen_committed_prefix() {
        for offset in [-1, 0, 255, 256, 511, 512] {
            let db = database();
            db.execute_batch("ATTACH DATABASE ':memory:' AS exact_stage_import; \
                CREATE TABLE exact_stage_import.manifest(complete INTEGER,size INTEGER,resume_offset INTEGER,prefix_sha256 BLOB,path TEXT,session_id TEXT); \
                UPDATE pending_sources SET resume_offset=256").unwrap();
            db.execute("INSERT INTO exact_stage_import.manifest VALUES(1,512,512,?1,'/fixture-source.jsonl','fixture')",
                params![vec![7_u8; 32]]).unwrap();
            add(&db, 1, 1, 120, None);
            db.execute("UPDATE usage_ledger_pending_bindings SET fingerprint=NULL,raw_offset=?1", params![offset]).unwrap();
            begin(&db);
            clear_pending(&db);
            add(&db, 9, 1, 120, None);
            db.execute("UPDATE usage_ledger_pending_bindings SET fingerprint=NULL,raw_offset=?1", params![offset]).unwrap();
            assert_eq!(verify(&db, 1, true).is_ok(), (0..256).contains(&offset), "offset {offset}");
            db.execute_batch("ROLLBACK").unwrap();
        }
    }

    #[test]
    fn new_source_uses_no_snapshot_and_autocommit_is_refused() {
        let db = database();
        assert!(snapshot(&db, 1, 2).is_err());
        db.execute_batch("DELETE FROM pending_sources; BEGIN IMMEDIATE").unwrap();
        assert!(!snapshot(&db, 2, 2).unwrap());
        verify(&db, 2, false).unwrap();
        assert_eq!(temporary_count(&db), 0);
        db.execute_batch("ROLLBACK").unwrap();
    }

    #[test]
    fn mismatched_generation_and_unknown_pending_columns_are_protected() {
        let db = database();
        db.execute_batch("BEGIN IMMEDIATE").unwrap();
        assert!(snapshot(&db, 1, 3).is_err());
        db.execute_batch("ROLLBACK; ALTER TABLE pending_event_rows ADD COLUMN future_history TEXT; BEGIN IMMEDIATE").unwrap();
        assert!(snapshot(&db, 1, 2).is_err());
        db.execute_batch("ROLLBACK").unwrap();
    }
}
