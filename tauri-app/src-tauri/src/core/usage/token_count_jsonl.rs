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
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::time::{Duration as StdDuration, Instant, SystemTime, UNIX_EPOCH};
use std::panic::{catch_unwind, AssertUnwindSafe};
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
static SESSION_CATALOG_BUILD_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static USAGE_SUMMARY_CACHE: OnceLock<Mutex<Option<CachedUsageSummary>>> = OnceLock::new();
static PRECISE_REFRESH_COORDINATORS:
    OnceLock<Mutex<HashMap<PathBuf, Weak<PreciseRefreshCoordinator>>>> = OnceLock::new();
static PRECISE_REFRESH_RECENCY: OnceLock<Mutex<HashMap<PathBuf, Instant>>> = OnceLock::new();
static PRECISE_PROCESS_OBSERVER_IDENTITY: OnceLock<PreciseObserverIdentity> = OnceLock::new();
static ATTRIBUTION_MUTATION_WATCHERS: OnceLock<Mutex<HashMap<PathBuf, AttributionMutationWatcher>>> =
    OnceLock::new();
static ATTRIBUTION_MARKER_WRITE_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static ATTRIBUTION_WATCHER_FAILURES: OnceLock<Mutex<HashMap<PathBuf, String>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_AGGREGATE_BUILD_COUNT: OnceLock<Mutex<HashMap<PathBuf, usize>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_SCAN_SIGNATURE_COUNT: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static PRECISE_REFRESH_SYNC_CALL_COUNT: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static PRECISE_REFRESH_SYNC_HOOK: OnceLock<Mutex<Option<PreciseRefreshSyncHook>>> =
    OnceLock::new();
#[cfg(test)]
static PRECISE_REFRESH_AFTER_CUTOFF_HOOK: OnceLock<Mutex<Option<PreciseRefreshCutoffHook>>> =
    OnceLock::new();
#[cfg(test)]
static PRECISE_REFRESH_PROMOTION_HOOK: OnceLock<Mutex<Option<PreciseRefreshPromotionHook>>> =
    OnceLock::new();
#[cfg(test)]
static PRECISE_REFRESH_FINISH_HOOK: OnceLock<Mutex<Option<PreciseRefreshFinishHook>>> =
    OnceLock::new();
#[cfg(test)]
static FAIL_NEXT_PRECISE_REFRESH_SPAWN: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
// v0.8.3 shipped the first stable DashboardSnapshot envelope (v16). v17 and
// v18 only added serde-defaulted fields to that same envelope; keep one
// isolated legacy decoder/sanitizer for all three versions and never write any
// of them again.
const LEGACY_DASHBOARD_AGGREGATE_CACHE_V16: u32 = 16;
const LEGACY_DASHBOARD_AGGREGATE_CACHE_V17: u32 = 17;
const LEGACY_DASHBOARD_AGGREGATE_CACHE_VERSION: u32 = 18;
const DASHBOARD_AGGREGATE_CACHE_VERSION: u32 = 19;
const AGGREGATE_CHECKPOINT_INTERVAL: StdDuration = StdDuration::from_secs(15 * 60);
const PRECISE_REFRESH_REUSE_INTERVAL: StdDuration = StdDuration::from_millis(250);
const PRECISE_REFRESH_RECENCY_RETENTION: StdDuration = StdDuration::from_secs(5 * 60);

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

fn precise_refresh_home(codex_home: &Path) -> Result<PathBuf, String> {
    fs::canonicalize(codex_home).map_err(|error| {
        format!(
            "精确 token refresh 无法解析 canonical Home {}：{error}",
            codex_home.display()
        )
    })
}

impl PreciseRefreshFlight {
    fn new(intent: PreciseRefreshIntent) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(PreciseRefreshFlightState {
                full_requested: intent == PreciseRefreshIntent::Full,
                full_build_started: false,
                promotion_closed: false,
                result: None,
            }),
            wake: Condvar::new(),
        })
    }

    fn is_done(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .result
            .is_some()
    }

    fn request_full(&self) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.result.is_some() || state.promotion_closed {
            return false;
        }
        if state.full_build_started {
            return true;
        }
        state.full_requested = true;
        true
    }

    fn has_full_result(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .result
            .as_ref()
            .is_some_and(|result| matches!(result.full.as_ref(), Some(Ok(_))))
    }

    fn claim_full_build_or_close(&self) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.full_requested {
            state.full_build_started = true;
            true
        } else {
            state.promotion_closed = true;
            false
        }
    }

    fn wait(&self) -> PreciseRefreshResult {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        while state.result.is_none() {
            state = self
                .wake
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        state
            .result
            .as_ref()
            .expect("precise refresh result is published before waking waiters")
            .clone()
    }
}

impl PreciseRefreshOwnerGuard {
    fn finish(&self, result: PreciseRefreshResult) {
        if self
            .state
            .finished
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            return;
        }
        finish_precise_refresh_flight(
            &self.state.coordinator,
            &self.state.flight,
            result,
        );
    }
}

impl Drop for PreciseRefreshOwnerGuard {
    fn drop(&mut self) {
        self.finish(PreciseRefreshResult::failure(
            "精确 token refresh owner 未发布结果".into(),
        ));
    }
}

fn finish_precise_refresh_flight(
    coordinator: &Arc<PreciseRefreshCoordinator>,
    flight: &Arc<PreciseRefreshFlight>,
    result: PreciseRefreshResult,
) {
    {
        let mut state = flight
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.result.is_none() {
            state.result = Some(result);
        }
        flight.wake.notify_all();
    }
    run_precise_refresh_finish_hook_for_testing();
    record_precise_refresh_attempt(&coordinator.canonical_home);

    let mut current = coordinator
        .flight
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if current
        .as_ref()
        .is_some_and(|candidate| Arc::ptr_eq(candidate, flight))
    {
        *current = None;
    }
}

fn precise_refresh_coordinator(
    codex_home: &Path,
) -> Result<Arc<PreciseRefreshCoordinator>, String> {
    let canonical_home = precise_refresh_home(codex_home)?;
    let registry = PRECISE_REFRESH_COORDINATORS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut registry = registry
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.retain(|_, coordinator| coordinator.strong_count() > 0);
    if let Some(coordinator) = registry.get(&canonical_home).and_then(Weak::upgrade) {
        return Ok(coordinator);
    }
    let coordinator = Arc::new(PreciseRefreshCoordinator {
        canonical_home: canonical_home.clone(),
        flight: Mutex::new(None),
    });
    registry.insert(canonical_home, Arc::downgrade(&coordinator));
    Ok(coordinator)
}

