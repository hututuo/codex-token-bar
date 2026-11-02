//! One private, verified pre-pool snapshot of business database A.
//!
//! This is evidence for the structure migration, not a rollback target. The
//! source connection is only read through SQLite's online backup API; A is
//! never replaced or restored from this image.

use rusqlite::{backup::Backup, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};

const BACKUP_ROOT: &str = "ledger-migration-backups";
const BACKUP_ID: &str = "structural-stage-pool-rust-v1";
const SNAPSHOT_NAME: &str = "snapshot.sqlite";
const MAX_BACKUP_STEP: i32 = 128;
const BACKUP_TIMEOUT: Duration = Duration::from_secs(30);
const RETRY_DELAY: Duration = Duration::from_millis(20);
const SAFETY_MARGIN_BYTES: u64 = 512 * 1024 * 1024;
const HASH_BUFFER_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Receipt {
    format: u32,
    source_identity: String,
    sha256: String,
}

/// Ensure the recorded pre-pool snapshot exists and is bound to this physical
/// A container. The supplied connection must be the same A file as `container`.
pub(super) fn ensure(container: &Path, source: &Connection) -> Result<(), String> {
    ensure_with_available_space(container, source, None)
}

fn ensure_with_available_space(
    container: &Path,
    source: &Connection,
    available_override: Option<u64>,
) -> Result<(), String> {
    let source_identity = verify_source(container, source)?;
    let parent = container
        .parent()
        .ok_or_else(|| "业务数据库 A 路径没有父目录".to_string())?;
    let backup_root = parent.join(BACKUP_ROOT);
    let directory = backup_root.join(BACKUP_ID);
    let image = directory.join("image");
    let snapshot = image.join(SNAPSHOT_NAME);
    let receipt_path = directory.join("receipt.json");
    let preparation_path = directory.join("preparation.json");

    verify_directory_if_present(&backup_root)?;
    verify_directory_if_present(&directory)?;
    verify_directory_if_present(&image)?;
    for path in [
        &snapshot,
        &image.join("snapshot.sqlite-wal"),
        &image.join("snapshot.sqlite-shm"),
        &image.join("snapshot.sqlite-journal"),
        &receipt_path,
        &preparation_path,
    ] {
        verify_regular_file_if_present(path)?;
    }

    if path_exists(&receipt_path)? {
        let receipt = read_receipt(&receipt_path)?;
        if receipt.format != 1 || receipt.source_identity != source_identity {
            return Err("预结构备份回执与当前业务数据库 A 身份不匹配".into());
        }
        verify_empty_snapshot_journals(&snapshot)?;
        if hash_file(&snapshot)? != receipt.sha256 {
            return Err("预结构备份哈希与回执不匹配".into());
        }
        return Ok(());
    }

    if directory_is_nonempty_if_present(&image)? {
        // Only a source-bound pending intent grants ownership of an incomplete
        // image family. A complete image can finish its receipt without ever
        // copying current A over the frozen snapshot.
        let preparation = read_receipt(&preparation_path)?;
        if preparation.format != 1
            || preparation.source_identity != source_identity
            || preparation.sha256 != "pending"
        {
            return Err("预结构备份准备记录无效；保留现有 image 原样".into());
        }

        verify_image_family(&image)?;
        if snapshot_has_empty_journals(&snapshot)? && snapshot_is_complete(&snapshot) {
            verify_source_identity(container, source, &source_identity)?;
            finish(&snapshot, &receipt_path, &directory, &source_identity)?;
            return Ok(());
        }

        // Keep the interrupted image and every allowed sidecar together as
        // evidence. A new backup always gets a newly created image directory.
        let retained = directory.join(format!("incomplete-{}", uuid::Uuid::new_v4()));
        fs::rename(&image, &retained)
            .map_err(|error| format!("无法保留未完成的预结构备份 image：{error}"))?;
        sync_parent(&directory)?;
    }

    ensure_directory(&backup_root)?;
    ensure_directory(&directory)?;
    let source_bytes = regular_file_size(container)?;
    let wal_bytes = regular_file_size_if_present(&append_suffix(container, "-wal"))?;
    let required = source_bytes
        .checked_add(wal_bytes)
        .and_then(|bytes| bytes.checked_add(SAFETY_MARGIN_BYTES))
        .ok_or_else(|| "预结构备份空间需求溢出".to_string())?;
    let available = match available_override {
        Some(value) => value,
        None => fs2::available_space(parent)
            .map_err(|error| format!("无法读取预结构备份可用空间：{error}"))?,
    };
    if available < required {
        return Err(format!(
            "预结构备份空间不足：需要至少 {required} 字节，可用 {available} 字节"
        ));
    }

    ensure_directory(&image)?;
    if path_exists(&snapshot)? {
        return Err("预结构备份 snapshot 已存在但没有可采用的回执".into());
    }

    if path_exists(&preparation_path)? {
        let existing = read_receipt(&preparation_path)?;
        if existing.format != 1
            || existing.source_identity != source_identity
            || existing.sha256 != "pending"
        {
            return Err("已有预结构备份准备记录不属于当前 A；保留原文件".into());
        }
    } else {
        write_json_atomically(
            &preparation_path,
            &Receipt {
                format: 1,
                source_identity: source_identity.clone(),
                sha256: "pending".into(),
            },
        )?;
    }

    let snapshot_file = create_snapshot_file(&snapshot)?;
    let snapshot_identity = identity_from_file(&snapshot_file)?;
    snapshot_file
        .sync_all()
        .map_err(|error| format!("无法同步预结构备份 snapshot 初始文件：{error}"))?;
    drop(snapshot_file);
    sync_parent(&image)?;

    let mut destination = Connection::open(&snapshot)
        .map_err(|error| format!("无法打开预结构备份 snapshot：{error}"))?;
    if physical_identity(&snapshot)? != snapshot_identity {
        return Err("预结构备份 snapshot 在打开期间被替换".into());
    }
    {
        let backup = Backup::new(source, &mut destination)
            .map_err(|error| format!("无法初始化 SQLite 预结构备份：{error}"))?;
        let deadline = Instant::now() + BACKUP_TIMEOUT;
        loop {
            match backup
                .step(MAX_BACKUP_STEP)
                .map_err(|error| format!("SQLite 预结构备份失败：{error}"))?
            {
                rusqlite::backup::StepResult::Done => break,
                rusqlite::backup::StepResult::More => {
                    if Instant::now() >= deadline {
                        return Err("SQLite 预结构备份在 30 秒内未完成".into());
                    }
                }
                rusqlite::backup::StepResult::Busy | rusqlite::backup::StepResult::Locked => {
                    if Instant::now() >= deadline {
                        return Err("SQLite 预结构备份在 30 秒内未完成".into());
                    }
                    thread::sleep(RETRY_DELAY);
                }
                _ => return Err("SQLite 预结构备份返回了未知状态".into()),
            }
        }
    }

    destination
        .close()
        .map_err(|(_, error)| format!("无法关闭预结构备份 snapshot：{error}"))?;
    if physical_identity(&snapshot)? != snapshot_identity {
        return Err("SQLite 预结构备份期间 snapshot 文件身份发生变化".into());
    }
    verify_source_identity(container, source, &source_identity)?;
    verify_empty_snapshot_journals(&snapshot)?;
    if !snapshot_is_complete(&snapshot) {
        return Err("预结构备份未通过完整 quick_check、user_version=1 和 ready 校验".into());
    }

    finish(&snapshot, &receipt_path, &directory, &source_identity)
}

