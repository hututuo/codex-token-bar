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
pub(crate) mod cycles;
mod protection;
#[cfg(test)]
mod protection_integration_tests;
mod series;

use database::{
    ensure_schema, insert_row, latest_trusted_row, maintain_if_due,
    rows_since_for_read_only_peer,
};
#[cfg(test)]
use database::{maintenance_metadata, recent_rows, rows_since, rows_since_for_row};
use series::{make_daily_history, make_interval_history, make_recent_history};
#[cfg(test)]
use series::DailyQuotaHistory;

#[cfg(test)]
use series::format_date;
const QUOTA_HISTORY_SOURCE: &str = "tauri";
/// A reset countdown may move by a few seconds while it still describes the
/// same observation.  This is deliberately much smaller than the old 120s
/// cycle heuristic; cycle identity is now carried by `cycle_generation`.
pub(crate) const RESET_MATCH_GRACE_SECONDS: f64 = 5.0;
pub(crate) const TIMESTAMP_COMPARISON_TOLERANCE_SECONDS: f64 = 0.000_001;
pub(crate) const QUOTA_HISTORY_POLICY_VERSION: i64 = 3;
pub(crate) const QUOTA_HISTORY_MAINTENANCE_INTERVAL_SECONDS: f64 = 24.0 * 60.0 * 60.0;
pub(crate) const QUOTA_HISTORY_IDENTITY_VERSION: i64 = 1;
static QUOTA_HISTORY_DATABASE_GATE: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum QuotaWindow {
    FiveHour,
    SevenDay,
}

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

pub(crate) fn quota_cycle_id_for_identity(
    identity: &QuotaHistoryIdentity,
    window: &str,
    generation: Option<i64>,
) -> Option<String> {
    generation.map(|generation| {
        // Cycle ids may cross the IPC boundary.  Keep the stable identity
        // scope opaque: the attribution identity is already a one-way hash
        // over home/account/limit components and never exposes those raw
        // values in a serialized id.
        let scope = identity.attribution_identity().scope_key;
        format!("quota-cycle-v1|{scope}|{window}|{generation}")
    })
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
        let Ok(observed_at) = OffsetDateTime::parse(&bundle.updated_at, &time::format_description::well_known::Rfc3339) else {
            // A response with no observation timestamp cannot provide a
            // durable freshness identity. Never substitute write time.
            return Ok(false);
        };
        self.record_for_identity_at(identity, bundle,
            observed_at.unix_timestamp_nanos() as f64 / 1_000_000_000.0)
    }

    fn record_for_identity_at(
        &self,
        identity: Option<&QuotaHistoryIdentity>,
        bundle: &AccountQuotaBundle,
        now: f64,
    ) -> SqlResult<bool> {
        let Some(identity) = identity else {
            return Ok(false);
        };
        let _database_guard = quota_history_database_guard();
        let mut connection = self.open()?;
        ensure_schema(&connection)?;
        maintain_if_due(&mut connection, now)?;

        if !now.is_finite() || !quota_available(&bundle.quota) { return Ok(false); }
        let row = QuotaHistoryRow::from_bundle(identity, bundle, now);
        let latest = latest_trusted_row(&connection, &row)?;
        if latest.as_ref().is_some_and(|latest| now <= latest.created_at + TIMESTAMP_COMPARISON_TOLERANCE_SECONDS) {
            // A cached response replay or explicitly older observation does
            // not become fresh evidence merely because it is written again.
            return Ok(false);
        }
        let history = self.history_rows_for_identity(&connection, identity, &row, f64::MAX)?;
        if history.last().is_some_and(|latest| now <= latest.created_at + TIMESTAMP_COMPARISON_TOLERANCE_SECONDS) { return Ok(false); }
        let mut input = history.clone();
        input.push(row.clone());
        let planned = canonicalized_cycle_rows(input, Some(identity)).pop().unwrap();
        // Every distinct successful observation is retained. This persists
        // the freshness watermark and confirmation samples together, so a
        // restart cannot turn a cached/older response into new evidence.
        insert_row(&connection, &planned)?;
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
        let mut connection = self.open()?;
        ensure_schema(&connection)?;
        maintain_if_due(&mut connection, now_unix())?;
        let rows = recent_rows(&connection)?;
        Ok(match interval_seconds {
            300 => make_recent_history(rows, count.max(1)),
            _ => make_interval_history(rows, count.max(1), interval_seconds),
        })
    }

    #[cfg(test)]
    fn daily_history(&self, day_count: usize) -> SqlResult<HashMap<String, DailyQuotaHistory>> {
        let mut connection = self.open()?;
        ensure_schema(&connection)?;
        maintain_if_due(&mut connection, now_unix())?;
        let rows = rows_since(&connection, day_count.max(1) as f64 * 24.0 * 60.0 * 60.0)?;
        Ok(make_daily_history(rows))
    }

    #[cfg(test)]
    fn history_bundle(
        &self,
        day_count: usize,
        recent_count: usize,
    ) -> SqlResult<QuotaHistoryBundle> {
        let mut connection = self.open()?;
        ensure_schema(&connection)?;
        maintain_if_due(&mut connection, now_unix())?;
        let rows = rows_since(
            &connection,
            day_count.max(31) as f64 * 24.0 * 60.0 * 60.0,
        )?;
        Ok(history_bundle_from_rows(rows, recent_count, None))
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
        let mut connection = self.open()?;
        ensure_schema(&connection)?;
        maintain_if_due(&mut connection, now_unix())?;
        let filter_row = QuotaHistoryRow::from_bundle(identity, bundle, now_unix());
        let rows = self.history_rows_for_identity(
            &connection,
            identity,
            &filter_row,
            day_count.max(31) as f64 * 24.0 * 60.0 * 60.0,
        )?;
        Ok(history_bundle_from_rows(rows, recent_count, Some(identity)))
    }

    fn history_rows_for_identity(
        &self,
        connection: &Connection,
        identity: &QuotaHistoryIdentity,
        filter_row: &QuotaHistoryRow,
        _age_seconds: f64,
    ) -> SqlResult<Vec<QuotaHistoryRow>> {
        // Replay the complete retained identity timeline before choosing chart
        // ranges: a prior accepted baseline can precede the visible window.
        let local_rows = database::all_rows_for_row(connection, filter_row)?;
        let peer_rows = self.read_peer_rows_for_identity(identity, f64::MAX);
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
        let mut connection = self.open()?;
        ensure_schema(&connection)?;
        maintain_if_due(&mut connection, now_unix())?;
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
        let mut connection = self.open()?;
        ensure_schema(&connection)?;
        maintain_if_due(&mut connection, now_unix())?;
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
    five_hour_cycle_generation: Option<i64>,
    five_hour_reset_anchor: Option<i64>,
    seven_day_used_percent: Option<i32>,
    seven_day_resets_at: Option<f64>,
    seven_day_cycle_generation: Option<i64>,
    seven_day_reset_anchor: Option<i64>,
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
            five_hour_cycle_generation: None,
            five_hour_reset_anchor: None,
            seven_day_used_percent: measured_used_percent(&bundle.quota.seven_day),
            seven_day_resets_at: measured_reset_timestamp(&bundle.quota.seven_day),
            seven_day_cycle_generation: None,
            seven_day_reset_anchor: None,
            status: bundle.quota.pace_label.clone(),
            identity_version: Some(identity.version),
            home_identity: Some(identity.home_identity.clone()),
            stable_account_key: Some(identity.stable_account_key.clone()),
            identity_plan_type: Some(identity.plan_type.clone()),
            identity_limit_id: Some(identity.limit_id.clone()),
        }
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

