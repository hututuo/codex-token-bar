use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

#[cfg(unix)]
use rustix::fs::{self as unix_fs, AtFlags, Mode, OFlags};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};
#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;
#[cfg(windows)]
use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle};

const ANCHOR_NAME: &str = ".codex-token-bar-coordination-v1.json";
const ANCHOR_SCHEMA_VERSION: u32 = 1;
const SESSION_LOCK_DIRECTORY: &str = "backups_state/codex-token-bar";
const AUTO_RESUME_DIRECTORY: &str = ".codex-token-bar-auto-resume/v1";
const THREAD_LEASES_DIRECTORY: &str = ".codex-token-bar-auto-resume/v1/leases";
const TEMP_ATTEMPTS: usize = 64;

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct CoordinationAnchor {
    schema_version: u32,
    directories: BTreeMap<String, String>,
}

/// A descriptor-pinned Codex Home plus the immutable physical identities of
/// every directory used for session-operation and auto-resume coordination.
///
/// The legacy relative paths are intentionally preserved so Swift and Tauri
/// continue to share the same lock and thread-lease namespace.
pub(crate) struct CoordinationHome {
    canonical_path: PathBuf,
    root: File,
    root_identity: String,
    anchor: CoordinationAnchor,
}

pub(crate) struct CoordinationDirectory {
    canonical_home: PathBuf,
    root: File,
    relative: PathBuf,
    directory: File,
    expected_identity: String,
}

impl CoordinationHome {
    pub(crate) fn open(codex_home: &Path) -> Result<Self, String> {
        let canonical_path = codex_home
            .canonicalize()
            .map_err(|error| format!("无法固定 Codex Home {}：{error}", codex_home.display()))?;
        let root = open_absolute_directory_without_following(&canonical_path)?;
        let root_identity = directory_identity(&root)?;

        let mut directories = BTreeMap::new();
        for relative in [
            SESSION_LOCK_DIRECTORY,
            AUTO_RESUME_DIRECTORY,
            THREAD_LEASES_DIRECTORY,
        ] {
            let directory = open_or_create_directory_all(&root, Path::new(relative))?;
            directories.insert(relative.to_string(), directory_identity(&directory)?);
        }
        let observed = CoordinationAnchor {
            schema_version: ANCHOR_SCHEMA_VERSION,
            directories,
        };
        let anchor = establish_anchor(&root, &observed)?;
        let home = Self {
            canonical_path,
            root,
            root_identity,
            anchor,
        };
        home.validate()?;
        Ok(home)
    }

    pub(crate) fn try_clone(&self) -> Result<Self, String> {
        Ok(Self {
            canonical_path: self.canonical_path.clone(),
            root: self
                .root
                .try_clone()
                .map_err(|error| format!("复制 Codex Home 协调句柄失败：{error}"))?,
            root_identity: self.root_identity.clone(),
            anchor: self.anchor.clone(),
        })
    }

    pub(crate) fn validate_requested_path(&self, requested_path: &Path) -> Result<(), String> {
        let canonical_path = requested_path.canonicalize().map_err(|error| {
            format!(
                "自动续跑请求的 Codex Home {} 已无法重新解析：{error}",
                requested_path.display()
            )
        })?;
        let current =
            open_absolute_directory_without_following(&canonical_path).map_err(|error| {
                format!(
                    "自动续跑请求的 Codex Home {} 已无法安全固定：{error}",
                    requested_path.display()
                )
            })?;
        if directory_identity(&current)? != self.root_identity {
            return Err("自动续跑请求的 Codex Home 已切换到不同物理目录".into());
        }
        Ok(())
    }

