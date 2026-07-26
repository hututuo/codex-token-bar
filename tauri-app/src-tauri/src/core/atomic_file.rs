use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

const TEMP_ATTEMPTS: usize = 64;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum AtomicWriteStage {
    Write,
    FileSync,
    Replace,
    ParentSync,
    Cleanup,
    CleanupAfterIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum AtomicWriteError {
    NotCommitted(String),
    CommittedNotDurable(String),
}

impl std::fmt::Display for AtomicWriteError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotCommitted(message) => write!(formatter, "NotCommitted: {message}"),
            Self::CommittedNotDurable(message) => write!(formatter, "CommittedNotDurable: {message}"),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum FileIdentity {
    #[cfg(unix)]
    Unix { device: u64, inode: u64 },
    #[cfg(windows)]
    Windows { volume: u64, id: [u8; 16] },
}

pub(crate) fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), AtomicWriteError> {
    write_atomically_with_hook(path, bytes, |_, _| Ok(()))
}

pub(crate) fn write_atomically_streaming(
    path: &Path,
    write_content: impl FnMut(&mut File) -> Result<(), String>,
) -> Result<(), AtomicWriteError> {
    write_atomically_streaming_with_hook(path, write_content, |_, _| Ok(()))
}

pub(crate) fn write_atomically_with_hook(
    path: &Path,
    bytes: &[u8],
    hook: impl FnMut(AtomicWriteStage, &Path) -> Result<(), String>,
) -> Result<(), AtomicWriteError> {
    write_atomically_streaming_with_hook(
        path,
        |file| file.write_all(bytes).map_err(|error| error.to_string()),
        hook,
    )
}

fn write_atomically_streaming_with_hook(
    path: &Path,
    mut write_content: impl FnMut(&mut File) -> Result<(), String>,
    mut hook: impl FnMut(AtomicWriteStage, &Path) -> Result<(), String>,
) -> Result<(), AtomicWriteError> {
    let parent = path
        .parent()
        .ok_or_else(|| AtomicWriteError::NotCommitted(diagnostic(AtomicWriteStage::Write, path, "missing parent directory")))?;
    fs::create_dir_all(parent)
        .map_err(|error| AtomicWriteError::NotCommitted(diagnostic(AtomicWriteStage::Write, parent, error)))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| AtomicWriteError::NotCommitted(diagnostic(AtomicWriteStage::Write, path, "invalid destination name")))?;

    for _ in 0..TEMP_ATTEMPTS {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp = parent.join(format!(
            ".{name}.codex-token-bar-{}-{sequence:020}.tmp",
            std::process::id()
        ));
        let mut file = match create_temp(&temp) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(AtomicWriteError::NotCommitted(diagnostic(AtomicWriteStage::Write, &temp, error))),
        };
        let identity = file_identity(&file).map_err(|error| AtomicWriteError::NotCommitted(
            cleanup_after_error(diagnostic(AtomicWriteStage::Cleanup, &temp, error), &temp, None, &mut hook)
        ))?;
        let precommit = (|| {
            hook(AtomicWriteStage::Write, &temp)
                .map_err(|error| diagnostic(AtomicWriteStage::Write, &temp, error))?;
            write_content(&mut file)
                .map_err(|error| diagnostic(AtomicWriteStage::Write, &temp, error))?;
            hook(AtomicWriteStage::FileSync, &temp)
                .map_err(|error| diagnostic(AtomicWriteStage::FileSync, &temp, error))?;
            file.sync_all()
                .map_err(|error| diagnostic(AtomicWriteStage::FileSync, &temp, error))?;
            drop(file);
            hook(AtomicWriteStage::Replace, &temp)
                .map_err(|error| diagnostic(AtomicWriteStage::Replace, path, error))?;
            replace_destination(&temp, path)
                .map_err(|error| diagnostic(AtomicWriteStage::Replace, path, error))?;
            Ok(())
        })();
        if let Err(error) = precommit {
            return Err(AtomicWriteError::NotCommitted(cleanup_after_error(error, &temp, Some(&identity), &mut hook)));
        }
        if let Err(error) = hook(AtomicWriteStage::ParentSync, parent).and_then(|_| sync_parent(parent).map_err(|error| error.to_string())) {
            return Err(AtomicWriteError::CommittedNotDurable(diagnostic(AtomicWriteStage::ParentSync, parent, error)));
        }
        return Ok(());
    }
    Err(AtomicWriteError::NotCommitted(diagnostic(
        AtomicWriteStage::Write,
        path,
        "exhausted unique temporary file attempts",
    )))
}

