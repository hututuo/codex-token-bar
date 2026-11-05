use super::*;
use rusqlite::{types::Value, StatementStatus};

// Previous production selector is an independent semantic oracle. Keep its
// generation/deletion rules while changing the amount of unrelated work.
const REFERENCE: &str = r#"
    SELECT ?1, b.bucket_start, b.model_key, MAX(b.model),
           SUM(b.total_tokens), SUM(b.calls), SUM(b.input_tokens),
           SUM(b.cached_input_tokens), SUM(b.output_tokens)
    FROM dashboard_file_5m b
    JOIN (SELECT path, MAX(generation) AS generation FROM files
          WHERE generation <= ?1 GROUP BY path) latest
      ON latest.generation=b.file_generation AND latest.path=b.file_path
    JOIN files f ON f.generation=latest.generation AND f.path=latest.path AND f.deleted=0
    WHERE b.bucket_start BETWEEN ?2 AND ?3
    GROUP BY b.bucket_start,b.model_key
"#;

fn database() -> Connection {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(
        "PRAGMA foreign_keys=ON;
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) WITHOUT ROWID;
        INSERT INTO metadata VALUES('published_generation','5'),('building_generation','7');",
    )
    .unwrap();
    super::super::initialize_index_schema(&db).unwrap();
    db
}

fn source(db: &Connection, id: i64, bucket: i64, tokens: i64) {
    db.execute(
        "INSERT INTO sources(source_id,path,session_id,last_seen_generation)
        VALUES(?1,?2,'range-test',5)",
        params![id, format!("/fixture/{id}.jsonl")],
    )
    .unwrap();
    db.execute(
        "INSERT INTO dashboard_source_5m VALUES(?1,?2,'m','m',?3,1,?3,0,0)",
        params![id, bucket, tokens],
    )
    .unwrap();
}

fn pending(db: &Connection, id: i64, mode: &str, tokens: Option<i64>) {
    db.execute(
        "INSERT INTO pending_sources(source_id,target_generation,mode,deleted)
        VALUES(?1,7,?2,?3)",
        params![id, mode, i64::from(mode == "tombstone")],
    )
    .unwrap();
    if let Some(tokens) = tokens {
        db.execute(
            "INSERT INTO pending_dashboard_source_5m VALUES(?1,300,'m','m',?2,1,?2,0,0)",
            params![id, tokens],
        )
        .unwrap();
    }
}

fn rows(
    db: &Connection,
    sql: &str,
    generation: i64,
    start: i64,
    end: i64,
) -> rusqlite::Result<Vec<Vec<Value>>> {
    let mut statement = db.prepare(sql)?;
    let values = statement.query_map(params![generation, start, end], |r| {
        (0..9).map(|i| r.get(i)).collect()
    })?;
    values.collect()
}

fn candidate_select() -> &'static str {
    INSERT_RANGE_SQL.split_once(')').unwrap().1
}

