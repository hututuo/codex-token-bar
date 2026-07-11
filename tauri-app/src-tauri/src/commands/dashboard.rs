use super::window_auth::require_window_label;
use crate::core::dashboard::DashboardDataSource;
use crate::core::startup_trace;
use crate::core::usage::cache_lifecycle::{self, UsageCacheStatus};
use crate::core::usage::token_count_jsonl::{self, TokenUsageSummary};
use crate::models::{AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, PlatformCapabilities};
use crate::platform;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt::Display;
use std::future::Future;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;
use tauri::{async_runtime, AppHandle, Emitter};

pub(crate) const CODEX_HOME_SOURCE_CHANGED_EVENT: &str = "codex-home-source-changed";

static CODEX_HOME_TRANSITION_STATE: OnceLock<Mutex<CodexHomeTransitionState>> = OnceLock::new();
static PINNED_SOURCE_SNAPSHOT_SEQUENCE: AtomicU64 = AtomicU64::new(0);
#[cfg(unix)]
static PINNED_DB_SNAPSHOT_CACHE: OnceLock<Mutex<HashMap<String, CachedPinnedDbSnapshot>>> =
    OnceLock::new();
#[cfg(test)]
static PINNED_SOURCE_SESSION_FILES_COPIED: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SOURCE_SNAPSHOTS_CREATED: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SOURCE_DB_FILES_COPIED: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SOURCE_SESSION_ENTRIES_INSPECTED: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SOURCE_COUNTER_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

const PINNED_SESSION_FILE_LIMIT: usize = 64;
const PINNED_SESSION_FIRST_LINE_LIMIT: u64 = 262_144;
const PINNED_SESSION_TAIL_LIMIT: u64 = 4 * 1024 * 1024;
const PINNED_SESSION_LOOKBACK_SECONDS: i64 = 30;

#[cfg(unix)]
struct CachedPinnedDbSnapshot {
    signature: u64,
    directory: PathBuf,
    _owner_lock: std::fs::File,
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
    snapshot_path: Option<PathBuf>,
    pub source_scope_key: String,
}

impl PinnedCodexHomeSource {
    pub(crate) fn read_path(&self) -> &Path {
        &self.read_path
    }
}

impl Drop for PinnedCodexHomeSource {
    fn drop(&mut self) {
        if let Some(path) = self.snapshot_path.take() {
            let _ = std::fs::remove_dir_all(path);
        }
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

async fn run_blocking_command<T, F>(work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub fn get_codex_home(window: tauri::WebviewWindow) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "get_codex_home")?;
    startup_trace::mark("command get_codex_home start");
    let result = with_codex_home_transition_state(|transition| {
        resolve_codex_home_source(
            transition,
            platform::default_codex_home_status(),
        )
    });
    startup_trace::mark("command get_codex_home end");
    result
}

#[tauri::command]
pub fn set_codex_home(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    path: String,
) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "set_codex_home")?;
    persist_codex_home_transition(app, || platform::save_codex_home(&path))
}

#[tauri::command]
pub fn reset_codex_home(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "reset_codex_home")?;
    persist_codex_home_transition(app, platform::reset_codex_home)
}

fn persist_codex_home_transition(
    app: tauri::AppHandle,
    save: impl FnOnce() -> Result<CodexHomeStatus, String>,
) -> Result<CodexHomeSourceEnvelope, String> {
    with_codex_home_transition_state(|transition| {
        commit_codex_home_transition(transition, save, |envelope| {
            app
                .emit_str(
                    CODEX_HOME_SOURCE_CHANGED_EVENT,
                    serde_json::to_string(envelope).map_err(|error| error.to_string())?,
                )
                .map_err(|error| error.to_string())
        })
    })
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

pub(crate) fn claim_codex_home_source_transition(
) -> Result<Option<CodexHomeSourceTransitionClaim>, String> {
    claim_codex_home_source_transition_from(codex_home_transition_state())
}

fn claim_codex_home_source_transition_from(
    state: &Mutex<CodexHomeTransitionState>,
) -> Result<Option<CodexHomeSourceTransitionClaim>, String> {
    with_locked_codex_home_transition_state(state, claim_codex_home_source_transition_in_state)
}

pub(crate) fn finish_codex_home_source_transition_claim(
    claim: &CodexHomeSourceTransitionClaim,
    published: bool,
) -> Result<(), String> {
    with_codex_home_transition_state(|transition| {
        finish_codex_home_source_transition_claim_in_state(transition, claim, published);
        Ok(())
    })
}

pub(crate) fn emit_detected_source_transition(app: &AppHandle) -> Result<bool, String> {
    let Some(claim) = claim_codex_home_source_transition()? else {
        return Ok(false);
    };
    let publish_result = serde_json::to_string(&claim.envelope)
        .map_err(|error| error.to_string())
        .and_then(|payload| {
            app.emit_str(CODEX_HOME_SOURCE_CHANGED_EVENT, payload)
                .map_err(|error| error.to_string())
        });
    finish_codex_home_source_transition_claim(&claim, publish_result.is_ok())?;
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
    let snapshot_path = snapshot_pinned_unread_source(&handle, &source_scope_key)?;
    Ok(PinnedCodexHomeSource {
        _handle: handle,
        read_path: snapshot_path.clone(),
        snapshot_path: Some(snapshot_path),
        source_scope_key,
    })
}

#[cfg(unix)]
fn snapshot_pinned_unread_source(
    root: &std::fs::File,
    source_scope_key: &str,
) -> Result<PathBuf, String> {
    use rustix::fs::FileType;

    let sequence = PINNED_SOURCE_SNAPSHOT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let snapshot = std::env::temp_dir().join(format!(
        "codex-token-bar-pinned-unread-{}-{sequence}",
        std::process::id()
    ));
    use std::os::unix::fs::DirBuilderExt;
    let mut builder = std::fs::DirBuilder::new();
    builder.mode(0o700);
    builder.create(&snapshot)
        .map_err(|error| format!("failed to create pinned Codex Home snapshot: {error}"))?;
    #[cfg(test)]
    PINNED_SOURCE_SNAPSHOTS_CREATED.fetch_add(1, Ordering::Relaxed);
    let result = (|| {
        evict_other_pinned_db_snapshots(source_scope_key)?;
        copy_optional_pinned_file(
            root,
            ".codex-global-state.json",
            &snapshot.join(".codex-global-state.json"),
        )?;
        if let Some(state_fingerprint) = pinned_state_fingerprint(&snapshot)? {
            materialize_cached_pinned_database(
                root,
                source_scope_key,
                state_fingerprint,
                &snapshot,
            )?;
        }
        copy_recent_pinned_sessions(root, &snapshot.join("sessions"))?;
        Ok::<(), String>(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_dir_all(&snapshot);
        return Err(error);
    }
    // Confirm the descriptor still names a directory after the full snapshot.
    let stat = rustix::fs::fstat(root)
        .map_err(|error| format!("failed to revalidate pinned Codex Home: {error}"))?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::Directory {
        let _ = std::fs::remove_dir_all(&snapshot);
        return Err("pinned Codex Home stopped being a directory".into());
    }
    Ok(snapshot)
}

#[cfg(unix)]
fn pinned_state_fingerprint(snapshot: &Path) -> Result<Option<u64>, String> {
    use std::hash::{Hash, Hasher};

    let path = snapshot.join(".codex-global-state.json");
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("failed to read pinned native unread state: {error}")),
    };
    let value: serde_json::Value = serde_json::from_slice(&data)
        .map_err(|error| format!("pinned native unread state JSON is invalid: {error}"))?;
    let unread = value
        .get("electron-persisted-atom-state")
        .and_then(|state| state.get("unread-thread-ids-by-host-v1"))
        .or_else(|| value.get("unread-thread-ids-by-host-v1"));
    let mut ids = Vec::new();
    if let Some(unread) = unread {
        collect_thread_ids_for_fingerprint(unread, &mut ids);
    }
    if ids.is_empty() {
        return Ok(None);
    }
    ids.sort();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    ids.hash(&mut hasher);
    Ok(Some(hasher.finish()))
}

#[cfg(unix)]
fn collect_thread_ids_for_fingerprint(value: &serde_json::Value, ids: &mut Vec<String>) {
    match value {
        serde_json::Value::String(text) if text.len() >= 24 && text.contains('-') => {
            ids.push(text.clone())
        }
        serde_json::Value::Array(items) => {
            for item in items {
                collect_thread_ids_for_fingerprint(item, ids);
            }
        }
        serde_json::Value::Object(map) => {
            for item in map.values() {
                collect_thread_ids_for_fingerprint(item, ids);
            }
        }
        _ => {}
    }
}

#[cfg(unix)]
fn materialize_cached_pinned_database(
    root: &std::fs::File,
    source_scope_key: &str,
    state_fingerprint: u64,
    snapshot: &Path,
) -> Result<(), String> {
    let signature_before = pinned_database_signature(root, state_fingerprint)?;
    let cache = pinned_db_snapshot_cache()?;
    let mut cache = cache
        .lock()
        .map_err(|_| "pinned unread DB cache lock was poisoned".to_string())?;
    if let Some(cached) = cache.get(source_scope_key) {
        if cached.signature == signature_before {
            return link_cached_pinned_database(&cached.directory, snapshot);
        }
    }

    let (directory, owner_lock) = create_owned_pinned_db_directory(&std::env::temp_dir())?;
    let result = (|| {
        for file_name in ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
            copy_optional_pinned_file(root, file_name, &directory.join(file_name))?;
        }
        validate_pinned_state_database(&directory)?;
        let signature_after = pinned_database_signature(root, state_fingerprint)?;
        if signature_after != signature_before {
            return Err("pinned unread SQLite changed while it was being copied".into());
        }
        Ok::<(), String>(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_dir_all(&directory);
        return Err(error);
    }
    if let Err(error) = link_cached_pinned_database(&directory, snapshot) {
        let _ = std::fs::remove_dir_all(&directory);
        return Err(error);
    }
    if let Some(previous) = cache.insert(
        source_scope_key.to_string(),
        CachedPinnedDbSnapshot {
            signature: signature_before,
            directory: directory.clone(),
            _owner_lock: owner_lock,
        },
    ) {
        let _ = std::fs::remove_dir_all(previous.directory);
    }
    Ok(())
}

#[cfg(unix)]
fn pinned_db_snapshot_cache(
) -> Result<&'static Mutex<HashMap<String, CachedPinnedDbSnapshot>>, String> {
    clean_stale_pinned_db_snapshots()?;
    Ok(PINNED_DB_SNAPSHOT_CACHE.get_or_init(|| Mutex::new(HashMap::new())))
}

#[cfg(unix)]
fn clean_stale_pinned_db_snapshots() -> Result<(), String> {
    clean_stale_pinned_db_snapshots_in(&std::env::temp_dir())
}

#[cfg(unix)]
fn clean_stale_pinned_db_snapshots_in(directory: &Path) -> Result<(), String> {
    clean_stale_pinned_db_snapshots_in_with_hook(directory, |_| {})
}

#[cfg(unix)]
fn clean_stale_pinned_db_snapshots_in_with_hook(
    directory: &Path,
    after_lock: impl FnMut(&str),
) -> Result<(), String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(i64::MAX);
    clean_stale_pinned_db_snapshots_in_with_policy(directory, after_lock, |stat| {
        now.saturating_sub(stat.st_mtime) >= 60
    })
}

