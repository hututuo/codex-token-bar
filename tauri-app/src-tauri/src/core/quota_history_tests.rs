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
