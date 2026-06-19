use crate::core::app_paths;
use crate::core::sqlite;
use crate::models::{
    AccountQuotaBundle, ActivityDay, LocalDataWarning, QuotaHistoryPoint, QuotaSnapshot,
    RecentUsagePoint,
};
use rusqlite::{Connection, Result as SqlResult};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;
use time::OffsetDateTime;

mod database;
mod series;

use database::{ensure_schema, insert_row, latest_trusted_row, prune, recent_rows, rows_since};
use series::{make_daily_history, make_recent_history, DailyQuotaHistory};

#[cfg(test)]
use series::format_date;
#[cfg(test)]
use time::UtcOffset;

const HEARTBEAT_SECONDS: f64 = 60.0 * 60.0;
const RETENTION_DAYS: i64 = 45;
const RECENT_BIN_COUNT: usize = 289;

pub fn record_bundle(bundle: &AccountQuotaBundle) -> Result<(), String> {
    if !quota_available(&bundle.quota) {
        return Ok(());
    }
    QuotaHistoryDatabase::default()?
        .record(bundle)
        .map_err(|error| format!("写入额度历史失败：{error}"))
}

pub fn recent_history_24h() -> Result<Vec<QuotaHistoryPoint>, String> {
    QuotaHistoryDatabase::default()?
        .recent_history_24h(RECENT_BIN_COUNT)
        .map_err(|error| format!("读取 24 小时额度历史失败：{error}"))
}

pub fn apply_recent_history(points: &mut [RecentUsagePoint]) -> Result<(), String> {
    if points.is_empty() {
        return Ok(());
    }
    let history = QuotaHistoryDatabase::default()?
        .recent_history_24h(points.len())
        .map_err(|error| format!("读取 24 小时额度历史失败：{error}"))?;
    overlay_history(points, &history);
    Ok(())
}

pub fn apply_activity_history(days: &mut [ActivityDay]) -> Result<(), String> {
    if days.is_empty() {
        return Ok(());
    }
    let history = QuotaHistoryDatabase::default()?
        .daily_history(days.len())
        .map_err(|error| format!("读取每日额度历史失败：{error}"))?;
    for day in days {
        if let Some(quota) = history.get(&day.date) {
            day.five_hour_remaining_percent = quota.five_hour_remaining_percent;
            day.seven_day_remaining_percent = quota.seven_day_remaining_percent;
        }
    }
    Ok(())
}

pub fn overlay_history(points: &mut [RecentUsagePoint], history: &[QuotaHistoryPoint]) {
    for (point, quota) in points.iter_mut().zip(history.iter()) {
        point.five_hour_remaining_percent = quota.five_hour_remaining_percent;
        point.seven_day_remaining_percent = quota.seven_day_remaining_percent;
    }
}

pub fn warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "quota_history".into(),
        message,
    }
}

fn quota_available(quota: &QuotaSnapshot) -> bool {
    quota.five_hour.resets_at_unix.is_some() || quota.seven_day.resets_at_unix.is_some()
}

struct QuotaHistoryDatabase {
    path: PathBuf,
}

impl QuotaHistoryDatabase {
    fn default() -> Result<Self, String> {
        database_path()
            .map(|path| Self { path })
            .ok_or_else(|| "无法定位系统应用支持目录，不能读取额度历史".into())
    }

    fn record(&self, bundle: &AccountQuotaBundle) -> SqlResult<()> {
        let connection = self.open()?;
        let now = now_unix();
        ensure_schema(&connection)?;
        let row = QuotaHistoryRow::from_bundle(bundle, now);
        let latest = latest_trusted_row(&connection, &row.account_key)?;
        let normalized = row.normalized_after(latest.as_ref());
        if latest
            .as_ref()
            .is_some_and(|latest| !should_insert(&normalized, latest, now))
        {
            return Ok(());
        }
        insert_row(&connection, &normalized)?;
        prune(&connection, now)?;
        Ok(())
    }

    fn recent_history_24h(&self, count: usize) -> SqlResult<Vec<QuotaHistoryPoint>> {
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let rows = recent_rows(&connection)?;
        Ok(make_recent_history(rows, count.max(1)))
    }

    fn daily_history(&self, day_count: usize) -> SqlResult<HashMap<String, DailyQuotaHistory>> {
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let rows = rows_since(&connection, day_count.max(1) as f64 * 24.0 * 60.0 * 60.0)?;
        Ok(make_daily_history(rows))
    }

    fn open(&self) -> SqlResult<Connection> {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        sqlite::open_wal(&self.path, Duration::from_secs(3))
    }
}