#[cfg(unix)]
fn clean_stale_pinned_db_snapshots_in_with_policy(
    directory: &Path,
    mut after_lock: impl FnMut(&str),
    old_enough: impl Fn(&rustix::fs::Stat) -> bool,
) -> Result<(), String> {
    use rustix::fs::{
        fstat, openat, statat, unlinkat, AtFlags, Dir, FileType, Mode, OFlags,
    };
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    const PREFIX: &[u8] = b"codex-token-bar-pinned-db-";
    let canonical_root = std::fs::canonicalize(directory)
        .map_err(|error| format!("failed to resolve pinned DB cache root: {error}"))?;
    let root = open_cache_root_without_following(&canonical_root)?;
    clean_stale_pinned_db_staging(&root, &mut after_lock, &old_enough)?;
    let mut entries = Dir::read_from(&root)
        .map_err(|error| format!("failed to inspect pinned DB cache directory: {error}"))?;
    while let Some(entry) = entries.read() {
        let Ok(entry) = entry else {
            continue;
        };
        let name_bytes = entry.file_name().to_bytes();
        if !name_bytes.starts_with(PREFIX) {
            continue;
        }
        let name = OsStr::from_bytes(name_bytes);
        let Ok(path_stat) = statat(&root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        if FileType::from_raw_mode(path_stat.st_mode) != FileType::Directory {
            continue;
        }
        let Ok(candidate) = openat(
            &root,
            name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        ) else {
            continue;
        };
        let Ok(candidate_stat) = fstat(&candidate) else {
            continue;
        };
        if !same_unix_file_identity(&path_stat, &candidate_stat) {
            continue;
        }
        let Ok(lock_path_stat) = statat(&candidate, ".owner.lock", AtFlags::SYMLINK_NOFOLLOW)
        else {
            continue;
        };
        if FileType::from_raw_mode(lock_path_stat.st_mode) != FileType::RegularFile {
            continue;
        }
        let Ok(lock_fd) = openat(
            &candidate,
            ".owner.lock",
            OFlags::RDWR | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        ) else {
            continue;
        };
        let lock = std::fs::File::from(lock_fd);
        let Ok(lock_stat) = fstat(&lock) else {
            continue;
        };
        if !same_unix_file_identity(&lock_path_stat, &lock_stat)
            || rustix::fs::flock(
                &lock,
                rustix::fs::FlockOperation::NonBlockingLockExclusive,
            )
            .is_err()
        {
            continue;
        }

        after_lock(&name.to_string_lossy());
        let Ok(current_candidate_stat) = statat(&root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        let Ok(current_lock_stat) = statat(&candidate, ".owner.lock", AtFlags::SYMLINK_NOFOLLOW)
        else {
            continue;
        };
        if !same_unix_file_identity(&candidate_stat, &current_candidate_stat)
            || FileType::from_raw_mode(current_candidate_stat.st_mode) != FileType::Directory
            || !same_unix_file_identity(&lock_stat, &current_lock_stat)
            || FileType::from_raw_mode(current_lock_stat.st_mode) != FileType::RegularFile
        {
            continue;
        }

        let mut children = match Dir::read_from(&candidate) {
            Ok(children) => children,
            Err(_) => continue,
        };
        let mut removable = Vec::new();
        let mut valid = true;
        while let Some(child) = children.read() {
            let Ok(child) = child else {
                valid = false;
                break;
            };
            let child_bytes = child.file_name().to_bytes();
            if child_bytes == b"." || child_bytes == b".." {
                continue;
            }
            let child_name = OsStr::from_bytes(child_bytes);
            let Ok(child_stat) = statat(&candidate, child_name, AtFlags::SYMLINK_NOFOLLOW) else {
                valid = false;
                break;
            };
            if FileType::from_raw_mode(child_stat.st_mode) != FileType::RegularFile {
                valid = false;
                break;
            }
            removable.push(child_name.to_os_string());
        }
        if !valid {
            continue;
        }
        for child in removable {
            if unlinkat(&candidate, &child, AtFlags::empty()).is_err() {
                valid = false;
                break;
            }
        }
        if !valid {
            continue;
        }
        let Ok(final_candidate_stat) = statat(&root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        if !same_unix_file_identity(&candidate_stat, &final_candidate_stat) {
            continue;
        }
        let _ = unlinkat(&root, name, AtFlags::REMOVEDIR);
    }
    Ok(())
}

#[cfg(unix)]
fn clean_stale_pinned_db_staging(
    root: &impl std::os::fd::AsFd,
    after_lock: &mut impl FnMut(&str),
    old_enough: &impl Fn(&rustix::fs::Stat) -> bool,
) -> Result<(), String> {
    use rustix::fs::{
        fstat, openat, statat, unlinkat, AtFlags, Dir, FileType, Mode, OFlags,
    };
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    const STAGING_PREFIX: &[u8] = b".codex-token-bar-pinned-db-staging-";
    const OWNER_PREFIX: &[u8] = b".codex-token-bar-pinned-db-owner-";
    let mut entries = Dir::read_from(root)
        .map_err(|error| format!("failed to inspect pinned DB staging directory: {error}"))?;
    while let Some(entry) = entries.read() {
        let Ok(entry) = entry else { continue };
        let bytes = entry.file_name().to_bytes();
        if !bytes.starts_with(STAGING_PREFIX) {
            continue;
        }
        let name = OsStr::from_bytes(bytes);
        let Ok(path_stat) = statat(root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        if FileType::from_raw_mode(path_stat.st_mode) != FileType::Directory {
            continue;
        }
        let Ok(candidate) = openat(
            root,
            name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        ) else {
            continue;
        };
        let Ok(candidate_stat) = fstat(&candidate) else {
            continue;
        };
        if !same_unix_file_identity(&path_stat, &candidate_stat) {
            continue;
        }
        let token = &bytes[STAGING_PREFIX.len()..];
        let owner_name = format!(
            ".codex-token-bar-pinned-db-owner-{}.lock",
            String::from_utf8_lossy(token)
        );
        let owner_path_stat = statat(root, owner_name.as_str(), AtFlags::SYMLINK_NOFOLLOW);
        let Ok(owner_path_stat) = owner_path_stat else {
            if old_enough(&candidate_stat)
                && directory_is_empty(&candidate)
                && statat(root, name, AtFlags::SYMLINK_NOFOLLOW)
                    .is_ok_and(|stat| same_unix_file_identity(&candidate_stat, &stat))
            {
                let _ = unlinkat(root, name, AtFlags::REMOVEDIR);
            }
            continue;
        };
        if FileType::from_raw_mode(owner_path_stat.st_mode) != FileType::RegularFile
            || !old_enough(&owner_path_stat)
        {
            continue;
        }
        let Ok(owner_fd) = openat(
            root,
            owner_name.as_str(),
            OFlags::RDWR | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        ) else {
            continue;
        };
        let owner = std::fs::File::from(owner_fd);
        let Ok(owner_stat) = fstat(&owner) else {
            continue;
        };
        if !same_unix_file_identity(&owner_path_stat, &owner_stat)
            || rustix::fs::flock(
                &owner,
                rustix::fs::FlockOperation::NonBlockingLockExclusive,
            )
            .is_err()
        {
            continue;
        }
        after_lock(&name.to_string_lossy());
        let Ok(current_candidate) = statat(root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        let Ok(current_owner) = statat(root, owner_name.as_str(), AtFlags::SYMLINK_NOFOLLOW)
        else {
            continue;
        };
        if !same_unix_file_identity(&candidate_stat, &current_candidate)
            || !same_unix_file_identity(&owner_stat, &current_owner)
        {
            continue;
        }
        match statat(&candidate, ".owner.lock", AtFlags::SYMLINK_NOFOLLOW) {
            Ok(internal)
                if FileType::from_raw_mode(internal.st_mode) == FileType::RegularFile
                    && same_unix_file_identity(&owner_stat, &internal) =>
            {
                if unlinkat(&candidate, ".owner.lock", AtFlags::empty()).is_err() {
                    continue;
                }
            }
            Err(rustix::io::Errno::NOENT) => {}
            _ => continue,
        }
        if !directory_is_empty(&candidate) {
            continue;
        }
        let Ok(final_candidate) = statat(root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        if !same_unix_file_identity(&candidate_stat, &final_candidate)
            || unlinkat(root, name, AtFlags::REMOVEDIR).is_err()
        {
            continue;
        }
        let Ok(final_owner) = statat(root, owner_name.as_str(), AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        if same_unix_file_identity(&owner_stat, &final_owner) {
            let _ = unlinkat(root, owner_name.as_str(), AtFlags::empty());
        }
    }

    let mut owners = Dir::read_from(root)
        .map_err(|error| format!("failed to inspect pinned DB owner artifacts: {error}"))?;
    while let Some(entry) = owners.read() {
        let Ok(entry) = entry else { continue };
        let bytes = entry.file_name().to_bytes();
        if !bytes.starts_with(OWNER_PREFIX) || !bytes.ends_with(b".lock") {
            continue;
        }
        let name = OsStr::from_bytes(bytes);
        let Ok(path_stat) = statat(root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        if FileType::from_raw_mode(path_stat.st_mode) != FileType::RegularFile
            || !old_enough(&path_stat)
        {
            continue;
        }
        let token = &bytes[OWNER_PREFIX.len()..bytes.len() - b".lock".len()];
        let staging_name = format!(
            ".codex-token-bar-pinned-db-staging-{}",
            String::from_utf8_lossy(token)
        );
        let final_name = format!(
            "codex-token-bar-pinned-db-{}",
            String::from_utf8_lossy(token)
        );
        if statat(root, staging_name.as_str(), AtFlags::SYMLINK_NOFOLLOW).is_ok()
            || statat(root, final_name.as_str(), AtFlags::SYMLINK_NOFOLLOW).is_ok()
        {
            continue;
        }
        let Ok(fd) = openat(
            root,
            name,
            OFlags::RDWR | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        ) else {
            continue;
        };
        let file = std::fs::File::from(fd);
        let Ok(opened_stat) = fstat(&file) else {
            continue;
        };
        if !same_unix_file_identity(&path_stat, &opened_stat)
            || rustix::fs::flock(
                &file,
                rustix::fs::FlockOperation::NonBlockingLockExclusive,
            )
            .is_err()
        {
            continue;
        }
        let Ok(current) = statat(root, name, AtFlags::SYMLINK_NOFOLLOW) else {
            continue;
        };
        if same_unix_file_identity(&opened_stat, &current) {
            let _ = unlinkat(root, name, AtFlags::empty());
        }
    }
    Ok(())
}

#[cfg(unix)]
fn directory_is_empty(directory: &impl std::os::fd::AsFd) -> bool {
    use rustix::fs::Dir;

    let Ok(mut entries) = Dir::read_from(directory) else {
        return false;
    };
    while let Some(entry) = entries.read() {
        let Ok(entry) = entry else { return false };
        let bytes = entry.file_name().to_bytes();
        if bytes != b"." && bytes != b".." {
            return false;
        }
    }
    true
}

#[cfg(unix)]
fn same_unix_file_identity(left: &rustix::fs::Stat, right: &rustix::fs::Stat) -> bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
}

#[cfg(unix)]
fn open_cache_root_without_following(path: &Path) -> Result<rustix::fd::OwnedFd, String> {
    use rustix::fs::{open, openat, Mode, OFlags};

    let mut current = open(
        "/",
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| format!("failed to open pinned DB filesystem root: {error}"))?;
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(name) => {
                current = openat(
                    &current,
                    name,
                    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                    Mode::empty(),
                )
                .map_err(|error| format!("failed to pin DB cache root: {error}"))?;
            }
            _ => return Err("pinned DB cache root is not an absolute canonical path".into()),
        }
    }
    Ok(current)
}

#[cfg(unix)]
fn process_session_identity() -> &'static str {
    static IDENTITY: OnceLock<String> = OnceLock::new();
    IDENTITY.get_or_init(|| {
        let started = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        format!("{:x}-{started:x}", std::process::id())
    })
}

#[cfg(unix)]
fn create_owned_pinned_db_directory(
    parent: &Path,
) -> Result<(PathBuf, std::fs::File), String> {
    create_owned_pinned_db_directory_with_hook(parent, |_, _, _| {})
}

#[cfg(unix)]
fn create_owned_pinned_db_directory_with_hook(
    parent: &Path,
    mut publication_hook: impl FnMut(&Path, &Path, bool),
) -> Result<(PathBuf, std::fs::File), String> {
    use rustix::fs::{linkat, mkdirat, openat, unlinkat, AtFlags, Mode, OFlags};

    let canonical_root = std::fs::canonicalize(parent)
        .map_err(|error| format!("failed to resolve pinned DB cache root: {error}"))?;
    let root = open_cache_root_without_following(&canonical_root)?;
    for _ in 0..16 {
        let sequence = PINNED_SOURCE_SNAPSHOT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let staging_name = format!(
            ".codex-token-bar-pinned-db-staging-{}-{sequence}",
            process_session_identity()
        );
        let final_name = format!(
            "codex-token-bar-pinned-db-{}-{sequence}",
            process_session_identity()
        );
        let owner_name = format!(
            ".codex-token-bar-pinned-db-owner-{}-{sequence}.lock",
            process_session_identity()
        );
        let owner_fd = match openat(
            &root,
            owner_name.as_str(),
            OFlags::RDWR | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        ) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::EXIST) => continue,
            Err(error) => {
                return Err(format!("failed to create pinned DB staging owner: {error}"))
            }
        };
        let owner_lock = std::fs::File::from(owner_fd);
        if let Err(error) =
            rustix::fs::flock(&owner_lock, rustix::fs::FlockOperation::LockExclusive)
        {
            let _ = unlinkat(&root, owner_name.as_str(), AtFlags::empty());
            return Err(format!("failed to lock pinned DB staging owner: {error}"));
        }
        if let Err(error) = mkdirat(&root, staging_name.as_str(), Mode::from_raw_mode(0o700)) {
            let _ = unlinkat(&root, owner_name.as_str(), AtFlags::empty());
            if error == rustix::io::Errno::EXIST {
                continue;
            }
            return Err(format!("failed to create pinned DB staging directory: {error}"));
        }
        let result = (|| {
            let staging = openat(
                &root,
                staging_name.as_str(),
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            )
            .map_err(|error| format!("failed to open pinned DB staging directory: {error}"))?;
            linkat(
                &root,
                owner_name.as_str(),
                &staging,
                ".owner.lock",
                AtFlags::empty(),
            )
            .map_err(|error| format!("failed to bind pinned DB staging owner: {error}"))?;
            let staging_path = canonical_root.join(&staging_name);
            let final_path = canonical_root.join(&final_name);
            publication_hook(&staging_path, &final_path, false);
            publish_pinned_db_cache_directory(&root, &staging_name, &final_name)?;
            let _ = unlinkat(&root, owner_name.as_str(), AtFlags::empty());
            publication_hook(&staging_path, &final_path, true);
            Ok::<_, String>((final_path, owner_lock))
        })();
        if result.is_err() {
            if let Ok(staging) = openat(
                &root,
                staging_name.as_str(),
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            ) {
                let _ = unlinkat(&staging, ".owner.lock", AtFlags::empty());
            }
            let _ = unlinkat(&root, staging_name.as_str(), AtFlags::REMOVEDIR);
            let _ = unlinkat(&root, owner_name.as_str(), AtFlags::empty());
        }
        match result {
            Ok(created) => return Ok(created),
            Err(error) if error.starts_with("pinned DB cache publication collided:") => continue,
            Err(error) => return Err(error),
        }
    }
    Err("failed to allocate a unique pinned DB cache directory".into())
}

#[cfg(all(unix, any(target_vendor = "apple", target_os = "linux", target_os = "redox")))]
fn publish_pinned_db_cache_directory(
    root: &impl std::os::fd::AsFd,
    staging_name: &str,
    final_name: &str,
) -> Result<(), String> {
    rustix::fs::renameat_with(
        root,
        staging_name,
        root,
        final_name,
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(|error| {
        if error == rustix::io::Errno::EXIST {
            format!("pinned DB cache publication collided: {error}")
        } else {
            format!("failed to publish pinned DB cache directory: {error}")
        }
    })
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "linux", target_os = "redox"))))]
fn publish_pinned_db_cache_directory(
    _root: &impl std::os::fd::AsFd,
    _staging_name: &str,
    _final_name: &str,
) -> Result<(), String> {
    Err("atomic no-replace pinned DB cache publication is unsupported on this platform".into())
}

