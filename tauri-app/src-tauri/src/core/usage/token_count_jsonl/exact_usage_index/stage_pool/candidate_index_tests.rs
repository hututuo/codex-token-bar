use super::*;
use rusqlite::StatementStatus;

fn v1_fixture() -> (tempfile::TempDir, Pool, StoreSpec) {
    let (root, pool, target) = super::tests::fixture();
    let raw = Connection::open(&pool.path).unwrap();
    raw.execute_batch(&format!(
        "DROP INDEX {}",
        pool.table(schema::CANDIDATE_INDEX)
    ))
    .unwrap();
    raw.execute(
        "DELETE FROM tb_store_objects WHERE store_id=?1 AND name=?2",
        params![pool.store.id, schema::CANDIDATE_INDEX],
    )
    .unwrap();
    raw.execute(
        "UPDATE tb_stores SET user_version=1,revision=0 WHERE store_id=?1",
        [&pool.store.id],
    )
    .unwrap();
    pool.validate_schema(&raw, &pool.schema_v1()).unwrap();
    (root, pool, target)
}

fn snapshot(pool: &Pool) -> (Vec<(String, String)>, String, i64, i64, Vec<Vec<u8>>) {
    let c = Container::open_existing(&pool.path).unwrap();
    let logical: String = c
        .connection()
        .query_row(
            "SELECT logical_path FROM tb_stores WHERE store_id=?1",
            [&pool.store.id],
            |r| r.get(0),
        )
        .unwrap();
    let observed =
        StoreSpec::new(&pool.store.module, &pool.store.source_identity, logical).unwrap();
    let proof = c.proof(&observed).unwrap();
    let mut s = c
        .connection()
        .prepare("SELECT type,coalesce(sql,'') FROM sqlite_master ORDER BY name")
        .unwrap();
    let objects = s
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    let revision = c
        .connection()
        .query_row(
            "SELECT revision FROM tb_stores WHERE store_id=?1",
            [&pool.store.id],
            |r| r.get(0),
        )
        .unwrap();
    let mut registration = Vec::new();
    for table in ["tb_stores", "tb_store_objects"] {
        let mut s = c
            .connection()
            .prepare(&format!(
                "SELECT * FROM {table} WHERE store_id=?1 ORDER BY 1,2"
            ))
            .unwrap();
        let mut rows = s.query([&pool.store.id]).unwrap();
        while let Some(row) = rows.next().unwrap() {
            registration.push(encode_row(row).unwrap());
        }
    }
    (
        objects,
        proof.rows_digest,
        proof.module_user_version,
        revision,
        registration,
    )
}

fn insert_header(
    raw: &Connection,
    pool: &Pool,
    id: &str,
    owner: &str,
    source: &str,
    base: &str,
    state: &str,
    sealed: f64,
    codec: i64,
) {
    raw.execute(&format!("INSERT INTO {}(job_id,owner,source_path,base_proof,contract_digest,logical_path,operation_id,codec,state,manifest,digest,byte_count,row_count,sealed_at) VALUES(?1,?2,?3,?4,'contract',?5,'operation',?6,?7,x'0001ff','digest',3,1,?8)",pool.table("jobs")),
        params![id,owner,source,base,format!("/candidate/{id}.stage"),codec,state,sealed]).unwrap();
}

