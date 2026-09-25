use super::*;
use crate::core::app_paths;

struct Fixture { root: PathBuf }
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("exact-empty-batch-{}", Uuid::new_v4()));
        fs::create_dir_all(root.join("sessions")).unwrap();
        fs::create_dir_all(root.join("archived_sessions")).unwrap();
        Self { root }
    }
    fn file(&self, name: &str) -> PathBuf { self.root.join("sessions").join(name) }
    fn sync(&self) -> u64 {
        let mut index = ExactUsageIndex::open(&self.root).unwrap();
        index.sync(&self.root, &mut Vec::new()).unwrap();
        index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC).unwrap().total_tokens
    }
    fn scalar(&self, sql: &str) -> i64 {
        let db = Connection::open(database_path(&self.root).unwrap()).unwrap();
        db.query_row(sql, [], |row| row.get(0)).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) { fs::remove_dir_all(&self.root).unwrap(); }
}
fn token(amount: u64) -> String {
    serde_json::json!({"timestamp":"2026-07-20T01:00:00Z", "type":"event_msg",
        "payload":{"type":"token_count","info":{"last_token_usage":{
            "input_tokens":amount,"cached_input_tokens":0,"output_tokens":0,"total_tokens":amount
        }}}}).to_string() + "\n"
}

#[test]
fn new_empty_sources_publish_checkpoints_without_staging_and_append_after_reopen() {
    let _guard = app_paths::app_path_test_env_guard(&[]);
    let fixture = Fixture::new();
    let file = fixture.file("rollout-first-empty.jsonl");
    fs::write(&file, "").unwrap();
    reset_test_counters();
    assert_eq!(fixture.sync(), 0);
    assert_eq!(test_counters(), (0, 1, 1));
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM sources WHERE deleted=0 AND append_ready=1 AND resume_offset=0 AND length(prefix_sha256)=32 AND accounting_state IS NOT NULL"), 1);
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing=0"), 1);
    reset_test_counters();
    ExactUsageIndex::reset_scan_bytes_for_testing();
    assert_eq!(fixture.sync(), 0);
    assert_eq!(test_counters(), (0, 0, 0));
    assert_eq!(ExactUsageIndex::scan_bytes_for_testing(), (0, 0));
    assert_eq!(ExactUsageIndex::metadata_validation_bytes_for_testing(), 0);
    fs::write(&file, token(17)).unwrap();
    assert_eq!(fixture.sync(), 17);
    assert_eq!(test_counters().0, 0, "append from an empty checkpoint must remain incremental");
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM event_rows"), 1);
}

#[test]
fn append_after_empty_batch_commit_is_observed_on_the_next_scan() {
    let _guard = app_paths::app_path_test_env_guard(&[]);
    let fixture = Fixture::new();
    let file = fixture.file("rollout-append-after-commit.jsonl");
    fs::write(&file, "").unwrap();
    ExactUsageIndex::set_after_file_commit_hook_for_testing(|path| {
        fs::write(path, token(29)).map_err(|error| error.to_string())
    });
    // The fixed observation boundary was empty, even though the writer has
    // appended by the time this generation finishes publication.
    assert_eq!(fixture.sync(), 0);
    reset_test_counters();
    ExactUsageIndex::reset_scan_bytes_for_testing();
    assert_eq!(fixture.sync(), 29);
    assert_eq!(test_counters(), (0, 0, 0));
    assert_eq!(ExactUsageIndex::scan_bytes_for_testing().0, 0);
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM event_rows"), 1);
    fs::remove_file(file).unwrap();
    assert_eq!(fixture.sync(), 29, "deleting the source must retain its published usage");
}

#[test]
fn queued_empty_deleted_before_import_does_not_reserve_a_phantom_source() {
    let _guard = app_paths::app_path_test_env_guard(&[]);
    let fixture = Fixture::new();
    let file = fixture.file("rollout-disappearing-empty.jsonl");
    fs::write(&file, "").unwrap();
    let file = fs::canonicalize(file).unwrap();
    let mut index = ExactUsageIndex::open(&fixture.root).unwrap();
    let generation = begin_or_resume_generation(&mut index.connection, ExactSyncMode::Full).unwrap();
    let mut jobs = Vec::new();
    assert!(queue_if_new(&index.connection, &file, &file.to_string_lossy(),
        file_signature(&file).unwrap(), &mut jobs).unwrap());
    fs::remove_file(&file).unwrap();
    let mut full = Vec::new();
    import_new_sources(&mut index.connection, generation, &jobs, &mut full,
        &mut Vec::new(), &mut ExactScanCompleteness::default(),
        &mut ExactScanDiagnostics::default()).unwrap();
    assert!(full.is_empty());
    for table in ["sources", "pending_sources", "source_observations"] {
        assert_eq!(index.connection.query_row(&format!("SELECT COUNT(*) FROM {table}"),
            [], |row| row.get::<_, i64>(0)).unwrap(), 0);
    }
    drop(index);
    fs::write(file, token(31)).unwrap();
    assert_eq!(fixture.sync(), 31);
}