/// Historical candidate state is reconstructed from durable observations.
/// Clearing transient network state must not erase persisted evidence.
pub(crate) fn reset_stability_tracking() {}

#[cfg(test)]
fn normalized_used_percent(
    current_used: Option<i32>,
    current_reset: Option<f64>,
    previous_used: Option<i32>,
    previous_reset: Option<f64>,
) -> Option<i32> {
    normalized_used_percent_with_cycle(
        current_used,
        current_reset,
        None,
        previous_used,
        previous_reset,
        None,
    )
}

#[cfg(test)]
fn normalized_used_percent_with_cycle(
    current_used: Option<i32>,
    current_reset: Option<f64>,
    current_generation: Option<i64>,
    previous_used: Option<i32>,
    previous_reset: Option<f64>,
    previous_generation: Option<i64>,
) -> Option<i32> {
    let Some(current_used) = current_used else {
        return None;
    };
    if !(0..=100).contains(&current_used) { return None; }
    let Some(previous_used) = previous_used.filter(|value| (0..=100).contains(value)) else {
        return Some(current_used);
    };
    if current_used >= previous_used {
        return Some(current_used);
    }
    if !same_cycle_for_window(
        Some(current_used),
        current_reset,
        current_generation,
        Some(previous_used),
        previous_reset,
        previous_generation,
    ) {
        return Some(current_used);
    }
    // Pairwise compatibility helper cannot confirm a multi-sample revision.
    Some(previous_used)
}