fn verify_source(container: &Path, source: &Connection) -> Result<String, String> {
    let source_identity = physical_identity(container)?;
    verify_source_identity(container, source, &source_identity)?;
    Ok(source_identity)
}

fn verify_source_identity(
    container: &Path,
    source: &Connection,
    expected: &str,
) -> Result<(), String> {
    let container_identity = physical_identity(container)?;
    let connection_path = source
        .path()
        .ok_or_else(|| "SQLite source connection 没有关联的 main 文件路径".to_string())?;
    let connection_identity = physical_identity(Path::new(connection_path))?;
    if container_identity != expected || connection_identity != expected {
        return Err("SQLite source connection 与业务数据库 A 物理身份不匹配或已改变".into());
    }
    Ok(())
}

fn finish(
    snapshot: &Path,
    receipt_path: &Path,
    directory: &Path,
    source_identity: &str,
) -> Result<(), String> {
    verify_empty_snapshot_journals(snapshot)?;
    set_private_file_permissions(snapshot)?;
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(snapshot)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("无法同步完成的预结构 snapshot：{error}"))?;
    sync_parent(snapshot.parent().unwrap_or_else(|| Path::new(".")))?;

    let receipt = Receipt {
        format: 1,
        source_identity: source_identity.to_string(),
        sha256: hash_file(snapshot)?,
    };
    write_json_atomically(receipt_path, &receipt)?;
    sync_parent(directory)?;
    Ok(())
}

