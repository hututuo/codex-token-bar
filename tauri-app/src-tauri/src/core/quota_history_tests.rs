use super::*;
use crate::models::{AccountInfo, QuotaLimit, ResetCreditSummary};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn record_normalizes_same_reset_window_regressions() {
    let path = temp_db_path("normalize");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.84, reset as i64, 0.20, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.71, reset as i64, 0.21, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_history_24h(4).unwrap();
    let latest = history.last().unwrap();
    assert_eq!(latest.five_hour_remaining_percent, Some(0.16));
    assert_eq!(latest.seven_day_remaining_percent, Some(0.79));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_recovers_from_isolated_full_usage_spike() {
    let path = temp_db_path("full-spike");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.00, reset as i64, 0.20, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 1.00, reset as i64, 0.20, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.15, reset as i64, 0.21, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_history_24h(4).unwrap();
    let latest = history.last().unwrap();
    assert_eq!(latest.five_hour_remaining_percent, Some(0.85));
    assert_eq!(latest.seven_day_remaining_percent, Some(0.79));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_suppresses_recovered_full_usage_spike_runs() {
    let path = temp_db_path("full-spike-run");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.02, reset as i64, 0.03, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 1.00, reset as i64, 1.00, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 1.00, reset as i64, 1.00, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.06, reset as i64, 0.04, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_history_24h(12).unwrap();
    assert!(history
        .iter()
        .all(|point| point.five_hour_remaining_percent != Some(0.0)));
    assert!(history
        .iter()
        .all(|point| point.seven_day_remaining_percent != Some(0.0)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.94));
    assert_eq!(history.last().unwrap().seven_day_remaining_percent, Some(0.96));

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_includes_legacy_codex_account_key_rows() {
    let path = temp_db_path("legacy-key");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_row(
        &connection,
        &history_row(
            now - 600.0,
            "tester|pro",
            "pro",
            None,
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
    )
    .unwrap();
    insert_row(
        &connection,
        &history_row(
            now - 300.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            15,
            reset,
            21,
            reset + 500_000.0,
        ),
    )
    .unwrap();

    let history = database.recent_history_24h(12).unwrap();
    assert!(history
        .iter()
        .any(|point| point.five_hour_remaining_percent == Some(0.90)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.85));

    let _ = std::fs::remove_file(path);
}

#[test]
fn quota_history_points_include_start_unix_for_time_aligned_merge() {
    let path = temp_db_path("start-unix");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_history_24h(RECENT_BIN_COUNT).unwrap();
    assert!(history.iter().all(|point| point.start_unix > 0));
    for pair in history.windows(2) {
        assert_eq!(pair[1].start_unix - pair[0].start_unix, 5 * 60);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn overlay_history_matches_points_by_start_unix_not_position() {
    let mut points = vec![recent_point(1_000), recent_point(1_300), recent_point(1_600)];
    let history = vec![
        QuotaHistoryPoint {
            label: "00:25".into(),
            start_unix: 1_300,
            five_hour_remaining_percent: Some(0.88),
            seven_day_remaining_percent: Some(0.77),
        },
        QuotaHistoryPoint {
            label: "00:30".into(),
            start_unix: 1_600,
            five_hour_remaining_percent: Some(0.66),
            seven_day_remaining_percent: Some(0.55),
        },
    ];

    overlay_history(&mut points, &history);

    assert_eq!(points[0].five_hour_remaining_percent, None);
    assert_eq!(points[1].five_hour_remaining_percent, Some(0.88));
    assert_eq!(points[2].seven_day_remaining_percent, Some(0.55));
}

#[test]
fn history_carries_to_reset_as_full_quota() {
    let path = temp_db_path("reset-carry");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = (now_unix() - 60.0) as i64;

    database
        .record(&bundle("tester", 0.50, reset, 0.30, reset + 500_000))
        .unwrap();

    let history = database.recent_history_24h(2).unwrap();
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(1.0));

    let _ = std::fs::remove_file(path);
}

#[test]
fn daily_history_groups_quota_samples_by_local_day() {
    let path = temp_db_path("daily");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.30, reset as i64, 0.50, (reset + 500_000.0) as i64))
        .unwrap();

    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let today = format_date(OffsetDateTime::now_utc().to_offset(local_offset).date());
    let history = database.daily_history(1).unwrap();
    let quota = history.get(&today).unwrap();

    assert_eq!(quota.five_hour_remaining_percent, Some(0.75));
    assert_eq!(quota.seven_day_remaining_percent, Some(0.55));

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_uses_canonical_five_minute_axis() {
    let path = temp_db_path("recent-axis");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_history_24h(RECENT_BIN_COUNT).unwrap();
    assert_eq!(history.len(), 289);
    assert!(history
        .iter()
        .all(|point| point.label.len() == "00:00".len()));
    for pair in history.windows(2) {
        let left = minutes_since_midnight(&pair[0].label);
        let right = minutes_since_midnight(&pair[1].label);
        assert_eq!((right - left).rem_euclid(24 * 60), 5);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn interval_history_supports_hour_and_six_hour_axes() {
    let path = temp_db_path("interval-axis");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 12.0 * 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let hourly = database.recent_history(168, 60 * 60).unwrap();
    assert_eq!(hourly.len(), 168);
    assert!(hourly
        .iter()
        .all(|point| point.label.len() == "00:00".len()));

    let six_hour = database.recent_history(120, 6 * 60 * 60).unwrap();
    assert_eq!(six_hour.len(), 120);
    assert!(six_hour
        .iter()
        .all(|point| point.label.len() == "00:00".len()));

    let _ = std::fs::remove_file(path);
}

fn bundle(
    name: &str,
    five_used: f64,
    five_reset: i64,
    seven_used: f64,
    seven_reset: i64,
) -> AccountQuotaBundle {
    AccountQuotaBundle {
        account: AccountInfo {
            display_name: name.into(),
            plan_label: "Pro".into(),
        },
        quota: QuotaSnapshot {
            five_hour: QuotaLimit {
                label: "5h".into(),
                remaining_percent: 1.0 - five_used,
                used_percent: five_used,
                resets_at: "12:00".into(),
                resets_at_unix: Some(five_reset),
            },
            seven_day: QuotaLimit {
                label: "7d".into(),
                remaining_percent: 1.0 - seven_used,
                used_percent: seven_used,
                resets_at: "06/18".into(),
                resets_at_unix: Some(seven_reset),
            },
            reset_credit: ResetCreditSummary {
                available_count: 0,
                status: "0 张重置卡".into(),
                credits: Vec::new(),
            },
            pace_label: "测试".into(),
        },
        quota_history_24h: Vec::new(),
        quota_history_7d: Vec::new(),
        quota_history_30d: Vec::new(),
        warnings: Vec::new(),
    }
}

#[allow(clippy::too_many_arguments)]
fn history_row(
    created_at: f64,
    account_key: &str,
    plan_type: &str,
    limit_name: Option<&str>,
    five_used_percent: i32,
    five_reset: f64,
    seven_used_percent: i32,
    seven_reset: f64,
) -> QuotaHistoryRow {
    QuotaHistoryRow {
        created_at,
        account_key: account_key.into(),
        plan_type: Some(plan_type.into()),
        limit_name: limit_name.map(str::to_string),
        account_name: Some("tester".into()),
        five_hour_used_percent: Some(five_used_percent),
        five_hour_resets_at: Some(five_reset),
        seven_day_used_percent: Some(seven_used_percent),
        seven_day_resets_at: Some(seven_reset),
        status: "测试".into(),
    }
}

fn temp_db_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "codex-token-bar-quota-history-{label}-{}-{}.sqlite",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn minutes_since_midnight(label: &str) -> i32 {
    let (hour, minute) = label.split_once(':').unwrap();
    hour.parse::<i32>().unwrap() * 60 + minute.parse::<i32>().unwrap()
}

fn recent_point(start_unix: i64) -> RecentUsagePoint {
    RecentUsagePoint {
        label: "00:00".into(),
        start_unix,
        tokens: 0,
        calls: 0,
        input_tokens: 0,
        cached_input_tokens: 0,
        cache_hit_rate: None,
        five_hour_remaining_percent: None,
        seven_day_remaining_percent: None,
    }
}
