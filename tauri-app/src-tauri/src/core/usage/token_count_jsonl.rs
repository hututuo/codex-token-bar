use super::cache_lifecycle;
use crate::core::app_paths;
use crate::models::{
    AccountInfo, DashboardSnapshot, LocalDataWarning, QuotaLimit, QuotaSnapshot, ResetCreditSummary,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration as StdDuration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

#[cfg(test)]
mod aggregates;
#[cfg(test)]
mod cache_version_tests;
mod exact_usage_index;
mod session_files;
mod session_parser;
#[cfg(test)]
mod tests;

#[cfg(test)]
use aggregates::{activity_days_at, stats_at};
use exact_usage_index::ExactUsageIndex;

static DASHBOARD_AGGREGATE_CACHE: OnceLock<Mutex<DashboardAggregateCacheState>> = OnceLock::new();
static DASHBOARD_BUILD_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static SESSION_CATALOG_BUILD_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static USAGE_SUMMARY_REFRESH_IN_FLIGHT: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
static USAGE_SUMMARY_SOURCE_SCAN_CACHE: OnceLock<Mutex<HashMap<PathBuf, (Instant, bool)>>> =
    OnceLock::new();
static USAGE_SUMMARY_CACHE: OnceLock<Mutex<Option<CachedUsageSummary>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_AGGREGATE_BUILD_COUNT: OnceLock<Mutex<HashMap<PathBuf, usize>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_SCAN_SIGNATURE_COUNT: AtomicUsize = AtomicUsize::new(0);
const DASHBOARD_AGGREGATE_CACHE_VERSION: u32 = 16;
const AGGREGATE_CHECKPOINT_INTERVAL: StdDuration = StdDuration::from_secs(15 * 60);
const USAGE_SUMMARY_SOURCE_SCAN_REUSE_INTERVAL: StdDuration = StdDuration::from_millis(250);
const USAGE_SUMMARY_SOURCE_SCAN_STATE_RETENTION: StdDuration = StdDuration::from_secs(5 * 60);

#[derive(Clone, Debug)]
pub(crate) struct IndexedSessionMetadata {
    pub(crate) thread_id: String,
    pub(crate) cwd: String,
    pub(crate) source: String,
    pub(crate) session_id: Option<String>,
    pub(crate) forked_from_id: Option<String>,
    pub(crate) parent_thread_id: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct IndexedSessionCatalogEntry {
    pub(crate) path: PathBuf,
    pub(crate) archived: bool,
    pub(crate) metadata: IndexedSessionMetadata,
    pub(crate) size: u64,
    pub(crate) modified_at: Option<i64>,
    pub(crate) created_at: Option<i64>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct IndexedSessionCatalogSnapshot {
    pub(crate) entries: Vec<IndexedSessionCatalogEntry>,
    pub(crate) warnings: Vec<String>,
}

struct UsageSummaryRefreshOwner {
    key: PathBuf,
}

impl Drop for UsageSummaryRefreshOwner {
    fn drop(&mut self) {
        let Some(in_flight) = USAGE_SUMMARY_REFRESH_IN_FLIGHT.get() else {
            return;
        };
        let mut guard = in_flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.remove(&self.key);
    }
}

pub(crate) fn session_catalog_snapshot<F>(
    codex_home: &Path,
    parser: F,
) -> Result<IndexedSessionCatalogSnapshot, String>
where
    F: FnMut(&[u8]) -> Result<IndexedSessionMetadata, String>,
{
    let build_gate = SESSION_CATALOG_BUILD_GATE.get_or_init(|| Mutex::new(()));
    let _build_guard = build_gate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut index = ExactUsageIndex::open(codex_home)?;
    match index.refresh_session_catalog(codex_home, parser) {
        Ok(()) => index.session_catalog_snapshot(),
        Err(error) => {
            let mut snapshot = index.session_catalog_snapshot()?;
            snapshot.warnings.push(format!(
                "会话目录增量索引刷新失败，继续使用上一份完整目录：{error}"
            ));
            Ok(snapshot)
        }
    }
}

#[cfg(test)]
pub(crate) fn fail_next_session_catalog_publish_for_testing() {
    exact_usage_index::fail_next_session_catalog_publish_for_testing();
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsageSummary {
    pub total_tokens: u64,
    pub today_tokens: u64,
    pub today_requests: u32,
}

#[cfg(test)]
#[derive(Clone, Debug)]
struct TokenEvent {
    timestamp: OffsetDateTime,
    session_id: String,
    tokens: u64,
    input_tokens: u64,
    cached_input_tokens: u64,
    output_tokens: u64,
    user_prompt: String,
    assistant_response: String,
}

pub fn dashboard_snapshot(codex_home: &Path) -> Result<DashboardSnapshot, String> {
    let build_gate = DASHBOARD_BUILD_GATE.get_or_init(|| Mutex::new(()));
    let _build_guard = build_gate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut warnings = Vec::new();
    let mut index = ExactUsageIndex::open(codex_home)?;
    let revision = index.sync(codex_home, &mut warnings)?;
    let signature = dashboard_index_signature(codex_home, revision);
    if let Some(mut snapshot) = cached_dashboard_snapshot(&signature) {
        let _ = cache_lifecycle::mark_usage_cache_ready_after_success();
        merge_usage_cache_marker_warning(&mut snapshot);
        return Ok(snapshot_with_generated_at(snapshot));
    }
    if index.is_empty()? {
        return Err(no_token_events_error(&warnings));
    }

    record_dashboard_aggregate_build_for_testing(codex_home);
    let now_utc = OffsetDateTime::now_utc();
    let local_offset = crate::core::localtime::local_offset();
    let data = index.dashboard_data(codex_home, now_utc, local_offset, &mut warnings)?;
    let generated_at = now_utc
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());

    let mut snapshot = DashboardSnapshot {
        generated_at,
        account: AccountInfo {
            display_name: "账户待读取".into(),
            plan_label: "计划待读取".into(),
        },
        stats: data.stats,
        quota: placeholder_quota(),
        activity_days: data.activity_days,
        recent_usage_24h: data.recent_usage_24h,
        recent_usage_7d: data.recent_usage_7d,
        recent_usage_30d: data.recent_usage_30d,
        cache_hit_ranking: data.cache_hit_ranking,
        cache_usage: data.cache_usage,
        warnings,
        diagnostics: Vec::new(),
    };
    if let Some(warning) =
        store_dashboard_aggregate(signature, Some(snapshot.clone()), data.summary)
    {
        snapshot.warnings.push(warning);
    }
    let _ = cache_lifecycle::mark_usage_cache_ready_after_success();
    merge_usage_cache_marker_warning(&mut snapshot);
    Ok(snapshot)
}

fn merge_usage_cache_marker_warning(snapshot: &mut DashboardSnapshot) {
    if let Some(warning) = cache_lifecycle::usage_cache_persistence_warning() {
        if !snapshot
            .warnings
            .iter()
            .any(|existing| existing.source == warning.source)
        {
            snapshot.warnings.push(warning);
        }
    }
}

#[cfg(test)]
fn activity_days_and_stats_at(
    events: &[TokenEvent],
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> (
    Vec<crate::models::ActivityDay>,
    crate::models::DashboardStats,
) {
    let days = activity_days_at(events, now_utc, local_offset);
    let stats = stats_at(events, &days, now_utc.to_offset(local_offset).date());
    (days, stats)
}

fn usage_summary(codex_home: &Path) -> Result<TokenUsageSummary, String> {
    let build_gate = DASHBOARD_BUILD_GATE.get_or_init(|| Mutex::new(()));
    let _build_guard = build_gate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut warnings = Vec::new();
    let mut index = ExactUsageIndex::open(codex_home)?;
    let revision = index.sync(codex_home, &mut warnings)?;
    let signature = dashboard_index_signature(codex_home, revision);
    if let Some(summary) = cached_usage_summary(&signature) {
        return Ok(summary);
    }
    if index.is_empty()? {
        return Err(no_token_events_error(&warnings));
    }

    let local_offset = crate::core::localtime::local_offset();
    let summary = index.summary(OffsetDateTime::now_utc(), local_offset)?;
    store_usage_summary(signature, summary.clone());

    Ok(summary)
}

pub fn dashboard_usage_summary(codex_home: &Path) -> Result<TokenUsageSummary, String> {
    usage_summary(codex_home)
}

pub fn usage_summary_snapshot(codex_home: &Path) -> Result<TokenUsageSummary, String> {
    let mut index = ExactUsageIndex::open(codex_home)?;
    let signature = dashboard_index_signature(codex_home, index.revision()?);
    let mut warnings = Vec::new();
    if usage_summary_sources_changed(&mut index, codex_home, &mut warnings)? {
        schedule_usage_summary_refresh(codex_home);
    }
    if let Some(summary) = cached_usage_summary(&signature) {
        return Ok(summary);
    }
    if let Some(cached) = cached_dashboard_aggregate(&signature) {
        return Ok(cached.summary);
    }

    let local_offset = crate::core::localtime::local_offset();
    let last_trusted = if index.is_empty()? {
        None
    } else {
        index.summary(OffsetDateTime::now_utc(), local_offset).ok()
    };
    if let Some(summary) = last_trusted.as_ref() {
        store_usage_summary_cache(signature, summary.clone());
    }
    last_trusted.ok_or_else(|| "精确 token summary 尚未就绪，正在后台初始化".into())
}

fn usage_summary_sources_changed(
    index: &mut ExactUsageIndex,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<bool, String> {
    let cache =
        USAGE_SUMMARY_SOURCE_SCAN_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut cache = cache
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let now = Instant::now();
    cache.retain(|_, (scanned_at, _)| {
        now.duration_since(*scanned_at) < USAGE_SUMMARY_SOURCE_SCAN_STATE_RETENTION
    });
    if let Some((scanned_at, changed)) = cache.get(codex_home) {
        if now.duration_since(*scanned_at) < USAGE_SUMMARY_SOURCE_SCAN_REUSE_INTERVAL {
            return Ok(*changed);
        }
    }

    let changed = index.sources_changed(codex_home, warnings)?;
    cache.insert(codex_home.to_path_buf(), (Instant::now(), changed));
    Ok(changed)
}

fn mark_usage_summary_sources_synced(codex_home: &Path) {
    let cache =
        USAGE_SUMMARY_SOURCE_SCAN_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut cache) = cache.lock() {
        cache.insert(codex_home.to_path_buf(), (Instant::now(), false));
    }
}

pub(crate) fn cached_dashboard_usage_summary(codex_home: &Path) -> Option<TokenUsageSummary> {
    let local_offset = crate::core::localtime::local_offset();
    cached_dashboard_usage_summary_at(codex_home, OffsetDateTime::now_utc(), local_offset).or_else(
        || {
            let index = ExactUsageIndex::open(codex_home).ok()?;
            if index.is_empty().ok()? {
                return None;
            }
            index.summary(OffsetDateTime::now_utc(), local_offset).ok()
        },
    )
}

pub(crate) fn cached_dashboard_snapshot_for_startup(
    codex_home: &Path,
) -> Option<DashboardSnapshot> {
    let index = ExactUsageIndex::open(codex_home).ok()?;
    let signature = dashboard_index_signature(codex_home, index.revision().ok()?);
    cached_dashboard_startup_snapshot(&signature).map(snapshot_with_generated_at)
}

#[cfg(test)]
fn usage_summary_from_events(events: &[TokenEvent], local_offset: UtcOffset) -> TokenUsageSummary {
    usage_summary_from_events_at(events, OffsetDateTime::now_utc(), local_offset)
}

#[cfg(test)]
fn usage_summary_from_events_at(
    events: &[TokenEvent],
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> TokenUsageSummary {
    let today = now_utc.to_offset(local_offset).date();
    let mut summary = TokenUsageSummary::default();

    for event in events {
        summary.total_tokens = summary.total_tokens.saturating_add(event.tokens);
        if event.timestamp.to_offset(local_offset).date() == today {
            summary.today_tokens = summary.today_tokens.saturating_add(event.tokens);
            summary.today_requests = summary.today_requests.saturating_add(1);
        }
    }

    summary
}

fn schedule_usage_summary_refresh(codex_home: &Path) {
    let key = codex_home.to_path_buf();
    let in_flight = USAGE_SUMMARY_REFRESH_IN_FLIGHT.get_or_init(|| Mutex::new(HashSet::new()));
    let mut guard = in_flight
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if !guard.insert(key.clone()) {
        return;
    }
    drop(guard);
    let owner = UsageSummaryRefreshOwner { key: key.clone() };

    let _ = std::thread::Builder::new()
        .name("codex-usage-summary".into())
        .spawn(move || {
            let _owner = owner;
            if usage_summary(&key).is_ok() {
                mark_usage_summary_sources_synced(&key);
            }
        });
}

fn no_token_events_error(warnings: &[LocalDataWarning]) -> String {
    if warnings.is_empty() {
        return "No token_count events found".into();
    }
    let details = warnings
        .iter()
        .map(|warning| format!("{}: {}", warning.source, warning.message))
        .collect::<Vec<_>>()
        .join("；");
    format!("No token_count events found；{details}")
}

fn placeholder_quota() -> QuotaSnapshot {
    QuotaSnapshot {
        five_hour: QuotaLimit {
            label: "5h".into(),
            availability: crate::models::QuotaAvailability::Unavailable,
            remaining_percent: None,
            used_percent: None,
            resets_at: "待读取".into(),
            resets_at_unix: None,
        },
        seven_day: QuotaLimit {
            label: "7d".into(),
            availability: crate::models::QuotaAvailability::Unavailable,
            remaining_percent: None,
            used_percent: None,
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

#[derive(Clone, Debug, Deserialize, Serialize)]
struct CachedDashboardAggregate {
    signature: DashboardScanSignature,
    snapshot: Option<DashboardSnapshot>,
    summary: TokenUsageSummary,
    snapshot_complete: bool,
}

#[derive(Default)]
struct DashboardAggregateCacheState {
    persistent_loaded: bool,
    aggregate: Option<CachedDashboardAggregate>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DashboardUsageScope {
    codex_home: PathBuf,
    local_date: String,
    utc_offset_seconds: i32,
}

#[derive(Clone, Debug)]
struct CachedUsageSummary {
    signature: DashboardScanSignature,
    summary: TokenUsageSummary,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct DashboardScanSignature {
    codex_home: PathBuf,
    local_date: String,
    utc_offset_seconds: i32,
    #[serde(default)]
    index_revision: u64,
}

fn dashboard_index_signature(codex_home: &Path, index_revision: u64) -> DashboardScanSignature {
    let local_offset = crate::core::localtime::local_offset();
    let now_utc = OffsetDateTime::now_utc();
    DashboardScanSignature {
        codex_home: codex_home.to_path_buf(),
        local_date: local_date_string(now_utc.to_offset(local_offset)),
        utc_offset_seconds: local_offset.whole_seconds(),
        index_revision,
    }
}

fn dashboard_usage_scope_at(
    codex_home: &Path,
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> DashboardUsageScope {
    DashboardUsageScope {
        codex_home: codex_home.to_path_buf(),
        local_date: local_date_string(now_utc.to_offset(local_offset)),
        utc_offset_seconds: local_offset.whole_seconds(),
    }
}

fn cached_dashboard_usage_summary_at(
    codex_home: &Path,
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> Option<TokenUsageSummary> {
    hydrate_dashboard_aggregate_cache_once();
    let expected_scope = dashboard_usage_scope_at(codex_home, now_utc, local_offset);
    let summary_cache = USAGE_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Some(summary) = summary_cache
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .filter(|cached| cached.signature.usage_scope() == expected_scope)
        .map(|cached| cached.summary)
    {
        return Some(summary);
    }
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    cache
        .lock()
        .ok()
        .and_then(|guard| guard.aggregate.clone())
        .filter(|cached| cached.signature.usage_scope() == expected_scope)
        .map(|cached| cached.summary)
}

impl DashboardScanSignature {
    fn usage_scope(&self) -> DashboardUsageScope {
        DashboardUsageScope {
            codex_home: self.codex_home.clone(),
            local_date: self.local_date.clone(),
            utc_offset_seconds: self.utc_offset_seconds,
        }
    }
}

#[cfg(test)]
fn dashboard_scan_signature_at(
    codex_home: &Path,
    index_revision: u64,
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> DashboardScanSignature {
    DashboardScanSignature {
        codex_home: codex_home.to_path_buf(),
        local_date: local_date_string(now_utc.to_offset(local_offset)),
        utc_offset_seconds: local_offset.whole_seconds(),
        index_revision,
    }
}

fn local_date_string(date_time: OffsetDateTime) -> String {
    let date = date_time.date();
    format!(
        "{:04}-{:02}-{:02}",
        date.year(),
        u8::from(date.month()),
        date.day()
    )
}

fn cached_dashboard_snapshot(signature: &DashboardScanSignature) -> Option<DashboardSnapshot> {
    cached_dashboard_aggregate(signature)
        .filter(|cached| cached.snapshot_complete)
        .and_then(|cached| cached.snapshot)
}

fn cached_dashboard_startup_snapshot(
    signature: &DashboardScanSignature,
) -> Option<DashboardSnapshot> {
    hydrate_dashboard_aggregate_cache_once();
    let expected_scope = signature.usage_scope();
    DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()))
        .lock()
        .ok()
        .and_then(|guard| guard.aggregate.clone())
        .filter(|cached| cached.signature.usage_scope() == expected_scope)
        .and_then(|cached| cached.snapshot)
}

fn cached_dashboard_aggregate(
    signature: &DashboardScanSignature,
) -> Option<CachedDashboardAggregate> {
    hydrate_dashboard_aggregate_cache_once();
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    cache
        .lock()
        .ok()
        .and_then(|guard| guard.aggregate.clone())
        .filter(|cached| &cached.signature == signature)
}

fn hydrate_dashboard_aggregate_cache_once() {
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    let should_load = if let Ok(mut guard) = cache.lock() {
        if guard.persistent_loaded {
            false
        } else {
            guard.persistent_loaded = true;
            true
        }
    } else {
        false
    };
    if !should_load {
        return;
    }

    let Some(persistent) = load_persistent_dashboard_aggregate() else {
        return;
    };
    if let Ok(mut guard) = cache.lock() {
        if guard.aggregate.is_none() {
            guard.aggregate = Some(persistent);
        }
    }
}

fn store_dashboard_aggregate(
    signature: DashboardScanSignature,
    snapshot: Option<DashboardSnapshot>,
    summary: TokenUsageSummary,
) -> Option<LocalDataWarning> {
    store_usage_summary_cache(signature.clone(), summary.clone());
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    let mut aggregate = CachedDashboardAggregate {
        signature,
        snapshot,
        summary,
        snapshot_complete: true,
    };
    let warning = save_persistent_dashboard_aggregate(&aggregate)
        .err()
        .map(|error| LocalDataWarning {
            source: "usage-cache-persistence".into(),
            message: error,
        });
    if let (Some(warning), Some(snapshot)) = (&warning, aggregate.snapshot.as_mut()) {
        if !snapshot
            .warnings
            .iter()
            .any(|existing| existing.source == warning.source)
        {
            snapshot.warnings.push(warning.clone());
        }
    }
    if let Ok(mut guard) = cache.lock() {
        guard.persistent_loaded = true;
        guard.aggregate = Some(aggregate);
    }
    warning
}

fn cached_usage_summary(signature: &DashboardScanSignature) -> Option<TokenUsageSummary> {
    let cache = USAGE_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(guard) = cache.lock() {
        if let Some(cached) = guard.as_ref() {
            if &cached.signature == signature {
                return Some(cached.summary.clone());
            }
        }
    }

    if let Some(cached) = load_persistent_dashboard_aggregate() {
        if &cached.signature == signature {
            store_usage_summary_cache(cached.signature.clone(), cached.summary.clone());
            return Some(cached.summary);
        }
    }

    None
}

fn store_usage_summary(signature: DashboardScanSignature, summary: TokenUsageSummary) {
    store_usage_summary_cache(signature.clone(), summary.clone());

    let memory_snapshot = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()))
        .lock()
        .ok()
        .and_then(|guard| {
            guard
                .aggregate
                .as_ref()
                .filter(|cached| cached.signature == signature)
                .and_then(|cached| cached.snapshot.clone())
        });
    let persistent_snapshot = memory_snapshot.or_else(|| {
        load_persistent_dashboard_aggregate()
            .filter(|cached| cached.signature == signature)
            .and_then(|cached| cached.snapshot)
    });

    if let Some(snapshot) = persistent_snapshot {
        let _ = store_dashboard_aggregate(signature, Some(snapshot), summary);
    }
}

fn store_usage_summary_cache(signature: DashboardScanSignature, summary: TokenUsageSummary) {
    let cache = USAGE_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = cache.lock() {
        *guard = Some(CachedUsageSummary { signature, summary });
    }
}

fn load_persistent_dashboard_aggregate() -> Option<CachedDashboardAggregate> {
    let path = app_paths::token_aggregate_cache_path()?;
    let data = fs::read(path).ok()?;
    decode_persistent_dashboard_aggregate(&data)
}

fn decode_persistent_dashboard_aggregate(data: &[u8]) -> Option<CachedDashboardAggregate> {
    let cache = serde_json::from_slice::<PersistentDashboardAggregateCache>(data).ok()?;
    (cache.version == DASHBOARD_AGGREGATE_CACHE_VERSION).then_some(CachedDashboardAggregate {
        signature: cache.signature,
        snapshot: cache.snapshot,
        summary: cache.summary,
        snapshot_complete: false,
    })
}

fn save_persistent_dashboard_aggregate(aggregate: &CachedDashboardAggregate) -> Result<(), String> {
    let Some(path) = app_paths::token_aggregate_cache_path() else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "create aggregate cache directory {}: {error}",
                parent.display()
            )
        })?;
    }
    if !aggregate_checkpoint_due(&path, &aggregate.signature, SystemTime::now()) {
        return Ok(());
    }
    let payload = PersistentDashboardAggregateCache {
        version: DASHBOARD_AGGREGATE_CACHE_VERSION,
        signature: aggregate.signature.clone(),
        snapshot: aggregate
            .snapshot
            .clone()
            .map(sanitize_snapshot_for_persistence),
        summary: aggregate.summary.clone(),
    };
    let data = serde_json::to_vec(&payload)
        .map_err(|error| format!("serialize aggregate cache {}: {error}", path.display()))?;
    write_aggregate_if_changed(&path, &data, |path, data| {
        crate::core::atomic_file::write_atomically(path, data)
    })
}

fn aggregate_checkpoint_due(
    path: &Path,
    signature: &DashboardScanSignature,
    now: SystemTime,
) -> bool {
    let Some(existing) = fs::read(path)
        .ok()
        .and_then(|data| serde_json::from_slice::<PersistentDashboardAggregateCache>(&data).ok())
    else {
        return true;
    };
    if existing.version != DASHBOARD_AGGREGATE_CACHE_VERSION
        || existing.signature.usage_scope() != signature.usage_scope()
    {
        return true;
    }
    let Some(modified) = fs::metadata(path)
        .ok()
        .and_then(|metadata| metadata.modified().ok())
    else {
        return true;
    };
    now.duration_since(modified)
        .is_ok_and(|age| age >= AGGREGATE_CHECKPOINT_INTERVAL)
}

fn write_aggregate_if_changed(
    path: &Path,
    data: &[u8],
    writer: impl FnOnce(&Path, &[u8]) -> Result<(), crate::core::atomic_file::AtomicWriteError>,
) -> Result<(), String> {
    if fs::read(path).is_ok_and(|existing| existing == data) {
        return Ok(());
    }
    writer(path, data).map_err(|error| error.to_string())
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistentDashboardAggregateCache {
    version: u32,
    signature: DashboardScanSignature,
    snapshot: Option<DashboardSnapshot>,
    summary: TokenUsageSummary,
}

fn sanitize_snapshot_for_persistence(mut snapshot: DashboardSnapshot) -> DashboardSnapshot {
    snapshot.recent_usage_24h.clear();
    snapshot.cache_hit_ranking.clear();
    snapshot.cache_usage = Default::default();
    snapshot
}

fn snapshot_with_generated_at(mut snapshot: DashboardSnapshot) -> DashboardSnapshot {
    snapshot.generated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    snapshot
}

fn record_dashboard_aggregate_build_for_testing(_codex_home: &Path) {
    #[cfg(test)]
    {
        let counts = DASHBOARD_AGGREGATE_BUILD_COUNT.get_or_init(|| Mutex::new(HashMap::new()));
        if let Ok(mut counts) = counts.lock() {
            *counts.entry(_codex_home.to_path_buf()).or_default() += 1;
        }
    }
}

fn record_dashboard_source_scan_for_testing() {
    #[cfg(test)]
    DASHBOARD_SCAN_SIGNATURE_COUNT.fetch_add(1, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_dashboard_aggregate_build_count_for_testing() {
    wait_for_usage_summary_refreshes_for_testing();
    let counts = DASHBOARD_AGGREGATE_BUILD_COUNT.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut counts) = counts.lock() {
        counts.clear();
    }
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    if let Ok(mut guard) = cache.lock() {
        *guard = DashboardAggregateCacheState::default();
    }
    let summary_cache = USAGE_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = summary_cache.lock() {
        *guard = None;
    }
    let in_flight = USAGE_SUMMARY_REFRESH_IN_FLIGHT.get_or_init(|| Mutex::new(HashSet::new()));
    if let Ok(mut guard) = in_flight.lock() {
        guard.clear();
    }
    let source_scan_cache =
        USAGE_SUMMARY_SOURCE_SCAN_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut guard) = source_scan_cache.lock() {
        guard.clear();
    }
    DASHBOARD_SCAN_SIGNATURE_COUNT.store(0, Ordering::Relaxed);
}

#[cfg(test)]
fn wait_for_usage_summary_refreshes_for_testing() {
    let in_flight = USAGE_SUMMARY_REFRESH_IN_FLIGHT.get_or_init(|| Mutex::new(HashSet::new()));
    for _ in 0..250 {
        let is_empty = in_flight
            .lock()
            .map(|guard| guard.is_empty())
            .unwrap_or(false);
        if is_empty {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    panic!("usage summary background refresh did not quiesce before test reset");
}

#[cfg(test)]
pub(crate) fn dashboard_aggregate_build_count_for_testing(codex_home: &Path) -> usize {
    let counts = DASHBOARD_AGGREGATE_BUILD_COUNT.get_or_init(|| Mutex::new(HashMap::new()));
    counts
        .lock()
        .ok()
        .and_then(|counts| counts.get(codex_home).copied())
        .unwrap_or(0)
}

#[cfg(test)]
pub(crate) fn reset_dashboard_scan_signature_count_for_testing() {
    DASHBOARD_SCAN_SIGNATURE_COUNT.store(0, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn dashboard_scan_signature_count_for_testing() -> usize {
    DASHBOARD_SCAN_SIGNATURE_COUNT.load(Ordering::Relaxed)
}