fn request_precise_refresh(
    codex_home: &Path,
    intent: PreciseRefreshIntent,
) -> Result<Arc<PreciseRefreshFlight>, String> {
    request_precise_refresh_inner(codex_home, intent, false)?.ok_or_else(|| {
        "精确 token refresh explicit request 未创建 flight".to_string()
    })
}

fn schedule_precise_refresh(
    codex_home: &Path,
) -> Result<Option<Arc<PreciseRefreshFlight>>, String> {
    request_precise_refresh_inner(codex_home, PreciseRefreshIntent::Summary, true)
}

fn request_precise_refresh_inner(
    codex_home: &Path,
    intent: PreciseRefreshIntent,
    enforce_reuse_window: bool,
) -> Result<Option<Arc<PreciseRefreshFlight>>, String> {
    let coordinator = precise_refresh_coordinator(codex_home)?;
    loop {
        let existing = coordinator
            .flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        if let Some(existing) = existing {
            if existing.is_done() {
                if intent == PreciseRefreshIntent::Full && existing.has_full_result() {
                    return Ok(Some(existing));
                }
                let mut current = coordinator
                    .flight
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if current
                    .as_ref()
                    .is_some_and(|candidate| Arc::ptr_eq(candidate, &existing))
                {
                    *current = None;
                }
                continue;
            }
            if intent == PreciseRefreshIntent::Full {
                let promoted = existing.request_full();
                run_precise_refresh_promotion_hook_for_testing(promoted)?;
                if !promoted {
                    existing.wait();
                    continue;
                }
            }
            return Ok(Some(existing));
        }

        let current = coordinator
            .flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if current.is_some() {
            continue;
        }
        drop(current);
        if enforce_reuse_window
            && !record_precise_refresh_attempt_if_due(&coordinator.canonical_home)
        {
            return Ok(None);
        }
        if !enforce_reuse_window {
            record_precise_refresh_attempt(&coordinator.canonical_home);
        }
        let mut current = coordinator
            .flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if current.is_some() {
            continue;
        }
        let flight = PreciseRefreshFlight::new(intent);
        *current = Some(Arc::clone(&flight));
        drop(current);
        spawn_precise_refresh_owner(Arc::clone(&coordinator), Arc::clone(&flight));
        return Ok(Some(flight));
    }
}

fn record_precise_refresh_attempt(canonical_home: &Path) {
    let recency = PRECISE_REFRESH_RECENCY.get_or_init(|| Mutex::new(HashMap::new()));
    let now = Instant::now();
    let mut recency = recency
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    recency.retain(|_, attempted_at| {
        now.duration_since(*attempted_at) < PRECISE_REFRESH_RECENCY_RETENTION
    });
    recency.insert(canonical_home.to_path_buf(), now);
}

fn record_precise_refresh_attempt_if_due(canonical_home: &Path) -> bool {
    let recency = PRECISE_REFRESH_RECENCY.get_or_init(|| Mutex::new(HashMap::new()));
    let now = Instant::now();
    let mut recency = recency
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    recency.retain(|_, attempted_at| {
        now.duration_since(*attempted_at) < PRECISE_REFRESH_RECENCY_RETENTION
    });
    if recency
        .get(canonical_home)
        .is_some_and(|attempted_at| now.duration_since(*attempted_at) < PRECISE_REFRESH_REUSE_INTERVAL)
    {
        return false;
    }
    recency.insert(canonical_home.to_path_buf(), now);
    true
}

fn spawn_precise_refresh_owner(
    coordinator: Arc<PreciseRefreshCoordinator>,
    flight: Arc<PreciseRefreshFlight>,
) {
    let owner_state = Arc::new(PreciseRefreshOwnerState {
        coordinator: Arc::clone(&coordinator),
        flight: Arc::clone(&flight),
        finished: std::sync::atomic::AtomicBool::new(false),
    });

    #[cfg(test)]
    if FAIL_NEXT_PRECISE_REFRESH_SPAWN.swap(false, std::sync::atomic::Ordering::SeqCst) {
        finish_precise_refresh_flight(
            &coordinator,
            &flight,
            PreciseRefreshResult::failure("精确 token refresh owner 线程启动失败".into()),
        );
        return;
    }

    let key = coordinator.canonical_home.clone();
    let thread_owner = Arc::clone(&owner_state);
    let spawned = std::thread::Builder::new()
        .name("codex-precise-refresh".into())
        .spawn(move || {
            let owner = PreciseRefreshOwnerGuard {
                state: thread_owner,
            };
            let result = catch_unwind(AssertUnwindSafe(|| {
                run_precise_refresh(&key, &owner.state.flight)
            }));
            match result {
                Ok(result) => owner.finish(result),
                Err(_) => owner.finish(PreciseRefreshResult::failure(
                    "精确 token refresh owner 执行异常".into(),
                )),
            }
        });
    if spawned.is_err() {
        finish_precise_refresh_flight(
            &coordinator,
            &flight,
            PreciseRefreshResult::failure("精确 token refresh owner 线程启动失败".into()),
        );
    }
}

