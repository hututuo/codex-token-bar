use super::{run_blocking_command, run_blocking_command_with_worker_start};
use super::window_auth::require_window_label;
use crate::core::dashboard::DashboardDataSource;
use crate::core::startup_trace;
use crate::core::unread::{UnreadObservation, UnreadObservationBuilder};
use crate::core::usage::cache_lifecycle::{self, UsageCacheStatus};
use crate::core::usage::token_count_jsonl::{self, TokenUsageSummarySnapshot};
use crate::models::{
    AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, PlatformCapabilities,
    PreciseDashboardProgress,
};
use crate::platform;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::future::Future;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;
use tauri::{AppHandle, Emitter};

pub(crate) const CODEX_HOME_SOURCE_CHANGED_EVENT: &str = "codex-home-source-changed";

static CODEX_HOME_TRANSITION_STATE: OnceLock<Mutex<CodexHomeTransitionState>> = OnceLock::new();
static PINNED_SQLITE_VIEW_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static PRECISE_DASHBOARD_REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);
#[cfg(unix)]
static PINNED_SQLITE_DESCRIPTOR_VIEW: OnceLock<Mutex<Option<PinnedSqliteDescriptorView>>> =
    OnceLock::new();
#[cfg(unix)]
static PINNED_SQLITE_VIEW_CLEANUP: OnceLock<Result<(), String>> = OnceLock::new();
#[cfg(test)]
static PINNED_SQLITE_VIEWS_CREATED: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SQLITE_LINK_MUTATIONS: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SOURCE_SESSION_ENTRIES_INSPECTED: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SOURCE_COUNTER_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

const PINNED_SESSION_FILE_LIMIT: usize = 64;
const PINNED_SESSION_FIRST_LINE_LIMIT: u64 = 262_144;
const PINNED_SESSION_TAIL_LIMIT: u64 = 4 * 1024 * 1024;
const PINNED_SESSION_LOOKBACK_SECONDS: i64 = 30;
#[cfg(unix)]
const PINNED_STATE_FILE_LIMIT: u64 = 16 * 1024 * 1024;

#[cfg(unix)]
struct PinnedSqliteDescriptorView {
    directory: PathBuf,
    files: HashMap<String, PinnedDescriptorFile>,
    _owner_lock: std::fs::File,
}

#[cfg(unix)]
struct PinnedSqliteDescriptorViewLease {
    view: Option<PinnedSqliteDescriptorView>,
}

#[cfg(unix)]
impl PinnedSqliteDescriptorViewLease {
    fn acquire(create_if_missing: bool) -> Result<Self, String> {
        let existing = {
            let mut slot = pinned_sqlite_descriptor_view().lock().map_err(|_| {
                "pinned unread SQLite descriptor view lock was poisoned".to_string()
            })?;
            slot.take()
        };
        let view = match (existing, create_if_missing) {
            (Some(view), _) => Some(view),
            (None, true) => Some(create_pinned_sqlite_descriptor_view()?),
            (None, false) => None,
        };
        Ok(Self { view })
    }

    fn view_mut(&mut self) -> Option<&mut PinnedSqliteDescriptorView> {
        self.view.as_mut()
    }
}

#[cfg(unix)]
impl Drop for PinnedSqliteDescriptorViewLease {
    fn drop(&mut self) {
        let Some(view) = self.view.take() else {
            return;
        };
        let mut slot = pinned_sqlite_descriptor_view()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if slot.is_none() {
            *slot = Some(view);
        }
    }
}

#[cfg(unix)]
struct PinnedDescriptorFile {
    handle: std::fs::File,
    device: u64,
    inode: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeSourceEnvelope {
    pub codex_home: CodexHomeStatus,
    pub canonical_home_key: String,
    pub physical_home_key: String,
    pub transition_generation: u64,
}

#[derive(Debug)]
pub(crate) struct CodexHomeSourceTransitionClaim {
    pub envelope: CodexHomeSourceEnvelope,
    pub claim_nonce: u64,
}

struct CodexHomeSourceTransitionClaimOwner<'a> {
    state: &'a Mutex<CodexHomeTransitionState>,
    claim: Option<CodexHomeSourceTransitionClaim>,
}

impl<'a> CodexHomeSourceTransitionClaimOwner<'a> {
    fn new(
        state: &'a Mutex<CodexHomeTransitionState>,
        claim: CodexHomeSourceTransitionClaim,
    ) -> Self {
        Self {
            state,
            claim: Some(claim),
        }
    }

    fn claim(&self) -> &CodexHomeSourceTransitionClaim {
        self.claim
            .as_ref()
            .expect("Codex Home transition claim owner was already finished")
    }

    fn finish(mut self, published: bool) -> Result<(), String> {
        let claim = self.claim();
        with_locked_codex_home_transition_state(self.state, |transition| {
            finish_codex_home_source_transition_claim_in_state(transition, claim, published);
            Ok(())
        })?;
        self.claim = None;
        Ok(())
    }
}

impl Drop for CodexHomeSourceTransitionClaimOwner<'_> {
    fn drop(&mut self) {
        let Some(claim) = self.claim.take() else {
            return;
        };
        let mut transition = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        finish_codex_home_source_transition_claim_in_state(&mut transition, &claim, false);
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeSourceToken {
    pub canonical_home_key: String,
    pub physical_home_key: String,
    pub transition_generation: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct CapturedCodexHomeSource {
    pub source_token: CodexHomeSourceToken,
    pub codex_home: PathBuf,
    pub(crate) source_path: PathBuf,
}

pub(crate) struct PinnedCodexHomeSource {
    _handle: std::fs::File,
    read_path: PathBuf,
    observation: Option<UnreadObservation>,
    pub source_scope_key: String,
}

impl PinnedCodexHomeSource {
    pub(crate) fn read_path(&self) -> &Path {
        &self.read_path
    }

    pub(crate) fn observation(&self) -> Option<&UnreadObservation> {
        self.observation.as_ref()
    }
}

#[derive(Default)]
struct CodexHomeTransitionState {
    canonical_home_key: Option<String>,
    physical_home_key: Option<String>,
    codex_home_path: Option<PathBuf>,
    source_path: Option<PathBuf>,
    source_kind: Option<String>,
    source_exists: bool,
    pending_publication_generation: Option<u64>,
    in_flight_publication: Option<(u64, u64)>,
    next_claim_nonce: u64,
    transition_generation: u64,
}

#[cfg(test)]
impl CodexHomeSourceEnvelope {
    pub(crate) fn source_token(&self) -> CodexHomeSourceToken {
        CodexHomeSourceToken {
            canonical_home_key: self.canonical_home_key.clone(),
            physical_home_key: self.physical_home_key.clone(),
            transition_generation: self.transition_generation,
        }
    }
}

#[tauri::command]
pub async fn get_codex_home(
    window: tauri::WebviewWindow,
) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "get_codex_home")?;
    // 状态解析含设置读取与物理身份探测（磁盘 IO），startup_trace 埋点也写盘，
    // 一并移交阻塞线程池。
    run_blocking_command(|| {
        startup_trace::mark("command get_codex_home start");
        let result = with_codex_home_transition_state(|transition| {
            resolve_codex_home_source(transition, platform::default_codex_home_status())
        });
        startup_trace::mark("command get_codex_home end");
        result
    })
    .await
}

#[tauri::command]
pub async fn set_codex_home(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    path: String,
) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "set_codex_home")?;
    persist_codex_home_transition(app, move || platform::save_codex_home(&path)).await
}

#[tauri::command]
pub async fn reset_codex_home(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "reset_codex_home")?;
    persist_codex_home_transition(app, platform::reset_codex_home).await
}

async fn persist_codex_home_transition(
    app: tauri::AppHandle,
    save: impl FnOnce() -> Result<CodexHomeStatus, String> + Send + 'static,
) -> Result<CodexHomeSourceEnvelope, String> {
    // 保存（磁盘写+fsync）与状态推进在阻塞池的锁内完成；事件发布走 claim
    // 模式在锁外执行。发布失败只记录，pending 代次保留，由任一后续
    // emit_detected_source_transition 调用点自愈补发。
    let envelope = run_blocking_command(move || {
        with_codex_home_transition_state(|transition| {
            commit_codex_home_transition(transition, save)
        })
    })
    .await?;
    if let Err(error) = emit_detected_source_transition(&app) {
        startup_trace::mark_performance(format!(
            "codex home source event publish failed generation={} error={error}",
            envelope.transition_generation
        ));
    }
    Ok(envelope)
}

fn with_codex_home_transition_state<T>(
    operation: impl FnOnce(&mut CodexHomeTransitionState) -> Result<T, String>,
) -> Result<T, String> {
    let state = codex_home_transition_state();
    with_locked_codex_home_transition_state(state, operation)
}

fn codex_home_transition_state() -> &'static Mutex<CodexHomeTransitionState> {
    CODEX_HOME_TRANSITION_STATE.get_or_init(|| Mutex::new(CodexHomeTransitionState::default()))
}

fn with_locked_codex_home_transition_state<T>(
    state: &Mutex<CodexHomeTransitionState>,
    operation: impl FnOnce(&mut CodexHomeTransitionState) -> Result<T, String>,
) -> Result<T, String> {
    let mut state = state
        .lock()
        .map_err(|_| "Codex Home source transition lock was poisoned".to_string())?;
    operation(&mut state)
}

pub(crate) fn capture_codex_home_source(
    expected: Option<&CodexHomeSourceToken>,
) -> Result<CapturedCodexHomeSource, String> {
    with_codex_home_transition_state(|transition| {
        if transition.canonical_home_key.is_none() {
            resolve_codex_home_source(transition, platform::default_codex_home_status())?;
        } else {
            refresh_codex_home_source_identity(transition)?;
        }
        let captured = match expected {
            Some(expected) => capture_codex_home_source_from_state(transition, expected)?,
            None => {
                let current = current_codex_home_source_token(transition)?;
                capture_codex_home_source_from_state(transition, &current)?
            }
        };
        Ok(captured)
    })
}

fn claim_codex_home_source_transition_from(
    state: &Mutex<CodexHomeTransitionState>,
) -> Result<Option<CodexHomeSourceTransitionClaim>, String> {
    with_locked_codex_home_transition_state(state, claim_codex_home_source_transition_in_state)
}

pub(crate) fn emit_detected_source_transition(app: &AppHandle) -> Result<bool, String> {
    emit_detected_source_transition_from(codex_home_transition_state(), |envelope| {
        let payload = serde_json::to_string(envelope).map_err(|error| error.to_string())?;
        app.emit_str(CODEX_HOME_SOURCE_CHANGED_EVENT, payload)
            .map_err(|error| error.to_string())
    })
}

fn emit_detected_source_transition_from(
    state: &Mutex<CodexHomeTransitionState>,
    publish: impl FnOnce(&CodexHomeSourceEnvelope) -> Result<(), String>,
) -> Result<bool, String> {
    let Some(claim) = claim_codex_home_source_transition_from(state)? else {
        return Ok(false);
    };
    let owner = CodexHomeSourceTransitionClaimOwner::new(state, claim);
    let publish_result = publish(&owner.claim().envelope);
    owner.finish(publish_result.is_ok())?;
    publish_result.map(|_| true)
}

fn claim_codex_home_source_transition_in_state(
    transition: &mut CodexHomeTransitionState,
) -> Result<Option<CodexHomeSourceTransitionClaim>, String> {
    if transition.canonical_home_key.is_none() {
        return Ok(None);
    }
    refresh_codex_home_source_identity(transition)?;
    let Some(generation) = transition.pending_publication_generation else {
        return Ok(None);
    };
    if transition.in_flight_publication.is_some() {
        return Ok(None);
    }
    transition.next_claim_nonce = transition
        .next_claim_nonce
        .checked_add(1)
        .ok_or_else(|| "Codex Home source event claim nonce overflow".to_string())?;
    let claim_nonce = transition.next_claim_nonce;
    transition.in_flight_publication = Some((generation, claim_nonce));
    Ok(Some(CodexHomeSourceTransitionClaim {
        envelope: current_codex_home_source_envelope(transition)?,
        claim_nonce,
    }))
}

