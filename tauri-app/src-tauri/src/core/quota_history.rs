use crate::core::app_paths;
use crate::core::sqlite;
use crate::models::{
    AccountQuotaBundle, LocalDataWarning, QuotaHistoryDailyPoint, QuotaHistoryPoint, QuotaSnapshot,
};
#[cfg(test)]
use crate::models::RecentUsagePoint;
use rusqlite::{Connection, Result as SqlResult};
#[cfg(test)]
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;
use time::OffsetDateTime;

mod database;
mod series;

use database::{ensure_schema, insert_row, latest_trusted_row, prune, rows_since};
#[cfg(test)]
use database::recent_rows;
use series::{make_daily_history, make_interval_history, make_recent_history};
#[cfg(test)]
use series::DailyQuotaHistory;

#[cfg(test)]
use series::format_date;
#[cfg(test)]
use time::UtcOffset;

const HEARTBEAT_SECONDS: f64 = 60.0 * 60.0;
const RETENTION_DAYS: i64 = 45;
const RECENT_BIN_COUNT: usize = 289;
const QUOTA_HISTORY_SOURCE: &str = "tauri";

#[derive(Clone, Debug, Default)]
pub struct QuotaHistoryBundle {
    pub daily: Vec<QuotaHistoryDailyPoint>,
    pub recent_24h: Vec<QuotaHistoryPoint>,
    pub recent_7d: Vec<QuotaHistoryPoint>,
    pub recent_30d: Vec<QuotaHistoryPoint>,
}

pub fn record_bundle(bundle: &AccountQuotaBundle) -> Result<(), String> {
    if !quota_available(&bundle.quota) {
        return Ok(());
    }
    QuotaHistoryDatabase::default()?
        .record(bundle)
        .map_err(|error| format!("写入额度历史失败：{error}"))
}

pub fn history_bundle(day_count: usize) -> Result<QuotaHistoryBundle, String> {
    QuotaHistoryDatabase::default()?
        .history_bundle(day_count, RECENT_BIN_COUNT)
        .map_err(|error| format!("读取额度历史失败：{error}"))
}

