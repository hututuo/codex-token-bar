use super::cache_lifecycle;
use crate::core::app_paths;
use crate::models::{
    AccountInfo, DashboardSnapshot, LocalDataWarning, QuotaLimit, QuotaSnapshot, ResetCreditSummary,
};
use notify::event::ModifyKind;
use notify::{
    Event as NotifyEvent, EventKind as NotifyEventKind, RecommendedWatcher, RecursiveMode, Watcher,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration as StdDuration, Instant, SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};
use uuid::Uuid;

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
static PRECISE_PROCESS_OBSERVER_IDENTITY: OnceLock<PreciseObserverIdentity> = OnceLock::new();
static ATTRIBUTION_MUTATION_WATCHERS: OnceLock<Mutex<HashMap<PathBuf, AttributionMutationWatcher>>> =
    OnceLock::new();
static ATTRIBUTION_MARKER_WRITE_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static ATTRIBUTION_WATCHER_FAILURES: OnceLock<Mutex<HashMap<PathBuf, String>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_AGGREGATE_BUILD_COUNT: OnceLock<Mutex<HashMap<PathBuf, usize>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_SCAN_SIGNATURE_COUNT: AtomicUsize = AtomicUsize::new(0);
const DASHBOARD_AGGREGATE_CACHE_VERSION: u32 = 17;
const AGGREGATE_CHECKPOINT_INTERVAL: StdDuration = StdDuration::from_secs(15 * 60);
const USAGE_SUMMARY_SOURCE_SCAN_REUSE_INTERVAL: StdDuration = StdDuration::from_millis(250);
const USAGE_SUMMARY_SOURCE_SCAN_STATE_RETENTION: StdDuration = StdDuration::from_secs(5 * 60);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PreciseObserverIdentity {
    epoch: String,
    started_at_unix_micros: u64,
    sequence: u64,
}

struct AttributionMutationWatcher {
    _watcher: RecommendedWatcher,
    physical_home_identity: String,
}

