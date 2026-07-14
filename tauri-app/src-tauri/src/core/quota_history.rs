use crate::core::app_paths;
use crate::core::sqlite;
use crate::core::time_series_timeline::LONG_RECENT_POINT_COUNT;
use crate::models::{
    AccountQuotaBundle, LocalDataWarning, QuotaAvailability, QuotaHistoryDailyPoint,
    QuotaHistoryPoint, QuotaLimit, QuotaSnapshot,
};
#[cfg(test)]
use crate::models::RecentUsagePoint;
use rusqlite::backup::Backup;
use rusqlite::{Connection, Result as SqlResult};
#[cfg(test)]
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use time::OffsetDateTime;

mod database;
mod series;

use database::{ensure_schema, insert_row, latest_trusted_row, prune, rows_since_for_row};
#[cfg(test)]
use database::{recent_rows, rows_since};
use series::{make_daily_history, make_interval_history, make_recent_history};
#[cfg(test)]
use series::DailyQuotaHistory;

#[cfg(test)]
use series::format_date;
#[cfg(test)]
use time::UtcOffset;

const HEARTBEAT_SECONDS: f64 = 60.0 * 60.0;
const RETENTION_DAYS: i64 = 45;
const QUOTA_HISTORY_SOURCE: &str = "tauri";
pub(crate) const QUOTA_HISTORY_IDENTITY_VERSION: i64 = 1;
static QUOTA_HISTORY_DATABASE_GATE: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) struct QuotaHistoryIdentity {
    version: i64,
    home_identity: String,
    stable_account_key: String,
    plan_type: String,
    limit_id: String,
}

impl QuotaHistoryIdentity {
    pub(crate) fn from_bundle(
        canonical_codex_home: &Path,
        stable_account_key: Option<&str>,
        bundle: &AccountQuotaBundle,
        limit_id: Option<&str>,
    ) -> Option<Self> {
        Self::from_canonical_parts(
            canonical_codex_home,
            stable_account_key,
            &bundle.account.plan_label,
            limit_id?,
        )
    }

    pub(crate) fn from_canonical_parts(
        canonical_codex_home: &Path,
        stable_account_key: Option<&str>,
        plan_type: &str,
        limit_id: &str,
    ) -> Option<Self> {
        let home_identity = canonical_codex_home
            .to_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())?
            .to_string();
        let stable_account_key = stable_account_key
            .map(str::trim)
            .filter(|value| !value.is_empty())?
            .to_string();
        let limit_id = canonical_stable_limit_name(Some(limit_id))?;
        let plan_type = canonical_plan_type(Some(plan_type), Some(&limit_id))?;
        Some(Self {
            version: QUOTA_HISTORY_IDENTITY_VERSION,
            home_identity,
            stable_account_key,
            plan_type,
            limit_id,
        })
    }
}

#[derive(Clone, Debug, Default)]
pub struct QuotaHistoryBundle {
    pub daily: Vec<QuotaHistoryDailyPoint>,
    pub recent_24h: Vec<QuotaHistoryPoint>,
    pub recent_7d: Vec<QuotaHistoryPoint>,
    pub recent_30d: Vec<QuotaHistoryPoint>,
}

pub fn record_bundle(
    identity: &QuotaHistoryIdentity,
    bundle: &AccountQuotaBundle,
) -> Result<(), String> {
    if !quota_available(&bundle.quota) {
        return Ok(());
    }
    QuotaHistoryDatabase::default()?
        .record_for_identity(Some(identity), bundle)
        .map(|_| ())
        .map_err(|error| format!("写入额度历史失败：{error}"))
}

pub fn history_bundle_for(
    identity: &QuotaHistoryIdentity,
    bundle: &AccountQuotaBundle,
    day_count: usize,
) -> Result<QuotaHistoryBundle, String> {
    QuotaHistoryDatabase::default()?
        .history_bundle_for_identity(
            Some(identity),
            bundle,
            day_count,
            LONG_RECENT_POINT_COUNT as usize,
        )
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
    use crate::models::QuotaAvailability::Measured;
    quota.five_hour.availability == Measured || quota.seven_day.availability == Measured
}

struct QuotaHistoryDatabase {
    path: PathBuf,
}

impl QuotaHistoryDatabase {
    fn default() -> Result<Self, String> {
        let path = database_path()
            .ok_or_else(|| "无法定位系统应用支持目录，不能读取额度历史".to_string())?;
        migrate_legacy_quota_history_if_needed(&path)
            .map_err(|error| format!("迁移 Tauri 额度历史失败：{error}"))?;
        Ok(Self { path })
    }

