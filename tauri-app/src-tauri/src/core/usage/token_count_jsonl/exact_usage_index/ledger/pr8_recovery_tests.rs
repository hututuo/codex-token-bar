//! Focused SQLite regressions for PR8 pending recovery contracts.
//!
//! Executes the branch production publisher and pending recovery entrypoints
//! against disposable SQLite. This does not assert full application startup.

use super::super::{Connection, TransactionBehavior};
use super::*;

const SOURCE: i64 = 41;
const GENERATION: i64 = 7;
const PATH: &str = "/fixture/pending.jsonl";

fn database() -> Connection {
    let db = Connection::open_in_memory().unwrap();
    db.pragma_update(None, "foreign_keys", true).unwrap();
    db.execute_batch(
        "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) WITHOUT ROWID;
         INSERT INTO metadata(key,value) VALUES('published_generation','0');
         INSERT INTO metadata(key,value) VALUES('building_generation','7');",
    )
    .unwrap();
    super::super::initialize_index_schema(&db).unwrap();
    super::install(&db).unwrap();
    db
}

#[test]
fn pending_binding_cascade_is_bounded_after_existing_ledger_upgrade() {
    let db = database();
    // Reproduce an already installed ledger from before the source index.
    db.execute_batch("DROP INDEX IF EXISTS usage_ledger_pending_binding_source").unwrap();
    db.execute_batch("BEGIN IMMEDIATE").unwrap();
    for source in 1..=128_i64 {
        db.execute("INSERT INTO sources(source_id,path,session_id,deleted,last_seen_generation,size,modified_ns,prefix_sha256,append_ready,audit_chunk_index) VALUES(?1,?2,'cascade-fixture',0,0,0,'0',X'',0,0)",params![source,format!("/fixture/cascade-{source}.jsonl")]).unwrap();
        db.execute("INSERT INTO pending_sources(source_id,target_generation,mode) VALUES(?1,7,'full')",[source]).unwrap();
        for event in 0..64_i64 {
            db.execute("INSERT INTO usage_ledger_pending_bindings(event_id,source_id,raw_generation,available) VALUES(?1,?2,7,1)",params![source*64+event,source]).unwrap();
        }
    }
    db.execute_batch("COMMIT").unwrap();
    let before: (i64,i64) = db.query_row("SELECT COUNT(*),SUM(event_id) FROM usage_ledger_pending_bindings",[],|r|Ok((r.get(0)?,r.get(1)?))).unwrap();
    super::install(&db).unwrap();
    super::install(&db).unwrap();
    assert_eq!(before,db.query_row("SELECT COUNT(*),SUM(event_id) FROM usage_ledger_pending_bindings",[],|r|Ok((r.get(0)?,r.get(1)?))).unwrap());
    let mut delete=db.prepare("DELETE FROM pending_sources WHERE source_id=?1").unwrap();
    assert_eq!(delete.execute([1_i64]).unwrap(),1);
    let scans=delete.get_status(rusqlite::StatementStatus::FullscanStep);
    assert!(scans<=64,"one source deletion scanned {scans} unrelated binding rows");
    assert_eq!(db.query_row("SELECT COUNT(*) FROM usage_ledger_pending_bindings",[],|r|r.get::<_,i64>(0)).unwrap(),127*64);
    assert_eq!(db.query_row("SELECT COUNT(*) FROM usage_ledger_pending_bindings WHERE source_id=1",[],|r|r.get::<_,i64>(0)).unwrap(),0);
    assert_eq!(db.query_row("SELECT COUNT(*) FROM sources",[],|r|r.get::<_,i64>(0)).unwrap(),128);
    assert!(!db.prepare("PRAGMA foreign_key_check").unwrap().query([]).unwrap().next().unwrap().is_some());
}

fn add_source(db: &Connection, mode: &str) {
    add_source_at(db, mode, PATH);
}

fn add_source_at(db: &Connection, mode: &str, path: &str) {
    db.execute(
        "INSERT INTO sources(source_id,path,session_id,deleted,last_seen_generation,size,modified_ns,
                            prefix_sha256,append_ready,resume_offset,audit_chunk_index)
         VALUES(?1,?2,'fixture-session',0,0,512,'0',?3,1,512,0)",
        params![SOURCE, path, vec![0xA5_u8; 32]],
    )
    .unwrap();
    db.execute(
        "INSERT INTO pending_sources(source_id,target_generation,mode,deleted,size,modified_ns,
                                     prefix_sha256,append_ready,resume_offset,audit_chunk_index)
         VALUES(?1,?2,?3,0,512,'0',?4,1,512,0)",
        params![SOURCE, GENERATION, mode, vec![0xA5_u8; 32]],
    )
    .unwrap();
}

