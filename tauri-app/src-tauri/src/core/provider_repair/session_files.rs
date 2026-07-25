use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(windows)]
use super::safe_fs::windows_extended_length_path;
use super::safe_fs::{AtomicInstallPhase, PinnedHome};

const ATOMIC_TEMP_ATTEMPTS: usize = 64;
static ATOMIC_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SessionRewritePhase {
    BeforeTempCreate,
    BeforeReplace,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AtomicWritePhase {
    BeforeReplace,
    AfterDestinationExists,
    CleanupTemp,
    AfterCleanupIdentityCheck,
    BeforeHandleDelete,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum AtomicFileIdentity {
    #[cfg(unix)]
    Unix { device: u64, inode: u64 },
    #[cfg(windows)]
    Windows {
        volume_serial_number: u64,
        file_id: [u8; 16],
    },
}

pub(super) struct SessionScan {
    pub(super) files_found: u32,
    pub(super) provider_counts: HashMap<String, u32>,
    pub(super) invalid_files: u32,
    pub(super) newest_provider: Option<String>,
    pub(super) records: Vec<SessionProviderRecord>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct SessionProviderRecord {
    pub(super) file: PathBuf,
    pub(super) thread_id: String,
    pub(super) provider: String,
}

impl SessionScan {
    pub(super) fn count_provider_mismatches(&self, target_provider: &str) -> u32 {
        self.provider_counts
            .iter()
            .filter(|(provider, _)| provider.as_str() != target_provider)
            .map(|(_, count)| *count)
            .sum()
    }

    pub(super) fn canonical_thread_providers(&self) -> HashMap<String, String> {
        let mut providers = HashMap::<String, Option<String>>::new();
        for record in &self.records {
            if record.provider.trim().is_empty() || record.provider == "(missing)" {
                continue;
            }
            providers
                .entry(record.thread_id.clone())
                .and_modify(|current| {
                    if current.as_deref() != Some(record.provider.as_str()) {
                        *current = None;
                    }
                })
                .or_insert_with(|| Some(record.provider.clone()));
        }
        providers
            .into_iter()
            .filter_map(|(thread_id, provider)| provider.map(|provider| (thread_id, provider)))
            .collect()
    }

    pub(super) fn ambiguous_thread_count(&self) -> u32 {
        let mut providers = HashMap::<&str, &str>::new();
        let mut ambiguous = HashSet::new();
        for record in &self.records {
            if let Some(previous) =
                providers.insert(record.thread_id.as_str(), record.provider.as_str())
            {
                if previous != record.provider {
                    ambiguous.insert(record.thread_id.as_str());
                }
            }
        }
        u32::try_from(ambiguous.len()).unwrap_or(u32::MAX)
    }
}

pub(super) fn find_session_files(
    codex_home: &Path,
    include_archived: bool,
) -> Result<Vec<PathBuf>, String> {
    let canonical_home = codex_home
        .canonicalize()
        .map_err(|error| format!("无法确认 Codex Home {}：{error}", codex_home.display()))?;
    let mut roots = vec![codex_home.join("sessions")];
    if include_archived {
        roots.push(codex_home.join("archived_sessions"));
    }
    let mut files = Vec::new();
    let mut visited = HashSet::new();
    for root in roots {
        collect_jsonl_files(&canonical_home, &root, &mut files, &mut visited)?;
    }
    files.sort();
    Ok(files)
}

pub(super) fn collect_jsonl_files(
    canonical_root: &Path,
    path: &Path,
    files: &mut Vec<PathBuf>,
    visited: &mut HashSet<PathBuf>,
) -> Result<(), String> {
    let mut pending = vec![path.to_path_buf()];
    while let Some(next) = pending.pop() {
        let metadata = match fs::symlink_metadata(&next) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(format!("读取会话路径失败 {}：{error}", next.display()))
            }
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        let canonical_path = next
            .canonicalize()
            .map_err(|error| format!("无法确认会话路径 {}：{error}", next.display()))?;
        if !canonical_path.starts_with(canonical_root) {
            continue;
        }
        if metadata.is_file() {
            if canonical_path
                .extension()
                .is_some_and(|extension| extension == "jsonl")
            {
                files.push(canonical_path);
            }
            continue;
        }
        if !metadata.is_dir() || !visited.insert(canonical_path) {
            continue;
        }
        let entries = fs::read_dir(&next)
            .map_err(|error| format!("读取会话目录失败 {}：{error}", next.display()))?;
        for entry in entries {
            pending.push(
                entry
                    .map_err(|error| format!("读取会话目录项失败：{error}"))?
                    .path(),
            );
        }
    }
    Ok(())
}

pub(super) fn scan_session_providers(files: &[PathBuf]) -> SessionScan {
    let mut provider_counts = HashMap::<String, u32>::new();
    let mut invalid_files = 0;
    let mut newest_provider = None;
    let mut newest_modified = None;
    let mut records = Vec::new();

    for file in files {
        match read_session_provider(file) {
            Ok(Some(record)) => {
                *provider_counts.entry(record.provider.clone()).or_insert(0) += 1;
                let modified = fs::metadata(file)
                    .and_then(|metadata| metadata.modified())
                    .ok();
                if newest_modified.is_none_or(|current| modified.is_some_and(|next| next > current))
                {
                    newest_modified = modified;
                    newest_provider = Some(record.provider.clone());
                }
                records.push(record);
            }
            Ok(None) | Err(_) => invalid_files += 1,
        }
    }

    SessionScan {
        files_found: u32::try_from(files.len()).unwrap_or(u32::MAX),
        provider_counts,
        invalid_files,
        newest_provider,
        records,
    }
}

#[cfg(test)]
pub(super) fn rewrite_session_provider(
    canonical_home: &Path,
    file: &Path,
    target_provider: &str,
) -> Result<bool, String> {
    let pinned_home = PinnedHome::open(canonical_home)?;
    rewrite_session_provider_in(&pinned_home, file, target_provider, |_, _| Ok(()))
}

#[cfg(test)]
pub(super) fn rewrite_session_provider_with_hook(
    canonical_home: &Path,
    file: &Path,
    target_provider: &str,
    hook: impl FnMut(SessionRewritePhase, &Path) -> Result<(), String>,
) -> Result<bool, String> {
    let pinned_home = PinnedHome::open(canonical_home)?;
    rewrite_session_provider_in(&pinned_home, file, target_provider, hook)
}

pub(super) fn rewrite_session_provider_in(
    pinned_home: &PinnedHome,
    file: &Path,
    target_provider: &str,
    hook: impl FnMut(SessionRewritePhase, &Path) -> Result<(), String>,
) -> Result<bool, String> {
    let canonical_file = file.canonicalize().map_err(|error| error.to_string())?;
    let relative = canonical_file
        .strip_prefix(pinned_home.canonical_path())
        .map_err(|_| {
            format!(
                "拒绝改写 Codex Home 外的会话文件：{}",
                canonical_file.display()
            )
        })?;
    rewrite_session_provider_relative_in(pinned_home, relative, target_provider, hook)
}

pub(super) fn rewrite_session_provider_relative_in(
    pinned_home: &PinnedHome,
    relative: &Path,
    target_provider: &str,
    mut hook: impl FnMut(SessionRewritePhase, &Path) -> Result<(), String>,
) -> Result<bool, String> {
    let display_path = pinned_home.canonical_path().join(relative);
    pinned_home.transform_first_line_atomically(
        relative,
        |first_line_bytes| {
            let (json_bytes, separator) = split_first_line(first_line_bytes);
            let text = std::str::from_utf8(json_bytes).map_err(|error| {
                format!("会话文件不是有效 UTF-8 {}：{error}", display_path.display())
            })?;
            let mut value: Value = serde_json::from_str(text)
                .map_err(|error| format!("{}: {error}", display_path.display()))?;
            if value.get("type").and_then(Value::as_str) != Some("session_meta") {
                return Ok(None);
            }
            let payload = value
                .get_mut("payload")
                .and_then(Value::as_object_mut)
                .ok_or_else(|| format!("{} 缺少 session_meta.payload", display_path.display()))?;
            let thread_id = payload
                .get("id")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| format!("{} 缺少 session_meta.payload.id", display_path.display()))?;
            validate_rollout_thread_identity(relative, thread_id)?;
            if payload.get("model_provider").and_then(Value::as_str) == Some(target_provider) {
                return Ok(None);
            }
            payload.insert(
                "model_provider".into(),
                Value::String(target_provider.into()),
            );
            let mut replacement =
                serde_json::to_vec(&value).map_err(|error| error.to_string())?;
            replacement.extend_from_slice(separator);
            Ok(Some(replacement))
        },
        |phase, path| match phase {
            AtomicInstallPhase::BeforeTempCreate => {
                hook(SessionRewritePhase::BeforeTempCreate, path)
            }
            AtomicInstallPhase::BeforeReplace => hook(SessionRewritePhase::BeforeReplace, path),
            _ => Ok(()),
        },
    )
}

fn read_session_provider(file: &Path) -> Result<Option<SessionProviderRecord>, String> {
    let source = fs::File::open(file).map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(source);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    if read == 0 {
        return Ok(None);
    }
    parse_session_provider_record(file, &line)
}

pub(super) fn parse_session_provider_record(
    file: &Path,
    line: &str,
) -> Result<Option<SessionProviderRecord>, String> {
    let value: Value = serde_json::from_str(line.trim_end()).map_err(|error| error.to_string())?;
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return Ok(None);
    }
    let payload = value
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| format!("{} 缺少 session_meta.payload", file.display()))?;
    let thread_id = payload
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("{} 缺少 session_meta.payload.id", file.display()))?;
    validate_rollout_thread_identity(file, thread_id)?;
    let provider = payload
        .get("model_provider")
        .and_then(Value::as_str)
        .unwrap_or("(missing)")
        .to_string();
    Ok(Some(SessionProviderRecord {
        file: file.to_path_buf(),
        thread_id: thread_id.to_string(),
        provider,
    }))
}

