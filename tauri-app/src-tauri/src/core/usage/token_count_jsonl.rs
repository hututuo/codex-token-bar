use super::cache_lifecycle;
use crate::core::app_paths;
use crate::core::startup_trace;
use crate::models::PreciseDashboardProgress;
use crate::models::{
    AccountInfo, DashboardSnapshot, LocalDataWarning, ModelTokenBreakdown, QuotaLimit,
    QuotaSnapshot, ResetCreditSummary,
};
use notify::event::ModifyKind;
use notify::{
    Event as NotifyEvent, EventKind as NotifyEventKind, RecommendedWatcher, RecursiveMode, Watcher,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
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
static SESSION_CATALOG_BUILD_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static USAGE_SUMMARY_CACHE: OnceLock<Mutex<Option<CachedUsageSummary>>> = OnceLock::new();
static PRECISE_REFRESH_COORDINATORS: OnceLock<
    Mutex<HashMap<PreciseRefreshHomeKey, Arc<PreciseRefreshCoordinator>>>,
> = OnceLock::new();
static PRECISE_INDEX_PROGRESS: OnceLock<Mutex<HashMap<PreciseProgressKey, PreciseDashboardProgress>>> =
    OnceLock::new();
static PRECISE_REFRESH_FLIGHT_SEQUENCE: AtomicU64 = AtomicU64::new(1);
static PRECISE_PROCESS_OBSERVER_IDENTITY: OnceLock<PreciseObserverIdentity> = OnceLock::new();
static ATTRIBUTION_MUTATION_WATCHERS: OnceLock<
    Mutex<HashMap<PathBuf, AttributionMutationWatcher>>,
> = OnceLock::new();
static ATTRIBUTION_MARKER_WRITE_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static ATTRIBUTION_WATCHER_FAILURES: OnceLock<Mutex<HashMap<PathBuf, String>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_AGGREGATE_BUILD_COUNT: OnceLock<Mutex<HashMap<PathBuf, usize>>> = OnceLock::new();
#[cfg(test)]
static DASHBOARD_SCAN_SIGNATURE_COUNT: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static PRECISE_REFRESH_SYNC_CALL_COUNT: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static PRECISE_REFRESH_SYNC_HOOK: OnceLock<Mutex<Option<PreciseRefreshSyncHook>>> = OnceLock::new();
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
// V20 invalidates the V19 local-day projection cache. V19 used one fixed
// current UTC offset for all historical events, which is wrong across DST or
// a timezone change. Rebuilding this disposable cache reads the exact SQLite
// events only; it never rescans JSONL bodies.
const DASHBOARD_AGGREGATE_CACHE_VERSION: u32 = 20;
const AGGREGATE_CHECKPOINT_INTERVAL: StdDuration = StdDuration::from_secs(15 * 60);
const PRECISE_SUMMARY_REFRESH_TTL: StdDuration = StdDuration::from_secs(3 * 60);
const PRECISE_SUMMARY_FAILURE_RETRY_INTERVAL: StdDuration = StdDuration::from_secs(30);
const PRECISE_REFRESH_COMPLETED_OWNER_WINDOW: StdDuration = StdDuration::from_secs(5 * 60);
const PRECISE_SCAN_ESTIMATE_TIMEOUT: StdDuration = StdDuration::from_secs(10);

thread_local! {
    // A refresh owner keeps the physical Home identity it started with.  If a
    // directory is replaced at the same path while that owner is unwinding,
    // its late progress updates must not overwrite the replacement owner's
    // slot.
    static ACTIVE_PRECISE_PROGRESS_KEY: std::cell::RefCell<Option<PreciseProgressKey>> =
        const { std::cell::RefCell::new(None) };
}

fn precise_progress_now() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct PreciseProgressKey {
    canonical_home: PathBuf,
    physical_home_identity: Option<String>,
}

fn precise_progress_key(codex_home: &Path) -> PreciseProgressKey {
    let canonical_home = fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf());
    let physical_home_identity =
        attribution_watch_root_physical_identity(&canonical_home).ok();
    PreciseProgressKey {
        canonical_home,
        physical_home_identity,
    }
}

fn active_or_current_progress_key(codex_home: &Path) -> PreciseProgressKey {
    let canonical_home = fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf());
    ACTIVE_PRECISE_PROGRESS_KEY.with(|slot| {
        slot.borrow()
            .as_ref()
            .filter(|key| key.canonical_home == canonical_home)
            .cloned()
            .unwrap_or_else(|| precise_progress_key(&canonical_home))
    })
}

fn precise_progress_fraction(completed: u64, total: Option<u64>) -> Option<f64> {
    let total = total.filter(|value| *value > 0)?;
    Some((completed as f64 / total as f64).clamp(0.0, 1.0))
}

fn idle_precise_dashboard_progress() -> PreciseDashboardProgress {
    let now = precise_progress_now();
    PreciseDashboardProgress {
        phase: "idle".into(),
        message: "等待精确统计".into(),
        completed: 0,
        total: None,
        fraction: None,
        started_at: now.clone(),
        updated_at: now,
    }
}

pub(crate) fn precise_dashboard_progress(codex_home: &Path) -> PreciseDashboardProgress {
    let key = active_or_current_progress_key(codex_home);
    PRECISE_INDEX_PROGRESS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&key)
        .cloned()
        .unwrap_or_else(idle_precise_dashboard_progress)
}

pub(crate) fn begin_precise_dashboard_progress(codex_home: &Path) {
    let now = precise_progress_now();
    let key = precise_progress_key(codex_home);
    ACTIVE_PRECISE_PROGRESS_KEY.with(|slot| {
        *slot.borrow_mut() = Some(key.clone());
    });
    let progress = PreciseDashboardProgress {
        phase: "preparing".into(),
        message: "正在计算索引规模，可能需要数分钟".into(),
        completed: 0,
        total: None,
        fraction: None,
        started_at: now.clone(),
        updated_at: now,
    };
    PRECISE_INDEX_PROGRESS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(key, progress);
}

fn update_precise_dashboard_progress_for_key(
    key: PreciseProgressKey,
    phase: &str,
    message: impl Into<String>,
    completed: u64,
    total: Option<u64>,
) {
    let mut states = PRECISE_INDEX_PROGRESS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let started_at = states
        .get(&key)
        .map(|state| state.started_at.clone())
        .unwrap_or_else(precise_progress_now);
    let clamped_completed = total.map_or(completed, |value| completed.min(value));
    states.insert(
        key,
        PreciseDashboardProgress {
            phase: phase.into(),
            message: message.into(),
            completed: clamped_completed,
            total,
            fraction: precise_progress_fraction(clamped_completed, total),
            started_at,
            updated_at: precise_progress_now(),
        },
    );
}

pub(crate) fn update_precise_dashboard_progress(
    codex_home: &Path,
    phase: &str,
    message: impl Into<String>,
    completed: u64,
    total: Option<u64>,
) {
    update_precise_dashboard_progress_for_key(
        active_or_current_progress_key(codex_home),
        phase,
        message,
        completed,
        total,
    );
}

pub(crate) fn finish_precise_dashboard_progress(
    codex_home: &Path,
    succeeded: bool,
    message: impl Into<String>,
) {
    let key = active_or_current_progress_key(codex_home);
    let current = PRECISE_INDEX_PROGRESS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&key)
        .cloned()
        .unwrap_or_else(idle_precise_dashboard_progress);
    let completed = if succeeded {
        current.total.unwrap_or(current.completed)
    } else {
        current.completed
    };
    update_precise_dashboard_progress_for_key(
        key,
        if succeeded { "complete" } else { "failed" },
        message,
        completed,
        current.total,
    );
    ACTIVE_PRECISE_PROGRESS_KEY.with(|slot| {
        *slot.borrow_mut() = None;
    });
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct PreciseRefreshHomeKey {
    canonical_home: PathBuf,
    physical_home_identity: String,
}

#[derive(Clone, Debug, Default)]
struct PreciseRefreshScheduleState {
    last_attempt_at: Option<Instant>,
    last_success_at: Option<Instant>,
    last_error: Option<String>,
}

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
        fs::create_dir_all(parent)
            .map_err(|error| format!("无法创建本地用量连续性目录 {}：{error}", parent.display()))?;
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

fn mutation_event_touches_exact_source(codex_home: &Path, event: &NotifyEvent) -> bool {
    event.need_rescan()
        || event
            .paths
            .iter()
            .any(|path| is_monitored_exact_source_path(codex_home, path))
}

