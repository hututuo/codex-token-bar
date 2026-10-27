use super::*;

fn sample(id: &str, start: f64, end: f64, rate: f64, covered: f64) -> ActivitySpeedSample {
    ActivitySpeedSample {
        id: id.into(),
        source_identity: LEGACY_SOURCE_IDENTITY.into(),
        display_mode: "tokens".into(),
        estimator_id: "agent-speed".into(),
        estimator_version: "1".into(),
        metric_kind: "output".into(),
        client: "codex".into(),
        model: "model-a".into(),
        started_at: start,
        ended_at: end,
        output_rate: rate,
        covered_seconds: covered,
    }
}

fn database() -> Connection {
    let connection = Connection::open_in_memory().unwrap();
    create_schema(&connection).unwrap();
    connection
}

#[test]
fn duplicate_replay_and_weighted_window_are_idempotent() {
    let connection = database();
    let a = sample("a", 1_500.0, 1_560.0, 10.0, 60.0);
    let b = sample("b", 1_620.0, 1_800.0, 20.0, 180.0);
    assert!(add_sample(&connection, &a, 1_800.0).unwrap());
    assert!(!add_sample(&connection, &a, 1_800.0).unwrap());
    assert!(add_sample(&connection, &b, 1_800.0).unwrap());
    let result = query(&connection, 1_800.0, &ActivitySpeedFilter::default(), 10).unwrap();
    let aggregate = result.series[0].rolling_5m.as_ref().unwrap();
    assert!((aggregate.weighted_output - 4_200.0).abs() < 0.0001);
    assert!((aggregate.covered_seconds - 240.0).abs() < 0.0001);
    assert!((aggregate.output_rate() - 17.5).abs() < 0.0001);
    let count: i64 = connection
        .query_row(
            "SELECT SUM(sample_count) FROM activity_speed_buckets_5m",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 2);
}

#[test]
fn trend_since_filters_rollup_scan_and_rejects_invalid_bounds() {
    let connection = database();
    let now = 100_000.0;
    let old = sample("old-trend", 96_990.0, 97_000.0, 2.0, 10.0);
    let recent = sample("recent-trend", 99_980.0, 99_990.0, 4.0, 10.0);
    add_sample(&connection, &old, now).unwrap();
    add_sample(&connection, &recent, now).unwrap();

    let all_history = query(&connection, now, &ActivitySpeedFilter::default(), 8).unwrap();
    assert_eq!(all_history.series[0].five_minute_trend.len(), 2);
    assert_eq!(all_history.series[0].thirty_minute_trend.len(), 2);

    let since = now - 1_800.0;
    let filter = ActivitySpeedFilter {
        trend_since: Some(since),
        ..Default::default()
    };
    let limited = query(&connection, now, &filter, 8).unwrap();
    let series = &limited.series[0];
    let earliest = bucket_start(since);
    assert_eq!(series.five_minute_trend.len(), 1);
    assert_eq!(series.thirty_minute_trend.len(), 1);
    assert!(series
        .five_minute_trend
        .iter()
        .all(|point| point.bucket_start >= earliest));
    assert!(series
        .thirty_minute_trend
        .iter()
        .all(|point| point.bucket_start >= earliest));

    for invalid_since in [-1.0, f64::NAN, now + 1.0] {
        let invalid = ActivitySpeedFilter {
            trend_since: Some(invalid_since),
            ..Default::default()
        };
        assert!(matches!(
            query(&connection, now, &invalid, 8),
            Err(ActivitySpeedStoreError::InvalidFilter)
        ));
    }
}

