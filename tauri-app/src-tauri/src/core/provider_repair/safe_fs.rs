use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(target_os = "linux")]
use rustix::fd::AsRawFd;
#[cfg(unix)]
use rustix::fd::OwnedFd;
#[cfg(unix)]
use rustix::fs::{self as unix_fs, AtFlags, Mode, OFlags};
#[cfg(windows)]
use std::ffi::{OsStr, OsString};
#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;
#[cfg(windows)]
use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle};

const ATOMIC_TEMP_ATTEMPTS: usize = 64;
static ATOMIC_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AtomicInstallPhase {
    BeforeTempCreate,
    ValidateTemp,
    BeforeReplace,
    BeforeFileSync,
    BeforeParentSync,
    CleanupTemp,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(super) enum PhysicalFileIdentity {
    #[cfg(unix)]
    Unix { device: u64, inode: u64 },
    #[cfg(windows)]
    Windows {
        volume_serial_number: u64,
        file_id: [u8; 16],
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PinnedMemberState {
    relative: PathBuf,
    identity: Option<PhysicalFileIdentity>,
    size: Option<u64>,
    checksum_sha256: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PinnedMutationGuard {
    storage: PinnedStorageGuard,
    account_identity: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PinnedStorageGuard {
    root_generation: HomeGenerationIdentity,
    members: Vec<PinnedMemberState>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub(super) enum HomeGenerationIdentity {
    #[cfg(unix)]
    Unix { device: u64, inode: u64 },
    #[cfg(windows)]
    Windows {
        volume_serial_number: u64,
        file_id: String,
    },
}

#[cfg(test)]
pub(super) fn provider_mutation_support_for_platform(platform: &str) -> Result<(), String> {
    if platform.eq_ignore_ascii_case("windows") || platform.eq_ignore_ascii_case("unix") {
        Ok(())
    } else {
        Err(format!("Provider 写操作不支持平台：{platform}"))
    }
}

#[cfg(not(any(unix, windows)))]
fn unsupported_platform_error() -> String {
    "Provider 写操作不支持当前平台。".into()
}

pub(crate) struct PinnedHome {
    canonical_path: PathBuf,
    #[cfg(unix)]
    root: OwnedFd,
    #[cfg(windows)]
    root: File,
    #[cfg(windows)]
    root_identity: WindowsFileIdentity,
}

impl PinnedHome {
    pub(crate) fn open(path: &Path) -> Result<Self, String> {
        let canonical_path = path
            .canonicalize()
            .map_err(|error| format!("无法确认 Codex Home {}：{error}", path.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;

            let expected = std::fs::metadata(&canonical_path).map_err(|error| error.to_string())?;
            if !expected.is_dir() {
                return Err(format!("Codex Home 不是目录：{}", canonical_path.display()));
            }
            let root = open_absolute_directory_without_following(&canonical_path)?;
            let actual_file = File::from(
                rustix::io::dup(&root)
                    .map_err(|error| format!("复制 Codex Home 目录句柄失败：{error}"))?,
            );
            let actual = actual_file.metadata().map_err(|error| error.to_string())?;
            if expected.dev() != actual.dev() || expected.ino() != actual.ino() {
                return Err(format!(
                    "Codex Home 在固定目录句柄时发生身份变化，已在写入前拒绝：{}",
                    canonical_path.display()
                ));
            }
            return Ok(Self {
                canonical_path,
                root,
            });
        }

        #[cfg(windows)]
        {
            // The root handle is shared by read paths and by relative child
            // opens. Request only traversal/read rights here; a mutating child
            // handle still asks for its own write/delete rights below. This
            // keeps a readable Home usable for diagnostics and scanning when
            // the directory ACL does not grant FILE_DELETE_CHILD to the root
            // handle itself.
            let root = open_windows_absolute_directory_without_following(&canonical_path)?;
            let root_identity = windows_file_identity(&root)?;
            return Ok(Self {
                canonical_path,
                root,
                root_identity,
            });
        }

        #[cfg(not(any(unix, windows)))]
        {
            let _ = canonical_path;
            Err(unsupported_platform_error())
        }
    }

    pub(crate) fn canonical_path(&self) -> &Path {
        &self.canonical_path
    }

    pub(super) fn generation_identity(&self) -> Result<HomeGenerationIdentity, String> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;

            let root = File::from(
                rustix::io::dup(&self.root)
                    .map_err(|error| format!("复制固定 Codex Home 句柄失败：{error}"))?,
            );
            let metadata = root.metadata().map_err(|error| {
                format!(
                    "读取固定 Codex Home generation 失败 {}：{error}",
                    self.canonical_path.display()
                )
            })?;
            return Ok(HomeGenerationIdentity::Unix {
                device: metadata.dev(),
                inode: metadata.ino(),
            });
        }

        #[cfg(windows)]
        {
            return Ok(HomeGenerationIdentity::Windows {
                volume_serial_number: self.root_identity.volume_serial_number,
                file_id: self
                    .root_identity
                    .file_id
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
            });
        }

        #[cfg(not(any(unix, windows)))]
        {
            Err(unsupported_platform_error())
        }
    }

    pub(super) fn account_identity_fingerprint(&self) -> Result<Option<String>, String> {
        let relative = Path::new("auth.json");
        let Some(mut file) = self.open_file(relative)? else {
            return Ok(None);
        };
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)
            .map_err(|error| format!("读取 Provider auth.json 失败：{error}"))?;
        let Some(account_key) = stable_account_key_from_auth_json(&bytes) else {
            return Ok(None);
        };
        let mut hasher = Sha256::new();
        hasher.update(b"provider-account-identity-v1\0");
        hasher.update(account_key.as_bytes());
        Ok(Some(format!("sha256:{:x}", hasher.finalize())))
    }

    pub(super) fn ensure_canonical_path_identity(&self) -> Result<(), String> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;

            let current = open_absolute_directory_without_following(&self.canonical_path).map_err(
                |error| {
                    format!(
                        "固定 Codex Home 的规范路径已变化，已拒绝路径读取 {}：{error}",
                        self.canonical_path.display()
                    )
                },
            )?;
            let expected = File::from(
                rustix::io::dup(&self.root)
                    .map_err(|error| format!("复制固定 Codex Home 句柄失败：{error}"))?,
            )
            .metadata()
            .map_err(|error| error.to_string())?;
            let actual = File::from(current)
                .metadata()
                .map_err(|error| error.to_string())?;
            if expected.dev() != actual.dev() || expected.ino() != actual.ino() {
                return Err(format!(
                    "固定 Codex Home 的规范路径已指向不同目录，已在路径读取前拒绝：{}",
                    self.canonical_path.display()
                ));
            }
            Ok(())
        }
        #[cfg(windows)]
        {
            let current =
                open_windows_absolute_directory_without_following(&self.canonical_path).map_err(
                    |error| {
                        format!(
                            "固定 Codex Home 的规范路径已变化，已拒绝路径读取 {}：{error}",
                            self.canonical_path.display()
                        )
                    },
                )?;
            let actual = windows_file_identity(&current)?;
            if actual != self.root_identity {
                return Err(format!(
                    "固定 Codex Home 的规范路径已指向不同目录，已在路径读取前拒绝：{}",
                    self.canonical_path.display()
                ));
            }
            Ok(())
        }
        #[cfg(not(any(unix, windows)))]
        {
            Err(unsupported_platform_error())
        }
    }

    pub(super) fn access_path(&self) -> PathBuf {
        #[cfg(all(unix, target_os = "linux"))]
        {
            return PathBuf::from(format!("/proc/self/fd/{}", self.root.as_raw_fd()));
        }
        #[cfg(all(unix, not(target_os = "linux")))]
        {
            return self.canonical_path.clone();
        }
        #[cfg(windows)]
        {
            self.canonical_path.clone()
        }
        #[cfg(not(any(unix, windows)))]
        {
            self.canonical_path.clone()
        }
    }

    pub(super) fn read(&self, relative: &Path) -> Result<Vec<u8>, String> {
        let Some(mut file) = self.open_file(relative)? else {
            return Err(format!("Provider 文件不存在：{}", relative.display()));
        };
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)
            .map_err(|error| format!("读取 Provider 文件 {} 失败：{error}", relative.display()))?;
        Ok(bytes)
    }

    pub(crate) fn open_file(&self, relative: &Path) -> Result<Option<File>, String> {
        #[cfg(unix)]
        {
            let parent = self.open_parent(relative, false)?;
            return open_regular_file_at(&parent.fd, &parent.file_name, relative);
        }
        #[cfg(windows)]
        {
            let parent = self.open_parent_with_access(relative, false, false)?;
            return windows_open_regular_file_at(
                &parent.file,
                &parent.file_name,
                relative,
                windows_read_file_access(),
            );
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = relative;
            Err(unsupported_platform_error())
        }
    }

    pub(crate) fn ensure_parent_directories(&self, relative: &Path) -> Result<(), String> {
        #[cfg(unix)]
        {
            let _ = self.open_parent(relative, true)?;
            return Ok(());
        }
        #[cfg(windows)]
        {
            let _ = self.open_parent(relative, true)?;
            return Ok(());
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = relative;
            Err(unsupported_platform_error())
        }
    }

    pub(super) fn member_len_and_sha256(
        &self,
        relative: &Path,
    ) -> Result<Option<(u64, String)>, String> {
        let Some(mut file) = self.open_file(relative)? else {
            return Ok(None);
        };
        let length = file.metadata().map_err(|error| error.to_string())?.len();
        let checksum = sha256_file(&mut file)?;
        Ok(Some((length, checksum)))
    }

    pub(super) fn capture_mutation_guard(
        &self,
        relatives: &[PathBuf],
    ) -> Result<PinnedMutationGuard, String> {
        let storage = self.capture_storage_guard(relatives)?;
        let account_identity = self
            .account_identity_fingerprint()?
            .ok_or_else(|| "Provider commit 前无法确认稳定账号身份，已拒绝写入。".to_string())?;
        Ok(PinnedMutationGuard {
            storage,
            account_identity,
        })
    }

    pub(super) fn capture_storage_guard(
        &self,
        relatives: &[PathBuf],
    ) -> Result<PinnedStorageGuard, String> {
        let mut logical_members = HashSet::new();
        let mut physical_members = HashSet::new();
        let mut members = Vec::with_capacity(relatives.len());
        for relative in relatives {
            let logical_key = logical_member_key(relative)?;
            if !logical_members.insert(logical_key) {
                return Err(format!(
                    "Provider 待写成员集合存在逻辑别名：{}",
                    relative.display()
                ));
            }
            let state = self.capture_member_state(relative)?;
            if let Some(identity) = &state.identity {
                if !physical_members.insert(identity.clone()) {
                    return Err(format!(
                        "Provider 待写成员集合存在物理别名（相同 dev/inode 或 volume/file ID）：{}",
                        relative.display()
                    ));
                }
            }
            members.push(state);
        }
        members.sort_by(|left, right| left.relative.cmp(&right.relative));
        Ok(PinnedStorageGuard {
            root_generation: self.generation_identity()?,
            members,
        })
    }

    pub(super) fn verify_mutation_guard(
        &self,
        expected: &PinnedMutationGuard,
    ) -> Result<(), String> {
        self.ensure_canonical_path_identity()?;
        let relatives = expected.storage.member_paths();
        let actual = self.capture_mutation_guard(&relatives)?;
        if actual.account_identity != expected.account_identity {
            return Err("Provider commit 前账号身份已变化，已拒绝提交。".into());
        }
        if actual.storage != expected.storage {
            return Err("Provider commit 前待写成员 descriptor 身份、内容或 expected set 已变化，已拒绝提交。".into());
        }
        Ok(())
    }

    pub(super) fn verify_mutation_scope(
        &self,
        expected: &PinnedMutationGuard,
    ) -> Result<(), String> {
        self.ensure_canonical_path_identity()?;
        if self.generation_identity()? != expected.storage.root_generation {
            return Err("Provider commit 前 Codex Home generation 已变化，已拒绝提交。".into());
        }
        let account_identity = self
            .account_identity_fingerprint()?
            .ok_or_else(|| "Provider commit 前账号身份变为未知，已拒绝提交。".to_string())?;
        if account_identity != expected.account_identity {
            return Err("Provider commit 前账号身份已变化，已拒绝提交。".into());
        }
        Ok(())
    }

    pub(super) fn verify_storage_guard(
        &self,
        expected: &PinnedStorageGuard,
    ) -> Result<(), String> {
        self.ensure_canonical_path_identity()?;
        let actual = self.capture_storage_guard(&expected.member_paths())?;
        if &actual != expected {
            return Err(
                "Provider commit 前 SQLite 根目录或待写成员身份、内容发生变化，已拒绝提交。"
                    .into(),
            );
        }
        Ok(())
    }

    pub(super) fn verify_storage_scope(
        &self,
        expected: &PinnedStorageGuard,
    ) -> Result<(), String> {
        self.ensure_canonical_path_identity()?;
        if self.generation_identity()? != expected.root_generation {
            return Err("Provider commit 前 SQLite 根目录 generation 已变化，已拒绝提交。".into());
        }
        Ok(())
    }

    fn capture_member_state(&self, relative: &Path) -> Result<PinnedMemberState, String> {
        let Some(mut file) = self.open_file(relative)? else {
            return Ok(PinnedMemberState {
                relative: relative.to_path_buf(),
                identity: None,
                size: None,
                checksum_sha256: None,
            });
        };
        reject_physical_alias(&file, relative)?;
        let identity = physical_file_identity(&file)?;
        let size = file.metadata().map_err(|error| error.to_string())?.len();
        let checksum_sha256 = sha256_file(&mut file)?;
        Ok(PinnedMemberState {
            relative: relative.to_path_buf(),
            identity: Some(identity),
            size: Some(size),
            checksum_sha256: Some(checksum_sha256),
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn install_atomically(
        &self,
        relative: &Path,
        expected_size: Option<u64>,
        expected_checksum: Option<&str>,
        mut populate: impl FnMut(&mut File) -> Result<(), String>,
        mut event: impl FnMut(AtomicInstallPhase, &Path) -> Result<(), String>,
    ) -> Result<(), String> {
        #[cfg(unix)]
        {
            let parent = self.open_parent(relative, true)?;
            reject_existing_non_regular(&parent.fd, &parent.file_name, relative)?;
            self.install_atomically_in_parent(
                relative,
                &parent,
                expected_size,
                expected_checksum,
                &mut populate,
                &mut event,
            )
        }
        #[cfg(windows)]
        {
            let parent = self.open_parent(relative, true)?;
            windows_reject_existing_non_regular(&parent.file, &parent.file_name, relative)?;
            self.install_atomically_in_parent(
                relative,
                &parent,
                expected_size,
                expected_checksum,
                &mut populate,
                &mut event,
            )
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (
                relative,
                expected_size,
                expected_checksum,
                &mut populate,
                &mut event,
            );
            Err(unsupported_platform_error())
        }
    }

    pub(super) fn transform_file_atomically(
        &self,
        relative: &Path,
        mut transform: impl FnMut(Vec<u8>) -> Result<Option<Vec<u8>>, String>,
        mut event: impl FnMut(AtomicInstallPhase, &Path) -> Result<(), String>,
    ) -> Result<bool, String> {
        #[cfg(unix)]
        {
            let parent = self.open_parent(relative, false)?;
            let mut source =
                open_regular_file_required_at(&parent.fd, parent.file_name.as_os_str(), relative)?;
            let mut bytes = Vec::new();
            source.read_to_end(&mut bytes).map_err(|error| {
                format!("读取 Provider 文件 {} 失败：{error}", relative.display())
            })?;
            drop(source);
            let Some(replacement) = transform(bytes)? else {
                return Ok(false);
            };
            self.install_atomically_in_parent(
                relative,
                &parent,
                None,
                None,
                &mut |target| {
                    target
                        .write_all(&replacement)
                        .map_err(|error| error.to_string())
                },
                &mut event,
            )?;
            Ok(true)
        }
        #[cfg(windows)]
        {
            let parent = self.open_parent(relative, false)?;
            let mut source = windows_open_regular_file_required_at(
                &parent.file,
                parent.file_name.as_os_str(),
                relative,
                windows_read_file_access(),
            )?;
            let mut bytes = Vec::new();
            source.read_to_end(&mut bytes).map_err(|error| {
                format!("读取 Provider 文件 {} 失败：{error}", relative.display())
            })?;
            drop(source);
            let Some(replacement) = transform(bytes)? else {
                return Ok(false);
            };
            self.install_atomically_in_parent(
                relative,
                &parent,
                None,
                None,
                &mut |target| {
                    target
                        .write_all(&replacement)
                        .map_err(|error| error.to_string())
                },
                &mut event,
            )?;
            Ok(true)
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (relative, &mut transform, &mut event);
            Err(unsupported_platform_error())
        }
    }

    pub(crate) fn transform_first_line_atomically(
        &self,
        relative: &Path,
        mut transform: impl FnMut(&[u8]) -> Result<Option<Vec<u8>>, String>,
        mut event: impl FnMut(AtomicInstallPhase, &Path) -> Result<(), String>,
    ) -> Result<bool, String> {
        #[cfg(unix)]
        {
            let parent = self.open_parent(relative, false)?;
            let mut source =
                open_regular_file_required_at(&parent.fd, parent.file_name.as_os_str(), relative)?;
            let source_identity = physical_file_identity(&source)?;
            let source_size = source.metadata().map_err(|error| error.to_string())?.len();
            let first_line = read_first_line_bytes(&mut source, relative)?;
            let Some(replacement) = transform(&first_line)? else {
                return Ok(false);
            };
            let first_line_len = u64::try_from(first_line.len())
                .map_err(|_| format!("Provider 首行过大：{}", relative.display()))?;
            self.install_atomically_in_parent(
                relative,
                &parent,
                None,
                None,
                &mut |target| {
                    target
                        .write_all(&replacement)
                        .map_err(|error| error.to_string())?;
                    source
                        .seek(SeekFrom::Start(first_line_len))
                        .map_err(|error| error.to_string())?;
                    std::io::copy(&mut source, target)
                        .map(|_| ())
                        .map_err(|error| error.to_string())?;
                    if source.metadata().map_err(|error| error.to_string())?.len() != source_size {
                        return Err(format!(
                            "Provider 会话文件在流式改写期间发生变化：{}",
                            relative.display()
                        ));
                    }
                    Ok(())
                },
                &mut |phase, path| {
                    if phase == AtomicInstallPhase::BeforeReplace {
                        let current = open_regular_file_required_at(
                            &parent.fd,
                            parent.file_name.as_os_str(),
                            relative,
                        )?;
                        if physical_file_identity(&current)? != source_identity {
                            return Err(format!(
                                "Provider 会话文件在原子替换前已被其他进程换代：{}",
                                relative.display()
                            ));
                        }
                        // 同 inode 的并发追加不改变 identity：必须复查 size，
                        // 否则替换会静默丢弃复制之后追加的事件。
                        if current.metadata().map_err(|error| error.to_string())?.len()
                            != source_size
                        {
                            return Err(format!(
                                "Provider 会话文件在原子替换前发生追加或截断：{}",
                                relative.display()
                            ));
                        }
                    }
                    event(phase, path)
                },
            )?;
            return Ok(true);
        }
        #[cfg(windows)]
        {
            let parent = self.open_parent(relative, false)?;
            let mut source = windows_open_regular_file_required_at(
                &parent.file,
                parent.file_name.as_os_str(),
                relative,
                windows_read_file_access(),
            )?;
            let source_identity = physical_file_identity(&source)?;
            let source_size = source.metadata().map_err(|error| error.to_string())?.len();
            let first_line = read_first_line_bytes(&mut source, relative)?;
            let Some(replacement) = transform(&first_line)? else {
                return Ok(false);
            };
            let first_line_len = u64::try_from(first_line.len())
                .map_err(|_| format!("Provider 首行过大：{}", relative.display()))?;
            self.install_atomically_in_parent(
                relative,
                &parent,
                None,
                None,
                &mut |target| {
                    target
                        .write_all(&replacement)
                        .map_err(|error| error.to_string())?;
                    source
                        .seek(SeekFrom::Start(first_line_len))
                        .map_err(|error| error.to_string())?;
                    std::io::copy(&mut source, target)
                        .map(|_| ())
                        .map_err(|error| error.to_string())?;
                    if source.metadata().map_err(|error| error.to_string())?.len() != source_size {
                        return Err(format!(
                            "Provider 会话文件在流式改写期间发生变化：{}",
                            relative.display()
                        ));
                    }
                    Ok(())
                },
                &mut |phase, path| {
                    if phase == AtomicInstallPhase::BeforeReplace {
                        let current = windows_open_regular_file_required_at(
                            &parent.file,
                            parent.file_name.as_os_str(),
                            relative,
                            windows_read_file_access(),
                        )?;
                        if physical_file_identity(&current)? != source_identity {
                            return Err(format!(
                                "Provider 会话文件在原子替换前已被其他进程换代：{}",
                                relative.display()
                            ));
                        }
                        // 同 inode 的并发追加不改变 identity：必须复查 size，
                        // 否则替换会静默丢弃复制之后追加的事件。
                        if current.metadata().map_err(|error| error.to_string())?.len()
                            != source_size
                        {
                            return Err(format!(
                                "Provider 会话文件在原子替换前发生追加或截断：{}",
                                relative.display()
                            ));
                        }
                    }
                    event(phase, path)
                },
            )?;
            return Ok(true);
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (relative, &mut transform, &mut event);
            Err(unsupported_platform_error())
        }
    }

    pub(crate) fn remove_file(
        &self,
        relative: &Path,
        mut before_parent_sync: impl FnMut() -> Result<(), String>,
    ) -> Result<bool, String> {
        #[cfg(unix)]
        {
            let parent = self.open_parent(relative, false)?;
            match open_regular_file_at(&parent.fd, &parent.file_name, relative)? {
                Some(_) => {}
                None => return Ok(false),
            }
            unix_fs::unlinkat(&parent.fd, parent.file_name.as_os_str(), AtFlags::empty()).map_err(
                |error| format!("移除 Provider 文件 {} 失败：{error}", relative.display()),
            )?;
            before_parent_sync()?;
            unix_fs::fsync(&parent.fd).map_err(|error| {
                format!("同步 Provider 父目录 {} 失败：{error}", relative.display())
            })?;
            Ok(true)
        }
        #[cfg(windows)]
        {
            let parent = self.open_parent(relative, false)?;
            let Some(file) = windows_open_regular_file_at(
                &parent.file,
                &parent.file_name,
                relative,
                windows_delete_file_access(),
            )?
            else {
                return Ok(false);
            };
            self.verify_windows_parent(relative, &parent)?;
            windows_delete_open_file(&file).map_err(|error| {
                format!("移除 Provider 文件 {} 失败：{error}", relative.display())
            })?;
            drop(file);
            before_parent_sync()?;
            parent.file.sync_all().map_err(|error| {
                format!("同步 Provider 父目录 {} 失败：{error}", relative.display())
            })?;
            Ok(true)
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (relative, &mut before_parent_sync);
            Err(unsupported_platform_error())
        }
    }

    #[cfg(unix)]
    fn open_parent(&self, relative: &Path, create: bool) -> Result<PinnedParent, String> {
        let components = normal_components(relative)?;
        let (file_name, parents) = components
            .split_last()
            .ok_or_else(|| format!("Provider 相对路径为空：{}", relative.display()))?;
        let mut current = rustix::io::dup(&self.root)
            .map_err(|error| format!("复制 Codex Home 句柄失败：{error}"))?;
        let mut relative_parent = PathBuf::new();
        for component in parents {
            let next = match unix_fs::openat(
                &current,
                component.as_os_str(),
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            ) {
                Ok(fd) => fd,
                Err(error) if create && error == rustix::io::Errno::NOENT => {
                    unix_fs::mkdirat(&current, component.as_os_str(), Mode::from_raw_mode(0o700))
                        .map_err(|mkdir_error| {
                        format!(
                            "创建 Provider 父目录 {} 失败：{mkdir_error}",
                            relative.display()
                        )
                    })?;
                    unix_fs::fsync(&current).map_err(|sync_error| {
                        format!(
                            "同步新建 Provider 父目录项 {} 失败：{sync_error}",
                            relative.display()
                        )
                    })?;
                    unix_fs::openat(
                        &current,
                        component.as_os_str(),
                        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                        Mode::empty(),
                    )
                    .map_err(|open_error| {
                        format!(
                            "打开新建 Provider 父目录 {} 失败：{open_error}",
                            relative.display()
                        )
                    })?
                }
                Err(error) => {
                    return Err(format!(
                        "打开 Provider 父目录 {} 失败，已拒绝路径跟随：{error}",
                        relative.display()
                    ))
                }
            };
            current = next;
            relative_parent.push(component);
        }
        Ok(PinnedParent {
            fd: current,
            relative_parent,
            file_name: file_name.clone(),
        })
    }

    #[cfg(unix)]
    #[allow(clippy::too_many_arguments)]
    fn install_atomically_in_parent(
        &self,
        relative: &Path,
        parent: &PinnedParent,
        expected_size: Option<u64>,
        expected_checksum: Option<&str>,
        populate: &mut impl FnMut(&mut File) -> Result<(), String>,
        event: &mut impl FnMut(AtomicInstallPhase, &Path) -> Result<(), String>,
    ) -> Result<(), String> {
        let file_name = parent
            .file_name
            .to_str()
            .ok_or_else(|| format!("Provider 文件名不是有效 UTF-8：{}", relative.display()))?;
        event(
            AtomicInstallPhase::BeforeTempCreate,
            &self.canonical_path.join(relative),
        )?;

        for _ in 0..ATOMIC_TEMP_ATTEMPTS {
            let sequence = ATOMIC_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let temp_name = format!(
                ".{file_name}.restore-{}-{sequence:020}.tmp",
                std::process::id()
            );
            let temp_fd = match unix_fs::openat(
                &parent.fd,
                temp_name.as_str(),
                OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::from_raw_mode(0o600),
            ) {
                Ok(fd) => fd,
                Err(error) if error == rustix::io::Errno::EXIST => continue,
                Err(error) => return Err(format!("创建 Provider 临时文件失败：{error}")),
            };
            let mut temp_file = File::from(temp_fd);
            let temp_display = self
                .canonical_path
                .join(&parent.relative_parent)
                .join(&temp_name);

            let result = (|| {
                populate(&mut temp_file)?;
                temp_file
                    .sync_all()
                    .map_err(|error| format!("同步 Provider 临时文件失败：{error}"))?;
                event(AtomicInstallPhase::ValidateTemp, &temp_display)?;

                let mut verify_file = open_regular_file_required_at(
                    &parent.fd,
                    temp_name.as_ref(),
                    Path::new(&temp_name),
                )?;
                let actual_size = verify_file
                    .metadata()
                    .map_err(|error| error.to_string())?
                    .len();
                let actual_checksum = expected_checksum
                    .map(|_| sha256_file(&mut verify_file))
                    .transpose()?;
                if expected_size.is_some_and(|expected| actual_size != expected)
                    || expected_checksum
                        .zip(actual_checksum.as_deref())
                        .is_some_and(|(expected, actual)| actual != expected)
                {
                    return Err(format!(
                        "Provider 临时文件在替换前 SHA-256 或大小校验失败：{}",
                        relative.display()
                    ));
                }

                event(AtomicInstallPhase::BeforeReplace, &temp_display)?;
                unix_fs::renameat(
                    &parent.fd,
                    temp_name.as_str(),
                    &parent.fd,
                    parent.file_name.as_os_str(),
                )
                .map_err(|error| {
                    format!(
                        "原子替换 Provider 文件 {} 失败：{error}",
                        relative.display()
                    )
                })?;

                let destination = open_regular_file_required_at(
                    &parent.fd,
                    parent.file_name.as_os_str(),
                    relative,
                )?;
                let destination_display = self.canonical_path.join(relative);
                event(AtomicInstallPhase::BeforeFileSync, &destination_display)?;
                destination.sync_all().map_err(|error| {
                    format!("同步 Provider 文件 {} 失败：{error}", relative.display())
                })?;
                event(AtomicInstallPhase::BeforeParentSync, &destination_display)?;
                unix_fs::fsync(&parent.fd).map_err(|error| {
                    format!("同步 Provider 父目录 {} 失败：{error}", relative.display())
                })?;
                Ok(())
            })();

            if let Err(error) = result {
                let cleanup = match event(AtomicInstallPhase::CleanupTemp, &temp_display) {
                    Ok(()) => cleanup_unix_temp_file(
                        &temp_file,
                        &parent.fd,
                        temp_name.as_str(),
                        &temp_display,
                    ),
                    Err(cleanup_error) => Err(format!(
                        "Provider 临时文件清理失败，残留路径为 {}：{cleanup_error}",
                        temp_display.display()
                    )),
                };
                return Err(match cleanup {
                    Ok(()) => error,
                    Err(cleanup_error) => format!("{error}；{cleanup_error}"),
                });
            }
            return Ok(());
        }
        Err(format!(
            "无法为 Provider 目标创建唯一临时文件：{}",
            relative.display()
        ))
    }

    #[cfg(windows)]
    fn open_parent(&self, relative: &Path, create: bool) -> Result<PinnedParent, String> {
        self.open_parent_with_access(relative, create, true)
    }

    #[cfg(windows)]
    fn open_parent_with_access(
        &self,
        relative: &Path,
        create: bool,
        mutation: bool,
    ) -> Result<PinnedParent, String> {
        self.ensure_canonical_path_identity()?;
        let components = normal_components(relative)?;
        let (file_name, parents) = components
            .split_last()
            .ok_or_else(|| format!("Provider 相对路径为空：{}", relative.display()))?;
        let mut current = self
            .root
            .try_clone()
            .map_err(|error| format!("复制 Codex Home 目录句柄失败：{error}"))?;
        let mut relative_parent = PathBuf::new();
        for component in parents {
            let next = match windows_open_directory_relative(&current, component, mutation) {
                Ok(directory) => directory,
                Err(error) if create && error.kind() == std::io::ErrorKind::NotFound => {
                    match windows_create_directory_relative(&current, component) {
                        Ok(directory) => {
                            current.sync_all().map_err(|sync_error| {
                                format!(
                                    "同步新建 Provider 父目录项 {} 失败：{sync_error}",
                                    relative.display()
                                )
                            })?;
                            directory
                        }
                        Err(create_error)
                            if create_error.kind() == std::io::ErrorKind::AlreadyExists =>
                        {
                            windows_open_directory_relative(&current, component, true).map_err(
                                |open_error| {
                                    format!(
                                        "打开并发新建 Provider 父目录 {} 失败：{open_error}",
                                        relative.display()
                                    )
                                },
                            )?
                        }
                        Err(create_error) => {
                            return Err(format!(
                                "创建 Provider 父目录 {} 失败：{create_error}",
                                relative.display()
                            ))
                        }
                    }
                }
                Err(error) => {
                    return Err(format!(
                        "打开 Provider 父目录 {} 失败：{error}",
                        relative.display()
                    ))
                }
            };
            current = next;
            relative_parent.push(component);
        }
        Ok(PinnedParent {
            file: current,
            relative_parent,
            file_name: file_name.clone(),
        })
    }

    #[cfg(windows)]
    fn verify_windows_parent(&self, relative: &Path, parent: &PinnedParent) -> Result<(), String> {
        self.ensure_canonical_path_identity()?;
        let mut current = self
            .root
            .try_clone()
            .map_err(|error| format!("复制 Codex Home 目录句柄失败：{error}"))?;
        if !parent.relative_parent.as_os_str().is_empty() {
            for component in normal_components(&parent.relative_parent)? {
                current =
                    windows_open_directory_relative(&current, &component, true).map_err(|error| {
                        format!(
                            "Provider 父目录在操作期间被替换或重定向 {}：{error}",
                            relative.display()
                        )
                    })?;
            }
        }
        if windows_file_identity(&current)? != windows_file_identity(&parent.file)? {
            return Err(format!(
                "Provider 父目录在操作期间身份变化，已拒绝写入：{}",
                relative.display()
            ));
        }
        Ok(())
    }

    #[cfg(windows)]
    #[allow(clippy::too_many_arguments)]
    fn install_atomically_in_parent(
        &self,
        relative: &Path,
        parent: &PinnedParent,
        expected_size: Option<u64>,
        expected_checksum: Option<&str>,
        populate: &mut impl FnMut(&mut File) -> Result<(), String>,
        event: &mut impl FnMut(AtomicInstallPhase, &Path) -> Result<(), String>,
    ) -> Result<(), String> {
        let file_name = parent.file_name.to_string_lossy();
        event(
            AtomicInstallPhase::BeforeTempCreate,
            &self.canonical_path.join(relative),
        )?;
        self.verify_windows_parent(relative, parent)?;

        for _ in 0..ATOMIC_TEMP_ATTEMPTS {
            let sequence = ATOMIC_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let temp_name = OsString::from(format!(
                ".{file_name}.restore-{}-{sequence:020}.tmp",
                std::process::id()
            ));
            let mut temp_file = match windows_create_file_relative(&parent.file, &temp_name) {
                Ok(file) => file,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(format!(
                        "创建 Provider 临时文件 {} 失败：{error}",
                        self.canonical_path
                            .join(&parent.relative_parent)
                            .join(&temp_name)
                            .display()
                    ))
                }
            };
            let temp_display = self
                .canonical_path
                .join(&parent.relative_parent)
                .join(&temp_name);
            let mut renamed = false;

            let result = (|| {
                populate(&mut temp_file)?;
                temp_file
                    .sync_all()
                    .map_err(|error| format!("同步 Provider 临时文件失败：{error}"))?;
                event(AtomicInstallPhase::ValidateTemp, &temp_display)?;

                let mut verify_file = temp_file
                    .try_clone()
                    .map_err(|error| format!("复制 Provider 临时文件句柄失败：{error}"))?;
                let actual_size = verify_file
                    .metadata()
                    .map_err(|error| error.to_string())?
                    .len();
                let actual_checksum = expected_checksum
                    .map(|_| sha256_file(&mut verify_file))
                    .transpose()?;
                if expected_size.is_some_and(|expected| actual_size != expected)
                    || expected_checksum
                        .zip(actual_checksum.as_deref())
                        .is_some_and(|(expected, actual)| actual != expected)
                {
                    return Err(format!(
                        "Provider 临时文件在替换前 SHA-256 或大小校验失败：{}",
                        relative.display()
                    ));
                }

                event(AtomicInstallPhase::BeforeReplace, &temp_display)?;
                self.verify_windows_parent(relative, parent)?;
                windows_reject_existing_non_regular(&parent.file, &parent.file_name, relative)?;
                windows_verify_named_file_identity(
                    &parent.file,
                    &temp_name,
                    &temp_file,
                    &temp_display,
                )?;
                windows_rename_open_file(&temp_file, &parent.file, &parent.file_name, true)
                    .map_err(|error| {
                        format!(
                            "原子替换 Provider 文件 {} 失败：{error}",
                            relative.display()
                        )
                    })?;
                renamed = true;

                let destination = windows_open_regular_file_required_at(
                    &parent.file,
                    &parent.file_name,
                    relative,
                    windows_sync_file_access(),
                )?;
                if windows_file_identity(&destination)? != windows_file_identity(&temp_file)? {
                    return Err(format!(
                        "Provider 文件替换后身份不一致，已拒绝成功：{}",
                        relative.display()
                    ));
                }
                let destination_display = self.canonical_path.join(relative);
                event(AtomicInstallPhase::BeforeFileSync, &destination_display)?;
                destination.sync_all().map_err(|error| {
                    format!("同步 Provider 文件 {} 失败：{error}", relative.display())
                })?;
                event(AtomicInstallPhase::BeforeParentSync, &destination_display)?;
                parent.file.sync_all().map_err(|error| {
                    format!("同步 Provider 父目录 {} 失败：{error}", relative.display())
                })?;
                Ok(())
            })();

            if let Err(error) = result {
                if renamed {
                    return Err(error);
                }
                if let Err(cleanup_error) = event(AtomicInstallPhase::CleanupTemp, &temp_display) {
                    return Err(format!(
                        "{error}；Provider 临时文件清理失败，残留路径为 {}：{cleanup_error}",
                        temp_display.display()
                    ));
                }
                return Err(
                    match cleanup_windows_temp_file(
                        temp_file,
                        &parent.file,
                        &temp_name,
                        &temp_display,
                    ) {
                        Ok(()) => error,
                        Err(cleanup_error) => format!("{error}；{cleanup_error}"),
                    },
                );
            }
            return Ok(());
        }
        Err(format!(
            "无法为 Provider 目标创建唯一临时文件：{}",
            relative.display()
        ))
    }
}

impl PinnedStorageGuard {
    fn member_paths(&self) -> Vec<PathBuf> {
        self.members
            .iter()
            .map(|member| member.relative.clone())
            .collect()
    }
}

fn stable_account_key_from_auth_json(bytes: &[u8]) -> Option<String> {
    let auth: serde_json::Value = serde_json::from_slice(bytes).ok()?;
    let id_token = auth
        .get("tokens")
        .and_then(|tokens| tokens.get("id_token"))
        .and_then(serde_json::Value::as_str)?;
    let payload = id_token.split('.').nth(1)?;
    let payload: serde_json::Value =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).ok()?).ok()?;
    [
        ("sub", "sub:"),
        ("account_id", "account:"),
        ("accountId", "account:"),
    ]
    .into_iter()
    .find_map(|(key, prefix)| {
        payload
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| format!("{prefix}{value}"))
    })
}