fn history_bundle_from_rows(
    rows: Vec<QuotaHistoryRow>,
    recent_count: usize,
    fallback_identity: Option<&QuotaHistoryIdentity>,
) -> QuotaHistoryBundle {
    let mut rows = rows;
    if let Some(identity) = fallback_identity {
        for row in &mut rows {
            if row.stable_identity().is_none() {
                row.identity_version = Some(identity.version);
                row.home_identity = Some(identity.home_identity.clone());
                row.stable_account_key = Some(identity.stable_account_key.clone());
                row.identity_plan_type = Some(identity.plan_type.clone());
                row.identity_limit_id = Some(identity.limit_id.clone());
            }
        }
    }
    let now = now_unix();
    QuotaHistoryBundle {
        daily: series::make_daily_history_at(rows.clone(), now)
            .into_iter()
            .map(|(date, history)| QuotaHistoryDailyPoint {
                date,
                five_hour_remaining_percent: history.five_hour_remaining_percent,
                seven_day_remaining_percent: history.seven_day_remaining_percent,
            })
            .collect(),
        recent_24h: series::make_interval_history_at(rows.clone(), recent_count.max(1), 300, now),
        recent_7d: series::make_interval_history_at(rows.clone(), 30 * 24, 60 * 60, now),
        recent_30d: series::make_interval_history_at(rows, 30 * 4, 6 * 60 * 60, now),
    }
}

#[derive(Default)]
struct CanonicalCycleState {
    seen: bool,
    generation: i64,
    accepted_reset: Option<f64>,
}

fn canonicalized_cycle_rows(rows: Vec<QuotaHistoryRow>, fallback_identity: Option<&QuotaHistoryIdentity>) -> Vec<QuotaHistoryRow> {
    replay_cycle_rows(rows, fallback_identity, true)
}

fn replay_cycle_rows(
    mut rows: Vec<QuotaHistoryRow>,
    fallback_identity: Option<&QuotaHistoryIdentity>,
    preserve_latest_target: bool,
) -> Vec<QuotaHistoryRow> {
    rows.sort_by(|left, right| {
        left.created_at
            .partial_cmp(&right.created_at)
            .unwrap_or_else(|| left.created_at.to_bits().cmp(&right.created_at.to_bits()))
            .then_with(|| history_row_fingerprint(left).cmp(&history_row_fingerprint(right)))
    });
    // Raw writes retain the latest durable offset. Filtered reads start from
    // the earliest retained native target so a removed reset cannot leave a
    // phantom generation behind. Both retain offsets across history retention.
    let mut target_order: Vec<usize> = (0..rows.len()).collect();
    if preserve_latest_target { target_order.reverse(); }
    let five_generation_target = target_order.iter().find_map(|&index| {
        let row = &rows[index];
        is_tauri_source(row.source.as_deref())
            .then_some(row.five_hour_cycle_generation)
            .flatten()
            .map(|generation| (index, generation))
    });
    let seven_generation_target = target_order.iter().find_map(|&index| {
        let row = &rows[index];
        is_tauri_source(row.source.as_deref())
            .then_some(row.seven_day_cycle_generation)
            .flatten()
            .map(|generation| (index, generation))
    });

    let mut five = CanonicalCycleState::default();
    let mut seven = CanonicalCycleState::default();
    for row in &mut rows {
        if row.stable_identity().is_none() {
            if let Some(identity) = fallback_identity {
                // `history_rows_for_identity` only supplies legacy rows after
                // its durable bridge claim has proved them unambiguous.  Bind
                // that identity in memory so the read layer can emit the same
                // opaque cycle ids without rewriting the peer/local row.
                row.identity_version = Some(identity.version);
                row.home_identity = Some(identity.home_identity.clone());
                row.stable_account_key = Some(identity.stable_account_key.clone());
                row.identity_plan_type = Some(identity.plan_type.clone());
                row.identity_limit_id = Some(identity.limit_id.clone());
            }
        }

        let (generation, anchor) = canonical_window_metadata(
            row.five_hour_used_percent,
            row.five_hour_resets_at,
            row.five_hour_reset_anchor,
            &mut five,
            protection::HistoryPolicy::FIVE_HOUR,
        );
        row.five_hour_cycle_generation = generation;
        row.five_hour_reset_anchor = anchor;

        let (generation, anchor) = canonical_window_metadata(
            row.seven_day_used_percent,
            row.seven_day_resets_at,
            row.seven_day_reset_anchor,
            &mut seven,
            protection::HistoryPolicy::SEVEN_DAY,
        );
        row.seven_day_cycle_generation = generation;
        row.seven_day_reset_anchor = anchor;
    }
    apply_generation_offset(
        &mut rows,
        five_generation_target,
        QuotaWindow::FiveHour,
    );
    apply_generation_offset(
        &mut rows,
        seven_generation_target,
        QuotaWindow::SevenDay,
    );
    rows
}

fn is_tauri_source(source: Option<&str>) -> bool {
    source
        .map(str::trim)
        .is_some_and(|source| source.eq_ignore_ascii_case(QUOTA_HISTORY_SOURCE))
}