fn split_first_line(bytes: &[u8]) -> (&[u8], &[u8]) {
    if bytes.ends_with(b"\r\n") {
        (&bytes[..bytes.len() - 2], b"\r\n")
    } else if bytes.ends_with(b"\n") {
        (&bytes[..bytes.len() - 1], b"\n")
    } else {
        (bytes, b"")
    }
}

fn validate_rollout_thread_identity(path: &Path, thread_id: &str) -> Result<(), String> {
    let Some(file_thread_id) = rollout_thread_id_from_path(path) else {
        return Ok(());
    };
    if file_thread_id == thread_id {
        Ok(())
    } else {
        Err(format!(
            "{} 的文件名线程 ID {} 与 session_meta.payload.id {} 不一致",
            path.display(),
            file_thread_id,
            thread_id
        ))
    }
}

fn rollout_thread_id_from_path(path: &Path) -> Option<&str> {
    let stem = path.file_stem()?.to_str()?;
    let candidate = stem.get(stem.len().checked_sub(36)?..)?;
    let bytes = candidate.as_bytes();
    let valid = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        });
    valid.then_some(candidate)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_atomic_with_hook(path, bytes, |_, _| Ok(()))
}

fn write_atomic_with_hook(
    path: &Path,
    bytes: &[u8],
    mut hook: impl FnMut(AtomicWritePhase, &Path) -> Result<(), String>,
) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("目标文件缺少父目录：{}", path.display()))?;
    let parent_metadata = fs::symlink_metadata(parent).map_err(|error| error.to_string())?;
    if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
        return Err(format!("目标父路径不是普通目录：{}", parent.display()));
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("目标文件名无效：{}", path.display()))?;

    for _ in 0..ATOMIC_TEMP_ATTEMPTS {
        let sequence = ATOMIC_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp = parent.join(format!(
            ".{file_name}.codex-token-bar-{}-{sequence:020}.tmp",
            std::process::id()
        ));
        let mut file = match create_atomic_temp(&temp) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.to_string()),
        };
        let temp_identity = atomic_file_identity(&file)?;
        let write_result = file
            .write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|error| error.to_string());
        drop(file);
        if let Err(error) = write_result {
            return Err(with_atomic_cleanup_error(
                error,
                &temp,
                &temp_identity,
                &mut hook,
            ));
        }
        let replace_result = hook(AtomicWritePhase::BeforeReplace, &temp).and_then(|_| {
            replace_file_atomically_with_hook(&temp, path, || {
                hook(AtomicWritePhase::AfterDestinationExists, path)
            })
        });
        if let Err(error) = replace_result {
            return Err(with_atomic_cleanup_error(
                error,
                &temp,
                &temp_identity,
                &mut hook,
            ));
        }
        return Ok(());
    }

    Err(format!("无法为 {} 创建唯一临时文件", path.display()))
}