fn mark_precise_refresh_source_dirty(codex_home: &Path) {
    let Ok(canonical_home) = precise_refresh_home(codex_home) else {
        return;
    };
    let Ok(physical_home_identity) =
        attribution_watch_root_physical_identity(&canonical_home)
    else {
        return;
    };
    let key = PreciseRefreshHomeKey {
        canonical_home,
        physical_home_identity,
    };
    let coordinator = PRECISE_REFRESH_COORDINATORS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&key)
        .cloned();
    if let Some(coordinator) = coordinator {
        coordinator.source_revision.fetch_add(1, Ordering::SeqCst);
    }
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
    let canonical_home = fs::canonicalize(codex_home)
        .map_err(|error| format!("无法确认本地用量监听目录 {}：{error}", codex_home.display()))?;
    let callback_home = canonical_home.clone();
    let mut watcher = notify::recommended_watcher(move |result: notify::Result<NotifyEvent>| {
        if let Ok(event) = result.as_ref() {
            if mutation_event_touches_exact_source(&callback_home, event) {
                mark_precise_refresh_source_dirty(&callback_home);
            }
        }
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
    let canonical_home = fs::canonicalize(codex_home)
        .map_err(|error| format!("无法确认本地用量监听目录 {}：{error}", codex_home.display()))?;
    let physical_home_identity = attribution_watch_root_physical_identity(&canonical_home)?;
    let watchers = ATTRIBUTION_MUTATION_WATCHERS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut watchers = watchers
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    watchers.retain(|path, _| path.exists());
    if watchers
        .get(&canonical_home)
        .is_some_and(|entry| entry.physical_home_identity == physical_home_identity)
    {
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
        if let Err(error) = write_attribution_continuity_unsafe_marker(&canonical_home, reason) {
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
    fn new(
        intent: PreciseRefreshIntent,
        after_summary_only: bool,
        summary_gap_ms: Option<u64>,
        summary_previous_flight_id: Option<u64>,
        source_revision_at_start: u64,
        reusable_summary_sync: Option<PreciseSummarySyncReceipt>,
    ) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(PreciseRefreshFlightState {
                full_requested: intent == PreciseRefreshIntent::Full,
                full_build_started: false,
                promotion_closed: false,
                summary_result: None,
                result: None,
            }),
            wake: Condvar::new(),
            trace: Mutex::new(PreciseRefreshTrace::new(
                intent,
                after_summary_only,
                summary_gap_ms,
                summary_previous_flight_id,
            )),
            trace_finished: std::sync::atomic::AtomicBool::new(false),
            source_revision_at_start,
            reusable_summary_sync,
            completed_sync: Mutex::new(None),
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
        let promoted_from_summary = self.trace_intent() == PreciseRefreshIntent::Summary;
        state.full_requested = true;
        if promoted_from_summary {
            self.mark_trace_promoted();
        }
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
        let claimed = if state.full_requested {
            state.full_build_started = true;
            true
        } else {
            state.promotion_closed = true;
            false
        };
        self.set_trace_claim(claimed);
        claimed
    }

    fn trace_intent(&self) -> PreciseRefreshIntent {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .intent
    }

    fn mark_trace_promoted(&self) {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .promoted_to_full = true;
    }

    fn set_trace_claim(&self, claimed: bool) {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .claim_full = Some(claimed);
    }

    fn set_trace_status(&self, status: &'static str) {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .status = status;
    }

    fn trace_status(&self) -> &'static str {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .status
    }

    fn record_trace_stage(&self, stage: PreciseRefreshTraceStage, elapsed: StdDuration) {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .record_stage(stage, elapsed);
    }

    fn render_trace(&self, result: &PreciseRefreshResult) -> String {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .render(result)
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

    fn publish_summary(&self, summary: &Result<TokenUsageSummary, String>) {
        let Ok(summary) = summary else { return };
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.summary_result.is_none() {
            state.summary_result = Some(Ok(summary.clone()));
            self.wake.notify_all();
        }
    }

    fn wait_summary(&self) -> Result<TokenUsageSummary, String> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        loop {
            if let Some(summary) = state.summary_result.as_ref() {
                return summary.clone();
            }
            if let Some(result) = state.result.as_ref() {
                return result.summary.clone();
            }
            state = self
                .wake
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }

    fn trace_flight_id(&self) -> u64 {
        self.trace
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .flight_id
    }

    fn record_completed_sync(&self, revision: u64) {
        *self
            .completed_sync
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(PreciseSummarySyncReceipt {
            revision,
            source_revision: self.source_revision_at_start,
        });
    }

    fn completed_sync(&self) -> Option<PreciseSummarySyncReceipt> {
        self.completed_sync
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

impl PreciseRefreshCoordinator {
    fn record_completed_owner(
        &self,
        flight: &PreciseRefreshFlight,
        result: &PreciseRefreshResult,
        completed_at: Instant,
    ) {
        let owner = CompletedPreciseRefreshOwner {
            flight_id: flight.trace_flight_id(),
            summary_only: result.full.is_none(),
            completed_at,
            sync: flight.completed_sync(),
        };
        *self
            .previous_completed_owner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(owner);
    }

    fn take_previous_completed_owner(
        &self,
        intent: PreciseRefreshIntent,
    ) -> Option<(u64, u64, PreciseSummarySyncReceipt)> {
        if intent != PreciseRefreshIntent::Full {
            return None;
        }
        let mut slot = self
            .previous_completed_owner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let owner = slot.as_ref()?.clone();
        let gap = Instant::now().saturating_duration_since(owner.completed_at);
        if gap >= PRECISE_REFRESH_COMPLETED_OWNER_WINDOW || !owner.summary_only {
            *slot = None;
            return None;
        }
        let sync = owner.sync.clone();
        *slot = None;
        let sync = sync?;
        Some((
            owner.flight_id,
            u64::try_from(gap.as_millis()).unwrap_or(u64::MAX),
            sync,
        ))
    }

    fn record_attempt(&self) {
        self.schedule
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .last_attempt_at = Some(Instant::now());
    }

    fn summary_refresh_due(&self, success_ttl: StdDuration) -> bool {
        let now = Instant::now();
        let mut schedule = self
            .schedule
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let success_expired = schedule
            .last_attempt_at
            .is_none_or(|started| now.saturating_duration_since(started) >= success_ttl);
        let retry_due = schedule.last_error.is_none()
            || schedule.last_attempt_at.is_none_or(|attempt| {
                now.saturating_duration_since(attempt)
                    >= PRECISE_SUMMARY_FAILURE_RETRY_INTERVAL
            });
        // A watcher event is a coalescing hint, not a request to start a new
        // owner immediately after every append. Once a successful owner has
        // published, keep the existing cadence window even when the source
        // revision advances while it is running. Failed owners retain their
        // bounded retry interval. Manual refreshes bypass this gate through
        // an absent summary refresh interval.
        if schedule.last_error.is_none() {
            if !success_expired {
                return false;
            }
        } else if !retry_due {
            return false;
        }
        schedule.last_attempt_at = Some(now);
        true
    }

    fn record_result(&self, _flight: &PreciseRefreshFlight, result: &PreciseRefreshResult) {
        let mut schedule = self
            .schedule
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match &result.summary {
            Ok(_) => {
                schedule.last_success_at = Some(Instant::now());
                schedule.last_error = None;
                // Mark everything observed by the completed owner as covered.
                // Changes arriving after this load remain dirty and are
                // picked up at the next cadence; they do not recursively
                // create another full owner while this one is publishing.
                self.refreshed_source_revision
                    .store(self.source_revision.load(Ordering::SeqCst), Ordering::SeqCst);
            }
            Err(error) => schedule.last_error = Some(error.clone()),
        }
    }

    fn last_summary_refresh_error(&self) -> Option<String> {
        self.schedule
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .last_error
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
        finish_precise_refresh_flight(&self.state.coordinator, &self.state.flight, result);
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
    let published_result = {
        let mut state = flight
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let publish_result = state.result.is_none();
        if publish_result {
            state.result = Some(result);
        }
        let published = state.result.clone().unwrap_or_else(|| {
            PreciseRefreshResult::failure("精确 token refresh trace 无结果".into())
        });
        if publish_result {
            coordinator.record_completed_owner(flight, &published, Instant::now());
            coordinator.record_result(flight, &published);
        }
        flight.wake.notify_all();
        published
    };
    if !flight
        .trace_finished
        .swap(true, std::sync::atomic::Ordering::SeqCst)
    {
        startup_trace::mark_performance(flight.render_trace(&published_result));
    }
    run_precise_refresh_finish_hook_for_testing();

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
    let physical_home_identity = attribution_watch_root_physical_identity(&canonical_home)?;
    let key = PreciseRefreshHomeKey {
        canonical_home,
        physical_home_identity,
    };
    let registry = PRECISE_REFRESH_COORDINATORS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut registry = registry
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let now = Instant::now();
    registry.retain(|_, coordinator| {
        if Arc::strong_count(coordinator) > 1 {
            return true;
        }
        coordinator
            .previous_completed_owner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_ref()
            .is_some_and(|owner| {
                now.saturating_duration_since(owner.completed_at)
                    < PRECISE_REFRESH_COMPLETED_OWNER_WINDOW
            })
    });
    if let Some(coordinator) = registry.get(&key) {
        return Ok(Arc::clone(coordinator));
    }
    let coordinator = Arc::new(PreciseRefreshCoordinator {
        home_key: key.clone(),
        flight: Mutex::new(None),
        previous_completed_owner: Mutex::new(None),
        schedule: Mutex::new(PreciseRefreshScheduleState::default()),
        source_revision: AtomicU64::new(0),
        refreshed_source_revision: AtomicU64::new(0),
    });
    registry.insert(key, Arc::clone(&coordinator));
    Ok(coordinator)
}

fn request_precise_refresh(
    codex_home: &Path,
    intent: PreciseRefreshIntent,
) -> Result<Arc<PreciseRefreshFlight>, String> {
    request_precise_refresh_inner(codex_home, intent, None)?
        .ok_or_else(|| "精确 token refresh explicit request 未创建 flight".to_string())
}

fn schedule_precise_refresh(
    codex_home: &Path,
    refresh_interval: StdDuration,
) -> Result<Option<Arc<PreciseRefreshFlight>>, String> {
    request_precise_refresh_inner(
        codex_home,
        PreciseRefreshIntent::Summary,
        Some(refresh_interval),
    )
}

fn request_precise_refresh_inner(
    codex_home: &Path,
    intent: PreciseRefreshIntent,
    summary_refresh_interval: Option<StdDuration>,
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
        if let Some(interval) = summary_refresh_interval {
            if !coordinator.summary_refresh_due(interval) {
                return Ok(None);
            }
        } else {
            coordinator.record_attempt();
        }
        let mut current = coordinator
            .flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if current.is_some() {
            continue;
        }
        let previous_summary = coordinator.take_previous_completed_owner(intent);
        let (after_summary_only, summary_gap_ms, summary_previous_flight_id, reusable_summary_sync) =
            previous_summary.map_or((false, None, None, None), |(flight_id, gap_ms, sync)| {
                (true, Some(gap_ms), Some(flight_id), Some(sync))
            });
        let flight = PreciseRefreshFlight::new(
            intent,
            after_summary_only,
            summary_gap_ms,
            summary_previous_flight_id,
            coordinator.source_revision.load(Ordering::SeqCst),
            reusable_summary_sync,
        );
        *current = Some(Arc::clone(&flight));
        drop(current);
        spawn_precise_refresh_owner(Arc::clone(&coordinator), Arc::clone(&flight));
        return Ok(Some(flight));
    }
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
        flight.set_trace_status("spawn_error");
        finish_precise_refresh_flight(
            &coordinator,
            &flight,
            PreciseRefreshResult::failure("精确 token refresh owner 线程启动失败".into()),
        );
        return;
    }

    let key = coordinator.home_key.canonical_home.clone();
    let progress_key = key.clone();
    let spawn_progress_key = progress_key.clone();
    let thread_coordinator = Arc::clone(&coordinator);
    let thread_owner = Arc::clone(&owner_state);
    let spawned = std::thread::Builder::new()
        .name("codex-precise-refresh".into())
        .spawn(move || {
            let owner = PreciseRefreshOwnerGuard {
                state: thread_owner,
            };
            let result = catch_unwind(AssertUnwindSafe(|| {
                run_precise_refresh(&thread_coordinator, &key, &owner.state.flight)
            }));
            match result {
                Ok(result) => owner.finish(result),
                Err(_) => {
                    finish_precise_dashboard_progress(
                        &spawn_progress_key,
                        false,
                        "精确 token refresh owner 执行异常，保留上次可信数据",
                    );
                    owner.finish(PreciseRefreshResult::failure(
                        "精确 token refresh owner 执行异常".into(),
                    ));
                }
            }
        });
    if spawned.is_err() {
        flight.set_trace_status("spawn_error");
        finish_precise_dashboard_progress(
            &progress_key,
            false,
            "精确 token refresh owner 启动失败，保留上次可信数据",
        );
        finish_precise_refresh_flight(
            &coordinator,
            &flight,
            PreciseRefreshResult::failure("精确 token refresh owner 线程启动失败".into()),
        );
    }
}

fn run_precise_refresh(
    coordinator: &PreciseRefreshCoordinator,
    canonical_home: &Path,
    flight: &PreciseRefreshFlight,
) -> PreciseRefreshResult {
    begin_precise_dashboard_progress(canonical_home);
    let result = run_precise_refresh_inner(coordinator, canonical_home, flight);
    // The derived dashboard aggregate backfill also reports a `migrating`
    // phase while it groups already-indexed SQLite events. That is not an
    // unfinished exact-index migration and must not be presented as
    // "continue on next launch". Keep this decision tied to the durable
    // migration markers returned by the owner instead of inferring it from
    // the shared UI progress phase.
    let terminal_progress = result.terminal_progress();
    let message = result.terminal_message();
    if terminal_progress == PreciseRefreshTerminalProgress::MigrationPending {
        // A pending migration is an expected resumable state, not a failed
        // precise read. Keep the phase visible so startup can distinguish
        // "upgrade awaiting the next scan" from an actual owner error.
        let progress = precise_dashboard_progress(canonical_home);
        update_precise_dashboard_progress(
            canonical_home,
            "migrating",
            message,
            progress.completed,
            progress.total,
        );
        ACTIVE_PRECISE_PROGRESS_KEY.with(|slot| {
            *slot.borrow_mut() = None;
        });
    } else if terminal_progress == PreciseRefreshTerminalProgress::SummaryOnlySuccess {
        // The lightweight summary is published before the full five-minute and
        // model dashboard. A summary-only owner must not claim the shared
        // precise workflow is complete, especially during cold startup.
        update_precise_dashboard_progress(canonical_home, "idle", message, 0, None);
        ACTIVE_PRECISE_PROGRESS_KEY.with(|slot| {
            *slot.borrow_mut() = None;
        });
    } else {
        finish_precise_dashboard_progress(
            canonical_home,
            terminal_progress == PreciseRefreshTerminalProgress::FullSuccess,
            message,
        );
    }
    result
}

fn run_precise_refresh_inner(
    coordinator: &PreciseRefreshCoordinator,
    canonical_home: &Path,
    flight: &PreciseRefreshFlight,
) -> PreciseRefreshResult {
    let mut warnings = Vec::new();
    let open_result = {
        let _stage = PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::Open);
        ExactUsageIndex::open(canonical_home)
    };
    let mut index = match open_result {
        Ok(index) => index,
        Err(error) => {
            flight.set_trace_status("open_error");
            trace_precise_failure("open", &error);
            return PreciseRefreshResult::failure(error);
        }
    };
    let watcher_before: Result<(), String> = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::WatcherBefore);
        #[cfg(not(test))]
        {
            ensure_attribution_mutation_watcher(canonical_home)
        }
        #[cfg(test)]
        {
            Ok(())
        }
    };
    if let Err(error) = watcher_before {
        flight.set_trace_status("watcher_before_error");
        return PreciseRefreshResult::failure(error);
    }
    let reused_completed_summary = if index.migration_pending() {
        // A summary-only reuse would bypass the scan that commits a pending
        // attribution/schema migration. Keep the migration visible and force
        // the normal durable path once before allowing cache reuse again.
        None
    } else {
        match reusable_completed_summary_revision(
            coordinator,
            canonical_home,
            &mut index,
            flight,
        ) {
            Ok(revision) => revision,
            Err(error) => {
                flight.set_trace_status("summary_reuse_probe_error");
                trace_precise_failure("summary_reuse_probe", &error);
                return PreciseRefreshResult::failure(error);
            }
        }
    };
    let precise_coverage_at = OffsetDateTime::now_utc();
    let revision = if let Some(revision) = reused_completed_summary {
        revision
    } else {
        let sync_hook = {
            let _stage =
                PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::SyncHook);
            run_precise_refresh_sync_hook_for_testing(canonical_home)
        };
        if let Err(error) = sync_hook {
            flight.set_trace_status("sync_hook_error");
            return PreciseRefreshResult::failure(error);
        }
        update_precise_dashboard_progress(
            canonical_home,
            "preparing",
            "正在预扫描精确历史规模（只读，不修改索引）",
            0,
            None,
        );
        let discovery = match exact_usage_index::estimate_precise_scan_total_with_source_revision(
            canonical_home,
            PRECISE_SCAN_ESTIMATE_TIMEOUT,
            flight.source_revision_at_start,
        ) {
            Ok(plan) if plan.candidate_total > 0 => {
                let total = plan.candidate_total;
                update_precise_dashboard_progress(
                    canonical_home,
                    "preparing",
                    format!("预扫描完成，约 {total} 个候选文件，开始精确扫描"),
                    0,
                    Some(total),
                );
                (Some(plan), Some(total))
            }
            Ok(plan) => {
                update_precise_dashboard_progress(
                    canonical_home,
                    "preparing",
                    "预扫描未发现候选文件，继续使用动态扫描进度",
                    0,
                    None,
                );
                (Some(plan), None)
            }
            Err(_) => {
                // The estimate is a UI-only sidecar. Any timeout, transient
                // SQLite lock, or filesystem race must never block the real
                // scanner or turn a safe index refresh into a failure.
                update_precise_dashboard_progress(
                    canonical_home,
                    "preparing",
                    "预扫描未完成，继续使用动态扫描进度",
                    0,
                    None,
                );
                (None, None)
            }
        };
        let sync_result = {
            let _stage = PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::Sync);
            index.sync_with_scan_plan(
                canonical_home,
                &mut warnings,
                discovery.0,
                discovery.1,
            )
        };
        match sync_result {
            Ok(revision) => revision,
            Err(error) => {
                flight.set_trace_status("sync_error");
                trace_precise_failure("sync", &error);
                return PreciseRefreshResult::failure(error);
            }
        }
    };
    if let Err(error) = index.ensure_dashboard_aggregates(canonical_home) {
        flight.set_trace_status("aggregate_upgrade_error");
        trace_precise_failure("aggregate_upgrade", &error);
        return PreciseRefreshResult::failure(error);
    }
    // Capture the durable exact-index migration state after the scan and any
    // disposable aggregate backfill. `ensure_dashboard_aggregates` may leave
    // the shared progress phase as `migrating`, but that is only a derived
    // SQLite rebuild when the exact index itself is already complete.
    let migration_pending = index.migration_pending();
    let dashboard_revision = match index.dashboard_revision() {
        Ok(revision) => revision,
        Err(error) => {
            flight.set_trace_status("dashboard_revision_error");
            trace_precise_failure("dashboard_revision", &error);
            return PreciseRefreshResult::failure(error);
        }
    };
    flight.record_completed_sync(revision);
    let watcher_after: Result<(), String> = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::WatcherAfter);
        #[cfg(not(test))]
        {
            ensure_attribution_mutation_watcher(canonical_home)
        }
        #[cfg(test)]
        {
            Ok(())
        }
    };
    if let Err(error) = watcher_after {
        flight.set_trace_status("watcher_after_error");
        return PreciseRefreshResult::failure(error);
    }

    let summary = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::SignatureSummary);
        let signature = dashboard_index_signature(canonical_home, dashboard_revision);
        summary_after_precise_sync(&index, canonical_home, &signature, &warnings, flight)
    };
    flight.publish_summary(&summary);
    let claim_full = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::ClaimFull);
        flight.claim_full_build_or_close()
    };
    if !claim_full {
        if let Err(error) = run_precise_refresh_after_cutoff_hook_for_testing() {
            flight.set_trace_status("cutoff_error");
            return PreciseRefreshResult::failure(error);
        }
        if summary.is_ok() {
            if flight.trace_status() == "running" {
                flight.set_trace_status("summary_only");
            }
        } else if flight.trace_status() == "running" {
            flight.set_trace_status("summary_error");
        }
        return PreciseRefreshResult {
            summary,
            full: None,
            migration_pending,
        };
    }

    match build_full_dashboard_after_precise_sync(
        flight,
        &mut index,
        canonical_home,
        dashboard_revision,
        precise_coverage_at,
        &mut warnings,
    ) {
        Ok((snapshot, full_summary)) => {
            let trace_status = flight.trace_status();
            if trace_status.starts_with("summary_") || trace_status == "running" {
                flight.set_trace_status("full_ok");
            }
            PreciseRefreshResult {
                summary: if summary.is_ok() {
                    summary
                } else {
                    Ok(full_summary)
                },
                full: Some(Ok(snapshot)),
                migration_pending,
            }
        }
        Err(error) => {
            if flight.trace_status().starts_with("summary_") || flight.trace_status() == "running" {
                flight.set_trace_status("full_error");
            }
            PreciseRefreshResult {
                summary,
                full: Some(Err(error)),
                migration_pending,
            }
        }
    }
}