#[derive(Clone, Debug)]
struct QuotaHistoryRow {
    created_at: f64,
    account_key: String,
    plan_type: Option<String>,
    limit_name: Option<String>,
    account_name: Option<String>,
    five_hour_used_percent: Option<i32>,
    five_hour_resets_at: Option<f64>,
    seven_day_used_percent: Option<i32>,
    seven_day_resets_at: Option<f64>,
    status: String,
}

impl QuotaHistoryRow {
    fn from_bundle(bundle: &AccountQuotaBundle, created_at: f64) -> Self {
        Self {
            created_at,
            account_key: account_key(bundle),
            plan_type: Some(bundle.account.plan_label.clone()).filter(|value| !value.trim().is_empty()),
            limit_name: Some("codex".into()),
            account_name: Some(bundle.account.display_name.clone())
                .filter(|value| !value.trim().is_empty()),
            five_hour_used_percent: percent_to_int(bundle.quota.five_hour.used_percent),
            five_hour_resets_at: bundle.quota.five_hour.resets_at_unix.map(|value| value as f64),
            seven_day_used_percent: percent_to_int(bundle.quota.seven_day.used_percent),
            seven_day_resets_at: bundle.quota.seven_day.resets_at_unix.map(|value| value as f64),
            status: bundle.quota.pace_label.clone(),
        }
    }

    fn normalized_after(&self, previous: Option<&Self>) -> Self {
        let Some(previous) = previous else {
            return self.clone();
        };
        let mut normalized = self.clone();
        normalized.five_hour_used_percent = normalized_used_percent(
            self.five_hour_used_percent,
            self.five_hour_resets_at,
            previous.five_hour_used_percent,
            previous.five_hour_resets_at,
        );
        normalized.seven_day_used_percent = normalized_used_percent(
            self.seven_day_used_percent,
            self.seven_day_resets_at,
            previous.seven_day_used_percent,
            previous.seven_day_resets_at,
        );
        normalized
    }

    fn five_hour_remaining(&self) -> Option<f64> {
        remaining_from_used(self.five_hour_used_percent)
    }

    fn seven_day_remaining(&self) -> Option<f64> {
        remaining_from_used(self.seven_day_used_percent)
    }
}

fn normalized_used_percent(
    current_used: Option<i32>,
    current_reset: Option<f64>,
    previous_used: Option<i32>,
    previous_reset: Option<f64>,
) -> Option<i32> {
    let Some(current_used) = current_used else {
        return previous_used;
    };
    match (current_reset, previous_reset, previous_used) {
        (Some(current_reset), Some(previous_reset), Some(previous_used))
            if same_reset_window(current_reset, previous_reset) =>
        {
            Some(current_used.max(previous_used))
        }
        (None, None, Some(previous_used)) => Some(current_used.max(previous_used)),
        _ => Some(current_used),
    }
}

fn same_reset_window(left: f64, right: f64) -> bool {
    (left - right).abs() < 1.0
}

fn should_insert(row: &QuotaHistoryRow, latest: &QuotaHistoryRow, now: f64) -> bool {
    if row.account_key != latest.account_key {
        return true;
    }
    if row.five_hour_used_percent != latest.five_hour_used_percent {
        return true;
    }
    if row.seven_day_used_percent != latest.seven_day_used_percent {
        return true;
    }
    if row.five_hour_resets_at != latest.five_hour_resets_at {
        return true;
    }
    if row.seven_day_resets_at != latest.seven_day_resets_at {
        return true;
    }
    if row.plan_type != latest.plan_type
        || row.limit_name != latest.limit_name
        || row.account_name != latest.account_name
    {
        return true;
    }
    now - latest.created_at >= HEARTBEAT_SECONDS
}

fn account_key(bundle: &AccountQuotaBundle) -> String {
    let mut parts = vec![
        bundle.account.display_name.trim().to_string(),
        bundle.account.plan_label.trim().to_string(),
        "codex".into(),
    ];
    parts.retain(|value| !value.is_empty());
    if parts.is_empty() {
        "default".into()
    } else {
        parts.join("|")
    }
}

fn percent_to_int(value: f64) -> Option<i32> {
    if !value.is_finite() {
        return None;
    }
    Some((value * 100.0).round().clamp(0.0, 100.0) as i32)
}

fn remaining_from_used(value: Option<i32>) -> Option<f64> {
    value.map(|used| (100 - used).clamp(0, 100) as f64 / 100.0)
}

fn now_unix() -> f64 {
    OffsetDateTime::now_utc().unix_timestamp() as f64
}

fn database_path() -> Option<PathBuf> {
    app_paths::quota_history_database_path()
}

#[cfg(test)]
#[path = "quota_history_tests.rs"]
mod quota_history_tests;