#[test]
fn dashboard_range_ignores_unrelated_sources_after_existing_index_upgrade() {
    let db = database();
    db.execute_batch("BEGIN IMMEDIATE").unwrap();
    for id in 1..=1024 {
        source(&db, id, id * 300, 10);
        db.execute(
            "INSERT INTO pending_sources(source_id,target_generation,mode) VALUES(?1,7,'full')",
            [id],
        )
        .unwrap();
        db.execute(
            "INSERT INTO pending_dashboard_source_5m VALUES(?1,?2,'m','m',20,1,20,0,0)",
            params![id, id * 300],
        )
        .unwrap();
    }
    db.execute_batch("COMMIT; DROP INDEX pending_dashboard_source_5m_time_idx")
        .unwrap();
    let before: (i64, i64) = db
        .query_row(
            "SELECT COUNT(*),SUM(total_tokens) FROM pending_dashboard_source_5m",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    install(&db).unwrap();
    install(&db).unwrap();
    assert_eq!(
        before,
        db.query_row(
            "SELECT COUNT(*),SUM(total_tokens) FROM pending_dashboard_source_5m",
            [],
            |r| Ok((r.get(0)?, r.get(1)?))
        )
        .unwrap()
    );
    let mut insert = db.prepare(INSERT_RANGE_SQL).unwrap();
    insert.execute(params![7, 300, 300]).unwrap();
    let scans = insert.get_status(StatementStatus::FullscanStep);
    let automatic = insert.get_status(StatementStatus::AutoIndex);
    let steps = insert.get_status(StatementStatus::VmStep);
    assert!(
        scans < 64 && automatic == 0 && steps < 10_000,
        "one bucket scanned unrelated sources: scans={scans}, automatic={automatic}, vm={steps}"
    );
    assert_eq!(
        db.query_row(
            "SELECT total_tokens FROM pending_dashboard_5m WHERE bucket_start=300",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        20
    );
    assert_eq!(
        db.query_row(
            "SELECT SUM(total_tokens) FROM dashboard_source_5m",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        10240
    );
    assert_eq!(
        db.query_row(
            "SELECT value FROM metadata WHERE key='published_generation'",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "5"
    );
    assert!(db
        .prepare("PRAGMA foreign_key_check")
        .unwrap()
        .query([])
        .unwrap()
        .next()
        .unwrap()
        .is_none());
}

#[test]
fn dashboard_range_preserves_pending_visibility_and_replacement_rules() {
    let mut db = database();
    for id in 1..=6 {
        source(&db, id, 300, id * 100);
    }
    pending(&db, 1, "full", Some(50));
    pending(&db, 2, "delta", Some(25));
    pending(&db, 3, "tombstone", None);
    pending(&db, 5, "full", None);
    pending(&db, 6, "full", Some(60));
    db.execute(
        "UPDATE pending_sources SET target_generation=9 WHERE source_id=6",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO pending_dashboard_source_5m VALUES(2,600,'',NULL,15,1,12,2,3)",
        [],
    )
    .unwrap();
    let expected = rows(&db, REFERENCE, 7, 300, 600).unwrap();
    assert_eq!(expected[0][4], Value::Integer(1275)); // 50 + (200+25) + 400 + 600
    assert_eq!(expected[1][4], Value::Integer(15));
    for generation in [4, 5, 7, 9] {
        assert_eq!(
            rows(&db, candidate_select(), generation, 300, 600).unwrap(),
            rows(&db, REFERENCE, generation, 300, 600).unwrap()
        );
    }
    db.execute_batch("INSERT INTO dashboard_5m_current VALUES(300,'m','m',2100,6,2100,0,0)")
        .unwrap();
    {
        let tx = db.transaction().unwrap();
        refresh_range(&tx, 7, 300, 600).unwrap();
        assert_eq!(rows(&tx,"SELECT ?1,bucket_start,model_key,model,total_tokens,calls,input_tokens,cached_input_tokens,output_tokens FROM pending_dashboard_5m WHERE target_generation=?1 AND bucket_start BETWEEN ?2 AND ?3 ORDER BY bucket_start,model_key",7,300,600).unwrap(),expected);
        assert_eq!(
            tx.query_row("SELECT total_tokens FROM dashboard_5m_current", [], |r| r
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            2100
        );
        tx.rollback().unwrap();
    }
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM pending_dashboard_5m", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    // Deletion and future-source selection must remain identical to the old view.
    db.execute_batch(
        "UPDATE sources SET deleted=1 WHERE source_id=4;
        UPDATE sources SET last_seen_generation=10 WHERE source_id=6;
        UPDATE pending_sources SET deleted=1 WHERE source_id=2;",
    )
    .unwrap();
    assert_eq!(
        rows(&db, candidate_select(), 7, 300, 600).unwrap(),
        rows(&db, REFERENCE, 7, 300, 600).unwrap()
    );
    db.execute(
        "UPDATE metadata SET value='5' WHERE key='building_generation'",
        [],
    )
    .unwrap();
    assert_eq!(
        rows(&db, candidate_select(), 5, 300, 600).unwrap(),
        rows(&db, REFERENCE, 5, 300, 600).unwrap()
    );
}

#[test]
fn dashboard_range_keeps_overflow_as_an_error_and_rolls_back() {
    let mut db = database();
    source(&db, 1, 300, i64::MAX);
    pending(&db, 1, "delta", Some(1));
    db.execute_batch(
        "INSERT INTO dashboard_5m_current VALUES(300,'m','m',17,1,17,0,0);
        INSERT INTO pending_dashboard_5m VALUES(7,300,'m','m',19,1,19,0,0);",
    )
    .unwrap();
    assert!(rows(&db, REFERENCE, 7, 300, 300)
        .unwrap_err()
        .to_string()
        .contains("overflow"));
    {
        let tx = db.transaction().unwrap();
        assert!(refresh_range(&tx, 7, 300, 300)
            .unwrap_err()
            .contains("overflow"));
    }
    assert_eq!(
        db.query_row("SELECT total_tokens FROM pending_dashboard_5m", [], |r| r
            .get::<_, i64>(
            0
        ))
        .unwrap(),
        19
    );
    assert_eq!(
        db.query_row("SELECT total_tokens FROM dashboard_5m_current", [], |r| r
            .get::<_, i64>(
            0
        ))
        .unwrap(),
        17
    );
}

#[test]
fn dashboard_range_executes_through_the_bound_store_namespace() {
    use crate::core::business_store_connection::StoreConnection;
    use crate::core::business_store_sql::StoreSqlBinding;
    let schema = database();
    let ddl: Vec<String> = schema
        .prepare(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL
         ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 WHEN 'view' THEN 2 ELSE 3 END",
        )
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let raw = Connection::open_in_memory().unwrap();
    raw.execute_batch("CREATE TABLE tb_stores(store_id TEXT PRIMARY KEY,user_version INTEGER);
        CREATE TABLE tb_store_objects(store_id TEXT,name TEXT,type TEXT,original_sql TEXT);
        INSERT INTO tb_stores VALUES('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0);").unwrap();
    let bound = StoreConnection::bound(
        raw,
        StoreSqlBinding::new(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_",
            Vec::<String>::new(),
        )
        .unwrap(),
    )
    .unwrap();
    for sql in ddl {
        bound.execute_batch(&sql).unwrap();
    }
    bound.execute_batch("INSERT INTO metadata VALUES('published_generation','5'),('building_generation','7');
        INSERT INTO sources(source_id,path,session_id,last_seen_generation) VALUES(1,'/fixture/bound','bound',5);
        INSERT INTO pending_sources(source_id,target_generation,mode) VALUES(1,7,'delta');
        INSERT INTO dashboard_source_5m VALUES(1,300,'m','m',100,1,80,20,20);
        INSERT INTO pending_dashboard_source_5m VALUES(1,300,'m','m',25,1,20,5,5);").unwrap();
    bound.execute_batch(INSTALL_INDEX_SQL).unwrap();
    bound
        .execute(INSERT_RANGE_SQL, params![7, 300, 300])
        .unwrap();
    let actual: (i64, i64) = bound
        .query_row(
            "SELECT total_tokens,calls FROM pending_dashboard_5m WHERE target_generation=7",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(actual, (125, 2));
    assert_eq!(
        bound
            .query_row("SELECT total_tokens FROM dashboard_source_5m", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        100
    );
}

#[test]
fn current_index_reopen_adds_bucket_index_without_changing_published_events() {
    use super::super::{database_path, ExactUsageIndex};
    let _guard = crate::core::app_paths::app_path_test_env_guard(&[]);
    let root =
        std::env::temp_dir().join(format!("tokenbar-range-upgrade-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(root.join("sessions")).unwrap();
    std::fs::write(root.join("sessions/rollout-range-upgrade.jsonl"),
        "{\"timestamp\":\"2026-06-18T01:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":3,\"cached_input_tokens\":1,\"output_tokens\":2,\"total_tokens\":5}}}}\n").unwrap();
    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();
    drop(index);
    let db = Connection::open(database_path(&root).unwrap()).unwrap();
    db.execute_batch("DROP INDEX pending_dashboard_source_5m_time_idx")
        .unwrap();
    let snapshot = || {
        db.query_row(
            "SELECT (SELECT value FROM metadata WHERE key='schema_version'),
        (SELECT value FROM metadata WHERE key='published_generation'),
        (SELECT COUNT(*) FROM event_rows),(SELECT SUM(tokens) FROM event_rows)",
            [],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            },
        )
        .unwrap()
    };
    let before = snapshot();
    assert_eq!((before.2, before.3), (1, 5));
    for _ in 0..2 {
        drop(ExactUsageIndex::open(&root).unwrap());
        assert_eq!(snapshot(), before);
        assert_eq!(db.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='pending_dashboard_source_5m_time_idx'",[],|r|r.get::<_,i64>(0)).unwrap(),1);
    }
    drop(db);
    std::fs::remove_dir_all(root).unwrap();
}
