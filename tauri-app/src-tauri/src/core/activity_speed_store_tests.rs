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

fn half_minute_point(series: &ActivitySpeedSeries, bucket: i64) -> &ActivitySpeedTrendPoint {
    series
        .half_minute_trend
        .iter()
        .find(|item| item.bucket_start == bucket)
        .unwrap()
}

fn half_minute_bucket_start(timestamp: f64) -> i64 {
    (timestamp / HALF_MINUTE_SECONDS as f64).floor() as i64 * HALF_MINUTE_SECONDS
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
fn one_minute_trend_splits_cross_minute_samples_and_uses_weighted_mean() {
    let connection = database();
    let crossing = sample("crossing", 59.0, 61.0, 10.0, 2.0);
    let following = sample("following", 61.0, 63.0, 20.0, 2.0);
    add_sample(&connection, &crossing, 120.0).unwrap();
    add_sample(&connection, &following, 120.0).unwrap();

    let result = query(&connection, 120.0, &ActivitySpeedFilter::default(), 8).unwrap();
    let points = &result.series[0].one_minute_trend;
    assert_eq!(points.len(), 2);
    assert_eq!(points[0].bucket_start, 0);
    assert!((points[0].value.covered_seconds - 1.0).abs() < 0.0001);
    assert!((points[0].value.weighted_output - 10.0).abs() < 0.0001);
    assert!((points[0].value.output_rate() - 10.0).abs() < 0.0001);
    assert_eq!(points[1].bucket_start, 60);
    assert!((points[1].value.covered_seconds - 3.0).abs() < 0.0001);
    assert!((points[1].value.weighted_output - 50.0).abs() < 0.0001);
    assert!((points[1].value.output_rate() - (50.0 / 3.0)).abs() < 0.0001);
}

#[test]
fn one_minute_trend_keeps_source_mode_client_and_model_scopes_separate() {
    let connection = database();
    let mut source = sample("source-b", 110.0, 112.0, 20.0, 2.0);
    source.source_identity = "source-b".into();
    let mut mode = sample("mode-agent", 110.0, 112.0, 30.0, 2.0);
    mode.display_mode = "agentSpeed".into();
    let mut client = sample("client-claude", 110.0, 112.0, 40.0, 2.0);
    client.client = "claude".into();
    let mut model = sample("model-b", 110.0, 112.0, 50.0, 2.0);
    model.model = "model-b".into();
    let base = sample("base", 110.0, 112.0, 10.0, 2.0);
    for item in [&base, &source, &mode, &client, &model] {
        add_sample(&connection, item, 120.0).unwrap();
    }

    let all = query(&connection, 120.0, &ActivitySpeedFilter::default(), 8).unwrap();
    assert_eq!(all.series.len(), 5);
    for series in &all.series {
        assert_eq!(series.one_minute_trend.len(), 1);
        let rate = series.one_minute_trend[0].value.output_rate();
        match (
            series.dimensions.source_identity.as_str(),
            series.dimensions.display_mode.as_str(),
            series.dimensions.client.as_str(),
            series.dimensions.model.as_str(),
        ) {
            (LEGACY_SOURCE_IDENTITY, "tokens", "codex", "model-a") => {
                assert!((rate - 10.0).abs() < 0.0001)
            }
            ("source-b", "tokens", "codex", "model-a") => {
                assert!((rate - 20.0).abs() < 0.0001)
            }
            (LEGACY_SOURCE_IDENTITY, "agentSpeed", "codex", "model-a") => {
                assert!((rate - 30.0).abs() < 0.0001)
            }
            (LEGACY_SOURCE_IDENTITY, "tokens", "claude", "model-a") => {
                assert!((rate - 40.0).abs() < 0.0001)
            }
            (LEGACY_SOURCE_IDENTITY, "tokens", "codex", "model-b") => {
                assert!((rate - 50.0).abs() < 0.0001)
            }
            unexpected => panic!("unexpected activity speed dimensions: {unexpected:?}"),
        }
    }

    let filtered = query(
        &connection,
        120.0,
        &ActivitySpeedFilter {
            source_identity: Some(LEGACY_SOURCE_IDENTITY.into()),
            display_mode: Some("tokens".into()),
            client: Some("codex".into()),
            model: Some("model-a".into()),
            ..Default::default()
        },
        8,
    )
    .unwrap();
    assert_eq!(filtered.series.len(), 1);
    assert!((filtered.series[0].one_minute_trend[0].value.output_rate() - 10.0).abs() < 0.0001);
}

#[test]
fn one_minute_trend_clips_future_samples_at_now() {
    let connection = database();
    let future_ending = sample("future-end", 110.0, 130.0, 10.0, 20.0);
    connection
        .execute(
            "INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
            rusqlite::params![
                future_ending.source_identity,
                future_ending.id,
                future_ending.display_mode,
                future_ending.estimator_id,
                future_ending.estimator_version,
                future_ending.metric_kind,
                future_ending.client,
                future_ending.model,
                future_ending.started_at,
                future_ending.ended_at,
                future_ending.output_rate,
                future_ending.covered_seconds,
                future_ending.output_rate * future_ending.covered_seconds,
            ],
        )
        .unwrap();

    let result = query(&connection, 120.0, &ActivitySpeedFilter::default(), 8).unwrap();
    let points = &result.series[0].one_minute_trend;
    assert_eq!(points.len(), 1);
    assert_eq!(points[0].bucket_start, 60);
    assert!((points[0].value.covered_seconds - 10.0).abs() < 0.0001);
    assert!((points[0].value.weighted_output - 100.0).abs() < 0.0001);
    assert!((points[0].value.output_rate() - 10.0).abs() < 0.0001);
}

#[test]
fn one_minute_trend_keeps_gaps_and_only_reads_the_last_30_minutes() {
    let connection = database();
    let old_but_retained = sample("outside-window", 1_700.0, 1_710.0, 8.0, 10.0);
    let recent = sample("recent", 3_541.0, 3_542.0, 12.0, 1.0);
    add_sample(&connection, &old_but_retained, 3_600.0).unwrap();
    add_sample(&connection, &recent, 3_600.0).unwrap();

    let result = query(&connection, 3_600.0, &ActivitySpeedFilter::default(), 8).unwrap();
    let points = &result.series[0].one_minute_trend;
    assert_eq!(points.len(), 1);
    assert_eq!(points[0].bucket_start, 3_540);
    assert!((points[0].value.output_rate() - 12.0).abs() < 0.0001);
    let json = serde_json::to_value(&result).unwrap();
    assert!(json["series"][0]["oneMinuteTrend"].is_array());
}

#[test]
fn one_minute_trend_is_bounded_to_31_nonempty_buckets() {
    let connection = database();
    let now = 1_830.5;
    let from = now - DEFAULT_MINUTE_TREND_WINDOW_SECONDS as f64;
    let first_bucket = minute_bucket_start(from);
    for minute in 0..MAX_DEFAULT_MINUTE_TREND_POINTS {
        let bucket = first_bucket + minute as i64 * MINUTE_SECONDS;
        let offset = if minute == 0 {
            from - first_bucket as f64 + 0.1
        } else if minute + 1 == MAX_DEFAULT_MINUTE_TREND_POINTS {
            0.1
        } else {
            1.0
        };
        let start = bucket as f64 + offset;
        let item = sample(&format!("minute-{minute}"), start, start + 0.2, 6.0, 0.1);
        add_sample(&connection, &item, now).unwrap();
    }

    let result = query(&connection, now, &ActivitySpeedFilter::default(), 8).unwrap();
    assert_eq!(result.series[0].one_minute_trend.len(), MAX_DEFAULT_MINUTE_TREND_POINTS);
    assert!(result.series[0].one_minute_trend.len() <= MAX_DEFAULT_MINUTE_TREND_POINTS);
}

#[test]
fn activity_history_reads_day_samples_splits_weights_and_clips_both_bounds() {
    let connection = database();
    let now = 100_143.5;
    let from = now - 86_400.0;
    let samples = [
        // Crosses the day boundary and minute boundary; only 80s in the window count.
        sample("window-edge", from - 20.0, from + 80.0, 10.0, 100.0),
        sample("outside-day", from - 100.0, from - 90.0, 99.0, 10.0),
        sample("old-day-point", now - 5_000.0, now - 4_990.0, 6.0, 10.0),
        sample("slow-crossing", 100_010.0, 100_070.0, 10.0, 60.0),
        sample("fast-crossing", 100_030.0, 100_070.0, 20.0, 40.0),
        // The query clips this stored interval at now.
        sample("future-end", now - 20.0, now + 20.0, 4.0, 40.0),
    ];
    for item in &samples {
        add_sample(&connection, item, now + 20.0).unwrap();
    }

    let day = activity_history(&connection, now, &ActivitySpeedFilter::default(), 86_400).unwrap();
    assert_eq!(day.series.len(), 1);
    let series = &day.series[0];
    assert!(series.rolling_5m.is_none());
    assert!(series.five_minute_trend.is_empty());
    assert!(series.thirty_minute_trend.is_empty());
    assert!(series.one_minute_trend.is_empty());
    assert_eq!(series.half_minute_trend.len(), 9);
    assert!(series.half_minute_trend.len() <= MAX_HALF_MINUTE_TREND_POINTS);

    let edge_first = half_minute_point(series, half_minute_bucket_start(from));
    assert!((edge_first.value.covered_seconds - 26.5).abs() < 0.0001);
    assert!((edge_first.value.weighted_output - 265.0).abs() < 0.0001);
    assert!((edge_first.value.output_rate() - 10.0).abs() < 0.0001);
    let edge_middle = half_minute_point(series, half_minute_bucket_start(from + 30.0));
    assert!((edge_middle.value.covered_seconds - 30.0).abs() < 0.0001);
    assert!((edge_middle.value.weighted_output - 300.0).abs() < 0.0001);
    let edge_last = half_minute_point(series, half_minute_bucket_start(from + 60.0));
    assert!((edge_last.value.covered_seconds - 23.5).abs() < 0.0001);
    assert!((edge_last.value.weighted_output - 235.0).abs() < 0.0001);

    let first_weighted = half_minute_point(series, 99_990);
    assert!((first_weighted.value.covered_seconds - 10.0).abs() < 0.0001);
    assert!((first_weighted.value.output_rate() - 10.0).abs() < 0.0001);
    let second_weighted = half_minute_point(series, 100_020);
    assert!((second_weighted.value.weighted_output - 700.0).abs() < 0.0001);
    assert!((second_weighted.value.covered_seconds - 50.0).abs() < 0.0001);
    assert!((second_weighted.value.output_rate() - 14.0).abs() < 0.0001);
    let third_weighted = half_minute_point(series, 100_050);
    assert!((third_weighted.value.weighted_output - 600.0).abs() < 0.0001);
    assert!((third_weighted.value.covered_seconds - 40.0).abs() < 0.0001);
    assert!((third_weighted.value.output_rate() - 15.0).abs() < 0.0001);

    let clipped_now = half_minute_point(series, 100_140);
    assert!((clipped_now.value.weighted_output - 14.0).abs() < 0.0001);
    assert!((clipped_now.value.covered_seconds - 3.5).abs() < 0.0001);
    assert!((clipped_now.value.output_rate() - 4.0).abs() < 0.0001);
    let old_bucket = half_minute_bucket_start(now - 5_000.0);
    assert!(series.half_minute_trend.iter().any(|item| item.bucket_start == old_bucket));
    assert!(!series.half_minute_trend.iter().any(|item| item.value.output_rate() == 99.0));

    let thirty_minutes = activity_history(&connection, now, &ActivitySpeedFilter::default(), 1_800).unwrap();
    assert!(thirty_minutes.series[0].half_minute_trend.len() <= 61);
    assert!(!thirty_minutes.series[0]
        .half_minute_trend
        .iter()
        .any(|item| item.bucket_start == old_bucket));
    let legacy = query(&connection, now, &ActivitySpeedFilter::default(), 8).unwrap();
    assert!(legacy.series[0].one_minute_trend.len() <= MAX_DEFAULT_MINUTE_TREND_POINTS);
    assert!(!legacy.series[0]
        .one_minute_trend
        .iter()
        .any(|item| item.bucket_start == old_bucket));
}

#[test]
fn activity_history_can_return_exactly_2881_half_minute_buckets() {
    let connection = database();
    let now = 100_000.5;
    let from = now - 86_400.0;
    let first_bucket = half_minute_bucket_start(from);
    let samples = (0..MAX_HALF_MINUTE_TREND_POINTS)
        .map(|index| {
            let bucket = (first_bucket + index as i64 * HALF_MINUTE_SECONDS) as f64;
            let start = if index == 0 { from + 0.1 } else { bucket + 1.0 };
            let end = start + 0.2;
            sample(
                &format!("half-minute-{index}"),
                start,
                end,
                6.0,
                end - start,
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(add_samples(&connection, &samples, now).unwrap(), MAX_HALF_MINUTE_TREND_POINTS);

    let result = activity_history(&connection, now, &ActivitySpeedFilter::default(), 86_400).unwrap();
    let points = &result.series[0].half_minute_trend;
    assert_eq!(points.len(), MAX_HALF_MINUTE_TREND_POINTS);
    assert_eq!(points.first().unwrap().bucket_start, first_bucket);
    assert_eq!(points.last().unwrap().bucket_start, half_minute_bucket_start(now));
}

#[test]
fn activity_history_enforces_the_64_series_limit() {
    let connection = database();
    for index in 0..65 {
        let mut item = sample(&format!("series-{index}"), 100.0, 101.0, 1.0, 1.0);
        item.model = format!("model-{index}");
        add_sample(&connection, &item, 110.0).unwrap();
    }
    assert!(matches!(
        activity_history(&connection, 110.0, &ActivitySpeedFilter::default(), 86_400),
        Err(ActivitySpeedStoreError::TooManySeries)
    ));
}

#[test]
fn activity_history_is_read_only_and_does_not_prune_retained_tables() {
    let connection = database();
    let item = sample("expired-detail", 10.0, 11.0, 3.0, 1.0);
    connection
        .execute(
            "INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
            rusqlite::params![
                item.source_identity,
                item.id,
                item.display_mode,
                item.estimator_id,
                item.estimator_version,
                item.metric_kind,
                item.client,
                item.model,
                item.started_at,
                item.ended_at,
                item.output_rate,
                item.covered_seconds,
                item.output_rate * item.covered_seconds,
            ],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO activity_speed_sample_ids(source_identity,id,ended_at) VALUES (?1,?2,?3)",
            rusqlite::params![item.source_identity, item.id, item.ended_at],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO activity_speed_buckets_5m(source_identity,display_mode,estimator_id,estimator_version,metric_kind,client,model,bucket_start,weighted_output,covered_seconds,sample_count) VALUES (?1,?2,?3,?4,?5,?6,?7,0,3,1,1)",
            rusqlite::params![
                item.source_identity,
                item.display_mode,
                item.estimator_id,
                item.estimator_version,
                item.metric_kind,
                item.client,
                item.model,
            ],
        )
        .unwrap();

    let result = activity_history(&connection, 5_000_000.0, &ActivitySpeedFilter::default(), 86_400).unwrap();
    assert!(result.series.is_empty());
    for table in ["activity_speed_samples", "activity_speed_sample_ids", "activity_speed_buckets_5m"] {
        let count: i64 = connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1, "activity history must not prune {table}");
    }
}

#[test]
fn activity_history_keeps_dimension_scopes_separate_and_rejects_other_windows() {
    let connection = database();
    let mut source = sample("source-b", 110.0, 112.0, 20.0, 2.0);
    source.source_identity = "source-b".into();
    let mut mode = sample("mode", 110.0, 112.0, 30.0, 2.0);
    mode.display_mode = "agentSpeed".into();
    let mut estimator = sample("estimator", 110.0, 112.0, 40.0, 2.0);
    estimator.estimator_id = "statusline".into();
    let mut estimator_version = sample("estimator-version", 110.0, 112.0, 45.0, 2.0);
    estimator_version.estimator_version = "2".into();
    let mut client = sample("client", 110.0, 112.0, 50.0, 2.0);
    client.client = "claude".into();
    let mut model = sample("model", 110.0, 112.0, 60.0, 2.0);
    model.model = "model-b".into();
    let base = sample("base", 110.0, 112.0, 10.0, 2.0);
    for item in [&base, &source, &mode, &estimator, &estimator_version, &client, &model] {
        add_sample(&connection, item, 120.0).unwrap();
    }

    let all = activity_history(&connection, 120.0, &ActivitySpeedFilter::default(), 86_400).unwrap();
    assert_eq!(all.series.len(), 7);
    assert!(all.series.iter().all(|item| item.rolling_5m.is_none()
        && item.one_minute_trend.is_empty() && item.half_minute_trend.len() == 1));
    let filter = ActivitySpeedFilter {
        source_identity: Some(LEGACY_SOURCE_IDENTITY.into()),
        display_mode: Some("tokens".into()),
        estimator_id: Some("agent-speed".into()),
        estimator_version: Some("1".into()),
        client: Some("codex".into()),
        model: Some("model-a".into()),
        ..Default::default()
    };
    let filtered = activity_history(&connection, 120.0, &filter, 86_400).unwrap();
    assert_eq!(filtered.series.len(), 1);
    assert!((filtered.series[0].half_minute_trend[0].value.output_rate() - 10.0).abs() < 0.0001);
    assert!(matches!(
        activity_history(&connection, 120.0, &filter, 3_600),
        Err(ActivitySpeedStoreError::InvalidWindow)
    ));
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