fn snapshot_is_complete(snapshot: &Path) -> bool {
    let check = || -> Result<bool, String> {
        let expected_identity = physical_identity(snapshot)?;
        let connection = Connection::open_with_flags(
            snapshot,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|error| error.to_string())?;
        let mut statement = connection
            .prepare("PRAGMA quick_check")
            .map_err(|error| error.to_string())?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())?;
        if rows != ["ok"] {
            return Ok(false);
        }
        let user_version: i64 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(|error| error.to_string())?;
        if user_version != 1 {
            return Ok(false);
        }
        let activation_state: Option<String> = connection
            .query_row(
                "SELECT value FROM tb_container_meta WHERE key='activation_state'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| error.to_string())?;
        let schema: String = connection
            .query_row(
                "SELECT value FROM tb_container_meta WHERE key='schema_version'",
                [],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        Ok(schema == "1"
            && activation_state.as_deref().is_none_or(|s| s == "ready")
            && physical_identity(snapshot)? == expected_identity)
    };
    check().unwrap_or(false)
}

fn verify_image_family(image: &Path) -> Result<(), String> {
    let allowed = [
        SNAPSHOT_NAME,
        "snapshot.sqlite-wal",
        "snapshot.sqlite-shm",
        "snapshot.sqlite-journal",
    ];
    for entry in fs::read_dir(image).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        if !allowed.contains(&entry.file_name().to_string_lossy().as_ref()) {
            return Err(format!(
                "预结构备份 image 含未知文件；拒绝移动：{}",
                entry.path().display()
            ));
        }
        verify_regular_file_if_present(&entry.path())?;
    }
    Ok(())
}

fn verify_empty_snapshot_journals(snapshot: &Path) -> Result<(), String> {
    if !snapshot_has_empty_journals(snapshot)? {
        return Err("预结构备份 WAL 或 journal 非空；拒绝复用该 snapshot".into());
    }
    Ok(())
}

fn snapshot_has_empty_journals(snapshot: &Path) -> Result<bool, String> {
    for suffix in ["-wal", "-journal"] {
        let sidecar = append_suffix(snapshot, suffix);
        if let Some(metadata) = metadata_if_exists(&sidecar)? {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return Err(format!(
                    "预结构备份 sidecar 不是普通文件：{}",
                    sidecar.display()
                ));
            }
            if metadata.len() != 0 {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn read_receipt(path: &Path) -> Result<Receipt, String> {
    let bytes = fs::read(path)
        .map_err(|error| format!("无法读取预结构备份记录 {}：{error}", path.display()))?;
    serde_json::from_slice(&bytes)
        .map_err(|error| format!("预结构备份记录 JSON 无效 {}：{error}", path.display()))
}

fn write_json_atomically(path: &Path, receipt: &Receipt) -> Result<(), String> {
    let bytes = serde_json::to_vec(receipt).map_err(|error| error.to_string())?;
    crate::core::atomic_file::write_atomically(path, &bytes)
        .map_err(|error| format!("无法原子写入预结构备份记录：{error}"))
}

fn hash_file(path: &Path) -> Result<String, String> {
    let mut file = OpenOptions::new()
        .read(true)
        .open(path)
        .map_err(|error| format!("无法打开预结构备份用于哈希：{error}"))?;
    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; HASH_BUFFER_BYTES];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("无法流式读取预结构备份：{error}"))?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(hex_digest(&digest.finalize()))
}

fn hex_digest(bytes: &[u8]) -> String {
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(result, "{byte:02x}");
    }
    result
}

fn append_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

fn path_exists(path: &Path) -> Result<bool, String> {
    Ok(metadata_if_exists(path)?.is_some())
}

fn metadata_if_exists(path: &Path) -> Result<Option<fs::Metadata>, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("无法检查路径 {}：{error}", path.display())),
    }
}