fn run_precise_refresh(
    canonical_home: &Path,
    flight: &PreciseRefreshFlight,
) -> PreciseRefreshResult {
    let mut warnings = Vec::new();
    let mut index = match ExactUsageIndex::open(canonical_home) {
        Ok(index) => index,
        Err(error) => return PreciseRefreshResult::failure(error),
    };
    #[cfg(not(test))]
    if let Err(error) = ensure_attribution_mutation_watcher(canonical_home) {
        return PreciseRefreshResult::failure(error);
    }
    let precise_coverage_at = OffsetDateTime::now_utc();
    if let Err(error) = run_precise_refresh_sync_hook_for_testing(canonical_home) {
        return PreciseRefreshResult::failure(error);
    }
    let revision = match index.sync(canonical_home, &mut warnings) {
        Ok(revision) => revision,
        Err(error) => return PreciseRefreshResult::failure(error),
    };
    #[cfg(not(test))]
    if let Err(error) = ensure_attribution_mutation_watcher(canonical_home) {
        return PreciseRefreshResult::failure(error);
    }

    let signature = dashboard_index_signature(canonical_home, revision);
    let summary = match summary_after_precise_sync(
        &index,
        canonical_home,
        &signature,
        &warnings,
    ) {
        Ok(summary) => Ok(summary),
        Err(error) => Err(error),
    };
    if !flight.claim_full_build_or_close() {
        if let Err(error) = run_precise_refresh_after_cutoff_hook_for_testing() {
            return PreciseRefreshResult::failure(error);
        }
        return PreciseRefreshResult {
            summary,
            full: None,
        };
    }

    match build_full_dashboard_after_precise_sync(
        &mut index,
        canonical_home,
        revision,
        precise_coverage_at,
        &mut warnings,
    ) {
        Ok((snapshot, full_summary)) => PreciseRefreshResult {
            summary: if summary.is_ok() { summary } else { Ok(full_summary) },
            full: Some(Ok(snapshot)),
        },
        Err(error) => PreciseRefreshResult {
            summary,
            full: Some(Err(error)),
        },
    }
}

fn summary_after_precise_sync(
    index: &ExactUsageIndex,
    canonical_home: &Path,
    signature: &DashboardScanSignature,
    warnings: &[LocalDataWarning],
) -> Result<TokenUsageSummary, String> {
    let attribution_safety = index.attribution_safety_state()?;
    let physical_home_identity = attribution_watch_root_physical_identity(canonical_home)?;
    if let Some(summary) = cached_dashboard_aggregate(signature)
        .filter(|cached| {
            cached.persistent_binding.as_ref().map_or(true, |binding| {
                persistent_numeric_cache_binding_matches_current(
                    binding,
                    canonical_home,
                    signature,
                    &physical_home_identity,
                    &attribution_safety,
                )
            })
        })
        .map(|cached| cached.summary)
    {
        return Ok(summary);
    }
    if index.is_empty()? {
        return Err(no_token_events_error(warnings));
    }
    let local_offset = crate::core::localtime::local_offset();
    let summary = index.summary(OffsetDateTime::now_utc(), local_offset)?;
    store_usage_summary(signature.clone(), summary.clone());
    Ok(summary)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PreciseRefreshIntent {
    Summary,
    Full,
}

#[derive(Clone, Debug)]
struct PreciseRefreshResult {
    summary: Result<TokenUsageSummary, String>,
    full: Option<Result<DashboardSnapshot, String>>,
}

impl PreciseRefreshResult {
    fn failure(error: String) -> Self {
        Self {
            summary: Err(error.clone()),
            full: Some(Err(error)),
        }
    }
}

struct PreciseRefreshFlightState {
    full_requested: bool,
    full_build_started: bool,
    promotion_closed: bool,
    result: Option<PreciseRefreshResult>,
}

struct PreciseRefreshFlight {
    state: Mutex<PreciseRefreshFlightState>,
    wake: Condvar,
}

struct PreciseRefreshCoordinator {
    canonical_home: PathBuf,
    flight: Mutex<Option<Arc<PreciseRefreshFlight>>>,
}

struct PreciseRefreshOwnerState {
    coordinator: Arc<PreciseRefreshCoordinator>,
    flight: Arc<PreciseRefreshFlight>,
    finished: std::sync::atomic::AtomicBool,
}

struct PreciseRefreshOwnerGuard {
    state: Arc<PreciseRefreshOwnerState>,
}

#[cfg(test)]
pub(crate) type PreciseRefreshSyncHook = Arc<dyn Fn(&Path) -> Result<(), String> + Send + Sync>;
#[cfg(test)]
pub(crate) type PreciseRefreshCutoffHook = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;
#[cfg(test)]
pub(crate) type PreciseRefreshPromotionHook =
    Arc<dyn Fn(bool) -> Result<(), String> + Send + Sync>;
#[cfg(test)]
pub(crate) type PreciseRefreshFinishHook = Arc<dyn Fn() + Send + Sync>;

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

/// Cheap source-change probe used by the dashboard cadence. The probe only
/// enumerates the published session paths and compares filesystem metadata;
/// it never reads JSONL bodies. A full precise refresh remains the authority
/// whenever the probe cannot prove that the source is unchanged.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreciseDashboardSourceProbe {
    pub state: String,
    /// Published generations are authoritative dashboard lineage. Preserve
    /// the u64 as text at IPC so the frontend never compares rounded values.
    pub published_generation: String,
}

pub fn precise_dashboard_source_probe(
    codex_home: &Path,
) -> Result<PreciseDashboardSourceProbe, String> {
    let canonical_home = precise_refresh_home(codex_home)?;
    let mut index = ExactUsageIndex::open(&canonical_home)?;
    let published_generation = index.published_generation()?;
    let mut warnings = Vec::new();
    let changed = index.sources_changed(&canonical_home, &mut warnings)?;
    let state = if !warnings.is_empty() {
        "unknown"
    } else if changed {
        "changed"
    } else {
        "unchanged"
    };
    Ok(PreciseDashboardSourceProbe {
        state: state.into(),
        published_generation: published_generation.to_string(),
    })
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
    let flight = request_precise_refresh(codex_home, PreciseRefreshIntent::Full)?;
    flight
        .wait()
        .full
        .unwrap_or_else(|| Err("精确 token full refresh 未发布结果".into()))
}

