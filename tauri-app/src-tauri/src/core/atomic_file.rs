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
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum FileIdentity {
    #[cfg(unix)]
    Unix { device: u64, inode: u64 },
    #[cfg(windows)]
    Windows { volume: u64, id: [u8; 16] },
}

pub(crate) fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_atomically_with_hook(path, bytes, |_, _| Ok(()))
}

pub(crate) fn write_atomically_with_hook(
    path: &Path,
    bytes: &[u8],
    mut hook: impl FnMut(AtomicWriteStage, &Path) -> Result<(), String>,
) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| diagnostic(AtomicWriteStage::Write, path, "missing parent directory"))?;
    fs::create_dir_all(parent)
        .map_err(|error| diagnostic(AtomicWriteStage::Write, parent, error))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| diagnostic(AtomicWriteStage::Write, path, "invalid destination name"))?;

    for _ in 0..TEMP_ATTEMPTS {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp = parent.join(format!(
            ".{name}.codex-token-bar-{}-{sequence:020}.tmp",
            std::process::id()
        ));
        let mut file = match create_temp(&temp) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(diagnostic(AtomicWriteStage::Write, &temp, error)),
        };
        let identity = file_identity(&file)
            .map_err(|error| cleanup_after_error(error, &temp, None, &mut hook))?;
        let result = (|| {
            hook(AtomicWriteStage::Write, &temp)
                .map_err(|error| diagnostic(AtomicWriteStage::Write, &temp, error))?;
            file.write_all(bytes)
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
            hook(AtomicWriteStage::ParentSync, parent)
                .map_err(|error| diagnostic(AtomicWriteStage::ParentSync, parent, error))?;
            sync_parent(parent)
                .map_err(|error| diagnostic(AtomicWriteStage::ParentSync, parent, error))?;
            Ok(())
        })();
        return result.map_err(|error| cleanup_after_error(error, &temp, Some(&identity), &mut hook));
    }
    Err(diagnostic(
        AtomicWriteStage::Write,
        path,
        "exhausted unique temporary file attempts",
    ))
}

fn cleanup_after_error(
    original: String,
    temp: &Path,
    identity: Option<&FileIdentity>,
    hook: &mut impl FnMut(AtomicWriteStage, &Path) -> Result<(), String>,
) -> String {
    let cleanup = hook(AtomicWriteStage::Cleanup, temp)
        .and_then(|_| match identity {
            Some(identity) => cleanup_temp_if_same(temp, identity),
            None => Ok(()),
        });
    match cleanup {
        Ok(()) => original,
        Err(error) => format!("{original}; cleanup path={} error={error}", temp.display()),
    }
}

fn diagnostic(stage: AtomicWriteStage, path: &Path, error: impl std::fmt::Display) -> String {
    format!("atomic-cache stage={stage:?} path={} error={error}", path.display())
}

fn create_temp(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().read(true).write(true).create_new(true).open(path)
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
fn cleanup_temp_if_same(path: &Path, expected: &FileIdentity) -> Result<(), String> {
    use rustix::fs::{openat, unlinkat, AtFlags, Mode, OFlags};
    let parent = File::open(path.parent().ok_or("temporary path has no parent")?)
        .map_err(|error| error.to_string())?;
    let name = path.file_name().ok_or("temporary path has no name")?;
    let fd = match openat(&parent, name, OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::empty()) {
        Ok(fd) => fd,
        Err(rustix::io::Errno::NOENT) => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    let opened = File::from(fd);
    if &file_identity(&opened)? != expected {
        return Err("temporary path identity changed; preserved replacement".into());
    }
    unlinkat(&parent, name, AtFlags::empty()).map_err(|error| error.to_string())
}

#[cfg(windows)]
fn cleanup_temp_if_same(path: &Path, expected: &FileIdentity) -> Result<(), String> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE};
    let file = match OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    if &file_identity(&file)? != expected {
        return Err("temporary path identity changed; preserved replacement".into());
    }
    fs::remove_file(path).map_err(|error| error.to_string())
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

    #[test]
    fn injected_stage_failures_are_diagnostic_and_cleanup_temp() {
        for failed in [AtomicWriteStage::Write, AtomicWriteStage::FileSync, AtomicWriteStage::Replace, AtomicWriteStage::ParentSync] {
            let root = root("failure");
            fs::create_dir_all(&root).unwrap();
            let path = root.join("cache.json");
            if failed == AtomicWriteStage::ParentSync { fs::write(&path, b"old").unwrap(); }
            let error = write_atomically_with_hook(&path, b"new", |stage, _| {
                if stage == failed { Err("injected".into()) } else { Ok(()) }
            }).unwrap_err();
            assert!(error.contains(&format!("stage={failed:?}")));
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
        assert!(error.contains("identity changed"));
        assert_eq!(fs::read(alias.unwrap()).unwrap(), b"new");
        assert!(fs::read_dir(&root).unwrap().flatten().any(|entry| {
            fs::read(entry.path()).ok().as_deref() == Some(b"unrelated replacement")
        }));
        fs::remove_dir_all(root).unwrap();
    }
}