fn finish_codex_home_source_transition_claim_in_state(
    transition: &mut CodexHomeTransitionState,
    claim: &CodexHomeSourceTransitionClaim,
    published: bool,
) {
    let generation = claim.envelope.transition_generation;
    if transition.in_flight_publication != Some((generation, claim.claim_nonce)) {
        return;
    }
    transition.in_flight_publication = None;
    if published && transition.pending_publication_generation == Some(generation) {
        transition.pending_publication_generation = None;
    }
}

pub(crate) fn validate_codex_home_source(
    source_token: &CodexHomeSourceToken,
) -> Result<(), String> {
    with_codex_home_transition_state(|transition| {
        refresh_codex_home_source_identity(transition)?;
        validate_codex_home_source_in_state(transition, source_token)
    })
}

pub(crate) fn validate_captured_codex_home_source(
    captured: &CapturedCodexHomeSource,
) -> Result<(), String> {
    let transition_validation = validate_codex_home_source(&captured.source_token);
    let resolved = canonical_home_path(&captured.source_path);
    let current = CodexHomeSourceToken {
        canonical_home_key: platform_path_key(&resolved),
        physical_home_key: physical_home_key(&resolved)?,
        transition_generation: captured.source_token.transition_generation,
    };
    if current.canonical_home_key != captured.source_token.canonical_home_key
        || current.physical_home_key != captured.source_token.physical_home_key
    {
        return Err("Codex Home physical identity changed before source-bound work".into());
    }
    transition_validation
}

#[cfg(unix)]
pub(crate) fn pin_captured_codex_home_source(
    captured: &CapturedCodexHomeSource,
) -> Result<PinnedCodexHomeSource, String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

    #[cfg(target_os = "macos")]
    const DIRECTORY_NOFOLLOW_FLAGS: i32 = 0x0010_0000 | 0x0000_0100;
    #[cfg(not(target_os = "macos"))]
    const DIRECTORY_NOFOLLOW_FLAGS: i32 = 0x0001_0000 | 0x0002_0000;

    let handle = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(DIRECTORY_NOFOLLOW_FLAGS)
        .open(&captured.codex_home)
        .map_err(|error| format!("failed to pin Codex Home source: {error}"))?;
    let metadata = handle
        .metadata()
        .map_err(|error| format!("failed to inspect pinned Codex Home source: {error}"))?;
    let physical_home_key = format!("unix:{}:{}", metadata.dev(), metadata.ino());
    if physical_home_key != captured.source_token.physical_home_key {
        return Err("Codex Home physical identity changed before it could be pinned".into());
    }
    let source_scope_key = format!(
        "{}|{}",
        captured.source_token.canonical_home_key, captured.source_token.physical_home_key
    );
    let observation = capture_pinned_unread_observation(&handle, &captured.codex_home)?;
    Ok(PinnedCodexHomeSource {
        _handle: handle,
        read_path: PathBuf::new(),
        observation: Some(observation),
        source_scope_key,
    })
}

#[cfg(unix)]
fn capture_pinned_unread_observation(
    root: &std::fs::File,
    source_root: &Path,
) -> Result<UnreadObservation, String> {
    use std::io::Read;

    ensure_stale_pinned_sqlite_views_cleaned()?;
    let state = match open_optional_pinned_descriptor_file(root, ".codex-global-state.json")? {
        Some(file) => {
            let size = file
                .handle
                .metadata()
                .map_err(|error| format!("failed to inspect pinned native unread state: {error}"))?
                .len();
            if size > PINNED_STATE_FILE_LIMIT {
                return Err(format!(
                    "pinned native unread state exceeds the {} byte safety limit",
                    PINNED_STATE_FILE_LIMIT
                ));
            }
            let mut data = Vec::with_capacity(size as usize);
            file.handle
                .take(PINNED_STATE_FILE_LIMIT + 1)
                .read_to_end(&mut data)
                .map_err(|error| format!("failed to read pinned native unread state: {error}"))?;
            if data.len() as u64 > PINNED_STATE_FILE_LIMIT {
                return Err(format!(
                    "pinned native unread state exceeds the {} byte safety limit",
                    PINNED_STATE_FILE_LIMIT
                ));
            }
            Some(data)
        }
        None => None,
    };
    let mut builder = UnreadObservationBuilder::from_native_state(state.as_deref())?;
    observe_recent_pinned_sessions(root, &mut builder)?;
    if !builder.has_native_unread_ids() {
        let mut lease = PinnedSqliteDescriptorViewLease::acquire(false)?;
        if let Some(view) = lease.view_mut() {
            install_pinned_sqlite_descriptor_files(view, None, HashMap::new())?;
        }
        return builder.finish(None);
    }

    let mut lease = PinnedSqliteDescriptorViewLease::acquire(true)?;
    let view = lease
        .view_mut()
        .ok_or_else(|| "pinned unread SQLite descriptor view is unavailable".to_string())?;
    refresh_pinned_sqlite_descriptor_view(root, source_root, view)?;
    builder.finish(Some(&view.directory.join("state_5.sqlite")))
}

#[cfg(unix)]
fn observe_recent_pinned_sessions(
    root: &std::fs::File,
    builder: &mut UnreadObservationBuilder,
) -> Result<(), String> {
    use rustix::fs::{openat, Mode, OFlags};

    let sessions = match openat(
        root,
        "sessions",
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::DIRECTORY,
        Mode::empty(),
    ) {
        Ok(fd) => fd,
        Err(rustix::io::Errno::NOENT) => return Ok(()),
        Err(error) => return Err(format!("failed to open pinned sessions: {error}")),
    };
    validate_canonical_sessions_root(&sessions)?;
    let now_utc = time::OffsetDateTime::now_utc();
    let local_offset = crate::core::localtime::local_offset();
    let cutoff = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64 - PINNED_SESSION_LOOKBACK_SECONDS)
        .unwrap_or(i64::MAX);
    let mut candidates = Vec::new();
    for date_path in recent_session_date_paths(now_utc, local_offset) {
        let Some(day) = open_pinned_directory_path(&sessions, &date_path)? else {
            continue;
        };
        collect_recent_pinned_session_candidates(&day, &date_path, cutoff, &mut candidates)?;
    }
    candidates.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    for (relative_path, _) in candidates.into_iter().take(PINNED_SESSION_FILE_LIMIT) {
        observe_pinned_session_candidate(&sessions, &relative_path, cutoff, builder)?;
    }
    Ok(())
}

#[cfg(unix)]
fn observe_pinned_session_candidate(
    sessions: &impl std::os::fd::AsFd,
    relative_path: &Path,
    cutoff: i64,
    builder: &mut UnreadObservationBuilder,
) -> Result<(), String> {
    use rustix::fs::{fstat, openat, FileType, Mode, OFlags};
    use std::io::{Read, Seek, SeekFrom};

    let mut current = rustix::io::dup(sessions)
        .map_err(|error| format!("failed to duplicate pinned sessions handle: {error}"))?;
    let mut components = relative_path.components().peekable();
    while let Some(component) = components.next() {
        let flags = if components.peek().is_some() {
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::DIRECTORY
        } else {
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW
        };
        current = openat(&current, component.as_os_str(), flags, Mode::empty())
            .map_err(|error| format!("failed to open pinned session candidate: {error}"))?;
    }
    let stat = fstat(&current)
        .map_err(|error| format!("failed to inspect pinned session candidate: {error}"))?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err("pinned session candidate stopped being a regular file".into());
    }
    if stat.st_mtime < cutoff {
        return Ok(());
    }
    let mut file = std::fs::File::from(current);
    let mut first = vec![0; PINNED_SESSION_FIRST_LINE_LIMIT as usize];
    let first_len = file
        .read(&mut first)
        .map_err(|error| format!("failed to read pinned session head: {error}"))?;
    first.truncate(
        first[..first_len]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|index| index + 1)
            .unwrap_or(first_len),
    );
    let size = stat.st_size.max(0) as u64;
    let tail_start = size.saturating_sub(PINNED_SESSION_TAIL_LIMIT);
    file.seek(SeekFrom::Start(tail_start))
        .map_err(|error| format!("failed to seek pinned session tail: {error}"))?;
    let mut tail = Vec::with_capacity((size - tail_start) as usize);
    file.take(PINNED_SESSION_TAIL_LIMIT)
        .read_to_end(&mut tail)
        .map_err(|error| format!("failed to read pinned session tail: {error}"))?;
    builder.observe_session(&first, &tail, tail_start > 0);
    Ok(())
}

#[cfg(unix)]
fn pinned_sqlite_descriptor_view() -> &'static Mutex<Option<PinnedSqliteDescriptorView>> {
    PINNED_SQLITE_DESCRIPTOR_VIEW.get_or_init(|| Mutex::new(None))
}

#[cfg(unix)]
fn create_pinned_sqlite_descriptor_view() -> Result<PinnedSqliteDescriptorView, String> {
    use std::os::unix::fs::DirBuilderExt;

    for _ in 0..32 {
        let sequence = PINNED_SQLITE_VIEW_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let directory = std::env::temp_dir().join(format!(
            "codex-token-bar-pinned-sqlite-view-{}-{sequence}-{timestamp}",
            std::process::id()
        ));
        let mut builder = std::fs::DirBuilder::new();
        builder.mode(0o700);
        match builder.create(&directory) {
            Ok(()) => {
                let owner_path = directory.join(".owner.lock");
                let owner_lock = std::fs::OpenOptions::new()
                    .create_new(true)
                    .read(true)
                    .write(true)
                    .open(&owner_path)
                    .map_err(|error| {
                        format!("failed to create pinned unread SQLite owner lock: {error}")
                    })?;
                rustix::fs::flock(
                    &owner_lock,
                    rustix::fs::FlockOperation::LockExclusive,
                )
                .map_err(|error| {
                    format!("failed to lock pinned unread SQLite descriptor view: {error}")
                })?;
                #[cfg(test)]
                PINNED_SQLITE_VIEWS_CREATED.fetch_add(1, Ordering::Relaxed);
                return Ok(PinnedSqliteDescriptorView {
                    directory,
                    files: HashMap::new(),
                    _owner_lock: owner_lock,
                });
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "failed to create pinned unread SQLite descriptor view: {error}"
                ))
            }
        }
    }
    Err("failed to allocate pinned unread SQLite descriptor view".into())
}

#[cfg(unix)]
fn ensure_stale_pinned_sqlite_views_cleaned() -> Result<(), String> {
    PINNED_SQLITE_VIEW_CLEANUP
        .get_or_init(clean_stale_pinned_sqlite_descriptor_views)
        .clone()
}

#[cfg(unix)]
fn clean_stale_pinned_sqlite_descriptor_views() -> Result<(), String> {
    const PREFIX: &str = "codex-token-bar-pinned-sqlite-view-";
    let entries = std::fs::read_dir(std::env::temp_dir())
        .map_err(|error| format!("failed to inspect pinned SQLite view root: {error}"))?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_string_lossy().starts_with(PREFIX) {
            continue;
        }
        let path = entry.path();
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_dir() => metadata,
            _ => continue,
        };
        let owner = match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path.join(".owner.lock"))
        {
            Ok(owner) => owner,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let old_enough = metadata
                    .modified()
                    .ok()
                    .and_then(|modified| modified.elapsed().ok())
                    .is_some_and(|age| age >= std::time::Duration::from_secs(60));
                if old_enough {
                    let _ = std::fs::remove_dir_all(&path);
                }
                continue;
            }
            Err(_) => continue,
        };
        match rustix::fs::flock(
            &owner,
            rustix::fs::FlockOperation::NonBlockingLockExclusive,
        ) {
            Ok(()) => {
                let _ = std::fs::remove_dir_all(&path);
            }
            Err(rustix::io::Errno::WOULDBLOCK) => {}
            Err(_) => {}
        }
    }
    Ok(())
}

