use super::*;

fn owner_lookup_fixture() -> (tempfile::TempDir, Pool, PathBuf, StoreSpec) {
    let root = tempfile::tempdir().unwrap();
    let a = root.path().join("codex-ledger.sqlite");
    let index = root.path().join("missing/cache/index.sqlite3");
    let target = crate::core::business_store_route::exact_store_spec(&index).unwrap();
    let container = Container::open(&a).unwrap();
    container.register(&target).unwrap();
    container.into_store_connection(&target).unwrap().execute_batch(
        "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);INSERT INTO metadata VALUES('published_generation','1'),('fixture_tokens','123')"
    ).unwrap();
    std::fs::write(format!("{}.initialized", a.display()), b"tokenbar-codex-ledger-v1\n").unwrap();
    let pool = Pool::open(&a).unwrap();
    (root, pool, index, target)
}

#[test]
fn held_owner_lookup_rechecks_identity_and_root_versions_without_writing() {
    let (_root, pool, index, target) = owner_lookup_fixture();
    let writer = Connection::open(&pool.path).unwrap();
    let before = pool.with(|c| Ok(c.connection().total_changes())).unwrap();
    assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    for (column, original) in [
        ("module", &target.module), ("source_identity", &target.source_identity),
        ("logical_path", &target.logical_path), ("namespace_prefix", &target.prefix),
    ] {
        writer.execute(&format!("UPDATE tb_stores SET {column}='invalid-owner' WHERE store_id=?1"), [&target.id]).unwrap();
        assert!(pool.existing_exact_store_spec(&index).is_err(), "{column}");
        assert!(pool.with(|c| Ok(c.connection().is_autocommit())).unwrap());
        writer.execute(&format!("UPDATE tb_stores SET {column}=?1 WHERE store_id=?2"), params![original, target.id]).unwrap();
        assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    }
    for (invalidate, restore) in [
        ("PRAGMA user_version=9", "PRAGMA user_version=1"),
        ("UPDATE tb_container_meta SET value='9' WHERE key='schema_version'", "UPDATE tb_container_meta SET value='1' WHERE key='schema_version'"),
        ("DELETE FROM tb_container_meta WHERE key='schema_version'", "INSERT INTO tb_container_meta VALUES('schema_version','1')"),
    ] {
        writer.execute_batch(invalidate).unwrap();
        assert!(pool.existing_exact_store_spec(&index).is_err());
        assert!(pool.with(|c| Ok(c.connection().is_autocommit())).unwrap());
        writer.execute_batch(restore).unwrap();
        assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    }
    // A single owner is a lookup result, even when it is not writable. The
    // original resolver never promoted this lookup to target write admission.
    for state in ["ready", "sealed", "staging"] {
        writer.execute("UPDATE tb_stores SET state=?1 WHERE store_id=?2", params![state, target.id]).unwrap();
        assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    }
    writer.execute("DELETE FROM tb_stores WHERE store_id=?1", [&target.id]).unwrap();
    let absent = pool.existing_exact_store_spec(&index).unwrap();
    assert_eq!(absent, target, "missing owners retain the original preferred-spec fallback");
    assert!(pool.candidates(&absent, "/fixture.jsonl").is_err(), "a missing owner cannot use cached write admission");
    assert_eq!(pool.with(|c| Ok(c.connection().total_changes())).unwrap(), before);
    assert_eq!(writer.query_row(&format!("SELECT value FROM {} WHERE key='fixture_tokens'", quote(&format!("{}metadata", target.prefix))), [], |r| r.get::<_, String>(0)).unwrap(), "123");
}