    pub(crate) fn configure_pinned_codex_home(
        &self,
        command: &mut std::process::Command,
    ) -> Result<(), String> {
        self.validate()?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            use std::os::unix::process::CommandExt;

            let root = self
                .root
                .try_clone()
                .map_err(|error| format!("复制 Codex Home 子进程根句柄失败：{error}"))?;
            command.env("CODEX_HOME", ".");
            // SAFETY: the closure only calls async-signal-safe fchdir with an
            // already-open descriptor. The descriptor is captured by value and
            // remains alive until Command::spawn reaches pre-exec.
            unsafe {
                command.pre_exec(move || {
                    if libc::fchdir(root.as_raw_fd()) == 0 {
                        Ok(())
                    } else {
                        Err(std::io::Error::last_os_error())
                    }
                });
            }
        }
        #[cfg(not(unix))]
        {
            command.env("CODEX_HOME", &self.canonical_path);
        }
        Ok(())
    }

    pub(crate) fn validate(&self) -> Result<(), String> {
        let current_home = open_absolute_directory_without_following(&self.canonical_path)
            .map_err(|error| format!("Codex Home 协调根的规范路径已变化，已拒绝继续：{error}"))?;
        if directory_identity(&current_home)? != self.root_identity {
            return Err("Codex Home 协调根已指向不同物理目录，已拒绝继续".into());
        }
        let anchor = read_anchor(&self.root)?
            .ok_or_else(|| "Codex Home 协调根锚点已消失，已拒绝继续".to_string())?;
        if anchor != self.anchor {
            return Err("Codex Home 协调根锚点已变化，已拒绝继续".into());
        }
        for (relative, expected_identity) in &self.anchor.directories {
            let current = open_directory_all(&self.root, Path::new(relative))
                .map_err(|error| format!("协调目录 {relative} 已被替换或无法安全打开：{error}"))?;
            if directory_identity(&current)? != *expected_identity {
                return Err(format!(
                    "协调目录 {relative} 的物理身份已变化，已拒绝拆分互斥域"
                ));
            }
        }
        Ok(())
    }

    pub(crate) fn session_lock_directory(&self) -> Result<CoordinationDirectory, String> {
        self.directory(Path::new(SESSION_LOCK_DIRECTORY))
    }

    pub(crate) fn auto_resume_directory(&self) -> Result<CoordinationDirectory, String> {
        self.directory(Path::new(AUTO_RESUME_DIRECTORY))
    }

    pub(crate) fn thread_leases_directory(&self) -> Result<CoordinationDirectory, String> {
        self.directory(Path::new(THREAD_LEASES_DIRECTORY))
    }

    fn directory(&self, relative: &Path) -> Result<CoordinationDirectory, String> {
        self.validate()?;
        let relative_key = relative_key(relative)?;
        let expected_identity = self
            .anchor
            .directories
            .get(&relative_key)
            .cloned()
            .ok_or_else(|| format!("协调目录未登记到物理锚点：{relative_key}"))?;
        let directory = open_directory_all(&self.root, relative)?;
        if directory_identity(&directory)? != expected_identity {
            return Err(format!(
                "协调目录 {relative_key} 的物理身份已变化，已拒绝继续"
            ));
        }
        Ok(CoordinationDirectory {
            canonical_home: self.canonical_path.clone(),
            root: self
                .root
                .try_clone()
                .map_err(|error| format!("复制 Codex Home 协调句柄失败：{error}"))?,
            relative: relative.to_path_buf(),
            directory,
            expected_identity,
        })
    }
}

impl CoordinationDirectory {
    pub(crate) fn try_clone(&self) -> Result<Self, String> {
        Ok(Self {
            canonical_home: self.canonical_home.clone(),
            root: self
                .root
                .try_clone()
                .map_err(|error| format!("复制协调根句柄失败：{error}"))?,
            relative: self.relative.clone(),
            directory: self
                .directory
                .try_clone()
                .map_err(|error| format!("复制协调目录句柄失败：{error}"))?,
            expected_identity: self.expected_identity.clone(),
        })
    }

    #[cfg(test)]
    pub(crate) fn display_path(&self) -> PathBuf {
        self.canonical_home.join(&self.relative)
    }

    pub(crate) fn same_physical_directory(&self, other: &Self) -> bool {
        self.expected_identity == other.expected_identity
    }

    pub(crate) fn verify_current(&self) -> Result<(), String> {
        let current = open_directory_all(&self.root, &self.relative).map_err(|error| {
            format!(
                "协调目录 {} 已无法从固定 Codex Home 安全打开：{error}",
                self.relative.display()
            )
        })?;
        if directory_identity(&current)? != self.expected_identity
            || directory_identity(&self.directory)? != self.expected_identity
        {
            return Err(format!(
                "协调目录 {} 已被替换，已拒绝继续",
                self.relative.display()
            ));
        }
        Ok(())
    }

    pub(crate) fn open_lock_file(&self, name: &str, label: &str) -> Result<File, String> {
        validate_name(name)?;
        self.verify_current()?;
        let file = open_lock_file_at(&self.directory, OsStr::new(name))
            .map_err(|error| format!("打开{label}锁失败：{error}"))?;
        self.verify_current()?;
        Ok(file)
    }

