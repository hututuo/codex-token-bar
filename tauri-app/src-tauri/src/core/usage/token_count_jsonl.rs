use super::cache_lifecycle;
use crate::core::app_paths;
use crate::models::{
    AccountInfo, DashboardSnapshot, LocalDataWarning, QuotaLimit, QuotaSnapshot,
    ResetCreditSummary,
};
#[cfg(test)]
use std::collections::HashMap;
use std::collections::HashSet;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

mod aggregates;
mod event_loader;
mod ranking;
mod session_files;
mod session_parser;
#[cfg(test)]
mod cache_version_tests;
#[cfg(test)]
mod tests;
mod token_event_cache;

use aggregates::{activity_days_at, recent_usage, recent_usage_30d, recent_usage_7d, stats_at};
use event_loader::load_token_events_from_files;
use ranking::{cache_hit_ranking, cache_usage, sanitize_cache_usage_for_persistence};
use session_files::jsonl_files_for_codex_home;
use token_event_cache::{file_cache_key, file_signature, CachedFileSignature};

static DASHBOARD_AGGREGATE_CACHE: OnceLock<Mutex<DashboardAggregateCacheState>> = OnceLock::new();
static DASHBOARD_BUILD_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static USAGE_SUMMARY_REFRESH_IN_FLIGHT: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
#[cfg(test)]
static USAGE_SUMMARY_CACHE: OnceLock<Mutex<Option<CachedUsageSummary>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_AGGREGATE_BUILD_COUNT: OnceLock<Mutex<HashMap<PathBuf, usize>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_SCAN_SIGNATURE_COUNT: AtomicUsize = AtomicUsize::new(0);
const DASHBOARD_AGGREGATE_CACHE_VERSION: u32 = 11;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsageSummary {
    pub total_tokens: u64,
    pub today_tokens: u64,
    pub today_requests: u32,
}

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
    let session_files = jsonl_files_for_codex_home(codex_home, &mut warnings);
    let signature = dashboard_scan_signature(codex_home, &session_files);
    if let Some(snapshot) = cached_dashboard_snapshot(&signature) {
        cache_lifecycle::mark_usage_cache_ready_after_success();
        return Ok(snapshot_with_generated_at(snapshot));
    }

    let mut events = Vec::new();
    events.extend(load_token_events_from_files(codex_home, session_files, &mut warnings));

    if events.is_empty() {
        return Err(no_token_events_error(&warnings));
    }

    record_dashboard_aggregate_build_for_testing(codex_home);
    let now_utc = OffsetDateTime::now_utc();
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let summary = usage_summary_from_events_at(&events, now_utc, local_offset);
    let generated_at = now_utc
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    let (activity_days, stats) = activity_days_and_stats_at(&events, now_utc, local_offset);
    let recent_usage_24h = recent_usage(&events, local_offset);
    let recent_usage_7d = recent_usage_7d(&events, local_offset);
    let recent_usage_30d = recent_usage_30d(&events, local_offset);
    let cache_hit_ranking = cache_hit_ranking(&events, codex_home, local_offset, &mut warnings);
    let cache_usage = cache_usage(&events, codex_home, local_offset, &mut warnings);

    let snapshot = DashboardSnapshot {
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
        cache_hit_ranking,
        cache_usage,
        warnings,
        diagnostics: Vec::new(),
    };
    store_dashboard_aggregate(signature, Some(snapshot.clone()), summary);
    cache_lifecycle::mark_usage_cache_ready_after_success();
    Ok(snapshot)
}

