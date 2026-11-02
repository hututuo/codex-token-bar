//! Shared probes run with both raw test SQLite and real production routing.
use super::*;

pub(super) fn verify_live_state(home: &Path) -> Result<serde_json::Value, String> {
    macro_rules! check { ($value:expr) => { $value.map_err(|error| error.to_string())? }; }
    macro_rules! require { ($value:expr, $message:literal) => {
        if !$value { return Err($message.into()); }
    }; }
    check!(fs::create_dir_all(home.join("live")));
    let home = check!(fs::canonicalize(home));
    let database = home.join("state_5.sqlite");
    require!(!database.exists(), "refusing an existing external state fixture");
    let writer = check!(rusqlite::Connection::open(&database));
    check!(writer.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, updated_at INTEGER,
            rollout_path TEXT, archived INTEGER DEFAULT 0);
        INSERT INTO threads VALUES('one','before',1781715600,'live/one.jsonl',0);
        PRAGMA wal_checkpoint(TRUNCATE);"));
    check!(fs::write(home.join("live/one.jsonl"), b"{}\n"));
    check!(fs::write(home.join("live/two.jsonl"), b"{}\n"));
    let database_bytes = check!(fs::read(&database));
    let read = open_external_state_database(&database, StdDuration::from_secs(1))?;
    require!(read.execute("DELETE FROM threads", []).is_err(), "external state handle was writable");
    drop(read);
    let mut warnings = Vec::new();
    let ThreadMetadataStage::Updated(first) = stage_thread_metadata(&home, (None,None), &mut warnings)? else {
        return Err("initial old-column state schema was not read".into());
    };
    require!(first.rows.len()==1 && first.rows[0].1=="before", "initial state metadata mismatch");
    check!(writer.execute_batch("UPDATE threads SET title='after',updated_at=1781715700 WHERE id='one';
        INSERT INTO threads VALUES('two','second',1781715800,'live/two.jsonl',0);"));
    require!(check!(fs::read(&database)) == database_bytes, "fixture write escaped WAL into the main DB");
    let ThreadMetadataStage::Updated(second) = stage_thread_metadata(&home, first.signature.unzip(), &mut warnings)? else {
        return Err("WAL-only update was hidden by an immutable import or stale signature".into());
    };
    require!(second.rows.len()==2 && second.rows.iter().any(|r|r.0=="one" && r.1=="after"),
        "dynamic external metadata was not refreshed");
    let mut candidates=HashMap::new(); let mut directories=HashMap::new();
    let mut boundary_warnings=Vec::new(); let mut unresolved=false;
    estimate_active_rollouts(&home, &home, &(Instant::now()+StdDuration::from_secs(10)),
        &mut candidates, &mut directories, &mut boundary_warnings, &mut unresolved, &HashMap::new())?;
    require!(candidates.len()==2 && !unresolved && boundary_warnings.is_empty(), "active-rollout estimate used stale external state");
    let mut index = check!(Connection::open_in_memory());
    let mut visited=Vec::new(); let mut completeness=ExactScanCompleteness::default();
    visit_active_rollouts(&mut index, &home, &home, &mut warnings, &mut completeness,
        |_, path, _, _| {visited.push(path.to_path_buf()); Ok(())})?;
    require!(visited.len()==2 && warnings.is_empty(), "active-rollout visit lost dynamic state rows");
    #[cfg(not(test))]
    require!(!crate::core::business_store_route::exact_store_exists(&database)?,
        "external database was imported as an immutable Token Bar ledger");
    // A malformed replacement must keep last-good metadata, not publish an
    // empty successful scan simply because optional-column fallbacks exist.
    check!(writer.execute_batch("DROP TABLE threads; CREATE TABLE threads(id TEXT PRIMARY KEY);"));
    require!(matches!(stage_thread_metadata(&home, second.signature.unzip(), &mut warnings)?,
        ThreadMetadataStage::Failed), "malformed external schema was treated as empty metadata");
    drop(writer);
    Ok(serde_json::json!({"name":"live-external-state-readers","status":"PASS",
        "walOnlyMutationObserved":true,"readOnly":true,"activeRollouts":visited.len(),
        "oldColumnsRead":true,"malformedReplacementPreserved":true}))
}

#[test]
fn external_state_readers_observe_live_wal_and_do_not_assume_new_optional_columns() {
    let root=std::env::temp_dir().join(format!("tokenbar-state-readers-{}", Uuid::new_v4()));
    let result=verify_live_state(&root);
    let _=fs::remove_dir_all(&root);
    result.unwrap();
}