    pub(crate) fn create_child_directory(
        &self,
        name: &str,
    ) -> Result<Option<CoordinationDirectory>, String> {
        validate_name(name)?;
        self.verify_current()?;
        match create_directory_at(&self.directory, OsStr::new(name)) {
            Ok(directory) => {
                sync_directory(&self.directory)?;
                self.child_from_open(name, directory).map(Some)
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(None),
            Err(error) => Err(format!(
                "创建协调子目录 {}/{} 失败：{error}",
                self.relative.display(),
                name
            )),
        }
    }

    pub(crate) fn open_child_directory(
        &self,
        name: &str,
    ) -> Result<Option<CoordinationDirectory>, String> {
        validate_name(name)?;
        self.verify_current()?;
        match open_directory_at(&self.directory, OsStr::new(name)) {
            Ok(directory) => self.child_from_open(name, directory).map(Some),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(format!(
                "打开协调子目录 {}/{} 失败，已拒绝路径跟随：{error}",
                self.relative.display(),
                name
            )),
        }
    }

    pub(crate) fn rename_child_directory(
        &self,
        source_name: &str,
        destination_name: &str,
        expected: &CoordinationDirectory,
    ) -> Result<(), String> {
        validate_name(source_name)?;
        validate_name(destination_name)?;
        self.verify_current()?;
        let current = self
            .open_child_directory(source_name)?
            .ok_or_else(|| format!("协调子目录已消失：{source_name}"))?;
        if current.expected_identity != expected.expected_identity {
            return Err(format!(
                "协调子目录 {source_name} 的物理身份已变化，已拒绝重命名"
            ));
        }
        rename_open_directory_at(
            &self.directory,
            OsStr::new(source_name),
            OsStr::new(destination_name),
            &expected.directory,
        )
        .map_err(|error| format!("原子退役协调子目录 {source_name} 失败：{error}"))?;
        sync_directory(&self.directory)?;
        Ok(())
    }

    pub(crate) fn read_optional(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
        validate_name(name)?;
        self.verify_current()?;
        read_optional_at(&self.directory, OsStr::new(name))
    }

    pub(crate) fn write_atomic(&self, name: &str, bytes: &[u8]) -> Result<(), String> {
        validate_name(name)?;
        self.verify_current()?;
        write_atomic_at(&self.directory, name, bytes)?;
        self.verify_current()
    }

    pub(crate) fn remove_file_if_exists(&self, name: &str) -> Result<(), String> {
        validate_name(name)?;
        remove_file_at(&self.directory, OsStr::new(name))?;
        sync_directory(&self.directory)
    }

    pub(crate) fn remove_empty_child_if_exists(&self, name: &str) -> Result<(), String> {
        validate_name(name)?;
        remove_directory_at(&self.directory, OsStr::new(name))?;
        sync_directory(&self.directory)
    }

    pub(crate) fn modified_age(&self) -> Option<Duration> {
        self.directory
            .metadata()
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|modified| SystemTime::now().duration_since(modified).ok())
    }

    fn child_from_open(
        &self,
        name: &str,
        directory: File,
    ) -> Result<CoordinationDirectory, String> {
        let expected_identity = directory_identity(&directory)?;
        Ok(CoordinationDirectory {
            canonical_home: self.canonical_home.clone(),
            root: self
                .root
                .try_clone()
                .map_err(|error| format!("复制协调根句柄失败：{error}"))?,
            relative: self.relative.join(name),
            directory,
            expected_identity,
        })
    }
}

fn establish_anchor(
    root: &File,
    observed: &CoordinationAnchor,
) -> Result<CoordinationAnchor, String> {
    if let Some(existing) = read_anchor(root)? {
        validate_anchor(&existing, observed)?;
        return Ok(existing);
    }
    let bytes = serde_json::to_vec_pretty(observed)
        .map_err(|error| format!("序列化协调根锚点失败：{error}"))?;
    match create_exclusive_file_at(root, OsStr::new(ANCHOR_NAME)) {
        Ok(mut file) => {
            if let Err(error) = (|| {
                file.write_all(&bytes)?;
                file.sync_all()
            })() {
                drop(file);
                let _ = remove_file_at(root, OsStr::new(ANCHOR_NAME));
                return Err(format!("写入协调根锚点失败：{error}"));
            }
            sync_directory(root)?;
            let reread = read_anchor(root)?
                .ok_or_else(|| "协调根锚点创建后不可读，已拒绝继续".to_string())?;
            validate_anchor(&reread, observed)?;
            Ok(reread)
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let existing = read_anchor(root)?
                .ok_or_else(|| "协调根锚点并发创建后不可读，已拒绝继续".to_string())?;
            validate_anchor(&existing, observed)?;
            Ok(existing)
        }
        Err(error) => Err(format!("创建协调根锚点失败：{error}")),
    }
}

fn read_anchor(root: &File) -> Result<Option<CoordinationAnchor>, String> {
    let Some(bytes) = read_optional_at(root, OsStr::new(ANCHOR_NAME))? else {
        return Ok(None);
    };
    let anchor = serde_json::from_slice::<CoordinationAnchor>(&bytes)
        .map_err(|error| format!("协调根锚点损坏，已拒绝继续：{error}"))?;
    if anchor.schema_version != ANCHOR_SCHEMA_VERSION {
        return Err(format!("协调根锚点版本不兼容：{}", anchor.schema_version));
    }
    Ok(Some(anchor))
}

fn validate_anchor(
    existing: &CoordinationAnchor,
    observed: &CoordinationAnchor,
) -> Result<(), String> {
    if existing != observed {
        return Err("会话锁或自动续跑租约目录的物理身份已变化，已拒绝拆分互斥域".into());
    }
    Ok(())
}

fn relative_key(path: &Path) -> Result<String, String> {
    Ok(normal_components(path)?
        .into_iter()
        .map(|component| {
            component
                .into_string()
                .map_err(|_| "协调目录包含非 UTF-8 路径组件".to_string())
        })
        .collect::<Result<Vec<_>, _>>()?
        .join("/"))
}

fn normal_components(path: &Path) -> Result<Vec<OsString>, String> {
    path.components()
        .map(|component| match component {
            Component::Normal(value) => Ok(value.to_os_string()),
            _ => Err(format!("协调相对路径无效：{}", path.display())),
        })
        .collect()
}

