//! Best-effort, privacy-bounded diagnostics for local recovery attempts.
//!
//! This module deliberately has no background worker. Records stay in a small
//! memory queue until another record arrives after the one-second write window,
//! the queue reaches its bound, or the caller closes/drops the guard.

use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const FORMAT: &str = "tokenbar-recovery-diagnostic-v1";
const OWNER_MARKER: &[u8] = b"tokenbar-recovery-diagnostics-v1\n";
const MAX_QUEUE_ROWS: usize = 32;
const MAX_QUEUE_BYTES: usize = 64 * 1024;
const MAX_SESSION_BYTES: u64 = 256 * 1024;
const MAX_LATEST_FAILURE_BYTES: usize = 4 * 1024;
const MAX_HEADER_BYTES: usize = 4 * 1024;
const MAX_DIRECTORY_ENTRIES: usize = 4_096;
const FLUSH_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Phase {
    Preparing,
    Importing,
    Verifying,
    Activating,
    Ready,
    Failure,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RecordStatus {
    Disabled,
    Buffered,
    Flushed,
    QueueFull,
    SessionLimit,
    WriteFailed,
    Closed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RecordOutcome {
    pub(crate) status: RecordStatus,
    /// `Some` only for a failure record. This is a diagnostic write result,
    /// never a recovery or publication authority.
    pub(crate) latest_failure_written: Option<bool>,
}

/// A best-effort guard. Failure to prepare or write diagnostics never fails the
/// recovery operation being observed.
pub(crate) struct RecoveryDiagnostics {
    state: Option<Mutex<State>>,
}

struct State {
    root: PathBuf,
    file: Option<File>,
    queue: VecDeque<Vec<u8>>,
    queued_bytes: usize,
    file_bytes: u64,
    last_flush: Instant,
    closed: bool,
    session_full: bool,
    #[cfg(test)]
    fail_next_write: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionHeader {
    format: String,
    attempt: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiagnosticRecord {
    phase: Phase,
    at: f64,
    completed: u64,
    total: u64,
    #[serde(rename = "retryCount")]
    retry_count: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<i32>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LatestFailure {
    format: String,
    event: DiagnosticRecord,
}

#[derive(Clone, Copy)]
struct RetentionPolicy {
    max_age: Duration,
    max_total_bytes: u64,
    max_session_bytes: u64,
}

const RETENTION: RetentionPolicy = RetentionPolicy {
    max_age: Duration::from_secs(30 * 24 * 60 * 60),
    max_total_bytes: 50 * 1024 * 1024 - MAX_SESSION_BYTES,
    max_session_bytes: MAX_SESSION_BYTES,
};

impl RecoveryDiagnostics {
    /// Prepare a strictly owned diagnostics directory and start a new session.
    /// All errors are converted into a disabled guard.
    pub(crate) fn start(root: &Path) -> Self {
        let Some(state) = prepare_session(root) else {
            return Self { state: None };
        };
        Self {
            state: Some(Mutex::new(state)),
        }
    }

    /// Append a fixed-schema record. No paths, account identifiers, arbitrary
    /// error messages, or user supplied strings are accepted by this API.
    pub(crate) fn record(
        &self,
        phase: Phase,
        completed: u64,
        total: u64,
        retry_count: u64,
        code: Option<i32>,
    ) -> RecordOutcome {
        let Some(state) = &self.state else {
            return RecordOutcome {
                status: RecordStatus::Disabled,
                latest_failure_written: None,
            };
        };
        let Ok(mut state) = state.lock() else {
            return RecordOutcome {
                status: RecordStatus::Disabled,
                latest_failure_written: None,
            };
        };
        if state.closed {
            return RecordOutcome {
                status: RecordStatus::Closed,
                latest_failure_written: None,
            };
        }

        // A call is the only automatic flush trigger. The one-second gate
        // bounds writes even when callers produce a burst of records.
        if !state.queue.is_empty() && state.last_flush.elapsed() >= FLUSH_INTERVAL {
            if flush_queue(&mut state).is_err() {
                return RecordOutcome {
                    status: RecordStatus::WriteFailed,
                    latest_failure_written: if phase == Phase::Failure {
                        Some(write_latest_failure(
                            state_root_for_failure(&state),
                            phase,
                            completed,
                            total,
                            retry_count,
                            code,
                        ))
                    } else {
                        None
                    },
                };
            }
        }

        let latest_failure_written = if phase == Phase::Failure {
            Some(write_latest_failure(
                session_root(&state),
                phase,
                completed,
                total,
                retry_count,
                code,
            ))
        } else {
            None
        };

        if state.session_full || state.file.is_none() {
            return RecordOutcome {
                status: if state.file.is_none() {
                    RecordStatus::WriteFailed
                } else {
                    RecordStatus::SessionLimit
                },
                latest_failure_written,
            };
        }

        let record = DiagnosticRecord {
            phase,
            at: unix_now_fractional(),
            completed: completed.min(i64::MAX as u64),
            total: total.min(i64::MAX as u64),
            retry_count: retry_count.min(i64::MAX as u64),
            code,
        };
        let mut bytes = match serde_json::to_vec(&record) {
            Ok(bytes) => bytes,
            Err(_) => {
                return RecordOutcome {
                    status: RecordStatus::WriteFailed,
                    latest_failure_written,
                }
            }
        };
        bytes.push(b'\n');

        if state
            .file_bytes
            .saturating_add(state.queued_bytes as u64)
            .saturating_add(bytes.len() as u64)
            > MAX_SESSION_BYTES
        {
            state.session_full = true;
            return RecordOutcome {
                status: RecordStatus::SessionLimit,
                latest_failure_written,
            };
        }
        if state.queue.len() >= MAX_QUEUE_ROWS
            || state.queued_bytes.saturating_add(bytes.len()) > MAX_QUEUE_BYTES
        {
            return RecordOutcome {
                status: RecordStatus::QueueFull,
                latest_failure_written,
            };
        }

        state.queued_bytes += bytes.len();
        state.queue.push_back(bytes);
        let should_flush =
            state.queue.len() >= MAX_QUEUE_ROWS || state.queued_bytes >= MAX_QUEUE_BYTES;
        if should_flush && state.last_flush.elapsed() >= FLUSH_INTERVAL {
            match flush_queue(&mut state) {
                Ok(()) => RecordOutcome {
                    status: RecordStatus::Flushed,
                    latest_failure_written,
                },
                Err(()) => RecordOutcome {
                    status: RecordStatus::WriteFailed,
                    latest_failure_written,
                },
            }
        } else {
            RecordOutcome {
                status: RecordStatus::Buffered,
                latest_failure_written,
            }
        }
    }

    /// Flush and close the diagnostic stream. Safe to call more than once.
    pub(crate) fn close(&self) -> RecordStatus {
        let Some(state) = &self.state else {
            return RecordStatus::Disabled;
        };
        let Ok(mut state) = state.lock() else {
            return RecordStatus::Disabled;
        };
        if state.closed {
            return RecordStatus::Closed;
        }
        let result = flush_queue(&mut state);
        let _ = state.file.take();
        state.closed = true;
        if result.is_ok() {
            RecordStatus::Flushed
        } else {
            RecordStatus::WriteFailed
        }
    }
}

impl Drop for RecoveryDiagnostics {
    fn drop(&mut self) {
        if let Some(state) = &self.state {
            if let Ok(mut state) = state.lock() {
                if !state.closed {
                    let _ = flush_queue(&mut state);
                    let _ = state.file.take();
                    state.closed = true;
                }
            }
        }
    }
}

fn prepare_session(root: &Path) -> Option<State> {
    prepare_session_with_limits(root, RETENTION, MAX_DIRECTORY_ENTRIES)
}

fn prepare_session_with_limits(
    root: &Path,
    retention: RetentionPolicy,
    max_entries: usize,
) -> Option<State> {
    let (root, created_final) = ensure_directory_chain(root).ok()?;
    let marker = root.join("owner.marker");
    if created_final {
        let mut file = create_new_file(&marker).ok()?;
        file.write_all(OWNER_MARKER).ok()?;
        // This marker owns best-effort logs, never accounting or recovery
        // receipts. A lost/partial marker disables future logging/GC safely;
        // it must not force a startup fsync before the real ledger can open.
    }
    if !marker_has_exact_owner(&marker) {
        return None;
    }
    if !set_directory_permissions(&root) {
        return None;
    }

    collect_sessions(&root, retention, SystemTime::now(), max_entries).ok()?;
    let attempt = Uuid::new_v4().to_string();
    let header = SessionHeader {
        format: FORMAT.to_owned(),
        attempt: attempt.clone(),
    };
    let mut header_bytes = serde_json::to_vec(&header).ok()?;
    header_bytes.push(b'\n');
    if header_bytes.len() > MAX_HEADER_BYTES || header_bytes.len() as u64 > MAX_SESSION_BYTES {
        return None;
    }
    let session_path = root.join(format!("session-{attempt}.jsonl"));
    let mut file = create_new_file(&session_path).ok()?;
    file.write_all(&header_bytes).ok()?;
    Some(State {
        root,
        file: Some(file),
        queue: VecDeque::new(),
        queued_bytes: 0,
        file_bytes: header_bytes.len() as u64,
        last_flush: Instant::now(),
        closed: false,
        session_full: false,
        #[cfg(test)]
        fail_next_write: false,
    })
}

fn ensure_directory_chain(path: &Path) -> std::io::Result<(PathBuf, bool)> {
    if path.as_os_str().is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "empty diagnostics root",
        ));
    }
    if path
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "parent component rejected",
        ));
    }
    // Probe complete ancestors. Windows canonical paths can use a verbatim
    // prefix (`\\?\C:\...`); the bare prefix component is not a path to stat.
    let mut ancestors: Vec<_> = path
        .ancestors()
        .filter(|ancestor| !ancestor.as_os_str().is_empty())
        .collect();
    ancestors.reverse();
    if ancestors.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "diagnostics root has no filesystem ancestor",
        ));
    }
    let mut created_final = false;
    for (index, ancestor) in ancestors.iter().enumerate() {
        let is_last = index + 1 == ancestors.len();
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) => {
                if !metadata.is_dir() || is_link_or_reparse(&metadata) {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "unsafe diagnostics path component",
                    ));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match create_directory(ancestor) {
                    Ok(()) => {
                        if is_last {
                            created_final = true;
                        }
                    }
                    Err(create_error)
                        if create_error.kind() == std::io::ErrorKind::AlreadyExists =>
                    {
                        let metadata = fs::symlink_metadata(ancestor)?;
                        if !metadata.is_dir() || is_link_or_reparse(&metadata) {
                            return Err(std::io::Error::new(
                                std::io::ErrorKind::PermissionDenied,
                                "unsafe diagnostics path component",
                            ));
                        }
                    }
                    Err(create_error) => return Err(create_error),
                }
            }
            Err(error) => return Err(error),
        }
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || is_link_or_reparse(&metadata) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "unsafe diagnostics root",
        ));
    }
    Ok((path.to_path_buf(), created_final))
}