#[test]
fn batch_is_atomic_bounded_and_replay_safe() {
    let connection = database();
    let valid = sample("batch-valid", 1_700.0, 1_701.0, 4.0, 1.0);
    let mut invalid = sample("batch-invalid", 1_700.0, 1_701.0, 1.0, 1.0);
    invalid.output_rate = f64::NAN;
    assert!(matches!(
        add_samples(&connection, &[valid.clone(), invalid], 1_800.0),
        Err(ActivitySpeedStoreError::InvalidSample)
    ));

    let huge_rate = f64::MAX / 1.5;
    let overflow_a = sample("overflow-a", 1_700.0, 1_701.0, huge_rate, 1.0);
    let overflow_b = sample("overflow-b", 1_700.0, 1_701.0, huge_rate, 1.0);
    assert!(matches!(
        add_samples(&connection, &[overflow_a, overflow_b], 1_800.0),
        Err(ActivitySpeedStoreError::InvalidSample)
    ));
    let ids_after_rejections: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM activity_speed_sample_ids",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(ids_after_rejections, 0);

    assert_eq!(
        add_samples(&connection, &[valid.clone(), valid.clone()], 1_800.0).unwrap(),
        1
    );
    assert_eq!(
        add_samples(&connection, &[valid.clone()], 1_800.0).unwrap(),
        0
    );
    assert!(matches!(
        add_samples(&connection, &vec![valid; 4_097], 1_800.0),
        Err(ActivitySpeedStoreError::TooManySamples)
    ));
    let total: i64 = connection
        .query_row(
            "SELECT SUM(sample_count) FROM activity_speed_buckets_5m",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(total, 1);
}

#[test]
fn scope_filters_separate_client_model_and_estimator() {
    let connection = database();
    let mut a = sample("codex", 1_700.0, 1_710.0, 10.0, 10.0);
    let mut b = sample("claude", 1_700.0, 1_710.0, 20.0, 10.0);
    b.client = "claude".into();
    b.estimator_id = "statusline".into();
    add_sample(&connection, &a, 1_800.0).unwrap();
    add_sample(&connection, &b, 1_800.0).unwrap();
    let all = query(&connection, 1_800.0, &ActivitySpeedFilter::default(), 10).unwrap();
    assert_eq!(all.series.len(), 2);
    let filter = ActivitySpeedFilter {
        client: Some("claude".into()),
        estimator_id: Some("statusline".into()),
        ..Default::default()
    };
    let only_claude = query(&connection, 1_800.0, &filter, 10).unwrap();
    assert_eq!(only_claude.series.len(), 1);
    assert_eq!(
        only_claude.series[0]
            .rolling_5m
            .as_ref()
            .unwrap()
            .output_rate(),
        20.0
    );
    a.output_rate = f64::NAN;
    assert!(matches!(
        add_sample(&connection, &a, 1_800.0),
        Err(ActivitySpeedStoreError::InvalidSample)
    ));
}

#[test]
fn detail_and_rollup_retention_have_separate_horizons() {
    let connection = database();
    let now = 40.0 * 86_400.0;
    let old_detail = sample(
        "ten-days",
        now - 10.0 * 86_400.0 - 10.0,
        now - 10.0 * 86_400.0,
        5.0,
        10.0,
    );
    let old_rollup = sample(
        "twenty-nine-days",
        now - 29.0 * 86_400.0 - 10.0,
        now - 29.0 * 86_400.0,
        7.0,
        10.0,
    );
    add_sample(&connection, &old_detail, now).unwrap();
    add_sample(&connection, &old_rollup, now).unwrap();
    let raw: i64 = connection
        .query_row("SELECT COUNT(*) FROM activity_speed_samples", [], |r| {
            r.get(0)
        })
        .unwrap();
    let buckets: i64 = connection
        .query_row("SELECT COUNT(*) FROM activity_speed_buckets_5m", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(raw, 0);
    assert_eq!(buckets, 2);
    assert!(!add_sample(&connection, &old_detail, now).unwrap());
    query(
        &connection,
        now + 8.0 * 86_400.0,
        &ActivitySpeedFilter::default(),
        10,
    )
    .unwrap();
    let retained: i64 = connection
        .query_row("SELECT COUNT(*) FROM activity_speed_buckets_5m", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(retained, 1);
}

#[test]
fn input_span_and_query_series_are_bounded() {
    let connection = database();
    let overlong = sample("overlong", 100.0, 3_701.0, 1.0, 3_601.0);
    assert!(matches!(
        add_sample(&connection, &overlong, 4_000.0),
        Err(ActivitySpeedStoreError::InvalidSample)
    ));
    for index in 0..65 {
        let mut item = sample(&format!("bounded-{index}"), 1_700.0, 1_710.0, 1.0, 10.0);
        item.model = format!("model-{index}");
        add_sample(&connection, &item, 1_800.0).unwrap();
    }
    assert!(matches!(
        query(&connection, 1_800.0, &ActivitySpeedFilter::default(), 10),
        Err(ActivitySpeedStoreError::TooManySeries)
    ));
}

#[test]
fn schema_initialization_preserves_user_version_and_usage_ledger() {
    let connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "PRAGMA user_version=17;
             CREATE TABLE client_usage_events(event_id TEXT PRIMARY KEY);
             INSERT INTO client_usage_events(event_id) VALUES('kept');",
        )
        .unwrap();
    create_schema(&connection).unwrap();
    let user_version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap();
    let ledger_rows: i64 = connection
        .query_row("SELECT COUNT(*) FROM client_usage_events", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(user_version, 17);
    assert_eq!(ledger_rows, 1);
}

#[test]
fn v1_migration_preserves_legacy_rows_and_isolates_sources() {
    let connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "PRAGMA user_version=17;
             CREATE TABLE client_usage_events(event_id TEXT PRIMARY KEY);
             INSERT INTO client_usage_events(event_id) VALUES('kept');
             CREATE TABLE activity_speed_meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
             INSERT INTO activity_speed_meta(key,value) VALUES('schema_version','1');
             CREATE TABLE activity_speed_samples(
                 id TEXT PRIMARY KEY NOT NULL, display_mode TEXT NOT NULL, estimator_id TEXT NOT NULL,
                 estimator_version TEXT NOT NULL, metric_kind TEXT NOT NULL, client TEXT NOT NULL,
                 model TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL NOT NULL,
                 output_rate REAL NOT NULL CHECK(output_rate>=0), covered_seconds REAL NOT NULL CHECK(covered_seconds>0),
                 weighted_output REAL NOT NULL CHECK(weighted_output>=0), CHECK(ended_at>started_at)
             ) WITHOUT ROWID;
             CREATE INDEX activity_speed_samples_time ON activity_speed_samples(ended_at,started_at);
             CREATE INDEX activity_speed_samples_scope_time ON activity_speed_samples(display_mode,estimator_id,estimator_version,metric_kind,client,model,ended_at);
             INSERT INTO activity_speed_samples VALUES('shared-id','tokens','agent-speed','1','output','codex','model-a',1700,1710,10,10,100);
             CREATE TABLE activity_speed_sample_ids(id TEXT PRIMARY KEY NOT NULL, ended_at REAL NOT NULL) WITHOUT ROWID;
             CREATE INDEX activity_speed_sample_ids_time ON activity_speed_sample_ids(ended_at);
             INSERT INTO activity_speed_sample_ids VALUES('shared-id',1710);
             CREATE TABLE activity_speed_buckets_5m(
                 display_mode TEXT NOT NULL, estimator_id TEXT NOT NULL, estimator_version TEXT NOT NULL,
                 metric_kind TEXT NOT NULL, client TEXT NOT NULL, model TEXT NOT NULL, bucket_start INTEGER NOT NULL,
                 weighted_output REAL NOT NULL CHECK(weighted_output>=0), covered_seconds REAL NOT NULL CHECK(covered_seconds>0),
                 sample_count INTEGER NOT NULL CHECK(sample_count>0),
                 PRIMARY KEY(display_mode,estimator_id,estimator_version,metric_kind,client,model,bucket_start)
             ) WITHOUT ROWID;
             CREATE INDEX activity_speed_buckets_time ON activity_speed_buckets_5m(bucket_start);
             INSERT INTO activity_speed_buckets_5m VALUES('tokens','agent-speed','1','output','codex','model-a',1500,100,10,1);",
        )
        .unwrap();

    create_schema(&connection).unwrap();
    let version: String = connection
        .query_row(
            "SELECT value FROM activity_speed_meta WHERE key='schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let retained_legacy: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM activity_speed_samples_v1_legacy",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let retained_ids: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM activity_speed_sample_ids_v1_legacy",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let retained_buckets: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM activity_speed_buckets_5m_v1_legacy",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let copied_identity: String = connection
        .query_row(
            "SELECT source_identity FROM activity_speed_samples",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let user_version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap();
    let ledger_rows: i64 = connection
        .query_row("SELECT COUNT(*) FROM client_usage_events", [], |row| {
            row.get(0)
        })
        .unwrap();
    let sample_plan: String = connection
        .query_row(
            "EXPLAIN QUERY PLAN SELECT * FROM activity_speed_samples WHERE ended_at>?1 AND started_at<?2",
            (1_600.0, 1_800.0),
            |row| row.get(3),
        )
        .unwrap();
    let bucket_plan: String = connection
        .query_row(
            "EXPLAIN QUERY PLAN SELECT * FROM activity_speed_buckets_5m WHERE bucket_start>=?1 AND bucket_start<=?2",
            (1_200, 1_800),
            |row| row.get(3),
        )
        .unwrap();
    assert_eq!(version, "2");
    assert_eq!(retained_legacy, 1);
    assert_eq!(retained_ids, 1);
    assert_eq!(retained_buckets, 1);
    assert_eq!(copied_identity, LEGACY_SOURCE_IDENTITY);
    assert_eq!(user_version, 17);
    assert_eq!(ledger_rows, 1);
    assert!(
        sample_plan.contains("activity_speed_samples_v2_time"),
        "{sample_plan}"
    );
    assert!(
        bucket_plan.contains("activity_speed_buckets_v2_time"),
        "{bucket_plan}"
    );

    let legacy_result = query(&connection, 1_800.0, &ActivitySpeedFilter::default(), 8).unwrap();
    assert_eq!(legacy_result.series.len(), 1);
    assert_eq!(
        legacy_result.series[0].dimensions.source_identity,
        LEGACY_SOURCE_IDENTITY
    );
    assert_eq!(legacy_result.series[0].five_minute_trend.len(), 1);
    assert!(!add_sample(
        &connection,
        &sample("shared-id", 1_700.0, 1_710.0, 10.0, 10.0),
        1_800.0
    )
    .unwrap());
    let mut same_id = sample("shared-id", 1_700.0, 1_710.0, 20.0, 10.0);
    same_id.source_identity = "sha256-root-b".into();
    assert!(add_sample(&connection, &same_id, 1_800.0).unwrap());

    let separated = query(&connection, 1_800.0, &ActivitySpeedFilter::default(), 8).unwrap();
    assert_eq!(separated.series.len(), 2);
    let only_new_source = query(
        &connection,
        1_800.0,
        &ActivitySpeedFilter {
            source_identity: Some("sha256-root-b".into()),
            ..Default::default()
        },
        8,
    )
    .unwrap();
    assert_eq!(only_new_source.series.len(), 1);
    assert_eq!(
        only_new_source.series[0]
            .rolling_5m
            .as_ref()
            .unwrap()
            .output_rate(),
        20.0
    );
}