    fn record_for_identity(
        &self,
        identity: Option<&QuotaHistoryIdentity>,
        bundle: &AccountQuotaBundle,
    ) -> SqlResult<bool> {
        let Some(identity) = identity else {
            return Ok(false);
        };
        let _database_guard = quota_history_database_guard();
        let connection = self.open()?;
        let now = now_unix();
        ensure_schema(&connection)?;
        let row = QuotaHistoryRow::from_bundle(identity, bundle, now);
        let latest = latest_trusted_row(&connection, &row)?;
        let normalized = row.normalized_after(latest.as_ref());
        if latest
            .as_ref()
            .is_some_and(|latest| !should_insert(&normalized, latest, now))
        {
            return Ok(true);
        }
        insert_row(&connection, &normalized)?;
        prune(&connection, now)?;
        Ok(true)
    }

    #[cfg(test)]
    fn record(&self, bundle: &AccountQuotaBundle) -> SqlResult<()> {
        let stable_account_key = format!("sub:test:{}", bundle.account.display_name);
        let identity = QuotaHistoryIdentity::from_bundle(
            self.path.parent().unwrap_or_else(|| Path::new("/fixture/test-home")),
            Some(&stable_account_key),
            bundle,
            Some("codex"),
        )
        .expect("test quota bundle must have a stable history identity");
        self.record_for_identity(Some(&identity), bundle).map(|_| ())
    }