fn reusable_completed_summary_revision(
    coordinator: &PreciseRefreshCoordinator,
    canonical_home: &Path,
    index: &mut ExactUsageIndex,
    flight: &PreciseRefreshFlight,
) -> Result<Option<u64>, String> {
    let Some(receipt) = flight.reusable_summary_sync.as_ref() else {
        return Ok(None);
    };
    let source_revision_before = coordinator.source_revision.load(Ordering::SeqCst);
    if source_revision_before != receipt.source_revision {
        return Ok(None);
    }
    let revision = index.revision()?;
    if revision < receipt.revision {
        return Ok(None);
    }
    let mut probe_warnings = Vec::new();
    if index.sources_changed(canonical_home, &mut probe_warnings)? || !probe_warnings.is_empty() {
        return Ok(None);
    }
    if coordinator.source_revision.load(Ordering::SeqCst) != source_revision_before {
        return Ok(None);
    }
    Ok(Some(revision))
}

fn summary_after_precise_sync(
    index: &ExactUsageIndex,
    canonical_home: &Path,
    signature: &DashboardScanSignature,
    warnings: &[LocalDataWarning],
    flight: &PreciseRefreshFlight,
) -> Result<TokenUsageSummary, String> {
    let attribution_safety = match index.attribution_safety_state() {
        Ok(state) => state,
        Err(error) => {
            flight.set_trace_status("summary_safety_error");
            return Err(error);
        }
    };
    let physical_home_identity = match attribution_watch_root_physical_identity(canonical_home) {
        Ok(identity) => identity,
        Err(error) => {
            flight.set_trace_status("summary_identity_error");
            return Err(error);
        }
    };
    let cached = cached_dashboard_aggregate(signature)
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
        .map(|cached| cached.summary);
    if let Some(summary) = cached {
        flight.set_trace_status("summary_cache_hit");
        return Ok(summary);
    }
    let empty = match index.is_empty() {
        Ok(empty) => empty,
        Err(error) => {
            flight.set_trace_status("summary_empty_check_error");
            return Err(error);
        }
    };
    if empty {
        flight.set_trace_status("summary_empty");
        return Err(no_token_events_error(warnings));
    }
    let summary = match index.summary_with_system_timezone(OffsetDateTime::now_utc()) {
        Ok(summary) => summary,
        Err(error) => {
            flight.set_trace_status("summary_error");
            return Err(error);
        }
    };
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
    /// Durable exact-index migration state. This is intentionally separate
    /// from the UI progress phase because aggregate backfill uses the same
    /// phase name while it rebuilds disposable numeric tables.
    migration_pending: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PreciseRefreshTerminalProgress {
    MigrationPending,
    SummaryOnlySuccess,
    FullSuccess,
    Failed,
}

impl PreciseRefreshResult {
    fn failure(error: String) -> Self {
        Self {
            summary: Err(error.clone()),
            full: Some(Err(error)),
            migration_pending: false,
        }
    }

    fn terminal_message(&self) -> &'static str {
        match (&self.summary, &self.full) {
            _ if self.migration_pending => "精确统计已更新，索引升级待下次启动继续",
            (_, Some(Ok(_))) => "精确统计已更新",
            (Ok(_), None) => "精确统计数值已更新",
            _ => "精确统计失败，保留上次可信数据",
        }
    }

    fn terminal_progress(&self) -> PreciseRefreshTerminalProgress {
        if self.migration_pending {
            return PreciseRefreshTerminalProgress::MigrationPending;
        }
        match (&self.summary, &self.full) {
            (_, Some(Ok(_))) => PreciseRefreshTerminalProgress::FullSuccess,
            (Ok(_), None) => PreciseRefreshTerminalProgress::SummaryOnlySuccess,
            _ => PreciseRefreshTerminalProgress::Failed,
        }
    }
}