fn validate_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || Path::new(name).components().count() != 1
        || !matches!(
            Path::new(name).components().next(),
            Some(Component::Normal(_))
        )
    {
        return Err(format!("协调成员名无效：{name}"));
    }
    Ok(())
}

fn open_directory_all(root: &File, relative: &Path) -> Result<File, String> {
    let mut current = root
        .try_clone()
        .map_err(|error| format!("复制协调根句柄失败：{error}"))?;
    for component in normal_components(relative)? {
        current = open_directory_at(&current, &component).map_err(|error| {
            format!(
                "打开协调目录 {} 失败，已拒绝 symlink/junction/reparse：{error}",
                relative.display()
            )
        })?;
    }
    Ok(current)
}

fn open_or_create_directory_all(root: &File, relative: &Path) -> Result<File, String> {
    let mut current = root
        .try_clone()
        .map_err(|error| format!("复制协调根句柄失败：{error}"))?;
    for component in normal_components(relative)? {
        current = match open_directory_at(&current, &component) {
            Ok(directory) => directory,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match create_directory_at(&current, &component) {
                    Ok(directory) => {
                        sync_directory(&current)?;
                        directory
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                        open_directory_at(&current, &component).map_err(|open_error| {
                            format!(
                                "并发创建协调目录 {} 后无法安全打开：{open_error}",
                                relative.display()
                            )
                        })?
                    }
                    Err(error) => {
                        return Err(format!("创建协调目录 {} 失败：{error}", relative.display()))
                    }
                }
            }
            Err(error) => {
                return Err(format!(
                    "打开协调目录 {} 失败，已拒绝 symlink/junction/reparse：{error}",
                    relative.display()
                ))
            }
        };
    }
    Ok(current)
}

fn read_optional_at(parent: &File, name: &OsStr) -> Result<Option<Vec<u8>>, String> {
    let mut file = match open_regular_file_at(parent, name) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "读取协调文件 {} 失败，已拒绝路径跟随：{error}",
                name.to_string_lossy()
            ))
        }
    };
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| format!("读取协调文件失败：{error}"))?;
    Ok(Some(bytes))
}

fn write_atomic_at(parent: &File, name: &str, bytes: &[u8]) -> Result<(), String> {
    for _ in 0..TEMP_ATTEMPTS {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_name = format!(".{name}.{}-{sequence:020}.tmp", std::process::id());
        let mut temp = match create_exclusive_file_at(parent, OsStr::new(&temp_name)) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("创建协调临时文件失败：{error}")),
        };
        let result = (|| {
            temp.write_all(bytes)
                .map_err(|error| format!("写入协调临时文件失败：{error}"))?;
            temp.sync_all()
                .map_err(|error| format!("同步协调临时文件失败：{error}"))?;
            rename_open_file_at(
                parent,
                OsStr::new(&temp_name),
                OsStr::new(name),
                &temp,
                true,
            )
            .map_err(|error| format!("发布协调文件失败：{error}"))?;
            sync_directory(parent)
        })();
        if result.is_err() {
            drop(temp);
            let _ = remove_file_at(parent, OsStr::new(&temp_name));
        }
        return result;
    }
    Err("无法分配唯一协调临时文件名".into())
}