fn create_directory(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700).create(path)
    }
    #[cfg(not(unix))]
    {
        fs::create_dir(path)
    }
}

fn create_new_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).read(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || is_link_or_reparse(&metadata) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "created diagnostics item is not a regular file",
        ));
    }
    Ok(file)
}

fn open_existing_rw_nofollow(path: &Path) -> std::io::Result<File> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || is_link_or_reparse(&metadata) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "diagnostics item is not a regular file",
        ));
    }
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path)?;
    let opened = file.metadata()?;
    if !opened.is_file() || is_link_or_reparse(&opened) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "opened diagnostics item is not a regular file",
        ));
    }
    Ok(file)
}

fn open_existing_read_nofollow(path: &Path) -> std::io::Result<File> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || is_link_or_reparse(&metadata) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "diagnostics item is not a regular file",
        ));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path)?;
    let opened = file.metadata()?;
    if !opened.is_file() || is_link_or_reparse(&opened) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "opened diagnostics item is not a regular file",
        ));
    }
    Ok(file)
}

fn is_link_or_reparse(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    {
        false
    }
}

fn marker_has_exact_owner(marker: &Path) -> bool {
    let Ok(mut file) = open_existing_read_nofollow(marker) else {
        return false;
    };
    let mut bytes = Vec::with_capacity(OWNER_MARKER.len() + 1);
    if Read::by_ref(&mut file)
        .take((OWNER_MARKER.len() + 1) as u64)
        .read_to_end(&mut bytes)
        .is_err()
    {
        return false;
    }
    bytes == OWNER_MARKER && set_file_permissions(&file)
}