#[cfg(unix)]
struct PinnedParent {
    fd: OwnedFd,
    relative_parent: PathBuf,
    file_name: std::ffi::OsString,
}

#[cfg(windows)]
struct PinnedParent {
    file: File,
    relative_parent: PathBuf,
    file_name: OsString,
}

#[cfg(unix)]
fn open_absolute_directory_without_following(path: &Path) -> Result<OwnedFd, String> {
    let mut current = unix_fs::open(
        Path::new("/"),
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| format!("打开文件系统根目录失败：{error}"))?;
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(part) => {
                current = unix_fs::openat(
                    &current,
                    part,
                    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                    Mode::empty(),
                )
                .map_err(|error| {
                    format!(
                        "固定 Codex Home 目录组件 {} 失败，已拒绝路径跟随：{error}",
                        path.display()
                    )
                })?;
            }
            _ => return Err(format!("Codex Home 规范路径无效：{}", path.display())),
        }
    }
    Ok(current)
}

#[cfg(any(unix, windows))]
fn logical_member_key(path: &Path) -> Result<String, String> {
    let components = normal_components(path)?;
    let key = components
        .iter()
        .map(|component| {
            component
                .to_str()
                .ok_or_else(|| format!("Provider 成员路径不是有效 UTF-8：{}", path.display()))
        })
        .collect::<Result<Vec<_>, _>>()?
        .join("/");
    #[cfg(windows)]
    let key = key.to_lowercase();
    Ok(key)
}