#[cfg(unix)]
fn open_absolute_directory_without_following(path: &Path) -> Result<File, String> {
    let mut current = File::from(
        unix_fs::open(
            Path::new("/"),
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|error| format!("打开文件系统根目录失败：{error}"))?,
    );
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(name) => {
                current = open_directory_at(&current, name).map_err(|error| {
                    format!(
                        "固定 Codex Home 组件 {} 失败，已拒绝路径跟随：{error}",
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
fn open_directory_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    unix_fs::openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map(File::from)
    .map_err(std::io::Error::from)
}

#[cfg(unix)]
fn create_directory_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    unix_fs::mkdirat(parent, name, Mode::from_raw_mode(0o700)).map_err(std::io::Error::from)?;
    open_directory_at(parent, name)
}

#[cfg(unix)]
fn open_regular_file_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    unix_fs::openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map(File::from)
    .map_err(std::io::Error::from)
}

#[cfg(unix)]
fn create_exclusive_file_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    unix_fs::openat(
        parent,
        name,
        OFlags::RDWR | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(0o600),
    )
    .map(File::from)
    .map_err(std::io::Error::from)
}

#[cfg(unix)]
fn open_lock_file_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    let file = unix_fs::openat(
        parent,
        name,
        OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(0o600),
    )
    .map(File::from)
    .map_err(std::io::Error::from)?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

#[cfg(unix)]
fn rename_open_file_at(
    parent: &File,
    source_name: &OsStr,
    destination_name: &OsStr,
    _source: &File,
    _replace_existing: bool,
) -> std::io::Result<()> {
    unix_fs::renameat(parent, source_name, parent, destination_name).map_err(std::io::Error::from)
}

#[cfg(unix)]
fn rename_open_directory_at(
    parent: &File,
    source_name: &OsStr,
    destination_name: &OsStr,
    _source: &File,
) -> std::io::Result<()> {
    unix_fs::renameat(parent, source_name, parent, destination_name).map_err(std::io::Error::from)
}

#[cfg(unix)]
fn remove_file_at(parent: &File, name: &OsStr) -> Result<(), String> {
    match unix_fs::unlinkat(parent, name, AtFlags::empty()) {
        Ok(()) => Ok(()),
        Err(rustix::io::Errno::NOENT) => Ok(()),
        Err(error) => Err(format!("删除协调文件失败：{error}")),
    }
}

#[cfg(unix)]
fn remove_directory_at(parent: &File, name: &OsStr) -> Result<(), String> {
    match unix_fs::unlinkat(parent, name, AtFlags::REMOVEDIR) {
        Ok(()) => Ok(()),
        Err(rustix::io::Errno::NOENT) => Ok(()),
        Err(error) => Err(format!("删除协调目录失败：{error}")),
    }
}

#[cfg(unix)]
fn sync_directory(directory: &File) -> Result<(), String> {
    unix_fs::fsync(directory).map_err(|error| format!("同步协调目录失败：{error}"))
}

#[cfg(unix)]
fn directory_identity(file: &File) -> Result<String, String> {
    let metadata = file
        .metadata()
        .map_err(|error| format!("读取协调目录身份失败：{error}"))?;
    if !metadata.is_dir() {
        return Err("协调成员不是目录".into());
    }
    Ok(format!("unix:{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn open_absolute_directory_without_following(path: &Path) -> Result<File, String> {
    let (drive, components) = windows_local_drive_components(path)?;
    if components.is_empty() {
        return Err("Windows Codex Home 不得直接使用卷根目录".into());
    }
    let mut current = windows_open_drive_root(drive)?;
    for (index, component) in components.iter().enumerate() {
        let final_component = index + 1 == components.len();
        let desired_access = if final_component {
            windows_pinned_home_access()
        } else {
            windows_directory_read_access()
        };
        current = windows_open_directory_at_with_access_and_share(
            &current,
            component,
            desired_access,
            !final_component,
        )
        .map_err(|error| {
            format!(
                "固定 Codex Home 组件 {} 失败，已拒绝 junction/reparse：{error}",
                path.display()
            )
        })?;
    }
    Ok(current)
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
                    "协调根仅支持本地磁盘上的 Codex Home：{}",
                    path.display()
                ))
            }
        },
        _ => {
            return Err(format!(
                "Windows Codex Home 缺少磁盘前缀：{}",
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
            Component::Normal(value) => Ok(value.to_os_string()),
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
            "打开 Windows 卷根目录失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    let file = unsafe { File::from_raw_handle(handle as RawHandle) };
    windows_require_directory_without_reparse(&file, Path::new(&path))?;
    Ok(file)
}

#[cfg(windows)]
fn windows_directory_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{
        DELETE, FILE_DELETE_CHILD, FILE_GENERIC_READ, FILE_GENERIC_WRITE, SYNCHRONIZE,
    };
    FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_DELETE_CHILD | DELETE | SYNCHRONIZE
}

#[cfg(windows)]
fn windows_pinned_home_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_DELETE_CHILD, FILE_GENERIC_READ, FILE_GENERIC_WRITE, SYNCHRONIZE,
    };
    FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_DELETE_CHILD | SYNCHRONIZE
}

#[cfg(windows)]
fn windows_directory_read_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_LIST_DIRECTORY, FILE_READ_ATTRIBUTES, FILE_TRAVERSE, SYNCHRONIZE,
    };
    FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | FILE_TRAVERSE | SYNCHRONIZE
}

#[cfg(windows)]
fn windows_nt_open_relative(
    parent: &File,
    name: &OsStr,
    desired_access: u32,
    share_access: u32,
    create_disposition: u32,
    create_options: u32,
    file_attributes: u32,
) -> std::io::Result<File> {
    use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
    use windows_sys::Wdk::Storage::FileSystem::NtCreateFile;
    use windows_sys::Win32::Foundation::{
        RtlNtStatusToDosError, HANDLE, OBJ_CASE_INSENSITIVE, UNICODE_STRING,
    };
    use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;

    let mut wide = name.encode_wide().collect::<Vec<_>>();
    if wide.is_empty() || wide.iter().any(|unit| *unit == 0) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Windows 协调成员名为空或包含 NUL",
        ));
    }
    let byte_length = wide
        .len()
        .checked_mul(std::mem::size_of::<u16>())
        .and_then(|length| u16::try_from(length).ok())
        .ok_or_else(|| std::io::Error::other("Windows 协调成员名过长"))?;
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
            share_access,
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
            "NtCreateFile 成功但未返回协调文件句柄",
        ));
    }
    Ok(unsafe { File::from_raw_handle(handle as RawHandle) })
}

#[cfg(windows)]
fn open_directory_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    windows_open_directory_at_with_access(parent, name, windows_directory_access())
}

#[cfg(windows)]
fn windows_open_directory_at_with_access(
    parent: &File,
    name: &OsStr,
    desired_access: u32,
) -> std::io::Result<File> {
    windows_open_directory_at_with_access_and_share(parent, name, desired_access, true)
}

