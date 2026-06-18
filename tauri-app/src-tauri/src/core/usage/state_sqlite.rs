use crate::core::quota_history;
use crate::models::{
    AccountInfo, ActivityDay, CacheHitRankingItem, DashboardSnapshot, DashboardStats,
    QuotaLimit, QuotaSnapshot, RecentUsagePoint, ResetCreditSummary,
};
use rusqlite::{Connection, OpenFlags, Result};
use std::path::Path;
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

pub fn dashboard_snapshot(codex_home: &Path) -> Result<DashboardSnapshot> {
    let db_path = codex_home.join("state_5.sqlite");
    let connection = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    connection.busy_timeout(std::time::Duration::from_secs(3))?;

    let generated_at: String = connection.query_row(
        "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
        [],
        |row| row.get(0),
    )?;
    let stats = read_stats(&connection)?;
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let local_now = OffsetDateTime::now_utc().to_offset(local_offset);
    let mut activity_days = empty_activity_days(local_now.date());
    quota_history::apply_activity_history(&mut activity_days);
    let recent_usage_24h = empty_recent_usage(local_now);

    Ok(DashboardSnapshot {
        generated_at,
        account: AccountInfo {
            display_name: "本地账户".into(),
            plan_label: "Pro".into(),
        },
        stats,
        quota: placeholder_quota(),
        activity_days,
        recent_usage_24h,
        cache_hit_ranking: Vec::<CacheHitRankingItem>::new(),
    })
}

pub fn empty_dashboard_snapshot() -> DashboardSnapshot {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let now = OffsetDateTime::now_utc();
    let local_now = now.to_offset(local_offset);

    DashboardSnapshot {
        generated_at: now.format(&Rfc3339).unwrap_or_else(|_| String::new()),
        account: AccountInfo {
            display_name: "本地账户".into(),
            plan_label: "Pro".into(),
        },
        stats: DashboardStats {
            total_tokens: 0,
            peak_day_tokens: 0,
            peak_thread_tokens: 0,
            current_streak_days: 0,
            longest_streak_days: 0,
            total_calls: 0,
            total_threads: 0,
        },
        quota: placeholder_quota(),
        activity_days: empty_activity_days(local_now.date()),
        recent_usage_24h: empty_recent_usage(local_now),
        cache_hit_ranking: Vec::new(),
    }
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

fn empty_recent_usage(now: OffsetDateTime) -> Vec<RecentUsagePoint> {
    let now_epoch = now.unix_timestamp();
    let end_bin = now_epoch - now_epoch.rem_euclid(300);
    let start_bin = end_bin - 24 * 60 * 60;
    (0..=288)
        .map(|index| {
            let timestamp = OffsetDateTime::from_unix_timestamp(start_bin + index * 300)
                .unwrap_or(now)
                .to_offset(now.offset());
            RecentUsagePoint {
                label: format_time(timestamp),
                tokens: 0,
                calls: 0,
                cache_hit_rate: None,
                five_hour_remaining_percent: None,
                seven_day_remaining_percent: None,
            }
        })
        .collect()
}

fn read_stats(connection: &Connection) -> Result<DashboardStats> {
    let (total_tokens, peak_thread_tokens, total_threads): (i64, i64, i64) =
        connection.query_row(
            r#"
            SELECT COALESCE(SUM(tokens_used), 0) AS total_tokens,
                   COALESCE(MAX(tokens_used), 0) AS peak_thread_tokens,
                   COUNT(*) AS total_threads
            FROM threads;
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;

    Ok(DashboardStats {
        total_tokens: to_u64(total_tokens),
        peak_day_tokens: 0,
        peak_thread_tokens: to_u64(peak_thread_tokens),
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

fn to_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
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
    fn dashboard_snapshot_reads_state_sqlite_summary_and_recent_bins() {
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
        assert_eq!(snapshot.stats.total_tokens, 300);
        assert_eq!(snapshot.stats.peak_day_tokens, 0);
        assert_eq!(snapshot.stats.peak_thread_tokens, 180);
        assert_eq!(snapshot.stats.current_streak_days, 0);
        assert_eq!(snapshot.stats.longest_streak_days, 0);
        assert_eq!(snapshot.stats.total_calls, 0);
        assert_eq!(snapshot.stats.total_threads, 2);
        assert!(snapshot.activity_days.iter().all(|day| day.tokens == 0));
        assert_eq!(snapshot.recent_usage_24h.len(), 289);
        assert!(snapshot.recent_usage_24h.iter().all(|point| point.tokens == 0));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn empty_dashboard_snapshot_is_zero_without_real_usage() {
        let snapshot = empty_dashboard_snapshot();

        assert_eq!(snapshot.account.display_name, "本地账户");
        assert_eq!(snapshot.stats.total_tokens, 0);
        assert_eq!(snapshot.stats.peak_day_tokens, 0);
        assert_eq!(snapshot.stats.peak_thread_tokens, 0);
        assert_eq!(snapshot.stats.total_calls, 0);
        assert_eq!(snapshot.stats.total_threads, 0);
        assert_eq!(snapshot.quota.pace_label, "额度待读取");
        assert_eq!(snapshot.activity_days.len(), 365);
        assert_eq!(snapshot.recent_usage_24h.len(), 289);
        assert!(snapshot.cache_hit_ranking.is_empty());
    }
}
