//! Displaced observations survive a source replacement/deletion. These tables
//! contain evidence, not a second aggregate to blindly add to current events.
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashSet;

const REVISION: &str = "2";
const WRITER_REVISION: &str = "4";

pub(super) fn validate(db: &Connection) -> Result<(), String> {
    let exists: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='retained_usage_meta')", [], |r| r.get(0)).map_err(|e| e.to_string())?;
    if !exists { return Ok(()); }
    let stored: Option<String> = db.query_row("SELECT value FROM retained_usage_meta WHERE key='schema_version'", [], |r| r.get(0)).optional().map_err(|e| e.to_string())?;
    if stored.as_deref() != Some("1") && stored.as_deref() != Some(REVISION) {
        return Err(format!("Unsupported history retention revision {stored:?}; preserved index"));
    }
    let writer: Option<String> = db.query_row("SELECT value FROM retained_usage_meta WHERE key='writer_revision'", [], |r| r.get(0)).optional().map_err(|e| e.to_string())?;
    if writer.as_deref().is_some_and(|v| v != "2" && v != "3" && v != WRITER_REVISION) {
        return Err(format!("Unsupported history retention writer {writer:?}; preserved index"));
    }
    Ok(())
}

pub(super) fn install(db: &Connection) -> Result<(), String> {
    validate(db)?;
    let mut statement = db.prepare("PRAGMA table_info(event_rows)").map_err(|e| e.to_string())?;
    let columns: HashSet<String> = statement.query_map([], |r| r.get(1)).map_err(|e| e.to_string())?.collect::<Result<_, _>>().map_err(|e| e.to_string())?;
    let optional = ["accounting_kind", "reported_total_tokens", "legacy_tokens"];
    let mut source_statement = db.prepare("PRAGMA table_info(sources)").map_err(|e| e.to_string())?;
    let source_columns: HashSet<String> = source_statement.query_map([], |r| r.get(1)).map_err(|e| e.to_string())?.collect::<Result<_, _>>().map_err(|e| e.to_string())?;
    let has_bindings = super::table_exists_checked(db,"usage_ledger_bindings")?;
    let flavor = format!("{}|accounting_state={}|writer={WRITER_REVISION}|bindings={has_bindings}",
        optional.iter().filter(|c| columns.contains(**c)).copied().collect::<Vec<_>>().join(","),source_columns.contains("accounting_state"));
    let trigger_count: i64 = db.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('retain_usage_before_event_delete','retain_usage_before_source_delete','retain_usage_before_identity_update','retain_usage_before_fingerprint_delete','retain_usage_before_event_update')", [], |r| r.get(0)).map_err(|e| e.to_string())?;
    if trigger_count == 5 {
        let previous: Option<String> = db.query_row("SELECT value FROM retained_usage_meta WHERE key='event_columns'", [], |r| r.get(0)).optional().map_err(|e| e.to_string())?;
        if previous.as_deref() == Some(&flavor) { return Ok(()); }
    }
    db.execute_batch("SAVEPOINT install_usage_retention").map_err(|e| e.to_string())?;
    let result = install_transaction(db, &columns, &source_columns, &flavor);
    match result {
        Ok(()) => db.execute_batch("RELEASE install_usage_retention").map_err(|e| e.to_string()),
        Err(error) => {
            let _ = db.execute_batch("ROLLBACK TO install_usage_retention; RELEASE install_usage_retention");
            Err(error)
        }
    }
}