#[cfg(unix)]
fn refresh_pinned_sqlite_descriptor_view(
    root: &std::fs::File,
    source_root: &Path,
    view: &mut PinnedSqliteDescriptorView,
) -> Result<(), String> {
    let mut desired = HashMap::new();
    let database = open_optional_pinned_descriptor_file(root, "state_5.sqlite")?.ok_or_else(|| {
        "pinned unread observation requires state_5.sqlite when native unread state exists"
            .to_string()
    })?;
    desired.insert("state_5.sqlite".to_string(), database);
    for name in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
        if let Some(file) = open_optional_pinned_descriptor_file(root, name)? {
            desired.insert(name.to_string(), file);
        }
    }
    validate_pinned_descriptor_set(root, &desired)?;
    install_pinned_sqlite_descriptor_files(view, Some(source_root), desired)
}

#[cfg(unix)]
fn validate_pinned_descriptor_set(
    root: &std::fs::File,
    files: &HashMap<String, PinnedDescriptorFile>,
) -> Result<(), String> {
    use rustix::fs::{statat, AtFlags, FileType};

    for name in ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
        match (statat(root, name, AtFlags::SYMLINK_NOFOLLOW), files.get(name)) {
            (Ok(stat), Some(file))
                if FileType::from_raw_mode(stat.st_mode) == FileType::RegularFile
                    && u64::try_from(stat.st_dev).ok() == Some(file.device)
                    && stat.st_ino == file.inode => {}
            (Err(rustix::io::Errno::NOENT), None) => {}
            _ => {
                return Err(format!(
                    "pinned unread SQLite descriptor set changed while it was being captured: {name}"
                ))
            }
        }
    }
    Ok(())
}

#[cfg(unix)]
fn open_optional_pinned_descriptor_file(
    parent: &impl std::os::fd::AsFd,
    name: &str,
) -> Result<Option<PinnedDescriptorFile>, String> {
    use rustix::fs::{fstat, openat, statat, AtFlags, FileType, Mode, OFlags};

    let before = match statat(parent, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(stat) => stat,
        Err(rustix::io::Errno::NOENT) => return Ok(None),
        Err(error) => return Err(format!("failed to inspect pinned unread entry {name}: {error}")),
    };
    match FileType::from_raw_mode(before.st_mode) {
        FileType::RegularFile => {}
        FileType::Directory => return Err(format!("pinned unread file {name} is a directory")),
        FileType::Symlink => {
            return Err(format!(
                "pinned unread entry {name} is a symlink and was rejected"
            ))
        }
        other => {
            return Err(format!(
                "pinned unread entry {name} has unsupported type {other:?}"
            ))
        }
    }
    let handle = openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
        Mode::empty(),
    )
    .map_err(|error| format!("failed to open pinned unread file {name}: {error}"))?;
    let after = fstat(&handle)
        .map_err(|error| format!("failed to inspect opened pinned unread file {name}: {error}"))?;
    if before.st_dev != after.st_dev || before.st_ino != after.st_ino {
        return Err(format!(
            "pinned unread entry {name} changed while it was being opened"
        ));
    }
    Ok(Some(PinnedDescriptorFile {
        handle: std::fs::File::from(handle),
        device: u64::try_from(after.st_dev)
            .map_err(|_| format!("pinned unread entry {name} has an invalid device id"))?,
        inode: after.st_ino,
    }))
}

#[cfg(unix)]
fn install_pinned_sqlite_descriptor_files(
    view: &mut PinnedSqliteDescriptorView,
    source_root: Option<&Path>,
    mut desired: HashMap<String, PinnedDescriptorFile>,
) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;

    for name in ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
        if !desired.contains_key(name) {
            let destination = view.directory.join(name);
            match std::fs::remove_file(destination) {
                Ok(()) => {
                    #[cfg(test)]
                    PINNED_SQLITE_LINK_MUTATIONS.fetch_add(1, Ordering::Relaxed);
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(format!(
                        "failed to remove stale pinned unread SQLite descriptor {name}: {error}"
                    ))
                }
            }
        }
    }
    let names = desired.keys().cloned().collect::<Vec<_>>();
    for name in names {
        let unchanged = view.files.get(&name).is_some_and(|existing| {
            let replacement = desired.get(&name).expect("desired descriptor disappeared");
            existing.device == replacement.device
                && existing.inode == replacement.inode
                && std::fs::symlink_metadata(view.directory.join(&name)).is_ok_and(|metadata| {
                    metadata.file_type().is_file()
                        && metadata.dev() == existing.device
                        && metadata.ino() == existing.inode
                })
        });
        if unchanged {
            if let Some(existing) = view.files.remove(&name) {
                desired.insert(name, existing);
            }
            continue;
        }
        let descriptor = desired
            .get(&name)
            .ok_or_else(|| "desired pinned SQLite descriptor disappeared".to_string())?;
        let source_root = source_root.ok_or_else(|| {
            "pinned unread SQLite source root is unavailable for descriptor publication"
                .to_string()
        })?;
        let destination = view.directory.join(&name);
        match std::fs::remove_file(&destination) {
            Ok(()) => {
                #[cfg(test)]
                PINNED_SQLITE_LINK_MUTATIONS.fetch_add(1, Ordering::Relaxed);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "failed to replace pinned unread SQLite descriptor {name}: {error}"
                ))
            }
        }
        std::fs::hard_link(source_root.join(&name), &destination).map_err(|error| {
            format!(
                "failed to publish pinned unread SQLite descriptor {name} without copying data: {error}"
            )
        })?;
        let published = std::fs::symlink_metadata(&destination).map_err(|error| {
            format!("failed to inspect pinned unread SQLite descriptor {name}: {error}")
        })?;
        if !published.file_type().is_file()
            || published.dev() != descriptor.device
            || published.ino() != descriptor.inode
        {
            let _ = std::fs::remove_file(&destination);
            return Err(format!(
                "pinned unread SQLite descriptor {name} changed while it was being published"
            ));
        }
        #[cfg(test)]
        PINNED_SQLITE_LINK_MUTATIONS.fetch_add(1, Ordering::Relaxed);
    }
    view.files = desired;
    Ok(())
}

#[cfg(unix)]
fn recent_session_date_paths(
    now_utc: time::OffsetDateTime,
    local_offset: time::UtcOffset,
) -> Vec<PathBuf> {
    let mut dates = std::collections::BTreeSet::new();
    for current in [now_utc.date(), now_utc.to_offset(local_offset).date()] {
        dates.insert(current);
        if let Some(previous) = current.previous_day() {
            dates.insert(previous);
        }
    }
    dates
        .into_iter()
        .map(|date| {
            PathBuf::from(format!("{:04}", date.year()))
                .join(format!("{:02}", u8::from(date.month())))
                .join(format!("{:02}", date.day()))
        })
        .collect()
}

#[cfg(unix)]
fn open_pinned_directory_path(
    root: &impl std::os::fd::AsFd,
    path: &Path,
) -> Result<Option<rustix::fd::OwnedFd>, String> {
    use rustix::fs::{openat, Mode, OFlags};

    let mut current = rustix::io::dup(root)
        .map_err(|error| format!("failed to duplicate pinned sessions root: {error}"))?;
    for component in path.components() {
        current = match openat(
            &current,
            component.as_os_str(),
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::DIRECTORY,
            Mode::empty(),
        ) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::NOENT) => return Ok(None),
            Err(error) => {
                return Err(format!("failed to open pinned session date directory: {error}"))
            }
        };
    }
    Ok(Some(current))
}

#[cfg(unix)]
fn validate_canonical_sessions_root(root: &impl std::os::fd::AsFd) -> Result<(), String> {
    use rustix::fs::{statat, AtFlags, Dir, FileType};
    let mut directory = Dir::read_from(root)
        .map_err(|error| format!("failed to enumerate pinned sessions root: {error}"))?;
    while let Some(entry) = directory.read() {
        let entry = entry.map_err(|error| format!("failed to enumerate pinned sessions root: {error}"))?;
        let name = entry.file_name().to_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        let text = String::from_utf8_lossy(name);
        let stat = statat(root, text.as_ref(), AtFlags::SYMLINK_NOFOLLOW)
            .map_err(|error| format!("failed to inspect pinned sessions root: {error}"))?;
        let file_type = FileType::from_raw_mode(stat.st_mode);
        if text.starts_with('.')
            && !text.to_ascii_lowercase().ends_with(".jsonl")
            && file_type == FileType::RegularFile
        {
            continue;
        }
        if text.len() != 4
            || !text.bytes().all(|byte| byte.is_ascii_digit())
            || file_type != FileType::Directory
        {
            return Err("non-canonical sessions layout cannot be observed safely".into());
        }
    }
    Ok(())
}

