use super::*;

#[test]
fn missing_and_known_empty_legacy_candidates_use_the_held_pool_without_becoming_facts() {
    let (root,pool,_)=fixture();
    let path=root.path().join("index.sqlite3.staging").join(format!("{}.candidate-v2-{}.sqlite3","a".repeat(64),"b".repeat(64)));
    assert_eq!(pool.legacy_presence(&path).unwrap(),Some(false));
    let spec=crate::core::business_store_route::exact_store_spec(&path).unwrap();
    let container=Container::open_existing(&pool.path).unwrap();
    container.register(&spec).unwrap();
    let writer=container.into_store_connection(&spec).unwrap();
    writer.execute_batch(&super::super::staging_schema_sql(false)).unwrap();
    assert_eq!(pool.legacy_presence(&path).unwrap(),Some(false));
    assert!(!path.exists());
    let work=seed_fixture_stage("/fixture.jsonl").unwrap();
    let count=TABLES[0].1;
    let values=work.query_row("SELECT * FROM manifest",[],|row| {
        (0..count).map(|i|row.get::<_,rusqlite::types::Value>(i)).collect::<rusqlite::Result<Vec<_>>>()
    }).unwrap();
    writer.execute(&format!("INSERT INTO manifest VALUES({})",vec!["?";count].join(",")),params_from_iter(values)).unwrap();
    assert_eq!(pool.legacy_presence(&path).unwrap(),Some(true));
}

#[test]
fn an_unknown_empty_legacy_layout_is_preserved_and_refused() {
    let (root,pool,_)=fixture();
    let path=root.path().join("index.sqlite3.staging").join(format!("{}.candidate-v2-{}.sqlite3","a".repeat(64),"c".repeat(64)));
    let spec=crate::core::business_store_route::exact_store_spec(&path).unwrap();
    let container=Container::open_existing(&pool.path).unwrap();
    container.register(&spec).unwrap();
    let writer=container.into_store_connection(&spec).unwrap();
    writer.execute_batch(&super::super::staging_schema_sql(false)).unwrap();
    writer.execute_batch("CREATE TABLE unknown_future(value TEXT)").unwrap();
    assert!(pool.legacy_presence(&path).is_err());
    assert_eq!(writer.query_row("SELECT COUNT(*) FROM manifest",[],|r|r.get::<_,i64>(0)).unwrap(),0);
    assert_eq!(pool.legacy_presence(&root.path().join("ordinary-index.sqlite3")).unwrap(),None);
}

#[test]
fn offline_maintenance_cannot_close_a_pool_while_an_owner_is_using_it() {
    let (_root, pool, _) = fixture();
    let path = pool.path.clone();
    let owner = Arc::new(pool);
    let mut pools = HashMap::new();
    pools.insert(path, owner.clone());
    assert!(release_idle(&mut pools).is_err());
    assert_eq!(pools.len(), 1);
    drop(owner);
    release_idle(&mut pools).unwrap();
    assert!(pools.is_empty());
}

fn fixture() -> (tempfile::TempDir, Pool, StoreSpec) {
    let root = tempfile::tempdir().unwrap();
    let a = root.path().join("codex-ledger.sqlite");
    let c = Container::open(&a).unwrap();
    let target = StoreSpec::new("exact", "fixture", "exact/index/fixture").unwrap();
    c.register(&target).unwrap();
    c.into_store_connection(&target).unwrap().execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);INSERT INTO metadata VALUES('published_generation','1'),('fixture_tokens','123')").unwrap();
    let pool = Pool::open(&a).unwrap();
    (root, pool, target)
}

#[test]
fn sealed_jobs_reopen_without_per_job_catalog_growth_or_lossy_values() {
    let (_root, pool, target) = fixture();
    let raw = Connection::open(&pool.path).unwrap();
    let count = || {
        (
            raw.query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
            raw.query_row("SELECT COUNT(*) FROM tb_stores", [], |r| r.get::<_, i64>(0))
                .unwrap(),
        )
    };
    let before = count();
    let mut paths = Vec::new();
    for i in 0..13 {
        let source = format!("/fixture/{i}.jsonl");
        let job = pool.job(&target, &source, source.as_bytes()).unwrap();
        let work = seed_fixture_stage(&source).unwrap();
        work.execute(
            "UPDATE events SET tokens=9007199254740993,model=CAST(x'ff0061' AS TEXT)",
            [],
        )
        .unwrap();
        work.execute(
            "UPDATE manifest SET actual_bytes=?1",
            [Pool::footprint(&work).unwrap() as i64],
        )
        .unwrap();
        pool.persist(&job, &work).unwrap();
        assert_eq!(pool.seal(&job).unwrap().unwrap().rows, 4);
        let restored = pool.restore(&job).unwrap();
        assert_eq!(
            restored
                .query_row("SELECT tokens FROM events", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            9007199254740993
        );
        assert_eq!(
            restored
                .query_row("SELECT hex(model) FROM events", [], |r| r
                    .get::<_, String>(0))
                .unwrap(),
            "FF0061"
        );
        assert!(restored.execute("DELETE FROM events", []).is_err());
        assert!(raw
            .execute(
                &format!("DELETE FROM {} WHERE job_id=?1", pool.table("event_rows")),
                [&job.id]
            )
            .is_err());
        assert!(pool.persist(&job, &work).is_err());
        pool.reclaim(&job).unwrap(); // no publication receipt: retains payload
        assert!(pool.restore(&job).is_ok());
        paths.push(job.path);
        assert_eq!(count(), before);
    }
    let reopened = Pool::open(&pool.path).unwrap();
    for path in paths {
        let job = reopened.lookup(&path).unwrap().unwrap();
        assert!(reopened.restore(&job).is_ok());
    }
    assert_eq!(count(), before);
}

#[test]
fn mismatched_manifest_cannot_be_sealed_or_replace_a_published_fact() {
    let (_root, pool, target) = fixture();
    let job = pool.job(&target, "/source.jsonl", b"request").unwrap();
    let work = seed_fixture_stage("/source.jsonl").unwrap();
    work.execute("UPDATE manifest SET event_count=99", [])
        .unwrap();
    assert!(pool.persist(&job, &work).is_err());
    assert!(pool.seal(&job).unwrap().is_none());
    let raw = Connection::open(&pool.path).unwrap();
    assert_eq!(
        raw.query_row(
            &format!(
                "SELECT value FROM {}metadata WHERE key='fixture_tokens'",
                target.prefix
            ),
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "123"
    );
}

#[test]
fn future_pool_and_foreign_path_are_rejected_without_mutating_jobs_or_facts() {
    let (root, pool, target) = fixture();
    let job = pool.job(&target, "/source.jsonl", b"request").unwrap();
    pool.persist(&job, &seed_fixture_stage("/source.jsonl").unwrap())
        .unwrap();
    assert!(pool
        .lookup(
            &root
                .path()
                .join("other/.exact-stage-pool-rust-v1")
                .join(&target.id)
                .join(format!("{}.stage", job.id))
        )
        .is_err());
    let raw = Connection::open(&pool.path).unwrap();
    raw.execute(
        "UPDATE tb_stores SET user_version=2 WHERE store_id=?1",
        [&pool.store.id],
    )
    .unwrap();
    assert!(pool.restore(&job).is_err());
    assert!(Pool::open(&pool.path).is_err());
    assert_eq!(
        raw.query_row(
            &format!("SELECT COUNT(*) FROM {}", pool.table("event_rows")),
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
}