#[cfg(windows)]
fn windows_open_directory_at_with_access_and_share(
    parent: &File,
    name: &OsStr,
    desired_access: u32,
    share_delete: bool,
) -> std::io::Result<File> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FILE_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT, FILE_SYNCHRONOUS_IO_NONALERT,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_NORMAL, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    let directory = windows_nt_open_relative(
        parent,
        name,
        desired_access,
        FILE_SHARE_READ | FILE_SHARE_WRITE | if share_delete { FILE_SHARE_DELETE } else { 0 },
        FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
        FILE_ATTRIBUTE_NORMAL,
    )?;
    windows_require_directory_without_reparse(&directory, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(directory)
}

#[cfg(windows)]
fn create_directory_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FILE_CREATE, FILE_DIRECTORY_FILE, FILE_OPEN_REPARSE_POINT, FILE_SYNCHRONOUS_IO_NONALERT,
        FILE_WRITE_THROUGH,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_DIRECTORY, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    let directory = windows_nt_open_relative(
        parent,
        name,
        windows_directory_access(),
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        FILE_CREATE,
        FILE_DIRECTORY_FILE
            | FILE_OPEN_REPARSE_POINT
            | FILE_SYNCHRONOUS_IO_NONALERT
            | FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_DIRECTORY,
    )?;
    windows_require_directory_without_reparse(&directory, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(directory)
}

#[cfg(windows)]
fn windows_regular_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{
        DELETE, FILE_GENERIC_READ, FILE_GENERIC_WRITE, SYNCHRONIZE,
    };
    FILE_GENERIC_READ | FILE_GENERIC_WRITE | DELETE | SYNCHRONIZE
}

#[cfg(windows)]
fn windows_lock_file_access() -> u32 {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_GENERIC_READ, FILE_GENERIC_WRITE, SYNCHRONIZE,
    };
    FILE_GENERIC_READ | FILE_GENERIC_WRITE | SYNCHRONIZE
}

#[cfg(windows)]
fn open_regular_file_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT, FILE_SYNCHRONOUS_IO_NONALERT,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_NORMAL, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    let file = windows_nt_open_relative(
        parent,
        name,
        windows_regular_access(),
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        FILE_OPEN,
        FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
        FILE_ATTRIBUTE_NORMAL,
    )?;
    windows_require_regular_without_reparse(&file, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(file)
}

#[cfg(windows)]
fn create_exclusive_file_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FILE_CREATE, FILE_NON_DIRECTORY_FILE, FILE_OPEN_REPARSE_POINT,
        FILE_SYNCHRONOUS_IO_NONALERT, FILE_WRITE_THROUGH,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_NORMAL, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    let file = windows_nt_open_relative(
        parent,
        name,
        windows_regular_access(),
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        FILE_CREATE,
        FILE_NON_DIRECTORY_FILE
            | FILE_OPEN_REPARSE_POINT
            | FILE_SYNCHRONOUS_IO_NONALERT
            | FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_NORMAL,
    )?;
    windows_require_regular_without_reparse(&file, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(file)
}

#[cfg(windows)]
fn open_lock_file_at(parent: &File, name: &OsStr) -> std::io::Result<File> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FILE_NON_DIRECTORY_FILE, FILE_OPEN_IF, FILE_OPEN_REPARSE_POINT,
        FILE_SYNCHRONOUS_IO_NONALERT, FILE_WRITE_THROUGH,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    let file = windows_nt_open_relative(
        parent,
        name,
        windows_lock_file_access(),
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        FILE_OPEN_IF,
        FILE_NON_DIRECTORY_FILE
            | FILE_OPEN_REPARSE_POINT
            | FILE_SYNCHRONOUS_IO_NONALERT
            | FILE_WRITE_THROUGH,
        FILE_ATTRIBUTE_NORMAL,
    )?;
    windows_require_regular_without_reparse(&file, Path::new(name))
        .map_err(std::io::Error::other)?;
    Ok(file)
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
            "读取 Windows 协调文件属性失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(info.FileAttributes)
}

#[cfg(windows)]
fn windows_require_directory_without_reparse(file: &File, path: &Path) -> Result<(), String> {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
    };
    let attributes = windows_file_attributes(file)?;
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!("拒绝 Windows 协调目录重解析点：{}", path.display()));
    }
    if attributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(format!("Windows 协调成员不是目录：{}", path.display()));
    }
    Ok(())
}

#[cfg(windows)]
fn windows_require_regular_without_reparse(file: &File, path: &Path) -> Result<(), String> {
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
    };
    let attributes = windows_file_attributes(file)?;
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!("拒绝 Windows 协调文件重解析点：{}", path.display()));
    }
    if attributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(format!("Windows 协调成员不是普通文件：{}", path.display()));
    }
    Ok(())
}