fn add_event(db: &Connection, table: &str, id: i64, tokens: i64, bounds: [Option<i64>; 4]) {
    assert!(table == "event_rows" || table == "pending_event_rows");
    db.execute(
        &format!(
            "INSERT INTO {table}(
                id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,
                output_tokens,reasoning_output_tokens,model,user_prompt_start,user_prompt_end,
                assistant_response_start,assistant_response_end,accounting_kind,
                reported_total_tokens,token_source_offset,legacy_tokens
             ) VALUES(?1,?2,?1,?3,?4,?4,0,0,0,'fixture-model',?5,?6,?7,?8,0,NULL,?9,?4)"
        ),
        params![
            id,
            SOURCE,
            1_000 + id,
            tokens,
            bounds[0],
            bounds[1],
            bounds[2],
            bounds[3],
            100 * id,
        ],
    )
    .unwrap();
}

fn add_binding(db: &Connection, table: &str, id: i64, generation: i64, available: i64) {
    assert!(table == "usage_ledger_bindings" || table == "usage_ledger_pending_bindings");
    db.execute(
        &format!(
            "INSERT INTO {table}(
                event_id,source_id,raw_generation,raw_offset,user_prompt_start,user_prompt_end,
                assistant_response_start,assistant_response_end,fingerprint,available
             ) VALUES(?1,?2,?3,?4,NULL,NULL,NULL,NULL,NULL,?5)"
        ),
        params![id, SOURCE, generation, 100 * id, available],
    )
    .unwrap();
}

fn add_existing_120_and_pending_175(db: &Connection) {
    add_existing_120_and_pending_175_at(db, PATH);
}

fn add_existing_120_and_pending_175_at(db: &Connection, path: &str) {
    add_source_at(db, "full", path);
    db.execute(
        "INSERT INTO usage_ledger_sources(source_id,raw_generation,missing) VALUES(?1,0,0)",
        [SOURCE],
    )
    .unwrap();
    add_event(db, "event_rows", 1, 120, [None, None, None, None]);
    add_binding(db, "usage_ledger_bindings", 1, 0, 1);
    add_event(db, "pending_event_rows", 1, 120, [None, None, None, None]);
    add_event(db, "pending_event_rows", 2, 55, [None, None, None, None]);
    add_binding(db, "usage_ledger_pending_bindings", 1, GENERATION, 1);
    add_binding(db, "usage_ledger_pending_bindings", 2, GENERATION, 1);
}