fn build_full_dashboard_after_precise_sync(
    index: &mut ExactUsageIndex,
    codex_home: &Path,
    revision: u64,
    precise_coverage_at: OffsetDateTime,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<(DashboardSnapshot, TokenUsageSummary), String> {
    let attribution_safety = index.attribution_safety_state()?;
    let observer_identity = precise_observer_identity(codex_home)?;
    let signature = dashboard_index_signature(codex_home, revision);
    if let Some(snapshot) = cached_dashboard_snapshot_for_current(
        &signature,
        codex_home,
        &attribution_safety,
    ) {
        let summary = cached_dashboard_aggregate(&signature)
            .map(|cached| cached.summary)
            .ok_or_else(|| {
                "精确 token full refresh 缺少与完整快照对应的 summary".to_string()
            })?;
        let mut snapshot = snapshot_with_precise_coverage(
            snapshot,
            precise_coverage_at,
            &observer_identity,
            &attribution_safety,
        );
        let _ = cache_lifecycle::mark_usage_cache_ready_after_success();
        merge_usage_cache_marker_warning(&mut snapshot);
        return Ok((snapshot, summary));
    }
    if index.is_empty()? {
        return Err(no_token_events_error(warnings));
    }

    record_dashboard_aggregate_build_for_testing(codex_home);
    let now_utc = OffsetDateTime::now_utc();
    let local_offset = crate::core::localtime::local_offset();
    let data = index.dashboard_data(codex_home, now_utc, local_offset, warnings)?;
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
        warnings: warnings.clone(),
        diagnostics: Vec::new(),
    };
    let summary = data.summary;
    let persistent_binding = match persistent_numeric_cache_binding(
        codex_home,
        signature.clone(),
        &attribution_safety,
    ) {
        Ok(binding) => Some(binding),
        Err(error) => {
            snapshot.warnings.push(LocalDataWarning {
                source: "usage-cache-persistence".into(),
                message: error,
            });
            None
        }
    };
    if let Some(warning) = store_dashboard_aggregate_with_binding(
        signature,
        Some(snapshot.clone()),
        summary.clone(),
        persistent_binding,
    ) {
        snapshot.warnings.push(warning);
    }
    let _ = cache_lifecycle::mark_usage_cache_ready_after_success();
    merge_usage_cache_marker_warning(&mut snapshot);
    Ok((snapshot, summary))
}