fn apply_generation_offset(
    rows: &mut [QuotaHistoryRow],
    target: Option<(usize, i64)>,
    window: QuotaWindow,
) {
    let Some((target_index, persisted_generation)) = target else {
        return;
    };
    let relative_generation = match window {
        QuotaWindow::FiveHour => rows[target_index].five_hour_cycle_generation,
        QuotaWindow::SevenDay => rows[target_index].seven_day_cycle_generation,
    };
    let Some(relative_generation) = relative_generation else {
        return;
    };
    let offset = persisted_generation.saturating_sub(relative_generation);
    for row in rows {
        let generation = match window {
            QuotaWindow::FiveHour => &mut row.five_hour_cycle_generation,
            QuotaWindow::SevenDay => &mut row.seven_day_cycle_generation,
        };
        if let Some(value) = generation.as_mut() {
            *value = value.saturating_add(offset);
        }
    }
}

fn canonical_window_metadata(
    used_percent: Option<i32>,
    reset: Option<f64>,
    _persisted_anchor: Option<i64>,
    state: &mut CanonicalCycleState,
    policy: protection::HistoryPolicy,
) -> (Option<i64>, Option<i64>) {
    if !used_percent.is_some_and(|value| (0..=100).contains(&value)) {
        return (None, Some(0));
    }
    let reset = reset.filter(|value| value.is_finite());
    let mut anchor = false;
    if !state.seen {
        state.seen = true;
        anchor = true;
    } else if used_percent.is_some_and(|value| (0..=policy.maximum_new_cycle_used_percent).contains(&value))
        && reset.zip(state.accepted_reset).is_some_and(|(current, accepted)| {
            (current - accepted)
                > policy.new_cycle_reset_delta
                    + TIMESTAMP_COMPARISON_TOLERANCE_SECONDS
        })
    {
        state.generation = state.generation.saturating_add(1);
        anchor = true;
    }

    if anchor {
        if let Some(reset) = reset {
            state.accepted_reset = Some(reset);
        }
    } else if state.accepted_reset.is_none() {
        state.accepted_reset = reset;
    }
    (Some(state.generation), Some(i64::from(anchor)))
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
        row.five_hour_cycle_generation
            .map(|value| value.to_string())
            .unwrap_or_default(),
        row.five_hour_reset_anchor
            .map(|value| value.to_string())
            .unwrap_or_default(),
        row.seven_day_used_percent
            .map(|value| value.to_string())
            .unwrap_or_default(),
        row.seven_day_resets_at
            .map(|value| value.to_bits().to_string())
            .unwrap_or_default(),
        row.seven_day_cycle_generation
            .map(|value| value.to_string())
            .unwrap_or_default(),
        row.seven_day_reset_anchor
            .map(|value| value.to_string())
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
    (left - right).abs()
        <= RESET_MATCH_GRACE_SECONDS + TIMESTAMP_COMPARISON_TOLERANCE_SECONDS
}

fn same_observed_cycle(left: Option<f64>, right: Option<f64>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => same_reset_window(left, right),
        (None, None) => true,
        _ => false,
    }
}

#[cfg(test)]
fn same_cycle_for_window(current_used: Option<i32>, current_reset: Option<f64>, current_generation: Option<i64>, previous_used: Option<i32>, previous_reset: Option<f64>, previous_generation: Option<i64>) -> bool {
    same_cycle_for_window_with_policy(current_used, current_reset, current_generation, previous_used, previous_reset, previous_generation, protection::HistoryPolicy::FIVE_HOUR)
}

fn same_cycle_for_window_with_policy(
    current_used: Option<i32>,
    current_reset: Option<f64>,
    current_generation: Option<i64>,
    _previous_used: Option<i32>,
    previous_reset: Option<f64>,
    previous_generation: Option<i64>,
    policy: protection::HistoryPolicy,
) -> bool {
    if let (Some(current_generation), Some(previous_generation)) =
        (current_generation, previous_generation)
    {
        return current_generation == previous_generation;
    }
    match (current_reset, previous_reset) {
        (Some(current_reset), Some(previous_reset)) => {
            !(current_used.is_some_and(|value| (0..=policy.maximum_new_cycle_used_percent).contains(&value))
                && (current_reset - previous_reset)
                    > policy.new_cycle_reset_delta
                        + TIMESTAMP_COMPARISON_TOLERANCE_SECONDS)
        }
        (None, None) => true,
        _ => false,
    }
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
    (0.0..=1.0).contains(&value).then(|| (value * 100.0).round() as i32)
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
    OffsetDateTime::now_utc().unix_timestamp_nanos() as f64 / 1_000_000_000.0
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
