//! Admission for the active business container and its published readers.
//!
//! Keep the original initialization, runtime readiness and physical identity
//! checks together. Bootstrap/import ordering remains in the parent; this
//! module does not own coordinator transitions, store registration or receipts.

use super::container_path;
use crate::core::business_store_container::Container;
#[cfg(not(any(unix, windows)))]
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
#[cfg(not(test))]
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ContainerFileIdentity {
    volume: u64,
    file_id: u128,
}

#[cfg(not(test))]
static ACTIVE_CONTAINER_IDENTITY: OnceLock<Mutex<Option<ContainerFileIdentity>>> = OnceLock::new();

/// A failed follow-up operation cannot revoke a valid published container.
/// No CREATE, repair, import, checkpoint, or source scan occurs here. A missing
/// marker or an unknown root contract remains a complete startup failure.
pub(crate) fn admit_published_reads() -> Result<(), String> {
    let path = container_path()?;
    admit_published_reads_at(&path)
}

fn admit_published_reads_at(path: &Path) -> Result<(), String> {
    verify_marker(path)?;
    let container = Container::open_read_only_existing(path, std::time::Duration::from_secs(3))
        .map_err(|error| error.to_string())?;
    container.validate_catalog().map_err(|error| error.to_string())?;
    #[cfg(not(test))]
    remember_active_container_identity(path)?;
    Ok(())
}

pub(super) fn initialized_marker_path(container_path: &Path) -> PathBuf {
    let mut value = container_path.as_os_str().to_os_string();
    value.push(".initialized");
    PathBuf::from(value)
}

fn verify_marker(container_path: &Path) -> Result<(), String> {
    let marker = initialized_marker_path(container_path);
    let container_metadata = std::fs::symlink_metadata(container_path)
        .map_err(|error| format!("业务数据库 A 缺少有效容器文件：{error}"))?;
    if container_metadata.file_type().is_symlink() || !container_metadata.is_file() {
        return Err("业务数据库 A 不是普通文件；拒绝打开".into());
    }
    let marker_metadata = std::fs::symlink_metadata(&marker)
        .map_err(|error| format!("业务数据库 A 缺少有效初始化标记：{error}"))?;
    if marker_metadata.file_type().is_symlink() || !marker_metadata.is_file() {
        return Err("业务数据库 A 初始化标记不是普通文件；拒绝写入".into());
    }
    let contents = std::fs::read(&marker)
        .map_err(|error| format!("业务数据库 A 缺少有效初始化标记：{error}"))?;
    if contents != b"tokenbar-codex-ledger-v1\n" {
        return Err("业务数据库 A 初始化标记损坏；拒绝写入".into());
    }
    Ok(())
}

pub(super) fn verify_initialized(container_path: &Path) -> Result<(), String> {
    verify_marker(container_path)?;
    Container::open(container_path).map_err(|error| format!("业务数据库 A 校验失败：{error}"))?;
    #[cfg(not(test))]
    remember_active_container_identity(container_path)?;
    Ok(())
}

/// Retained Exact staging uses the runtime readiness and physical identity
/// fences without reopening A and reparsing its large MAIN catalog.
pub(crate) fn validate_exact_stage_container(path: &Path) -> Result<(), String> {
    ensure_runtime_business_store_ready()?;
    verify_marker(path)?;
    #[cfg(not(test))]
    verify_active_container_identity(path)?;
    Ok(())
}

pub(super) fn open_ready_container(container_path: &Path) -> Result<Container, String> {
    ensure_runtime_business_store_ready()?;
    open_ready_container_during_bootstrap(container_path)
}

pub(super) fn open_ready_container_during_bootstrap(container_path: &Path) -> Result<Container, String> {
    verify_ready_container(container_path)?;
    let container = Container::open_existing(container_path).map_err(|error| error.to_string())?;
    #[cfg(not(test))]
    verify_active_container_identity(container_path)?;
    Ok(container)
}