fn usage_summary(codex_home: &Path) -> Result<TokenUsageSummary, String> {
    request_precise_refresh(codex_home, PreciseRefreshIntent::Summary)?
        .wait()
        .summary
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
    let cached = cached_dashboard_usage_summary_cache_only(codex_home);
    if let Err(error) = schedule_precise_refresh(codex_home) {
        return cached.ok_or(error);
    }
    cached.ok_or_else(|| "精确 token summary 尚未就绪，正在后台初始化".into())
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

fn cached_dashboard_usage_summary_cache_only(codex_home: &Path) -> Option<TokenUsageSummary> {
    let local_offset = crate::core::localtime::local_offset();
    let now_utc = OffsetDateTime::now_utc();
    cached_dashboard_usage_summary_at(codex_home, now_utc, local_offset).or_else(|| {
        let canonical_home = precise_refresh_home(codex_home).ok()?;
        (canonical_home != codex_home)
            .then(|| cached_dashboard_usage_summary_at(&canonical_home, now_utc, local_offset))
            .flatten()
    })
}

pub(crate) fn cached_dashboard_usage_summary(codex_home: &Path) -> Option<TokenUsageSummary> {
    let local_offset = crate::core::localtime::local_offset();
    cached_dashboard_usage_summary_cache_only(codex_home).or_else(|| {
        let canonical_home = precise_refresh_home(codex_home).ok()?;
        let index = ExactUsageIndex::open(&canonical_home).ok()?;
        if index.is_empty().ok()? {
            return None;
        }
        index.summary(OffsetDateTime::now_utc(), local_offset).ok()
    })
}

pub(crate) fn cached_dashboard_snapshot_for_startup(
    codex_home: &Path,
) -> Option<DashboardSnapshot> {
    let canonical_home = precise_refresh_home(codex_home).ok()?;
    let canonical_index = ExactUsageIndex::open(&canonical_home).ok()?;
    let revision = canonical_index.revision().ok()?;
    let attribution_safety = canonical_index.attribution_safety_state().ok()?;
    let physical_home_identity =
        attribution_watch_root_physical_identity(&canonical_home).ok()?;
    let canonical_signature = dashboard_index_signature(&canonical_home, revision);
    if let Some(snapshot) = cached_dashboard_startup_snapshot(
        &canonical_signature,
        &canonical_home,
        &attribution_safety,
        &physical_home_identity,
    ) {
        return Some(snapshot_with_generated_at(snapshot));
    }

    // V18 wrote the pre-canonical request path. It is still safe to use only
    // as a stale startup snapshot after the canonical index has been opened;
    // never open an index at this raw alias path.
    if canonical_home != codex_home {
        let raw_signature = DashboardScanSignature {
            codex_home: codex_home.to_path_buf(),
            local_date: canonical_signature.local_date.clone(),
            utc_offset_seconds: canonical_signature.utc_offset_seconds,
            index_revision: revision,
        };
        if let Some(snapshot) = cached_dashboard_startup_snapshot(
            &raw_signature,
            &canonical_home,
            &attribution_safety,
            &physical_home_identity,
        ) {
            return Some(snapshot_with_generated_at(snapshot));
        }
    }
    None
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

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistentNumericCacheBinding {
    canonical_home: PathBuf,
    physical_home_identity: String,
    signature: DashboardScanSignature,
    precise_attribution_provenance_epoch: String,
    precise_attribution_generation: u64,
    precise_attribution_unsafe_since_generation: Option<u64>,
    precise_attribution_unsafe_id: Option<String>,
    precise_attribution_current_scan_unsafe: bool,
    precise_attribution_current_scan_incomplete: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistentNumericDashboardCacheV19 {
    version: u32,
    #[serde(flatten)]
    binding: PersistentNumericCacheBinding,
    built_at: String,
    coverage_at: Option<String>,
    summary: TokenUsageSummary,
    stats: crate::models::DashboardStats,
    activity_days: Vec<crate::models::ActivityDay>,
    recent_usage_24h: Vec<PersistentNumericRecentUsagePoint>,
    recent_usage_7d: Vec<PersistentNumericRecentUsagePoint>,
    recent_usage_30d: Vec<PersistentNumericRecentUsagePoint>,
}

/// Persistence DTO deliberately has no source attribution fields. Reusing
/// `RecentUsagePoint` here would serialize nullable/empty provenance fields and
/// make a future model-field addition an accidental cache privacy expansion.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistentNumericRecentUsagePoint {
    label: String,
    start_unix: i64,
    tokens: u64,
    calls: u32,
    input_tokens: u64,
    cached_input_tokens: u64,
    output_tokens: u64,
    #[serde(default)]
    model_breakdowns: Vec<crate::models::ModelTokenBreakdown>,
    cache_hit_rate: Option<f64>,
    five_hour_remaining_percent: Option<f64>,
    seven_day_remaining_percent: Option<f64>,
}

#[derive(Clone, Debug)]
struct CachedDashboardAggregate {
    signature: DashboardScanSignature,
    snapshot: Option<DashboardSnapshot>,
    summary: TokenUsageSummary,
    snapshot_complete: bool,
    persistent_version: u32,
    persistent_binding: Option<PersistentNumericCacheBinding>,
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
        .filter(|cached| {
            let Some(binding) = cached.persistent_binding.as_ref() else {
                return true;
            };
            let Ok(canonical_home) = precise_refresh_home(codex_home) else {
                return false;
            };
            let Ok(physical_home_identity) =
                attribution_watch_root_physical_identity(&canonical_home)
            else {
                return false;
            };
            binding.canonical_home == canonical_home
                && binding.physical_home_identity == physical_home_identity
        })
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

fn persistent_numeric_cache_binding(
    canonical_home: &Path,
    signature: DashboardScanSignature,
    attribution_safety: &exact_usage_index::AttributionSafetyState,
) -> Result<PersistentNumericCacheBinding, String> {
    let canonical_home = precise_refresh_home(canonical_home)?;
    let physical_home_identity = attribution_watch_root_physical_identity(&canonical_home)?;
    Ok(PersistentNumericCacheBinding {
        canonical_home: canonical_home.clone(),
        physical_home_identity,
        signature,
        precise_attribution_provenance_epoch: attribution_safety.provenance_epoch.clone(),
        precise_attribution_generation: attribution_safety.generation,
        precise_attribution_unsafe_since_generation: attribution_safety.unsafe_since_generation,
        precise_attribution_unsafe_id: attribution_safety.unsafe_id.clone(),
        precise_attribution_current_scan_unsafe: attribution_safety
            .current_scan_unsafe_cause_detected,
        precise_attribution_current_scan_incomplete: attribution_safety.current_scan_incomplete,
    })
}

fn persistent_numeric_cache_binding_is_well_formed(
    binding: &PersistentNumericCacheBinding,
) -> bool {
    let Ok(canonical_home) = precise_refresh_home(&binding.canonical_home) else {
        return false;
    };
    if canonical_home != binding.canonical_home
        || binding.signature.codex_home != binding.canonical_home
        || binding.signature.local_date.trim().is_empty()
        || binding.physical_home_identity.trim().is_empty()
        || binding.precise_attribution_provenance_epoch.trim().is_empty()
    {
        return false;
    }
    if binding
        .precise_attribution_unsafe_id
        .as_deref()
        .is_some_and(|unsafe_id| Uuid::parse_str(unsafe_id).is_err())
    {
        return false;
    }
    attribution_watch_root_physical_identity(&binding.canonical_home)
        .is_ok_and(|identity| identity == binding.physical_home_identity)
}

fn persistent_numeric_cache_binding_matches_current(
    binding: &PersistentNumericCacheBinding,
    canonical_home: &Path,
    signature: &DashboardScanSignature,
    physical_home_identity: &str,
    attribution_safety: &exact_usage_index::AttributionSafetyState,
) -> bool {
    binding.canonical_home == canonical_home
        && binding.physical_home_identity == physical_home_identity
        && binding.signature == *signature
        && binding.precise_attribution_provenance_epoch == attribution_safety.provenance_epoch
        && binding.precise_attribution_generation == attribution_safety.generation
        && binding.precise_attribution_unsafe_since_generation
            == attribution_safety.unsafe_since_generation
        && binding.precise_attribution_unsafe_id == attribution_safety.unsafe_id
        && binding.precise_attribution_current_scan_unsafe
            == attribution_safety.current_scan_unsafe_cause_detected
        && binding.precise_attribution_current_scan_incomplete
            == attribution_safety.current_scan_incomplete
}

fn sanitize_numeric_recent_usage_points(
    points: &mut [crate::models::RecentUsagePoint],
) {
    for point in points {
        point.source_contribution_epoch = None;
        point.source_contributions.clear();
    }
}

fn startup_snapshot_from_persistent_numeric(
    cache: &PersistentNumericDashboardCacheV19,
) -> DashboardSnapshot {
    let recent_usage_24h = restore_persistent_numeric_recent_usage_points(&cache.recent_usage_24h);
    let recent_usage_7d = restore_persistent_numeric_recent_usage_points(&cache.recent_usage_7d);
    let recent_usage_30d = restore_persistent_numeric_recent_usage_points(&cache.recent_usage_30d);
    DashboardSnapshot {
        generated_at: cache.built_at.clone(),
        precise_recent_usage_covered_at: cache.coverage_at.clone(),
        precise_recent_usage_fresh: false,
        precise_observer_epoch: None,
        precise_observer_started_at_unix_micros: None,
        precise_observer_sequence: None,
        precise_attribution_provenance_epoch: None,
        precise_attribution_generation: None,
        precise_attribution_unsafe_since_generation: None,
        precise_attribution_unsafe_id: None,
        precise_attribution_current_scan_unsafe: false,
        account: AccountInfo {
            display_name: "账户待读取".into(),
            plan_label: "计划待读取".into(),
        },
        stats: cache.stats.clone(),
        quota: placeholder_quota(),
        activity_days: cache.activity_days.clone(),
        recent_usage_24h,
        recent_usage_7d,
        recent_usage_30d,
        cache_hit_ranking: Vec::new(),
        cache_usage: Default::default(),
        warnings: Vec::new(),
        diagnostics: Vec::new(),
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

fn cached_dashboard_snapshot_for_current(
    signature: &DashboardScanSignature,
    canonical_home: &Path,
    attribution_safety: &exact_usage_index::AttributionSafetyState,
) -> Option<DashboardSnapshot> {
    let physical_home_identity = attribution_watch_root_physical_identity(canonical_home).ok()?;
    cached_dashboard_aggregate(signature)
        .filter(|cached| cached.snapshot_complete)
        .filter(|cached| {
            cached.persistent_binding.as_ref().map_or(true, |binding| {
                persistent_numeric_cache_binding_matches_current(
                    binding,
                    canonical_home,
                    signature,
                    &physical_home_identity,
                    attribution_safety,
                )
            })
        })
        .and_then(|cached| cached.snapshot)
}

fn cached_dashboard_startup_snapshot(
    signature: &DashboardScanSignature,
    canonical_home: &Path,
    attribution_safety: &exact_usage_index::AttributionSafetyState,
    physical_home_identity: &str,
) -> Option<DashboardSnapshot> {
    hydrate_dashboard_aggregate_cache_once();
    DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()))
        .lock()
        .ok()
        .and_then(|guard| guard.aggregate.clone())
        .filter(|cached| {
            if cached.persistent_version == DASHBOARD_AGGREGATE_CACHE_VERSION
                || cached.persistent_version == 0
            {
                cached.signature == *signature
                    && cached.persistent_binding.as_ref().is_some_and(|binding| {
                        persistent_numeric_cache_binding_matches_current(
                            binding,
                            canonical_home,
                            signature,
                            physical_home_identity,
                            attribution_safety,
                        )
                    })
            } else {
                // Legacy V16-V18 have no physical/binding proof. The caller
                // must supply the exact expected signature, including Home,
                // local date, UTC offset, and index revision. The alias
                // fallback constructs its raw signature explicitly, so this
                // equality cannot bypass the Home or revision contract.
                cached.signature == *signature
            }
        })
        .and_then(|cached| cached.snapshot.map(sanitize_legacy_snapshot_for_startup))
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
    let existing_binding = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()))
        .lock()
        .ok()
        .and_then(|guard| {
            guard
                .aggregate
                .as_ref()
                .filter(|cached| cached.signature == signature)
                .and_then(|cached| cached.persistent_binding.clone())
        });
    #[cfg(test)]
    let needs_test_binding = snapshot.is_none();
    #[cfg(test)]
    let snapshot = snapshot.or_else(|| Some(persistent_numeric_test_snapshot(&summary)));
    #[cfg(test)]
    let persistent_binding = if needs_test_binding {
        Some(persistent_numeric_test_binding(&signature))
    } else {
        existing_binding
    };
    #[cfg(not(test))]
    let persistent_binding = existing_binding;
    store_dashboard_aggregate_with_binding(signature, snapshot, summary, persistent_binding)
}

fn store_dashboard_aggregate_with_binding(
    signature: DashboardScanSignature,
    snapshot: Option<DashboardSnapshot>,
    summary: TokenUsageSummary,
    persistent_binding: Option<PersistentNumericCacheBinding>,
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
        persistent_version: 0,
        persistent_binding,
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

#[cfg(test)]
fn persistent_numeric_test_binding(
    signature: &DashboardScanSignature,
) -> PersistentNumericCacheBinding {
    let _ = fs::create_dir_all(&signature.codex_home);
    let canonical_home = precise_refresh_home(&signature.codex_home)
        .unwrap_or_else(|_| signature.codex_home.clone());
    let mut canonical_signature = signature.clone();
    canonical_signature.codex_home = canonical_home.clone();
    let physical_home_identity =
        attribution_watch_root_physical_identity(&canonical_home).unwrap_or_default();
    PersistentNumericCacheBinding {
        canonical_home,
        physical_home_identity,
        signature: canonical_signature,
        precise_attribution_provenance_epoch: Uuid::nil().to_string(),
        precise_attribution_generation: 0,
        precise_attribution_unsafe_since_generation: None,
        precise_attribution_unsafe_id: None,
        precise_attribution_current_scan_unsafe: false,
        precise_attribution_current_scan_incomplete: false,
    }
}

#[cfg(test)]
fn persistent_numeric_test_snapshot(summary: &TokenUsageSummary) -> DashboardSnapshot {
    DashboardSnapshot {
        generated_at: OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into()),
        precise_recent_usage_covered_at: None,
        precise_recent_usage_fresh: false,
        precise_observer_epoch: None,
        precise_observer_started_at_unix_micros: None,
        precise_observer_sequence: None,
        precise_attribution_provenance_epoch: None,
        precise_attribution_generation: None,
        precise_attribution_unsafe_since_generation: None,
        precise_attribution_unsafe_id: None,
        precise_attribution_current_scan_unsafe: false,
        account: AccountInfo {
            display_name: "账户待读取".into(),
            plan_label: "计划待读取".into(),
        },
        stats: crate::models::DashboardStats {
            total_tokens: summary.total_tokens,
            peak_day_tokens: summary.today_tokens,
            peak_thread_tokens: summary.today_tokens,
            current_streak_days: 0,
            longest_streak_days: 0,
            total_calls: summary.today_requests,
            total_threads: 0,
            total_input_tokens: 0,
            total_cached_input_tokens: 0,
            total_output_tokens: 0,
            model_breakdowns: Vec::new(),
            first_usage_at: None,
        },
        quota: placeholder_quota(),
        activity_days: Vec::new(),
        recent_usage_24h: Vec::new(),
        recent_usage_7d: Vec::new(),
        recent_usage_30d: Vec::new(),
        cache_hit_ranking: Vec::new(),
        cache_usage: Default::default(),
        warnings: Vec::new(),
        diagnostics: Vec::new(),
    }
}

fn store_usage_summary(signature: DashboardScanSignature, summary: TokenUsageSummary) {
    // A summary refresh may run after a full V19 publish. Hydrate first so the
    // existing binding is carried forward instead of silently downgrading the
    // in-memory aggregate to an unbound snapshot.
    hydrate_dashboard_aggregate_cache_once();
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
    let metadata = fs::symlink_metadata(&path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let data = fs::read(path).ok()?;
    decode_persistent_dashboard_aggregate(&data)
}

fn decode_persistent_dashboard_aggregate(data: &[u8]) -> Option<CachedDashboardAggregate> {
    let version = serde_json::from_slice::<serde_json::Value>(data)
        .ok()?
        .get("version")
        .and_then(serde_json::Value::as_u64)
        .and_then(|version| u32::try_from(version).ok())?;
    match version {
        DASHBOARD_AGGREGATE_CACHE_VERSION => {
            let cache = serde_json::from_slice::<PersistentNumericDashboardCacheV19>(data).ok()?;
            if cache.version != DASHBOARD_AGGREGATE_CACHE_VERSION
                || !persistent_numeric_cache_binding_is_well_formed(&cache.binding)
                || !valid_persistent_cache_timestamp(&cache.built_at)
                || cache
                    .coverage_at
                    .as_deref()
                    .is_some_and(|value| !valid_persistent_cache_timestamp(value))
            {
                return None;
            }
            let snapshot = startup_snapshot_from_persistent_numeric(&cache);
            Some(CachedDashboardAggregate {
                signature: cache.binding.signature.clone(),
                snapshot: Some(snapshot),
                summary: cache.summary,
                snapshot_complete: false,
                persistent_version: DASHBOARD_AGGREGATE_CACHE_VERSION,
                persistent_binding: Some(cache.binding),
            })
        }
        LEGACY_DASHBOARD_AGGREGATE_CACHE_V16
        | LEGACY_DASHBOARD_AGGREGATE_CACHE_V17
        | LEGACY_DASHBOARD_AGGREGATE_CACHE_VERSION => {
            let cache = serde_json::from_slice::<PersistentDashboardAggregateCache>(data).ok()?;
            if !matches!(
                cache.version,
                LEGACY_DASHBOARD_AGGREGATE_CACHE_V16
                    | LEGACY_DASHBOARD_AGGREGATE_CACHE_V17
                    | LEGACY_DASHBOARD_AGGREGATE_CACHE_VERSION
            ) {
                return None;
            }
            Some(CachedDashboardAggregate {
                signature: cache.signature,
                snapshot: cache.snapshot.map(sanitize_legacy_snapshot_for_startup),
                summary: cache.summary,
                snapshot_complete: false,
                persistent_version: cache.version,
                persistent_binding: None,
            })
        }
        _ => None,
    }
}

fn valid_persistent_cache_timestamp(value: &str) -> bool {
    OffsetDateTime::parse(value, &Rfc3339).is_ok()
}

fn save_persistent_dashboard_aggregate(aggregate: &CachedDashboardAggregate) -> Result<(), String> {
    let Some(path) = app_paths::token_aggregate_cache_path() else {
        return Ok(());
    };
    let (Some(binding), Some(snapshot)) = (
        aggregate.persistent_binding.as_ref(),
        aggregate.snapshot.as_ref(),
    ) else {
        return Ok(());
    };
    if !persistent_numeric_cache_binding_is_well_formed(binding) {
        return Err("persistent numeric dashboard cache binding is not trustworthy".into());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "create aggregate cache directory {}: {error}",
                parent.display()
            )
        })?;
    }
    if !aggregate_checkpoint_due_with_binding(
        &path,
        &binding.signature,
        Some(binding),
        SystemTime::now(),
    ) {
        return Ok(());
    }
    let payload = PersistentNumericDashboardCacheV19 {
        version: DASHBOARD_AGGREGATE_CACHE_VERSION,
        binding: binding.clone(),
        built_at: snapshot.generated_at.clone(),
        coverage_at: snapshot.precise_recent_usage_covered_at.clone(),
        summary: aggregate.summary.clone(),
        stats: snapshot.stats.clone(),
        activity_days: snapshot.activity_days.clone(),
        recent_usage_24h: persistent_numeric_recent_usage_points(&snapshot.recent_usage_24h),
        recent_usage_7d: persistent_numeric_recent_usage_points(&snapshot.recent_usage_7d),
        recent_usage_30d: persistent_numeric_recent_usage_points(&snapshot.recent_usage_30d),
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
    aggregate_checkpoint_due_with_binding(path, signature, None, now)
}