#[test]
fn missing_source_retention_helper_publishes_pending_175_unavailable() {
    let mut db = database();
    add_existing_120_and_pending_175(&db);

    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    assert!(super::retain_pending_when_source_missing(&tx, SOURCE, GENERATION).unwrap());
    let pending: (i64, i64) = tx
        .query_row(
            "SELECT COUNT(*),SUM(tokens) FROM pending_event_rows WHERE source_id=?1",
            [SOURCE],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(pending, (2, 175));
    assert_eq!(
        tx.query_row(
            "SELECT COUNT(*) FROM usage_ledger_pending_bindings WHERE source_id=?1 AND available=0",
            [SOURCE],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        2
    );
    super::super::publish_schema11_pending_generation(&tx, GENERATION).unwrap();
    tx.commit().unwrap();

    let published: (i64, i64) = db
        .query_row(
            "SELECT COUNT(*),SUM(tokens) FROM event_rows WHERE source_id=?1",
            [SOURCE],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(published, (2, 175));
    assert_eq!(
        db.query_row(
            "SELECT missing FROM usage_ledger_sources WHERE source_id=?1",
            [SOURCE],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM usage_ledger_bindings WHERE source_id=?1 AND available<>0",
            [SOURCE],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        0
    );
}

#[test]
fn publication_fills_null_association_fields_but_preserves_known_values() {
    let mut db = database();
    add_source(&db, "full");
    db.execute(
        "INSERT INTO usage_ledger_sources(source_id,raw_generation,missing) VALUES(?1,0,0)",
        [SOURCE],
    )
    .unwrap();
    // The old canonical row knows both ends, while its starts are still NULL.
    add_event(
        &db,
        "event_rows",
        1,
        120,
        [None, Some(901), None, Some(902)],
    );
    add_binding(&db, "usage_ledger_bindings", 1, 0, 1);
    add_event(
        &db,
        "pending_event_rows",
        1,
        120,
        [Some(11), Some(12), Some(21), Some(22)],
    );
    add_binding(&db, "usage_ledger_pending_bindings", 1, GENERATION, 1);

    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    super::super::publish_schema11_pending_generation(&tx, GENERATION).unwrap();
    tx.commit().unwrap();

    let bounds: (Option<i64>, Option<i64>, Option<i64>, Option<i64>) = db
        .query_row(
            "SELECT user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end
             FROM event_rows WHERE id=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(bounds, (Some(11), Some(901), Some(21), Some(902)));
}

#[test]
fn pending_preservation_helper_rejects_known_association_conflict_and_rollback_keeps_old_value() {
    let mut db = database();
    add_source(&db, "full");
    add_event(
        &db,
        "event_rows",
        1,
        120,
        [Some(11), Some(12), Some(21), Some(22)],
    );
    add_binding(&db, "usage_ledger_bindings", 1, 0, 1);
    add_event(
        &db,
        "pending_event_rows",
        1,
        120,
        [Some(11), Some(12), Some(21), Some(22)],
    );
    add_binding(&db, "usage_ledger_pending_bindings", 1, GENERATION, 1);

    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    let had_snapshot = super::snapshot_pending_import(&tx, SOURCE, GENERATION).unwrap();
    assert!(had_snapshot);
    tx.execute(
        "UPDATE pending_event_rows SET assistant_response_start=999 WHERE id=1",
        [],
    )
    .unwrap();
    assert!(super::verify_pending_import(&tx, SOURCE, had_snapshot).is_err());
    tx.rollback().unwrap();

    assert_eq!(
        db.query_row(
            "SELECT assistant_response_start FROM pending_event_rows WHERE id=1",
            [],
            |row| row.get::<_, Option<i64>>(0),
        )
        .unwrap(),
        Some(21)
    );
}

#[test]
fn pending_preservation_helper_allows_null_to_known_associations() {
    let mut db = database();
    add_source(&db, "full");
    add_event(&db, "event_rows", 1, 120, [None, None, None, None]);
    add_binding(&db, "usage_ledger_bindings", 1, 0, 1);
    add_event(&db, "pending_event_rows", 1, 120, [None, None, None, None]);
    add_binding(&db, "usage_ledger_pending_bindings", 1, GENERATION, 1);

    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    let had_snapshot = super::snapshot_pending_import(&tx, SOURCE, GENERATION).unwrap();
    tx.execute(
        "UPDATE pending_event_rows SET user_prompt_start=11,user_prompt_end=12,
             assistant_response_start=21,assistant_response_end=22 WHERE id=1",
        [],
    )
    .unwrap();
    assert!(super::verify_pending_import(&tx, SOURCE, had_snapshot).is_ok());
    tx.commit().unwrap();

    assert_eq!(
        db.query_row(
            "SELECT user_prompt_start,assistant_response_start FROM pending_event_rows WHERE id=1",
            [],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .unwrap(),
        (Some(11), Some(21))
    );
}

#[test]
fn unknown_pending_fingerprint_column_refuses_snapshot_without_losing_value() {
    let mut db = database();
    add_source(&db, "full");
    db.execute_batch("ALTER TABLE pending_fingerprints ADD COLUMN future_history TEXT")
        .unwrap();
    db.execute(
        "INSERT INTO pending_fingerprints(source_id,fingerprint,future_history)
         VALUES(?1,X'01','must-survive')",
        [SOURCE],
    )
    .unwrap();

    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    assert!(super::snapshot_pending_import(&tx, SOURCE, GENERATION).is_err());
    tx.rollback().unwrap();

    assert_eq!(
        db.query_row(
            "SELECT future_history FROM pending_fingerprints WHERE source_id=?1",
            [SOURCE],
            |row| row.get::<_, String>(0),
        )
        .unwrap(),
        "must-survive"
    );
}

fn missing_raw_in_temporary_home() -> (tempfile::TempDir, std::path::PathBuf) {
    let temp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(temp.path().join("sessions")).unwrap();
    let canonical_home = std::fs::canonicalize(temp.path()).unwrap();
    let raw = canonical_home
        .join("sessions")
        .join("missing-pending.jsonl");
    let mut compressed_name = raw.as_os_str().to_os_string();
    compressed_name.push(".zst");
    assert!(!raw.exists());
    assert!(!std::path::PathBuf::from(compressed_name).exists());
    (temp, raw)
}

fn assert_published_missing_175(db: &Connection) {
    let published: (i64, i64) = db
        .query_row(
            "SELECT COUNT(*),SUM(tokens) FROM event_rows WHERE source_id=?1",
            [SOURCE],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(published, (2, 175));
    assert_eq!(
        db.query_row(
            "SELECT missing FROM usage_ledger_sources WHERE source_id=?1",
            [SOURCE],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM usage_ledger_bindings WHERE source_id=?1 AND available<>0",
            [SOURCE],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        0
    );
}

// Production Rust function-level SQLite entry test only. It enters the normal
// publish-input consistency path with a canonical temporary Home whose raw and
// compressed representations are both absent; it is not full-App coverage.
#[test]
fn ordinary_publish_input_validation_entry_retains_and_publishes_pending_175() {
    let (_home, raw) = missing_raw_in_temporary_home();
    let canonical_home = raw.parent().unwrap().parent().unwrap().to_path_buf();
    let path = raw.to_string_lossy().into_owned();
    let mut db = database();
    add_existing_120_and_pending_175_at(&db, &path);

    super::super::validate_building_generation_commit_scope(&mut db, GENERATION, &canonical_home)
        .unwrap();
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*),SUM(tokens) FROM pending_event_rows WHERE source_id=?1",
            [SOURCE],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )
        .unwrap(),
        (2, 175)
    );
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    super::super::publish_schema11_pending_generation(&tx, GENERATION).unwrap();
    tx.commit().unwrap();

    // Read back after commit from the canonical tables, not from fixture memory.
    assert_published_missing_175(&db);
}

// Production Rust function-level SQLite entry test only. The caller normally
// reaches this helper after an enrichment candidate's raw file disappeared;
// this invokes that entry directly and then the real generation publisher.
#[test]
fn enrichment_missing_source_entry_retains_and_publishes_pending_175() {
    let (_home, raw) = missing_raw_in_temporary_home();
    let path = raw.to_string_lossy().into_owned();
    let mut db = database();
    add_existing_120_and_pending_175_at(&db, &path);
    let candidate = super::super::EventEnrichmentCandidate {
        path,
        session_id: "fixture-session".into(),
        signature: super::super::FileSignature {
            size: 512,
            modified_ns: 0,
            physical: None,
        },
        prefix_sha256: [0xA5; 32],
    };

    super::super::record_missing_event_enrichment_source(&mut db, GENERATION, &candidate).unwrap();
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*),SUM(tokens) FROM pending_event_rows WHERE source_id=?1",
            [SOURCE],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )
        .unwrap(),
        (2, 175)
    );
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    super::super::publish_schema11_pending_generation(&tx, GENERATION).unwrap();
    tx.commit().unwrap();

    // Read back after commit from the canonical tables, not from fixture memory.
    assert_published_missing_175(&db);
}

#[test]
fn publication_refuses_unknown_pending_fingerprint_history_before_clearing_rows() {
    let mut db = database();
    add_existing_120_and_pending_175(&db);
    db.execute_batch("ALTER TABLE pending_fingerprints ADD COLUMN future_history TEXT;         INSERT INTO pending_fingerprints(source_id,fingerprint,future_history) VALUES(41,X'010203','keep-me');").unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    assert!(super::super::publish_schema11_pending_generation(&tx, GENERATION).is_err());
    drop(tx);
    assert_eq!(
        db.query_row(
            "SELECT future_history FROM pending_fingerprints WHERE source_id=41",
            [],
            |row| row.get::<_, String>(0)
        )
        .unwrap(),
        "keep-me"
    );
    assert_eq!(
        db.query_row("SELECT SUM(tokens) FROM event_rows", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        120
    );
}