#[test]
fn held_owner_lookup_preserves_marker_pool_and_file_fences() {
    let (_root, pool, index, target) = owner_lookup_fixture();
    let writer = Connection::open(&pool.path).unwrap();
    assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    let marker = format!("{}.initialized", pool.path.display());
    for contents in [None, Some(b"broken marker".as_slice())] {
        match contents {
            Some(bytes) => std::fs::write(&marker, bytes).unwrap(),
            None => std::fs::remove_file(&marker).unwrap(),
        }
        assert!(pool.existing_exact_store_spec(&index).is_err());
        std::fs::write(&marker, b"tokenbar-codex-ledger-v1\n").unwrap();
        assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    }
    writer.execute("INSERT INTO tb_container_meta VALUES('activation_state','recovering')", []).unwrap();
    assert!(pool.existing_exact_store_spec(&index).is_err());
    writer.execute("DELETE FROM tb_container_meta WHERE key='activation_state'", []).unwrap();
    for (column, bad, good) in [("user_version", "9", "1"), ("state", "staging", "ready")] {
        writer.execute(&format!("UPDATE tb_stores SET {column}=?1 WHERE store_id=?2"), params![bad, pool.store.id]).unwrap();
        assert!(pool.existing_exact_store_spec(&index).is_err());
        writer.execute(&format!("UPDATE tb_stores SET {column}=?1 WHERE store_id=?2"), params![good, pool.store.id]).unwrap();
        assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    }
    #[cfg(unix)] {
        let parked = pool.path.with_extension("retained.sqlite");
        std::fs::rename(&pool.path, &parked).unwrap();
        std::os::unix::fs::symlink(&parked, &pool.path).unwrap();
        assert!(pool.existing_exact_store_spec(&index).is_err());
        std::fs::remove_file(&pool.path).unwrap();
        std::fs::write(&pool.path, b"unrelated replacement").unwrap();
        assert!(pool.existing_exact_store_spec(&index).is_err());
        std::fs::remove_file(&pool.path).unwrap();
        std::fs::rename(&parked, &pool.path).unwrap();
        assert_eq!(pool.existing_exact_store_spec(&index).unwrap(), target);
    }
    let pool = Arc::new(pool);
    let workers = (0..4).map(|_| {
        let pool = pool.clone();
        let index = index.clone();
        let target = target.clone();
        std::thread::spawn(move || {
            for _ in 0..32 {
                let owner = pool.existing_exact_store_spec(&index).unwrap();
                assert_eq!(owner, target);
                assert!(pool.candidates(&owner, "/missing.jsonl").unwrap().is_empty());
            }
        })
    }).collect::<Vec<_>>();
    for worker in workers { worker.join().unwrap(); }
}

#[test]
fn pool_writer_locks_before_state_read_instead_of_upgrading_a_stale_snapshot() {
    let (_root, pool, target) = fixture();
    let source = "/writer-admission.jsonl";
    let job = pool.job(&target, source, source.as_bytes()).unwrap();
    pool.persist(&job, &seed_fixture_stage(source).unwrap()).unwrap();
    let before = pool.seal(&job).unwrap().unwrap().digest;
    let external = Connection::open(&pool.path).unwrap();
    external.busy_timeout(std::time::Duration::ZERO).unwrap();
    let update = format!("INSERT OR REPLACE INTO {} VALUES('writer-admission-control','1')",
        quote(&format!("{}metadata", target.prefix)));
    pool.with(|container| {
        let tx = container.connection().unchecked_transaction().map_err(|e|e.to_string())?;
        let _: String = tx.query_row(&format!("SELECT state FROM {} WHERE job_id=?1",pool.table("jobs")),[&job.id],|r|r.get(0)).map_err(|e|e.to_string())?;
        external.execute(&update,[]).map_err(|e|e.to_string())?;
        let error = tx.execute(&format!("UPDATE {} SET state=state WHERE job_id=?1",pool.table("jobs")),[&job.id]).unwrap_err();
        assert!(matches!(error,rusqlite::Error::SqliteFailure(code,_) if code.extended_code==rusqlite::ffi::SQLITE_BUSY_SNAPSHOT));
        tx.rollback().map_err(|e|e.to_string())
    }).unwrap();
    pool.with(|container| {
        let tx = begin_pool_write(container.connection()).map_err(|e|e.to_string())?;
        let _: String = tx.query_row(&format!("SELECT state FROM {} WHERE job_id=?1",pool.table("jobs")),[&job.id],|r|r.get(0)).map_err(|e|e.to_string())?;
        let error = external.execute(&update,[]).unwrap_err();
        assert!(matches!(error,rusqlite::Error::SqliteFailure(code,_) if code.code==rusqlite::ErrorCode::DatabaseBusy));
        tx.execute(&format!("UPDATE {} SET state=state WHERE job_id=?1",pool.table("jobs")),[&job.id]).map_err(|e|e.to_string())?;
        tx.commit().map_err(|e|e.to_string())
    }).unwrap();
    external.execute(&update,[]).unwrap();
    assert_eq!(pool.seal(&job).unwrap().unwrap().digest,before);
    assert_eq!(pool.restore(&job).unwrap().query_row("SELECT tokens FROM events",[],|r|r.get::<_,i64>(0)).unwrap(),11);
}