fn verify_directory_if_present(path: &Path) -> Result<(), String> {
    if let Some(metadata) = metadata_if_exists(path)? {
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(format!(
                "预结构备份目录不是普通目录；保留现状：{}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn verify_regular_file_if_present(path: &Path) -> Result<(), String> {
    if let Some(metadata) = metadata_if_exists(path)? {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(format!(
                "预结构备份文件不是普通文件；保留现状：{}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn directory_is_nonempty(path: &Path) -> Result<bool, String> {
    let mut entries =
        fs::read_dir(path).map_err(|error| format!("无法检查预结构备份 image：{error}"))?;
    Ok(entries
        .next()
        .transpose()
        .map_err(|error| error.to_string())?
        .is_some())
}

fn directory_is_nonempty_if_present(path: &Path) -> Result<bool, String> {
    if metadata_if_exists(path)?.is_none() {
        return Ok(false);
    }
    directory_is_nonempty(path)
}

fn ensure_directory(path: &Path) -> Result<(), String> {
    match fs::create_dir(path) {
        Ok(()) => {
            set_private_directory_permissions(path)?;
            if let Some(parent) = path.parent() {
                sync_parent(parent)?;
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            verify_directory_if_present(path)?;
        }
        Err(error) => {
            return Err(format!(
                "无法创建预结构备份目录 {}：{error}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn regular_file_size(path: &Path) -> Result<u64, String> {
    verify_regular_file_if_present(path)?;
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("无法读取数据库文件大小 {}：{error}", path.display()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(format!("数据库文件不是普通文件：{}", path.display()));
    }
    Ok(metadata.len())
}

fn regular_file_size_if_present(path: &Path) -> Result<u64, String> {
    let Some(metadata) = metadata_if_exists(path)? else {
        return Ok(0);
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("数据库 WAL 不是普通文件：{}", path.display()));
    }
    Ok(metadata.len())
}

fn sync_parent(path: &Path) -> Result<(), String> {
    crate::core::atomic_file::sync_parent(path)
        .map_err(|error| format!("无法同步预结构备份目录 {}：{error}", path.display()))
}

fn create_snapshot_file(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    options
        .open(path)
        .map_err(|error| format!("无法独占创建预结构 snapshot {}：{error}", path.display()))
}

fn set_private_directory_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("无法设置预结构备份目录权限：{error}"))?;
    }
    let _ = path;
    Ok(())
}

fn set_private_file_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("无法设置预结构 snapshot 权限：{error}"))?;
    }
    let _ = path;
    Ok(())
}

fn physical_identity(path: &Path) -> Result<String, String> {
    let path_metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("无法读取物理文件身份 {}：{error}", path.display()))?;
    if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
        return Err(format!("物理身份路径不是普通文件：{}", path.display()));
    }

    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options
        .open(path)
        .map_err(|error| format!("无法打开物理身份路径 {}：{error}", path.display()))?;
    let opened_metadata = file.metadata().map_err(|error| error.to_string())?;
    if !opened_metadata.is_file() {
        return Err(format!("物理身份句柄不是普通文件：{}", path.display()));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if path_metadata.dev() != opened_metadata.dev()
            || path_metadata.ino() != opened_metadata.ino()
        {
            return Err(format!(
                "物理身份路径在打开期间发生变化：{}",
                path.display()
            ));
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
        if path_metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
            || opened_metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        {
            return Err(format!("物理身份路径是 reparse point：{}", path.display()));
        }
    }

    identity_from_file(&file)
}

#[cfg(unix)]
fn identity_from_file(file: &File) -> Result<String, String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    Ok(format!("{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn identity_from_file(file: &File) -> Result<String, String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
    };
    let mut information = FILE_ID_INFO::default();
    let result = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileIdInfo,
            (&mut information as *mut FILE_ID_INFO).cast(),
            std::mem::size_of::<FILE_ID_INFO>() as u32,
        )
    };
    if result == 0 {
        return Err(format!(
            "无法读取 Windows 文件身份：{}",
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
    Ok(format!("{}:{file_id}", information.VolumeSerialNumber))
}

#[cfg(not(any(unix, windows)))]
fn identity_from_file(_file: &File) -> Result<String, String> {
    Err("当前平台没有已验证的稳定文件身份实现".into())
}

#[cfg(test)]
mod tests {
    use super::{ensure_with_available_space, snapshot_is_complete, Receipt};
    use rusqlite::Connection;
    use std::{fs, path::PathBuf};

    struct Fixture {
        root: PathBuf,
        container: PathBuf,
        source: Option<Connection>,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .join(format!("exact-stage-pool-backup-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&root).unwrap();
            let container = root.join("codex-ledger.sqlite");
            let source = Connection::open(&container).unwrap();
            source
                .execute_batch(
                    "CREATE TABLE tb_container_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                     INSERT INTO tb_container_meta VALUES('activation_state','ready');
                     INSERT INTO tb_container_meta VALUES('schema_version','1');
                     CREATE TABLE facts(value TEXT NOT NULL);
                     INSERT INTO facts VALUES('original');
                     PRAGMA user_version=1;",
                )
                .unwrap();
            Self {
                root,
                container,
                source: Some(source),
            }
        }

        fn source(&self) -> &Connection {
            self.source.as_ref().expect("fixture source is open")
        }

        fn backup_dir(&self) -> PathBuf {
            self.root.join("ledger-migration-backups").join(BACKUP_ID)
        }

        fn snapshot(&self) -> PathBuf {
            self.backup_dir().join("image/snapshot.sqlite")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            // This is best-effort in the test harness; the production helper
            // never deletes A or any backup evidence.
            drop(self.source.take());
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn ensure_with_space(fixture: &Fixture) -> Result<(), String> {
        ensure_with_available_space(&fixture.container, fixture.source(), Some(1_u64 << 60))
    }

    #[test]
    fn creates_a_complete_snapshot_and_receipt_without_mutating_a() {
        let fixture = Fixture::new();
        ensure_with_space(&fixture).unwrap();
        let receipt_path = fixture.backup_dir().join("receipt.json");
        assert!(receipt_path.is_file());
        assert!(fixture.snapshot().is_file());
        assert!(snapshot_is_complete(&fixture.snapshot()));
        let receipt: Receipt = serde_json::from_slice(&fs::read(receipt_path).unwrap()).unwrap();
        assert_eq!(receipt.format, 1);
        assert_eq!(receipt.sha256.len(), 64);
        assert_eq!(
            fixture
                .source()
                .query_row("SELECT value FROM facts", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "original"
        );
    }

    #[test]
    fn completed_pending_image_finishes_receipt_without_copying_new_a_facts() {
        let fixture = Fixture::new();
        ensure_with_space(&fixture).unwrap();
        let before = fs::read(fixture.snapshot()).unwrap();
        fs::remove_file(fixture.backup_dir().join("receipt.json")).unwrap();
        fixture
            .source()
            .execute("UPDATE facts SET value='new-fact'", [])
            .unwrap();

        ensure_with_space(&fixture).unwrap();

        assert_eq!(fs::read(fixture.snapshot()).unwrap(), before);
        assert_eq!(
            fixture
                .source()
                .query_row("SELECT value FROM facts", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "new-fact"
        );
    }

    #[test]
    fn incomplete_owned_image_is_retained_as_a_family_before_retry() {
        let fixture = Fixture::new();
        ensure_with_space(&fixture).unwrap();
        fs::remove_file(fixture.backup_dir().join("receipt.json")).unwrap();
        fs::write(fixture.snapshot(), b"interrupted owned image").unwrap();

        ensure_with_space(&fixture).unwrap();

        let retained = fs::read_dir(fixture.backup_dir())
            .unwrap()
            .filter_map(Result::ok)
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("incomplete-")
            })
            .expect("incomplete image should be retained");
        assert_eq!(
            fs::read(retained.path().join("snapshot.sqlite")).unwrap(),
            b"interrupted owned image"
        );
        assert!(snapshot_is_complete(&fixture.snapshot()));
        assert!(fixture.backup_dir().join("receipt.json").is_file());
    }

    #[test]
    fn unknown_image_without_intent_is_never_moved_or_overwritten() {
        let fixture = Fixture::new();
        let image = fixture.backup_dir().join("image");
        fs::create_dir_all(&image).unwrap();
        let unknown_path = image.join("snapshot.sqlite");
        fs::write(&unknown_path, b"unknown user bytes").unwrap();

        assert!(ensure_with_space(&fixture).is_err());

        assert_eq!(fs::read(&unknown_path).unwrap(), b"unknown user bytes");
        assert!(!fixture.backup_dir().join("receipt.json").exists());
        assert!(fs::read_dir(fixture.backup_dir())
            .unwrap()
            .all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("incomplete-")));
    }
}