#[cfg(unix)]
fn collect_recent_pinned_session_candidates<Fd: std::os::fd::AsFd>(
    parent: Fd,
    relative_root: &Path,
    cutoff: i64,
    candidates: &mut Vec<(PathBuf, (i64, i64))>,
) -> Result<(), String> {
    use rustix::fs::{openat, statat, AtFlags, Dir, FileType, Mode, OFlags};
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let mut directory = Dir::read_from(&parent)
        .map_err(|error| format!("failed to enumerate pinned sessions: {error}"))?;
    while let Some(entry) = directory.read() {
        let entry = entry.map_err(|error| format!("failed to enumerate pinned sessions: {error}"))?;
        let bytes = entry.file_name().to_bytes();
        if bytes == b"." || bytes == b".." {
            continue;
        }
        #[cfg(test)]
        PINNED_SOURCE_SESSION_ENTRIES_INSPECTED.fetch_add(1, Ordering::Relaxed);
        let child_name = OsStr::from_bytes(bytes);
        let child_name_text = child_name.to_string_lossy();
        let stat = statat(&parent, child_name_text.as_ref(), AtFlags::SYMLINK_NOFOLLOW)
            .map_err(|error| format!("failed to inspect pinned session entry: {error}"))?;
        match FileType::from_raw_mode(stat.st_mode) {
            FileType::Directory => {
                let fd = openat(
                    &parent,
                    child_name_text.as_ref(),
                    OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::DIRECTORY,
                    Mode::empty(),
                )
                .map_err(|error| format!("failed to open pinned session directory: {error}"))?;
                collect_recent_pinned_session_candidates(
                    &fd,
                    &relative_root.join(child_name),
                    cutoff,
                    candidates,
                )?;
            }
            FileType::RegularFile => {
                if child_name
                    .to_string_lossy()
                    .to_ascii_lowercase()
                    .ends_with(".jsonl")
                    && stat.st_mtime >= cutoff
                {
                    candidates.push((
                        relative_root.join(child_name),
                        (stat.st_mtime, stat.st_mtime_nsec),
                    ));
                    if candidates.len() > PINNED_SESSION_FILE_LIMIT {
                        candidates.sort_by(|left, right| {
                            right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0))
                        });
                        candidates.truncate(PINNED_SESSION_FILE_LIMIT);
                    }
                }
            }
            FileType::Symlink => {
                return Err("pinned session entry is a symlink and was rejected".into())
            }
            _ => return Err("pinned session entry has an unsupported type".into()),
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) fn reset_pinned_source_observation_counters_for_test() {
    PINNED_SQLITE_VIEWS_CREATED.store(0, Ordering::Relaxed);
    PINNED_SQLITE_LINK_MUTATIONS.store(0, Ordering::Relaxed);
    PINNED_SOURCE_SESSION_ENTRIES_INSPECTED.store(0, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn pinned_source_counter_test_guard() -> std::sync::MutexGuard<'static, ()> {
    PINNED_SOURCE_COUNTER_TEST_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
pub(crate) fn pinned_sqlite_view_create_count_for_test() -> u64 {
    PINNED_SQLITE_VIEWS_CREATED.load(Ordering::Relaxed)
}

#[cfg(test)]
pub(crate) fn pinned_sqlite_link_mutation_count_for_test() -> u64 {
    PINNED_SQLITE_LINK_MUTATIONS.load(Ordering::Relaxed)
}

#[cfg(test)]
pub(crate) fn pinned_source_inspected_count_for_test() -> u64 {
    PINNED_SOURCE_SESSION_ENTRIES_INSPECTED.load(Ordering::Relaxed)
}

#[cfg(windows)]
pub(crate) fn pin_captured_codex_home_source(
    captured: &CapturedCodexHomeSource,
) -> Result<PinnedCodexHomeSource, String> {
    use std::fs::OpenOptions;
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_SHARE_WRITE: u32 = 0x0000_0002;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;

    let handle = OpenOptions::new()
        .read(true)
        // Denying delete sharing keeps the configured path bound to this directory
        // until the source-bound read and acknowledgement complete.
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(&captured.codex_home)
        .map_err(|error| format!("failed to pin Codex Home source: {error}"))?;
    let (volume, file_id) = windows_home_identity(&handle)
        .map_err(|error| format!("failed to inspect pinned Codex Home source: {error}"))?;
    let physical_home_key = format!("windows:{volume}:{file_id}");
    if physical_home_key != captured.source_token.physical_home_key {
        return Err("Codex Home physical identity changed before it could be pinned".into());
    }
    use std::os::windows::fs::MetadataExt;
    if handle
        .metadata()
        .map_err(|error| format!("failed to inspect pinned Codex Home attributes: {error}"))?
        .file_attributes()
        & FILE_ATTRIBUTE_REPARSE_POINT
        != 0
    {
        return Err("canonical Codex Home target is a reparse point".into());
    }
    Ok(PinnedCodexHomeSource {
        _handle: handle,
        read_path: captured.codex_home.clone(),
        observation: None,
        source_scope_key: format!(
            "{}|{}",
            captured.source_token.canonical_home_key,
            captured.source_token.physical_home_key
        ),
    })
}

#[cfg(not(any(unix, windows)))]
pub(crate) fn pin_captured_codex_home_source(
    _captured: &CapturedCodexHomeSource,
) -> Result<PinnedCodexHomeSource, String> {
    Err("pinned Codex Home reads are unsupported on this platform".into())
}

pub(crate) fn with_valid_codex_home_source<T>(
    source_token: &CodexHomeSourceToken,
    operation: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    with_valid_codex_home_source_in_state(
        codex_home_transition_state(),
        source_token,
        operation,
    )
}

fn with_valid_codex_home_source_in_state<T>(
    state: &Mutex<CodexHomeTransitionState>,
    source_token: &CodexHomeSourceToken,
    operation: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    validate_codex_home_source_in_mutex(state, source_token)?;
    let result = operation()?;
    validate_codex_home_source_in_mutex(state, source_token)?;
    Ok(result)
}

fn validate_codex_home_source_in_mutex(
    state: &Mutex<CodexHomeTransitionState>,
    source_token: &CodexHomeSourceToken,
) -> Result<(), String> {
    with_locked_codex_home_transition_state(state, |transition| {
        refresh_codex_home_source_identity(transition)?;
        validate_codex_home_source_in_state(transition, source_token)
    })
}

fn commit_codex_home_transition(
    transition: &mut CodexHomeTransitionState,
    save: impl FnOnce() -> Result<CodexHomeStatus, String>,
) -> Result<CodexHomeSourceEnvelope, String> {
    let codex_home = save()?;
    let envelope = resolve_codex_home_source(transition, codex_home)?;
    // 锁内只登记待发布代次，不做 emit；同路径重设也照常登记，保持
    // "每次成功保存都对外发布一次" 的既有可见行为。
    transition.pending_publication_generation = Some(envelope.transition_generation);
    transition.in_flight_publication = None;
    Ok(envelope)
}

fn resolve_codex_home_source(
    transition: &mut CodexHomeTransitionState,
    codex_home: CodexHomeStatus,
) -> Result<CodexHomeSourceEnvelope, String> {
    let source_path = lexical_absolute_path(Path::new(&codex_home.path));
    let codex_home_path = canonical_home_path(&source_path);
    let canonical_home_key = platform_path_key(&codex_home_path);
    let physical_home_key = physical_home_key(&codex_home_path)?;
    let changed = transition.canonical_home_key.as_deref() != Some(&canonical_home_key)
        || transition.physical_home_key.as_deref() != Some(&physical_home_key);
    if changed {
        transition.transition_generation = transition.transition_generation.saturating_add(1);
        transition.canonical_home_key = Some(canonical_home_key.clone());
        transition.physical_home_key = Some(physical_home_key.clone());
    }
    transition.codex_home_path = Some(codex_home_path);
    transition.source_path = Some(source_path);
    transition.source_kind = Some(codex_home.source.clone());
    transition.source_exists = codex_home.exists;
    startup_trace::mark_performance(format!(
        "codex_home_source generation={} changed={} exists={}",
        transition.transition_generation,
        u8::from(changed),
        u8::from(codex_home.exists),
    ));

    Ok(CodexHomeSourceEnvelope {
        codex_home,
        canonical_home_key,
        physical_home_key,
        transition_generation: transition.transition_generation,
    })
}

fn refresh_codex_home_source_identity(
    transition: &mut CodexHomeTransitionState,
) -> Result<Option<CodexHomeSourceEnvelope>, String> {
    let source_path = transition
        .source_path
        .clone()
        .ok_or_else(|| "Codex Home source path is not initialized".to_string())?;
    let codex_home_path = canonical_home_path(&source_path);
    let canonical_home_key = platform_path_key(&codex_home_path);
    let physical_home_key = physical_home_key(&codex_home_path)?;
    let changed = transition.canonical_home_key.as_deref() != Some(&canonical_home_key)
        || transition.physical_home_key.as_deref() != Some(&physical_home_key);
    if changed {
        transition.transition_generation = transition.transition_generation.saturating_add(1);
        transition.canonical_home_key = Some(canonical_home_key.clone());
        transition.physical_home_key = Some(physical_home_key.clone());
        transition.pending_publication_generation = Some(transition.transition_generation);
        transition.in_flight_publication = None;
        startup_trace::mark_performance(format!(
            "codex_home_source_identity_changed generation={}",
            transition.transition_generation,
        ));
    }
    transition.codex_home_path = Some(codex_home_path);
    if !changed {
        return Ok(None);
    }
    Ok(Some(CodexHomeSourceEnvelope {
        codex_home: CodexHomeStatus {
            path: source_path.display().to_string(),
            exists: transition.source_exists,
            source: transition.source_kind.clone().unwrap_or_else(|| "auto".into()),
        },
        canonical_home_key,
        physical_home_key,
        transition_generation: transition.transition_generation,
    }))
}

fn current_codex_home_source_envelope(
    transition: &CodexHomeTransitionState,
) -> Result<CodexHomeSourceEnvelope, String> {
    Ok(CodexHomeSourceEnvelope {
        codex_home: CodexHomeStatus {
            path: transition
                .source_path
                .as_ref()
                .ok_or_else(|| "Codex Home source path is not initialized".to_string())?
                .display()
                .to_string(),
            exists: transition.source_exists,
            source: transition
                .source_kind
                .clone()
                .ok_or_else(|| "Codex Home source kind is not initialized".to_string())?,
        },
        canonical_home_key: transition
            .canonical_home_key
            .clone()
            .ok_or_else(|| "Codex Home source is not initialized".to_string())?,
        physical_home_key: transition
            .physical_home_key
            .clone()
            .ok_or_else(|| "Codex Home physical identity is not initialized".to_string())?,
        transition_generation: transition.transition_generation,
    })
}

#[cfg(test)]
fn canonical_home_key(path: &Path) -> String {
    platform_path_key(&canonical_home_path(path))
}

fn canonical_home_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| lexical_absolute_path(path))
}

fn capture_codex_home_source_from_state(
    transition: &CodexHomeTransitionState,
    expected: &CodexHomeSourceToken,
) -> Result<CapturedCodexHomeSource, String> {
    validate_codex_home_source_in_state(transition, expected)?;
    Ok(CapturedCodexHomeSource {
        source_token: expected.clone(),
        codex_home: transition
            .codex_home_path
            .clone()
            .ok_or_else(|| "Codex Home source path is not initialized".to_string())?,
        source_path: transition
            .source_path
            .clone()
            .ok_or_else(|| "Codex Home configured path is not initialized".to_string())?,
    })
}

fn validate_codex_home_source_in_state(
    transition: &CodexHomeTransitionState,
    expected: &CodexHomeSourceToken,
) -> Result<(), String> {
    let current = current_codex_home_source_token(transition)?;
    if current == *expected {
        Ok(())
    } else {
        Err(format!(
            "Codex Home source changed from generation {} ({}) to generation {} ({})",
            expected.transition_generation,
            expected.canonical_home_key,
            current.transition_generation,
            current.canonical_home_key,
        ))
    }
}

fn current_codex_home_source_token(
    transition: &CodexHomeTransitionState,
) -> Result<CodexHomeSourceToken, String> {
    Ok(CodexHomeSourceToken {
        canonical_home_key: transition
            .canonical_home_key
            .clone()
            .ok_or_else(|| "Codex Home source is not initialized".to_string())?,
        physical_home_key: transition
            .physical_home_key
            .clone()
            .ok_or_else(|| "Codex Home physical identity is not initialized".to_string())?,
        transition_generation: transition.transition_generation,
    })
}