#[test]
fn candidate_index_upgrades_v1_once_without_changing_retained_rows() {
    let (_root, pool, target) = v1_fixture();
    let raw = Connection::open(&pool.path).unwrap();
    for state in ["building", "sealed", "consumed", "reclaimed"] {
        insert_header(
            &raw, &pool, state, &target.id, "/source", "base", state, 1.0, 1,
        );
    }
    raw.execute(
        &format!(
            "INSERT INTO {} VALUES(?1,'consumed','digest',7)",
            pool.table("publication_receipts")
        ),
        [&target.id],
    )
    .unwrap();
    raw.execute(
        &format!(
            "INSERT INTO {} VALUES('building',0,x'ff0001')",
            pool.table("event_rows")
        ),
        [],
    )
    .unwrap();
    let before = snapshot(&pool);
    let upgraded = Pool::open(&pool.path).unwrap();
    let after = snapshot(&upgraded);
    assert_eq!(after.0.len(), before.0.len() + 1);
    assert_eq!(
        after.1, before.1,
        "all typed job, payload and receipt values survive"
    );
    assert_eq!((after.2, after.3), (2, 1));
    assert_eq!(upgraded.store, pool.store);
    let (kind,sql): (String,String) = raw.query_row("SELECT type,original_sql FROM tb_store_objects WHERE store_id=?1 AND name='jobs_sealed_candidates'",[&pool.store.id],|r|Ok((r.get(0)?,r.get(1)?))).unwrap();
    assert_eq!(kind, "index");
    assert!(!sql.contains(&pool.store.prefix));
    assert!(sql.contains("WHERE state='sealed'"));
    Container::open_existing(&pool.path)
        .unwrap()
        .validate_catalog()
        .unwrap();
    let again = Pool::open(&pool.path).unwrap();
    assert_eq!(snapshot(&again), after);
    assert_eq!(
        again.with(|c| Ok(c.connection().total_changes())).unwrap(),
        0
    );
    // The former binary accepts only version 1 before any pool operation.
    assert!(!raw
        .query_row(
            "SELECT user_version=1 FROM tb_stores WHERE store_id=?1",
            [&pool.store.id],
            |r| r.get::<_, bool>(0)
        )
        .unwrap());
}

#[test]
fn candidate_index_migration_rolls_back_ddl_catalog_and_version_on_failure() {
    for (timing, table, condition) in [
        (
            "BEFORE INSERT",
            "tb_store_objects",
            "NEW.name='jobs_sealed_candidates'",
        ),
        (
            "BEFORE UPDATE OF user_version",
            "tb_stores",
            "NEW.user_version=2",
        ),
        (
            "AFTER UPDATE OF user_version",
            "tb_stores",
            "NEW.user_version=2",
        ),
    ] {
        let (_root, pool, _) = v1_fixture();
        let raw = Connection::open(&pool.path).unwrap();
        raw.execute_batch(&format!("CREATE TRIGGER fixture_fail_pool_upgrade {timing} ON {table} WHEN NEW.store_id='{}' AND {condition} BEGIN SELECT RAISE(ABORT,'fixture migration failure'); END",pool.store.id)).unwrap();
        let before = snapshot(&pool);
        assert!(Pool::open(&pool.path)
            .err()
            .unwrap()
            .contains("fixture migration failure"));
        assert_eq!(snapshot(&pool), before);
        pool.validate_schema(&raw, &pool.schema_v1()).unwrap();
        raw.execute_batch("DROP TRIGGER fixture_fail_pool_upgrade")
            .unwrap();
        assert!(Pool::open(&pool.path).is_ok());
    }
}

#[test]
fn candidate_index_concurrent_openers_admit_one_committed_upgrade() {
    let (_root, pool, _) = v1_fixture();
    let path = pool.path.clone();
    let raw = Connection::open(&path).unwrap();
    raw.execute_batch("PRAGMA journal_mode=WAL; BEGIN IMMEDIATE")
        .unwrap();
    let pool = Arc::new(pool);
    let waiter = pool.clone();
    let (signal, waiting) = std::sync::mpsc::channel();
    thread_local! {
        static BUSY_SIGNAL: std::cell::RefCell<Option<std::sync::mpsc::Sender<()>>> = const { std::cell::RefCell::new(None) };
    }
    let worker = std::thread::spawn(move || {
        let c = Container::open_existing(&waiter.path).unwrap();
        BUSY_SIGNAL.with(|value| *value.borrow_mut() = Some(signal));
        c.connection()
            .busy_handler(Some(|attempt| {
                BUSY_SIGNAL.with(|value| {
                    if let Some(signal) = value.borrow_mut().take() {
                        signal.send(()).unwrap();
                    }
                });
                std::thread::sleep(std::time::Duration::from_millis(1));
                attempt < 5000
            }))
            .unwrap();
        waiter.prepare_schema(&c).unwrap();
    });
    // The actual opener has read v1 and is now blocked taking the writer lease.
    waiting
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    let (name, sql) = pool.candidate_index();
    let ns = SQLiteStoreNamespace::new(
        pool.store.prefix.clone(),
        pool.schema().iter().map(|(n, _)| n.clone()),
    );
    raw.execute_batch(&sql).unwrap();
    raw.execute(
        "INSERT INTO tb_store_objects VALUES(?1,?2,'index',?3)",
        params![pool.store.id, name, ns.unbind(&sql).unwrap()],
    )
    .unwrap();
    raw.execute(
        "UPDATE tb_stores SET user_version=2,revision=revision+1 WHERE store_id=?1",
        [&pool.store.id],
    )
    .unwrap();
    raw.execute_batch("COMMIT").unwrap();
    worker.join().unwrap();
    let after = snapshot(&pool);
    assert_eq!((after.2, after.3), (2, 1));
    pool.validate_schema(&raw, &pool.schema()).unwrap();
}