#[cfg(unix)]
pub(super) fn physical_file_identity(file: &File) -> Result<PhysicalFileIdentity, String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    Ok(PhysicalFileIdentity::Unix {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

#[cfg(windows)]
pub(super) fn physical_file_identity(file: &File) -> Result<PhysicalFileIdentity, String> {
    let identity = windows_file_identity(file)?;
    Ok(PhysicalFileIdentity::Windows {
        volume_serial_number: identity.volume_serial_number,
        file_id: identity.file_id,
    })
}

fn read_first_line_bytes(file: &mut File, diagnostic: &Path) -> Result<Vec<u8>, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("定位 Provider 文件 {} 失败：{error}", diagnostic.display()))?;
    let mut first_line = Vec::new();
    BufReader::new(&mut *file)
        .read_until(b'\n', &mut first_line)
        .map_err(|error| format!("读取 Provider 文件首行 {} 失败：{error}", diagnostic.display()))?;
    Ok(first_line)
}

#[cfg(unix)]
fn reject_physical_alias(file: &File, diagnostic: &Path) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    if file.metadata().map_err(|error| error.to_string())?.nlink() > 1 {
        return Err(format!(
            "Provider 成员是 hard link 物理别名，已拒绝写入：{}",
            diagnostic.display()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn reject_physical_alias(file: &File, diagnostic: &Path) -> Result<(), String> {
    if windows_file_link_count(file)? > 1 {
        return Err(format!(
            "Provider 成员是 hard link 物理别名，已拒绝写入：{}",
            diagnostic.display()
        ));
    }
    Ok(())
}

#[cfg(any(unix, windows))]
fn normal_components(path: &Path) -> Result<Vec<std::ffi::OsString>, String> {
    if path.as_os_str().is_empty() || path.is_absolute() {
        return Err(format!("Provider 相对路径无效：{}", path.display()));
    }
    path.components()
        .map(|component| match component {
            Component::Normal(part) => Ok(part.to_os_string()),
            _ => Err(format!("Provider 相对路径无效：{}", path.display())),
        })
        .collect()
}

#[cfg(windows)]
pub(super) fn windows_extended_length_path(path: &Path) -> Result<Vec<u16>, String> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err(format!(
            "Windows 文件操作要求无点组件的绝对路径：{}",
            path.display()
        ));
    }

    let mut path_wide = path.as_os_str().encode_wide().collect::<Vec<_>>();
    if path_wide.is_empty() || path_wide.contains(&0) {
        return Err(format!("Windows 文件操作路径无效：{}", path.display()));
    }
    for unit in &mut path_wide {
        if *unit == u16::from(b'/') {
            *unit = u16::from(b'\\');
        }
    }

    let slash = u16::from(b'\\');
    let question = u16::from(b'?');
    let dot = u16::from(b'.');
    let has_verbatim_prefix = path_wide.starts_with(&[slash, slash, question, slash]);
    let has_device_prefix = path_wide.starts_with(&[slash, slash, dot, slash]);
    let mut wide = if has_verbatim_prefix || has_device_prefix {
        path_wide
    } else if path_wide.starts_with(&[slash, slash]) {
        "\\\\?\\UNC\\"
            .encode_utf16()
            .chain(path_wide.into_iter().skip(2))
            .collect()
    } else {
        "\\\\?\\".encode_utf16().chain(path_wide).collect()
    };
    wide.push(0);
    Ok(wide)
}

#[cfg(unix)]
fn open_regular_file_at(
    parent: &OwnedFd,
    file_name: &std::ffi::OsStr,
    diagnostic: &Path,
) -> Result<Option<File>, String> {
    match unix_fs::openat(
        parent,
        file_name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(fd) => {
            let file = File::from(fd);
            let metadata = file.metadata().map_err(|error| error.to_string())?;
            if !metadata.is_file() {
                return Err(format!(
                    "Provider 成员不是普通文件：{}",
                    diagnostic.display()
                ));
            }
            Ok(Some(file))
        }
        Err(error) if error == rustix::io::Errno::NOENT => Ok(None),
        Err(error) => Err(format!(
            "打开 Provider 文件 {} 失败，已拒绝符号链接：{error}",
            diagnostic.display()
        )),
    }
}

#[cfg(unix)]
fn open_regular_file_required_at(
    parent: &OwnedFd,
    file_name: &std::ffi::OsStr,
    diagnostic: &Path,
) -> Result<File, String> {
    open_regular_file_at(parent, file_name, diagnostic)?
        .ok_or_else(|| format!("Provider 文件不存在：{}", diagnostic.display()))
}

#[cfg(unix)]
fn reject_existing_non_regular(
    parent: &OwnedFd,
    file_name: &std::ffi::OsStr,
    diagnostic: &Path,
) -> Result<(), String> {
    let _ = open_regular_file_at(parent, file_name, diagnostic)?;
    Ok(())
}

#[cfg(windows)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct WindowsFileIdentity {
    volume_serial_number: u64,
    file_id: [u8; 16],
}