#[test]
fn empty_truncation_and_archived_identity_keep_existing_ledger_reconciliation() {
    let _guard = app_paths::app_path_test_env_guard(&[]);
    let fixture = Fixture::new();
    let file = fixture.file("rollout-owned-history.jsonl");
    fs::write(&file, token(120)).unwrap();
    assert_eq!(fixture.sync(), 120);
    reset_test_counters();
    fs::write(&file, "").unwrap();
    assert_eq!(fixture.sync(), 120, "truncation cannot erase old usage");
    assert_eq!(test_counters(), (1, 0, 0));
    let moved = fixture.root.join("archived_sessions/rollout-owned-history.jsonl");
    fs::rename(&file, &moved).unwrap();
    reset_test_counters();
    assert_eq!(fixture.sync(), 120);
    assert_eq!(test_counters().2, 0, "a new path is not necessarily a new ledger identity");
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM sources"), 1);
}

#[test]
fn interrupted_empty_batch_does_not_publish_partial_generation_and_resumes() {
    let _guard = app_paths::app_path_test_env_guard(&[]);
    let fixture = Fixture::new();
    fs::write(fixture.file("rollout-history.jsonl"), token(120)).unwrap();
    assert_eq!(fixture.sync(), 120);
    let published = fixture.scalar("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='published_generation'");
    for number in 0..BATCH_SIZE + 1 {
        fs::write(fixture.file(&format!("empty-{number:05}.jsonl")), "").unwrap();
    }
    ExactUsageIndex::set_after_file_commit_hook_for_testing(|_| Err("stop after empty batch".into()));
    {
        let mut index = ExactUsageIndex::open(&fixture.root).unwrap();
        let error = index.sync(&fixture.root, &mut Vec::new()).unwrap_err();
        assert!(error.contains("stop after empty batch"), "{error}");
    }
    assert_eq!(fixture.scalar("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='published_generation'"), published);
    assert_eq!(fixture.scalar("SELECT SUM(tokens) FROM event_rows"), 120);
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM pending_sources"), BATCH_SIZE as i64);
    reset_test_counters();
    assert_eq!(fixture.sync(), 120);
    assert_eq!(test_counters(), (0, 1, 1), "resume must reuse the committed pending checkpoints");
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM published_files"), (BATCH_SIZE + 2) as i64);
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM pending_sources"), 0);
}

#[test]
fn queued_empty_that_grows_is_deferred_to_normal_parser_before_publication() {
    let _guard = app_paths::app_path_test_env_guard(&[]);
    let fixture = Fixture::new();
    let file = fixture.file("rollout-growing.jsonl");
    fs::write(&file, "").unwrap();
    let file = fs::canonicalize(file).unwrap();
    let path = file.to_string_lossy().into_owned();
    let mut index = ExactUsageIndex::open(&fixture.root).unwrap();
    let generation = begin_or_resume_generation(&mut index.connection, ExactSyncMode::Full).unwrap();
    let mut jobs = Vec::new();
    assert!(queue_if_new(&index.connection, &file, &path, file_signature(&file).unwrap(), &mut jobs).unwrap());
    fs::write(&file, token(23)).unwrap();
    let mut full = Vec::new();
    let mut completeness = ExactScanCompleteness::default();
    let mut diagnostics = ExactScanDiagnostics::default();
    reset_test_counters();
    import_new_sources(&mut index.connection, generation, &jobs, &mut full,
        &mut Vec::new(), &mut completeness, &mut diagnostics).unwrap();
    assert_eq!(full.len(), 1);
    assert_eq!(full[0].signature.size, fs::metadata(&file).unwrap().len());
    assert_eq!(test_counters().2, 0);
    assert!(diagnostics.source_drift);
    assert_eq!(index.connection.query_row("SELECT COUNT(*) FROM pending_sources", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
    drop(index);
    assert_eq!(fixture.sync(), 23);
}

#[test]
fn failed_empty_batch_rolls_back_sources_and_pending_rows_together() {
    let _guard = app_paths::app_path_test_env_guard(&[]);
    let fixture = Fixture::new();
    let mut index = ExactUsageIndex::open(&fixture.root).unwrap();
    let generation = begin_or_resume_generation(&mut index.connection, ExactSyncMode::Full).unwrap();
    let mut jobs = Vec::new();
    for name in ["empty-a.jsonl", "empty-b.jsonl"] {
        let file = fixture.file(name);
        fs::write(&file, "").unwrap();
        let file = fs::canonicalize(file).unwrap();
        assert!(queue_if_new(&index.connection, &file, &file.to_string_lossy(), file_signature(&file).unwrap(), &mut jobs).unwrap());
    }
    index.connection.execute_batch("CREATE TRIGGER test_reject_empty BEFORE INSERT ON pending_sources
        WHEN (SELECT path FROM sources WHERE source_id=NEW.source_id) LIKE '%empty-b.jsonl'
        BEGIN SELECT RAISE(ABORT, 'empty batch write failure'); END;").unwrap();
    let error = import_new_sources(&mut index.connection, generation, &jobs, &mut Vec::new(),
        &mut Vec::new(), &mut ExactScanCompleteness::default(), &mut ExactScanDiagnostics::default()).unwrap_err();
    assert!(error.contains("empty batch write failure"), "{error}");
    for table in ["sources", "pending_sources", "source_observations"] {
        assert_eq!(index.connection.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get::<_, i64>(0)).unwrap(), 0);
    }
    index.connection.execute_batch("DROP TRIGGER test_reject_empty").unwrap();
    drop(index);
    assert_eq!(fixture.sync(), 0);
    assert_eq!(fixture.scalar("SELECT COUNT(*) FROM published_files"), 2);
}