fn with_atomic_cleanup_error(
    original_error: String,
    temp: &Path,
    expected: &AtomicFileIdentity,
    hook: &mut impl FnMut(AtomicWritePhase, &Path) -> Result<(), String>,
) -> String {
    match cleanup_atomic_temp(temp, expected, hook) {
        Ok(()) => original_error,
        Err(cleanup_error) => format!(
            "{original_error}；原子替换临时文件清理失败：{cleanup_error}"
        ),
    }
}

fn cleanup_atomic_temp(
    temp: &Path,
    expected: &AtomicFileIdentity,
    hook: &mut impl FnMut(AtomicWritePhase, &Path) -> Result<(), String>,
) -> Result<(), String> {
    hook(AtomicWritePhase::CleanupTemp, temp)
        .map_err(|error| format!("{error}；残留于 {}", temp.display()))?;

    #[cfg(unix)]
    return cleanup_unix_atomic_temp(temp, expected, hook);
    #[cfg(windows)]
    return cleanup_windows_atomic_temp(temp, expected, hook);
}

#[cfg(unix)]
fn cleanup_unix_atomic_temp(
    temp: &Path,
    expected: &AtomicFileIdentity,
    hook: &mut impl FnMut(AtomicWritePhase, &Path) -> Result<(), String>,
) -> Result<(), String> {
    use rustix::fs::{AtFlags, Mode, OFlags, RenameFlags};

    let parent_path = temp
        .parent()
        .ok_or_else(|| format!("临时文件缺少父目录，残留于 {}", temp.display()))?;
    let name = temp
        .file_name()
        .ok_or_else(|| format!("临时文件缺少文件名，残留于 {}", temp.display()))?;
    let parent = rustix::fs::open(
        parent_path,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| format!("无法固定临时文件父目录，残留于 {}：{error}", temp.display()))?;
    let named = match open_unix_atomic_temp_at(&parent, name) {
        Ok(file) => file,
        Err(error) if error == rustix::io::Errno::NOENT => return Ok(()),
        Err(error) => return Err(format!("无法安全重新打开临时文件，残留于 {}：{error}", temp.display())),
    };
    validate_atomic_temp(&named, expected, temp)?;
    hook(AtomicWritePhase::AfterCleanupIdentityCheck, temp)
        .map_err(|error| format!("{error}；残留于 {}", temp.display()))?;

    let quarantine_name = format!(
        ".codex-token-bar-cleanup-{}-{:020}.tmp",
        std::process::id(),
        ATOMIC_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    );
    let quarantine = parent_path.join(&quarantine_name);
    rustix::fs::renameat_with(&parent, name, &parent, quarantine_name.as_str(), RenameFlags::NOREPLACE)
        .map_err(|error| format!("无法隔离待清理临时文件，残留于 {}：{error}", temp.display()))?;
    let quarantined = open_unix_atomic_temp_at(&parent, quarantine_name.as_ref()).map_err(|error| {
        format!("无法复验隔离临时文件，残留于 {}：{error}", quarantine.display())
    })?;
    validate_atomic_temp(&quarantined, expected, &quarantine).map_err(|error| {
        format!("{error}；隔离对象未删除，真实残留路径为 {}", quarantine.display())
    })?;
    hook(AtomicWritePhase::BeforeHandleDelete, &quarantine).map_err(|error| {
        format!("{error}；隔离对象未删除，真实残留路径为 {}", quarantine.display())
    })?;
    rustix::fs::unlinkat(&parent, quarantine_name.as_str(), AtFlags::empty()).map_err(|error| {
        format!("隔离临时文件删除失败，真实残留路径为 {}：{error}", quarantine.display())
    })?;
    rustix::fs::fsync(&parent).map_err(|error| {
        format!("临时文件已删除但父目录同步失败，残留可能恢复于 {}：{error}", quarantine.display())
    })
}

