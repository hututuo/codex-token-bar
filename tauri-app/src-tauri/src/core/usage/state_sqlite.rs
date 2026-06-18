use crate::models::{
    AccountInfo, ActivityDay, CacheHitRankingItem, DashboardSnapshot, DashboardStats,
    QuotaLimit, QuotaSnapshot, RecentUsagePoint, ResetCreditSummary,
};
use rusqlite::{Connection, OpenFlags, Result};
use std::path::Path;

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
    let activity_days = read_activity_days(&connection)?;
    let recent_usage_24h = read_recent_usage(&connection)?;

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

    let peak_day_tokens: i64 = connection.query_row(
        r#"
        SELECT COALESCE(MAX(day_tokens), 0)
        FROM (
            SELECT SUM(tokens_used) AS day_tokens
            FROM threads
            GROUP BY strftime('%Y-%m-%d', COALESCE(updated_at_ms, updated_at) / 1000, 'unixepoch', 'localtime')
        );
        "#,
        [],
        |row| row.get(0),
    )?;

    let active_days = read_active_days(connection)?;

    Ok(DashboardStats {
        total_tokens: to_u64(total_tokens),
        peak_day_tokens: to_u64(peak_day_tokens),
        peak_thread_tokens: to_u64(peak_thread_tokens),
        current_streak_days: current_streak_days(&active_days),
        longest_streak_days: longest_streak_days(&active_days),
        total_calls: read_recent_calls(connection)?,
        total_threads: to_u32(total_threads),
    })
}

fn read_activity_days(connection: &Connection) -> Result<Vec<ActivityDay>> {
    let mut statement = connection.prepare(
        r#"
        WITH RECURSIVE days(day) AS (
            SELECT date('now', 'localtime', '-364 days')
            UNION ALL
            SELECT date(day, '+1 day') FROM days WHERE day < date('now', 'localtime')
        )
        SELECT days.day,
               COALESCE(SUM(threads.tokens_used), 0) AS tokens,
               COUNT(threads.id) AS calls
        FROM days
        LEFT JOIN threads
          ON strftime('%Y-%m-%d', COALESCE(threads.updated_at_ms, threads.updated_at) / 1000, 'unixepoch', 'localtime') = days.day
        GROUP BY days.day
        ORDER BY days.day;
        "#,
    )?;

    let rows = statement.query_map([], |row| {
        let date: String = row.get(0)?;
        let tokens: i64 = row.get(1)?;
        let calls: i64 = row.get(2)?;
        Ok(ActivityDay {
            date,
            tokens: to_u64(tokens),
            calls: to_u32(calls),
            cache_hit_rate: 0.0,
        })
    })?;

    rows.collect()
}

fn read_recent_usage(connection: &Connection) -> Result<Vec<RecentUsagePoint>> {
    let mut statement = connection.prepare(
        r#"
        WITH RECURSIVE bins(bin_epoch) AS (
            SELECT CAST(CAST(strftime('%s', 'now', '-24 hours') AS INTEGER) / 300 AS INTEGER) * 300
            UNION ALL
            SELECT bin_epoch + 300
            FROM bins
            WHERE bin_epoch < CAST(CAST(strftime('%s', 'now') AS INTEGER) / 300 AS INTEGER) * 300
        )
        SELECT strftime('%H:%M', bins.bin_epoch, 'unixepoch', 'localtime') AS label,
               COALESCE(SUM(threads.tokens_used), 0) AS tokens,
               COUNT(threads.id) AS calls
        FROM bins
        LEFT JOIN threads
          ON CAST((COALESCE(threads.updated_at_ms, threads.updated_at) / 1000) / 300 AS INTEGER) * 300 = bins.bin_epoch
        GROUP BY bins.bin_epoch
        ORDER BY bins.bin_epoch;
        "#,
    )?;

    let rows = statement.query_map([], |row| {
        let label: String = row.get(0)?;
        let tokens: i64 = row.get(1)?;
        let calls: i64 = row.get(2)?;
        Ok(RecentUsagePoint {
            label,
            tokens: to_u64(tokens),
            calls: to_u32(calls),
            cache_hit_rate: None,
            five_hour_remaining_percent: None,
            seven_day_remaining_percent: None,
        })
    })?;

    rows.collect()
}

fn read_active_days(connection: &Connection) -> Result<Vec<bool>> {
    let days = read_activity_days(connection)?;
    Ok(days.into_iter().map(|day| day.tokens > 0).collect())
}

fn read_recent_calls(connection: &Connection) -> Result<u32> {
    let calls: i64 = connection.query_row(
        r#"
        SELECT COUNT(*)
        FROM threads
        WHERE COALESCE(updated_at_ms, updated_at) / 1000 >= strftime('%s', 'now', '-24 hours');
        "#,
        [],
        |row| row.get(0),
    )?;
    Ok(to_u32(calls))
}

fn current_streak_days(active_days: &[bool]) -> u32 {
    let mut streak = 0;
    for active in active_days.iter().rev() {
        if *active {
            streak += 1;
        } else if streak > 0 {
            break;
        }
    }
    streak
}

fn longest_streak_days(active_days: &[bool]) -> u32 {
    let mut best = 0;
    let mut current = 0;
    for active in active_days {
        if *active {
            current += 1;
            best = best.max(current);
        } else {
            current = 0;
        }
    }
    best
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
        assert_eq!(snapshot.stats.peak_thread_tokens, 180);
        assert_eq!(snapshot.stats.total_threads, 2);
        assert!(snapshot.activity_days.iter().any(|day| day.tokens == 300));
        assert!(snapshot.recent_usage_24h.iter().any(|point| point.tokens == 300));

        fs::remove_dir_all(root).unwrap();
    }
}