#[cfg(windows)]
fn windows_read_file_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::FILE_GENERIC_READ;
    FILE_GENERIC_READ
}

#[cfg(windows)]
fn windows_delete_file_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{DELETE, FILE_GENERIC_READ};
    FILE_GENERIC_READ | DELETE
}

#[cfg(windows)]
fn windows_sync_file_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{FILE_GENERIC_READ, FILE_GENERIC_WRITE};
    FILE_GENERIC_READ | FILE_GENERIC_WRITE
}

#[cfg(windows)]
fn windows_directory_read_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_LIST_DIRECTORY, FILE_READ_ATTRIBUTES, FILE_TRAVERSE, SYNCHRONIZE,
    };
    FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | FILE_TRAVERSE | SYNCHRONIZE
}

#[cfg(windows)]
fn windows_directory_mutation_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_DELETE_CHILD, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    };
    FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_DELETE_CHILD
}

#[cfg(windows)]
fn open_windows_absolute_directory_without_following(path: &Path) -> Result<File, String> {
    let (drive, components) = windows_local_drive_components(path)?;
    if components.is_empty() {
        return Err(format!(
            "Codex Home 不能是 Windows 卷根目录：{}",
            path.display()
        ));
    }
    let mut current = windows_open_drive_root(drive)?;
    for component in components.iter() {
        let desired_access = windows_directory_read_access();
        current = windows_nt_open_relative(
            &current,
            component,
            desired_access,
            windows_sys::Wdk::Storage::FileSystem::FILE_OPEN,
            windows_sys::Wdk::Storage::FileSystem::FILE_DIRECTORY_FILE
                | windows_sys::Wdk::Storage::FileSystem::FILE_OPEN_REPARSE_POINT
                | windows_sys::Wdk::Storage::FileSystem::FILE_SYNCHRONOUS_IO_NONALERT,
            windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_NORMAL,
        )
        .map_err(|error| format_windows_directory_open_error(path, error))?;
        windows_require_directory_without_reparse(&current, path)?;
    }
    Ok(current)
}