#[cfg(unix)]
fn evict_other_pinned_db_snapshots(source_scope_key: &str) -> Result<(), String> {
    let cache = pinned_db_snapshot_cache()?;
    let mut cache = cache
        .lock()
        .map_err(|_| "pinned unread DB cache lock was poisoned".to_string())?;
    let stale_keys = cache
        .keys()
        .filter(|key| key.as_str() != source_scope_key)
        .cloned()
        .collect::<Vec<_>>();
    for key in stale_keys {
        if let Some(stale) = cache.remove(&key) {
            let _ = std::fs::remove_dir_all(stale.directory);
        }
    }
    Ok(())
}

#[cfg(unix)]
fn pinned_database_signature(
    root: &std::fs::File,
    state_fingerprint: u64,
) -> Result<u64, String> {
    use rustix::fs::{statat, AtFlags};
    use std::hash::{Hash, Hasher};

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    state_fingerprint.hash(&mut hasher);
    for file_name in ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
        match statat(root, file_name, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(stat) => {
                file_name.hash(&mut hasher);
                stat.st_ino.hash(&mut hasher);
                stat.st_size.hash(&mut hasher);
                stat.st_mtime.hash(&mut hasher);
                stat.st_mtime_nsec.hash(&mut hasher);
            }
            Err(rustix::io::Errno::NOENT) if file_name != "state_5.sqlite" => {
                file_name.hash(&mut hasher);
            }
            Err(rustix::io::Errno::NOENT) => {
                return Err(
                    "pinned unread observation requires state_5.sqlite when native unread state exists"
                        .into(),
                )
            }
            Err(error) => {
                return Err(format!("failed to inspect pinned unread SQLite: {error}"))
            }
        }
    }
    Ok(hasher.finish())
}