fn flush_queue(state: &mut State) -> Result<(), ()> {
    state.last_flush = Instant::now();
    if state.queue.is_empty() {
        return Ok(());
    }
    #[cfg(test)]
    if state.fail_next_write {
        state.fail_next_write = false;
        state.file.take();
        state.queue.clear();
        state.queued_bytes = 0;
        return Err(());
    }
    let Some(file) = state.file.as_mut() else {
        state.queue.clear();
        state.queued_bytes = 0;
        return Err(());
    };
    let mut batch = Vec::with_capacity(state.queued_bytes);
    for row in &state.queue {
        batch.extend_from_slice(row);
    }
    if file.write_all(&batch).is_err() {
        state.file.take();
        state.queue.clear();
        state.queued_bytes = 0;
        return Err(());
    }
    state.file_bytes = state.file_bytes.saturating_add(batch.len() as u64);
    state.queue.clear();
    state.queued_bytes = 0;
    Ok(())
}

fn collect_sessions(
    root: &Path,
    policy: RetentionPolicy,
    now: SystemTime,
    max_entries: usize,
) -> std::io::Result<()> {
    if !marker_has_exact_owner(&root.join("owner.marker")) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "diagnostics ownership changed during cleanup",
        ));
    }
    let mut sessions = Vec::new();
    let entries = fs::read_dir(root)?;
    for (index, entry) in entries.enumerate() {
        if index >= max_entries {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "diagnostics directory entry budget exceeded",
            ));
        }
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(attempt) = strict_session_filename(name) else {
            continue;
        };
        let path = entry.path();
        let Some((metadata, identity)) = owned_session_snapshot(&path, &attempt) else {
            continue;
        };
        let modified = metadata.modified().unwrap_or(UNIX_EPOCH);
        sessions.push(SessionForGc {
            path,
            attempt,
            bytes: metadata.len(),
            modified,
            identity,
        });
    }

    let mut remove = Vec::new();
    for session in &sessions {
        if now.duration_since(session.modified).unwrap_or_default() > policy.max_age
            || session.bytes > policy.max_session_bytes
        {
            remove.push(session.attempt.clone());
        }
    }
    let mut retained_bytes: u64 = sessions
        .iter()
        .filter(|session| !remove.contains(&session.attempt))
        .map(|session| session.bytes)
        .fold(0, u64::saturating_add);
    if retained_bytes > policy.max_total_bytes {
        let mut by_oldest: Vec<_> = sessions
            .iter()
            .filter(|session| !remove.contains(&session.attempt))
            .collect();
        by_oldest.sort_by_key(|session| session.modified);
        for session in by_oldest {
            if retained_bytes <= policy.max_total_bytes {
                break;
            }
            remove.push(session.attempt.clone());
            retained_bytes = retained_bytes.saturating_sub(session.bytes);
        }
    }
    for session in sessions {
        if remove.contains(&session.attempt) {
            if !marker_has_exact_owner(&root.join("owner.marker")) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "diagnostics ownership changed during cleanup",
                ));
            }
            let current = owned_session_snapshot(&session.path, &session.attempt);
            if let Some((_, identity)) = current {
                if identity != session.identity {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::Other,
                        "owned diagnostics session changed during cleanup",
                    ));
                }
                match fs::remove_file(&session.path) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error),
                }
            }
        }
    }
    Ok(())
}

struct SessionForGc {
    path: PathBuf,
    attempt: String,
    bytes: u64,
    modified: SystemTime,
    identity: FileIdentity,
}

