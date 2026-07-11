use super::window_auth::require_window_label;
use crate::commands::local_source;
use crate::core::dashboard::DashboardDataSource;
use crate::core::startup_trace;
use crate::core::usage::cache_lifecycle::{self, UsageCacheStatus};
use crate::core::usage::token_count_jsonl::{self, TokenUsageSummary};
use crate::models::{AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, PlatformCapabilities};
use crate::platform;
use serde::{Deserialize, Serialize};
use std::fmt::Display;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;
use tauri::{async_runtime, Emitter};

pub(crate) const CODEX_HOME_SOURCE_CHANGED_EVENT: &str = "codex-home-source-changed";

static CODEX_HOME_TRANSITION_STATE: OnceLock<Mutex<CodexHomeTransitionState>> = OnceLock::new();
static PINNED_SOURCE_SNAPSHOT_SEQUENCE: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static PINNED_SOURCE_SESSION_FILES_COPIED: AtomicU64 = AtomicU64::new(0);

const PINNED_SESSION_FILE_LIMIT: usize = 64;
const PINNED_SESSION_ENTRY_LIMIT: usize = 1_024;
const PINNED_SESSION_FIRST_LINE_LIMIT: u64 = 262_144;
const PINNED_SESSION_TAIL_LIMIT: u64 = 4 * 1024 * 1024;
const PINNED_SESSION_LOOKBACK_SECONDS: i64 = 30;

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
    path: String,
) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "set_codex_home")?;
    persist_codex_home_transition(window, || platform::save_codex_home(&path))
}

#[tauri::command]
pub fn reset_codex_home(window: tauri::WebviewWindow) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "reset_codex_home")?;
    persist_codex_home_transition(window, platform::reset_codex_home)
}