fn cleanup_after_error(
    original: String,
    temp: &Path,
    identity: Option<&FileIdentity>,
    hook: &mut impl FnMut(AtomicWriteStage, &Path) -> Result<(), String>,
) -> String {
    let cleanup = hook(AtomicWriteStage::Cleanup, temp)
        .and_then(|_| match identity {
            Some(identity) => cleanup_temp_if_same(temp, identity, hook),
            None => Err(format!("identity unavailable; exact residual path={}", temp.display())),
        });
    match cleanup {
        Ok(()) => original,
        Err(error) => format!("{original}; cleanup path={} error={error}", temp.display()),
    }
}

fn diagnostic(stage: AtomicWriteStage, path: &Path, error: impl std::fmt::Display) -> String {
    format!("atomic-cache stage={stage:?} path={} error={error}", path.display())
}

#[cfg(unix)]
fn create_temp(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(any(unix, windows)))]
fn create_temp(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().read(true).write(true).create_new(true).open(path)
}

#[cfg(windows)]
fn create_temp(path: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::{DELETE, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE};
    OpenOptions::new().read(true).write(true).create_new(true)
        .access_mode(FILE_GENERIC_READ | FILE_GENERIC_WRITE | DELETE)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .open(path)
}

#[cfg(unix)]
fn file_identity(file: &File) -> Result<FileIdentity, String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    Ok(FileIdentity::Unix { device: metadata.dev(), inode: metadata.ino() })
}

#[cfg(windows)]
fn file_identity(file: &File) -> Result<FileIdentity, String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO};
    let mut info = FILE_ID_INFO::default();
    let ok = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileIdInfo,
            (&mut info as *mut FILE_ID_INFO).cast(),
            std::mem::size_of::<FILE_ID_INFO>() as u32,
        )
    };
    if ok == 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(FileIdentity::Windows { volume: info.VolumeSerialNumber, id: info.FileId.Identifier })
}

#[cfg(unix)]
fn cleanup_temp_if_same(path: &Path, expected: &FileIdentity, hook: &mut impl FnMut(AtomicWriteStage, &Path) -> Result<(), String>) -> Result<(), String> {
    use rustix::fs::{openat, renameat_with, unlinkat, AtFlags, Mode, OFlags, RenameFlags};
    let parent_path = path.parent().ok_or("temporary path has no parent")?;
    let parent = rustix::fs::open(parent_path, OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::empty())
        .map_err(|error| format!("residual path={}: {error}", path.display()))?;
    let name = path.file_name().ok_or("temporary path has no name")?;
    let fd = match openat(&parent, name, OFlags::RDONLY | OFlags::NONBLOCK | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::empty()) {
        Ok(fd) => fd,
        Err(rustix::io::Errno::NOENT) => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    let opened = File::from(fd);
    validate_temp(&opened, expected, path)?;
    hook(AtomicWriteStage::CleanupAfterIdentity, path)?;
    let quarantine_name = format!(".codex-token-bar-cleanup-{}-{:020}.tmp", std::process::id(), TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed));
    let quarantine = parent_path.join(&quarantine_name);
    renameat_with(&parent, name, &parent, quarantine_name.as_str(), RenameFlags::NOREPLACE)
        .map_err(|error| format!("quarantine failed residual path={}: {error}", path.display()))?;
    let quarantined = File::from(openat(&parent, quarantine_name.as_str(), OFlags::RDONLY | OFlags::NONBLOCK | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::empty())
        .map_err(|error| format!("quarantine reopen failed residual path={}: {error}", quarantine.display()))?);
    validate_temp(&quarantined, expected, &quarantine)?;
    unlinkat(&parent, quarantine_name.as_str(), AtFlags::empty())
        .map_err(|error| format!("handle-safe unlink failed residual path={}: {error}", quarantine.display()))?;
    rustix::fs::fsync(&parent).map_err(|error| format!("cleanup parent sync failed path={}: {error}", parent_path.display()))
}