fn aggregate_checkpoint_due_with_binding(
    path: &Path,
    signature: &DashboardScanSignature,
    binding: Option<&PersistentNumericCacheBinding>,
    now: SystemTime,
) -> bool {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return true;
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return true;
    }
    let Some(data) = fs::read(path).ok() else {
        return true;
    };
    let Some(version) = serde_json::from_slice::<serde_json::Value>(&data)
        .ok()
        .and_then(|value| value.get("version").and_then(serde_json::Value::as_u64))
        .and_then(|version| u32::try_from(version).ok())
    else {
        return true;
    };
    if version != DASHBOARD_AGGREGATE_CACHE_VERSION {
        return true;
    }
    let Ok(existing) = serde_json::from_slice::<PersistentNumericDashboardCacheV19>(&data) else {
        return true;
    };
    if existing.binding.signature != *signature
        || binding.is_some_and(|binding| &existing.binding != binding)
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
    let same_regular_file = fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && !metadata.file_type().is_symlink())
        && fs::read(path).is_ok_and(|existing| existing == data);
    if same_regular_file {
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

fn persistent_numeric_recent_usage_points(
    points: &[crate::models::RecentUsagePoint],
) -> Vec<PersistentNumericRecentUsagePoint> {
    points
        .iter()
        .map(|point| PersistentNumericRecentUsagePoint {
            label: point.label.clone(),
            start_unix: point.start_unix,
            tokens: point.tokens,
            calls: point.calls,
            input_tokens: point.input_tokens,
            cached_input_tokens: point.cached_input_tokens,
            output_tokens: point.output_tokens,
            model_breakdowns: point.model_breakdowns.clone(),
            cache_hit_rate: point.cache_hit_rate,
            five_hour_remaining_percent: point.five_hour_remaining_percent,
            seven_day_remaining_percent: point.seven_day_remaining_percent,
        })
        .collect()
}

fn restore_persistent_numeric_recent_usage_points(
    points: &[PersistentNumericRecentUsagePoint],
) -> Vec<crate::models::RecentUsagePoint> {
    points
        .iter()
        .map(|point| crate::models::RecentUsagePoint {
            label: point.label.clone(),
            start_unix: point.start_unix,
            tokens: point.tokens,
            calls: point.calls,
            input_tokens: point.input_tokens,
            cached_input_tokens: point.cached_input_tokens,
            output_tokens: point.output_tokens,
            model_breakdowns: point.model_breakdowns.clone(),
            cache_hit_rate: point.cache_hit_rate,
            five_hour_remaining_percent: point.five_hour_remaining_percent,
            seven_day_remaining_percent: point.seven_day_remaining_percent,
            source_contribution_epoch: None,
            source_contributions: Vec::new(),
        })
        .collect()
}

fn sanitize_legacy_snapshot_for_startup(mut snapshot: DashboardSnapshot) -> DashboardSnapshot {
    snapshot.account = AccountInfo {
        display_name: "账户待读取".into(),
        plan_label: "计划待读取".into(),
    };
    snapshot.quota = placeholder_quota();
    sanitize_numeric_recent_usage_points(&mut snapshot.recent_usage_24h);
    sanitize_numeric_recent_usage_points(&mut snapshot.recent_usage_7d);
    sanitize_numeric_recent_usage_points(&mut snapshot.recent_usage_30d);
    snapshot.cache_hit_ranking.clear();
    snapshot.cache_usage = Default::default();
    snapshot.warnings.clear();
    snapshot.diagnostics.clear();
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
        let Ok(canonical_home) = precise_refresh_home(_codex_home) else {
            return;
        };
        let counts = DASHBOARD_AGGREGATE_BUILD_COUNT.get_or_init(|| Mutex::new(HashMap::new()));
        if let Ok(mut counts) = counts.lock() {
            *counts.entry(canonical_home).or_default() += 1;
        }
    }
}