#[cfg(windows)]
fn format_windows_directory_open_error(path: &Path, error: std::io::Error) -> String {
    if error.kind() == std::io::ErrorKind::PermissionDenied {
        return format!(
            "固定 Codex Home 目录组件 {} 失败：Windows 拒绝访问。请确认当前用户对该目录至少有读取权限；执行修复/同步还需要修改权限。",
            path.display()
        );
    }
    format!("固定 Codex Home 目录组件 {} 失败：{error}", path.display())
}

#[cfg(windows)]
fn windows_local_drive_components(path: &Path) -> Result<(u8, Vec<OsString>), String> {
    use std::path::Prefix;

    let mut components = path.components();
    let drive = match components.next() {
        Some(Component::Prefix(prefix)) => match prefix.kind() {
            Prefix::Disk(drive) | Prefix::VerbatimDisk(drive) => drive,
            _ => {
                return Err(format!(
                    "Windows Provider 仅支持本地磁盘上的 Codex Home，已拒绝 UNC/设备路径：{}",
                    path.display()
                ))
            }
        },
        _ => {
            return Err(format!(
                "Windows Codex Home 缺少本地磁盘前缀：{}",
                path.display()
            ))
        }
    };
    if !matches!(components.next(), Some(Component::RootDir)) {
        return Err(format!(
            "Windows Codex Home 不是绝对路径：{}",
            path.display()
        ));
    }
    let remaining = components
        .map(|component| match component {
            Component::Normal(part) => Ok(part.to_os_string()),
            _ => Err(format!("Windows Codex Home 路径无效：{}", path.display())),
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok((drive, remaining))
}

#[cfg(windows)]
fn windows_open_drive_root(drive: u8) -> Result<File, String> {
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE,
        FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
    };

    let path = OsString::from(format!(r"\\?\{}:\", char::from(drive)));
    let wide = path
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            windows_directory_read_access(),
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(format!(
            "打开 Windows 卷根目录 {} 失败：{}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let file = unsafe { File::from_raw_handle(handle as RawHandle) };
    windows_require_directory_without_reparse(&file, Path::new(&path))?;
    Ok(file)
}

#[cfg(windows)]
fn windows_nt_open_relative(
    parent: &File,
    name: &OsStr,
    desired_access: u32,
    create_disposition: u32,
    create_options: u32,
    file_attributes: u32,
) -> std::io::Result<File> {
    use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
    use windows_sys::Wdk::Storage::FileSystem::NtCreateFile;
    use windows_sys::Win32::Foundation::{
        RtlNtStatusToDosError, HANDLE, OBJ_CASE_INSENSITIVE, UNICODE_STRING,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;

    let mut wide = name.encode_wide().collect::<Vec<_>>();
    if wide.is_empty() || wide.iter().any(|unit| *unit == 0) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Windows Provider 成员名为空或包含 NUL",
        ));
    }
    let byte_length = wide
        .len()
        .checked_mul(std::mem::size_of::<u16>())
        .and_then(|length| u16::try_from(length).ok())
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Windows Provider 成员名过长",
            )
        })?;
    let name = UNICODE_STRING {
        Length: byte_length,
        MaximumLength: byte_length,
        Buffer: wide.as_mut_ptr(),
    };
    let attributes = OBJECT_ATTRIBUTES {
        Length: u32::try_from(std::mem::size_of::<OBJECT_ATTRIBUTES>()).unwrap_or(u32::MAX),
        RootDirectory: parent.as_raw_handle() as HANDLE,
        ObjectName: &name,
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: std::ptr::null(),
        SecurityQualityOfService: std::ptr::null(),
    };
    let mut io_status = IO_STATUS_BLOCK::default();
    let mut handle: HANDLE = std::ptr::null_mut();
    let status = unsafe {
        NtCreateFile(
            &mut handle,
            desired_access,
            &attributes,
            &mut io_status,
            std::ptr::null(),
            file_attributes,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            create_disposition,
            create_options,
            std::ptr::null(),
            0,
        )
    };
    if status < 0 {
        let code = unsafe { RtlNtStatusToDosError(status) };
        return Err(std::io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ));
    }
    if handle.is_null() {
        return Err(std::io::Error::other(
            "NtCreateFile 成功但未返回 Windows 文件句柄",
        ));
    }
    Ok(unsafe { File::from_raw_handle(handle as RawHandle) })
}

