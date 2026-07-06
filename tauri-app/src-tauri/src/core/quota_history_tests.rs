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
fn record_writes_canonical_codex_key_and_source() {
    let path = temp_db_path("canonical-key-source");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("来先生", 0.01, reset as i64, 0.50, (reset + 500_000.0) as i64))
        .unwrap();

    let connection = database.open().unwrap();
    let stored = connection
        .query_row(
            "SELECT account_key, plan_type, limit_name, source FROM quota_snapshots ORDER BY id DESC LIMIT 1;",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .unwrap();

    assert_eq!(stored.0, "来先生|Pro|codex");
    assert_eq!(stored.1.as_deref(), Some("Pro"));
    assert_eq!(stored.2.as_deref(), Some("codex"));
    assert_eq!(stored.3.as_deref(), Some("tauri"));

    let _ = std::fs::remove_file(path);
}

#[test]
fn record_uses_read_plan_label_instead_of_inventing_pro() {
    let path = temp_db_path("plan-label");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle_with_plan(
            "来先生",
            "Plus",
            0.01,
            reset as i64,
            0.50,
            (reset + 500_000.0) as i64,
        ))
        .unwrap();

    let connection = database.open().unwrap();
    let stored = connection
        .query_row(
            "SELECT account_key, plan_type, limit_name FROM quota_snapshots ORDER BY id DESC LIMIT 1;",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .unwrap();

    assert_eq!(stored.0, "来先生|Plus|codex");
    assert_eq!(stored.1.as_deref(), Some("Plus"));
    assert_eq!(stored.2.as_deref(), Some("codex"));

    let _ = std::fs::remove_file(path);
}

#[test]
fn record_unknown_plan_does_not_write_fake_pro() {
    let path = temp_db_path("unknown-plan");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle_with_plan(
            "来先生",
            "计划待读取",
            0.01,
            reset as i64,
            0.50,
            (reset + 500_000.0) as i64,
        ))
        .unwrap();

    let connection = database.open().unwrap();
    let stored = connection
        .query_row(
            "SELECT account_key, plan_type, limit_name FROM quota_snapshots ORDER BY id DESC LIMIT 1;",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .unwrap();

    assert_eq!(stored.0, "来先生|codex");
    assert_eq!(stored.1, None);
    assert_eq!(stored.2.as_deref(), Some("codex"));

    let _ = std::fs::remove_file(path);
}