const PRECISE_OWNER_TRACE_MAX_BYTES: usize = 1_024;

#[derive(Clone, Copy)]
enum PreciseRefreshTraceStage {
    Open,
    WatcherBefore,
    SyncHook,
    Sync,
    WatcherAfter,
    SignatureSummary,
    ClaimFull,
    FullSafety,
    FullIdentity,
    FullSignature,
    FullCacheDecision,
    FullEmptyCheck,
    DashboardData,
    PersistentBinding,
    StorePublish,
    FullTotal,
}

struct PreciseRefreshTrace {
    flight_id: u64,
    intent: PreciseRefreshIntent,
    promoted_to_full: bool,
    after_summary_only: bool,
    summary_gap_ms: Option<u64>,
    summary_previous_flight_id: Option<u64>,
    claim_full: Option<bool>,
    status: &'static str,
    started: Instant,
    open_ms: Option<u64>,
    watcher_before_ms: Option<u64>,
    sync_hook_ms: Option<u64>,
    sync_ms: Option<u64>,
    watcher_after_ms: Option<u64>,
    signature_summary_ms: Option<u64>,
    claim_full_ms: Option<u64>,
    full_safety_ms: Option<u64>,
    full_identity_ms: Option<u64>,
    full_signature_ms: Option<u64>,
    full_cache_decision_ms: Option<u64>,
    full_empty_check_ms: Option<u64>,
    dashboard_data_ms: Option<u64>,
    persistent_binding_ms: Option<u64>,
    store_publish_ms: Option<u64>,
    full_total_ms: Option<u64>,
}

impl PreciseRefreshTrace {
    fn new(
        intent: PreciseRefreshIntent,
        after_summary_only: bool,
        summary_gap_ms: Option<u64>,
        summary_previous_flight_id: Option<u64>,
    ) -> Self {
        Self {
            flight_id: PRECISE_REFRESH_FLIGHT_SEQUENCE.fetch_add(1, Ordering::Relaxed),
            intent,
            promoted_to_full: false,
            after_summary_only,
            summary_gap_ms,
            summary_previous_flight_id,
            claim_full: None,
            status: "running",
            started: Instant::now(),
            open_ms: None,
            watcher_before_ms: None,
            sync_hook_ms: None,
            sync_ms: None,
            watcher_after_ms: None,
            signature_summary_ms: None,
            claim_full_ms: None,
            full_safety_ms: None,
            full_identity_ms: None,
            full_signature_ms: None,
            full_cache_decision_ms: None,
            full_empty_check_ms: None,
            dashboard_data_ms: None,
            persistent_binding_ms: None,
            store_publish_ms: None,
            full_total_ms: None,
        }
    }

    fn record_stage(&mut self, stage: PreciseRefreshTraceStage, elapsed: StdDuration) {
        let millis = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
        match stage {
            PreciseRefreshTraceStage::Open => self.open_ms = Some(millis),
            PreciseRefreshTraceStage::WatcherBefore => self.watcher_before_ms = Some(millis),
            PreciseRefreshTraceStage::SyncHook => self.sync_hook_ms = Some(millis),
            PreciseRefreshTraceStage::Sync => self.sync_ms = Some(millis),
            PreciseRefreshTraceStage::WatcherAfter => self.watcher_after_ms = Some(millis),
            PreciseRefreshTraceStage::SignatureSummary => self.signature_summary_ms = Some(millis),
            PreciseRefreshTraceStage::ClaimFull => self.claim_full_ms = Some(millis),
            PreciseRefreshTraceStage::FullSafety => self.full_safety_ms = Some(millis),
            PreciseRefreshTraceStage::FullIdentity => self.full_identity_ms = Some(millis),
            PreciseRefreshTraceStage::FullSignature => self.full_signature_ms = Some(millis),
            PreciseRefreshTraceStage::FullCacheDecision => {
                self.full_cache_decision_ms = Some(millis)
            }
            PreciseRefreshTraceStage::FullEmptyCheck => self.full_empty_check_ms = Some(millis),
            PreciseRefreshTraceStage::DashboardData => self.dashboard_data_ms = Some(millis),
            PreciseRefreshTraceStage::PersistentBinding => {
                self.persistent_binding_ms = Some(millis)
            }
            PreciseRefreshTraceStage::StorePublish => self.store_publish_ms = Some(millis),
            PreciseRefreshTraceStage::FullTotal => self.full_total_ms = Some(millis),
        }
    }

    fn stage_value(value: Option<u64>) -> String {
        value
            .map(|value| value.to_string())
            .unwrap_or_else(|| "na".into())
    }