fn strict_session_filename(name: &str) -> Option<String> {
    let attempt = name.strip_prefix("session-")?.strip_suffix(".jsonl")?;
    let parsed = Uuid::parse_str(attempt).ok()?;
    (parsed.to_string() == attempt).then(|| attempt.to_owned())
}

fn owned_session_snapshot(
    path: &Path,
    expected_attempt: &str,
) -> Option<(fs::Metadata, FileIdentity)> {
    let Ok(mut file) = open_existing_read_nofollow(path) else {
        return None;
    };
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || is_link_or_reparse(&metadata) {
        return None;
    }
    let mut line = Vec::new();
    let limit = MAX_HEADER_BYTES as u64 + 1;
    let read = BufReader::new(&mut file)
        .take(limit)
        .read_until(b'\n', &mut line);
    if read.is_err() || line.len() > MAX_HEADER_BYTES || line.last() != Some(&b'\n') {
        return None;
    }
    let Ok(header) = serde_json::from_slice::<SessionHeader>(&line[..line.len() - 1]) else {
        return None;
    };
    if header.format != FORMAT || header.attempt != expected_attempt {
        return None;
    }
    Some((metadata, file_identity(&file).ok()?))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FileIdentity {
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(windows)]
    volume: u32,
    #[cfg(windows)]
    file_id: u64,
    #[cfg(not(any(unix, windows)))]
    length: u64,
    #[cfg(not(any(unix, windows)))]
    modified: Option<SystemTime>,
}

#[cfg(unix)]
fn file_identity(file: &File) -> std::io::Result<FileIdentity> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata()?;
    Ok(FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

#[cfg(windows)]
fn file_identity(file: &File) -> std::io::Result<FileIdentity> {
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
    Ok(FileIdentity {
        volume: information.volume_serial_number,
        file_id: (u64::from(information.file_index_high) << 32)
            | u64::from(information.file_index_low),
    })
}

#[cfg(not(any(unix, windows)))]
fn file_identity(file: &File) -> std::io::Result<FileIdentity> {
    let metadata = file.metadata()?;
    Ok(FileIdentity {
        length: metadata.len(),
        modified: metadata.modified().ok(),
    })
}

fn write_latest_failure(
    root: &Path,
    phase: Phase,
    completed: u64,
    total: u64,
    retry_count: u64,
    code: Option<i32>,
) -> bool {
    if phase != Phase::Failure || !marker_has_exact_owner(&root.join("owner.marker")) {
        return false;
    }
    let latest = LatestFailure {
        format: FORMAT.to_owned(),
        event: DiagnosticRecord {
            phase,
            at: unix_now_fractional(),
            completed: completed.min(i64::MAX as u64),
            total: total.min(i64::MAX as u64),
            retry_count: retry_count.min(i64::MAX as u64),
            code,
        },
    };
    let Ok(mut bytes) = serde_json::to_vec(&latest) else {
        return false;
    };
    bytes.push(b'\n');
    if bytes.len() > MAX_LATEST_FAILURE_BYTES {
        return false;
    }
    let path = root.join("latest-failure.json");
    match create_new_file(&path) {
        Ok(mut file) => {
            set_file_permissions(&file);
            file.write_all(&bytes).is_ok()
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let Ok(mut file) = open_existing_rw_nofollow(&path) else {
                return false;
            };
            let Ok(metadata) = file.metadata() else {
                return false;
            };
            if metadata.len() > MAX_LATEST_FAILURE_BYTES as u64 {
                return false;
            }
            let mut current = Vec::with_capacity(metadata.len() as usize);
            if file.seek(SeekFrom::Start(0)).is_err()
                || file.read_to_end(&mut current).is_err()
                || !valid_latest_failure(&current)
            {
                return false;
            }
            if file.set_len(0).is_err()
                || file.seek(SeekFrom::Start(0)).is_err()
                || file.write_all(&bytes).is_err()
            {
                return false;
            }
            set_file_permissions(&file);
            true
        }
        Err(_) => false,
    }
}

fn valid_latest_failure(bytes: &[u8]) -> bool {
    let Ok(failure) = serde_json::from_slice::<LatestFailure>(bytes) else {
        return false;
    };
    failure.format == FORMAT && failure.event.phase == Phase::Failure
}

fn session_root(state: &State) -> &Path {
    &state.root
}

fn state_root_for_failure(state: &State) -> &Path {
    &state.root
}

fn set_file_permissions(file: &File) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .is_ok()
    }
    #[cfg(not(unix))]
    {
        let _ = file;
        true
    }
}

fn set_directory_permissions(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).is_ok()
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        true
    }
}