#[cfg(windows)]
fn directory_identity(file: &File) -> Result<String, String> {
    use windows_sys::Win32::Storage::FileSystem::{
        FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
    };
    windows_require_directory_without_reparse(file, Path::new("<coordination-directory>"))?;
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
            "读取 Windows 协调目录物理身份失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    let file_id = info
        .FileId
        .Identifier
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(format!("windows:{}:{file_id}", info.VolumeSerialNumber))
}

#[cfg(windows)]
fn windows_rename_open_file(
    file: &File,
    destination_parent: &File,
    destination_name: &OsStr,
    replace_existing: bool,
) -> std::io::Result<()> {
    use windows_sys::Wdk::Storage::FileSystem::{
        FileRenameInformation, NtSetInformationFile, FILE_RENAME_INFORMATION,
        FILE_RENAME_INFORMATION_0,
    };
    use windows_sys::Win32::Foundation::RtlNtStatusToDosError;
    use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;
    let name = destination_name.encode_wide().collect::<Vec<_>>();
    let name_bytes = name
        .len()
        .checked_mul(std::mem::size_of::<u16>())
        .ok_or_else(|| std::io::Error::other("Windows 协调目标名过长"))?;
    let buffer_bytes = std::mem::offset_of!(FILE_RENAME_INFORMATION, FileName)
        .checked_add(name_bytes)
        .ok_or_else(|| std::io::Error::other("Windows 协调 rename 缓冲区溢出"))?;
    let words = buffer_bytes.div_ceil(std::mem::size_of::<usize>());
    let mut buffer = vec![0_usize; words];
    let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFORMATION>();
    unsafe {
        (*info).Anonymous = FILE_RENAME_INFORMATION_0 {
            ReplaceIfExists: replace_existing,
        };
        (*info).RootDirectory = destination_parent.as_raw_handle() as _;
        (*info).FileNameLength = u32::try_from(name_bytes)
            .map_err(|_| std::io::Error::other("Windows 协调目标名过长"))?;
        std::ptr::copy_nonoverlapping(name.as_ptr(), (*info).FileName.as_mut_ptr(), name.len());
    }
    let mut io_status = IO_STATUS_BLOCK::default();
    let status = unsafe {
        NtSetInformationFile(
            file.as_raw_handle() as _,
            &mut io_status,
            info.cast(),
            u32::try_from(buffer_bytes)
                .map_err(|_| std::io::Error::other("Windows 协调 rename 缓冲区过长"))?,
            FileRenameInformation,
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
fn rename_open_file_at(
    parent: &File,
    _source_name: &OsStr,
    destination_name: &OsStr,
    source: &File,
    replace_existing: bool,
) -> std::io::Result<()> {
    windows_rename_open_file(source, parent, destination_name, replace_existing)
}

#[cfg(windows)]
fn rename_open_directory_at(
    parent: &File,
    _source_name: &OsStr,
    destination_name: &OsStr,
    source: &File,
) -> std::io::Result<()> {
    windows_rename_open_file(source, parent, destination_name, false)
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

#[cfg(windows)]
fn remove_file_at(parent: &File, name: &OsStr) -> Result<(), String> {
    match open_regular_file_at(parent, name) {
        Ok(file) => windows_delete_open_file(&file)
            .map_err(|error| format!("删除 Windows 协调文件失败：{error}")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("打开待删 Windows 协调文件失败：{error}")),
    }
}

#[cfg(windows)]
fn remove_directory_at(parent: &File, name: &OsStr) -> Result<(), String> {
    match open_directory_at(parent, name) {
        Ok(directory) => windows_delete_open_file(&directory)
            .map_err(|error| format!("删除 Windows 协调目录失败：{error}")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("打开待删 Windows 协调目录失败：{error}")),
    }
}

#[cfg(windows)]
fn sync_directory(directory: &File) -> Result<(), String> {
    directory
        .sync_all()
        .map_err(|error| format!("同步 Windows 协调目录失败：{error}"))
}

#[cfg(test)]
mod tests {
    use super::{CoordinationHome, SESSION_LOCK_DIRECTORY};
    use std::fs;
    use std::path::PathBuf;

    fn test_home(label: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "ctb-coordination-{label}-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[cfg(unix)]
    #[test]
    fn parent_symlink_is_rejected_during_descriptor_walk() {
        use std::os::unix::fs::symlink;
        let home = test_home("parent-symlink");
        let outside = test_home("parent-symlink-outside");
        symlink(&outside, home.join("backups_state")).unwrap();
        let error = CoordinationHome::open(&home).err().unwrap();
        assert!(
            error.contains("路径跟随") || error.contains("symlink"),
            "{error}"
        );
        let _ = fs::remove_dir_all(home);
        let _ = fs::remove_dir_all(outside);
    }

    #[test]
    fn anchored_lock_directory_replacement_fails_closed() {
        let home = test_home("directory-replacement");
        let coordination = CoordinationHome::open(&home).unwrap();
        let lock_directory = home.join(SESSION_LOCK_DIRECTORY);
        let retired = home.join("backups_state/codex-token-bar-retired");
        fs::rename(&lock_directory, &retired).unwrap();
        fs::create_dir(&lock_directory).unwrap();

        let error = coordination.validate().err().unwrap();
        assert!(
            error.contains("物理身份") || error.contains("替换"),
            "{error}"
        );
        let reopened_error = CoordinationHome::open(&home).err().unwrap();
        assert!(
            reopened_error.contains("物理身份") || reopened_error.contains("互斥域"),
            "{reopened_error}"
        );
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn windows_backend_is_root_relative_and_reparse_aware() {
        let source = include_str!("coordination_fs.rs");
        assert!(source.contains("#[cfg(windows)]\nfn windows_nt_open_relative"));
        assert!(source.contains("NtCreateFile"));
        assert!(source.contains("RootDirectory: parent.as_raw_handle()"));
        assert!(source.contains("FILE_OPEN_REPARSE_POINT"));
        assert!(source.contains("FILE_ATTRIBUTE_REPARSE_POINT"));
        assert!(source.contains("FileIdInfo"));
        assert!(source.contains("VolumeSerialNumber"));
        assert!(source.contains("command.pre_exec"));
        assert!(source.contains("libc::fchdir"));
        assert!(source.contains("command.env(\"CODEX_HOME\", \".\")"));
        assert!(source.contains("windows_open_directory_at_with_access_and_share"));
        assert!(source.contains("windows_pinned_home_access()"));
        assert!(source.contains("!final_component"));
        assert!(source.contains("windows_lock_file_access()"));
        assert!(source.contains("FILE_SHARE_READ | FILE_SHARE_WRITE"));
    }

    #[test]
    fn windows_lock_open_uses_non_delete_access_and_shared_open() {
        let source = include_str!("coordination_fs.rs");
        let access = source
            .split("fn windows_lock_file_access()")
            .nth(1)
            .expect("dedicated Windows lock access")
            .split("#[cfg(windows)]")
            .next()
            .unwrap();
        assert!(access.contains("FILE_GENERIC_READ"));
        assert!(access.contains("FILE_GENERIC_WRITE"));
        assert!(access.contains("SYNCHRONIZE"));
        assert!(!access.contains("DELETE"));

        let lock_open = source
            .split("#[cfg(windows)]\nfn open_lock_file_at")
            .nth(1)
            .expect("Windows lock open")
            .split("#[cfg(windows)]")
            .next()
            .unwrap();
        assert!(lock_open.contains("windows_lock_file_access()"));
        assert!(lock_open.contains("FILE_SHARE_READ | FILE_SHARE_WRITE"));
        assert!(!lock_open.contains("FILE_SHARE_DELETE"));
        assert!(!lock_open.contains("windows_regular_access()"));
    }

    #[test]
    fn windows_pinned_home_access_denies_delete_without_requesting_it() {
        let source = include_str!("coordination_fs.rs");
        let access = source
            .split("fn windows_pinned_home_access()")
            .nth(1)
            .expect("dedicated Windows pinned Home access")
            .split("#[cfg(windows)]")
            .next()
            .unwrap();
        assert!(access.contains("FILE_DELETE_CHILD"));
        assert!(access.contains("FILE_GENERIC_READ"));
        assert!(access.contains("FILE_GENERIC_WRITE"));
        assert!(!access.contains("DELETE,"));
        let walker = source
            .split("fn open_absolute_directory_without_following")
            .nth(2)
            .expect("Windows absolute descriptor walker")
            .split("#[cfg(windows)]")
            .next()
            .unwrap();
        assert!(walker.contains("windows_pinned_home_access()"));
        assert!(walker.contains("!final_component"));
    }

    #[cfg(windows)]
    #[test]
    fn windows_reparse_parent_is_rejected_when_symlink_creation_is_available() {
        use std::os::windows::fs::symlink_dir;
        let home = test_home("windows-parent-reparse");
        let outside = test_home("windows-parent-reparse-outside");
        if let Err(error) = symlink_dir(&outside, home.join("backups_state")) {
            if error.kind() == std::io::ErrorKind::PermissionDenied {
                let _ = fs::remove_dir_all(home);
                let _ = fs::remove_dir_all(outside);
                return;
            }
            panic!("create Windows directory reparse fixture: {error}");
        }
        let error = CoordinationHome::open(&home).err().unwrap();
        assert!(
            error.contains("reparse") || error.contains("重解析"),
            "{error}"
        );
        let _ = fs::remove_dir_all(home);
        let _ = fs::remove_dir_all(outside);
    }

    #[cfg(windows)]
    #[test]
    fn windows_pinned_home_handle_blocks_root_rename_until_drop() {
        let home = test_home("windows-home-rename");
        let moved = home.with_extension("moved");
        let coordination = CoordinationHome::open(&home).unwrap();
        let error = fs::rename(&home, &moved)
            .err()
            .expect("pinned Home handle must deny rename sharing");
        assert_eq!(
            error.raw_os_error(),
            Some(32),
            "the live pinned Home handle must block rename with ERROR_SHARING_VIOLATION: {error}"
        );
        drop(coordination);
        fs::rename(&home, &moved).unwrap();
        let _ = fs::remove_dir_all(moved);
    }
}