    fn result_status(&self, result: &PreciseRefreshResult) -> &'static str {
        if self.status != "running" {
            return self.status;
        }
        match (&result.summary, &result.full) {
            (_, Some(Ok(_))) => "full_ok",
            (_, Some(Err(_))) => "full_error",
            (Ok(_), None) => "summary_only",
            (Err(_), None) => "summary_error",
        }
    }

    fn render(&self, result: &PreciseRefreshResult) -> String {
        let claim = match self.claim_full {
            Some(true) => "1",
            Some(false) => "0",
            None => "na",
        };
        let intent = match self.intent {
            PreciseRefreshIntent::Summary => "summary",
            PreciseRefreshIntent::Full => "full",
        };
        let mut line = format!(
            "precise_owner flight={} intent={} promoted={} after_summary_only={} summary_prev_flight={} summary_gap_ms={} claim_full={} status={} open_ms={} watcher_before_ms={} sync_hook_ms={} sync_ms={} watcher_after_ms={} signature_summary_ms={} claim_full_ms={} full_safety_ms={} full_identity_ms={} full_signature_ms={} full_cache_decision_ms={} full_empty_check_ms={} dashboard_data_ms={} persistent_binding_ms={} store_publish_ms={} full_total_ms={} total_ms={}",
            self.flight_id,
            intent,
            u8::from(self.promoted_to_full),
            u8::from(self.after_summary_only),
            Self::stage_value(self.summary_previous_flight_id),
            Self::stage_value(self.summary_gap_ms),
            claim,
            self.result_status(result),
            Self::stage_value(self.open_ms),
            Self::stage_value(self.watcher_before_ms),
            Self::stage_value(self.sync_hook_ms),
            Self::stage_value(self.sync_ms),
            Self::stage_value(self.watcher_after_ms),
            Self::stage_value(self.signature_summary_ms),
            Self::stage_value(self.claim_full_ms),
            Self::stage_value(self.full_safety_ms),
            Self::stage_value(self.full_identity_ms),
            Self::stage_value(self.full_signature_ms),
            Self::stage_value(self.full_cache_decision_ms),
            Self::stage_value(self.full_empty_check_ms),
            Self::stage_value(self.dashboard_data_ms),
            Self::stage_value(self.persistent_binding_ms),
            Self::stage_value(self.store_publish_ms),
            Self::stage_value(self.full_total_ms),
            Self::stage_value(Some(
                self.started
                    .elapsed()
                    .as_millis()
                    .try_into()
                    .unwrap_or(u64::MAX),
            )),
        );
        if line.len() > PRECISE_OWNER_TRACE_MAX_BYTES {
            line.truncate(PRECISE_OWNER_TRACE_MAX_BYTES);
        }
        line
    }
}

#[cfg(test)]
mod precise_refresh_trace_tests {
    use super::*;

    fn empty_result() -> PreciseRefreshResult {
        PreciseRefreshResult {
            summary: Ok(TokenUsageSummary::default()),
            full: None,
            migration_pending: false,
        }
    }

    #[test]
    fn owner_trace_has_fixed_order_bounded_fields_and_no_source_text() {
        let mut trace =
            PreciseRefreshTrace::new(PreciseRefreshIntent::Summary, true, Some(7), Some(3));
        trace.promoted_to_full = true;
        trace.claim_full = Some(true);
        trace.status = "summary_cache_hit";
        trace.record_stage(PreciseRefreshTraceStage::Open, StdDuration::from_millis(3));
        let line = trace.render(&empty_result());
        let keys = line
            .split_whitespace()
            .map(|field| field.split_once('=').map_or(field, |(key, _)| key))
            .collect::<Vec<_>>();
        assert_eq!(
            keys,
            vec![
                "precise_owner",
                "flight",
                "intent",
                "promoted",
                "after_summary_only",
                "summary_prev_flight",
                "summary_gap_ms",
                "claim_full",
                "status",
                "open_ms",
                "watcher_before_ms",
                "sync_hook_ms",
                "sync_ms",
                "watcher_after_ms",
                "signature_summary_ms",
                "claim_full_ms",
                "full_safety_ms",
                "full_identity_ms",
                "full_signature_ms",
                "full_cache_decision_ms",
                "full_empty_check_ms",
                "dashboard_data_ms",
                "persistent_binding_ms",
                "store_publish_ms",
                "full_total_ms",
                "total_ms",
            ]
        );
        assert!(line.len() <= PRECISE_OWNER_TRACE_MAX_BYTES);
        assert!(line.contains("intent=summary"));
        assert!(line.contains("promoted=1"));
        assert!(line.contains("after_summary_only=1"));
        assert!(line.contains("summary_prev_flight=3"));
        assert!(line.contains("summary_gap_ms=7"));
        assert!(line.contains("claim_full=1"));
        assert!(!line.contains("/private/source.jsonl"));
    }

    #[test]
    fn aggregate_backfill_is_not_reported_as_pending_exact_migration() {
        let result = empty_result();
        assert!(!result.migration_pending);
        assert_eq!(result.terminal_message(), "精确统计数值已更新");
    }

    #[test]
    fn owner_trace_renders_explainable_terminal_statuses() {
        let cases = [
            ("summary_cache_hit", empty_result()),
            ("summary_only", empty_result()),
            (
                "full_error",
                PreciseRefreshResult {
                    summary: Err("error contains /private/source.jsonl".into()),
                    full: Some(Err("same error".into())),
                    migration_pending: false,
                },
            ),
            ("full_empty", empty_result()),
        ];
        for (status, result) in cases {
            let mut trace = PreciseRefreshTrace::new(PreciseRefreshIntent::Full, false, None, None);
            trace.status = status;
            let line = trace.render(&result);
            assert!(line.contains(&format!("status={status}")));
            assert!(line.len() <= PRECISE_OWNER_TRACE_MAX_BYTES);
            assert!(!line.contains("source.jsonl"));
        }
    }

    #[test]
    fn completed_owner_summary_metadata_survives_slot_clear_and_respects_window() {
        let coordinator = Arc::new(PreciseRefreshCoordinator {
            home_key: PreciseRefreshHomeKey {
                canonical_home: PathBuf::from("trace-only-home"),
                physical_home_identity: "trace-only-physical-home".into(),
            },
            flight: Mutex::new(None),
            previous_completed_owner: Mutex::new(None),
            schedule: Mutex::new(PreciseRefreshScheduleState::default()),
            source_revision: AtomicU64::new(0),
            refreshed_source_revision: AtomicU64::new(0),
        });
        let summary_flight = PreciseRefreshFlight::new(
            PreciseRefreshIntent::Summary,
            false,
            None,
            None,
            0,
            None,
        );
        summary_flight.record_completed_sync(7);
        let summary_result = empty_result();
        coordinator.record_completed_owner(
            &summary_flight,
            &summary_result,
            Instant::now() - StdDuration::from_millis(25),
        );
        // The coordinator slot is intentionally left empty: this models the
        // real owner cleanup that used to lose the summary-cutoff lineage.
        assert!(coordinator.flight.lock().unwrap().is_none());
        let (previous_flight_id, summary_gap_ms, reusable_sync) = coordinator
            .take_previous_completed_owner(PreciseRefreshIntent::Full)
            .expect("recent summary owner should be retained after slot cleanup");
        assert_eq!(reusable_sync.revision, 7);
        let full_trace = PreciseRefreshTrace::new(
            PreciseRefreshIntent::Full,
            true,
            Some(summary_gap_ms),
            Some(previous_flight_id),
        );
        let line = full_trace.render(&PreciseRefreshResult {
            summary: Ok(TokenUsageSummary::default()),
            full: Some(Err("diagnostic-only".into())),
            migration_pending: false,
        });
        assert!(line.contains("after_summary_only=1"));
        assert!(line.contains("summary_gap_ms="));

        let stale_summary_flight = PreciseRefreshFlight::new(
            PreciseRefreshIntent::Summary,
            false,
            None,
            None,
            0,
            None,
        );
        stale_summary_flight.record_completed_sync(8);
        coordinator.record_completed_owner(
            &stale_summary_flight,
            &summary_result,
            Instant::now() - PRECISE_REFRESH_COMPLETED_OWNER_WINDOW - StdDuration::from_millis(1),
        );
        assert!(coordinator
            .take_previous_completed_owner(PreciseRefreshIntent::Full)
            .is_none());

        let full_owner = PreciseRefreshFlight::new(
            PreciseRefreshIntent::Full,
            false,
            None,
            None,
            0,
            None,
        );
        coordinator.record_completed_owner(
            &full_owner,
            &PreciseRefreshResult {
                summary: Ok(TokenUsageSummary::default()),
                full: Some(Err("full owner".into())),
                migration_pending: false,
            },
            Instant::now(),
        );
        assert!(coordinator
            .take_previous_completed_owner(PreciseRefreshIntent::Full)
            .is_none());
    }

    #[test]
    fn source_events_coalesce_until_success_cadence_and_failures_keep_retrying() {
        let coordinator = Arc::new(PreciseRefreshCoordinator {
            home_key: PreciseRefreshHomeKey {
                canonical_home: PathBuf::from("cadence-home"),
                physical_home_identity: "cadence-physical-home".into(),
            },
            flight: Mutex::new(None),
            previous_completed_owner: Mutex::new(None),
            schedule: Mutex::new(PreciseRefreshScheduleState {
                last_attempt_at: Some(Instant::now()),
                last_success_at: Some(Instant::now()),
                last_error: None,
            }),
            source_revision: AtomicU64::new(2),
            refreshed_source_revision: AtomicU64::new(1),
        });

        assert!(
            !coordinator.summary_refresh_due(PRECISE_SUMMARY_REFRESH_TTL),
            "a watcher append after a successful owner must not launch a second owner immediately"
        );

        {
            let mut schedule = coordinator.schedule.lock().unwrap();
            schedule.last_attempt_at = Some(
                Instant::now() - PRECISE_SUMMARY_REFRESH_TTL - StdDuration::from_secs(1),
            );
            // Simulate an owner that completed only moments ago after using
            // most of its cadence interval. The next wall-clock tick is due
            // from request start and must not be skipped.
            schedule.last_success_at = Some(Instant::now());
        }
        assert!(coordinator.summary_refresh_due(PRECISE_SUMMARY_REFRESH_TTL));

        coordinator
            .schedule
            .lock()
            .unwrap()
            .last_error = Some("transient".into());
        coordinator
            .schedule
            .lock()
            .unwrap()
            .last_attempt_at = Some(Instant::now());
        assert!(!coordinator.summary_refresh_due(PRECISE_SUMMARY_REFRESH_TTL));
        coordinator
            .schedule
            .lock()
            .unwrap()
            .last_attempt_at = Some(Instant::now() - PRECISE_SUMMARY_FAILURE_RETRY_INTERVAL);
        assert!(coordinator.summary_refresh_due(PRECISE_SUMMARY_REFRESH_TTL));

        let flight = PreciseRefreshFlight::new(
            PreciseRefreshIntent::Summary,
            false,
            None,
            None,
            1,
            None,
        );
        coordinator.source_revision.store(3, Ordering::SeqCst);
        coordinator.record_result(&flight, &empty_result());
        assert_eq!(
            coordinator.refreshed_source_revision.load(Ordering::SeqCst),
            3,
            "the completed owner must cover the source revision observed at publish"
        );
    }
}

