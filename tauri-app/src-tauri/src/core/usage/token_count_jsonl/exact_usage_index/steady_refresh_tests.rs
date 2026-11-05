use super::*;

#[test]
fn prepared_aggregate_waiting_for_display_does_not_count_or_take_a_write_lock() {
    let _guard = crate::core::app_paths::app_path_test_env_guard(&[]);
    let root = tempfile::tempdir().unwrap();
    fs::create_dir_all(root.path().join("sessions")).unwrap();
    fs::write(root.path().join("sessions/rollout-aggregate-ready.jsonl"),
        "{\"timestamp\":\"2026-06-18T01:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":3,\"cached_input_tokens\":1,\"output_tokens\":2,\"total_tokens\":5}}}}\n").unwrap();
    let mut index = ExactUsageIndex::open(root.path()).unwrap();
    index.sync(root.path(), &mut Vec::new()).unwrap();
    let path = database_path(root.path()).unwrap();
    let writer = Connection::open(path).unwrap();
    writer.execute_batch("DELETE FROM metadata WHERE key IN
        ('dashboard_aggregate_published_generation','dashboard_aggregate_settled_through');").unwrap();
    let generation = index.published_generation().unwrap();
    let before_changes = index.connection.total_changes();
    let before_version: i64 = writer.query_row("PRAGMA data_version",[],|r|r.get(0)).unwrap();
    index.connection.busy_timeout(StdDuration::from_millis(20)).unwrap();
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    let before_counts = PUBLISHED_EVENT_COUNT_CALLS.with(Cell::get);
    // Read-only signature verification works with an unrelated writer. The
    // old path instead counts events and attempts BEGIN IMMEDIATE here.
    index.ensure_dashboard_aggregates(root.path()).unwrap();
    assert_eq!(PUBLISHED_EVENT_COUNT_CALLS.with(Cell::get), before_counts);
    writer.execute_batch("ROLLBACK").unwrap();
    assert_eq!(index.connection.total_changes(), before_changes);
    assert_eq!(writer.query_row("PRAGMA data_version",[],|r|r.get::<_,i64>(0)).unwrap(),before_version);
    assert_eq!(metadata_i64(&index.connection,DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY).unwrap(),None);
    assert_eq!(metadata_i64(&index.connection,DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY).unwrap(),None);
    assert_eq!(index.published_generation().unwrap(),generation);
    assert!(index.dashboard_5m_projection_is_complete().unwrap());

    // Display publication remains the only owner of these two markers.
    index.mark_dashboard_aggregate_published(generation, 1_750_204_800).unwrap();
    assert_eq!(metadata_i64(&index.connection,DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY).unwrap(),Some(generation as i64));
    assert_eq!(metadata_i64(&index.connection,DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY).unwrap(),Some(1_750_204_800));
    writer.execute_batch("DELETE FROM dashboard_5m_current").unwrap();
    assert!(!index.dashboard_5m_projection_is_complete().unwrap());
    index.ensure_dashboard_aggregates(root.path()).unwrap();
    assert!(PUBLISHED_EVENT_COUNT_CALLS.with(Cell::get) > before_counts,
        "the damaged-projection control must actually execute the count path");
    assert!(index.dashboard_5m_projection_is_complete().unwrap());
    assert_eq!(index.summary(OffsetDateTime::now_utc(),UtcOffset::UTC).unwrap().total_tokens,5);
}
