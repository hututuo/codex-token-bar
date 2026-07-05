use crate::core::sqlite;
use crate::models::{
    AccountInfo, ActivityDay, CacheHitRankingItem, DashboardSnapshot, DashboardStats,
    QuotaLimit, QuotaSnapshot, RecentUsagePoint, ResetCreditSummary,
};
use rusqlite::{Connection, Result};
use std::path::Path;
use std::time::Duration as StdDuration;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

pub fn dashboard_snapshot(codex_home: &Path) -> Result<DashboardSnapshot> {
    let db_path = codex_home.join("state_5.sqlite");
    let connection = sqlite::open_read_only(&db_path, StdDuration::from_secs(3))?;

    let generated_at: String = connection.query_row(
        "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
        [],
        |row| row.get(0),
    )?;
    let stats = read_stats(&connection)?;
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let local_now = OffsetDateTime::now_utc().to_offset(local_offset);
    let activity_days = empty_activity_days(local_now.date());
    let warnings = Vec::new();
    let recent_usage_24h = empty_recent_usage(local_now, 5 * 60, 289);
    let recent_usage_7d = empty_recent_usage(local_now, 60 * 60, 7 * 24);
    let recent_usage_30d = empty_recent_usage(local_now, 6 * 60 * 60, 30 * 4);

    Ok(DashboardSnapshot {
        generated_at,
        account: AccountInfo {
            display_name: "账户待读取".into(),
            plan_label: "计划待读取".into(),
        },
        stats,
        quota: placeholder_quota(),
        activity_days,
        recent_usage_24h,
        recent_usage_7d,
        recent_usage_30d,
        cache_hit_ranking: Vec::<CacheHitRankingItem>::new(),
        cache_usage: Default::default(),
        warnings,
        diagnostics: Vec::new(),
    })
}

fn empty_activity_days(today: Date) -> Vec<ActivityDay> {
    let start = today - Duration::days(364);
    (0..365)
        .map(|index| ActivityDay {
            date: format_date(start + Duration::days(index)),
            tokens: 0,
            calls: 0,
            cache_hit_rate: 0.0,
            five_hour_remaining_percent: None,
            seven_day_remaining_percent: None,
        })
        .collect()
}

fn empty_recent_usage(
    now: OffsetDateTime,
    interval_seconds: i64,
    point_count: i64,
) -> Vec<RecentUsagePoint> {
    let now_epoch = now.unix_timestamp();
    let end_bin = now_epoch - now_epoch.rem_euclid(interval_seconds);
    let start_bin = end_bin - (point_count.saturating_sub(1)) * interval_seconds;
    (0..point_count)
        .map(|index| {
            let bin_epoch = start_bin + index * interval_seconds;
            let timestamp = OffsetDateTime::from_unix_timestamp(bin_epoch)
                .unwrap_or(now)
                .to_offset(now.offset());
            RecentUsagePoint {
                label: format_time(timestamp),
                start_unix: bin_epoch,
                tokens: 0,
                calls: 0,
                input_tokens: 0,
                cached_input_tokens: 0,
                output_tokens: 0,
                cache_hit_rate: None,
                five_hour_remaining_percent: None,
                seven_day_remaining_percent: None,
            }
        })
        .collect()
}

fn read_stats(connection: &Connection) -> Result<DashboardStats> {
    let total_threads: i64 = connection.query_row(
        r#"
        SELECT COUNT(*) AS total_threads
        FROM threads;
        "#,
        [],
        |row| row.get(0),
    )?;

    Ok(DashboardStats {
        total_tokens: 0,
        peak_day_tokens: 0,
        peak_thread_tokens: 0,
        current_streak_days: 0,
        longest_streak_days: 0,
        total_calls: 0,
        total_threads: to_u32(total_threads),
    })
}

fn placeholder_quota() -> QuotaSnapshot {
    QuotaSnapshot {
        five_hour: QuotaLimit {
            label: "5h".into(),
            remaining_percent: 0.0,
            used_percent: 0.0,
            resets_at: "待读取".into(),
            resets_at_unix: None,
        },
        seven_day: QuotaLimit {
            label: "7d".into(),
            remaining_percent: 0.0,
            used_percent: 0.0,
            resets_at: "待读取".into(),
            resets_at_unix: None,
        },
        reset_credit: ResetCreditSummary {
            available_count: 0,
            status: "重置卡待读取".into(),
            credits: Vec::new(),
        },
        pace_label: "额度待读取".into(),
    }
}

fn to_u32(value: i64) -> u32 {
    u32::try_from(value).unwrap_or(0)
}

fn format_date(date: Date) -> String {
    let format = format_description!("[year]-[month]-[day]");
    date.format(&format).unwrap_or_else(|_| String::new())
}

fn format_time(date: OffsetDateTime) -> String {
    let format = format_description!("[hour]:[minute]");
    date.format(&format).unwrap_or_else(|_| String::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn dashboard_snapshot_uses_safe_placeholders_instead_of_state_token_sums() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-tauri-state-sqlite-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();

        let db_path = root.join("state_5.sqlite");
        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    updated_at INTEGER NOT NULL,
                    updated_at_ms INTEGER,
                    tokens_used INTEGER NOT NULL
                );

                INSERT INTO threads (id, updated_at, updated_at_ms, tokens_used)
                VALUES
                    ('a', CAST(strftime('%s', 'now') AS INTEGER) * 1000, CAST(strftime('%s', 'now') AS INTEGER) * 1000, 120),
                    ('b', CAST(strftime('%s', 'now') AS INTEGER) * 1000, CAST(strftime('%s', 'now') AS INTEGER) * 1000, 180);
                "#,
            )
            .unwrap();
        drop(connection);

        let snapshot = dashboard_snapshot(&root).unwrap();
        assert_eq!(snapshot.stats.total_tokens, 0);
        assert_eq!(snapshot.stats.peak_day_tokens, 0);
        assert_eq!(snapshot.stats.peak_thread_tokens, 0);
        assert_eq!(snapshot.stats.current_streak_days, 0);
        assert_eq!(snapshot.stats.longest_streak_days, 0);
        assert_eq!(snapshot.stats.total_calls, 0);
        assert_eq!(snapshot.stats.total_threads, 2);
        assert!(snapshot.activity_days.iter().all(|day| day.tokens == 0));
        assert_eq!(snapshot.recent_usage_24h.len(), 289);
        assert_eq!(snapshot.recent_usage_7d.len(), 168);
        assert_eq!(snapshot.recent_usage_30d.len(), 120);
        assert!(snapshot.recent_usage_24h.iter().all(|point| point.tokens == 0));
        assert!(snapshot.recent_usage_7d.iter().all(|point| point.tokens == 0));
        assert!(snapshot.recent_usage_30d.iter().all(|point| point.tokens == 0));

        fs::remove_dir_all(root).unwrap();
    }

}