pub(super) fn ensure_runtime_business_store_ready() -> Result<(), String> {
    #[cfg(test)]
    {
        // Unit tests exercise the route against isolated temporary containers;
        // coordinator transitions are tested independently without process
        // global state or races between test cases.
        Ok(())
    }
    #[cfg(not(test))]
    {
        crate::core::business_startup::process_coordinator().ensure_ready()
    }
}

pub(super) fn ensure_runtime_business_store_readable() -> Result<(), String> {
    #[cfg(test)]
    { Ok(()) }
    #[cfg(not(test))]
    { crate::core::business_startup::process_coordinator().ensure_readable() }
}

pub(crate) fn published_reads_only() -> bool {
    #[cfg(test)]
    { false }
    #[cfg(not(test))]
    { crate::core::business_startup::process_coordinator().snapshot().phase
        == crate::core::business_startup::BusinessStartupPhase::ReadyWithPendingRecovery }
}

pub(super) fn verify_ready_container(container_path: &Path) -> Result<(), String> {
    verify_marker(container_path)?;
    #[cfg(not(test))]
    verify_active_container_identity(container_path)?;
    Ok(())
}

#[cfg(not(test))]
fn remember_active_container_identity(path: &Path) -> Result<(), String> {
    let observed = container_file_identity(path)?;
    let slot = ACTIVE_CONTAINER_IDENTITY.get_or_init(|| Mutex::new(None));
    let mut cached = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    match *cached {
        Some(expected) if expected != observed => {
            Err("codex-ledger A 容器文件身份在本次运行中发生变化；拒绝继续写入".into())
        }
        Some(_) => Ok(()),
        None => {
            *cached = Some(observed);
            Ok(())
        }
    }
}

#[cfg(not(test))]
pub(super) fn verify_active_container_identity(path: &Path) -> Result<(), String> {
    let slot = ACTIVE_CONTAINER_IDENTITY.get_or_init(|| Mutex::new(None));
    let expected = slot
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .ok_or_else(|| "业务数据库 A 尚未在本次运行中完成身份缓存".to_string())?;
    let observed = container_file_identity(path)?;
    if observed != expected {
        return Err("codex-ledger A 容器文件已被替换；拒绝继续读写".into());
    }
    Ok(())
}

fn container_file_identity(path: &Path) -> Result<ContainerFileIdentity, String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| format!("无法读取业务数据库 A 文件身份：{error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("业务数据库 A 不是普通文件；拒绝打开".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        return Ok(ContainerFileIdentity {
            volume: metadata.dev(),
            file_id: u128::from(metadata.ino()),
        });
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{
            FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
        };
        let file = std::fs::File::open(path)
            .map_err(|error| format!("无法打开业务数据库 A 读取文件身份：{error}"))?;
        let mut information = FILE_ID_INFO::default();
        if unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle() as _,
                FileIdInfo,
                (&mut information as *mut FILE_ID_INFO).cast(),
                std::mem::size_of::<FILE_ID_INFO>() as u32,
            )
        } == 0
        {
            return Err(format!(
                "无法读取业务数据库 A 文件身份：{}",
                std::io::Error::last_os_error()
            ));
        }
        let file_id = information
            .FileId
            .Identifier
            .iter()
            .enumerate()
            .fold(0_u128, |value, (index, byte)| {
                value | (u128::from(*byte) << (index * 8))
            });
        return Ok(ContainerFileIdentity {
            volume: information.VolumeSerialNumber,
            file_id,
        });
    }
    #[cfg(not(any(unix, windows)))]
    {
        let canonical = std::fs::canonicalize(path).map_err(|error| error.to_string())?;
        let mut digest = Sha256::new();
        digest.update(canonical.to_string_lossy().as_bytes());
        digest.update(metadata.len().to_be_bytes());
        let bytes = digest.finalize();
        let mut file_id = [0_u8; 16];
        file_id.copy_from_slice(&bytes[..16]);
        Ok(ContainerFileIdentity {
            volume: 0,
            file_id: u128::from_be_bytes(file_id),
        })
    }
}