#[cfg(unix)]
fn attribution_watch_root_physical_identity(path: &Path) -> Result<String, String> {
    use std::os::unix::fs::MetadataExt;

    let handle = fs::File::open(path).map_err(|error| {
        format!(
            "无法打开本地用量监听目录以核对物理身份 {}：{error}",
            path.display()
        )
    })?;
    let metadata = handle.metadata().map_err(|error| {
        format!(
            "无法读取本地用量监听目录物理身份 {}：{error}",
            path.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err(format!("本地用量监听路径不是目录：{}", path.display()));
    }
    Ok(format!("unix:{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn attribution_watch_root_physical_identity(path: &Path) -> Result<String, String> {
    use std::fs::OpenOptions;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
    };

    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_SHARE_WRITE: u32 = 0x0000_0002;
    const FILE_SHARE_DELETE: u32 = 0x0000_0004;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;

    let handle = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .map_err(|error| {
            format!(
                "无法打开本地用量监听目录以核对物理身份 {}：{error}",
                path.display()
            )
        })?;
    let mut info = FILE_ID_INFO::default();
    let succeeded = unsafe {
        GetFileInformationByHandleEx(
            handle.as_raw_handle() as _,
            FileIdInfo,
            (&mut info as *mut FILE_ID_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_ID_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if succeeded == 0 {
        return Err(format!(
            "无法读取 Windows 本地用量监听目录物理身份 {}：{}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let file_id = info
        .FileId
        .Identifier
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(format!("windows:{}:{file_id}", info.VolumeSerialNumber))
}

#[cfg(not(any(unix, windows)))]
fn attribution_watch_root_physical_identity(path: &Path) -> Result<String, String> {
    let metadata = fs::metadata(path).map_err(|error| {
        format!(
            "无法读取本地用量监听目录物理身份 {}：{error}",
            path.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err(format!("本地用量监听路径不是目录：{}", path.display()));
    }
    Ok(format!(
        "portable:{}:{:?}:{:?}",
        metadata.len(),
        metadata.created().ok(),
        metadata.modified().ok()
    ))
}

fn precise_process_observer_identity() -> &'static PreciseObserverIdentity {
    PRECISE_PROCESS_OBSERVER_IDENTITY.get_or_init(|| PreciseObserverIdentity {
        epoch: Uuid::new_v4().to_string(),
        started_at_unix_micros: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros()
            .try_into()
            .unwrap_or(u64::MAX),
        sequence: 0,
    })
}

fn observer_marker_path(codex_home: &Path) -> Result<PathBuf, String> {
    let database = exact_usage_index::database_path(codex_home)?;
    let mut marker = database.as_os_str().to_os_string();
    marker.push(".attribution-continuity-unsafe.json");
    Ok(PathBuf::from(marker))
}

fn precise_observer_identity(codex_home: &Path) -> Result<PreciseObserverIdentity, String> {
    let canonical_home = fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf());
    if let Some(error) = ATTRIBUTION_WATCHER_FAILURES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&canonical_home)
        .cloned()
    {
        return Err(error);
    }
    let process = precise_process_observer_identity().clone();
    let marker_path = observer_marker_path(codex_home)?;
    let bytes = match fs::read(&marker_path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(process),
        Err(error) => {
            return Err(format!(
                "无法读取本地用量连续性标记 {}：{error}",
                marker_path.display()
            ))
        }
    };
    let marker: PreciseObserverIdentity = serde_json::from_slice(&bytes).map_err(|error| {
        format!(
            "本地用量连续性标记损坏，已停止共享账号归因：{}（{error}）",
            marker_path.display()
        )
    })?;
    if Uuid::parse_str(&marker.epoch).is_err() || marker.started_at_unix_micros == 0 {
        return Err("本地用量连续性标记字段无效，已停止共享账号归因".into());
    }
    if observer_identity_order(&marker) > observer_identity_order(&process) {
        Ok(marker)
    } else {
        Ok(process)
    }
}

fn observer_identity_order(identity: &PreciseObserverIdentity) -> (u64, u64) {
    (identity.started_at_unix_micros, identity.sequence)
}

fn write_attribution_continuity_unsafe_marker(
    codex_home: &Path,
    reason: &str,
) -> Result<(), String> {
    let _guard = ATTRIBUTION_MARKER_WRITE_GATE
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let marker_path = observer_marker_path(codex_home)?;
    if let Some(parent) = marker_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "无法创建本地用量连续性目录 {}：{error}",
                parent.display()
            )
        })?;
    }
    let previous = fs::read(&marker_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<PreciseObserverIdentity>(&bytes).ok());
    let process = precise_process_observer_identity();
    let now_micros: u64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros()
        .try_into()
        .unwrap_or(u64::MAX);
    let previous_sequence = previous.as_ref().map(|value| value.sequence).unwrap_or(0);
    let previous_started_at = previous
        .as_ref()
        .map(|value| value.started_at_unix_micros)
        .unwrap_or(0);
    let marker = PreciseObserverIdentity {
        epoch: Uuid::new_v4().to_string(),
        started_at_unix_micros: now_micros
            .max(process.started_at_unix_micros)
            .max(previous_started_at),
        sequence: previous_sequence.saturating_add(1),
    };
    let data = serde_json::to_vec(&marker)
        .map_err(|error| format!("无法编码本地用量连续性标记（{reason}）：{error}"))?;
    crate::core::atomic_file::write_atomically(&marker_path, &data).map_err(|error| {
        format!(
            "无法持久化本地用量连续性标记 {}（{reason}）：{error}",
            marker_path.display()
        )
    })?;
    Ok(())
}

fn is_monitored_exact_source_path(codex_home: &Path, path: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(codex_home) else {
        return false;
    };
    let Some(first) = relative.components().next() else {
        return false;
    };
    let first = first.as_os_str().to_string_lossy();
    first.eq_ignore_ascii_case("sessions")
        || first.eq_ignore_ascii_case("archived_sessions")
        || relative
            .extension()
            .is_some_and(|extension| extension.to_string_lossy().eq_ignore_ascii_case("jsonl"))
}

fn mutation_event_requires_continuity_cutover(codex_home: &Path, event: &NotifyEvent) -> bool {
    if event.need_rescan() {
        return true;
    }
    let touches_exact_source = event
        .paths
        .iter()
        .any(|path| is_monitored_exact_source_path(codex_home, path));
    if !touches_exact_source {
        return false;
    }
    matches!(
        event.kind,
        NotifyEventKind::Remove(_)
            | NotifyEventKind::Modify(ModifyKind::Name(_))
            | NotifyEventKind::Any
            | NotifyEventKind::Other
    )
}

fn record_attribution_watcher_failure(codex_home: &Path, error: String) {
    ATTRIBUTION_WATCHER_FAILURES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(codex_home.to_path_buf(), error);
}

fn clear_attribution_watcher_failure(codex_home: &Path) {
    ATTRIBUTION_WATCHER_FAILURES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(codex_home);
}

fn start_attribution_mutation_watcher(codex_home: &Path) -> Result<RecommendedWatcher, String> {
    let canonical_home = fs::canonicalize(codex_home).map_err(|error| {
        format!(
            "无法确认本地用量监听目录 {}：{error}",
            codex_home.display()
        )
    })?;
    let callback_home = canonical_home.clone();
    let mut watcher = notify::recommended_watcher(move |result: notify::Result<NotifyEvent>| {
        let reason = match result {
            Ok(event) if mutation_event_requires_continuity_cutover(&callback_home, &event) => {
                Some(format!("session_mutation:{:?}", event.kind))
            }
            Ok(_) => None,
            Err(error) => Some(format!("watcher_drop_or_overflow:{error}")),
        };
        let Some(reason) = reason else {
            return;
        };
        match write_attribution_continuity_unsafe_marker(&callback_home, &reason) {
            Ok(()) => clear_attribution_watcher_failure(&callback_home),
            Err(error) => record_attribution_watcher_failure(&callback_home, error),
        }
    })
    .map_err(|error| format!("无法启动本地用量目录监听：{error}"))?;
    watcher
        .watch(&canonical_home, RecursiveMode::Recursive)
        .map_err(|error| format!("无法监听本地会话目录 {}：{error}", canonical_home.display()))?;
    Ok(watcher)
}

fn ensure_attribution_mutation_watcher(codex_home: &Path) -> Result<(), String> {
    let canonical_home = fs::canonicalize(codex_home).map_err(|error| {
        format!(
            "无法确认本地用量监听目录 {}：{error}",
            codex_home.display()
        )
    })?;
    let physical_home_identity = attribution_watch_root_physical_identity(&canonical_home)?;
    let watchers = ATTRIBUTION_MUTATION_WATCHERS
        .get_or_init(|| Mutex::new(HashMap::new()));
    let mut watchers = watchers
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    watchers.retain(|path, _| path.exists());
    if watchers.get(&canonical_home).is_some_and(|entry| {
        entry.physical_home_identity == physical_home_identity
    }) {
        return precise_observer_identity(&canonical_home).map(|_| ());
    }
    let replaced_physical_root = watchers.remove(&canonical_home).is_some();
    if replaced_physical_root {
        if let Err(error) = write_attribution_continuity_unsafe_marker(
            &canonical_home,
            "watch_root_physical_identity_changed",
        ) {
            record_attribution_watcher_failure(&canonical_home, error.clone());
            return Err(error);
        }
    }
    // Clear an earlier start failure before registering the callback. Clearing
    // after `watch()` would race an immediately delivered native event and
    // could erase a real marker-write failure reported by that callback.
    clear_attribution_watcher_failure(&canonical_home);
    let watcher = match start_attribution_mutation_watcher(&canonical_home) {
        Ok(watcher) => watcher,
        Err(error) => {
            record_attribution_watcher_failure(&canonical_home, error.clone());
            return Err(error);
        }
    };
    let rebound_physical_home_identity =
        match attribution_watch_root_physical_identity(&canonical_home) {
            Ok(identity) => identity,
            Err(error) => {
                drop(watcher);
                record_attribution_watcher_failure(&canonical_home, error.clone());
                return Err(error);
            }
        };
    if rebound_physical_home_identity != physical_home_identity {
        drop(watcher);
        let reason = "watch_root_changed_while_binding";
        if let Err(error) =
            write_attribution_continuity_unsafe_marker(&canonical_home, reason)
        {
            record_attribution_watcher_failure(&canonical_home, error.clone());
            return Err(error);
        }
        let error = format!(
            "本地用量监听目录在重绑期间已被替换，已停止本轮共享账号归因：{}",
            canonical_home.display()
        );
        record_attribution_watcher_failure(&canonical_home, error.clone());
        return Err(error);
    }
    watchers.insert(
        canonical_home,
        AttributionMutationWatcher {
            _watcher: watcher,
            physical_home_identity: rebound_physical_home_identity,
        },
    );
    Ok(())
}

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
    #[cfg(not(test))]
    ensure_attribution_mutation_watcher(codex_home)?;
    // This is a conservative coverage watermark, captured before the full sync
    // starts. Events appended while sync/aggregation is running may or may not
    // enter this generation, so publishing the return time would overclaim.
    let precise_coverage_at = OffsetDateTime::now_utc();
    let revision = index.sync(codex_home, &mut warnings)?;
    #[cfg(not(test))]
    ensure_attribution_mutation_watcher(codex_home)?;
    let attribution_safety = index.attribution_safety_state()?;
    let observer_identity = precise_observer_identity(codex_home)?;
    let signature = dashboard_index_signature(codex_home, revision);
    if let Some(snapshot) = cached_dashboard_snapshot(&signature) {
        let _ = cache_lifecycle::mark_usage_cache_ready_after_success();
        let mut snapshot = snapshot_with_precise_coverage(
            snapshot,
            precise_coverage_at,
            &observer_identity,
            &attribution_safety,
        );
        merge_usage_cache_marker_warning(&mut snapshot);
        return Ok(snapshot);
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
    let precise_scan_complete = !attribution_safety.current_scan_incomplete;
    let precise_recent_usage_covered_at = precise_scan_complete.then(|| {
        precise_coverage_at
            .format(&Rfc3339)
            .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
    });

    let mut snapshot = DashboardSnapshot {
        generated_at: generated_at.clone(),
        precise_recent_usage_covered_at,
        precise_recent_usage_fresh: precise_scan_complete,
        precise_observer_epoch: precise_scan_complete
            .then_some(observer_identity.epoch.clone()),
        precise_observer_started_at_unix_micros: precise_scan_complete
            .then_some(observer_identity.started_at_unix_micros),
        precise_observer_sequence: precise_scan_complete
            .then_some(observer_identity.sequence),
        precise_attribution_provenance_epoch: Some(
            attribution_safety.provenance_epoch.clone(),
        ),
        precise_attribution_generation: Some(attribution_safety.generation),
        precise_attribution_unsafe_since_generation:
            attribution_safety.unsafe_since_generation,
        precise_attribution_unsafe_id: attribution_safety.unsafe_id.clone(),
        precise_attribution_current_scan_unsafe:
            attribution_safety.current_scan_unsafe_cause_detected,
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

pub fn acknowledge_attribution_safety(
    codex_home: &Path,
    provenance_epoch: &str,
    unsafe_id: &str,
    through_generation: u64,
) -> Result<bool, String> {
    let mut index = ExactUsageIndex::open(codex_home)?;
    index.acknowledge_attribution_safety(provenance_epoch, unsafe_id, through_generation)
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
    let snapshot_complete = snapshot.as_ref().is_some_and(|snapshot| {
        snapshot.precise_recent_usage_fresh
            && snapshot.precise_observer_epoch.is_some()
            && snapshot.precise_observer_started_at_unix_micros.is_some()
            && snapshot.precise_observer_sequence.is_some()
            && snapshot.precise_attribution_provenance_epoch.is_some()
            && snapshot.precise_attribution_generation.is_some()
            && !snapshot.recent_usage_24h.is_empty()
    });
    let mut aggregate = CachedDashboardAggregate {
        signature,
        snapshot,
        summary,
        snapshot_complete,
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
    snapshot.precise_recent_usage_fresh = false;
    snapshot.precise_observer_epoch = None;
    snapshot.precise_observer_started_at_unix_micros = None;
    snapshot.precise_observer_sequence = None;
    snapshot.precise_attribution_provenance_epoch = None;
    snapshot.precise_attribution_generation = None;
    snapshot.precise_attribution_unsafe_since_generation = None;
    snapshot.precise_attribution_unsafe_id = None;
    snapshot.precise_attribution_current_scan_unsafe = false;
    snapshot
}

fn snapshot_with_generated_at(mut snapshot: DashboardSnapshot) -> DashboardSnapshot {
    snapshot.generated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    snapshot
}

fn snapshot_with_precise_coverage(
    mut snapshot: DashboardSnapshot,
    coverage_at: OffsetDateTime,
    observer_identity: &PreciseObserverIdentity,
    attribution_safety: &exact_usage_index::AttributionSafetyState,
) -> DashboardSnapshot {
    let generated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    if snapshot.recent_usage_24h.is_empty() {
        snapshot.generated_at = generated_at;
        snapshot.precise_recent_usage_fresh = false;
        snapshot.precise_observer_epoch = None;
        snapshot.precise_observer_started_at_unix_micros = None;
        snapshot.precise_observer_sequence = None;
        snapshot.precise_attribution_provenance_epoch = None;
        snapshot.precise_attribution_generation = None;
        snapshot.precise_attribution_unsafe_since_generation = None;
        snapshot.precise_attribution_unsafe_id = None;
        snapshot.precise_attribution_current_scan_unsafe = false;
        return snapshot;
    }
    if attribution_safety.current_scan_incomplete {
        snapshot.generated_at = generated_at;
        snapshot.precise_recent_usage_fresh = false;
        snapshot.precise_observer_epoch = None;
        snapshot.precise_observer_started_at_unix_micros = None;
        snapshot.precise_observer_sequence = None;
        snapshot.precise_attribution_provenance_epoch = Some(
            attribution_safety.provenance_epoch.clone(),
        );
        snapshot.precise_attribution_generation = Some(attribution_safety.generation);
        snapshot.precise_attribution_unsafe_since_generation =
            attribution_safety.unsafe_since_generation;
        snapshot.precise_attribution_unsafe_id = attribution_safety.unsafe_id.clone();
        snapshot.precise_attribution_current_scan_unsafe =
            attribution_safety.current_scan_unsafe_cause_detected;
        return snapshot;
    }
    let covered_at = coverage_at
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    snapshot.generated_at = generated_at;
    snapshot.precise_recent_usage_covered_at = Some(covered_at);
    snapshot.precise_recent_usage_fresh = true;
    snapshot.precise_observer_epoch = Some(observer_identity.epoch.clone());
    snapshot.precise_observer_started_at_unix_micros = Some(
        observer_identity.started_at_unix_micros,
    );
    snapshot.precise_observer_sequence = Some(observer_identity.sequence);
    snapshot.precise_attribution_provenance_epoch = Some(
        attribution_safety.provenance_epoch.clone(),
    );
    snapshot.precise_attribution_generation = Some(attribution_safety.generation);
    snapshot.precise_attribution_unsafe_since_generation =
        attribution_safety.unsafe_since_generation;
    snapshot.precise_attribution_unsafe_id = attribution_safety.unsafe_id.clone();
    snapshot.precise_attribution_current_scan_unsafe =
        attribution_safety.current_scan_unsafe_cause_detected;
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