#[cfg(windows)]
fn cleanup_windows_atomic_temp(
    temp: &Path,
    expected: &AtomicFileIdentity,
    hook: &mut impl FnMut(AtomicWritePhase, &Path) -> Result<(), String>,
) -> Result<(), String> {
    let named = match open_windows_atomic_temp_no_follow(temp) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("无法安全重新打开临时文件，残留于 {}：{error}", temp.display())),
    };
    validate_atomic_temp(&named, expected, temp)?;
    hook(AtomicWritePhase::AfterCleanupIdentityCheck, temp)
        .map_err(|error| format!("{error}；残留于 {}", temp.display()))?;
    hook(AtomicWritePhase::BeforeHandleDelete, temp)
        .map_err(|error| format!("{error}；残留于 {}", temp.display()))?;
    windows_delete_open_atomic_temp(&named)
        .map_err(|error| format!("已验证句柄删除失败，残留于 {}：{error}", temp.display()))
}

fn validate_atomic_temp(
    file: &File,
    expected: &AtomicFileIdentity,
    diagnostic: &Path,
) -> Result<(), String> {
    let metadata = file.metadata().map_err(|error| {
        format!("读取临时文件类型失败，残留于 {}：{error}", diagnostic.display())
    })?;
    if !metadata.file_type().is_file() {
        return Err(format!("临时文件不是普通文件，拒绝清理；残留于 {}", diagnostic.display()));
    }
    if atomic_file_identity(file)? != *expected {
        return Err(format!("临时文件名已指向其他物理文件，拒绝误删；残留于 {}", diagnostic.display()));
    }
    if atomic_file_link_count(file)? > 1 {
        return Err(format!("临时文件存在物理别名，拒绝误删；残留于 {}", diagnostic.display()));
    }
    Ok(())
}