    #[cfg(test)]
    fn recent_five_minute_history(&self, count: usize) -> SqlResult<Vec<QuotaHistoryPoint>> {
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

    #[cfg(test)]
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

    fn history_bundle_for_identity(
        &self,
        identity: Option<&QuotaHistoryIdentity>,
        bundle: &AccountQuotaBundle,
        day_count: usize,
        recent_count: usize,
    ) -> SqlResult<QuotaHistoryBundle> {
        let Some(identity) = identity else {
            return Ok(QuotaHistoryBundle::default());
        };
        let _database_guard = quota_history_database_guard();
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let filter_row = QuotaHistoryRow::from_bundle(identity, bundle, now_unix());
        let rows = rows_since_for_row(
            &connection,
            day_count.max(31) as f64 * 24.0 * 60.0 * 60.0,
            &filter_row,
        )?;
        Ok(history_bundle_from_rows(rows, recent_count))
    }

    #[cfg(test)]
    fn history_bundle_for(
        &self,
        bundle: &AccountQuotaBundle,
        day_count: usize,
        recent_count: usize,
    ) -> SqlResult<QuotaHistoryBundle> {
        let stable_account_key = format!("sub:test:{}", bundle.account.display_name);
        let identity = QuotaHistoryIdentity::from_bundle(
            self.path.parent().unwrap_or_else(|| Path::new("/fixture/test-home")),
            Some(&stable_account_key),
            bundle,
            Some("codex"),
        );
        self.history_bundle_for_identity(identity.as_ref(), bundle, day_count, recent_count)
    }

    #[cfg(test)]
    fn rows_for_identity(
        &self,
        identity: Option<&QuotaHistoryIdentity>,
        bundle: &AccountQuotaBundle,
        age_seconds: f64,
    ) -> SqlResult<Vec<QuotaHistoryRow>> {
        let Some(identity) = identity else {
            return Ok(Vec::new());
        };
        let _database_guard = quota_history_database_guard();
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let filter_row = QuotaHistoryRow::from_bundle(identity, bundle, now_unix());
        rows_since_for_row(&connection, age_seconds, &filter_row)
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
    identity_version: Option<i64>,
    home_identity: Option<String>,
    stable_account_key: Option<String>,
    identity_plan_type: Option<String>,
    identity_limit_id: Option<String>,
}

impl QuotaHistoryRow {
    fn from_bundle(
        identity: &QuotaHistoryIdentity,
        bundle: &AccountQuotaBundle,
        created_at: f64,
    ) -> Self {
        let account_name =
            Some(bundle.account.display_name.clone()).filter(|value| !value.trim().is_empty());
        let limit_name = Some(identity.limit_id.clone());
        let plan_type = Some(identity.plan_type.clone());
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
            five_hour_used_percent: measured_used_percent(&bundle.quota.five_hour),
            five_hour_resets_at: measured_reset_timestamp(&bundle.quota.five_hour),
            seven_day_used_percent: measured_used_percent(&bundle.quota.seven_day),
            seven_day_resets_at: measured_reset_timestamp(&bundle.quota.seven_day),
            status: bundle.quota.pace_label.clone(),
            identity_version: Some(identity.version),
            home_identity: Some(identity.home_identity.clone()),
            stable_account_key: Some(identity.stable_account_key.clone()),
            identity_plan_type: Some(identity.plan_type.clone()),
            identity_limit_id: Some(identity.limit_id.clone()),
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

    fn stable_identity(&self) -> Option<QuotaHistoryIdentity> {
        let version = self.identity_version?;
        if version != QUOTA_HISTORY_IDENTITY_VERSION {
            return None;
        }
        let home_identity = nonempty_owned(self.home_identity.as_deref())?;
        let stable_account_key = nonempty_owned(self.stable_account_key.as_deref())?;
        let limit_id = canonical_stable_limit_name(self.identity_limit_id.as_deref())?;
        let plan_type =
            canonical_plan_type(self.identity_plan_type.as_deref(), Some(&limit_id))?;
        Some(QuotaHistoryIdentity {
            version,
            home_identity,
            stable_account_key,
            plan_type,
            limit_id,
        })
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
        return None;
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

fn history_bundle_from_rows(
    rows: Vec<QuotaHistoryRow>,
    recent_count: usize,
) -> QuotaHistoryBundle {
    QuotaHistoryBundle {
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

fn nonempty_owned(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn canonical_plan_type(plan_type: Option<&str>, _limit_name: Option<&str>) -> Option<String> {
    let value = plan_type?.trim();
    if value.is_empty() {
        return None;
    }
    let normalized = value.to_ascii_lowercase().replace([' ', '-', '_'], "");
    match normalized.as_str() {
        "plus" | "chatgptplus" => Some("Plus".into()),
        "pro" | "chatgptpro" => Some("Pro".into()),
        "team" | "teams" | "business" => Some("Team".into()),
        "enterprise" => Some("Enterprise".into()),
        "free" => Some("Free".into()),
        "unknown" | "null" | "none" | "unread" => None,
        _ if value.contains("待读取") || value.contains("未知") => None,
        _ => Some(value.to_string()),
    }
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

fn canonical_stable_limit_name(limit_name: Option<&str>) -> Option<String> {
    let limit_name = limit_name
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    canonical_limit_name(Some(limit_name))
}

fn is_codex_main_limit(limit_name: Option<&str>) -> bool {
    limit_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none_or(|value| value.eq_ignore_ascii_case("codex"))
}

fn percent_to_int(value: Option<f64>) -> Option<i32> {
    let value = value?;
    if !value.is_finite() {
        return None;
    }
    Some((value * 100.0).round().clamp(0.0, 100.0) as i32)
}

fn measured_used_percent(limit: &QuotaLimit) -> Option<i32> {
    (limit.availability == QuotaAvailability::Measured)
        .then(|| percent_to_int(limit.used_percent))
        .flatten()
}

fn measured_reset_timestamp(limit: &QuotaLimit) -> Option<f64> {
    (limit.availability == QuotaAvailability::Measured)
        .then_some(limit.resets_at_unix)
        .flatten()
        .map(|value| value as f64)
}

fn remaining_from_used(value: Option<i32>) -> Option<f64> {
    value.map(|used| (100 - used).clamp(0, 100) as f64 / 100.0)
}

fn now_unix() -> f64 {
    OffsetDateTime::now_utc().unix_timestamp() as f64
}

fn quota_history_database_guard() -> std::sync::MutexGuard<'static, ()> {
    QUOTA_HISTORY_DATABASE_GATE
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn database_path() -> Option<PathBuf> {
    app_paths::quota_history_database_path()
}

fn migrate_legacy_quota_history_if_needed(path: &Path) -> SqlResult<()> {
    let _database_guard = quota_history_database_guard();
    if path.exists() {
        return Ok(());
    }
    let Some(legacy_path) = app_paths::legacy_shared_quota_history_database_path() else {
        return Ok(());
    };
    if legacy_path == path || !legacy_path.exists() {
        return Ok(());
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let source = sqlite::open_read_only(&legacy_path, Duration::from_secs(3))?;
    let mut target = sqlite::open_wal(path, Duration::from_secs(3))?;
    {
        let backup = Backup::new(&source, &mut target)?;
        backup.run_to_completion(128, Duration::from_millis(5), None)?;
    }
    sqlite::checkpoint_wal_full(&target);
    Ok(())
}

#[cfg(test)]
#[path = "quota_history_tests.rs"]
mod quota_history_tests;