#[cfg(unix)]
fn link_cached_pinned_database(cache: &Path, snapshot: &Path) -> Result<(), String> {
    for file_name in ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
        let source = cache.join(file_name);
        if source.exists() {
            std::fs::hard_link(&source, snapshot.join(file_name)).map_err(|error| {
                format!("failed to link cached pinned unread SQLite {file_name}: {error}")
            })?;
        }
    }
    Ok(())
}

#[cfg(unix)]
fn validate_pinned_state_database(snapshot: &Path) -> Result<(), String> {
    let state = snapshot.join(".codex-global-state.json");
    let database = snapshot.join("state_5.sqlite");
    if !database.exists() {
        if !state.exists() {
            return Ok(());
        }
        return Err(
            "pinned unread observation requires state_5.sqlite when native unread state exists"
                .into(),
        );
    }
    let connection = rusqlite::Connection::open_with_flags(
        database,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|error| format!("pinned unread SQLite validation failed: {error}"))?;
    connection
        .prepare("SELECT id FROM threads LIMIT 0")
        .map_err(|error| format!("pinned unread SQLite threads validation failed: {error}"))?;
    Ok(())
}

#[cfg(unix)]
fn copy_recent_pinned_sessions(
    root: &std::fs::File,
    destination: &Path,
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
    let local_offset = time::UtcOffset::current_local_offset().unwrap_or(time::UtcOffset::UTC);
    let date_paths = recent_session_date_paths(now_utc, local_offset);
    let cutoff = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64 - PINNED_SESSION_LOOKBACK_SECONDS)
        .unwrap_or(i64::MAX);
    let mut candidates = Vec::new();
    for date_path in date_paths {
        let Some(day) = open_pinned_directory_path(&sessions, &date_path)? else {
            continue;
        };
        collect_recent_pinned_session_candidates(
            &day,
            &date_path,
            cutoff,
            &mut candidates,
        )?;
    }
    candidates.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    for (relative_path, _) in candidates.into_iter().take(PINNED_SESSION_FILE_LIMIT) {
        copy_pinned_session_candidate(&sessions, &relative_path, destination)?;
    }
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