fn record_dashboard_source_scan_for_testing() {
    #[cfg(test)]
    DASHBOARD_SCAN_SIGNATURE_COUNT.fetch_add(1, Ordering::Relaxed);
}

#[cfg(test)]
fn run_precise_refresh_sync_hook_for_testing(path: &Path) -> Result<(), String> {
    PRECISE_REFRESH_SYNC_CALL_COUNT.fetch_add(1, Ordering::SeqCst);
    let hook = PRECISE_REFRESH_SYNC_HOOK
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    if let Some(hook) = hook.as_ref() {
        hook(path)?;
    }
    Ok(())
}

#[cfg(not(test))]
fn run_precise_refresh_sync_hook_for_testing(_path: &Path) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
fn run_precise_refresh_after_cutoff_hook_for_testing() -> Result<(), String> {
    let hook = PRECISE_REFRESH_AFTER_CUTOFF_HOOK
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    if let Some(hook) = hook.as_ref() {
        hook()?;
    }
    Ok(())
}

#[cfg(test)]
fn run_precise_refresh_promotion_hook_for_testing(promoted: bool) -> Result<(), String> {
    let hook = PRECISE_REFRESH_PROMOTION_HOOK
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    if let Some(hook) = hook.as_ref() {
        hook(promoted)?;
    }
    Ok(())
}

