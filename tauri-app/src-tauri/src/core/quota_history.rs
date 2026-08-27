use crate::core::app_paths;
use crate::core::sqlite;
use crate::core::time_series_timeline::LONG_RECENT_POINT_COUNT;
use crate::models::{
    AccountQuotaBundle, LocalDataWarning, QuotaAttributionIdentity, QuotaAvailability,
    QuotaHistoryDailyPoint, QuotaHistoryPoint, QuotaLimit, QuotaSnapshot,
};
#[cfg(test)]
use crate::models::RecentUsagePoint;
use rusqlite::backup::Backup;
use rusqlite::{Connection, Result as SqlResult};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use time::OffsetDateTime;

mod database;
mod series;

use database::{
    ensure_schema, insert_row, latest_trusted_row, rows_since_for_read_only_peer,
    rows_since_for_row,
};
#[cfg(test)]
use database::{recent_rows, rows_since};
use series::{make_daily_history, make_interval_history, make_recent_history};
#[cfg(test)]
use series::DailyQuotaHistory;

#[cfg(test)]
use series::format_date;
// Quota history is intentionally unbounded. The hourly heartbeat and
// cross-runtime merge keep this percentage-only history small without
// deleting older quota state.
const HEARTBEAT_SECONDS: f64 = 60.0 * 60.0;
const QUOTA_HISTORY_SOURCE: &str = "tauri";
const RESET_MATCH_GRACE_SECONDS: f64 = 2.0 * 60.0;
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

    pub(crate) fn attribution_identity(&self) -> QuotaAttributionIdentity {
        let mut hasher = Sha256::new();
        hasher.update(b"codex-token-bar/quota-attribution-scope/v1\0");
        update_length_prefixed_hash(&mut hasher, self.home_identity.as_bytes());
        update_length_prefixed_hash(&mut hasher, self.stable_account_key.as_bytes());
        update_length_prefixed_hash(&mut hasher, self.limit_id.as_bytes());
        let scope_key = hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();

        QuotaAttributionIdentity {
            scope_key: format!("sha256:{scope_key}"),
            plan: self.plan_type.clone(),
            limit: self.limit_id.clone(),
        }
    }
}