#[cfg(windows)]
fn cleanup_temp_if_same(path: &Path, expected: &FileIdentity, hook: &mut impl FnMut(AtomicWriteStage, &Path) -> Result<(), String>) -> Result<(), String> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::{DELETE, FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE};
    let file = match OpenOptions::new()
        .read(true)
        .access_mode(FILE_GENERIC_READ | DELETE)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    validate_temp(&file, expected, path)?;
    hook(AtomicWriteStage::CleanupAfterIdentity, path)?;
    windows_delete_open_temp(&file).map_err(|error| format!("validated handle delete failed residual path={}: {error}", path.display()))
}

fn validate_temp(file: &File, expected: &FileIdentity, path: &Path) -> Result<(), String> {
    let metadata = file.metadata().map_err(|error| format!("type read failed residual path={}: {error}", path.display()))?;
    if !metadata.file_type().is_file() {
        return Err(format!("not a regular file; residual path={}", path.display()));
    }
    if &file_identity(file)? != expected {
        return Err(format!("temporary path identity changed; preserved replacement; residual path={}", path.display()));
    }
    Ok(())
}

#[cfg(windows)]
fn windows_delete_open_temp(file: &File) -> std::io::Result<()> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{SetFileInformationByHandle, FileDispositionInfo, FILE_DISPOSITION_INFO};
    let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
    let ok = unsafe { SetFileInformationByHandle(file.as_raw_handle() as _, FileDispositionInfo, (&disposition as *const FILE_DISPOSITION_INFO).cast(), std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32) };
    if ok == 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}

#[cfg(not(windows))]
fn replace_destination(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(windows)]
fn replace_destination(source: &Path, destination: &Path) -> std::io::Result<()> {
    use windows_sys::Win32::Storage::FileSystem::{ReplaceFileW, REPLACEFILE_WRITE_THROUGH};
    if !destination.exists() {
        return fs::rename(source, destination);
    }
    let destination = crate::core::windows_path::extended_length_path(destination)
        .map_err(std::io::Error::other)?;
    let source = crate::core::windows_path::extended_length_path(source)
        .map_err(std::io::Error::other)?;
    let ok = unsafe {
        ReplaceFileW(destination.as_ptr(), source.as_ptr(), std::ptr::null(), REPLACEFILE_WRITE_THROUGH, std::ptr::null(), std::ptr::null())
    };
    if ok == 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}

#[cfg(unix)]
fn sync_parent(parent: &Path) -> std::io::Result<()> {
    File::open(parent)?.sync_all()
}

#[cfg(windows)]
fn sync_parent(parent: &Path) -> std::io::Result<()> {
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_BACKUP_SEMANTICS, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, FlushFileBuffers};
    let directory = OpenOptions::new().read(true).write(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS).open(parent)?;
    let ok = unsafe { FlushFileBuffers(directory.as_raw_handle() as _) };
    if ok == 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}