#[cfg(test)]
pub fn overlay_history(points: &mut [RecentUsagePoint], history: &[QuotaHistoryPoint]) {
    let history_by_start: HashMap<i64, &QuotaHistoryPoint> = history
        .iter()
        .map(|point| (point.start_unix, point))
        .collect();
    for point in points.iter_mut() {
        let Some(quota) = history_by_start.get(&point.start_unix) else {
            continue;
        };
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
        let latest = latest_trusted_row(&connection, &row)?;
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

    #[cfg(test)]
    fn recent_history_24h(&self, count: usize) -> SqlResult<Vec<QuotaHistoryPoint>> {
        self.recent_history(count, 5 * 60)
    }

    #[cfg(test)]
    fn recent_history(&self, count: usize, interval_seconds: i64) -> SqlResult<Vec<QuotaHistoryPoint>> {
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let rows = recent_rows(&connection)?;
        Ok(match interval_seconds {
            300 => make_recent_history(rows, count.max(1)),
            _ => make_interval_history(rows, count.max(1), interval_seconds),
        })
    }

    #[cfg(test)]
    fn daily_history(&self, day_count: usize) -> SqlResult<HashMap<String, DailyQuotaHistory>> {
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let rows = rows_since(&connection, day_count.max(1) as f64 * 24.0 * 60.0 * 60.0)?;
        Ok(make_daily_history(rows))
    }

    fn history_bundle(
        &self,
        day_count: usize,
        recent_count: usize,
    ) -> SqlResult<QuotaHistoryBundle> {
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let rows = rows_since(
            &connection,
            day_count.max(31) as f64 * 24.0 * 60.0 * 60.0,
        )?;
        Ok(QuotaHistoryBundle {
            daily: make_daily_history(rows.clone())
                .into_iter()
                .map(|(date, history)| QuotaHistoryDailyPoint {
                    date,
                    five_hour_remaining_percent: history.five_hour_remaining_percent,
                    seven_day_remaining_percent: history.seven_day_remaining_percent,
                })
                .collect(),
            recent_24h: make_recent_history(rows.clone(), recent_count.max(1)),
            recent_7d: make_interval_history(rows.clone(), 7 * 24, 60 * 60),
            recent_30d: make_interval_history(rows, 30 * 4, 6 * 60 * 60),
        })
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
    source: Option<String>,
    five_hour_used_percent: Option<i32>,
    five_hour_resets_at: Option<f64>,
    seven_day_used_percent: Option<i32>,
    seven_day_resets_at: Option<f64>,
    status: String,
}

impl QuotaHistoryRow {
    fn from_bundle(bundle: &AccountQuotaBundle, created_at: f64) -> Self {
        let account_name =
            Some(bundle.account.display_name.clone()).filter(|value| !value.trim().is_empty());
        let plan_type = Some("Pro".to_string());
        let limit_name = Some("codex".to_string());
        let account_key = canonical_account_key(
            account_name.as_deref(),
            plan_type.as_deref(),
            limit_name.as_deref(),
            None,
        );
        Self {
            created_at,
            account_key,
            plan_type,
            limit_name,
            account_name,
            source: Some(QUOTA_HISTORY_SOURCE.into()),
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

    fn history_match_key(&self) -> String {
        canonical_account_key(
            self.account_name.as_deref(),
            self.plan_type.as_deref(),
            self.limit_name.as_deref(),
            Some(&self.account_key),
        )
    }

    fn match_account_name(&self) -> Option<String> {
        canonical_account_name(self.account_name.as_deref(), Some(&self.account_key))
    }

    fn match_plan_type(&self) -> Option<String> {
        canonical_plan_type(self.plan_type.as_deref(), self.limit_name.as_deref())
    }

    fn match_limit_name(&self) -> Option<String> {
        canonical_limit_name(self.limit_name.as_deref())
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
            if should_accept_full_usage_spike_recovery(current_used, previous_used) {
                return Some(current_used);
            }
            Some(current_used.max(previous_used))
        }
        (None, None, Some(previous_used)) => {
            if should_accept_full_usage_spike_recovery(current_used, previous_used) {
                return Some(current_used);
            }
            Some(current_used.max(previous_used))
        }
        _ => Some(current_used),
    }
}

fn should_accept_full_usage_spike_recovery(current_used: i32, previous_used: i32) -> bool {
    previous_used >= 95 && previous_used - current_used >= 20
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

fn canonical_account_key(
    account_name: Option<&str>,
    plan_type: Option<&str>,
    limit_name: Option<&str>,
    fallback_key: Option<&str>,
) -> String {
    let account_name = canonical_account_name(account_name, fallback_key);
    let limit_name = canonical_limit_name(limit_name);
    let plan_type = canonical_plan_type(plan_type, limit_name.as_deref());
    let mut parts = vec![
        account_name.unwrap_or_else(|| "default".into()),
        plan_type.unwrap_or_default(),
        limit_name.unwrap_or_default(),
    ];
    parts.retain(|value| !value.trim().is_empty());
    parts.join("|")
}

fn canonical_account_name(account_name: Option<&str>, fallback_key: Option<&str>) -> Option<String> {
    account_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .or_else(|| {
            fallback_key
                .and_then(|key| key.split('|').next())
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        })
}

fn canonical_plan_type(plan_type: Option<&str>, limit_name: Option<&str>) -> Option<String> {
    if is_codex_main_limit(limit_name) {
        return Some("Pro".into());
    }
    plan_type
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn canonical_limit_name(limit_name: Option<&str>) -> Option<String> {
    if is_codex_main_limit(limit_name) {
        return Some("codex".into());
    }
    limit_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn is_codex_main_limit(limit_name: Option<&str>) -> bool {
    limit_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none_or(|value| value.eq_ignore_ascii_case("codex"))
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