#[cfg(not(windows))]
fn create_atomic_temp(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().write(true).create_new(true).open(path)
}

#[cfg(windows)]
fn create_atomic_temp(path: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::{
        DELETE, FILE_ATTRIBUTE_NORMAL, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_DELETE,
        FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .access_mode(FILE_GENERIC_READ | FILE_GENERIC_WRITE | DELETE)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .attributes(FILE_ATTRIBUTE_NORMAL)
        .open(path)
}

#[cfg(unix)]
fn atomic_file_identity(file: &File) -> Result<AtomicFileIdentity, String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    Ok(AtomicFileIdentity::Unix {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

#[cfg(unix)]
fn atomic_file_link_count(file: &File) -> Result<u64, String> {
    use std::os::unix::fs::MetadataExt;
    file.metadata()
        .map(|metadata| metadata.nlink())
        .map_err(|error| error.to_string())
}

#[cfg(unix)]
fn open_unix_atomic_temp_at(
    parent: &impl std::os::fd::AsFd,
    name: &std::ffi::OsStr,
) -> Result<File, rustix::io::Errno> {
    use rustix::fs::{Mode, OFlags};
    let file = rustix::fs::openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::NONBLOCK | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    Ok(File::from(file))
}

#[cfg(windows)]
fn atomic_file_identity(file: &File) -> Result<AtomicFileIdentity, String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
    };
    let mut info = FILE_ID_INFO::default();
    let succeeded = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileIdInfo,
            (&mut info as *mut FILE_ID_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_ID_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if succeeded == 0 {
        return Err(format!(
            "读取 Windows 临时文件身份失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(AtomicFileIdentity::Windows {
        volume_serial_number: info.VolumeSerialNumber,
        file_id: info.FileId.Identifier,
    })
}

#[cfg(windows)]
fn atomic_file_link_count(file: &File) -> Result<u64, String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FileStandardInfo, GetFileInformationByHandleEx, FILE_STANDARD_INFO,
    };
    let mut info = FILE_STANDARD_INFO::default();
    let succeeded = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileStandardInfo,
            (&mut info as *mut FILE_STANDARD_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_STANDARD_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if succeeded == 0 {
        return Err(format!(
            "读取 Windows 临时文件 hard link 计数失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(u64::from(info.NumberOfLinks))
}

#[cfg(windows)]
fn open_windows_atomic_temp_no_follow(path: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::{
        DELETE, FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ, FILE_SHARE_DELETE,
        FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    OpenOptions::new()
        .read(true)
        .access_mode(FILE_GENERIC_READ | DELETE)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
}

#[cfg(windows)]
fn windows_delete_open_atomic_temp(file: &File) -> std::io::Result<()> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        SetFileInformationByHandle, FileDispositionInfo, FILE_DISPOSITION_INFO,
    };
    let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
    let succeeded = unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle() as _,
            FileDispositionInfo,
            (&disposition as *const FILE_DISPOSITION_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_DISPOSITION_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if succeeded == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn write_file_atomically_with_hook(
    path: &Path,
    bytes: &[u8],
    hook: impl FnMut(AtomicWritePhase, &Path) -> Result<(), String>,
) -> Result<(), String> {
    write_atomic_with_hook(path, bytes, hook)
}

pub(super) fn replace_file_atomically(source: &Path, destination: &Path) -> Result<(), String> {
    replace_file_atomically_with_hook(source, destination, || Ok(()))
}

fn replace_file_atomically_with_hook(
    source: &Path,
    destination: &Path,
    after_destination_exists: impl FnMut() -> Result<(), String>,
) -> Result<(), String> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Storage::FileSystem::{ReplaceFileW, REPLACEFILE_WRITE_THROUGH};
        let mut after_destination_exists = after_destination_exists;

        if destination.exists() {
            after_destination_exists()?;
            let replaced = windows_extended_length_path(destination)?;
            let replacement = windows_extended_length_path(source)?;
            // SAFETY: both UTF-16 buffers are NUL-terminated and live for the call;
            // the optional backup/exclusion pointers are intentionally null.
            let replaced_ok = unsafe {
                ReplaceFileW(
                    replaced.as_ptr(),
                    replacement.as_ptr(),
                    std::ptr::null(),
                    REPLACEFILE_WRITE_THROUGH,
                    std::ptr::null(),
                    std::ptr::null(),
                )
            };
            if replaced_ok == 0 {
                return Err(format!(
                    "原子替换 {} 失败：{}",
                    destination.display(),
                    std::io::Error::last_os_error()
                ));
            }
            return Ok(());
        }
    }

    #[cfg(not(windows))]
    let _ = after_destination_exists;

    fs::rename(source, destination).map_err(|error| error.to_string())
}

pub(super) fn write_file_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_atomic(path, bytes)
}