#[cfg(not(any(unix, windows)))]
fn sync_parent(_parent: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("directory durability unsupported"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_disposition_uses_windows_sys_boolean_field() {
        let atomic_source = include_str!("atomic_file.rs");
        let provider_source = include_str!("provider_repair/session_files.rs");
        assert!(atomic_source.contains("FILE_DISPOSITION_INFO { DeleteFile: true }"));
        assert!(provider_source.contains("FILE_DISPOSITION_INFO { DeleteFile: true }"));
        let integer_field = ["FILE_DISPOSITION_INFO { DeleteFile: ", "1 }"].concat();
        assert!(!atomic_source.contains(&integer_field));
        assert!(!provider_source.contains(&integer_field));
    }
    use std::path::PathBuf;

    fn root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("atomic-cache-{label}-{}-{}", std::process::id(), TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)))
    }

    #[test]
    fn repeated_save_replaces_destination_and_leaves_no_temp() {
        let root = root("replace");
        fs::create_dir_all(&root).unwrap();
        let path = root.join("cache.json");
        write_atomically(&path, b"one").unwrap();
        write_atomically(&path, b"two").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"two");
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn atomic_write_creates_private_files() {
        use std::os::unix::fs::PermissionsExt;

        let root = root("private-mode");
        fs::create_dir_all(&root).unwrap();
        let path = root.join("cache.json");
        write_atomically(&path, b"private").unwrap();
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn injected_stage_failures_are_diagnostic_and_cleanup_temp() {
        for failed in [AtomicWriteStage::Write, AtomicWriteStage::FileSync, AtomicWriteStage::Replace, AtomicWriteStage::ParentSync] {
            let root = root("failure");
            fs::create_dir_all(&root).unwrap();
            let path = root.join("cache.json");
            if matches!(failed, AtomicWriteStage::Replace | AtomicWriteStage::ParentSync) { fs::write(&path, b"old").unwrap(); }
            let error = write_atomically_with_hook(&path, b"new", |stage, _| {
                if stage == failed { Err("injected".into()) } else { Ok(()) }
            }).unwrap_err();
            assert!(error.to_string().contains(&format!("stage={failed:?}")));
            if failed == AtomicWriteStage::ParentSync {
                assert!(matches!(error, AtomicWriteError::CommittedNotDurable(_)));
                assert_eq!(fs::read(&path).unwrap(), b"new");
            } else {
                assert!(matches!(error, AtomicWriteError::NotCommitted(_)));
                if failed == AtomicWriteStage::Replace {
                    assert_eq!(fs::read(&path).unwrap(), b"old");
                }
            }
            assert!(!fs::read_dir(&root).unwrap().flatten().any(|entry| entry.file_name().to_string_lossy().ends_with(".tmp")));
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn cleanup_preserves_replaced_temp_alias_and_reports_identity_change() {
        let root = root("alias");
        fs::create_dir_all(&root).unwrap();
        let path = root.join("cache.json");
        let mut alias = None;
        let error = write_atomically_with_hook(&path, b"new", |stage, temp| {
            if stage == AtomicWriteStage::Replace {
                let moved = root.join("moved-original.tmp");
                fs::rename(temp, &moved).unwrap();
                fs::write(temp, b"unrelated replacement").unwrap();
                alias = Some(moved);
                return Err("injected alias swap".into());
            }
            Ok(())
        })
        .unwrap_err();
        assert!(error.to_string().contains("identity changed"));
        assert_eq!(fs::read(alias.unwrap()).unwrap(), b"new");
        assert!(fs::read_dir(&root).unwrap().flatten().any(|entry| {
            fs::read(entry.path()).ok().as_deref() == Some(b"unrelated replacement")
        }));
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn cleanup_rejects_fifo_and_identity_swap_without_blocking_or_deleting_aliases() {
        use std::os::unix::ffi::OsStrExt;

        for swap_after_identity in [false, true] {
            let root = root("fifo-race");
            fs::create_dir_all(&root).unwrap();
            let path = root.join("cache.json");
            let alias = root.join("original-alias.tmp");
            let error = write_atomically_with_hook(&path, b"new", |stage, temp| {
                if stage == AtomicWriteStage::Replace && !swap_after_identity {
                    fs::rename(temp, &alias).unwrap();
                    let bytes = std::ffi::CString::new(temp.as_os_str().as_bytes()).unwrap();
                    unsafe extern "C" { fn mkfifo(path: *const std::ffi::c_char, mode: u32) -> i32; }
                    assert_eq!(unsafe { mkfifo(bytes.as_ptr(), 0o600) }, 0);
                    return Err("inject fifo".into());
                }
                if stage == AtomicWriteStage::Replace && swap_after_identity {
                    return Err("defer swap".into());
                }
                if stage == AtomicWriteStage::CleanupAfterIdentity && swap_after_identity {
                    fs::rename(temp, &alias).unwrap();
                    fs::write(temp, b"replacement").unwrap();
                }
                Ok(())
            }).unwrap_err();
            assert!(matches!(error, AtomicWriteError::NotCommitted(_)));
            assert!(alias.exists());
            assert!(error.to_string().contains("residual path"));
            fs::remove_dir_all(root).unwrap();
        }
    }
}