#[test]
fn known_empty_partial_stage_stays_occupied_for_the_existing_restart_validator() {
    let (root,pool,_)=fixture();
    let path=root.path().join("index.sqlite3.staging").join(format!("{}.sqlite3","d".repeat(64)));
    let spec=crate::core::business_store_route::exact_store_spec(&path).unwrap();
    let container=Container::open_existing(&pool.path).unwrap();
    container.register(&spec).unwrap();
    let writer=container.into_store_connection(&spec).unwrap();
    writer.execute_batch("CREATE TABLE manifest(manifest_schema_version INTEGER NOT NULL,parser_revision TEXT NOT NULL,complete INTEGER NOT NULL,staging_mode TEXT NOT NULL,accounting_state TEXT);CREATE TABLE events(ordinal INTEGER PRIMARY KEY);CREATE TABLE fingerprints(fingerprint BLOB PRIMARY KEY);CREATE TABLE chunks(chunk_index INTEGER PRIMARY KEY);").unwrap();
    assert_eq!(pool.legacy_presence(&path).unwrap(),Some(true));
    assert!(!path.exists());
    writer.execute("INSERT INTO events VALUES(17)",[]).unwrap();
    assert!(pool.legacy_presence(&path).is_err(),"A partial artifact with facts is never an empty producer");
    assert_eq!(writer.query_row("SELECT ordinal FROM events",[],|r|r.get::<_,i64>(0)).unwrap(),17);
}

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
    assert_eq!(pool.legacy_presence(&path).unwrap(),Some(false),"Warm the held name catalog before external DDL");
    writer.execute_batch("CREATE TABLE unknown_future(value TEXT)").unwrap();
    assert!(pool.legacy_presence(&path).is_err());
    assert_eq!(writer.query_row("SELECT COUNT(*) FROM manifest",[],|r|r.get::<_,i64>(0)).unwrap(),0);
    assert_eq!(pool.legacy_presence(&root.path().join("ordinary-index.sqlite3")).unwrap(),None);
}