fn unix_now_fractional() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::business_store_container::{Container, StoreSpec};
    use rusqlite::{params, Connection};
    use std::{fs, time::Duration};
    use tempfile::tempdir;

    fn create_owned_session(root: &Path, bytes: usize) -> String {
        let attempt = Uuid::new_v4().to_string();
        let path = root.join(format!("session-{attempt}.jsonl"));
        let header = SessionHeader {
            format: FORMAT.to_owned(),
            attempt: attempt.clone(),
        };
        let mut contents = serde_json::to_vec(&header).unwrap();
        contents.push(b'\n');
        contents.resize(bytes.max(contents.len()), b'x');
        fs::write(&path, contents).unwrap();
        attempt
    }

    #[test]
    fn start_buffers_and_close_flushes_a_bound_session() {
        let temp = tempdir().unwrap();
        let root = temp
            .path()
            .canonicalize()
            .unwrap()
            .join("support/recovery-diagnostics/v1");
        let diagnostics = RecoveryDiagnostics::start(&root);
        let result = diagnostics.record(Phase::Importing, 3, 9, 1, Some(17));
        assert_eq!(result.status, RecordStatus::Buffered);
        assert_eq!(diagnostics.close(), RecordStatus::Flushed);

        let marker = fs::read(root.join("owner.marker")).unwrap();
        assert_eq!(marker, OWNER_MARKER);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&root).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(root.join("owner.marker"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        let mut sessions: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("session-")
            })
            .collect();
        assert_eq!(sessions.len(), 1);
        let session = sessions.pop().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&session).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let filename = session.file_name().unwrap().to_string_lossy();
        let attempt = strict_session_filename(&filename).unwrap();
        let content = fs::read_to_string(session).unwrap();
        let mut lines = content.lines();
        let header: SessionHeader = serde_json::from_str(lines.next().unwrap()).unwrap();
        assert_eq!(header.format, FORMAT);
        assert_eq!(header.attempt, attempt);
        let row: DiagnosticRecord = serde_json::from_str(lines.next().unwrap()).unwrap();
        assert_eq!(row.phase, Phase::Importing);
        assert_eq!(
            (row.completed, row.total, row.retry_count, row.code),
            (3, 9, 1, Some(17))
        );
        assert!(lines.next().is_none());
    }

    #[test]
    fn cleanup_removes_expired_and_oldest_over_capacity_only() {
        let temp = tempdir().unwrap();
        let root = temp.path();
        fs::write(root.join("owner.marker"), OWNER_MARKER).unwrap();
        let expired = create_owned_session(root, 128);
        let older = create_owned_session(root, 200);
        let newer = create_owned_session(root, 200);
        let protected_latest = root.join("latest-failure.json");
        fs::write(&protected_latest, b"unknown but protected").unwrap();
        let expiration_policy = RetentionPolicy {
            max_age: Duration::ZERO,
            max_total_bytes: u64::MAX,
            max_session_bytes: 1_000,
        };
        collect_sessions(
            root,
            expiration_policy,
            SystemTime::now() + Duration::from_secs(1),
            MAX_DIRECTORY_ENTRIES,
        )
        .unwrap();
        assert!(!root.join(format!("session-{expired}.jsonl")).exists());
        assert!(!root.join(format!("session-{older}.jsonl")).exists());
        assert!(!root.join(format!("session-{newer}.jsonl")).exists());
        let older = create_owned_session(root, 200);
        let newer = create_owned_session(root, 200);
        let capacity_policy = RetentionPolicy {
            max_age: Duration::from_secs(100),
            max_total_bytes: 250,
            max_session_bytes: 1_000,
        };
        collect_sessions(
            root,
            capacity_policy,
            SystemTime::now(),
            MAX_DIRECTORY_ENTRIES,
        )
        .unwrap();
        let older_exists = root.join(format!("session-{older}.jsonl")).exists();
        let newer_exists = root.join(format!("session-{newer}.jsonl")).exists();
        assert_ne!(older_exists, newer_exists);
        assert_eq!(
            fs::read(protected_latest).unwrap(),
            b"unknown but protected"
        );
    }

    #[test]
    fn unknown_entries_and_unowned_sessions_survive_cleanup() {
        let temp = tempdir().unwrap();
        let root = temp.path();
        fs::write(root.join("owner.marker"), OWNER_MARKER).unwrap();
        let unknown = root.join("notes.txt");
        fs::write(&unknown, b"leave me alone").unwrap();
        let directory = root.join("child");
        fs::create_dir(&directory).unwrap();
        let malformed_attempt = Uuid::new_v4().to_string();
        let malformed = root.join(format!("session-{malformed_attempt}.jsonl"));
        fs::write(&malformed, b"{\"format\":\"other\",\"attempt\":\"x\"}\n").unwrap();
        let policy = RetentionPolicy {
            max_age: Duration::ZERO,
            max_total_bytes: 0,
            max_session_bytes: 0,
        };
        collect_sessions(root, policy, SystemTime::now(), MAX_DIRECTORY_ENTRIES).unwrap();
        assert_eq!(fs::read(unknown).unwrap(), b"leave me alone");
        assert!(directory.is_dir());
        assert!(malformed.exists());
    }

    #[test]
    fn existing_unmarked_directory_is_not_adopted_or_modified() {
        let temp = tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("diagnostics");
        fs::create_dir(&root).unwrap();
        let unknown = root.join("notes.txt");
        fs::write(&unknown, b"unowned").unwrap();
        let diagnostics = RecoveryDiagnostics::start(&root);
        assert_eq!(
            diagnostics.record(Phase::Preparing, 0, 1, 0, None).status,
            RecordStatus::Disabled
        );
        assert!(!root.join("owner.marker").exists());
        assert_eq!(fs::read(unknown).unwrap(), b"unowned");
    }

    #[test]
    fn gc_budget_failure_disables_start_without_creating_a_session() {
        let temp = tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("diagnostics");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("owner.marker"), OWNER_MARKER).unwrap();

        let state = prepare_session_with_limits(&root, RETENTION, 0);
        assert!(state.is_none());
        let entries: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.file_name())
            .collect();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0], "owner.marker");
    }

    #[test]
    fn diagnostic_record_and_close_do_not_replace_business_result() {
        let temp = tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("unowned");
        fs::create_dir(&root).unwrap();
        let diagnostics = RecoveryDiagnostics::start(&root);
        let business_result: Result<u64, &'static str> = Err("recovery result");

        assert_eq!(
            diagnostics.record(Phase::Failure, 2, 5, 1, Some(-2)).status,
            RecordStatus::Disabled
        );
        assert_eq!(diagnostics.close(), RecordStatus::Disabled);
        assert_eq!(business_result, Err("recovery result"));
    }

    #[cfg(windows)]
    #[test]
    fn canonical_windows_temp_path_walks_complete_ancestors() {
        let temp = tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("chain-probe/leaf");
        let (ensured, created_final) = ensure_directory_chain(&root).unwrap();
        assert_eq!(ensured, root);
        assert!(created_final);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_session_and_target_survive_cleanup() {
        use std::os::unix::fs::symlink;
        let temp = tempdir().unwrap();
        let root = temp.path();
        fs::write(root.join("owner.marker"), OWNER_MARKER).unwrap();
        let target = root.join("target.jsonl");
        fs::write(&target, b"valuable").unwrap();
        let attempt = Uuid::new_v4().to_string();
        let link = root.join(format!("session-{attempt}.jsonl"));
        symlink(&target, &link).unwrap();
        let policy = RetentionPolicy {
            max_age: Duration::ZERO,
            max_total_bytes: 0,
            max_session_bytes: 0,
        };
        collect_sessions(root, policy, SystemTime::now(), MAX_DIRECTORY_ENTRIES).unwrap();
        assert!(fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(fs::read(target).unwrap(), b"valuable");
    }

    #[test]
    fn disk_failure_and_full_queue_return_status_without_panicking() {
        let temp = tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("diagnostics");
        let diagnostics = RecoveryDiagnostics::start(&root);
        diagnostics
            .state
            .as_ref()
            .unwrap()
            .lock()
            .unwrap()
            .last_flush = Instant::now() + Duration::from_secs(60);
        for _ in 0..MAX_QUEUE_ROWS {
            assert_eq!(
                diagnostics.record(Phase::Verifying, 1, 2, 0, None).status,
                RecordStatus::Buffered
            );
        }
        assert_eq!(
            diagnostics.record(Phase::Verifying, 1, 2, 0, None).status,
            RecordStatus::QueueFull
        );
        {
            let mut state = diagnostics.state.as_ref().unwrap().lock().unwrap();
            state.fail_next_write = true;
            state.last_flush = Instant::now() - FLUSH_INTERVAL;
        }
        assert_eq!(
            diagnostics.record(Phase::Preparing, 0, 1, 0, None).status,
            RecordStatus::WriteFailed
        );
    }

    #[test]
    fn failure_summary_is_small_and_not_removed_by_session_gc() {
        let temp = tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("diagnostics");
        let diagnostics = RecoveryDiagnostics::start(&root);
        let outcome = diagnostics.record(Phase::Failure, 4, 8, 2, Some(-7));
        assert_eq!(outcome.latest_failure_written, Some(true));
        let latest = root.join("latest-failure.json");
        assert!(fs::metadata(&latest).unwrap().len() <= MAX_LATEST_FAILURE_BYTES as u64);
        let policy = RetentionPolicy {
            max_age: Duration::ZERO,
            max_total_bytes: 0,
            max_session_bytes: 0,
        };
        collect_sessions(&root, policy, SystemTime::now(), MAX_DIRECTORY_ENTRIES).unwrap();
        assert!(latest.exists());
        let summary: LatestFailure = serde_json::from_slice(&fs::read(latest).unwrap()).unwrap();
        assert_eq!(summary.format, FORMAT);
        assert_eq!(summary.event.phase, Phase::Failure);
        assert_eq!(summary.event.code, Some(-7));
    }

    #[test]
    fn diagnostics_modes_never_change_managed_legacy_import_or_later_target_rows() {
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        enum Mode {
            Disabled,
            Enabled,
            UnknownDirectory,
            InjectedWriteFailure,
        }

        for mode in [
            Mode::Disabled,
            Mode::Enabled,
            Mode::UnknownDirectory,
            Mode::InjectedWriteFailure,
        ] {
            let temp = tempdir().unwrap();
            let root = temp.path().canonicalize().unwrap();
            let source_path = root.join("old-quota.sqlite");
            let snapshot_path = root.join("old-quota-frozen.sqlite");
            let container_path = root.join("business-a.sqlite");
            let retention_backup = root.join("retention-backup.sqlite");

            {
                let old = Connection::open(&source_path).unwrap();
                old.execute_batch(
                    "PRAGMA user_version=9;
                     CREATE TABLE quota_snapshots(
                         id INTEGER PRIMARY KEY,
                         account_key TEXT NOT NULL,
                         used REAL NOT NULL,
                         payload BLOB NOT NULL,
                         nullable_note TEXT
                     );
                     INSERT INTO quota_snapshots VALUES(1,'legacy-account',10.25,x'00ff',NULL);
                     CREATE TABLE quota_history_legacy_claims(name TEXT PRIMARY KEY,owner TEXT NOT NULL);
                     INSERT INTO quota_history_legacy_claims VALUES('display','legacy-account');
                     CREATE TABLE quota_history_maintenance(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                     INSERT INTO quota_history_maintenance VALUES('policy_version','3'),('last_compacted_at','100');",
                )
                .unwrap();
            }
            Container::backup_snapshot(&source_path, &snapshot_path).unwrap();
            let source_bytes = fs::read(&source_path).unwrap();
            let snapshot_bytes = fs::read(&snapshot_path).unwrap();
            let source_proof = Container::snapshot_proof_path(&snapshot_path).unwrap();
            assert_eq!(source_proof.module_user_version, 9, "{mode:?}");
            assert_eq!(source_proof.table_counts.get("quota_snapshots"), Some(&1), "{mode:?}");

            let source_identity = format!("recovery-diagnostics-{mode:?}");
            let logical_path = format!("quota/history/recovery-diagnostics-{mode:?}");
            let store = StoreSpec::new("quota_history_legacy", source_identity, logical_path).unwrap();
            let mut container = Container::open(&container_path).unwrap();
            let diagnostics_root = root.join("support/recovery-diagnostics/v1");
            let (diagnostics, blocked_path, unknown_note) = match mode {
                Mode::Disabled => {
                    let blocked = root.join("diagnostics-parent-is-a-file");
                    fs::write(&blocked, b"keep obstruction").unwrap();
                    (RecoveryDiagnostics::start(&blocked.join("v1")), Some(blocked), None)
                }
                Mode::Enabled | Mode::InjectedWriteFailure => {
                    (RecoveryDiagnostics::start(&diagnostics_root), None, None)
                }
                Mode::UnknownDirectory => {
                    fs::create_dir_all(&diagnostics_root).unwrap();
                    let note = diagnostics_root.join("owner-notes.txt");
                    fs::write(&note, b"unowned diagnostics data").unwrap();
                    (RecoveryDiagnostics::start(&diagnostics_root), None, Some(note))
                }
            };

            let preparing = diagnostics.record(Phase::Preparing, 0, 1, 0, None);
            match mode {
                Mode::Disabled | Mode::UnknownDirectory => {
                    assert_eq!(preparing.status, RecordStatus::Disabled, "{mode:?}");
                }
                Mode::Enabled | Mode::InjectedWriteFailure => {
                    assert!(
                        matches!(preparing.status, RecordStatus::Buffered | RecordStatus::Flushed),
                        "{mode:?}: {:?}",
                        preparing.status
                    );
                }
            }
            if mode == Mode::InjectedWriteFailure {
                let state = diagnostics.state.as_ref().unwrap();
                let mut state = state.lock().unwrap();
                state.fail_next_write = true;
                state.last_flush = Instant::now() - FLUSH_INTERVAL;
            }
            let importing = diagnostics.record(Phase::Importing, 0, 1, 0, None);
            match mode {
                Mode::Disabled | Mode::UnknownDirectory => {
                    assert_eq!(importing.status, RecordStatus::Disabled, "{mode:?}");
                }
                Mode::Enabled => {
                    assert!(
                        matches!(importing.status, RecordStatus::Buffered | RecordStatus::Flushed),
                        "{mode:?}: {:?}",
                        importing.status
                    );
                }
                Mode::InjectedWriteFailure => {
                    assert_eq!(importing.status, RecordStatus::WriteFailed, "{mode:?}");
                }
            }

            let imported = container
                .import_legacy_snapshot(
                    &snapshot_path,
                    &store,
                    &source_path,
                    &retention_backup,
                    1.0,
                    false,
                )
                .unwrap()
                .expect("the original legacy source should be imported");
            assert_eq!(imported, source_proof, "typed source proof differs: {mode:?}");
            assert_eq!(container.proof(&store).unwrap(), imported, "{mode:?}");
            let receipt = container.legacy_input_receipt(&source_path).unwrap().unwrap();
            assert_eq!(receipt.store_id, store.id, "{mode:?}");
            assert!(!receipt.retired, "{mode:?}");
            assert_eq!(
                receipt.source_digest,
                format!("{}:{}", source_proof.schema_digest, source_proof.rows_digest),
                "{mode:?}"
            );

            let target = container.into_store_connection(&store).unwrap();
            target
                .execute(
                    "INSERT INTO quota_snapshots(id,account_key,used,payload,nullable_note)
                     VALUES(2,'target-only-account',12.5,x'0001ff',NULL)",
                    params![],
                )
                .unwrap();
            drop(target);

            let reopened = Container::open_existing(&container_path).unwrap();
            let expanded_proof = reopened.proof(&store).unwrap();
            assert_eq!(expanded_proof.row_count, imported.row_count + 1, "{mode:?}");
            assert_eq!(
                expanded_proof.table_counts.get("quota_snapshots"),
                Some(&2),
                "{mode:?}"
            );
            let target = reopened.into_store_connection(&store).unwrap();
            let row: (String, f64, Vec<u8>) = target
                .query_row(
                    "SELECT account_key,used,payload FROM quota_snapshots WHERE id=2",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .unwrap();
            assert_eq!(row, ("target-only-account".into(), 12.5, vec![0, 1, 255]), "{mode:?}");

            assert_eq!(Container::snapshot_proof_path(&snapshot_path).unwrap(), source_proof, "{mode:?}");
            assert_eq!(fs::read(&source_path).unwrap(), source_bytes, "old source changed: {mode:?}");
            assert_eq!(fs::read(&snapshot_path).unwrap(), snapshot_bytes, "snapshot changed: {mode:?}");

            let ready = diagnostics.record(Phase::Ready, 1, 1, 0, None);
            if matches!(mode, Mode::Disabled | Mode::UnknownDirectory) {
                assert_eq!(ready.status, RecordStatus::Disabled, "{mode:?}");
            }
            match mode {
                Mode::Enabled => assert_eq!(diagnostics.close(), RecordStatus::Flushed),
                Mode::Disabled | Mode::UnknownDirectory => {
                    assert_eq!(diagnostics.close(), RecordStatus::Disabled);
                }
                Mode::InjectedWriteFailure => {
                    assert_eq!(ready.status, RecordStatus::WriteFailed, "{mode:?}");
                }
            }
            if let Some(blocked) = blocked_path {
                assert_eq!(fs::read(blocked).unwrap(), b"keep obstruction");
            }
            if let Some(note) = unknown_note {
                assert!(!diagnostics_root.join("owner.marker").exists());
                assert_eq!(fs::read(note).unwrap(), b"unowned diagnostics data");
            }
        }
    }

    #[test]
    fn diagnostics_import_overhead_profile_is_opt_in_and_keeps_five_percent_budget() {
        if std::env::var("TOKENBAR_DIAGNOSTIC_PROFILE").as_deref() != Ok("1") {
            return;
        }

        fn import_sample(with_diagnostics: bool, sample: usize, payload: &[u8]) -> Duration {
            let temp = tempdir().unwrap();
            let root = temp.path().canonicalize().unwrap();
            let source_path = root.join("legacy.sqlite");
            let snapshot_path = root.join("frozen.sqlite");
            let container_path = root.join("business-a.sqlite");
            {
                let source = Connection::open(&source_path).unwrap();
                source.execute_batch(
                    "PRAGMA user_version=9;
                     CREATE TABLE quota_snapshots(
                         id INTEGER PRIMARY KEY,
                         account_key TEXT NOT NULL,
                         used REAL NOT NULL,
                         payload BLOB NOT NULL
                     );",
                ).unwrap();
                source.execute(
                    "INSERT INTO quota_snapshots VALUES(1,'profile-account',20.5,?1)",
                    [payload],
                ).unwrap();
            }
            Container::backup_snapshot(&source_path, &snapshot_path).unwrap();
            let source_proof = Container::snapshot_proof_path(&snapshot_path).unwrap();
            let source_bytes = fs::read(&source_path).unwrap();
            let store = StoreSpec::new(
                "quota_history_legacy",
                format!("diagnostic-profile-{sample}-{with_diagnostics}"),
                format!("quota/history/diagnostic-profile/{sample}/{with_diagnostics}"),
            ).unwrap();
            let mut container = Container::open(&container_path).unwrap();

            let started = Instant::now();
            let diagnostics = with_diagnostics.then(|| {
                let diagnostics = RecoveryDiagnostics::start(&root.join("support/recovery-diagnostics/v1"));
                assert!(diagnostics.state.is_some(), "diagnostics profile could not start");
                for phase in [Phase::Preparing, Phase::Importing] {
                    let outcome = diagnostics.record(phase, 0, 1, 0, None);
                    assert!(matches!(outcome.status, RecordStatus::Buffered | RecordStatus::Flushed));
                }
                diagnostics
            });
            let imported = container.import_legacy_snapshot(
                &snapshot_path,
                &store,
                &source_path,
                &snapshot_path,
                1.0,
                false,
            ).unwrap().unwrap();
            if let Some(diagnostics) = diagnostics {
                assert!(matches!(
                    diagnostics.record(Phase::Ready, 1, 1, 0, None).status,
                    RecordStatus::Buffered | RecordStatus::Flushed
                ));
                assert_eq!(diagnostics.close(), RecordStatus::Flushed);
            }
            let elapsed = started.elapsed();
            assert_eq!(imported, source_proof);
            assert_eq!(fs::read(&source_path).unwrap(), source_bytes);
            elapsed
        }

        let payload = vec![0xA5; 512 * 1024];
        let mut with = Vec::with_capacity(7);
        let mut without = Vec::with_capacity(7);
        for sample in 0..7 {
            if sample % 2 == 0 {
                with.push(import_sample(true, sample, &payload).as_secs_f64());
                without.push(import_sample(false, sample, &payload).as_secs_f64());
            } else {
                without.push(import_sample(false, sample, &payload).as_secs_f64());
                with.push(import_sample(true, sample, &payload).as_secs_f64());
            }
        }
        let median = |values: &mut [f64]| {
            values.sort_by(f64::total_cmp);
            values[values.len() / 2]
        };
        let with_median = median(&mut with);
        let without_median = median(&mut without);
        let overhead_percent = if without_median > 0.0 {
            (with_median / without_median - 1.0) * 100.0
        } else {
            f64::INFINITY
        };
        println!(
            "TOKENBAR_DIAGNOSTIC_PROFILE {}",
            serde_json::json!({
                "format": "tokenbar-recovery-diagnostic-import-profile-v1",
                "samplesPerMode": 7,
                "payloadBytes": payload.len(),
                "withDiagnosticsMedianSeconds": with_median,
                "withoutDiagnosticsMedianSeconds": without_median,
                "medianOverheadPercent": overhead_percent,
                "budgetPercent": 5.0,
            })
        );
        assert!(
            overhead_percent <= 5.0,
            "diagnostic import overhead {overhead_percent:.2}% exceeds the 5% budget"
        );
    }
}