fn install_transaction(db: &Connection, columns: &HashSet<String>, source_columns: &HashSet<String>, flavor: &str) -> Result<(), String> {
    db.execute_batch(r#"
        CREATE TABLE IF NOT EXISTS retained_usage_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS retained_usage_sources(
            snapshot_id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL, session_id TEXT NOT NULL, path TEXT NOT NULL,
            signature TEXT NOT NULL, parser_revision TEXT NOT NULL, reason TEXT NOT NULL,
            UNIQUE(source_id,session_id,path,signature,parser_revision)
        );
        CREATE TABLE IF NOT EXISTS retained_usage_events(
            snapshot_id INTEGER NOT NULL REFERENCES retained_usage_sources(snapshot_id),
            position INTEGER NOT NULL, timestamp REAL NOT NULL, tokens INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL, reasoning_output_tokens INTEGER NOT NULL,
            model TEXT, accounting_kind INTEGER, reported_total_tokens INTEGER, legacy_tokens INTEGER,
            PRIMARY KEY(snapshot_id,position)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS retained_usage_fingerprints(
            snapshot_id INTEGER NOT NULL REFERENCES retained_usage_sources(snapshot_id),
            value BLOB NOT NULL, PRIMARY KEY(snapshot_id,value)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS retained_usage_checkpoints(
            snapshot_id INTEGER PRIMARY KEY REFERENCES retained_usage_sources(snapshot_id),
            append_ready INTEGER NOT NULL, resume_offset INTEGER, previous_total_tokens INTEGER,
            is_explicit_subagent_fork INTEGER NOT NULL, accounting_state TEXT
        );
        CREATE TABLE IF NOT EXISTS retained_usage_revisions(
            revision_id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL, session_id TEXT NOT NULL, path TEXT NOT NULL,
            signature TEXT NOT NULL, parser_revision TEXT NOT NULL,
            position INTEGER NOT NULL, timestamp REAL NOT NULL, tokens INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL, reasoning_output_tokens INTEGER NOT NULL,
            model TEXT, accounting_kind INTEGER, reported_total_tokens INTEGER, legacy_tokens INTEGER
        );
        CREATE INDEX IF NOT EXISTS retained_usage_revisions_source ON retained_usage_revisions(source_id,position);
        DROP TRIGGER IF EXISTS retain_usage_before_event_update;
        DROP TRIGGER IF EXISTS retain_usage_before_event_delete;
        DROP TRIGGER IF EXISTS retain_usage_before_source_delete;
        DROP TRIGGER IF EXISTS retain_usage_before_identity_update;
        DROP TRIGGER IF EXISTS retain_usage_before_fingerprint_delete;
    "#).map_err(|e| e.to_string())?;
    let location_columns=["user_prompt_start","user_prompt_end","assistant_response_start","assistant_response_end","token_source_offset"];
    for table in ["retained_usage_events","retained_usage_revisions"] {
        let mut stmt=db.prepare(&format!("PRAGMA table_info({table})")).map_err(|e|e.to_string())?;
        let existing: HashSet<String>=stmt.query_map([],|r|r.get(1)).map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
        for column in location_columns.iter().filter(|c| !existing.contains(**c)) {
            db.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} INTEGER")).map_err(|e|e.to_string())?;
        }
    }
    let has_bindings=super::table_exists_checked(db,"usage_ledger_bindings")?;
    let location_expressions=|prefix: &str| location_columns.iter().map(|c| {
        if has_bindings {
            let raw=if *c=="token_source_offset" {"raw_offset"} else {*c};
            format!("(SELECT b.{raw} FROM usage_ledger_bindings b WHERE b.event_id={prefix}.id)")
        } else if columns.contains(*c) { format!("{prefix}.{c}") } else { "NULL".into() }
    }).collect::<Vec<_>>();
    let locations=|prefix: &str| location_expressions(prefix).join(",");
    let event_locations=locations("e");
    let old_locations=locations("OLD");
    let signature = "CAST(s.size AS TEXT)||':'||s.modified_ns||':'||hex(s.prefix_sha256)||':'||CAST(s.last_seen_generation AS TEXT)";
    let parser = "COALESCE((SELECT parser_revision FROM source_enrichment WHERE source_id=s.source_id),(SELECT value FROM metadata WHERE key='fork_replay_boundary_revision'),'legacy')";
    let accounting_state = if source_columns.contains("accounting_state") { "s.accounting_state" } else { "NULL" };
    let snapshot = |filter: &str, reason: &str| format!(r#"
        INSERT OR IGNORE INTO retained_usage_sources(source_id,session_id,path,signature,parser_revision,reason)
        SELECT s.source_id,s.session_id,s.path,{signature},{parser},'{reason}' FROM sources s WHERE {filter};
        INSERT OR IGNORE INTO retained_usage_checkpoints
        SELECT h.snapshot_id,s.append_ready,s.resume_offset,s.previous_total_tokens,s.is_explicit_subagent_fork,{accounting_state}
        FROM sources s JOIN retained_usage_sources h ON h.source_id=s.source_id AND h.session_id=s.session_id
            AND h.path=s.path AND h.signature=({signature}) AND h.parser_revision=({parser})
        WHERE {filter};
    "#);
    let join = format!("h.source_id=s.source_id AND h.session_id=s.session_id AND h.path=s.path AND h.signature=({signature}) AND h.parser_revision=({parser})");
    let values = ["accounting_kind", "reported_total_tokens", "legacy_tokens"].iter().map(|c| if columns.contains(*c) { format!("e.{c}") } else { "NULL".into() }).collect::<Vec<_>>().join(",");
    let mut compared = vec!["timestamp", "tokens", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "model"];
    compared.extend(["accounting_kind", "reported_total_tokens", "legacy_tokens"].into_iter().filter(|c| columns.contains(*c)));
    let differs = compared.iter().map(|c| format!("prior.{c} IS NOT e.{c}"))
        .chain(location_columns.iter().zip(location_expressions("e")).map(|(c,raw)|format!("prior.{c} IS NOT {raw}")))
        .collect::<Vec<_>>().join(" OR ");
    let records = |filter: &str| format!(r#"
        INSERT INTO retained_usage_revisions(
            source_id,session_id,path,signature,parser_revision,position,timestamp,tokens,
            input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,
            model,accounting_kind,reported_total_tokens,legacy_tokens,
            user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,token_source_offset
        ) SELECT s.source_id,s.session_id,s.path,{signature},{parser},
            e.ordinal,e.timestamp,e.tokens,e.input_tokens,e.cached_input_tokens,
            e.output_tokens,e.reasoning_output_tokens,e.model,{values},{event_locations}
        FROM event_rows e JOIN sources s ON s.source_id=e.source_id
        JOIN retained_usage_sources h ON {join}
        JOIN retained_usage_events prior ON prior.snapshot_id=h.snapshot_id AND prior.position=e.ordinal
        WHERE ({filter}) AND ({differs});
        INSERT OR IGNORE INTO retained_usage_events
        SELECT h.snapshot_id,e.ordinal,e.timestamp,e.tokens,e.input_tokens,e.cached_input_tokens,
            e.output_tokens,e.reasoning_output_tokens,e.model,{values},{event_locations}
        FROM event_rows e JOIN sources s ON s.source_id=e.source_id
        JOIN retained_usage_sources h ON {join} WHERE {filter};
    "#);
    let fingerprints = |filter: &str| format!(r#"
        INSERT OR IGNORE INTO retained_usage_fingerprints
        SELECT h.snapshot_id,f.fingerprint FROM source_fingerprints f JOIN sources s ON s.source_id=f.source_id
        JOIN retained_usage_sources h ON {join} WHERE {filter};
    "#);
    let mut value_columns = vec!["source_id", "ordinal", "timestamp", "tokens", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "model"];
    value_columns.extend(["accounting_kind", "reported_total_tokens", "legacy_tokens"].into_iter().filter(|c| columns.contains(*c)));
    value_columns.extend(location_columns.iter().copied().filter(|c| columns.contains(*c)));
    let changed = value_columns.iter().map(|c| format!("OLD.{c} IS NOT NEW.{c}")).collect::<Vec<_>>().join(" OR ");
    let old_optional = ["accounting_kind", "reported_total_tokens", "legacy_tokens"].iter().map(|c| if columns.contains(*c) { format!("OLD.{c}") } else { "NULL".into() }).collect::<Vec<_>>().join(",");
    db.execute_batch(&format!(r#"
        CREATE TRIGGER retain_usage_before_event_update BEFORE UPDATE ON event_rows
        WHEN {changed} BEGIN
            INSERT INTO retained_usage_revisions(
                source_id,session_id,path,signature,parser_revision,position,timestamp,tokens,
                input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,
                model,accounting_kind,reported_total_tokens,legacy_tokens,
                user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,token_source_offset
            ) SELECT OLD.source_id,s.session_id,s.path,{signature},{parser},
                OLD.ordinal,OLD.timestamp,OLD.tokens,OLD.input_tokens,OLD.cached_input_tokens,
                OLD.output_tokens,OLD.reasoning_output_tokens,OLD.model,{old_optional},{old_locations}
              FROM sources s WHERE s.source_id=OLD.source_id;
        END;
        CREATE TRIGGER retain_usage_before_event_delete BEFORE DELETE ON event_rows BEGIN
            {event_snapshot} {event_rows}
        END;
        CREATE TRIGGER retain_usage_before_source_delete BEFORE DELETE ON sources BEGIN
            {source_snapshot} {source_rows} {source_fingerprints}
        END;
        CREATE TRIGGER retain_usage_before_identity_update BEFORE UPDATE OF path,session_id ON sources
        WHEN OLD.path IS NOT NEW.path OR OLD.session_id IS NOT NEW.session_id BEGIN
            {identity_snapshot} {source_rows} {source_fingerprints}
        END;
        CREATE TRIGGER retain_usage_before_fingerprint_delete BEFORE DELETE ON source_fingerprints BEGIN
            {event_snapshot} {fingerprint_row}
        END;
    "#,
        event_snapshot=snapshot("s.source_id=OLD.source_id", "event-replaced"),
        event_rows=records("e.source_id=OLD.source_id AND e.ordinal=OLD.ordinal"),
        source_snapshot=snapshot("s.source_id=OLD.source_id", "source-unavailable"),
        source_rows=records("e.source_id=OLD.source_id"),
        source_fingerprints=fingerprints("f.source_id=OLD.source_id"),
        identity_snapshot=snapshot("s.source_id=OLD.source_id", "source-identity-changed"),
        fingerprint_row=fingerprints("f.source_id=OLD.source_id AND f.fingerprint=OLD.fingerprint"),
    )).map_err(|e| e.to_string())?;
    for (key,value) in [("schema_version",REVISION),("writer_revision",WRITER_REVISION),("event_columns",flavor)] {
        db.execute("INSERT INTO retained_usage_meta(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,value]).map_err(|e|e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON; CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);").unwrap();
        super::super::initialize_index_schema(&db).unwrap();
        install(&db).unwrap();
        db.execute_batch(r#"
            INSERT INTO sources(source_id,path,session_id,size,modified_ns,prefix_sha256,last_seen_generation)
            VALUES(1,'/old/source.jsonl','child',1000,'100',x'ABCD',1);
            INSERT INTO event_rows(id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model)
            VALUES(1,1,100,1000,80,70,50,10,2,'gpt-5.6-sol'),(2,1,200,1001,20,18,10,2,1,'gpt-5.6-sol');
            INSERT INTO source_fingerprints(source_id,fingerprint) VALUES(1,x'0000000000000000000000');
        "#).unwrap();
        db
    }

    fn scalar(db: &Connection, sql: &str) -> i64 {
        db.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn replacement_preserves_evidence_without_double_counting_projection() {
        let mut db = fixture();
        let tx = db.transaction().unwrap();
        tx.execute_batch(r#"
            DELETE FROM event_rows WHERE source_id=1;
            DELETE FROM source_fingerprints WHERE source_id=1;
            INSERT INTO event_rows(id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model)
            VALUES(3,1,10,1001,20,18,10,2,1,'gpt-5.6-sol'),(4,1,20,1002,5,4,2,1,0,'gpt-5.6-sol');
        "#).unwrap();
        tx.commit().unwrap();
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_events"),100);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_fingerprints"),1);
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM event_rows"),25);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_events WHERE model='gpt-5.6-sol' AND accounting_kind=0"),2);
    }

    #[test]
    fn source_cascade_keeps_historical_events_and_fingerprints() {
        let db=fixture();
        db.execute_batch("DELETE FROM sources WHERE source_id=1").unwrap();
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM sources"),0);
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_events"),100);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_fingerprints"),1);
    }

    #[test]
    fn interrupted_replacement_rolls_back_evidence_and_deletion() {
        let mut db=fixture();
        let tx=db.transaction().unwrap();
        tx.execute_batch("DELETE FROM sources WHERE source_id=1").unwrap();
        tx.rollback().unwrap();
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM event_rows"),100);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_events"),0);
    }

    #[test]
    fn changed_source_identity_preserves_original_owner() {
        let db=fixture();
        db.execute_batch("UPDATE sources SET session_id='new-owner',path='/new/file' WHERE source_id=1").unwrap();
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_sources WHERE session_id='child' AND path='/old/source.jsonl'"),1);
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_events"),100);
    }

    #[test]
    fn unchanged_reopen_does_not_write() {
        let db=fixture();
        let before=scalar(&db,"SELECT total_changes()");
        install(&db).unwrap();
        assert_eq!(scalar(&db,"SELECT total_changes()"),before);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_events"),0);
    }

    #[test]
    fn future_contract_is_preserved_and_rejected() {
        let db=fixture();
        db.execute_batch("UPDATE retained_usage_meta SET value='999' WHERE key='schema_version'").unwrap();
        assert!(install(&db).is_err());
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM event_rows"),100);
    }
    #[test]
    fn accounting_and_model_changes_keep_prior_versions_but_noop_does_not() {
        let db=fixture();
        db.execute_batch("UPDATE event_rows SET tokens=70,input_tokens=60 WHERE source_id=1 AND ordinal=100;
            UPDATE event_rows SET model='corrected-model' WHERE source_id=1 AND ordinal=100;
            UPDATE event_rows SET tokens=tokens,model=model WHERE source_id=1;").unwrap();
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_revisions"),2);
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_revisions"),150);
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM event_rows"),90);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_revisions WHERE model='gpt-5.6-sol'"),2);
    }

    #[test]
    fn missing_protection_trigger_is_reinstalled() {
        let db=fixture();
        db.execute_batch("DROP TRIGGER retain_usage_before_source_delete").unwrap();
        install(&db).unwrap();
        db.execute_batch("DELETE FROM sources WHERE source_id=1").unwrap();
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_events"),100);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_fingerprints"),1);
    }

    #[test]
    fn repeated_replacement_at_same_position_and_signature_preserves_each_version() {
        let db=fixture();
        db.execute_batch("DELETE FROM event_rows WHERE source_id=1 AND ordinal=100;
            INSERT INTO event_rows(id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind)
            VALUES(3,1,100,1000,9,8,3,1,0,'another-model',0);
            DELETE FROM sources WHERE source_id=1;").unwrap();
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_events"),100);
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_revisions"),9);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_revisions WHERE model='another-model'"),1);
    }

    #[test]
    fn retained_checkpoint_survives_replacement_without_resuming_new_file() {
        let db=fixture();
        db.execute_batch("UPDATE sources SET append_ready=1,resume_offset=999,previous_total_tokens=300,is_explicit_subagent_fork=1,accounting_state='old-counter-proof' WHERE source_id=1;
            DELETE FROM event_rows WHERE source_id=1;
            UPDATE sources SET resume_offset=25,previous_total_tokens=5,accounting_state='new-counter-proof' WHERE source_id=1;").unwrap();
        assert_eq!(scalar(&db,"SELECT resume_offset FROM retained_usage_checkpoints"),999);
        assert_eq!(scalar(&db,"SELECT previous_total_tokens FROM retained_usage_checkpoints"),300);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_checkpoints WHERE accounting_state='old-counter-proof' AND is_explicit_subagent_fork=1"),1);
    }

    #[test]
    fn future_writer_is_rejected_before_maintenance() {
        let db=fixture();
        db.execute_batch("UPDATE retained_usage_meta SET value='999' WHERE key='writer_revision'").unwrap();
        assert!(validate(&db).is_err()); assert!(install(&db).is_err());
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM event_rows"),100);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_events"),0);
    }

    #[test]
    #[ignore = "set CODEX_TOKEN_BAR_RETENTION_RUST_FIXTURE to an immutable, closed historical snapshot"]
    fn protected_historical_fixture_preserves_every_numeric_column() {
        let input=std::env::var("CODEX_TOKEN_BAR_RETENTION_RUST_FIXTURE").unwrap();
        let root=std::env::temp_dir().join(format!("retention-real-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&root).unwrap();
        let copy=root.join("isolated.sqlite");
        std::fs::copy(input,&copy).unwrap();
        let db=Connection::open(&copy).unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        let all_fields="id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind,reported_total_tokens,legacy_tokens";
        db.execute_batch(&format!("CREATE TABLE test_expected_upgrade AS SELECT {all_fields} FROM event_rows")).unwrap();
        let home:String=db.query_row("SELECT value FROM metadata WHERE key='codex_home_identity'",[],|r|r.get(0)).unwrap();
        super::super::ExactUsageIndex::reset_scan_bytes_for_testing();
        drop(super::super::ExactUsageIndex::open_at(std::path::Path::new(&home),copy.clone()).unwrap());
        assert_eq!(super::super::ExactUsageIndex::scan_bytes_for_testing(),(0,0));
        assert_eq!(scalar(&db,&format!("SELECT COUNT(*) FROM (SELECT * FROM test_expected_upgrade EXCEPT SELECT {all_fields} FROM event_rows)")),0);
        assert_eq!(scalar(&db,&format!("SELECT COUNT(*) FROM (SELECT {all_fields} FROM event_rows EXCEPT SELECT * FROM test_expected_upgrade)")),0);
        let upgraded_count=scalar(&db,"SELECT COUNT(*) FROM event_rows");
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM usage_ledger_bindings"),upgraded_count);
        println!("Real Rust schema12 to13: {upgraded_count} rows unchanged, bindings complete, JSONL parse 0");
        db.execute_batch("DROP TABLE test_expected_upgrade").unwrap();
        let source=scalar(&db,"SELECT source_id FROM event_rows GROUP BY source_id ORDER BY COUNT(*) DESC LIMIT 1");
        let fields="timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind,reported_total_tokens,legacy_tokens";
        db.execute(&format!("CREATE TEMP TABLE expected AS SELECT ordinal AS position,{fields} FROM event_rows WHERE source_id=?1"),[source]).unwrap();
        db.execute("DELETE FROM sources WHERE source_id=?1",[source]).unwrap();
        let retained=format!("SELECT position,{fields} FROM retained_usage_events");
        assert_eq!(scalar(&db,&format!("SELECT COUNT(*) FROM (SELECT * FROM expected EXCEPT {retained})")),0);
        assert_eq!(scalar(&db,&format!("SELECT COUNT(*) FROM ({retained} EXCEPT SELECT * FROM expected)")),0);
        let expected=scalar(&db,"SELECT COUNT(*) FROM expected");
        assert!(expected>0);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_events"),expected);
        println!("Protected historical Rust fixture: {expected} event rows preserved field-for-field");
        drop(db);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn old_retention_revision_adds_locations_without_discarding_old_evidence() {
        let db=fixture();
        db.execute_batch("DELETE FROM event_rows WHERE source_id=1 AND ordinal=100").unwrap();
        for name in ["event_delete","source_delete","identity_update","fingerprint_delete","event_update"] {
            db.execute_batch(&format!("DROP TRIGGER retain_usage_before_{name}")).unwrap();
        }
        for table in ["retained_usage_events","retained_usage_revisions"] {
            for column in ["user_prompt_start","user_prompt_end","assistant_response_start","assistant_response_end","token_source_offset"] {
                db.execute_batch(&format!("ALTER TABLE {table} DROP COLUMN {column}")).unwrap();
            }
        }
        db.execute_batch("UPDATE retained_usage_meta SET value='1' WHERE key='schema_version'; DELETE FROM retained_usage_meta WHERE key='writer_revision';").unwrap();
        install(&db).unwrap();
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_events"),80);
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_events WHERE token_source_offset IS NULL"),1);
        db.execute_batch("UPDATE event_rows SET user_prompt_start=120,assistant_response_start=150,token_source_offset=200 WHERE source_id=1 AND ordinal=200; DELETE FROM sources WHERE source_id=1;").unwrap();
        assert_eq!(scalar(&db,"SELECT COUNT(*) FROM retained_usage_events WHERE user_prompt_start=120 AND assistant_response_start=150 AND token_source_offset=200"),1);
        assert_eq!(scalar(&db,"SELECT SUM(tokens) FROM retained_usage_events"),100);
    }

}