#[test]
fn legacy_empty_manifest_never_hides_payload_rows_after_a_warm_catalog() {
    for table in ["events", "fingerprints", "chunks"] {
        let (root, pool, _) = fixture();
        let path = root.path().join("index.sqlite3.staging").join(format!("{}.sqlite3", "e".repeat(64)));
        let spec = crate::core::business_store_route::exact_store_spec(&path).unwrap();
        let container = Container::open_existing(&pool.path).unwrap();
        container.register(&spec).unwrap();
        let writer = container.into_store_connection(&spec).unwrap();
        writer.execute_batch(&super::super::staging_schema_sql(false)).unwrap();
        assert_eq!(pool.legacy_presence(&path).unwrap(), Some(false));
        let seed = seed_fixture_stage("/fixture.jsonl").unwrap();
        let values = seed.query_row(&format!("SELECT * FROM {table}"), [], |row| {
            (0..row.as_ref().column_count()).map(|i| row.get::<_, rusqlite::types::Value>(i))
                .collect::<rusqlite::Result<Vec<_>>>()
        }).unwrap();
        writer.execute(&format!("INSERT INTO {table} VALUES({})", vec!["?"; values.len()].join(",")),
            params_from_iter(values.clone())).unwrap();
        assert!(pool.legacy_presence(&path).is_err(), "manifest=0 with {table} facts must stop recovery");
        let retained = writer.query_row(&format!("SELECT * FROM {table}"), [], |row| {
            (0..row.as_ref().column_count()).map(|i| row.get::<_, rusqlite::types::Value>(i))
                .collect::<rusqlite::Result<Vec<_>>>()
        }).unwrap();
        assert_eq!(retained, values);
        assert_eq!(writer.query_row("SELECT COUNT(*) FROM manifest", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
        writer.execute(&format!("DELETE FROM {table}"), []).unwrap();
        assert_eq!(pool.legacy_presence(&path).unwrap(), Some(false));
        let outside = Connection::open(&pool.path).unwrap();
        let physical = quote(&format!("{}{table}", spec.prefix));
        outside.execute(&format!("INSERT INTO {physical} VALUES({})", vec!["?"; values.len()].join(",")),
            params_from_iter(values)).unwrap();
        assert!(pool.legacy_presence(&path).is_err(), "External DML must invalidate empty presence without a schema change");
        assert_eq!(outside.query_row(&format!("SELECT COUNT(*) FROM {physical}"), [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        outside.execute(&format!("DELETE FROM {physical}"), []).unwrap();
        assert_eq!(pool.legacy_presence(&path).unwrap(), Some(false));
        assert!(!path.exists());
    }
}

#[test]
fn legacy_empty_manifest_requires_the_complete_known_table_contract() {
    let full = super::super::staging_schema_sql(false);
    let cases = [
        ("generated column", format!("{full} ALTER TABLE events ADD COLUMN future_value INTEGER GENERATED ALWAYS AS (tokens+1) VIRTUAL;")),
        ("column affinity", full.replace("sha256 BLOB NOT NULL", "sha256 TEXT NOT NULL")),
        ("nullability", full.replace("sha256 BLOB NOT NULL", "sha256 BLOB")),
        ("default", full.replace("DEFAULT 0", "DEFAULT 7")),
        ("check", full.replace("CHECK(complete IN (0, 1))", "CHECK(complete IN (0, 1, 2))")),
        ("rowid", full.replace("WITHOUT ROWID", "")),
        ("strict", full.replace("WITHOUT ROWID", "WITHOUT ROWID, STRICT")),
        ("automatic unique index", full.replace("tokens INTEGER NOT NULL,", "tokens INTEGER NOT NULL UNIQUE,")),
        ("payload check", full.replace("fingerprint BLOB PRIMARY KEY", "fingerprint BLOB PRIMARY KEY CHECK(length(fingerprint)=32)")),
    ];
    let mut accepted = Vec::new();
    for (label, schema) in cases {
        let (root, pool, _) = fixture();
        let path = root.path().join("index.sqlite3.staging").join(format!("{}.sqlite3", "f".repeat(64)));
        let spec = crate::core::business_store_route::exact_store_spec(&path).unwrap();
        let container = Container::open_existing(&pool.path).unwrap();
        container.register(&spec).unwrap();
        let writer = container.into_store_connection(&spec).unwrap();
        writer.execute_batch(&schema).unwrap();
        if pool.legacy_presence(&path).is_ok() { accepted.push(label); }
        assert_eq!(writer.query_row("SELECT COUNT(*) FROM manifest", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
        assert!(!path.exists());
    }
    assert!(accepted.is_empty(), "Unknown empty layouts were accepted: {accepted:?}");
}

#[test]
fn legacy_catalog_rejects_foreign_named_objects_depending_on_stage_tables() {
    for kind in ["INDEX", "TRIGGER"] {
      for name in ["foreign_named_object", "sqliteXforeign"] {
        let (root, pool, _) = fixture();
        let path = root.path().join("index.sqlite3.staging").join(format!("{}.sqlite3", "b".repeat(64)));
        let spec = crate::core::business_store_route::exact_store_spec(&path).unwrap();
        let container = Container::open_existing(&pool.path).unwrap();
        container.register(&spec).unwrap();
        let writer = container.into_store_connection(&spec).unwrap();
        writer.execute_batch(&super::super::staging_schema_sql(false)).unwrap();
        assert_eq!(pool.legacy_presence(&path).unwrap(), Some(false));
        let outside = Connection::open(&pool.path).unwrap();
        let table = quote(&format!("{}events", spec.prefix));
        let sql = match kind {
            "INDEX" => format!("CREATE INDEX {name} ON {table}(tokens)"),
            _ => format!("CREATE TRIGGER {name} AFTER INSERT ON {table} BEGIN SELECT 1; END"),
        };
        outside.execute_batch(&sql).unwrap();
        assert!(pool.legacy_presence(&path).is_err(), "A foreign named {kind} is still a dependency of the stage");
        assert_eq!(outside.query_row("SELECT COUNT(*) FROM sqlite_master WHERE name=?1", [name], |r| r.get::<_, i64>(0)).unwrap(), 1);
        outside.execute_batch(&format!("DROP {kind} {name}")).unwrap();
        assert_eq!(pool.legacy_presence(&path).unwrap(), Some(false));
      }
    }
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