fn activity_days_and_stats_at(
    events: &[TokenEvent],
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> (Vec<crate::models::ActivityDay>, crate::models::DashboardStats) {
    let days = activity_days_at(events, now_utc, local_offset);
    let stats = stats_at(events, &days, now_utc.to_offset(local_offset).date());
    (days, stats)
}

#[cfg(test)]
pub fn usage_summary(codex_home: &Path) -> Result<TokenUsageSummary, String> {
    let mut events = Vec::new();
    let mut warnings = Vec::new();
    let session_files = jsonl_files_for_codex_home(codex_home, &mut warnings);
    let signature = dashboard_scan_signature(codex_home, &session_files);
    if let Some(summary) = cached_usage_summary(&signature) {
        return Ok(summary);
    }

    events.extend(load_token_events_from_files(codex_home, session_files, &mut warnings));

    if events.is_empty() {
        return Err(no_token_events_error(&warnings));
    }

    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let summary = usage_summary_from_events(&events, local_offset);
    store_usage_summary(signature, summary.clone());

    Ok(summary)
}

pub fn dashboard_usage_summary(codex_home: &Path) -> Result<TokenUsageSummary, String> {
    let snapshot = dashboard_snapshot(codex_home)?;
    let today = snapshot.activity_days.last();
    Ok(TokenUsageSummary {
        total_tokens: snapshot.stats.total_tokens,
        today_tokens: today.map_or(0, |day| day.tokens),
        today_requests: today.map_or(0, |day| day.calls),
    })
}

pub fn usage_summary_snapshot(codex_home: &Path) -> Result<TokenUsageSummary, String> {
    let mut warnings = Vec::new();
    let session_files = jsonl_files_for_codex_home(codex_home, &mut warnings);
    let signature = dashboard_scan_signature(codex_home, &session_files);
    if let Some(cached) = cached_dashboard_aggregate(&signature) {
        return Ok(cached.summary);
    }

    let last_trusted = cached_dashboard_usage_summary(codex_home);
    schedule_usage_summary_refresh(codex_home);
    last_trusted.ok_or_else(|| "精确 token summary 尚未就绪，正在后台初始化".into())
}

pub(crate) fn cached_dashboard_usage_summary(codex_home: &Path) -> Option<TokenUsageSummary> {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    cached_dashboard_usage_summary_at(codex_home, OffsetDateTime::now_utc(), local_offset)
}

pub(crate) fn cached_dashboard_snapshot_for_startup(
    codex_home: &Path,
) -> Option<DashboardSnapshot> {
    let mut warnings = Vec::new();
    let session_files = jsonl_files_for_codex_home(codex_home, &mut warnings);
    let signature = dashboard_scan_signature(codex_home, &session_files);
    cached_dashboard_snapshot(&signature).map(snapshot_with_generated_at)
}

#[cfg(test)]
fn usage_summary_from_events(events: &[TokenEvent], local_offset: UtcOffset) -> TokenUsageSummary {
    usage_summary_from_events_at(events, OffsetDateTime::now_utc(), local_offset)
}

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
    if let Ok(mut guard) = in_flight.lock() {
        if !guard.insert(key.clone()) {
            return;
        }
    } else {
        return;
    }

    std::thread::spawn(move || {
        let _ = dashboard_usage_summary(&key);
        if let Some(in_flight) = USAGE_SUMMARY_REFRESH_IN_FLIGHT.get() {
            if let Ok(mut guard) = in_flight.lock() {
                guard.remove(&key);
            }
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

#[cfg(test)]
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
    session_files: Vec<SessionFileSignature>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct SessionFileSignature {
    cache_key: String,
    signature: CachedFileSignature,
}

fn dashboard_scan_signature(codex_home: &Path, session_files: &[PathBuf]) -> DashboardScanSignature {
    #[cfg(test)]
    DASHBOARD_SCAN_SIGNATURE_COUNT.fetch_add(1, Ordering::Relaxed);
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    dashboard_scan_signature_at(codex_home, session_files, OffsetDateTime::now_utc(), local_offset)
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

fn dashboard_scan_signature_at(
    codex_home: &Path,
    session_files: &[PathBuf],
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> DashboardScanSignature {
    let mut file_signatures = session_files
        .iter()
        .filter_map(|file| {
            Some(SessionFileSignature {
                cache_key: file_cache_key(codex_home, file),
                signature: file_signature(file)?,
            })
        })
        .collect::<Vec<_>>();
    file_signatures.sort_by(|left, right| left.cache_key.cmp(&right.cache_key));

    DashboardScanSignature {
        codex_home: codex_home.to_path_buf(),
        local_date: local_date_string(now_utc.to_offset(local_offset)),
        utc_offset_seconds: local_offset.whole_seconds(),
        session_files: file_signatures,
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
    cached_dashboard_aggregate(signature).and_then(|cached| cached.snapshot)
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
) {
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    let aggregate = CachedDashboardAggregate {
        signature,
        snapshot,
        summary,
    };
    if let Ok(mut guard) = cache.lock() {
        guard.persistent_loaded = true;
        guard.aggregate = Some(aggregate.clone());
    }
    save_persistent_dashboard_aggregate(&aggregate);
}

#[cfg(test)]
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
            store_dashboard_aggregate(
                cached.signature.clone(),
                cached.snapshot.clone(),
                cached.summary.clone(),
            );
            return Some(cached.summary);
        }
    }

    None
}

#[cfg(test)]
fn store_usage_summary(signature: DashboardScanSignature, summary: TokenUsageSummary) {
    let cache = USAGE_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = cache.lock() {
        *guard = Some(CachedUsageSummary {
            signature: signature.clone(),
            summary: summary.clone(),
        });
    }

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
        store_dashboard_aggregate(signature, Some(snapshot), summary);
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
    })
}

fn save_persistent_dashboard_aggregate(aggregate: &CachedDashboardAggregate) {
    let Some(path) = app_paths::token_aggregate_cache_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        if fs::create_dir_all(parent).is_err() {
            return;
        }
    }
    let payload = PersistentDashboardAggregateCache {
        version: DASHBOARD_AGGREGATE_CACHE_VERSION,
        signature: aggregate.signature.clone(),
        snapshot: aggregate.snapshot.clone().map(sanitize_snapshot_for_persistence),
        summary: aggregate.summary.clone(),
    };
    let Ok(data) = serde_json::to_vec(&payload) else {
        return;
    };
    let temp_path = unique_cache_temp_path(&path, "json.tmp");
    if fs::write(&temp_path, data).is_ok() {
        let _ = fs::rename(temp_path, path);
    }
}

fn unique_cache_temp_path(path: &Path, label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    path.with_extension(format!("{label}-{}-{nanos}", std::process::id()))
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
    snapshot.cache_usage = sanitize_cache_usage_for_persistence(snapshot.cache_usage);
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

#[cfg(test)]
pub(crate) fn reset_dashboard_aggregate_build_count_for_testing() {
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
    DASHBOARD_SCAN_SIGNATURE_COUNT.store(0, Ordering::Relaxed);
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