fn update_length_prefixed_hash(hasher: &mut Sha256, value: &[u8]) {
    hasher.update((value.len() as u64).to_le_bytes());
    hasher.update(value);
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
            recent_7d: make_interval_history(rows.clone(), 30 * 24, 60 * 60),
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
        let rows = self.history_rows_for_identity(
            &connection,
            identity,
            &filter_row,
            day_count.max(31) as f64 * 24.0 * 60.0 * 60.0,
        )?;
        Ok(history_bundle_from_rows(rows, recent_count))
    }

    fn history_rows_for_identity(
        &self,
        connection: &Connection,
        identity: &QuotaHistoryIdentity,
        filter_row: &QuotaHistoryRow,
        age_seconds: f64,
    ) -> SqlResult<Vec<QuotaHistoryRow>> {
        let local_rows = rows_since_for_row(connection, age_seconds, filter_row)?;
        let peer_rows = self.read_peer_rows_for_identity(identity, age_seconds);
        Ok(merge_history_rows(local_rows, peer_rows))
    }

    fn read_peer_rows_for_identity(
        &self,
        identity: &QuotaHistoryIdentity,
        age_seconds: f64,
    ) -> Vec<QuotaHistoryRow> {
        let Some(peer_path) = app_paths::legacy_shared_quota_history_database_path() else {
            return Vec::new();
        };
        if peer_path == self.path || !peer_path.exists() {
            return Vec::new();
        }

        let Ok(connection) = sqlite::open_read_only(&peer_path, Duration::from_millis(250)) else {
            return Vec::new();
        };
        rows_since_for_read_only_peer(&connection, age_seconds, identity).unwrap_or_default()
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

    #[cfg(test)]
    fn merged_rows_for_identity_for_test(
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
        self.history_rows_for_identity(&connection, identity, &filter_row, age_seconds)
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
    let current_used = current_used.clamp(0, 100);
    let Some(previous_used) = previous_used.map(|value| value.clamp(0, 100)) else {
        return Some(current_used);
    };
    if current_used >= previous_used
        || !same_observed_cycle(current_reset, previous_reset)
    {
        return Some(current_used);
    }
    if previous_used - current_used >= 20 {
        Some(current_used)
    } else {
        Some(previous_used)
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
        recent_7d: make_interval_history(rows.clone(), 30 * 24, 60 * 60),
        recent_30d: make_interval_history(rows, 30 * 4, 6 * 60 * 60),
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct HistoryRowMergeKey {
    created_at_bits: u64,
    stable_identity: Option<QuotaHistoryIdentity>,
    legacy_scope: Option<String>,
}

fn merge_history_rows(
    local_rows: Vec<QuotaHistoryRow>,
    peer_rows: Vec<QuotaHistoryRow>,
) -> Vec<QuotaHistoryRow> {
    let mut by_key = HashMap::<HistoryRowMergeKey, MergedHistoryRow>::new();

    // A source-qualified Tauri row outranks a Swift peer row. If both rows have
    // the same source (including an initial Swift-to-Tauri copy), the local
    // database wins; duplicate rows within one database use a deterministic
    // fingerprint tie-break. No values are synthesized during a conflict.
    for row in local_rows {
        let key = history_row_merge_key(&row);
        match by_key.get(&key) {
            Some(existing)
                if !prefer_history_row(&row, true, &existing.row, existing.is_local) =>
            {}
            _ => {
                by_key.insert(
                    key,
                    MergedHistoryRow {
                        row,
                        is_local: true,
                    },
                );
            }
        }
    }
    for row in peer_rows {
        let key = history_row_merge_key(&row);
        match by_key.get(&key) {
            Some(existing)
                if !prefer_history_row(&row, false, &existing.row, existing.is_local) =>
            {}
            _ => {
                by_key.insert(
                    key,
                    MergedHistoryRow {
                        row,
                        is_local: false,
                    },
                );
            }
        }
    }

    let mut rows = by_key
        .into_values()
        .map(|merged| merged.row)
        .collect::<Vec<_>>();
    rows.sort_by(|left, right| {
        left.created_at
            .partial_cmp(&right.created_at)
            .unwrap_or_else(|| left.created_at.to_bits().cmp(&right.created_at.to_bits()))
            .then_with(|| history_row_fingerprint(left).cmp(&history_row_fingerprint(right)))
    });
    rows
}

struct MergedHistoryRow {
    row: QuotaHistoryRow,
    is_local: bool,
}

fn history_row_merge_key(row: &QuotaHistoryRow) -> HistoryRowMergeKey {
    let stable_identity = row.stable_identity();
    let legacy_scope = if stable_identity.is_none() {
        Some(
            [
                row.history_match_key(),
                row.match_plan_type().unwrap_or_default(),
                row.match_limit_name().unwrap_or_default(),
            ]
            .join("\u{1f}"),
        )
    } else {
        None
    };
    HistoryRowMergeKey {
        created_at_bits: row.created_at.to_bits(),
        stable_identity,
        legacy_scope,
    }
}

fn prefer_history_row(
    candidate: &QuotaHistoryRow,
    candidate_is_local: bool,
    existing: &QuotaHistoryRow,
    existing_is_local: bool,
) -> bool {
    source_rank(candidate)
        .cmp(&source_rank(existing))
        .then_with(|| candidate_is_local.cmp(&existing_is_local))
        .then_with(|| history_row_fingerprint(candidate).cmp(&history_row_fingerprint(existing)))
        == std::cmp::Ordering::Greater
}

fn source_rank(row: &QuotaHistoryRow) -> u8 {
    match row.source.as_deref().map(str::trim) {
        Some(source) if source.eq_ignore_ascii_case("tauri") => 2,
        Some(source) if source.eq_ignore_ascii_case("swift") => 1,
        _ => 0,
    }
}

fn history_row_fingerprint(row: &QuotaHistoryRow) -> String {
    [
        row.account_key.clone(),
        row.plan_type.clone().unwrap_or_default(),
        row.limit_name.clone().unwrap_or_default(),
        row.account_name.clone().unwrap_or_default(),
        row.source.clone().unwrap_or_default(),
        row.five_hour_used_percent
            .map(|value| value.to_string())
            .unwrap_or_default(),
        row.five_hour_resets_at
            .map(|value| value.to_bits().to_string())
            .unwrap_or_default(),
        row.seven_day_used_percent
            .map(|value| value.to_string())
            .unwrap_or_default(),
        row.seven_day_resets_at
            .map(|value| value.to_bits().to_string())
            .unwrap_or_default(),
        row.status.clone(),
        row.identity_version
            .map(|value| value.to_string())
            .unwrap_or_default(),
        row.home_identity.clone().unwrap_or_default(),
        row.stable_account_key.clone().unwrap_or_default(),
        row.identity_plan_type.clone().unwrap_or_default(),
        row.identity_limit_id.clone().unwrap_or_default(),
    ]
    .join("\u{1f}")
}

fn same_reset_window(left: f64, right: f64) -> bool {
    (left - right).abs() <= RESET_MATCH_GRACE_SECONDS
}

fn same_observed_cycle(left: Option<f64>, right: Option<f64>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => same_reset_window(left, right),
        (None, None) => true,
        _ => false,
    }
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
    // Reset timestamps are sampled countdowns and can wobble by a few
    // seconds (or a scheduler tick) while the quota cycle is unchanged.
    // Treat the existing cycle grace as equal for write suppression, but keep
    // every actual usage change as its own timestamped row above.
    if !same_observed_cycle(row.five_hour_resets_at, latest.five_hour_resets_at) {
        return true;
    }
    if !same_observed_cycle(row.seven_day_resets_at, latest.seven_day_resets_at) {
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