#[cfg(windows)]
fn windows_open_directory_relative(
    parent: &File,
    name: &OsStr,
    mutation: bool,
) -> std::io::Result<File> {
    let directory = windows_nt_open_relative(
        parent,
        name,
        if mutation {
            windows_directory_mutation_access()
        } else {
            windows_directory_read_access()
        },
        windows_sys::Wdk::Storage::FileSystem::FILE_OPEN,
        windows_sys::Wdk::Storage::FileSystem::FILE_DIRECTORY_FILE
            | windows_sys::Wdk::Storage::FileSystem::FILE_OPEN_REPARSE_POINT
            | windows_sys::Wdk::Storage::FileSystem::FILE_SYNCHRONOUS_IO_NONALERT,
        windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_NORMAL,
    )?;
    windows_require_directory_without_reparse(&directory, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(directory)
}

#[cfg(windows)]
fn windows_create_directory_relative(parent: &File, name: &OsStr) -> std::io::Result<File> {
    let directory = windows_nt_open_relative(
        parent,
        name,
        windows_directory_mutation_access(),
        windows_sys::Wdk::Storage::FileSystem::FILE_CREATE,
        windows_sys::Wdk::Storage::FileSystem::FILE_DIRECTORY_FILE
            | windows_sys::Wdk::Storage::FileSystem::FILE_OPEN_REPARSE_POINT
            | windows_sys::Wdk::Storage::FileSystem::FILE_SYNCHRONOUS_IO_NONALERT
            | windows_sys::Wdk::Storage::FileSystem::FILE_WRITE_THROUGH,
        windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_DIRECTORY,
    )?;
    windows_require_directory_without_reparse(&directory, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(directory)
}

#[cfg(windows)]
fn windows_create_file_relative(parent: &File, name: &OsStr) -> std::io::Result<File> {
    use windows_sys::Win32::Storage::FileSystem::{
        DELETE, FILE_ATTRIBUTE_NORMAL, FILE_GENERIC_READ, FILE_GENERIC_WRITE, SYNCHRONIZE,
    };

    let file = windows_nt_open_relative(
        parent,
        name,
        FILE_GENERIC_READ | FILE_GENERIC_WRITE | DELETE | SYNCHRONIZE,
        windows_sys::Wdk::Storage::FileSystem::FILE_CREATE,
        windows_sys::Wdk::Storage::FileSystem::FILE_NON_DIRECTORY_FILE
            | windows_sys::Wdk::Storage::FileSystem::FILE_OPEN_REPARSE_POINT
            | windows_sys::Wdk::Storage::FileSystem::FILE_SYNCHRONOUS_IO_NONALERT
            | windows_sys::Wdk::Storage::FileSystem::FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_NORMAL,
    )?;
    windows_require_regular_without_reparse(&file, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(file)
}

#[cfg(windows)]
fn windows_open_regular_file_at(
    parent: &File,
    file_name: &OsStr,
    diagnostic: &Path,
    desired_access: u32,
) -> Result<Option<File>, String> {
    match windows_nt_open_relative(
        parent,
        file_name,
        desired_access,
        windows_sys::Wdk::Storage::FileSystem::FILE_OPEN,
        windows_sys::Wdk::Storage::FileSystem::FILE_NON_DIRECTORY_FILE
            | windows_sys::Wdk::Storage::FileSystem::FILE_OPEN_REPARSE_POINT
            | windows_sys::Wdk::Storage::FileSystem::FILE_SYNCHRONOUS_IO_NONALERT,
        windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_NORMAL,
    ) {
        Ok(file) => {
            windows_require_regular_without_reparse(&file, diagnostic)?;
            Ok(Some(file))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!(
            "打开 Provider 文件 {} 失败，已拒绝重解析点或非普通文件：{error}",
            diagnostic.display()
        )),
    }
}

#[cfg(windows)]
fn windows_open_regular_file_required_at(
    parent: &File,
    file_name: &OsStr,
    diagnostic: &Path,
    desired_access: u32,
) -> Result<File, String> {
    windows_open_regular_file_at(parent, file_name, diagnostic, desired_access)?
        .ok_or_else(|| format!("Provider 文件不存在：{}", diagnostic.display()))
}

#[cfg(windows)]
fn windows_reject_existing_non_regular(
    parent: &File,
    file_name: &OsStr,
    diagnostic: &Path,
) -> Result<(), String> {
    let _ =
        windows_open_regular_file_at(parent, file_name, diagnostic, windows_read_file_access())?;
    Ok(())
}

#[cfg(windows)]
fn windows_file_attributes(file: &File) -> Result<u32, String> {
    use windows_sys::Win32::Storage::FileSystem::{
        FileAttributeTagInfo, GetFileInformationByHandleEx, FILE_ATTRIBUTE_TAG_INFO,
    };

    let mut info = FILE_ATTRIBUTE_TAG_INFO::default();
    let succeeded = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileAttributeTagInfo,
            (&mut info as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_ATTRIBUTE_TAG_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if succeeded == 0 {
        return Err(format!(
            "读取 Windows Provider 文件属性失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(info.FileAttributes)
}

#[cfg(windows)]
fn windows_require_directory_without_reparse(file: &File, diagnostic: &Path) -> Result<(), String> {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
    };

    let attributes = windows_file_attributes(file)?;
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!(
            "拒绝 Windows Provider 目录重解析点：{}",
            diagnostic.display()
        ));
    }
    if attributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(format!(
            "Windows Provider 成员不是目录：{}",
            diagnostic.display()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn windows_require_regular_without_reparse(file: &File, diagnostic: &Path) -> Result<(), String> {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
    };

    let attributes = windows_file_attributes(file)?;
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!(
            "拒绝 Windows Provider 文件重解析点：{}",
            diagnostic.display()
        ));
    }
    if attributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(format!(
            "Windows Provider 成员不是普通文件：{}",
            diagnostic.display()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn windows_file_identity(file: &File) -> Result<WindowsFileIdentity, String> {
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
            "读取 Windows Provider 文件身份失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(WindowsFileIdentity {
        volume_serial_number: info.VolumeSerialNumber,
        file_id: info.FileId.Identifier,
    })
}

#[cfg(windows)]
fn windows_file_link_count(file: &File) -> Result<u32, String> {
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
            "读取 Windows Provider hard link 计数失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(info.NumberOfLinks)
}

#[cfg(windows)]
fn windows_verify_named_file_identity(
    parent: &File,
    name: &OsStr,
    expected: &File,
    diagnostic: &Path,
) -> Result<(), String> {
    let named = windows_open_regular_file_required_at(
        parent,
        name,
        diagnostic,
        windows_read_file_access(),
    )?;
    if windows_file_identity(&named)? != windows_file_identity(expected)? {
        return Err(format!(
            "Windows Provider 临时文件名已指向不同文件，残留路径可能为 {}",
            diagnostic.display()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn windows_rename_open_file(
    file: &File,
    destination_parent: &File,
    destination_name: &OsStr,
    replace_existing: bool,
) -> std::io::Result<()> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FileRenameInformationEx, NtSetInformationFile, FILE_RENAME_INFORMATION,
        FILE_RENAME_INFORMATION_0, FILE_RENAME_POSIX_SEMANTICS,
        FILE_RENAME_REPLACE_IF_EXISTS,
    };
    use windows_sys::Win32::Foundation::RtlNtStatusToDosError;
    use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;

    let name = destination_name.encode_wide().collect::<Vec<_>>();
    let name_bytes = name
        .len()
        .checked_mul(std::mem::size_of::<u16>())
        .ok_or_else(|| std::io::Error::other("Windows Provider 目标文件名过长"))?;
    let buffer_bytes = std::mem::offset_of!(FILE_RENAME_INFORMATION, FileName)
        .checked_add(name_bytes)
        .ok_or_else(|| std::io::Error::other("Windows Provider rename 缓冲区溢出"))?;
    let words = buffer_bytes.div_ceil(std::mem::size_of::<usize>());
    let mut buffer = vec![0_usize; words];
    let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFORMATION>();
    unsafe {
        (*info).Anonymous = FILE_RENAME_INFORMATION_0 {
            Flags: FILE_RENAME_POSIX_SEMANTICS
                | if replace_existing {
                    FILE_RENAME_REPLACE_IF_EXISTS
                } else {
                    0
                },
        };
        (*info).RootDirectory = destination_parent.as_raw_handle() as _;
        (*info).FileNameLength = u32::try_from(name_bytes)
            .map_err(|_| std::io::Error::other("Windows Provider 目标文件名过长"))?;
        std::ptr::copy_nonoverlapping(name.as_ptr(), (*info).FileName.as_mut_ptr(), name.len());
    }
    let mut io_status = IO_STATUS_BLOCK::default();
    let status = unsafe {
        NtSetInformationFile(
            file.as_raw_handle() as _,
            &mut io_status,
            info.cast(),
            u32::try_from(buffer_bytes)
                .map_err(|_| std::io::Error::other("Windows Provider rename 缓冲区过长"))?,
            FileRenameInformationEx,
        )
    };
    if status < 0 {
        let code = unsafe { RtlNtStatusToDosError(status) };
        return Err(std::io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn windows_delete_open_file(file: &File) -> std::io::Result<()> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FileDispositionInformation, NtSetInformationFile, FILE_DISPOSITION_INFORMATION,
    };
    use windows_sys::Win32::Foundation::RtlNtStatusToDosError;
    use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;

    let disposition = FILE_DISPOSITION_INFORMATION { DeleteFile: true };
    let mut io_status = IO_STATUS_BLOCK::default();
    let status = unsafe {
        NtSetInformationFile(
            file.as_raw_handle() as _,
            &mut io_status,
            (&disposition as *const FILE_DISPOSITION_INFORMATION).cast(),
            u32::try_from(std::mem::size_of::<FILE_DISPOSITION_INFORMATION>()).unwrap_or(u32::MAX),
            FileDispositionInformation,
        )
    };
    if status < 0 {
        let code = unsafe { RtlNtStatusToDosError(status) };
        return Err(std::io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn cleanup_unix_temp_file(
    file: &File,
    parent: &OwnedFd,
    name: &str,
    diagnostic: &Path,
) -> Result<(), String> {
    if let Some(named) = open_regular_file_at(parent, name.as_ref(), diagnostic)? {
        if physical_file_identity(&named)? != physical_file_identity(file)? {
            return Err(format!(
                "Provider 临时文件名称已指向其他物理文件，拒绝误删；残留路径为 {}",
                diagnostic.display()
            ));
        }
        unix_fs::unlinkat(parent, name, AtFlags::empty()).map_err(|error| {
            format!(
                "Provider 临时文件清理失败，残留路径为 {}：{error}",
                diagnostic.display()
            )
        })?;
    }
    unix_fs::fsync(parent).map_err(|error| {
        format!(
            "Provider 临时文件已删除但父目录同步失败，残留可能恢复于 {}：{error}",
            diagnostic.display()
        )
    })?;
    if open_regular_file_at(parent, name.as_ref(), diagnostic)?.is_some() {
        return Err(format!(
            "Provider 临时文件清理后仍存在，残留路径为 {}",
            diagnostic.display()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn cleanup_windows_temp_file(
    file: File,
    parent: &File,
    name: &OsStr,
    diagnostic: &Path,
) -> Result<(), String> {
    match windows_open_regular_file_at(parent, name, diagnostic, windows_read_file_access()) {
        Ok(Some(named)) => {
            if windows_file_identity(&named)? != windows_file_identity(&file)? {
                return Err(format!(
                    "Provider 临时文件名称已指向其他物理文件，拒绝误删；残留路径为 {}",
                    diagnostic.display()
                ));
            }
        }
        Ok(None) => {
            // The owned file may already be delete-pending after a concurrent
            // unlink. Closing our last handle completes that safe deletion.
            drop(file);
            parent.sync_all().map_err(|error| {
                format!(
                    "Provider 临时文件已删除但父目录同步失败，残留可能恢复于 {}：{error}",
                    diagnostic.display()
                )
            })?;
            return Ok(());
        }
        Err(error) => {
            return Err(format!(
                "Provider 临时文件清理状态无法确认，残留路径为 {}：{error}",
                diagnostic.display()
            ))
        }
    }
    windows_delete_open_file(&file).map_err(|error| {
        format!(
            "Provider 临时文件清理失败，残留路径为 {}：{error}",
            diagnostic.display()
        )
    })?;
    drop(file);
    match windows_open_regular_file_at(parent, name, diagnostic, windows_read_file_access()) {
        Ok(None) => {}
        Ok(Some(_)) => {
            return Err(format!(
                "Provider 临时文件清理后仍存在，残留路径为 {}",
                diagnostic.display()
            ))
        }
        Err(error) => {
            return Err(format!(
                "Provider 临时文件清理状态无法确认，残留路径为 {}：{error}",
                diagnostic.display()
            ))
        }
    }
    parent.sync_all().map_err(|error| {
        format!(
            "Provider 临时文件已删除但父目录同步失败，残留可能恢复于 {}：{error}",
            diagnostic.display()
        )
    })
}

fn sha256_file(file: &mut File) -> Result<String, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|error| error.to_string())?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::format_windows_directory_open_error;
    use std::path::Path;

    #[test]
    fn permission_denied_does_not_claim_a_reparse_point() {
        let message = format_windows_directory_open_error(
            Path::new(r"\\?\D:\CodexHome"),
            std::io::Error::from_raw_os_error(5),
        );
        assert!(message.contains("Windows 拒绝访问"));
        assert!(!message.contains("重解析点"));
    }
}