#[cfg(unix)]
fn copy_pinned_session_candidate(
    sessions: &impl std::os::fd::AsFd,
    relative_path: &Path,
    destination_root: &Path,
) -> Result<(), String> {
    use rustix::fs::{openat, Mode, OFlags};
    use std::io::{Read, Seek, SeekFrom, Write};

    let mut current = rustix::io::dup(sessions)
        .map_err(|error| format!("failed to duplicate pinned sessions handle: {error}"))?;
    let mut components = relative_path.components().peekable();
    while let Some(component) = components.next() {
        let name = component.as_os_str();
        let flags = if components.peek().is_some() {
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::DIRECTORY
        } else {
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW
        };
        current = openat(&current, name, flags, Mode::empty())
            .map_err(|error| format!("failed to open pinned session candidate: {error}"))?;
    }
    let mut source = std::fs::File::from(current);
    let size = source
        .metadata()
        .map_err(|error| format!("failed to inspect pinned session candidate: {error}"))?
        .len();
    let destination = destination_root.join(relative_path);
    std::fs::create_dir_all(
        destination
            .parent()
            .ok_or_else(|| "pinned session snapshot path has no parent".to_string())?,
    )
    .map_err(|error| format!("failed to create pinned session snapshot directory: {error}"))?;
    let mut target = std::fs::File::create(destination)
        .map_err(|error| format!("failed to create pinned session snapshot: {error}"))?;
    if size <= PINNED_SESSION_FIRST_LINE_LIMIT + PINNED_SESSION_TAIL_LIMIT {
        std::io::copy(&mut source, &mut target)
            .map_err(|error| format!("failed to copy recent pinned session: {error}"))?;
    } else {
        let mut first = vec![0; PINNED_SESSION_FIRST_LINE_LIMIT as usize];
        let first_len = source
            .read(&mut first)
            .map_err(|error| format!("failed to read pinned session head: {error}"))?;
        let first_line_end = first[..first_len]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|index| index + 1)
            .unwrap_or(first_len);
        target
            .write_all(&first[..first_line_end])
            .map_err(|error| format!("failed to write pinned session head: {error}"))?;
        source
            .seek(SeekFrom::Start(size - PINNED_SESSION_TAIL_LIMIT))
            .map_err(|error| format!("failed to seek pinned session tail: {error}"))?;
        std::io::copy(&mut source.take(PINNED_SESSION_TAIL_LIMIT), &mut target)
            .map_err(|error| format!("failed to copy pinned session tail: {error}"))?;
    }
    #[cfg(test)]
    PINNED_SOURCE_SESSION_FILES_COPIED.fetch_add(1, Ordering::Relaxed);
    Ok(())
}