#[test]
fn schema_adds_nullable_source_column_to_existing_database() {
    let path = temp_db_path("source-migration");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE quota_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                account_key TEXT NOT NULL,
                plan_type TEXT,
                limit_name TEXT,
                account_name TEXT,
                five_hour_used_percent INTEGER,
                five_hour_resets_at REAL,
                seven_day_used_percent INTEGER,
                seven_day_resets_at REAL,
                status TEXT NOT NULL
            );
            "#,
        )
        .unwrap();

    ensure_schema(&connection).unwrap();
    let has_source = connection
        .prepare("PRAGMA table_info(quota_snapshots);")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .any(|name| name.unwrap() == "source");

    assert!(has_source);

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_includes_legacy_fake_pro_rows_for_same_codex_account() {
    let path = temp_db_path("legacy-fake-pro");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_history_row_with_source(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
        Some("tauri"),
    );
    database
        .record(&bundle_with_plan(
            "tester",
            "Plus",
            0.15,
            reset as i64,
            0.21,
            (reset + 500_000.0) as i64,
        ))
        .unwrap();

    let history = database.recent_history_24h(12).unwrap();
    assert!(history
        .iter()
        .any(|point| point.five_hour_remaining_percent == Some(0.90)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.85));

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
fn recent_history_mixes_different_sources_for_same_codex_account() {
    let path = temp_db_path("source-merge");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_history_row_with_source(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
        Some("swift"),
    );
    insert_history_row_with_source(
        &connection,
        &history_row(
            now - 300.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            12,
            reset,
            21,
            reset + 500_000.0,
        ),
        Some("tauri"),
    );

    let history = database.recent_history_24h(12).unwrap();
    assert!(history
        .iter()
        .any(|point| point.five_hour_remaining_percent == Some(0.90)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.88));

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_does_not_merge_non_codex_limit_rows() {
    let path = temp_db_path("non-codex-limit");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_row(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|gpt-5-high",
            "Pro",
            Some("gpt-5-high"),
            50,
            reset,
            50,
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
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
    )
    .unwrap();

    let history = database.recent_history_24h(12).unwrap();
    assert!(history
        .iter()
        .all(|point| point.five_hour_remaining_percent != Some(0.50)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.90));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_suppresses_recovered_midcycle_usage_spike() {
    let path = temp_db_path("midcycle-spike");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    for (offset, used) in [(-900.0, 10), (-600.0, 45), (-300.0, 12)] {
        insert_row(
            &connection,
            &history_row(
                now + offset,
                "tester|Pro|codex",
                "Pro",
                Some("codex"),
                used,
                reset,
                20,
                reset + 500_000.0,
            ),
        )
        .unwrap();
    }

    let history = database.recent_history_24h(12).unwrap();
    assert!(history
        .iter()
        .all(|point| point.five_hour_remaining_percent != Some(0.55)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.88));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_allows_recovery_on_new_reset_window() {
    let path = temp_db_path("new-reset-recovery");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let old_reset = now - 60.0;
    let new_reset = now + 5.0 * 3_600.0;

    insert_row(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            100,
            old_reset,
            20,
            now + 500_000.0,
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
            0,
            new_reset,
            20,
            now + 500_000.0,
        ),
    )
    .unwrap();

    let history = database.recent_history_24h(12).unwrap();
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(1.0));

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

#[test]
fn history_bundle_builds_all_axes_from_one_read() {
    let path = temp_db_path("history-bundle");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 12.0 * 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.history_bundle(365, RECENT_BIN_COUNT).unwrap();
    assert_eq!(history.recent_24h.len(), RECENT_BIN_COUNT);
    assert_eq!(history.recent_7d.len(), 7 * 24);
    assert_eq!(history.recent_30d.len(), 30 * 4);
    assert!(history.daily.iter().any(|point| {
        point.five_hour_remaining_percent == Some(0.80)
            && point.seven_day_remaining_percent == Some(0.60)
    }));
    assert_eq!(
        history.recent_24h.last().unwrap().five_hour_remaining_percent,
        Some(0.80)
    );
    assert_eq!(
        history.recent_7d.last().unwrap().seven_day_remaining_percent,
        Some(0.60)
    );

    let _ = std::fs::remove_file(path);
}

fn bundle(
    name: &str,
    five_used: f64,
    five_reset: i64,
    seven_used: f64,
    seven_reset: i64,
) -> AccountQuotaBundle {
    bundle_with_plan(name, "Pro", five_used, five_reset, seven_used, seven_reset)
}

fn bundle_with_plan(
    name: &str,
    plan_label: &str,
    five_used: f64,
    five_reset: i64,
    seven_used: f64,
    seven_reset: i64,
) -> AccountQuotaBundle {
    AccountQuotaBundle {
        account: AccountInfo {
            display_name: name.into(),
            plan_label: plan_label.into(),
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
        quota_history_daily: Vec::new(),
        quota_history_24h: Vec::new(),
        quota_history_7d: Vec::new(),
        quota_history_30d: Vec::new(),
        warnings: Vec::new(),
        diagnostics: Vec::new(),
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
        source: None,
        five_hour_used_percent: Some(five_used_percent),
        five_hour_resets_at: Some(five_reset),
        seven_day_used_percent: Some(seven_used_percent),
        seven_day_resets_at: Some(seven_reset),
        status: "测试".into(),
    }
}

fn insert_history_row_with_source(
    connection: &rusqlite::Connection,
    row: &QuotaHistoryRow,
    source: Option<&str>,
) {
    connection
        .execute(
            r#"
            INSERT INTO quota_snapshots (
                created_at, account_key, plan_type, limit_name, account_name, source,
                five_hour_used_percent, five_hour_resets_at,
                seven_day_used_percent, seven_day_resets_at, status
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
            "#,
            rusqlite::params![
                row.created_at,
                row.account_key,
                row.plan_type,
                row.limit_name,
                row.account_name,
                source,
                row.five_hour_used_percent,
                row.five_hour_resets_at,
                row.seven_day_used_percent,
                row.seven_day_resets_at,
                row.status
            ],
        )
        .unwrap();
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
        output_tokens: 0,
        cache_hit_rate: None,
        five_hour_remaining_percent: None,
        seven_day_remaining_percent: None,
    }
}