#[cfg(unix)]
pub(crate) fn physical_home_key(path: &Path) -> Result<String, String> {
    use std::os::unix::fs::MetadataExt;

    let metadata = std::fs::metadata(path).map_err(|error| {
        format!("Codex Home physical identity unavailable for {}: {error}", path.display())
    })?;
    Ok(format!("unix:{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
pub(crate) fn physical_home_key(path: &Path) -> Result<String, String> {
    use std::fs::OpenOptions;
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_SHARE_WRITE: u32 = 0x0000_0002;
    const FILE_SHARE_DELETE: u32 = 0x0000_0004;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;

    let opened = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path);
    let (volume, file_id) = opened
        .and_then(|file| windows_home_identity(&file))
        .map_err(|error| {
            format!("Codex Home physical identity unavailable for {}: {error}", path.display())
        })?;
    Ok(format!("windows:{volume}:{file_id}"))
}

#[cfg(windows)]
fn windows_home_identity(file: &std::fs::File) -> std::io::Result<(u32, u64)> {
    use std::{ffi::c_void, mem::MaybeUninit, os::windows::io::AsRawHandle};

    #[repr(C)]
    struct FileTime {
        low_date_time: u32,
        high_date_time: u32,
    }
    #[repr(C)]
    struct ByHandleFileInformation {
        file_attributes: u32,
        creation_time: FileTime,
        last_access_time: FileTime,
        last_write_time: FileTime,
        volume_serial_number: u32,
        file_size_high: u32,
        file_size_low: u32,
        number_of_links: u32,
        file_index_high: u32,
        file_index_low: u32,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetFileInformationByHandle(
            file: *mut c_void,
            information: *mut ByHandleFileInformation,
        ) -> i32;
    }

    let mut information = MaybeUninit::<ByHandleFileInformation>::uninit();
    let result = unsafe {
        GetFileInformationByHandle(file.as_raw_handle().cast(), information.as_mut_ptr())
    };
    if result == 0 {
        return Err(std::io::Error::last_os_error());
    }
    let information = unsafe { information.assume_init() };
    let file_id =
        (u64::from(information.file_index_high) << 32) | u64::from(information.file_index_low);
    Ok((information.volume_serial_number, file_id))
}

#[cfg(not(any(unix, windows)))]
pub(crate) fn physical_home_key(path: &Path) -> Result<String, String> {
    let metadata = std::fs::metadata(path).map_err(|error| {
        format!("Codex Home physical identity unavailable for {}: {error}", path.display())
    })?;
    Ok(format!("portable:{}:{:?}", metadata.len(), metadata.created().ok()))
}

fn lexical_absolute_path(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

#[cfg(windows)]
fn platform_path_key(path: &Path) -> String {
    let raw = path.to_string_lossy().replace('\\', "/");
    let without_verbatim_prefix = raw
        .strip_prefix("//?/UNC/")
        .map(|rest| format!("//{rest}"))
        .or_else(|| raw.strip_prefix("//?/").map(str::to_string))
        .unwrap_or(raw);
    without_verbatim_prefix.to_lowercase()
}

#[cfg(not(windows))]
fn platform_path_key(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[tauri::command]
pub async fn read_platform_capabilities(
    window: tauri::WebviewWindow,
) -> Result<PlatformCapabilities, String> {
    require_window_label(&window, "read_platform_capabilities")?;
    run_blocking_command(|| {
        startup_trace::mark("command read_platform_capabilities start");
        let result = platform::platform_capabilities();
        startup_trace::mark("command read_platform_capabilities end");
        Ok(result)
    })
    .await
}

#[tauri::command]
pub async fn read_dashboard_snapshot(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
) -> Result<DashboardSnapshot, String> {
    require_window_label(&window, "read_dashboard_snapshot")?;
    startup_trace::mark("command read_dashboard_snapshot start");
    let started = Instant::now();
    let result = run_source_bound_dashboard_read(&app, source_token, move |codex_home| {
        crate::core::dashboard::LocalCodexDataSource::new(codex_home).read_dashboard_snapshot()
    })
    .await;
    let snapshot_details = result.as_ref().ok().map(|snapshot| {
        format!(
            "fresh={} coverage={} tokens={} calls={}",
            u8::from(snapshot.precise_recent_usage_fresh),
            u8::from(snapshot.precise_recent_usage_covered_at.is_some()),
            snapshot.stats.total_tokens,
            snapshot.stats.total_calls,
        )
    });
    startup_trace::mark_performance(format!(
        "read_dashboard_snapshot {}ms {} {}",
        started.elapsed().as_millis(),
        result_status(&result),
        snapshot_details.unwrap_or_else(|| "snapshot=none".into()),
    ));
    startup_trace::mark("command read_dashboard_snapshot end");
    result
}

#[tauri::command]
pub async fn read_precise_dashboard_snapshot(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
    request_reason: Option<String>,
) -> Result<DashboardSnapshot, String> {
    require_window_label(&window, "read_precise_dashboard_snapshot")?;
    let request_id = PRECISE_DASHBOARD_REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let request_reason = precise_dashboard_request_reason(request_reason.as_deref());
    let source_generation = source_token.transition_generation;
    let queue_wait_ms = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(u64::MAX));
    let queue_wait_for_worker = std::sync::Arc::clone(&queue_wait_ms);
    let started = Instant::now();
    let result = run_source_bound_dashboard_read_with_worker_start(
        &app,
        source_token,
        |codex_home| {
            crate::core::dashboard::LocalCodexDataSource::new(codex_home)
                .read_precise_dashboard_snapshot()
        },
        move |queue_wait| {
            queue_wait_for_worker.store(queue_wait, Ordering::Relaxed);
        },
    )
    .await;
    let queue_wait = queue_wait_ms.load(Ordering::Relaxed);
    startup_trace::mark_performance(format!(
        "precise_request id={} reason={} source_generation={} queue_wait_ms={} total_ms={} status={}",
        request_id,
        request_reason,
        source_generation,
        if queue_wait == u64::MAX {
            "na".to_string()
        } else {
            queue_wait.to_string()
        },
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn read_precise_dashboard_progress(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
) -> Result<PreciseDashboardProgress, String> {
    require_window_label(&window, "read_precise_dashboard_progress")?;
    run_source_bound_dashboard_read(&app, source_token, |codex_home| {
        Ok(token_count_jsonl::precise_dashboard_progress(&codex_home))
    })
    .await
}

async fn run_source_bound_dashboard_read_with_worker_start<T, Read, OnWorkerStart>(
    app: &AppHandle,
    expected: CodexHomeSourceToken,
    read: Read,
    on_worker_start: OnWorkerStart,
) -> Result<T, String>
where
    T: Send + 'static,
    Read: FnOnce(PathBuf) -> Result<T, String> + Send + 'static,
    OnWorkerStart: FnOnce(u64) + Send + 'static,
{
    run_source_bound_dashboard_read_with(
        &expected,
        || emit_detected_source_transition(app).map(|_| ()),
        |expected| capture_codex_home_source(Some(expected)),
        |codex_home| {
            run_blocking_command_with_worker_start(move || read(codex_home), on_worker_start)
        },
        validate_codex_home_source,
    )
    .await
}

fn precise_dashboard_request_reason(value: Option<&str>) -> &'static str {
    match value {
        Some("cadence") => "cadence",
        Some("source-change") => "source-change",
        Some("quota") => "quota",
        Some("catch-up") => "catch-up",
        Some("attribution") => "attribution",
        Some("manual") => "manual",
        Some("wake") => "wake",
        Some("retry") => "retry",
        _ => "unknown",
    }
}

#[tauri::command]
pub async fn acknowledge_attribution_safety(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
    provenance_epoch: String,
    unsafe_id: String,
    through_generation: u64,
) -> Result<bool, String> {
    require_window_label(&window, "acknowledge_attribution_safety")?;
    if uuid::Uuid::parse_str(&provenance_epoch).is_err() {
        return Err("精确 token 归因安全确认的谱系标识无效".into());
    }
    if uuid::Uuid::parse_str(&unsafe_id).is_err() {
        return Err("精确 token 归因安全确认的事件标识无效".into());
    }
    run_source_bound_dashboard_read(&app, source_token, move |codex_home| {
        token_count_jsonl::acknowledge_attribution_safety(
            &codex_home,
            &provenance_epoch,
            &unsafe_id,
            through_generation,
        )
    })
    .await
}

async fn run_source_bound_dashboard_read_with<
    T,
    Detect,
    Capture,
    Read,
    ReadFuture,
    Validate,
>(
    expected: &CodexHomeSourceToken,
    mut detect: Detect,
    capture: Capture,
    read: Read,
    validate: Validate,
) -> Result<T, String>
where
    Detect: FnMut() -> Result<(), String>,
    Capture: FnOnce(&CodexHomeSourceToken) -> Result<CapturedCodexHomeSource, String>,
    Read: FnOnce(PathBuf) -> ReadFuture,
    ReadFuture: Future<Output = Result<T, String>>,
    Validate: FnOnce(&CodexHomeSourceToken) -> Result<(), String>,
{
    detect()?;
    let captured = capture(expected)?;
    let completed_source_token = captured.source_token.clone();
    let result = read(captured.codex_home).await;
    let detection = detect();
    let validation = validate(&completed_source_token);
    detection?;
    validation?;
    result
}

pub(crate) async fn run_source_bound_dashboard_read<T, Read>(
    app: &AppHandle,
    expected: CodexHomeSourceToken,
    read: Read,
) -> Result<T, String>
where
    T: Send + 'static,
    Read: FnOnce(PathBuf) -> Result<T, String> + Send + 'static,
{
    run_source_bound_dashboard_read_with(
        &expected,
        || emit_detected_source_transition(app).map(|_| ()),
        |expected| capture_codex_home_source(Some(expected)),
        |codex_home| run_blocking_command(move || read(codex_home)),
        validate_codex_home_source,
    )
    .await
}

#[tauri::command]
pub async fn read_usage_summary_snapshot(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
    refresh_interval_seconds: Option<u64>,
) -> Result<Option<TokenUsageSummarySnapshot>, String> {
    require_window_label(&window, "read_usage_summary_snapshot")?;
    let started = Instant::now();
    let result = run_source_bound_dashboard_read(&app, source_token, move |codex_home| {
        let cached = token_count_jsonl::usage_summary_snapshot(&codex_home)?;
        token_count_jsonl::schedule_usage_summary_refresh_with_interval(
            &codex_home,
            refresh_interval_seconds,
        )?;
        Ok(cached)
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_usage_summary_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn read_precise_dashboard_source_probe(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
) -> Result<token_count_jsonl::PreciseDashboardSourceProbe, String> {
    require_window_label(&window, "read_precise_dashboard_source_probe")?;
    let started = Instant::now();
    let result = run_source_bound_dashboard_read(&app, source_token, |codex_home| {
        token_count_jsonl::precise_dashboard_source_probe(&codex_home)
    })
    .await;
    let probe_status = match &result {
        Ok(probe) => format!(
            "ok state={} published_generation={}",
            probe.state, probe.published_generation
        ),
        Err(_) => result_status(&result).to_string(),
    };
    startup_trace::mark_performance(format!(
        "read_precise_dashboard_source_probe {}ms {}",
        started.elapsed().as_millis(),
        probe_status
    ));
    result
}

#[tauri::command]
pub fn read_usage_cache_status(window: tauri::WebviewWindow) -> Result<UsageCacheStatus, String> {
    require_window_label(&window, "read_usage_cache_status")?;
    Ok(cache_lifecycle::usage_cache_status())
}

#[tauri::command]
pub async fn read_account_quota(
    window: tauri::WebviewWindow,
    app: AppHandle,
    auto_resume: tauri::State<'_, crate::commands::auto_resume::AutoResumeRegistry>,
    source_token: CodexHomeSourceToken,
    force_refresh: Option<bool>,
) -> Result<AccountQuotaBundle, String> {
    require_window_label(&window, "read_account_quota")?;
    startup_trace::mark_once("command read_account_quota start");
    let started = Instant::now();
    let forced = force_refresh.unwrap_or(false);
    let result = run_source_bound_dashboard_read(&app, source_token, move |codex_home| {
        crate::core::dashboard::LocalCodexDataSource::new(codex_home)
            .read_account_quota(forced)
    })
    .await;
    if let Ok(bundle) = &result {
        auto_resume.observe_quota(bundle);
    }
    startup_trace::mark_performance(format!(
        "read_account_quota force={} {}ms {}",
        forced,
        started.elapsed().as_millis(),
        account_quota_result_status(&result)
    ));
    startup_trace::mark_once("command read_account_quota end");
    result
}

#[tauri::command]
pub async fn read_account_reset_credits(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
    force_refresh: Option<bool>,
) -> Result<crate::models::ResetCreditBundle, String> {
    require_window_label(&window, "read_account_reset_credits")?;
    let started = Instant::now();
    let forced = force_refresh.unwrap_or(false);
    let result = run_source_bound_dashboard_read(&app, source_token, move |codex_home| {
        crate::core::dashboard::LocalCodexDataSource::new(codex_home)
            .read_account_reset_credits(forced)
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_account_reset_credits force={} {}ms {}",
        forced,
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

fn result_status<T>(result: &Result<T, String>) -> &'static str {
    if result.is_ok() {
        "ok"
    } else {
        "error"
    }
}

fn account_quota_result_status(result: &Result<AccountQuotaBundle, String>) -> String {
    match result {
        Err(error) => format!("error {}", compact_trace_text(error)),
        Ok(bundle) => {
            let quota_available = bundle.quota.five_hour.resets_at_unix.is_some()
                || bundle.quota.seven_day.resets_at_unix.is_some();
            let status = if quota_available {
                "quota_success"
            } else {
                "quota_placeholder"
            };
            if bundle.warnings.is_empty() && bundle.diagnostics.is_empty() {
                status.to_string()
            } else {
                let warnings = bundle
                    .warnings
                    .iter()
                    .map(|warning| {
                        format!(
                            "{}:{}",
                            warning.source,
                            compact_trace_text(&warning.message)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("|");
                let diagnostics = bundle
                    .diagnostics
                    .iter()
                    .map(|diagnostic| {
                        format!(
                            "{}:{}:{}",
                            diagnostic.source,
                            diagnostic.category,
                            compact_trace_text(
                                diagnostic
                                    .raw_cause
                                    .as_deref()
                                    .unwrap_or(&diagnostic.message)
                            )
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("|");
                match (warnings.is_empty(), diagnostics.is_empty()) {
                    (false, false) => {
                        format!("{status} warnings=[{warnings}] diagnostics=[{diagnostics}]")
                    }
                    (false, true) => format!("{status} warnings=[{warnings}]"),
                    (true, false) => format!("{status} diagnostics=[{diagnostics}]"),
                    (true, true) => status.to_string(),
                }
            }
        }
    }
}

fn compact_trace_text(text: &str) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= 1200 {
        compact
    } else {
        let mut truncated = compact.chars().take(1200).collect::<String>();
        truncated.push('…');
        truncated
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::unread::test_fixtures::write_initialized_sidebar_state;
    use crate::models::{
        AccountInfo, AccountQuotaBundle, QuotaLimit, QuotaSnapshot, ResetCreditSummary,
    };
    use std::cell::RefCell;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use tauri::async_runtime;

    static SOURCE_TEST_PATH_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn codex_home_transition_publishes_canonical_envelope_after_durable_save() {
        let home = disposable_source_test_directory("publish-order");
        let order = RefCell::new(Vec::new());
        let mut transition = CodexHomeTransitionState::default();

        // claim 模式：提交只在锁内登记待发布代次，发布必须经 claim 在锁外进行。
        let envelope = commit_codex_home_transition(&mut transition, || {
            order.borrow_mut().push("save");
            Ok(codex_home_status_for_test(home.join("."), "manual"))
        })
        .expect("durable save should return its exact envelope");
        assert_eq!(
            transition.pending_publication_generation,
            Some(envelope.transition_generation),
            "提交后待发布代次必须已登记"
        );

        let claim = claim_codex_home_source_transition_in_state(&mut transition)
            .expect("claim should succeed")
            .expect("committed transition must be claimable");
        order.borrow_mut().push("publish");
        // 事件载荷统一为词法归一化后的 source path（与 detected-transition
        // 发布路径同形态）；canonical 身份与代次不变。
        assert_eq!(claim.envelope.codex_home.path, home.display().to_string());
        assert_eq!(claim.envelope.canonical_home_key, canonical_home_key(&home));
        assert_eq!(claim.envelope.transition_generation, 1);

        finish_codex_home_source_transition_claim_in_state(&mut transition, &claim, true);
        assert_eq!(
            transition.pending_publication_generation, None,
            "发布成功后待发布代次必须清空"
        );
        assert_eq!(order.into_inner(), vec!["save", "publish"]);
        assert_eq!(envelope.canonical_home_key, canonical_home_key(&home));
        remove_source_test_directory(home);
    }

    #[test]
    fn codex_home_transition_does_not_publish_when_durable_save_fails() {
        let mut transition = CodexHomeTransitionState::default();

        let result = commit_codex_home_transition(&mut transition, || {
            Err("injected durable save failure".into())
        });

        assert_eq!(result.unwrap_err(), "injected durable save failure");
        assert_eq!(transition.transition_generation, 0);
        assert_eq!(transition.canonical_home_key, None);
        assert_eq!(transition.pending_publication_generation, None);
        // 未提交的迁移不可 claim，发布路径根本走不到。
        assert!(claim_codex_home_source_transition_in_state(&mut transition)
            .expect("claim probe should not error")
            .is_none());
    }

    #[test]
    fn codex_home_transition_generation_advances_only_for_canonical_source_changes() {
        let home_a = disposable_source_test_directory("source-a");
        let home_auto = disposable_source_test_directory("source-auto");
        let home_b = disposable_source_test_directory("source-b");
        let mut transition = CodexHomeTransitionState::default();

        let a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_a.clone(), "manual"),
        ).unwrap();
        let a_duplicate = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_a.join("."), "manual"),
        ).unwrap();
        let a_same_resolved_source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_a.clone(), "auto"),
        ).unwrap();
        let auto = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_auto.clone(), "auto"),
        ).unwrap();
        let auto_duplicate = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_auto.join("."), "auto"),
        ).unwrap();
        let b = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_b.clone(), "manual"),
        ).unwrap();

        assert_eq!(a.transition_generation, 1);
        assert_eq!(a_duplicate.transition_generation, 1);
        assert_eq!(a_same_resolved_source.transition_generation, 1);
        assert_eq!(auto.transition_generation, 2);
        assert_eq!(auto_duplicate.transition_generation, 2);
        assert_eq!(b.transition_generation, 3);
        assert_eq!(a.canonical_home_key, a_duplicate.canonical_home_key);
        assert_eq!(
            a.canonical_home_key,
            a_same_resolved_source.canonical_home_key
        );

        remove_source_test_directory(home_a);
        remove_source_test_directory(home_auto);
        remove_source_test_directory(home_b);
    }

    #[test]
    fn captured_codex_home_source_never_rebinds_to_a_later_transition() {
        let home_a = disposable_source_test_directory("captured-source-a");
        let home_b = disposable_source_test_directory("captured-source-b");
        let mut transition = CodexHomeTransitionState::default();
        let source_a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_a.clone(), "manual"),
        ).unwrap();
        let source_a_token = source_a.source_token();
        let captured = capture_codex_home_source_from_state(&transition, &source_a_token)
            .expect("A should be captured before the transition");

        resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_b.clone(), "manual"),
        ).unwrap();

        assert_eq!(captured.codex_home, canonical_home_path(&home_a));
        assert_eq!(captured.source_token, source_a_token);
        assert!(validate_codex_home_source_in_state(&transition, &source_a_token).is_err());

        remove_source_test_directory(home_a);
        remove_source_test_directory(home_b);
    }

    #[test]
    fn validated_source_operation_runs_outside_transition_lock() {
        let home = disposable_source_test_directory("validated-operation-lock");
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap()
        .source_token();
        let state = Mutex::new(transition);

        let result = with_valid_codex_home_source_in_state(&state, &source, || {
            assert!(
                state.try_lock().is_ok(),
                "validated operation must not inherit the transition mutex"
            );
            Ok::<_, String>(42)
        })
        .unwrap();

        assert_eq!(result, 42);
        remove_source_test_directory(home);
    }

    #[test]
    fn source_bound_dashboard_read_detects_captures_reads_and_post_validates_in_order() {
        let order = RefCell::new(Vec::new());
        let expected = CodexHomeSourceToken {
            canonical_home_key: "/captured/.codex".into(),
            physical_home_key: "unix:1:2".into(),
            transition_generation: 9,
        };
        let captured = CapturedCodexHomeSource {
            source_token: expected.clone(),
            codex_home: PathBuf::from("/captured/.codex"),
            source_path: PathBuf::from("/captured/.codex"),
        };

        let result = async_runtime::block_on(run_source_bound_dashboard_read_with(
            &expected,
            || {
                order.borrow_mut().push("detect");
                Ok(())
            },
            |token| {
                order.borrow_mut().push("capture");
                assert_eq!(token, &expected);
                Ok(captured)
            },
            |path| {
                order.borrow_mut().push("read");
                std::future::ready(Ok(path))
            },
            |token| {
                order.borrow_mut().push("validate");
                assert_eq!(token, &expected);
                Ok(())
            },
        ))
        .expect("source-bound read should complete");

        assert_eq!(result, PathBuf::from("/captured/.codex"));
        assert_eq!(
            order.into_inner(),
            vec!["detect", "capture", "read", "detect", "validate"]
        );
    }

    #[test]
    fn source_bound_dashboard_read_rejects_data_when_physical_source_changes_after_read() {
        let expected = CodexHomeSourceToken {
            canonical_home_key: "/same/.codex".into(),
            physical_home_key: "unix:1:2".into(),
            transition_generation: 4,
        };
        let captured = CapturedCodexHomeSource {
            source_token: expected.clone(),
            codex_home: PathBuf::from("/same/.codex"),
            source_path: PathBuf::from("/same/.codex"),
        };

        let result = async_runtime::block_on(run_source_bound_dashboard_read_with(
            &expected,
            || Ok(()),
            |_| Ok(captured),
            |_| std::future::ready(Ok("data from physical A")),
            |_| Err("Codex Home physical identity changed".into()),
        ));

        assert_eq!(
            result.unwrap_err(),
            "Codex Home physical identity changed"
        );
    }

    #[test]
    fn same_canonical_path_advances_when_physical_home_is_replaced() {
        let home = disposable_source_test_directory("physical-home");
        let displaced = home.with_extension("displaced");
        let mut transition = CodexHomeTransitionState::default();

        let source_a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        ).unwrap();
        let captured_a =
            capture_codex_home_source_from_state(&transition, &source_a.source_token())
                .expect("capture physical home A");
        std::fs::rename(&home, &displaced).expect("displace physical home A");
        std::fs::create_dir(&home).expect("create physical home B at the same path");
        let source_b = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        ).unwrap();

        assert_eq!(source_a.canonical_home_key, source_b.canonical_home_key);
        assert_ne!(source_a.physical_home_key, source_b.physical_home_key);
        assert_eq!(
            source_b.transition_generation,
            source_a.transition_generation + 1
        );
        assert!(
            validate_codex_home_source_in_state(&transition, &source_a.source_token()).is_err()
        );
        assert!(validate_captured_codex_home_source(&captured_a).is_err());

        remove_source_test_directory(home);
        remove_source_test_directory(displaced);
    }

    #[test]
    fn physical_identity_error_preserves_authoritative_source_state() {
        let home = disposable_source_test_directory("physical-error");
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .expect("initial physical identity should resolve");
        let authoritative = source.source_token();

        remove_source_test_directory(home);
        let error = refresh_codex_home_source_identity(&mut transition)
            .expect_err("missing physical home must fail closed");

        assert!(error.contains("physical identity"), "{error}");
        assert_eq!(
            current_codex_home_source_token(&transition).unwrap(),
            authoritative
        );
    }

    #[test]
    fn background_physical_replacement_returns_exactly_one_transition_envelope() {
        let home = disposable_source_test_directory("background-physical-change");
        let displaced = home.with_extension("displaced");
        let mut transition = CodexHomeTransitionState::default();
        let source_a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .expect("initialize source A");

        std::fs::rename(&home, &displaced).expect("displace physical source A");
        std::fs::create_dir(&home).expect("install physical source B");

        let source_b = refresh_codex_home_source_identity(&mut transition)
            .expect("refresh source B")
            .expect("first detector must receive an envelope to publish");
        let duplicate = refresh_codex_home_source_identity(&mut transition)
            .expect("repeat refresh")
            .is_none();

        assert_eq!(source_b.canonical_home_key, source_a.canonical_home_key);
        assert_ne!(source_b.physical_home_key, source_a.physical_home_key);
        assert_eq!(
            source_b.transition_generation,
            source_a.transition_generation + 1
        );
        assert!(duplicate, "the same transition must not publish twice");

        remove_source_test_directory(home);
        remove_source_test_directory(displaced);
    }

    #[test]
    fn concurrent_detectors_issue_one_claim_and_failure_requeues_it() {
        let home = disposable_source_test_directory("background-publish-ack");
        let displaced = home.with_extension("displaced");
        let mut transition = CodexHomeTransitionState::default();
        let source_a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();

        std::fs::rename(&home, &displaced).unwrap();
        std::fs::create_dir(&home).unwrap();

        let first = claim_codex_home_source_transition_in_state(&mut transition)
            .unwrap()
            .expect("first detection should publish");
        assert!(claim_codex_home_source_transition_in_state(&mut transition)
            .unwrap()
            .is_none());
        assert_eq!(
            first.envelope.transition_generation,
            source_a.transition_generation + 1
        );

        finish_codex_home_source_transition_claim_in_state(&mut transition, &first, false);
        let retry = claim_codex_home_source_transition_in_state(&mut transition)
            .unwrap()
            .expect("failed emit must requeue the generation");
        assert_eq!(retry.envelope.transition_generation, first.envelope.transition_generation);
        assert_ne!(retry.claim_nonce, first.claim_nonce);

        finish_codex_home_source_transition_claim_in_state(&mut transition, &retry, true);
        assert!(
            claim_codex_home_source_transition_in_state(&mut transition)
                .unwrap()
                .is_none(),
            "successful publish acknowledgement must consume the event exactly once"
        );

        remove_source_test_directory(home);
        remove_source_test_directory(displaced);
    }

    #[test]
    fn panicked_source_event_publisher_requeues_its_claim() {
        let home = disposable_source_test_directory("background-publish-panic");
        let displaced = home.with_extension("displaced");
        let mut transition = CodexHomeTransitionState::default();
        resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        std::fs::rename(&home, &displaced).unwrap();
        std::fs::create_dir(&home).unwrap();
        let state = Mutex::new(transition);

        let unwind = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = emit_detected_source_transition_from(&state, |_| {
                panic!("injected Codex Home event publisher panic");
            });
        }));

        assert!(unwind.is_err());
        let retry = claim_codex_home_source_transition_from(&state)
            .unwrap()
            .expect("publisher panic must requeue the pending source generation");
        with_locked_codex_home_transition_state(&state, |transition| {
            finish_codex_home_source_transition_claim_in_state(transition, &retry, true);
            Ok(())
        })
        .unwrap();

        remove_source_test_directory(home);
        remove_source_test_directory(displaced);
    }

    #[test]
    fn public_detector_lock_allows_one_in_flight_claim_across_threads() {
        use std::sync::{Arc, Barrier};

        let home = disposable_source_test_directory("threaded-detector");
        let displaced = home.with_extension("displaced");
        let mut initial = CodexHomeTransitionState::default();
        resolve_codex_home_source(
            &mut initial,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        std::fs::rename(&home, &displaced).unwrap();
        std::fs::create_dir(&home).unwrap();
        let state = Arc::new(Mutex::new(initial));
        let barrier = Arc::new(Barrier::new(3));
        let handles = [(), ()].map(|_| {
            let state = state.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                claim_codex_home_source_transition_from(&state).unwrap()
            })
        });
        barrier.wait();
        let claims = handles
            .into_iter()
            .filter_map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();

        assert_eq!(claims.len(), 1);

        remove_source_test_directory(home);
        remove_source_test_directory(displaced);
    }

    #[test]
    fn stale_claim_cannot_clear_a_newer_generation() {
        let home = disposable_source_test_directory("stale-claim-a");
        let displaced_a = home.with_extension("displaced-a");
        let displaced_b = home.with_extension("displaced-b");
        let mut transition = CodexHomeTransitionState::default();
        resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();

        std::fs::rename(&home, &displaced_a).unwrap();
        std::fs::create_dir(&home).unwrap();
        let stale = claim_codex_home_source_transition_in_state(&mut transition)
            .unwrap()
            .unwrap();

        std::fs::rename(&home, &displaced_b).unwrap();
        std::fs::create_dir(&home).unwrap();
        refresh_codex_home_source_identity(&mut transition).unwrap();
        finish_codex_home_source_transition_claim_in_state(&mut transition, &stale, true);

        let current = claim_codex_home_source_transition_in_state(&mut transition)
            .unwrap()
            .expect("stale acknowledgement must not clear the newer generation");
        assert!(current.envelope.transition_generation > stale.envelope.transition_generation);

        remove_source_test_directory(home);
        remove_source_test_directory(displaced_a);
        remove_source_test_directory(displaced_b);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_observation_survives_a_to_b_to_a_swap() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("pinned-source-a");
        write_initialized_sidebar_state(&home, &[]);
        let displaced = home.with_extension("displaced");
        let session_path = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&session_path).unwrap();
        write_completion_session(
            &session_path.join("observation.jsonl"),
            "019eaaaa-0000-0000-0000-0000000000a1",
        );
        let mut transition = CodexHomeTransitionState::default();
        let source_a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured =
            capture_codex_home_source_from_state(&transition, &source_a.source_token()).unwrap();
        reset_pinned_source_observation_counters_for_test();
        let pinned = pin_captured_codex_home_source(&captured).expect("pin physical A");

        std::fs::rename(&home, &displaced).expect("replace A with B after pin");
        std::fs::create_dir(&home).expect("install B at the same canonical path");
        let session_path_b = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&session_path_b).unwrap();
        write_completion_session(
            &session_path_b.join("observation.jsonl"),
            "019eaaaa-0000-0000-0000-0000000000b1",
        );
        std::fs::remove_dir_all(&home).unwrap();
        std::fs::rename(&displaced, &home).expect("restore A before validation");

        assert_eq!(
            pinned.observation().unwrap().recent_completion_count(),
            1
        );
        assert!(pinned.source_scope_key.contains(&source_a.physical_home_key));

        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_accepts_a_legal_canonical_target() {
        let _guard = pinned_source_counter_test_guard();
        use std::os::unix::fs::symlink;

        let target = disposable_source_test_directory("canonical-target");
        let link = target.with_extension("link");
        symlink(&target, &link).unwrap();
        write_initialized_sidebar_state(&target, &[]);
        let session_path = canonical_session_test_directory(&target);
        std::fs::create_dir_all(&session_path).unwrap();
        write_completion_session(
            &session_path.join("observation.jsonl"),
            "019eaaaa-0000-0000-0000-0000000000a2",
        );
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(link.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();

        let pinned = pin_captured_codex_home_source(&captured).expect("pin canonical target");
        assert_eq!(
            pinned.observation().unwrap().recent_completion_count(),
            1
        );

        std::fs::remove_file(link).unwrap();
        remove_source_test_directory(target);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_reads_only_bounded_recent_session_candidates_in_memory() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("bounded-pinned-sessions");
        write_initialized_sidebar_state(&home, &[]);
        let old_sessions = home.join("sessions/2000/01/01");
        std::fs::create_dir_all(&old_sessions).unwrap();
        for index in 0..10_000 {
            std::fs::write(old_sessions.join(format!("old-{index}.jsonl")), "old").unwrap();
        }
        let sessions = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&sessions).unwrap();
        for index in 0..2 {
            std::fs::write(sessions.join(format!("recent-{index}.jsonl")), "recent").unwrap();
        }
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();
        reset_pinned_source_observation_counters_for_test();

        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert!(pinned.observation().is_some());
        assert_eq!(pinned_source_inspected_count_for_test(), 2);
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_selects_the_newest_sixty_four_recent_sessions() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("newest-pinned-sessions");
        write_initialized_sidebar_state(&home, &[]);
        let sessions = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&sessions).unwrap();
        let base = std::time::SystemTime::now() - std::time::Duration::from_secs(20);
        for index in 0..70 {
            let path = sessions.join(format!("recent-{index:02}.jsonl"));
            write_completion_session(
                &path,
                &format!("019eaaaa-0000-0000-0000-{index:012}"),
            );
            std::fs::File::options()
                .write(true)
                .open(path)
                .unwrap()
                .set_times(
                    std::fs::FileTimes::new()
                        .set_modified(base + std::time::Duration::from_millis(index * 100)),
                )
                .unwrap();
        }
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();

        reset_pinned_source_observation_counters_for_test();
        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert_eq!(
            pinned.observation().unwrap().recent_completion_count(),
            64
        );
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn recent_session_dates_cover_utc_and_local_midnight_boundaries() {
        let now = time::macros::datetime!(2026-07-11 00:05 UTC);
        let west = recent_session_date_paths(now, time::UtcOffset::from_hms(-7, 0, 0).unwrap());
        assert!(west.contains(&PathBuf::from("2026/07/11")));
        assert!(west.contains(&PathBuf::from("2026/07/10")));
        assert!(west.contains(&PathBuf::from("2026/07/09")));

        let east_now = time::macros::datetime!(2026-07-11 18:30 UTC);
        let east = recent_session_date_paths(
            east_now,
            time::UtcOffset::from_hms(10, 0, 0).unwrap(),
        );
        assert!(east.contains(&PathBuf::from("2026/07/12")));
        assert!(east.contains(&PathBuf::from("2026/07/11")));
        assert!(east.contains(&PathBuf::from("2026/07/10")));
    }

    #[cfg(unix)]
    #[test]
    fn sessions_root_allows_ds_store_without_weakening_layout_validation() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("sessions-ds-store");
        write_initialized_sidebar_state(&home, &[]);
        std::fs::create_dir(home.join("sessions")).unwrap();
        std::fs::write(home.join("sessions/.DS_Store"), b"metadata").unwrap();
        let current = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&current).unwrap();
        std::fs::write(current.join("recent.jsonl"), b"recent").unwrap();
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();

        reset_pinned_source_observation_counters_for_test();
        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert!(pinned.observation().is_some());
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_fails_with_diagnostic_when_archived_fallback_cannot_be_safe() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("unsafe-archived-fallback");
        write_initialized_sidebar_state(
            &home,
            &["019eaaaa-0000-0000-0000-0000000000aa"],
        );
        let archived = home.join("archived_sessions");
        std::fs::create_dir(&archived).unwrap();
        std::fs::write(
            archived.join("archived.jsonl"),
            r#"{"type":"session_meta","payload":{"id":"019eaaaa-0000-0000-0000-0000000000aa","thread_source":"user"}}"#,
        )
        .unwrap();
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();

        let error = match pin_captured_codex_home_source(&captured) {
            Ok(_) => panic!("unsafe archived fallback must fail closed"),
            Err(error) => error,
        };

        assert!(error.contains("requires state_5.sqlite"), "{error}");
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn empty_native_state_never_copies_large_sqlite_files() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("empty-state-skips-db");
        write_initialized_sidebar_state(&home, &[]);
        std::fs::write(home.join("state_5.sqlite"), vec![0u8; 2 * 1024 * 1024]).unwrap();
        std::fs::write(home.join("state_5.sqlite-wal"), vec![0u8; 1024 * 1024]).unwrap();
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();
        reset_pinned_source_observation_counters_for_test();

        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert_eq!(pinned_sqlite_view_create_count_for_test(), 0);
        assert!(pinned.observation().is_some());
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn state_sqlite_directory_is_rejected_as_a_non_file() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("sqlite-directory");
        write_initialized_sidebar_state(
            &home,
            &["019eaaaa-0000-0000-0000-0000000000aa"],
        );
        std::fs::create_dir(home.join("state_5.sqlite")).unwrap();
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();

        let error = match pin_captured_codex_home_source(&captured) {
            Ok(_) => panic!("SQLite directory must be rejected"),
            Err(error) => error,
        };

        assert!(error.contains("is a directory"), "{error}");
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn descriptor_view_lease_releases_global_lock_during_observation_io() {
        let _guard = pinned_source_counter_test_guard();
        let mut lease = PinnedSqliteDescriptorViewLease::acquire(true).unwrap();
        assert!(lease.view_mut().is_some());

        let slot = pinned_sqlite_descriptor_view()
            .try_lock()
            .expect("descriptor view mutex must not be held by the active observation");
        assert!(
            slot.is_none(),
            "the active descriptor view must be owned by the observation lease"
        );
        drop(slot);
        drop(lease);

        assert!(
            pinned_sqlite_descriptor_view()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_some(),
            "dropping the observation lease must return its descriptor view to the cache"
        );
    }

    #[cfg(unix)]
    #[test]
    fn consecutive_15s_native_observations_reuse_unchanged_descriptor_links() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("db-signature-cache");
        let thread_id = "019eaaaa-0000-0000-0000-0000000000aa";
        write_initialized_sidebar_state(&home, &[thread_id]);
        let database_path = home.join("state_5.sqlite");
        let connection = rusqlite::Connection::open(&database_path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE threads (id TEXT PRIMARY KEY, archived INTEGER, thread_source TEXT, source TEXT, preview TEXT);",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO threads VALUES (?1, 0, 'user', 'user', 'visible')",
                [thread_id],
            )
            .unwrap();
        drop(connection);
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();
        reset_pinned_source_observation_counters_for_test();

        drop(pin_captured_codex_home_source(&captured).unwrap());
        let (directory_modified, link_modified, creations, mutations) = {
            let view = pinned_sqlite_descriptor_view().lock().unwrap();
            let view = view.as_ref().unwrap();
            (
                std::fs::metadata(&view.directory).unwrap().modified().unwrap(),
                std::fs::symlink_metadata(view.directory.join("state_5.sqlite"))
                    .unwrap()
                    .modified()
                    .unwrap(),
                pinned_sqlite_view_create_count_for_test(),
                pinned_sqlite_link_mutation_count_for_test(),
            )
        };
        drop(pin_captured_codex_home_source(&captured).unwrap());
        let view = pinned_sqlite_descriptor_view().lock().unwrap();
        let view = view.as_ref().unwrap();
        assert_eq!(
            std::fs::metadata(&view.directory).unwrap().modified().unwrap(),
            directory_modified
        );
        assert_eq!(
            std::fs::symlink_metadata(view.directory.join("state_5.sqlite"))
                .unwrap()
                .modified()
                .unwrap(),
            link_modified
        );
        assert_eq!(pinned_sqlite_view_create_count_for_test(), creations);
        assert_eq!(pinned_sqlite_link_mutation_count_for_test(), mutations);

        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn unix_descriptor_view_reads_uncheckpointed_wal_rows() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("descriptor-wal");
        let thread_id = "019eaaaa-0000-0000-0000-0000000000ab";
        write_initialized_sidebar_state(&home, &[thread_id]);
        let connection = rusqlite::Connection::open(home.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 PRAGMA wal_autocheckpoint=0;
                 CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    archived INTEGER,
                    thread_source TEXT,
                    source TEXT,
                    preview TEXT
                 );
                 INSERT INTO threads VALUES (
                    '019eaaaa-0000-0000-0000-0000000000ab', 0, 'user', 'user', 'visible'
                 );",
            )
            .unwrap();
        assert!(std::fs::metadata(home.join("state_5.sqlite-wal"))
            .unwrap()
            .len()
            > 32);

        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();
        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert_eq!(pinned.observation().unwrap().native_unread_count(), Some(1));
        {
            use std::os::unix::fs::MetadataExt;

            let view = pinned_sqlite_descriptor_view().lock().unwrap();
            let view = view.as_ref().unwrap();
            for name in ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
                let source = std::fs::symlink_metadata(home.join(name)).unwrap();
                let published =
                    std::fs::symlink_metadata(view.directory.join(name)).unwrap();
                assert!(published.file_type().is_file());
                assert_eq!(published.dev(), source.dev());
                assert_eq!(published.ino(), source.ino());
            }
        }
        drop(pinned);
        drop(connection);
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn descriptor_view_cleanup_removes_unlocked_stale_and_preserves_locked_active() {
        let _guard = pinned_source_counter_test_guard();
        let sequence = SOURCE_TEST_PATH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let stale = std::env::temp_dir().join(format!(
            "codex-token-bar-pinned-sqlite-view-stale-{}-{sequence}",
            std::process::id()
        ));
        let active = std::env::temp_dir().join(format!(
            "codex-token-bar-pinned-sqlite-view-active-{}-{sequence}",
            std::process::id()
        ));
        std::fs::create_dir(&stale).unwrap();
        std::fs::write(stale.join(".owner.lock"), b"").unwrap();
        std::fs::create_dir(&active).unwrap();
        std::fs::write(active.join(".owner.lock"), b"").unwrap();
        let active_lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(active.join(".owner.lock"))
            .unwrap();
        rustix::fs::flock(
            &active_lock,
            rustix::fs::FlockOperation::LockExclusive,
        )
        .unwrap();

        clean_stale_pinned_sqlite_descriptor_views().unwrap();

        assert!(!stale.exists());
        assert!(active.exists());
        drop(active_lock);
        clean_stale_pinned_sqlite_descriptor_views().unwrap();
        assert!(!active.exists());
    }

    #[cfg(unix)]
    #[test]
    fn empty_native_source_releases_previous_sqlite_descriptors() {
        let _guard = pinned_source_counter_test_guard();
        let home_a = disposable_source_test_directory("cache-source-a");
        let thread_id = "019eaaaa-0000-0000-0000-0000000000aa";
        write_initialized_sidebar_state(&home_a, &[thread_id]);
        let connection = rusqlite::Connection::open(home_a.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch("CREATE TABLE threads (id TEXT PRIMARY KEY);")
            .unwrap();
        drop(connection);
        let mut transition_a = CodexHomeTransitionState::default();
        let source_a = resolve_codex_home_source(
            &mut transition_a,
            codex_home_status_for_test(home_a.clone(), "manual"),
        )
        .unwrap();
        let captured_a =
            capture_codex_home_source_from_state(&transition_a, &source_a.source_token()).unwrap();
        drop(pin_captured_codex_home_source(&captured_a).unwrap());
        assert!(!pinned_sqlite_descriptor_view()
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .files
            .is_empty());

        let home_b = disposable_source_test_directory("cache-source-b-empty");
        write_initialized_sidebar_state(&home_b, &[]);
        let mut transition_b = CodexHomeTransitionState::default();
        let source_b = resolve_codex_home_source(
            &mut transition_b,
            codex_home_status_for_test(home_b.clone(), "manual"),
        )
        .unwrap();
        let captured_b =
            capture_codex_home_source_from_state(&transition_b, &source_b.source_token()).unwrap();
        drop(pin_captured_codex_home_source(&captured_b).unwrap());

        assert!(pinned_sqlite_descriptor_view()
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .files
            .is_empty());

        remove_source_test_directory(home_a);
        remove_source_test_directory(home_b);
    }

    #[cfg(unix)]
    #[test]
    fn invalid_sqlite_observation_fails_without_session_or_database_copy() {
        let _guard = pinned_source_counter_test_guard();
        reset_pinned_source_observation_counters_for_test();
        let home = disposable_source_test_directory("failed-db-cache");
        write_initialized_sidebar_state(
            &home,
            &["019eaaaa-0000-0000-0000-0000000000aa"],
        );
        std::fs::write(home.join("state_5.sqlite"), b"not sqlite").unwrap();
        let mut transition = CodexHomeTransitionState::default();
        let source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured = capture_codex_home_source_from_state(&transition, &source.source_token())
            .unwrap();

        assert!(pin_captured_codex_home_source(&captured).is_err());
        remove_source_test_directory(home);
    }

    #[test]
    fn account_quota_trace_status_distinguishes_placeholder_bundle_from_real_quota() {
        let mut quota = placeholder_quota_for_test();
        quota.pace_label = "额度读取失败".into();
        let placeholder = Ok(AccountQuotaBundle {
            updated_at: "2026-07-31T00:00:00Z".into(),
            attribution_identity: None,
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota,
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: vec![],
            diagnostics: Vec::new(),
        });

        assert_eq!(
            account_quota_result_status(&placeholder),
            "quota_placeholder"
        );
    }

    #[test]
    fn precise_dashboard_request_trace_accepts_only_bounded_reasons() {
        for reason in [
            "cadence",
            "source-change",
            "quota",
            "catch-up",
            "attribution",
            "manual",
            "wake",
            "retry",
        ] {
            assert_eq!(precise_dashboard_request_reason(Some(reason)), reason);
        }
        assert_eq!(
            precise_dashboard_request_reason(Some("/private/source.jsonl")),
            "unknown"
        );
        assert_eq!(precise_dashboard_request_reason(None), "unknown");
    }

    #[test]
    fn account_quota_trace_keeps_full_retry_diagnostics() {
        let long_warning = format!(
            "额度读取失败：网络连接失败：{}",
            "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)；".repeat(8)
        );
        let placeholder = Ok(AccountQuotaBundle {
            updated_at: "2026-07-31T00:00:00Z".into(),
            attribution_identity: None,
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota: placeholder_quota_for_test(),
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: vec![crate::models::LocalDataWarning {
                source: "account_quota".into(),
                message: long_warning,
            }],
            diagnostics: vec![crate::models::QuotaDiagnostic {
                source: "account_quota".into(),
                category: "network_send_fetch".into(),
                severity: "warning".into(),
                message: "网络连接失败".into(),
                raw_cause: Some("failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)；".repeat(8)),
                underlying_category: None,
                attempts: Some(3),
                http_status: None,
                retryable: true,
                occurred_at: "2026-07-06T00:00:00Z".into(),
                stale_data_displayed: false,
            }],
        });

        let status = account_quota_result_status(&placeholder);
        assert!(status.contains("quota_placeholder warnings=[account_quota:"));
        assert!(status.contains("diagnostics=[account_quota:network_send_fetch:"));
        assert!(status.contains("backend-api/wham/usage"));
        assert!(!status.contains('…'));
    }

    fn placeholder_quota_for_test() -> QuotaSnapshot {
        QuotaSnapshot {
            five_hour: QuotaLimit {
                label: "5h".into(),
                availability: crate::models::QuotaAvailability::Unavailable,
                used_percent: None,
                remaining_percent: None,
                resets_at: "待读取".into(),
                resets_at_unix: None,
            },
            seven_day: QuotaLimit {
                label: "7d".into(),
                availability: crate::models::QuotaAvailability::Unavailable,
                used_percent: None,
                remaining_percent: None,
                resets_at: "待读取".into(),
                resets_at_unix: None,
            },
            pace_label: "待读取".into(),
            reset_credit: ResetCreditSummary {
                available_count: 0,
                status: "重置卡待读取".into(),
                credits: Vec::new(),
            },
        }
    }

    fn codex_home_status_for_test(path: PathBuf, source: &str) -> CodexHomeStatus {
        CodexHomeStatus {
            path: path.display().to_string(),
            exists: true,
            source: source.into(),
        }
    }

    fn disposable_source_test_directory(label: &str) -> PathBuf {
        let sequence = SOURCE_TEST_PATH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "codex-token-bar-source-transition-{}-{}-{sequence}",
            std::process::id(),
            label,
        ));
        std::fs::create_dir_all(&path).expect("create disposable source transition directory");
        path
    }

    fn remove_source_test_directory(path: PathBuf) {
        std::fs::remove_dir_all(path).expect("remove disposable source transition directory");
    }

    #[cfg(unix)]
    fn canonical_session_test_directory(home: &Path) -> PathBuf {
        home.join("sessions").join(
            recent_session_date_paths(
                time::OffsetDateTime::now_utc(),
                crate::core::localtime::local_offset(),
            )
            .into_iter()
            .next()
            .unwrap(),
        )
    }

    #[cfg(unix)]
    fn write_completion_session(path: &Path, thread_id: &str) {
        let completed_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        std::fs::write(
            path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{thread_id}\",\"thread_source\":\"user\",\"source\":\"user\"}}}}\n{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_complete\",\"turn_id\":\"turn-1\",\"completed_at\":{completed_at}}}}}\n"
            ),
        )
        .unwrap();
    }

}