fn persist_codex_home_transition(
    window: tauri::WebviewWindow,
    save: impl FnOnce() -> Result<CodexHomeStatus, String>,
) -> Result<CodexHomeSourceEnvelope, String> {
    with_codex_home_transition_state(|transition| {
        commit_codex_home_transition(transition, save, |envelope| {
            window
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
    let snapshot_path = snapshot_pinned_unread_source(&handle)?;
    Ok(PinnedCodexHomeSource {
        _handle: handle,
        read_path: snapshot_path.clone(),
        snapshot_path: Some(snapshot_path),
        source_scope_key: format!(
            "{}|{}",
            captured.source_token.canonical_home_key,
            captured.source_token.physical_home_key
        ),
    })
}

#[cfg(unix)]
fn snapshot_pinned_unread_source(root: &std::fs::File) -> Result<PathBuf, String> {
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
    let result = (|| {
        for file_name in [
            ".codex-global-state.json",
            "state_5.sqlite",
            "state_5.sqlite-wal",
            "state_5.sqlite-shm",
        ] {
            copy_optional_pinned_entry(root, file_name, &snapshot.join(file_name))?;
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
    let cutoff = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64 - PINNED_SESSION_LOOKBACK_SECONDS)
        .unwrap_or(i64::MAX);
    let mut copied = 0usize;
    let mut inspected = 0usize;
    copy_recent_pinned_session_tree(
        &sessions,
        destination,
        cutoff,
        &mut inspected,
        &mut copied,
    )
}

#[cfg(unix)]
fn copy_recent_pinned_session_tree<Fd: std::os::fd::AsFd>(
    parent: Fd,
    destination: &Path,
    cutoff: i64,
    inspected: &mut usize,
    copied: &mut usize,
) -> Result<(), String> {
    use rustix::fs::{openat, statat, AtFlags, Dir, FileType, Mode, OFlags};
    use std::ffi::OsStr;
    use std::io::{Read, Seek, SeekFrom, Write};
    use std::os::unix::ffi::OsStrExt;

    let mut directory = Dir::read_from(&parent)
        .map_err(|error| format!("failed to enumerate pinned sessions: {error}"))?;
    while let Some(entry) = directory.read() {
        let entry = entry.map_err(|error| format!("failed to enumerate pinned sessions: {error}"))?;
        let bytes = entry.file_name().to_bytes();
        if bytes == b"." || bytes == b".." {
            continue;
        }
        *inspected += 1;
        if *inspected > PINNED_SESSION_ENTRY_LIMIT {
            return Err(format!(
                "pinned session observation exceeded {PINNED_SESSION_ENTRY_LIMIT} entries"
            ));
        }
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
                copy_recent_pinned_session_tree(
                    &fd,
                    &destination.join(child_name),
                    cutoff,
                    inspected,
                    copied,
                )?;
            }
            FileType::RegularFile => {
                if *copied >= PINNED_SESSION_FILE_LIMIT
                    || !child_name
                        .to_string_lossy()
                        .to_ascii_lowercase()
                        .ends_with(".jsonl")
                    || stat.st_mtime < cutoff
                {
                    continue;
                }
                let fd = openat(
                    &parent,
                    child_name_text.as_ref(),
                    OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
                    Mode::empty(),
                )
                .map_err(|error| format!("failed to open recent pinned session: {error}"))?;
                let mut source = std::fs::File::from(fd);
                let size = source
                    .metadata()
                    .map_err(|error| format!("failed to inspect recent pinned session: {error}"))?
                    .len();
                std::fs::create_dir_all(destination).map_err(|error| {
                    format!("failed to create pinned session snapshot directory: {error}")
                })?;
                let mut target = std::fs::File::create(destination.join(child_name)).map_err(
                    |error| format!("failed to create pinned session snapshot: {error}"),
                )?;
                if size <= PINNED_SESSION_FIRST_LINE_LIMIT + PINNED_SESSION_TAIL_LIMIT {
                    std::io::copy(&mut source, &mut target).map_err(|error| {
                        format!("failed to copy recent pinned session: {error}")
                    })?;
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
                    target.write_all(&first[..first_line_end]).map_err(|error| {
                        format!("failed to write pinned session head: {error}")
                    })?;
                    source
                        .seek(SeekFrom::Start(size - PINNED_SESSION_TAIL_LIMIT))
                        .map_err(|error| format!("failed to seek pinned session tail: {error}"))?;
                    std::io::copy(&mut source.take(PINNED_SESSION_TAIL_LIMIT), &mut target)
                        .map_err(|error| format!("failed to copy pinned session tail: {error}"))?;
                }
                *copied += 1;
                #[cfg(test)]
                PINNED_SOURCE_SESSION_FILES_COPIED.fetch_add(1, Ordering::Relaxed);
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
pub(crate) fn reset_pinned_source_copy_count_for_test() {
    PINNED_SOURCE_SESSION_FILES_COPIED.store(0, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn pinned_source_copy_count_for_test() -> u64 {
    PINNED_SOURCE_SESSION_FILES_COPIED.load(Ordering::Relaxed)
}

#[cfg(unix)]
fn copy_optional_pinned_entry<Fd: std::os::fd::AsFd>(
    parent: Fd,
    name: &str,
    destination: &Path,
) -> Result<(), String> {
    use rustix::fs::{openat, statat, AtFlags, Dir, FileType, Mode, OFlags};
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

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
            Ok(())
        }
        FileType::Directory => {
            std::fs::create_dir(destination).map_err(|error| {
                format!("failed to create pinned unread snapshot directory {name}: {error}")
            })?;
            let fd = openat(
                &parent,
                name,
                OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::DIRECTORY,
                Mode::empty(),
            )
            .map_err(|error| format!("failed to open pinned unread directory {name}: {error}"))?;
            let mut directory = Dir::read_from(&fd)
                .map_err(|error| format!("failed to enumerate pinned unread directory {name}: {error}"))?;
            while let Some(entry) = directory.read() {
                let entry = entry.map_err(|error| {
                    format!("failed to enumerate pinned unread directory {name}: {error}")
                })?;
                let bytes = entry.file_name().to_bytes();
                if bytes == b"." || bytes == b".." {
                    continue;
                }
                let child_name = OsStr::from_bytes(bytes);
                let child_name_text = child_name.to_string_lossy();
                copy_optional_pinned_entry(
                    &fd,
                    child_name_text.as_ref(),
                    &destination.join(child_name),
                )?;
            }
            Ok(())
        }
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
) -> Result<DashboardSnapshot, String> {
    require_window_label(&window, "read_dashboard_snapshot")?;
    startup_trace::mark("command read_dashboard_snapshot start");
    let started = Instant::now();
    let result = run_blocking_command(|| local_source().read_dashboard_snapshot()).await;
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
) -> Result<DashboardSnapshot, String> {
    require_window_label(&window, "read_precise_dashboard_snapshot")?;
    let started = Instant::now();
    let result = run_blocking_command(|| local_source().read_precise_dashboard_snapshot()).await;
    startup_trace::mark_performance(format!(
        "read_precise_dashboard_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn read_usage_summary_snapshot() -> Result<TokenUsageSummary, String> {
    let started = Instant::now();
    let codex_home = platform::default_codex_home();
    let result =
        run_blocking_command(move || token_count_jsonl::usage_summary_snapshot(&codex_home)).await;
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
pub async fn read_account_quota(force_refresh: Option<bool>) -> Result<AccountQuotaBundle, String> {
    startup_trace::mark_once("command read_account_quota start");
    let started = Instant::now();
    let forced = force_refresh.unwrap_or(false);
    let result = run_blocking_command(move || local_source().read_account_quota(forced)).await;
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
        let home = disposable_source_test_directory("pinned-source-a");
        let displaced = home.with_extension("displaced");
        std::fs::write(home.join(".codex-global-state.json"), "A").unwrap();
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
        std::fs::write(home.join(".codex-global-state.json"), "B").unwrap();
        std::fs::remove_dir_all(&home).unwrap();
        std::fs::rename(&displaced, &home).expect("restore A before validation");

        assert_eq!(
            std::fs::read_to_string(pinned.read_path().join(".codex-global-state.json")).unwrap(),
            "A"
        );
        assert!(pinned.source_scope_key.contains(&source_a.physical_home_key));

        remove_source_test_directory(home);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_accepts_a_legal_canonical_target() {
        use std::os::unix::fs::symlink;

        let target = disposable_source_test_directory("canonical-target");
        let link = target.with_extension("link");
        symlink(&target, &link).unwrap();
        std::fs::write(target.join(".codex-global-state.json"), "target").unwrap();
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
            std::fs::read_to_string(pinned.read_path().join(".codex-global-state.json")).unwrap(),
            "target"
        );

        std::fs::remove_file(link).unwrap();
        remove_source_test_directory(target);
    }

    #[cfg(unix)]
    #[test]
    fn pinned_source_copies_only_bounded_recent_session_candidates() {
        let home = disposable_source_test_directory("bounded-pinned-sessions");
        let sessions = home.join("sessions");
        std::fs::create_dir(&sessions).unwrap();
        let old_time = std::fs::FileTimes::new()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1));
        for index in 0..200 {
            let path = sessions.join(format!("old-{index}.jsonl"));
            std::fs::write(&path, "old").unwrap();
            std::fs::File::options()
                .write(true)
                .open(path)
                .unwrap()
                .set_times(old_time.clone())
                .unwrap();
        }
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
        assert_eq!(
            std::fs::read_dir(pinned.read_path().join("sessions"))
                .unwrap()
                .count(),
            2
        );
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
}