#[cfg(test)]
pub(crate) fn reset_pinned_source_copy_count_for_test() {
    PINNED_SOURCE_SESSION_FILES_COPIED.store(0, Ordering::Relaxed);
    PINNED_SOURCE_SNAPSHOTS_CREATED.store(0, Ordering::Relaxed);
    PINNED_SOURCE_DB_FILES_COPIED.store(0, Ordering::Relaxed);
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
pub(crate) fn pinned_source_copy_count_for_test() -> u64 {
    PINNED_SOURCE_SESSION_FILES_COPIED.load(Ordering::Relaxed)
}

#[cfg(test)]
pub(crate) fn pinned_source_snapshot_count_for_test() -> u64 {
    PINNED_SOURCE_SNAPSHOTS_CREATED.load(Ordering::Relaxed)
}

#[cfg(test)]
pub(crate) fn pinned_source_db_copy_count_for_test() -> u64 {
    PINNED_SOURCE_DB_FILES_COPIED.load(Ordering::Relaxed)
}

#[cfg(test)]
pub(crate) fn pinned_source_inspected_count_for_test() -> u64 {
    PINNED_SOURCE_SESSION_ENTRIES_INSPECTED.load(Ordering::Relaxed)
}

#[cfg(unix)]
fn copy_optional_pinned_file<Fd: std::os::fd::AsFd>(
    parent: Fd,
    name: &str,
    destination: &Path,
) -> Result<(), String> {
    use rustix::fs::{openat, statat, AtFlags, FileType, Mode, OFlags};

    let stat = match statat(&parent, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(stat) => stat,
        Err(rustix::io::Errno::NOENT) => return Ok(()),
        Err(error) => {
            return Err(format!("failed to inspect pinned unread entry {name}: {error}"))
        }
    };
    match FileType::from_raw_mode(stat.st_mode) {
        FileType::RegularFile => {
            let fd = openat(
                &parent,
                name,
                OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
                Mode::empty(),
            )
            .map_err(|error| format!("failed to open pinned unread file {name}: {error}"))?;
            let mut source = std::fs::File::from(fd);
            let mut target = std::fs::File::create(destination).map_err(|error| {
                format!("failed to create pinned unread snapshot file {name}: {error}")
            })?;
            std::io::copy(&mut source, &mut target)
                .map_err(|error| format!("failed to copy pinned unread file {name}: {error}"))?;
            #[cfg(test)]
            if name.starts_with("state_5.sqlite") {
                PINNED_SOURCE_DB_FILES_COPIED.fetch_add(1, Ordering::Relaxed);
            }
            Ok(())
        }
        FileType::Directory => Err(format!("pinned unread file {name} is a directory")),
        FileType::Symlink => Err(format!(
            "pinned unread entry {name} is a symlink and was rejected"
        )),
        other => Err(format!(
            "pinned unread entry {name} has unsupported type {other:?}"
        )),
    }
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
        snapshot_path: None,
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
    with_codex_home_transition_state(|transition| {
        refresh_codex_home_source_identity(transition)?;
        validate_codex_home_source_in_state(transition, source_token)?;
        operation()
    })
}

fn commit_codex_home_transition<E>(
    transition: &mut CodexHomeTransitionState,
    save: impl FnOnce() -> Result<CodexHomeStatus, String>,
    publish: impl FnOnce(&CodexHomeSourceEnvelope) -> Result<(), E>,
) -> Result<CodexHomeSourceEnvelope, String>
where
    E: Display,
{
    let codex_home = save()?;
    let envelope = resolve_codex_home_source(transition, codex_home)?;
    if let Err(error) = publish(&envelope) {
        startup_trace::mark_performance(format!(
            "codex home source event publish failed generation={} error={error}",
            envelope.transition_generation
        ));
    }
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
    if transition.canonical_home_key.as_deref() != Some(&canonical_home_key)
        || transition.physical_home_key.as_deref() != Some(&physical_home_key)
    {
        transition.transition_generation = transition.transition_generation.saturating_add(1);
        transition.canonical_home_key = Some(canonical_home_key.clone());
        transition.physical_home_key = Some(physical_home_key.clone());
    }
    transition.codex_home_path = Some(codex_home_path);
    transition.source_path = Some(source_path);
    transition.source_kind = Some(codex_home.source.clone());
    transition.source_exists = codex_home.exists;

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
fn physical_home_key(path: &Path) -> Result<String, String> {
    use std::os::unix::fs::MetadataExt;

    let metadata = std::fs::metadata(path).map_err(|error| {
        format!("Codex Home physical identity unavailable for {}: {error}", path.display())
    })?;
    Ok(format!("unix:{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn physical_home_key(path: &Path) -> Result<String, String> {
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
fn physical_home_key(path: &Path) -> Result<String, String> {
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
pub fn read_platform_capabilities() -> Result<PlatformCapabilities, String> {
    startup_trace::mark("command read_platform_capabilities start");
    let result = platform::platform_capabilities();
    startup_trace::mark("command read_platform_capabilities end");
    Ok(result)
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
    let result = run_source_bound_dashboard_read(&app, source_token, |codex_home| {
        crate::core::dashboard::LocalCodexDataSource::new(codex_home).read_dashboard_snapshot()
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_dashboard_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    startup_trace::mark("command read_dashboard_snapshot end");
    result
}

#[tauri::command]
pub async fn read_precise_dashboard_snapshot(
    window: tauri::WebviewWindow,
    app: AppHandle,
    source_token: CodexHomeSourceToken,
) -> Result<DashboardSnapshot, String> {
    require_window_label(&window, "read_precise_dashboard_snapshot")?;
    let started = Instant::now();
    let result = run_source_bound_dashboard_read(&app, source_token, |codex_home| {
        crate::core::dashboard::LocalCodexDataSource::new(codex_home)
            .read_precise_dashboard_snapshot()
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_precise_dashboard_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
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

async fn run_source_bound_dashboard_read<T, Read>(
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
    app: AppHandle,
    source_token: CodexHomeSourceToken,
) -> Result<TokenUsageSummary, String> {
    let started = Instant::now();
    let result = run_source_bound_dashboard_read(&app, source_token, |codex_home| {
        token_count_jsonl::usage_summary_snapshot(&codex_home)
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
pub fn read_usage_cache_status(window: tauri::WebviewWindow) -> Result<UsageCacheStatus, String> {
    require_window_label(&window, "read_usage_cache_status")?;
    Ok(cache_lifecycle::usage_cache_status())
}

#[tauri::command]
pub async fn read_account_quota(
    app: AppHandle,
    source_token: CodexHomeSourceToken,
    force_refresh: Option<bool>,
) -> Result<AccountQuotaBundle, String> {
    startup_trace::mark_once("command read_account_quota start");
    let started = Instant::now();
    let forced = force_refresh.unwrap_or(false);
    let result = run_source_bound_dashboard_read(&app, source_token, move |codex_home| {
        crate::core::dashboard::LocalCodexDataSource::new(codex_home)
            .read_account_quota(forced)
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_account_quota force={} {}ms {}",
        forced,
        started.elapsed().as_millis(),
        account_quota_result_status(&result)
    ));
    startup_trace::mark_once("command read_account_quota end");
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
    use crate::models::{
        AccountInfo, AccountQuotaBundle, QuotaLimit, QuotaSnapshot, ResetCreditSummary,
    };
    use std::cell::{Cell, RefCell};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static SOURCE_TEST_PATH_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn codex_home_transition_publishes_canonical_envelope_after_durable_save() {
        let home = disposable_source_test_directory("publish-order");
        let order = RefCell::new(Vec::new());
        let mut transition = CodexHomeTransitionState::default();

        let envelope = commit_codex_home_transition(
            &mut transition,
            || {
                order.borrow_mut().push("save");
                Ok(codex_home_status_for_test(home.join("."), "manual"))
            },
            |published| {
                order.borrow_mut().push("publish");
                assert_eq!(
                    published.codex_home.path,
                    home.join(".").display().to_string()
                );
                assert_eq!(published.canonical_home_key, canonical_home_key(&home));
                assert_eq!(published.transition_generation, 1);
                Ok::<(), String>(())
            },
        )
        .expect("durable save should return its exact envelope");

        assert_eq!(order.into_inner(), vec!["save", "publish"]);
        assert_eq!(envelope.canonical_home_key, canonical_home_key(&home));
        remove_source_test_directory(home);
    }

    #[test]
    fn codex_home_transition_does_not_publish_when_durable_save_fails() {
        let published = Cell::new(false);
        let mut transition = CodexHomeTransitionState::default();

        let result = commit_codex_home_transition(
            &mut transition,
            || Err("injected durable save failure".into()),
            |_| {
                published.set(true);
                Ok::<(), String>(())
            },
        );

        assert_eq!(result.unwrap_err(), "injected durable save failure");
        assert!(!published.get());
        assert_eq!(transition.transition_generation, 0);
        assert_eq!(transition.canonical_home_key, None);
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
        let displaced = home.with_extension("displaced");
        let session_path = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&session_path).unwrap();
        std::fs::write(session_path.join("observation.jsonl"), "A").unwrap();
        let mut transition = CodexHomeTransitionState::default();
        let source_a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home.clone(), "manual"),
        )
        .unwrap();
        let captured =
            capture_codex_home_source_from_state(&transition, &source_a.source_token()).unwrap();
        let pinned = pin_captured_codex_home_source(&captured).expect("pin physical A");

        std::fs::rename(&home, &displaced).expect("replace A with B after pin");
        std::fs::create_dir(&home).expect("install B at the same canonical path");
        let session_path_b = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&session_path_b).unwrap();
        std::fs::write(session_path_b.join("observation.jsonl"), "B").unwrap();
        std::fs::remove_dir_all(&home).unwrap();
        std::fs::rename(&displaced, &home).expect("restore A before validation");

        assert_eq!(
            std::fs::read_to_string(
                pinned
                    .read_path()
                    .join(session_path.strip_prefix(&home).unwrap())
                    .join("observation.jsonl"),
            )
            .unwrap(),
            "A"
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
        let session_path = canonical_session_test_directory(&target);
        std::fs::create_dir_all(&session_path).unwrap();
        std::fs::write(session_path.join("observation.jsonl"), "target").unwrap();
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
            std::fs::read_to_string(
                pinned
                    .read_path()
                    .join(session_path.strip_prefix(&target).unwrap())
                    .join("observation.jsonl"),
            )
            .unwrap(),
            "target"
        );

        std::fs::remove_file(link).unwrap();
        remove_source_test_directory(target);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_copies_only_bounded_recent_session_candidates() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("bounded-pinned-sessions");
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
        reset_pinned_source_copy_count_for_test();

        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert_eq!(pinned_source_copy_count_for_test(), 2);
        assert_eq!(pinned_source_inspected_count_for_test(), 2);
        assert_eq!(
            std::fs::read_dir(
                pinned
                    .read_path()
                    .join(sessions.strip_prefix(&home).unwrap()),
            )
                .unwrap()
                .count(),
            2
        );
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_selects_the_newest_sixty_four_recent_sessions() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("newest-pinned-sessions");
        let sessions = canonical_session_test_directory(&home);
        std::fs::create_dir_all(&sessions).unwrap();
        let base = std::time::SystemTime::now() - std::time::Duration::from_secs(20);
        for index in 0..70 {
            let path = sessions.join(format!("recent-{index:02}.jsonl"));
            std::fs::write(&path, format!("session-{index}")).unwrap();
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

        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert_eq!(
            std::fs::read_dir(
                pinned
                    .read_path()
                    .join(sessions.strip_prefix(&home).unwrap()),
            )
                .unwrap()
                .count(),
            64
        );
        assert!(!pinned
            .read_path()
            .join(sessions.strip_prefix(&home).unwrap())
            .join("recent-05.jsonl")
            .exists());
        assert!(pinned
            .read_path()
            .join(sessions.strip_prefix(&home).unwrap())
            .join("recent-69.jsonl")
            .exists());
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
    fn owner_lock_cleanup_removes_all_stale_and_preserves_active_or_unknown() {
        let root = disposable_source_test_directory("stale-cache-cleanup");
        for index in 0..100 {
            std::fs::create_dir(root.join(format!("unrelated-{index}"))).unwrap();
        }
        let same_pid_old_epoch = root.join(format!(
            "codex-token-bar-pinned-db-{:x}-old-0",
            std::process::id()
        ));
        std::fs::create_dir(&same_pid_old_epoch).unwrap();
        std::fs::write(same_pid_old_epoch.join(".owner.lock"), b"").unwrap();
        let mut stale = Vec::new();
        for index in 0..65 {
            let path = root.join(format!("codex-token-bar-pinned-db-deadbeef-old-{index}"));
            std::fs::create_dir(&path).unwrap();
            std::fs::write(path.join(".owner.lock"), b"").unwrap();
            stale.push(path);
        }
        let active = root.join("codex-token-bar-pinned-db-active-epoch-1");
        let unknown = root.join("codex-token-bar-pinned-db-unknown-epoch-1");
        std::fs::create_dir(&active).unwrap();
        std::fs::create_dir(&unknown).unwrap();
        let active_lock = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(active.join(".owner.lock"))
            .unwrap();
        rustix::fs::flock(&active_lock, rustix::fs::FlockOperation::LockExclusive).unwrap();

        clean_stale_pinned_db_snapshots_in(&root).unwrap();

        assert!(!same_pid_old_epoch.exists());
        assert!(stale.iter().all(|path| !path.exists()));
        assert!(active.exists());
        assert!(unknown.exists());
        let (created, created_lock) = create_owned_pinned_db_directory(&root).unwrap();
        assert!(created.exists());
        assert_ne!(created, same_pid_old_epoch);
        drop(created_lock);
        std::fs::remove_dir_all(created).unwrap();
        drop(active_lock);
        remove_source_test_directory(root);
    }

    #[cfg(unix)]
    #[test]
    fn owned_cache_directory_is_published_only_after_its_lock_is_held() {
        let root = disposable_source_test_directory("cache-publish-lock");
        let mut phases = Vec::new();
        let (published, owner_lock) = create_owned_pinned_db_directory_with_hook(
            &root,
            |staging, final_path, published| {
                clean_stale_pinned_db_snapshots_in(&root).unwrap();
                phases.push(published);
                if published {
                    assert!(final_path.exists());
                } else {
                    assert!(staging.exists());
                    assert!(!final_path.exists());
                }
            },
        )
        .unwrap();

        assert_eq!(phases, vec![false, true]);
        assert!(published.exists());
        clean_stale_pinned_db_snapshots_in(&root).unwrap();
        assert!(published.exists());
        drop(owner_lock);
        clean_stale_pinned_db_snapshots_in(&root).unwrap();
        assert!(!published.exists());
        remove_source_test_directory(root);
    }

    #[cfg(unix)]
    #[test]
    fn cache_publication_collision_retries_without_staging_or_owner_residue() {
        let root = disposable_source_test_directory("cache-publish-collision");
        let mut collision = None;
        let (published, owner_lock) = create_owned_pinned_db_directory_with_hook(
            &root,
            |_, final_path, published| {
                if !published && collision.is_none() {
                    std::fs::create_dir(final_path).unwrap();
                    collision = Some(final_path.to_path_buf());
                }
            },
        )
        .unwrap();

        assert!(published.exists());
        assert!(std::fs::read_dir(&root).unwrap().flatten().all(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            !name.starts_with(".codex-token-bar-pinned-db-staging-")
                && !name.starts_with(".codex-token-bar-pinned-db-owner-")
        }));
        std::fs::remove_dir(collision.unwrap()).unwrap();
        drop(owner_lock);
        clean_stale_pinned_db_snapshots_in(&root).unwrap();
        assert!(!published.exists());
        remove_source_test_directory(root);
    }

    #[cfg(unix)]
    #[test]
    fn stale_cleanup_never_follows_candidate_or_owner_lock_symlinks() {
        use std::os::unix::fs::symlink;

        let root = disposable_source_test_directory("cache-cleanup-symlink");
        let outside = disposable_source_test_directory("cache-cleanup-outside");
        std::fs::write(outside.join("sentinel"), b"keep").unwrap();
        let candidate_link = root.join("codex-token-bar-pinned-db-linked-epoch-1");
        symlink(&outside, &candidate_link).unwrap();

        let lock_link_dir = root.join("codex-token-bar-pinned-db-lock-link-epoch-1");
        std::fs::create_dir(&lock_link_dir).unwrap();
        let outside_lock = outside.join("outside.lock");
        std::fs::write(&outside_lock, b"keep").unwrap();
        symlink(&outside_lock, lock_link_dir.join(".owner.lock")).unwrap();

        clean_stale_pinned_db_snapshots_in(&root).unwrap();

        assert!(candidate_link.symlink_metadata().is_ok());
        assert!(lock_link_dir.exists());
        assert_eq!(std::fs::read(outside.join("sentinel")).unwrap(), b"keep");
        assert_eq!(std::fs::read(outside_lock).unwrap(), b"keep");
        std::fs::remove_file(candidate_link).unwrap();
        remove_source_test_directory(root);
        remove_source_test_directory(outside);
    }

    #[cfg(unix)]
    #[test]
    fn stale_cleanup_revalidates_lock_and_directory_identity_after_locking() {
        let root = disposable_source_test_directory("cache-cleanup-revalidate");
        let lock_swapped = root.join("codex-token-bar-pinned-db-lock-swap-1");
        std::fs::create_dir(&lock_swapped).unwrap();
        std::fs::write(lock_swapped.join(".owner.lock"), b"old").unwrap();
        let directory_swapped = root.join("codex-token-bar-pinned-db-dir-swap-1");
        std::fs::create_dir(&directory_swapped).unwrap();
        std::fs::write(directory_swapped.join(".owner.lock"), b"old").unwrap();
        let moved_directory = root.join("moved-original");

        clean_stale_pinned_db_snapshots_in_with_hook(&root, |name| {
            if name == "codex-token-bar-pinned-db-lock-swap-1" {
                std::fs::rename(
                    lock_swapped.join(".owner.lock"),
                    lock_swapped.join("old.lock"),
                )
                .unwrap();
                std::fs::write(lock_swapped.join(".owner.lock"), b"new").unwrap();
            } else if name == "codex-token-bar-pinned-db-dir-swap-1" {
                std::fs::rename(&directory_swapped, &moved_directory).unwrap();
                std::fs::create_dir(&directory_swapped).unwrap();
                std::fs::write(directory_swapped.join(".owner.lock"), b"new").unwrap();
            }
        })
        .unwrap();

        assert!(lock_swapped.exists());
        assert!(lock_swapped.join(".owner.lock").exists());
        assert!(directory_swapped.exists());
        assert!(moved_directory.exists());
        remove_source_test_directory(root);
    }

    #[cfg(unix)]
    #[test]
    fn staging_cleanup_is_owner_locked_bounded_and_symlink_safe() {
        use std::os::unix::fs::symlink;

        let root = disposable_source_test_directory("staging-cleanup");
        let active_owner = root.join(".codex-token-bar-pinned-db-owner-active-1.lock");
        let active_staging = root.join(".codex-token-bar-pinned-db-staging-active-1");
        std::fs::write(&active_owner, b"").unwrap();
        let active_lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&active_owner)
            .unwrap();
        rustix::fs::flock(&active_lock, rustix::fs::FlockOperation::LockExclusive).unwrap();
        std::fs::create_dir(&active_staging).unwrap();
        std::fs::hard_link(&active_owner, active_staging.join(".owner.lock")).unwrap();

        let mut stale = Vec::new();
        for index in 0..65 {
            let owner = root.join(format!(
                ".codex-token-bar-pinned-db-owner-stale-{index}.lock"
            ));
            let staging = root.join(format!(
                ".codex-token-bar-pinned-db-staging-stale-{index}"
            ));
            std::fs::write(&owner, b"").unwrap();
            std::fs::create_dir(&staging).unwrap();
            std::fs::hard_link(&owner, staging.join(".owner.lock")).unwrap();
            stale.push((owner, staging));
        }
        let fresh_ownerless = root.join(".codex-token-bar-pinned-db-staging-fresh-1");
        std::fs::create_dir(&fresh_ownerless).unwrap();
        let orphan_owner = root.join(".codex-token-bar-pinned-db-owner-orphan-1.lock");
        std::fs::write(&orphan_owner, b"").unwrap();

        let outside = disposable_source_test_directory("staging-cleanup-outside");
        std::fs::write(outside.join("sentinel"), b"keep").unwrap();
        let staging_link = root.join(".codex-token-bar-pinned-db-staging-linked-1");
        symlink(&outside, &staging_link).unwrap();
        let owner_link = root.join(".codex-token-bar-pinned-db-owner-linked-1.lock");
        symlink(outside.join("sentinel"), &owner_link).unwrap();

        clean_stale_pinned_db_snapshots_in_with_policy(&root, |_| {}, |_| false).unwrap();
        assert!(active_staging.exists());
        assert!(fresh_ownerless.exists());

        clean_stale_pinned_db_snapshots_in_with_policy(&root, |_| {}, |_| true).unwrap();
        assert!(active_staging.exists());
        assert!(active_owner.exists());
        assert!(stale
            .iter()
            .all(|(owner, staging)| !owner.exists() && !staging.exists()));
        assert!(!fresh_ownerless.exists());
        assert!(!orphan_owner.exists());
        assert!(staging_link.symlink_metadata().is_ok());
        assert!(owner_link.symlink_metadata().is_ok());
        assert_eq!(std::fs::read(outside.join("sentinel")).unwrap(), b"keep");

        drop(active_lock);
        clean_stale_pinned_db_snapshots_in_with_policy(&root, |_| {}, |_| true).unwrap();
        assert!(!active_staging.exists());
        assert!(!active_owner.exists());
        std::fs::remove_file(staging_link).unwrap();
        std::fs::remove_file(owner_link).unwrap();
        remove_source_test_directory(root);
        remove_source_test_directory(outside);
    }

    #[cfg(unix)]
    #[test]
    fn sessions_root_allows_ds_store_without_weakening_layout_validation() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("sessions-ds-store");
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

        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert!(pinned
            .read_path()
            .join(current.strip_prefix(&home).unwrap())
            .join("recent.jsonl")
            .exists());
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_fails_with_diagnostic_when_archived_fallback_cannot_be_safe() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("unsafe-archived-fallback");
        std::fs::write(
            home.join(".codex-global-state.json"),
            r#"{"unread-thread-ids-by-host-v1":{"localhost":["019eaaaa-0000-0000-0000-0000000000aa"]}}"#,
        )
        .unwrap();
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
        std::fs::write(
            home.join(".codex-global-state.json"),
            r#"{"unread-thread-ids-by-host-v1":{"localhost":[]}}"#,
        )
        .unwrap();
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
        reset_pinned_source_copy_count_for_test();

        let pinned = pin_captured_codex_home_source(&captured).unwrap();

        assert_eq!(pinned_source_db_copy_count_for_test(), 0);
        assert!(!pinned.read_path().join("state_5.sqlite").exists());
        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn state_sqlite_directory_is_rejected_as_a_non_file() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("sqlite-directory");
        std::fs::write(
            home.join(".codex-global-state.json"),
            r#"{"unread-thread-ids-by-host-v1":{"localhost":["019eaaaa-0000-0000-0000-0000000000aa"]}}"#,
        )
        .unwrap();
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
    fn unchanged_native_state_and_db_reuse_verified_db_snapshot_until_signature_changes() {
        let _guard = pinned_source_counter_test_guard();
        let home = disposable_source_test_directory("db-signature-cache");
        let thread_id = "019eaaaa-0000-0000-0000-0000000000aa";
        std::fs::write(
            home.join(".codex-global-state.json"),
            format!(r#"{{"unread-thread-ids-by-host-v1":{{"localhost":["{thread_id}"]}}}}"#),
        )
        .unwrap();
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
        reset_pinned_source_copy_count_for_test();

        drop(pin_captured_codex_home_source(&captured).unwrap());
        drop(pin_captured_codex_home_source(&captured).unwrap());
        assert_eq!(pinned_source_db_copy_count_for_test(), 1);

        let connection = rusqlite::Connection::open(&database_path).unwrap();
        connection
            .execute("UPDATE threads SET preview = 'changed' WHERE id = ?1", [thread_id])
            .unwrap();
        drop(connection);
        drop(pin_captured_codex_home_source(&captured).unwrap());
        assert_eq!(pinned_source_db_copy_count_for_test(), 2);

        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn empty_native_source_evicts_previous_physical_db_cache_and_directory() {
        let _guard = pinned_source_counter_test_guard();
        let home_a = disposable_source_test_directory("cache-source-a");
        let thread_id = "019eaaaa-0000-0000-0000-0000000000aa";
        std::fs::write(
            home_a.join(".codex-global-state.json"),
            format!(r#"{{"unread-thread-ids-by-host-v1":{{"localhost":["{thread_id}"]}}}}"#),
        )
        .unwrap();
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
        let key_a = format!("{}|{}", source_a.canonical_home_key, source_a.physical_home_key);
        let cached_directory = {
            let cache = pinned_db_snapshot_cache().unwrap().lock().unwrap();
            cache.get(&key_a).unwrap().directory.clone()
        };

        let home_b = disposable_source_test_directory("cache-source-b-empty");
        std::fs::write(
            home_b.join(".codex-global-state.json"),
            r#"{"unread-thread-ids-by-host-v1":{"localhost":[]}}"#,
        )
        .unwrap();
        let mut transition_b = CodexHomeTransitionState::default();
        let source_b = resolve_codex_home_source(
            &mut transition_b,
            codex_home_status_for_test(home_b.clone(), "manual"),
        )
        .unwrap();
        let captured_b =
            capture_codex_home_source_from_state(&transition_b, &source_b.source_token()).unwrap();
        drop(pin_captured_codex_home_source(&captured_b).unwrap());

        assert!(!pinned_db_snapshot_cache()
            .unwrap()
            .lock()
            .unwrap()
            .contains_key(&key_a));
        assert!(!cached_directory.exists());

        remove_source_test_directory(home_a);
        remove_source_test_directory(home_b);
    }

    #[cfg(unix)]
    #[test]
    fn failed_db_snapshot_creation_leaves_no_task_owned_directory() {
        let _guard = pinned_source_counter_test_guard();
        let prefix = format!(
            "codex-token-bar-pinned-db-{}-",
            process_session_identity()
        );
        let count = || {
            std::fs::read_dir(std::env::temp_dir())
                .unwrap()
                .flatten()
                .filter(|entry| entry.file_name().to_string_lossy().starts_with(&prefix))
                .count()
        };
        let before = count();
        let home = disposable_source_test_directory("failed-db-cache");
        std::fs::write(
            home.join(".codex-global-state.json"),
            r#"{"unread-thread-ids-by-host-v1":{"localhost":["019eaaaa-0000-0000-0000-0000000000aa"]}}"#,
        )
        .unwrap();
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
        assert_eq!(count(), before);
        remove_source_test_directory(home);
    }

    #[test]
    fn account_quota_trace_status_distinguishes_placeholder_bundle_from_real_quota() {
        let mut quota = placeholder_quota_for_test();
        quota.pace_label = "额度读取失败".into();
        let placeholder = Ok(AccountQuotaBundle {
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
    fn account_quota_trace_keeps_full_retry_diagnostics() {
        let long_warning = format!(
            "额度读取失败：网络连接失败：{}",
            "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)；".repeat(8)
        );
        let placeholder = Ok(AccountQuotaBundle {
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
                time::UtcOffset::current_local_offset().unwrap_or(time::UtcOffset::UTC),
            )
            .into_iter()
            .next()
            .unwrap(),
        )
    }

}
