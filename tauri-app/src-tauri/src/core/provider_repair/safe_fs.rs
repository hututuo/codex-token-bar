use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(target_os = "linux")]
use rustix::fd::AsRawFd;
#[cfg(unix)]
use rustix::fd::OwnedFd;
#[cfg(unix)]
use rustix::fs::{self as unix_fs, AtFlags, Mode, OFlags};

const ATOMIC_TEMP_ATTEMPTS: usize = 64;
static ATOMIC_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AtomicInstallPhase {
    BeforeTempCreate,
    ValidateTemp,
    BeforeReplace,
    BeforeFileSync,
    BeforeParentSync,
}

#[cfg(any(test, not(unix)))]
pub(super) fn provider_mutation_support_for_platform(platform: &str) -> Result<(), String> {
    if platform.eq_ignore_ascii_case("windows") {
        Err(
            "Windows Provider 写操作已安全拒绝：当前源码尚未实现重解析点感知的 handle-relative 替换与文件身份校验。"
                .into(),
        )
    } else {
        Ok(())
    }
}

#[cfg(not(unix))]
fn unsupported_platform_error() -> String {
    provider_mutation_support_for_platform("windows").unwrap_err()
}

pub(super) struct PinnedHome {
    canonical_path: PathBuf,
    #[cfg(unix)]
    root: OwnedFd,
}

impl PinnedHome {
    pub(super) fn open(path: &Path) -> Result<Self, String> {
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

        #[cfg(not(unix))]
        {
            let _ = canonical_path;
            Err(unsupported_platform_error())
        }
    }

    pub(super) fn canonical_path(&self) -> &Path {
        &self.canonical_path
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
        #[cfg(not(unix))]
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
        #[cfg(not(unix))]
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

    pub(super) fn open_file(&self, relative: &Path) -> Result<Option<File>, String> {
        #[cfg(unix)]
        {
            let parent = self.open_parent(relative, false)?;
            return open_regular_file_at(&parent.fd, &parent.file_name, relative);
        }
        #[cfg(not(unix))]
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

    #[allow(clippy::too_many_arguments)]
    pub(super) fn install_atomically(
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
        #[cfg(not(unix))]
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
        #[cfg(not(unix))]
        {
            let _ = (relative, &mut transform, &mut event);
            Err(unsupported_platform_error())
        }
    }

    pub(super) fn remove_file(
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
        #[cfg(not(unix))]
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
                let actual_checksum = sha256_file(&mut verify_file)?;
                if expected_size.is_some_and(|expected| actual_size != expected)
                    || expected_checksum.is_some_and(|expected| actual_checksum != expected)
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

            if result.is_err() {
                let _ = unix_fs::unlinkat(&parent.fd, temp_name.as_str(), AtFlags::empty());
                let _ = unix_fs::fsync(&parent.fd);
            }
            return result;
        }
        Err(format!(
            "无法为 Provider 目标创建唯一临时文件：{}",
            relative.display()
        ))
    }
}

#[cfg(unix)]
struct PinnedParent {
    fd: OwnedFd,
    relative_parent: PathBuf,
    file_name: std::ffi::OsString,
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

#[cfg(unix)]
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