#[cfg(not(test))]
fn run_precise_refresh_promotion_hook_for_testing(_promoted: bool) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
fn run_precise_refresh_finish_hook_for_testing() {
    let hook = PRECISE_REFRESH_FINISH_HOOK
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    if let Some(hook) = hook.as_ref() {
        hook();
    }
}

#[cfg(not(test))]
fn run_precise_refresh_finish_hook_for_testing() {}

#[cfg(not(test))]
fn run_precise_refresh_after_cutoff_hook_for_testing() -> Result<(), String> {
    Ok(())
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
    let recency = PRECISE_REFRESH_RECENCY.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut recency) = recency.lock() {
        recency.clear();
    }
    DASHBOARD_SCAN_SIGNATURE_COUNT.store(0, Ordering::Relaxed);
    PRECISE_REFRESH_SYNC_CALL_COUNT.store(0, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_precise_refresh_recency_for_testing() {
    let recency = PRECISE_REFRESH_RECENCY.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut recency) = recency.lock() {
        recency.clear();
    }
}

#[cfg(test)]
fn wait_for_usage_summary_refreshes_for_testing() {
    for _ in 0..250 {
        let coordinators = PRECISE_REFRESH_COORDINATORS
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .map(|registry| {
                registry
                    .values()
                    .filter_map(Weak::upgrade)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let idle = coordinators.iter().all(|coordinator| {
            coordinator
                .flight
                .lock()
                .map(|flight| flight.is_none())
                .unwrap_or(false)
        });
        if idle {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    panic!("usage summary background refresh did not quiesce before test reset");
}

#[cfg(test)]
pub(crate) fn set_precise_refresh_sync_hook_for_testing(
    hook: Option<PreciseRefreshSyncHook>,
) {
    let slot = PRECISE_REFRESH_SYNC_HOOK.get_or_init(|| Mutex::new(None));
    *slot
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
}

#[cfg(test)]
pub(crate) fn set_precise_refresh_after_cutoff_hook_for_testing(
    hook: Option<PreciseRefreshCutoffHook>,
) {
    let slot = PRECISE_REFRESH_AFTER_CUTOFF_HOOK.get_or_init(|| Mutex::new(None));
    *slot
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
}

#[cfg(test)]
pub(crate) fn set_precise_refresh_promotion_hook_for_testing(
    hook: Option<PreciseRefreshPromotionHook>,
) {
    let slot = PRECISE_REFRESH_PROMOTION_HOOK.get_or_init(|| Mutex::new(None));
    *slot
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
}

#[cfg(test)]
pub(crate) fn set_precise_refresh_finish_hook_for_testing(hook: Option<PreciseRefreshFinishHook>) {
    let slot = PRECISE_REFRESH_FINISH_HOOK.get_or_init(|| Mutex::new(None));
    *slot
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
}

#[cfg(test)]
pub(crate) fn precise_refresh_sync_call_count_for_testing() -> usize {
    PRECISE_REFRESH_SYNC_CALL_COUNT.load(Ordering::SeqCst)
}

#[cfg(test)]
pub(crate) fn fail_next_precise_refresh_spawn_for_testing() {
    FAIL_NEXT_PRECISE_REFRESH_SPAWN.store(true, Ordering::SeqCst);
}

#[cfg(test)]
pub(crate) fn precise_refresh_coordinator_registry_len_for_testing() -> usize {
    let registry = PRECISE_REFRESH_COORDINATORS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut registry = registry
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.retain(|_, coordinator| coordinator.strong_count() > 0);
    registry.len()
}

#[cfg(test)]
pub(crate) fn dashboard_aggregate_build_count_for_testing(codex_home: &Path) -> usize {
    let counts = DASHBOARD_AGGREGATE_BUILD_COUNT.get_or_init(|| Mutex::new(HashMap::new()));
    let Ok(canonical_home) = precise_refresh_home(codex_home) else {
        return 0;
    };
    counts
        .lock()
        .ok()
        .and_then(|counts| counts.get(&canonical_home).copied())
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