#[test]
fn candidate_index_versions_preserve_real_pending_publication_bridge() {
    use crate::core::{app_paths, business_store_route as route};
    for version in [1, 2] {
        let (root, pool, target) = v1_fixture();
        let _guard = app_paths::app_path_test_env_guard(&[(
            "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
            root.path().to_owned(),
        )]);
        assert_eq!(route::container_path().unwrap(), pool.path);
        let pool = Pool::open(&pool.path).unwrap();
        let job = pool.job(&target, "/bridge.jsonl", b"bridge").unwrap();
        pool.persist(&job, &seed_fixture_stage("/bridge.jsonl").unwrap())
            .unwrap();
        let seal = pool.seal(&job).unwrap().unwrap();
        let raw = Connection::open(&pool.path).unwrap();
        if version == 1 {
            raw.execute_batch(&format!(
                "DROP INDEX {}",
                pool.table(schema::CANDIDATE_INDEX)
            ))
            .unwrap();
            raw.execute(
                "DELETE FROM tb_store_objects WHERE store_id=?1 AND name=?2",
                params![pool.store.id, schema::CANDIDATE_INDEX],
            )
            .unwrap();
            raw.execute(
                "UPDATE tb_stores SET user_version=1 WHERE store_id=?1",
                [&pool.store.id],
            )
            .unwrap();
        }
        let mut writer = Container::open_existing(&pool.path)
            .unwrap()
            .into_store_connection(&target)
            .unwrap();
        writer
            .mount_exact_stage_rows(
                &target.id,
                "exact_stage_import",
                &seed_fixture_stage("/bridge.jsonl").unwrap(),
            )
            .unwrap();
        writer
            .unmount_exact_stage_rows("exact_stage_import")
            .unwrap();
        for commit in [false, true] {
            let tx = writer.transaction().unwrap();
            tx.mark_exact_stage_pending(&target.id, &job.id, &seal.digest, 2)
                .unwrap();
            tx.execute(
                "UPDATE metadata SET value='2' WHERE key='published_generation'",
                [],
            )
            .unwrap();
            tx.consume_exact_stage_generation(2).unwrap();
            if commit {
                tx.commit().unwrap();
            } else {
                tx.rollback().unwrap();
            }
            let count: i64 = raw
                .query_row(
                    &format!(
                        "SELECT COUNT(*) FROM {}",
                        pool.table("publication_receipts")
                    ),
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(count, i64::from(commit));
        }
        // Future versions fail before pending/publication can write.
        raw.execute(
            "UPDATE tb_stores SET user_version=3 WHERE store_id=?1",
            [&pool.store.id],
        )
        .unwrap();
        let tx = writer.transaction().unwrap();
        assert!(tx.consume_exact_stage_generation(2).is_err());
        tx.rollback().unwrap();
    }
}

#[test]
fn candidate_index_rejects_unknown_or_partial_contracts_without_repairing_them() {
    for mutation in [
        "extra",
        "wrong-trigger",
        "catalog-type",
        "catalog-sql",
        "index-before-version",
        "missing-v2-index",
        "wrong-v2-index",
        "future",
        "identity",
    ] {
        let (_root, pool, _) = v1_fixture();
        let raw = Connection::open(&pool.path).unwrap();
        match mutation {
            "extra" => raw
                .execute_batch(&format!("CREATE TABLE {}(value)", pool.table("unexpected")))
                .unwrap(),
            "wrong-trigger" => raw
                .execute_batch(&format!(
                    "DROP TRIGGER {}; CREATE TRIGGER {} BEFORE DELETE ON {} BEGIN SELECT 1; END",
                    pool.table("guard_job_delete"),
                    pool.table("guard_job_delete"),
                    pool.table("jobs")
                ))
                .unwrap(),
            "catalog-type" => {
                raw.execute("UPDATE tb_store_objects SET type='table' WHERE store_id=?1 AND name='guard_job_delete'",[&pool.store.id]).unwrap();
            }
            "catalog-sql" => {
                raw.execute("UPDATE tb_store_objects SET original_sql='unexpected' WHERE store_id=?1 AND name='jobs'",[&pool.store.id]).unwrap();
            }
            "index-before-version" => raw.execute_batch(&pool.candidate_index().1).unwrap(),
            "missing-v2-index" | "wrong-v2-index" => {
                raw.execute(
                    "UPDATE tb_stores SET user_version=2 WHERE store_id=?1",
                    [&pool.store.id],
                )
                .unwrap();
                if mutation == "wrong-v2-index" {
                    let sql = format!(
                        "CREATE INDEX {} ON {}(owner)",
                        pool.table(schema::CANDIDATE_INDEX),
                        pool.table("jobs")
                    );
                    raw.execute_batch(&sql).unwrap();
                    let ns = SQLiteStoreNamespace::new(
                        pool.store.prefix.clone(),
                        pool.schema().iter().map(|(n, _)| n.clone()),
                    );
                    raw.execute(
                        "INSERT INTO tb_store_objects VALUES(?1,?2,'index',?3)",
                        params![
                            pool.store.id,
                            schema::CANDIDATE_INDEX,
                            ns.unbind(&sql).unwrap()
                        ],
                    )
                    .unwrap();
                }
            }
            "future" => {
                raw.execute(
                    "UPDATE tb_stores SET user_version=3 WHERE store_id=?1",
                    [&pool.store.id],
                )
                .unwrap();
            }
            "identity" => {
                raw.execute(
                    "UPDATE tb_stores SET logical_path='unrecognized/pool' WHERE store_id=?1",
                    [&pool.store.id],
                )
                .unwrap();
            }
            _ => unreachable!(),
        }
        let before = snapshot(&pool);
        assert!(Pool::open(&pool.path).is_err(), "{mutation}");
        assert_eq!(snapshot(&pool), before, "{mutation}");
    }
}

#[test]
fn candidate_index_preserves_order_isolation_late_seals_and_unknown_codec() {
    let (_root, pool, target) = super::tests::fixture();
    let raw = Connection::open(&pool.path).unwrap();
    raw.execute_batch("PRAGMA journal_mode=WAL").unwrap();
    let base = pool.base(&target, &raw).unwrap();
    for (id, owner, source, proof, state, time) in [
        (
            "b",
            target.id.as_str(),
            "/source",
            base.as_str(),
            "sealed",
            2.0,
        ),
        (
            "a",
            target.id.as_str(),
            "/source",
            base.as_str(),
            "sealed",
            2.0,
        ),
        (
            "old",
            target.id.as_str(),
            "/source",
            base.as_str(),
            "sealed",
            1.0,
        ),
        (
            "foreign",
            "other-owner",
            "/source",
            base.as_str(),
            "sealed",
            9.0,
        ),
        (
            "other",
            target.id.as_str(),
            "/other",
            base.as_str(),
            "sealed",
            9.0,
        ),
        (
            "stale",
            target.id.as_str(),
            "/source",
            "old-base",
            "sealed",
            9.0,
        ),
        (
            "used",
            target.id.as_str(),
            "/source",
            base.as_str(),
            "consumed",
            9.0,
        ),
        (
            "late",
            target.id.as_str(),
            "/source",
            base.as_str(),
            "building",
            3.0,
        ),
    ] {
        insert_header(&raw, &pool, id, owner, source, proof, state, time, 1);
    }
    let paths = |ids: &[&str]| {
        ids.iter()
            .map(|id| PathBuf::from(format!("/candidate/{id}.stage")))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        pool.candidates(&target, "/source").unwrap(),
        paths(&["a", "b", "old"])
    );
    raw.execute_batch("BEGIN IMMEDIATE").unwrap();
    raw.execute(
        &format!(
            "UPDATE {} SET state='sealed' WHERE job_id='late'",
            pool.table("jobs")
        ),
        [],
    )
    .unwrap();
    assert_eq!(
        pool.candidates(&target, "/source").unwrap(),
        paths(&["a", "b", "old"])
    );
    raw.execute_batch("ROLLBACK").unwrap();
    assert_eq!(
        pool.candidates(&target, "/source").unwrap(),
        paths(&["a", "b", "old"])
    );
    raw.execute(
        &format!(
            "UPDATE {} SET state='sealed' WHERE job_id='late'",
            pool.table("jobs")
        ),
        [],
    )
    .unwrap();
    assert_eq!(
        pool.candidates(&target, "/source").unwrap(),
        paths(&["late", "a", "b", "old"])
    );
    raw.execute(
        &format!(
            "INSERT INTO {} VALUES(?1,'late','digest',2)",
            pool.table("publication_receipts")
        ),
        [&target.id],
    )
    .unwrap();
    raw.execute(
        &format!(
            "UPDATE {} SET state='consumed' WHERE job_id='late'",
            pool.table("jobs")
        ),
        [],
    )
    .unwrap();
    assert_eq!(
        pool.candidates(&target, "/source").unwrap(),
        paths(&["a", "b", "old"])
    );
    assert!(pool.candidates(&target, "/absent").unwrap().is_empty());
    insert_header(
        &raw,
        &pool,
        "bad-codec",
        &target.id,
        "/source",
        &base,
        "sealed",
        0.0,
        99,
    );
    assert_eq!(
        pool.candidates(&target, "/source").unwrap_err(),
        "未知暂存codec"
    );
    raw.execute(
        &format!(
            "UPDATE {}metadata SET value='2' WHERE key='published_generation'",
            target.prefix
        ),
        [],
    )
    .unwrap();
    assert!(pool.candidates(&target, "/source").unwrap().is_empty());
}

#[test]
fn candidate_lookup_work_is_bounded_by_matches_not_retained_job_headers() {
    let (_root, pool, target) = super::tests::fixture();
    let raw = Connection::open(&pool.path).unwrap();
    let base = pool.base(&target, &raw).unwrap();
    raw.execute_batch("BEGIN").unwrap();
    for i in 0..8272 {
        insert_header(
            &raw,
            &pool,
            &format!("history-{i}"),
            &target.id,
            "/history",
            &base,
            "consumed",
            1.0,
            1,
        );
    }
    insert_header(
        &raw, &pool, "match", &target.id, "/source", &base, "sealed", 1.0, 1,
    );
    raw.execute_batch("COMMIT").unwrap();
    let query = pool.candidates_sql();
    let measure = |sql: &str, source: &str| {
        let mut s = raw.prepare(sql).unwrap();
        let rows = s
            .query_map(params![target.id, source, base], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        (
            rows,
            s.get_status(StatementStatus::FullscanStep),
            s.get_status(StatementStatus::Sort),
            s.get_status(StatementStatus::VmStep),
        )
    };
    for source in ["/source", "/absent"] {
        let indexed = measure(&query, source);
        assert_eq!((indexed.1, indexed.2), (0, 0));
        assert!(indexed.3 < 100, "indexed VM work: {}", indexed.3);
        // Remove exactly this index inside a rollback-only fixture transaction.
        // NOT INDEXED does not reliably disable WITHOUT ROWID access paths.
        raw.execute_batch(&format!(
            "BEGIN; DROP INDEX {}",
            pool.table(schema::CANDIDATE_INDEX)
        ))
        .unwrap();
        let scanned = measure(&query, source);
        raw.execute_batch("ROLLBACK").unwrap();
        assert_eq!(scanned.0, indexed.0);
        assert!(scanned.1 >= 8272);
        assert!(scanned.3 > 40000);
        eprintln!(
            "candidate index {source}: VM {} -> {}, fullscan {} -> {}, sort {} -> {}",
            scanned.3, indexed.3, scanned.1, indexed.1, scanned.2, indexed.2
        );
    }
}