struct PreciseRefreshTraceStageGuard<'a> {
    flight: &'a PreciseRefreshFlight,
    stage: PreciseRefreshTraceStage,
    started: Instant,
}

impl<'a> PreciseRefreshTraceStageGuard<'a> {
    fn new(flight: &'a PreciseRefreshFlight, stage: PreciseRefreshTraceStage) -> Self {
        Self {
            flight,
            stage,
            started: Instant::now(),
        }
    }
}

impl Drop for PreciseRefreshTraceStageGuard<'_> {
    fn drop(&mut self) {
        self.flight
            .record_trace_stage(self.stage, self.started.elapsed());
    }
}

struct PreciseRefreshFlightState {
    full_requested: bool,
    full_build_started: bool,
    promotion_closed: bool,
    summary_result: Option<Result<TokenUsageSummary, String>>,
    result: Option<PreciseRefreshResult>,
}

struct PreciseRefreshFlight {
    state: Mutex<PreciseRefreshFlightState>,
    wake: Condvar,
    trace: Mutex<PreciseRefreshTrace>,
    trace_finished: std::sync::atomic::AtomicBool,
    source_revision_at_start: u64,
    reusable_summary_sync: Option<PreciseSummarySyncReceipt>,
    completed_sync: Mutex<Option<PreciseSummarySyncReceipt>>,
}

#[derive(Clone)]
struct CompletedPreciseRefreshOwner {
    flight_id: u64,
    summary_only: bool,
    completed_at: Instant,
    sync: Option<PreciseSummarySyncReceipt>,
}

#[derive(Clone, Debug)]
struct PreciseSummarySyncReceipt {
    revision: u64,
    source_revision: u64,
}

struct PreciseRefreshCoordinator {
    home_key: PreciseRefreshHomeKey,
    flight: Mutex<Option<Arc<PreciseRefreshFlight>>>,
    previous_completed_owner: Mutex<Option<CompletedPreciseRefreshOwner>>,
    schedule: Mutex<PreciseRefreshScheduleState>,
    source_revision: AtomicU64,
    refreshed_source_revision: AtomicU64,
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
pub(crate) type PreciseRefreshPromotionHook = Arc<dyn Fn(bool) -> Result<(), String> + Send + Sync>;
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
    #[serde(default)]
    pub today_model_breakdowns: Vec<ModelTokenBreakdown>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsageSummarySnapshot {
    #[serde(flatten)]
    pub summary: TokenUsageSummary,
    pub dashboard_revision: u64,
    pub aggregate_boundary_unix: i64,
    pub generated_at: String,
}

impl std::ops::Deref for TokenUsageSummarySnapshot {
    type Target = TokenUsageSummary;

    fn deref(&self) -> &Self::Target {
        &self.summary
    }
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
    flight: &PreciseRefreshFlight,
    index: &mut ExactUsageIndex,
    codex_home: &Path,
    revision: u64,
    precise_coverage_at: OffsetDateTime,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<(DashboardSnapshot, TokenUsageSummary), String> {
    let _full_total =
        PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::FullTotal);
    let attribution_safety = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::FullSafety);
        match index.attribution_safety_state() {
            Ok(state) => state,
            Err(error) => {
                flight.set_trace_status("full_safety_error");
                return Err(error);
            }
        }
    };
    let observer_identity = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::FullIdentity);
        match precise_observer_identity(codex_home) {
            Ok(identity) => identity,
            Err(error) => {
                flight.set_trace_status("full_identity_error");
                return Err(error);
            }
        }
    };
    let signature = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::FullSignature);
        dashboard_index_signature(codex_home, revision)
    };
    let cached_snapshot = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::FullCacheDecision);
        cached_dashboard_snapshot_for_current(&signature, codex_home, &attribution_safety)
    };
    if let Some(snapshot) = cached_snapshot {
        let summary = match cached_dashboard_aggregate(&signature).map(|cached| cached.summary) {
            Some(summary) => summary,
            None => {
                flight.set_trace_status("full_cache_error");
                return Err("精确 token full refresh 缺少与完整快照对应的 summary".to_string());
            }
        };
        flight.set_trace_status("full_cache_hit");
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
    let empty = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::FullEmptyCheck);
        match index.is_empty() {
            Ok(empty) => empty,
            Err(error) => {
                flight.set_trace_status("full_empty_check_error");
                return Err(error);
            }
        }
    };
    if empty {
        flight.set_trace_status("full_empty");
        return Err(no_token_events_error(warnings));
    }

    record_dashboard_aggregate_build_for_testing(codex_home);
    let now_utc = OffsetDateTime::now_utc();
    let data = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::DashboardData);
        match index.dashboard_data_with_system_timezone(codex_home, now_utc, warnings) {
            Ok(data) => data,
            Err(error) => {
                flight.set_trace_status("dashboard_data_error");
                trace_precise_failure("dashboard_data", &error);
                return Err(error);
            }
        }
    };
    let aggregate_generation = match index.published_generation() {
        Ok(generation) => generation,
        Err(error) => {
            flight.set_trace_status("aggregate_generation_error");
            return Err(error);
        }
    };
    if let Err(error) = index.mark_dashboard_aggregate_published(
        aggregate_generation,
        data.settled_through,
    ) {
        flight.set_trace_status("aggregate_publish_error");
        return Err(error);
    }
    let generated_at = now_utc
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    let precise_scan_complete = !attribution_safety.current_scan_incomplete;
    let precise_recent_usage_covered_at = precise_scan_complete.then(|| {
        precise_coverage_at
            .format(&Rfc3339)
            .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
    });
    let settled_through = precise_scan_complete
        .then(|| {
            OffsetDateTime::from_unix_timestamp(data.settled_through)
                .ok()
                .and_then(|value| value.format(&Rfc3339).ok())
        })
        .flatten();

    let mut snapshot = DashboardSnapshot {
        generated_at: generated_at.clone(),
        precise_recent_usage_covered_at,
        settled_through,
        precise_recent_usage_fresh: precise_scan_complete,
        precise_observer_epoch: precise_scan_complete.then_some(observer_identity.epoch.clone()),
        precise_observer_started_at_unix_micros: precise_scan_complete
            .then_some(observer_identity.started_at_unix_micros),
        precise_observer_sequence: precise_scan_complete.then_some(observer_identity.sequence),
        precise_attribution_provenance_epoch: Some(attribution_safety.provenance_epoch.clone()),
        precise_attribution_generation: Some(attribution_safety.generation),
        precise_attribution_unsafe_since_generation: attribution_safety.unsafe_since_generation,
        precise_attribution_unsafe_id: attribution_safety.unsafe_id.clone(),
        precise_attribution_current_scan_unsafe: attribution_safety
            .current_scan_unsafe_cause_detected,
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
    let persistent_binding = {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::PersistentBinding);
        match persistent_numeric_cache_binding(codex_home, signature.clone(), &attribution_safety) {
            Ok(binding) => Some(binding),
            Err(error) => {
                flight.set_trace_status("full_binding_warning");
                snapshot.warnings.push(LocalDataWarning {
                    source: "usage-cache-persistence".into(),
                    message: error,
                });
                None
            }
        }
    };
    {
        let _stage =
            PreciseRefreshTraceStageGuard::new(flight, PreciseRefreshTraceStage::StorePublish);
        if let Some(warning) = store_dashboard_aggregate_with_binding(
            signature,
            Some(snapshot.clone()),
            summary.clone(),
            persistent_binding,
        ) {
            flight.set_trace_status("full_store_warning");
            snapshot.warnings.push(warning);
        }
        let _ = cache_lifecycle::mark_usage_cache_ready_after_success();
        merge_usage_cache_marker_warning(&mut snapshot);
    }
    Ok((snapshot, summary))
}

fn trace_precise_failure(stage: &str, error: &str) {
    let normalized = error.to_ascii_lowercase();
    let class = if normalized.contains("unique constraint") {
        "unique_constraint"
    } else if normalized.contains("disk i/o") || normalized.contains("ioerr") {
        "disk_io"
    } else if normalized.contains("busy") || normalized.contains("locked") {
        "busy_locked"
    } else if normalized.contains("corrupt")
        || normalized.contains("malformed")
        || normalized.contains("损坏")
    {
        "corrupt"
    } else if normalized.contains("cantopen") || normalized.contains("无法打开") {
        "cant_open"
    } else if normalized.contains("source changed") || normalized.contains("源文件") {
        "source_changed"
    } else {
        "other"
    };
    startup_trace::mark_performance(format!(
        "precise_failure stage={stage} class={class}"
    ));
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

pub fn usage_summary_snapshot(
    codex_home: &Path,
) -> Result<Option<TokenUsageSummarySnapshot>, String> {
    cached_dashboard_usage_summary_snapshot_cache_only(codex_home)
}

/// Refreshes (or joins) the lightweight owner and returns the cache only after
/// that owner has published. Callers therefore never need a second polling
/// interval merely to observe a successful refresh.
pub fn refreshed_usage_summary_snapshot_with_interval(
    codex_home: &Path,
    refresh_interval_seconds: Option<u64>,
) -> Result<Option<TokenUsageSummarySnapshot>, String> {
    let configured_seconds = match refresh_interval_seconds {
        Some(0) => 0,
        Some(value @ (60 | 150 | 300 | 600)) => value,
        _ => PRECISE_SUMMARY_REFRESH_TTL.as_secs(),
    };
    let reuse_window = StdDuration::from_secs(configured_seconds);
    let scheduled = schedule_precise_refresh(codex_home, reuse_window)?;
    if let Some(flight) = scheduled {
        flight.wait_summary()?;
    } else if let Some(error) = precise_refresh_coordinator(codex_home)?.last_summary_refresh_error()
    {
        return Err(error);
    }
    usage_summary_snapshot(codex_home)
}

pub fn schedule_usage_summary_refresh(
    codex_home: &Path,
) -> Result<(), String> {
    schedule_usage_summary_refresh_with_interval(codex_home, None)
}

pub fn schedule_usage_summary_refresh_with_interval(
    codex_home: &Path,
    refresh_interval_seconds: Option<u64>,
) -> Result<(), String> {
    let configured_seconds = match refresh_interval_seconds {
        Some(value @ (60 | 150 | 300 | 600)) => value,
        _ => PRECISE_SUMMARY_REFRESH_TTL.as_secs(),
    };
    // Measure cadence from request start, not owner completion. A slow owner
    // must not make the next wall-clock tick miss and stretch the configured
    // interval to two periods.
    let reuse_window = StdDuration::from_secs(configured_seconds);
    let scheduled = schedule_precise_refresh(codex_home, reuse_window)?;
    if let Some(flight) = scheduled.as_ref().filter(|flight| flight.is_done()) {
        return flight.wait().summary.map(|_| ());
    }
    if scheduled.is_none() {
        if let Some(error) = precise_refresh_coordinator(codex_home)?.last_summary_refresh_error() {
            return Err(error);
        }
    }
    Ok(())
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

fn cached_dashboard_usage_summary_cache_only(
    codex_home: &Path,
) -> Result<Option<TokenUsageSummary>, String> {
    let local_offset = crate::core::localtime::current_local_offset();
    let now_utc = OffsetDateTime::now_utc();
    if let Some(summary) =
        cached_dashboard_usage_summary_at(codex_home, now_utc, local_offset)?
    {
        return Ok(Some(summary));
    }
    let canonical_home = precise_refresh_home(codex_home)?;
    if canonical_home == codex_home {
        return Ok(None);
    }
    cached_dashboard_usage_summary_at(&canonical_home, now_utc, local_offset)
}

fn cached_dashboard_usage_summary_snapshot_cache_only(
    codex_home: &Path,
) -> Result<Option<TokenUsageSummarySnapshot>, String> {
    let local_offset = crate::core::localtime::current_local_offset();
    let now_utc = OffsetDateTime::now_utc();
    if let Some(summary) =
        cached_dashboard_usage_summary_snapshot_at(codex_home, now_utc, local_offset)?
    {
        return Ok(Some(summary));
    }
    let canonical_home = precise_refresh_home(codex_home)?;
    if canonical_home == codex_home {
        return Ok(None);
    }
    cached_dashboard_usage_summary_snapshot_at(&canonical_home, now_utc, local_offset)
}

pub(crate) fn cached_dashboard_usage_summary(codex_home: &Path) -> Option<TokenUsageSummary> {
    // This helper is consumed by live-rate ticks. It may only consult the
    // already-hydrated dashboard/summary cache; opening the exact index here
    // would run startup integrity work (and potentially quick_check) on the
    // live path. The explicit `usage_summary` owner remains the sole path that
    // is allowed to open and synchronise the exact index after a cache miss.
    cached_dashboard_usage_summary_cache_only(codex_home)
        .ok()
        .flatten()
}

pub(crate) fn cached_dashboard_snapshot_for_startup(
    codex_home: &Path,
) -> Option<DashboardSnapshot> {
    // Load the persisted aggregate before consulting the index. A cache miss
    // must not perform any index work on the startup path.
    hydrate_dashboard_aggregate_cache_once().ok()?;
    let has_persisted_aggregate = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()))
        .lock()
        .ok()
        .is_some_and(|guard| guard.aggregate.is_some());
    if !has_persisted_aggregate {
        return None;
    }
    let canonical_home = precise_refresh_home(codex_home).ok()?;
    let index_identity = exact_usage_index::peek_startup_identity(&canonical_home)
        .ok()
        .flatten()?;
    let physical_home_identity = attribution_watch_root_physical_identity(&canonical_home).ok()?;
    let canonical_signature =
        dashboard_index_signature(&canonical_home, index_identity.dashboard_revision);
    if let Some(snapshot) = cached_dashboard_startup_snapshot(
        &canonical_signature,
        &canonical_home,
        &index_identity.attribution_safety,
        &physical_home_identity,
        Some(index_identity.published_generation),
    ) {
        return Some(snapshot_with_generated_at(snapshot));
    }

    // A completed exact sync can monotonically advance the current revision
    // before the next V20 checkpoint is due. Under the same Home, physical
    // identity, parser/schema and attribution provenance, the older numeric
    // envelope remains a trustworthy stale last-good. It must never be marked
    // current or used for attribution coverage.
    if let Some(cached_revision) = cached_v20_revision_for_startup()
        .filter(|cached_revision| *cached_revision <= index_identity.dashboard_revision)
    {
        let mut stale_signature = canonical_signature.clone();
        stale_signature.index_revision = cached_revision;
        if let Some(snapshot) = cached_dashboard_startup_snapshot(
            &stale_signature,
            &canonical_home,
            &index_identity.attribution_safety,
            &physical_home_identity,
            Some(index_identity.published_generation),
        ) {
            return Some(snapshot_with_generated_at(snapshot));
        }
    }

    // V18 wrote the pre-canonical request path. It is still safe to use only
    // as a stale startup snapshot after the canonical index identity has been
    // validated read-only; never inspect an index at this raw alias path.
    if canonical_home != codex_home {
        let raw_signature = DashboardScanSignature {
            codex_home: codex_home.to_path_buf(),
            local_date: canonical_signature.local_date.clone(),
            utc_offset_seconds: canonical_signature.utc_offset_seconds,
            index_revision: index_identity.dashboard_revision,
            aggregate_boundary_unix: canonical_signature.aggregate_boundary_unix,
        };
        if let Some(snapshot) = cached_dashboard_startup_snapshot(
            &raw_signature,
            &canonical_home,
            &index_identity.attribution_safety,
            &physical_home_identity,
            None,
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

    summary.today_model_breakdowns = Vec::new();

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
struct PersistentNumericDashboardCacheV20 {
    version: u32,
    #[serde(flatten)]
    binding: PersistentNumericCacheBinding,
    built_at: String,
    coverage_at: Option<String>,
    #[serde(default)]
    settled_through: Option<String>,
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
    generated_at: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct DashboardScanSignature {
    codex_home: PathBuf,
    local_date: String,
    utc_offset_seconds: i32,
    /// Numeric dashboard lineage, not the generic index revision. The latter
    /// also advances when state_5.sqlite thread metadata is refreshed.
    #[serde(default)]
    index_revision: u64,
    /// Latest closed UTC five-minute boundary (including the 15-second
    /// settlement delay). This prevents a cached chart from keeping an old
    /// time axis forever when no token event changed the exact generation.
    #[serde(default)]
    aggregate_boundary_unix: i64,
}

fn dashboard_index_signature(codex_home: &Path, index_revision: u64) -> DashboardScanSignature {
    let local_offset = crate::core::localtime::current_local_offset();
    let now_utc = OffsetDateTime::now_utc();
    DashboardScanSignature {
        codex_home: codex_home.to_path_buf(),
        local_date: local_date_string(now_utc.to_offset(local_offset)),
        utc_offset_seconds: local_offset.whole_seconds(),
        index_revision,
        aggregate_boundary_unix: ExactUsageIndex::latest_eligible_aggregate_boundary(now_utc),
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
) -> Result<Option<TokenUsageSummary>, String> {
    hydrate_dashboard_aggregate_cache_once()?;
    let expected_scope = dashboard_usage_scope_at(codex_home, now_utc, local_offset);
    let summary_cache = USAGE_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Some(summary) = summary_cache
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .filter(|cached| cached.signature.usage_scope() == expected_scope)
        .map(|cached| cached.summary)
    {
        return Ok(Some(summary));
    }
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    Ok(cache
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
        .map(|cached| cached.summary))
}

fn cached_dashboard_usage_summary_snapshot_at(
    codex_home: &Path,
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> Result<Option<TokenUsageSummarySnapshot>, String> {
    hydrate_dashboard_aggregate_cache_once()?;
    let expected_scope = dashboard_usage_scope_at(codex_home, now_utc, local_offset);
    let summary_cache = USAGE_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Some(cached) = summary_cache
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .filter(|cached| cached.signature.usage_scope() == expected_scope)
    {
        return Ok(Some(TokenUsageSummarySnapshot {
            summary: cached.summary,
            dashboard_revision: cached.signature.index_revision,
            aggregate_boundary_unix: cached.signature.aggregate_boundary_unix,
            generated_at: cached.generated_at,
        }));
    }
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    Ok(cache
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
        .and_then(|cached| {
            let generated_at = cached.snapshot.as_ref()?.generated_at.clone();
            Some(TokenUsageSummarySnapshot {
                summary: cached.summary,
                dashboard_revision: cached.signature.index_revision,
                aggregate_boundary_unix: cached.signature.aggregate_boundary_unix,
                generated_at,
            })
        }))
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
        || binding
            .precise_attribution_provenance_epoch
            .trim()
            .is_empty()
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

fn persistent_numeric_cache_binding_matches_startup(
    binding: &PersistentNumericCacheBinding,
    canonical_home: &Path,
    signature: &DashboardScanSignature,
    physical_home_identity: &str,
    attribution_safety: &exact_usage_index::AttributionSafetyState,
    current_published_generation: Option<u64>,
) -> bool {
    let Some(current_published_generation) = current_published_generation else {
        return false;
    };
    binding.canonical_home == canonical_home
        && binding.physical_home_identity == physical_home_identity
        && binding.signature == *signature
        && binding.precise_attribution_provenance_epoch == attribution_safety.provenance_epoch
        && binding.precise_attribution_generation <= current_published_generation
        && binding.precise_attribution_generation <= attribution_safety.generation
        && binding.precise_attribution_unsafe_since_generation
            == attribution_safety.unsafe_since_generation
        && binding.precise_attribution_unsafe_id == attribution_safety.unsafe_id
        && binding.precise_attribution_current_scan_unsafe
            == attribution_safety.current_scan_unsafe_cause_detected
        && binding.precise_attribution_current_scan_incomplete
            == attribution_safety.current_scan_incomplete
}

fn sanitize_numeric_recent_usage_points(points: &mut [crate::models::RecentUsagePoint]) {
    for point in points {
        point.source_contribution_epoch = None;
        point.source_contributions.clear();
    }
}

fn startup_snapshot_from_persistent_numeric(
    cache: &PersistentNumericDashboardCacheV20,
) -> DashboardSnapshot {
    let recent_usage_24h = restore_persistent_numeric_recent_usage_points(&cache.recent_usage_24h);
    let recent_usage_7d = restore_persistent_numeric_recent_usage_points(&cache.recent_usage_7d);
    let recent_usage_30d = restore_persistent_numeric_recent_usage_points(&cache.recent_usage_30d);
    DashboardSnapshot {
        generated_at: cache.built_at.clone(),
        precise_recent_usage_covered_at: cache.coverage_at.clone(),
        settled_through: cache.settled_through.clone(),
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
        aggregate_boundary_unix: ExactUsageIndex::latest_eligible_aggregate_boundary(now_utc),
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
    current_published_generation: Option<u64>,
) -> Option<DashboardSnapshot> {
    hydrate_dashboard_aggregate_cache_once().ok()?;
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
                        persistent_numeric_cache_binding_matches_startup(
                            binding,
                            canonical_home,
                            signature,
                            physical_home_identity,
                            attribution_safety,
                            current_published_generation,
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

fn cached_v20_revision_for_startup() -> Option<u64> {
    DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()))
        .lock()
        .ok()
        .and_then(|guard| {
            guard.aggregate.as_ref().and_then(|cached| {
                matches!(
                    cached.persistent_version,
                    0 | DASHBOARD_AGGREGATE_CACHE_VERSION
                )
                .then_some(cached.signature.index_revision)
            })
        })
}

fn cached_dashboard_aggregate(
    signature: &DashboardScanSignature,
) -> Option<CachedDashboardAggregate> {
    hydrate_dashboard_aggregate_cache_once().ok()?;
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    cache
        .lock()
        .ok()
        .and_then(|guard| guard.aggregate.clone())
        .filter(|cached| &cached.signature == signature)
}

fn hydrate_dashboard_aggregate_cache_once() -> Result<(), String> {
    let cache = DASHBOARD_AGGREGATE_CACHE
        .get_or_init(|| Mutex::new(DashboardAggregateCacheState::default()));
    let mut guard = cache
        .lock()
        .map_err(|_| "精确 token numeric cache 内存状态不可用".to_string())?;
    if guard.persistent_loaded {
        return Ok(());
    }
    let persistent = load_persistent_dashboard_aggregate()?;
    guard.persistent_loaded = true;
    if guard.aggregate.is_none() {
        guard.aggregate = persistent;
    }
    Ok(())
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
        settled_through: None,
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
    // A summary refresh may run after a full V20 publish. Hydrate first so the
    // existing binding is carried forward instead of silently downgrading the
    // in-memory aggregate to an unbound snapshot.
    let _ = hydrate_dashboard_aggregate_cache_once();
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
            .ok()
            .flatten()
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
        *guard = Some(CachedUsageSummary {
            signature,
            summary,
            generated_at: OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into()),
        });
    }
}

fn load_persistent_dashboard_aggregate() -> Result<Option<CachedDashboardAggregate>, String> {
    let Some(path) = app_paths::token_aggregate_cache_path() else {
        return Ok(None);
    };
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "无法检查精确 token numeric cache {}：{error}",
                path.display()
            ));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "拒绝读取非普通文件形式的精确 token numeric cache：{}",
            path.display()
        ));
    }
    let data = fs::read(&path).map_err(|error| {
        format!(
            "无法读取精确 token numeric cache {}：{error}",
            path.display()
        )
    })?;
    let decoded = decode_persistent_dashboard_aggregate(&data).ok_or_else(|| {
        format!(
            "精确 token numeric cache 格式或可信绑定无效：{}",
            path.display()
        )
    })?;
    Ok(Some(decoded))
}

fn decode_persistent_dashboard_aggregate(data: &[u8]) -> Option<CachedDashboardAggregate> {
    let version = serde_json::from_slice::<serde_json::Value>(data)
        .ok()?
        .get("version")
        .and_then(serde_json::Value::as_u64)
        .and_then(|version| u32::try_from(version).ok())?;
    match version {
        DASHBOARD_AGGREGATE_CACHE_VERSION => {
            let cache = serde_json::from_slice::<PersistentNumericDashboardCacheV20>(data).ok()?;
            if cache.version != DASHBOARD_AGGREGATE_CACHE_VERSION
                || !persistent_numeric_cache_binding_is_well_formed(&cache.binding)
                || !valid_persistent_cache_timestamp(&cache.built_at)
                || cache
                    .coverage_at
                    .as_deref()
                    .is_some_and(|value| !valid_persistent_cache_timestamp(value))
                || cache
                    .settled_through
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
    let payload = PersistentNumericDashboardCacheV20 {
        version: DASHBOARD_AGGREGATE_CACHE_VERSION,
        binding: binding.clone(),
        built_at: snapshot.generated_at.clone(),
        coverage_at: snapshot.precise_recent_usage_covered_at.clone(),
        settled_through: snapshot.settled_through.clone(),
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
    let Ok(existing) = serde_json::from_slice::<PersistentNumericDashboardCacheV20>(&data) else {
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
        snapshot.precise_attribution_provenance_epoch =
            Some(attribution_safety.provenance_epoch.clone());
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
    snapshot.precise_observer_started_at_unix_micros =
        Some(observer_identity.started_at_unix_micros);
    snapshot.precise_observer_sequence = Some(observer_identity.sequence);
    snapshot.precise_attribution_provenance_epoch =
        Some(attribution_safety.provenance_epoch.clone());
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
    let coordinators = PRECISE_REFRESH_COORDINATORS.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut coordinators) = coordinators.lock() {
        coordinators.clear();
    }
    DASHBOARD_SCAN_SIGNATURE_COUNT.store(0, Ordering::Relaxed);
    PRECISE_REFRESH_SYNC_CALL_COUNT.store(0, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_precise_refresh_recency_for_testing() {
    let coordinators = PRECISE_REFRESH_COORDINATORS.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(coordinators) = coordinators.lock() {
        for coordinator in coordinators.values() {
            *coordinator
                .schedule
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                PreciseRefreshScheduleState::default();
        }
    }
}

#[cfg(test)]
fn wait_for_usage_summary_refreshes_for_testing() {
    for _ in 0..250 {
        let coordinators = PRECISE_REFRESH_COORDINATORS
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .map(|registry| registry.values().cloned().collect::<Vec<_>>())
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
pub(crate) fn set_precise_refresh_sync_hook_for_testing(hook: Option<PreciseRefreshSyncHook>) {
    let slot = PRECISE_REFRESH_SYNC_HOOK.get_or_init(|| Mutex::new(None));
    *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
}

#[cfg(test)]
pub(crate) fn set_precise_refresh_after_cutoff_hook_for_testing(
    hook: Option<PreciseRefreshCutoffHook>,
) {
    let slot = PRECISE_REFRESH_AFTER_CUTOFF_HOOK.get_or_init(|| Mutex::new(None));
    *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
}

#[cfg(test)]
pub(crate) fn set_precise_refresh_promotion_hook_for_testing(
    hook: Option<PreciseRefreshPromotionHook>,
) {
    let slot = PRECISE_REFRESH_PROMOTION_HOOK.get_or_init(|| Mutex::new(None));
    *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
}

#[cfg(test)]
pub(crate) fn set_precise_refresh_finish_hook_for_testing(hook: Option<PreciseRefreshFinishHook>) {
    let slot = PRECISE_REFRESH_FINISH_HOOK.get_or_init(|| Mutex::new(None));
    *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
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
    registry.retain(|_, coordinator| {
        Arc::strong_count(coordinator) > 1
            || coordinator
                .previous_completed_owner
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .as_ref()
                .is_some_and(|owner| {
                    Instant::now().saturating_duration_since(owner.completed_at)
                        < PRECISE_REFRESH_COMPLETED_OWNER_WINDOW
                })
    });
    registry
        .values()
        .filter(|coordinator| {
            coordinator
                .flight
                .lock()
                .map(|flight| flight.is_some())
                .unwrap_or(false)
        })
        .count()
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
