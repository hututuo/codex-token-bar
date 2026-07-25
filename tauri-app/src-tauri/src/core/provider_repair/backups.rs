use crate::core::app_paths;
use crate::models::{ProviderRepairBackupInfo, ProviderRepairBackupRestoreStatus};
use rusqlite::backup::Backup;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, ErrorKind, Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

#[cfg(windows)]
use super::safe_fs::windows_extended_length_path;
use super::safe_fs::{
    physical_file_identity, AtomicInstallPhase, HomeGenerationIdentity, PinnedHome,
};
use super::session_files::{find_session_files, write_file_atomically};
use super::storage_roots::ProviderStorageRoots;

const BACKUP_MANIFEST_SCHEMA_VERSION: u32 = 3;
const RESTORE_JOURNAL_SCHEMA_VERSION: u32 = 3;
const PREVIOUS_BACKUP_MANIFEST_SCHEMA_VERSION: u32 = 2;
const PREVIOUS_RESTORE_JOURNAL_SCHEMA_VERSION: u32 = 2;
const LEGACY_UNSUPPORTED_REASON: &str = "旧版 v1 清单缺少可验证的成员摘要。";
const UNIQUE_DIRECTORY_ATTEMPTS: usize = 64;
const MAX_SYNC_DIRECTORIES: usize = 100_000;
static RECOVERY_POINT_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
struct BackupManifest {
    schema_version: u32,
    complete: bool,
    id: String,
    created_at: String,
    codex_home: String,
    codex_home_fingerprint: String,
    #[serde(default)]
    sqlite_home: Option<String>,
    #[serde(default)]
    sqlite_home_fingerprint: Option<String>,
    target_provider: String,
    members: Vec<BackupMember>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
struct BackupMember {
    kind: String,
    relative_path: String,
    backup_path: Option<String>,
    present: bool,
    size: u64,
    checksum_sha256: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum RestoreJournalPhase {
    Prepared,
    Applying,
    Verified,
    Committed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RestoreJournal {
    schema_version: u32,
    transaction_id: String,
    phase: RestoreJournalPhase,
    codex_home: String,
    codex_home_fingerprint: String,
    home_generation: HomeGenerationIdentity,
    account_identity: String,
    #[serde(default)]
    sqlite_home: Option<String>,
    #[serde(default)]
    sqlite_home_fingerprint: Option<String>,
    #[serde(default)]
    sqlite_home_generation: Option<HomeGenerationIdentity>,
    source_backup_id: String,
    source_backup_path: String,
    members: Vec<BackupMember>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RestoreRecoveryBlocked {
    pub code: String,
    pub recovery_path: Option<PathBuf>,
    pub message: String,
}

impl std::fmt::Display for RestoreRecoveryBlocked {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RestorePhase {
    Capture,
    PublishRecoveryManifest,
    JournalPrepared,
    SyncRecoveryRoot,
    JournalApplying,
    Apply,
    BeforeTempCreate,
    ValidateTemp,
    BeforeReplace,
    SyncDestinationFile,
    SyncDestinationParent,
    CleanupTemp,
    Verify,
    JournalVerified,
    JournalCommitted,
    Compensate,
    Cleanup,
    SyncCleanupRoot,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RestoreCrashPoint {
    Prepared,
    MidApply,
    Verified,
    Committed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum BackupPublicationPhase {
    SyncMemberDirectories,
    PublishManifest,
    SyncBackupDirectory,
    SyncBackupRoot,
}

pub fn list_provider_backups() -> Result<Vec<ProviderRepairBackupInfo>, String> {
    list_provider_backups_at(&provider_backup_root()?)
}

pub(super) fn provider_backup_root() -> Result<PathBuf, String> {
    app_paths::provider_repair_backup_root()
}

pub(super) fn list_provider_backups_at(
    root: &Path,
) -> Result<Vec<ProviderRepairBackupInfo>, String> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("读取备份列表失败：{error}")),
    };

    let mut backups = entries
        .flatten()
        .filter_map(|entry| read_backup_info(&entry.path()).ok())
        .collect::<Vec<_>>();
    backups.sort_by(|a, b| {
        b.created_at
            .cmp(&a.created_at)
            .then_with(|| b.id.cmp(&a.id))
    });
    Ok(backups)
}

#[cfg(test)]
pub(super) fn create_provider_backup_files_at(
    backup_root: &Path,
    codex_home: &Path,
    target_provider: &str,
) -> Result<ProviderRepairBackupInfo, String> {
    create_provider_backup_files_at_with_hook(backup_root, codex_home, target_provider, |_, _| {
        Ok(())
    })
}

#[cfg(test)]
pub(super) fn create_provider_backup_files_at_with_hook(
    backup_root: &Path,
    codex_home: &Path,
    target_provider: &str,
    hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    create_provider_backup_files_at_with_hooks(
        backup_root,
        codex_home,
        target_provider,
        hook,
        |_| Ok(()),
    )
}

#[cfg(test)]
pub(super) fn create_provider_backup_files_at_with_copy_hook(
    backup_root: &Path,
    codex_home: &Path,
    target_provider: &str,
    copy_hook: impl FnMut(&Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    create_provider_backup_files_at_with_hooks(
        backup_root,
        codex_home,
        target_provider,
        |_, _| Ok(()),
        copy_hook,
    )
}

#[cfg(test)]
fn create_provider_backup_files_at_with_hooks(
    backup_root: &Path,
    codex_home: &Path,
    target_provider: &str,
    hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
    mut copy_hook: impl FnMut(&Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    create_provider_backup_files_at_with_pinned_mode(
        backup_root,
        &pinned_home,
        &pinned_home,
        target_provider,
        false,
        true,
        None,
        hook,
        &mut copy_hook,
    )
}

pub(super) fn create_provider_backup_files_at_with_pinned_hook(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    target_provider: &str,
    hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    let mut copy_hook = no_session_copy_hook;
    create_provider_backup_files_at_with_pinned_mode(
        backup_root,
        pinned_home,
        pinned_home,
        target_provider,
        false,
        true,
        None,
        hook,
        &mut copy_hook,
    )
}

pub(super) fn create_provider_backup_files_at_with_pinned_stopped_hook(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    target_provider: &str,
    hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    let mut copy_hook = no_session_copy_hook;
    create_provider_backup_files_at_with_pinned_mode(
        backup_root,
        pinned_home,
        pinned_home,
        target_provider,
        true,
        true,
        None,
        hook,
        &mut copy_hook,
    )
}

pub(super) fn create_provider_backup_files_at_with_pinned_selection_stopped_hook(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    target_provider: &str,
    session_relative_paths: &[PathBuf],
    hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    let mut copy_hook = no_session_copy_hook;
    create_provider_backup_files_at_with_pinned_mode(
        backup_root,
        pinned_home,
        pinned_home,
        target_provider,
        true,
        true,
        Some(session_relative_paths),
        hook,
        &mut copy_hook,
    )
}

pub(super) fn create_provider_backup_files_at_with_pinned_roots_selection_stopped_hook(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    target_provider: &str,
    session_relative_paths: &[PathBuf],
    hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    let mut copy_hook = no_session_copy_hook;
    create_provider_backup_files_at_with_pinned_mode(
        backup_root,
        pinned_home,
        sqlite_home,
        target_provider,
        true,
        false,
        Some(session_relative_paths),
        hook,
        &mut copy_hook,
    )
}

fn create_provider_backup_files_at_with_pinned_mode(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    target_provider: &str,
    codex_stopped: bool,
    include_context_members: bool,
    session_relative_paths: Option<&[PathBuf]>,
    mut hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
    session_copy_hook: &mut impl FnMut(&Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    fs::create_dir_all(backup_root).map_err(|error| error.to_string())?;
    let (id, backup_path) = create_unique_directory(backup_root, "")?;

    let result = build_complete_backup(
        &id,
        &backup_path,
        backup_root,
        pinned_home,
        sqlite_home,
        target_provider,
        codex_stopped,
        include_context_members,
        session_relative_paths,
        &mut hook,
        session_copy_hook,
    );
    if let Err(error) = result {
        let cleanup = cleanup_incomplete_backup(backup_root, &backup_path, &id);
        return Err(format!("{error}{cleanup}"));
    }
    read_backup_info(&backup_path)
}

fn build_complete_backup(
    id: &str,
    backup_path: &Path,
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    target_provider: &str,
    codex_stopped: bool,
    include_context_members: bool,
    session_relative_paths: Option<&[PathBuf]>,
    hook: &mut impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
    session_copy_hook: &mut impl FnMut(&Path) -> Result<(), String>,
) -> Result<(), String> {
    let mut members = Vec::new();
    if include_context_members {
        members.push(
            backup_regular_member(
                pinned_home,
                backup_path,
                "config.toml",
                "config.toml.before",
                "fixed",
            )
            .map_err(|error| format!("备份 config.toml 失败：{error}"))?,
        );
    }
    members.push(
        backup_sqlite_member(sqlite_home, backup_path, codex_stopped)
            .map_err(|error| format!("备份 state_5.sqlite 失败：{error}"))?,
    );
    if include_context_members {
        members.push(
            backup_regular_member(
                pinned_home,
                backup_path,
                "session_index.jsonl",
                "session_index.jsonl.before",
                "fixed",
            )
            .map_err(|error| format!("备份 session_index.jsonl 失败：{error}"))?,
        );
    }
    members.push(absent_member("state_5.sqlite-wal", "sqliteSidecar"));
    members.push(absent_member("state_5.sqlite-shm", "sqliteSidecar"));

    let session_backup_root = backup_path.join("session-prefix");
    pinned_home.ensure_canonical_path_identity()?;
    let session_files = match session_relative_paths {
        Some(relatives) => relatives
            .iter()
            .map(|relative| pinned_home.canonical_path().join(relative))
            .collect(),
        None => find_session_files(pinned_home.canonical_path(), true)?,
    };
    pinned_home.ensure_canonical_path_identity()?;
    for source in session_files {
        let relative = source
            .strip_prefix(pinned_home.canonical_path())
            .map_err(|_| format!("会话文件不在规范 Codex Home 内：{}", source.display()))?;
        validate_relative_member_path(relative, "session")?;
        let backup_relative = PathBuf::from("session-prefix").join(relative);
        let target = backup_path.join(&backup_relative);
        let source_file = pinned_home
            .open_file(relative)?
            .ok_or_else(|| format!("备份会话文件在打开前消失：{}", relative.display()))?;
        let (size, checksum_sha256) = copy_open_first_line_with_hook(
            source_file,
            &target,
            || session_copy_hook(relative),
            || pinned_home.open_file(relative),
        )
        .map_err(|error| format!("备份会话首行 {} 失败：{error}", relative.display()))?;
        members.push(BackupMember {
            kind: "sessionPrefix".into(),
            relative_path: path_to_manifest_string(relative)?,
            backup_path: Some(path_to_manifest_string(&backup_relative)?),
            present: true,
            size,
            checksum_sha256: Some(checksum_sha256),
        });
    }
    pinned_home.ensure_canonical_path_identity()?;
    if !session_backup_root.exists() {
        fs::create_dir_all(&session_backup_root).map_err(|error| error.to_string())?;
    }

    let manifest = BackupManifest {
        schema_version: BACKUP_MANIFEST_SCHEMA_VERSION,
        complete: true,
        id: id.to_string(),
        created_at: format_now_rfc3339(),
        codex_home: pinned_home.canonical_path().display().to_string(),
        codex_home_fingerprint: pinned_home_fingerprint(pinned_home),
        sqlite_home: Some(sqlite_home.canonical_path().display().to_string()),
        sqlite_home_fingerprint: Some(pinned_home_fingerprint(sqlite_home)),
        target_provider: target_provider.to_string(),
        members,
    };
    hook(BackupPublicationPhase::SyncMemberDirectories, backup_path)?;
    sync_directory_tree(backup_path)?;
    let bytes = serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?;
    hook(
        BackupPublicationPhase::PublishManifest,
        &backup_path.join("manifest.json"),
    )?;
    write_file_atomically(&backup_path.join("manifest.json"), &bytes)?;
    hook(BackupPublicationPhase::SyncBackupDirectory, backup_path)?;
    sync_directory(backup_path)?;
    hook(BackupPublicationPhase::SyncBackupRoot, backup_root)?;
    sync_directory(backup_root)?;
    validate_backup_manifest(backup_path).map(|_| ())
}

fn backup_regular_member(
    pinned_home: &PinnedHome,
    backup_path: &Path,
    relative_path: &str,
    backup_relative_path: &str,
    kind: &str,
) -> Result<BackupMember, String> {
    let relative = Path::new(relative_path);
    let Some(source) = pinned_home.open_file(relative)? else {
        return Ok(absent_member(relative_path, kind));
    };
    let target = backup_path.join(backup_relative_path);
    let (size, checksum_sha256) = copy_open_file(source, &target)?;
    Ok(BackupMember {
        kind: kind.into(),
        relative_path: relative_path.into(),
        backup_path: Some(backup_relative_path.into()),
        present: true,
        size,
        checksum_sha256: Some(checksum_sha256),
    })
}

fn backup_sqlite_member(
    pinned_home: &PinnedHome,
    backup_path: &Path,
    codex_stopped: bool,
) -> Result<BackupMember, String> {
    let relative = Path::new("state_5.sqlite");
    let Some(_) = pinned_home.open_file(relative)? else {
        return Ok(absent_member("state_5.sqlite", "sqlite"));
    };
    let source = pinned_home.access_path().join(relative);
    let target = backup_path.join("state_5.sqlite.before");
    if codex_stopped {
        create_consistent_sqlite_snapshot_from_pinned_closed(pinned_home, &target)?;
    } else {
        pinned_home.ensure_canonical_path_identity()?;
        create_consistent_sqlite_snapshot(&source, &target)?;
        pinned_home.ensure_canonical_path_identity()?;
    }
    let size = fs::metadata(&target)
        .map_err(|error| error.to_string())?
        .len();
    let checksum_sha256 = file_sha256(&target)?;
    Ok(BackupMember {
        kind: "sqlite".into(),
        relative_path: "state_5.sqlite".into(),
        backup_path: Some("state_5.sqlite.before".into()),
        present: true,
        size,
        checksum_sha256: Some(checksum_sha256),
    })
}

fn create_consistent_sqlite_snapshot(source: &Path, target: &Path) -> Result<(), String> {
    let source_open_path = sqlite_open_path(source)?;
    let target_open_path = sqlite_open_path(target)?;
    let source_connection =
        Connection::open_with_flags(&source_open_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|error| format!("创建 SQLite 一致性快照失败：{error}"))?;
    let mut target_connection = Connection::open(&target_open_path)
        .map_err(|error| format!("创建 SQLite 一致性快照失败：{error}"))?;
    {
        let backup = Backup::new(&source_connection, &mut target_connection)
            .map_err(|error| format!("创建 SQLite 一致性快照失败：{error}"))?;
        backup
            .run_to_completion(128, Duration::from_millis(5), None)
            .map_err(|error| format!("创建 SQLite 一致性快照失败：{error}"))?;
    }
    target_connection
        .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
        .map_err(|error| format!("固化 SQLite 一致性快照失败：{error}"))?;
    let journal_mode: String = target_connection
        .query_row("PRAGMA journal_mode = DELETE", [], |row| row.get(0))
        .map_err(|error| format!("固化 SQLite 一致性快照日志模式失败：{error}"))?;
    if !journal_mode.eq_ignore_ascii_case("delete") {
        return Err(format!(
            "SQLite 一致性快照日志模式未固化为 delete：{journal_mode}"
        ));
    }
    let integrity: String = target_connection
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|error| format!("验证 SQLite 一致性快照失败：{error}"))?;
    if integrity != "ok" {
        return Err(format!("SQLite 一致性快照 integrity_check: {integrity}"));
    }
    drop(target_connection);
    remove_snapshot_sidecars(target)?;
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(target)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("同步 SQLite 一致性快照 {} 失败：{error}", target.display()))
}

#[cfg(not(windows))]
fn sqlite_open_path(path: &Path) -> Result<PathBuf, String> {
    Ok(path.to_path_buf())
}

#[cfg(windows)]
fn sqlite_open_path(path: &Path) -> Result<PathBuf, String> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;

    let mut wide = windows_extended_length_path(path)?;
    let terminator = wide
        .pop()
        .ok_or_else(|| format!("Windows SQLite 路径为空：{}", path.display()))?;
    if terminator != 0 {
        return Err(format!("Windows SQLite 路径缺少终止符：{}", path.display()));
    }
    Ok(PathBuf::from(OsString::from_wide(&wide)))
}

fn create_consistent_sqlite_snapshot_from_pinned_closed(
    pinned_home: &PinnedHome,
    target: &Path,
) -> Result<(), String> {
    let parent = target
        .parent()
        .ok_or_else(|| format!("SQLite 快照目标缺少父目录：{}", target.display()))?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let (_, stage) = create_unique_directory(parent, ".sqlite-source-")?;
    let result = (|| {
        let main = pinned_home
            .open_file(Path::new("state_5.sqlite"))?
            .ok_or_else(|| "SQLite 主库在一致性快照前消失".to_string())?;
        copy_open_file(main, &stage.join("state_5.sqlite"))?;
        if let Some(wal) = pinned_home.open_file(Path::new("state_5.sqlite-wal"))? {
            copy_open_file(wal, &stage.join("state_5.sqlite-wal"))?;
        }
        sync_directory_tree(&stage)?;
        create_consistent_sqlite_snapshot(&stage.join("state_5.sqlite"), target)
    })();
    match fs::remove_dir_all(&stage) {
        Ok(()) => {
            sync_directory(parent)?;
            result
        }
        Err(error) if error.kind() == ErrorKind::NotFound => result,
        Err(error) => match result {
            Ok(()) => Err(format!(
                "SQLite 一致性快照已创建，但敏感源暂存清理失败，残留于 {}：{error}",
                stage.display()
            )),
            Err(snapshot_error) => Err(format!(
                "{snapshot_error}；敏感源暂存清理失败，残留于 {}：{error}",
                stage.display()
            )),
        },
    }
}

fn remove_snapshot_sidecars(database: &Path) -> Result<(), String> {
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = database.as_os_str().to_os_string();
        sidecar.push(suffix);
        let sidecar = PathBuf::from(sidecar);
        match fs::symlink_metadata(&sidecar) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
                return Err(format!(
                    "SQLite 一致性快照 sidecar 不是普通文件：{}",
                    sidecar.display()
                ))
            }
            Ok(_) => fs::remove_file(&sidecar).map_err(|error| {
                format!(
                    "移除 SQLite 一致性快照 sidecar {} 失败：{error}",
                    sidecar.display()
                )
            })?,
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(())
}

fn absent_member(relative_path: &str, kind: &str) -> BackupMember {
    BackupMember {
        kind: kind.into(),
        relative_path: relative_path.into(),
        backup_path: None,
        present: false,
        size: 0,
        checksum_sha256: None,
    }
}

pub(super) fn backup_by_id(backup_id: &str) -> Result<ProviderRepairBackupInfo, String> {
    backup_by_id_at(&provider_backup_root()?, backup_id)
}

fn backup_by_id_at(
    backup_root: &Path,
    backup_id: &str,
) -> Result<ProviderRepairBackupInfo, String> {
    let trimmed = backup_id.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
    {
        return Err("备份 ID 无效".into());
    }
    read_backup_info(&backup_root.join(trimmed))
}

pub(super) fn ensure_backup_matches_codex_home(
    backup: &ProviderRepairBackupInfo,
    codex_home: &Path,
) -> Result<(), String> {
    if backup.restore_status != ProviderRepairBackupRestoreStatus::Supported {
        return Err(format!(
            "{} 请创建新的 v2 恢复点后再回滚。旧版备份保留于 {}。",
            backup
                .restore_unsupported_reason
                .as_deref()
                .unwrap_or(LEGACY_UNSUPPORTED_REASON),
            backup.path
        ));
    }
    let expected = codex_home_fingerprint(codex_home);
    if backup.codex_home_fingerprint.trim().is_empty() {
        return Err("这个备份缺少 Codex Home 绑定信息，请先为当前目录重新创建备份。".into());
    }
    if backup.codex_home_fingerprint != expected {
        return Err(format!(
            "备份属于 {}，当前目录是 {}。为避免误回滚，请为当前目录重新创建备份。",
            backup.codex_home,
            codex_home_identity(codex_home)
        ));
    }
    Ok(())
}

pub(super) fn verified_session_relative_paths(
    backup: &ProviderRepairBackupInfo,
) -> Result<Vec<PathBuf>, String> {
    let manifest = validate_backup_manifest(Path::new(&backup.path))?;
    if manifest.id != backup.id || manifest.codex_home_fingerprint != backup.codex_home_fingerprint
    {
        return Err("备份 manifest 与恢复点身份不一致。".into());
    }
    if manifest
        .sqlite_home_fingerprint
        .as_deref()
        .unwrap_or(&manifest.codex_home_fingerprint)
        != backup.sqlite_home_fingerprint
    {
        return Err("备份 manifest 与恢复点的 SQLite Home 身份不一致。".into());
    }
    manifest
        .members
        .iter()
        .filter(|member| member.kind == "session" || member.kind == "sessionPrefix")
        .map(|member| manifest_path(&member.relative_path))
        .collect()
}

pub(super) fn verified_member_relative_paths(
    backup: &ProviderRepairBackupInfo,
) -> Result<Vec<PathBuf>, String> {
    let manifest = validate_backup_manifest(Path::new(&backup.path))?;
    if manifest.id != backup.id || manifest.codex_home_fingerprint != backup.codex_home_fingerprint
    {
        return Err("备份 manifest 与恢复点身份不一致。".into());
    }
    if manifest
        .sqlite_home_fingerprint
        .as_deref()
        .unwrap_or(&manifest.codex_home_fingerprint)
        != backup.sqlite_home_fingerprint
    {
        return Err("备份 manifest 与恢复点的 SQLite Home 身份不一致。".into());
    }
    manifest
        .members
        .iter()
        .map(|member| manifest_path(&member.relative_path))
        .collect()
}

pub(super) fn current_member_relative_paths_with_pinned(
    pinned_home: &PinnedHome,
) -> Result<Vec<PathBuf>, String> {
    pinned_home.ensure_canonical_path_identity()?;
    let mut relatives = [
        "config.toml",
        "state_5.sqlite",
        "session_index.jsonl",
        "state_5.sqlite-wal",
        "state_5.sqlite-shm",
    ]
    .into_iter()
    .map(PathBuf::from)
    .collect::<Vec<_>>();
    for source in find_session_files(pinned_home.canonical_path(), true)? {
        let relative = source
            .strip_prefix(pinned_home.canonical_path())
            .map_err(|_| format!("会话文件不在固定 Codex Home 内：{}", source.display()))?;
        validate_relative_member_path(relative, "session")?;
        relatives.push(relative.to_path_buf());
    }
    pinned_home.ensure_canonical_path_identity()?;
    relatives.sort();
    Ok(relatives)
}

pub(super) struct VerifiedSQLiteSnapshot {
    pub(super) path: PathBuf,
    pub(super) size: u64,
    pub(super) checksum_sha256: String,
}

pub(super) fn verified_sqlite_snapshot(
    backup: &ProviderRepairBackupInfo,
) -> Result<Option<VerifiedSQLiteSnapshot>, String> {
    let manifest = validate_backup_manifest(Path::new(&backup.path))?;
    if manifest.id != backup.id || manifest.codex_home_fingerprint != backup.codex_home_fingerprint
    {
        return Err("备份 manifest 与恢复点身份不一致。".into());
    }
    if manifest
        .sqlite_home_fingerprint
        .as_deref()
        .unwrap_or(&manifest.codex_home_fingerprint)
        != backup.sqlite_home_fingerprint
    {
        return Err("备份 manifest 与恢复点的 SQLite Home 身份不一致。".into());
    }
    let sqlite = manifest
        .members
        .iter()
        .find(|member| member.kind == "sqlite")
        .ok_or_else(|| "备份 manifest 缺少 SQLite 成员".to_string())?;
    if !sqlite.present {
        return Ok(None);
    }
    let relative = sqlite
        .backup_path
        .as_deref()
        .ok_or_else(|| "备份 SQLite 成员缺少源路径".to_string())?;
    Ok(Some(VerifiedSQLiteSnapshot {
        path: PathBuf::from(&backup.path).join(manifest_path(relative)?),
        size: sqlite.size,
        checksum_sha256: sqlite
            .checksum_sha256
            .clone()
            .ok_or_else(|| "备份 SQLite 成员缺少 SHA-256".to_string())?,
    }))
}

fn ensure_backup_matches_pinned_home(
    backup: &ProviderRepairBackupInfo,
    pinned_home: &PinnedHome,
) -> Result<(), String> {
    if backup.restore_status != ProviderRepairBackupRestoreStatus::Supported {
        return Err(format!(
            "{} 请创建新的 v2 恢复点后再回滚。旧版备份保留于 {}。",
            backup
                .restore_unsupported_reason
                .as_deref()
                .unwrap_or(LEGACY_UNSUPPORTED_REASON),
            backup.path
        ));
    }
    if backup.codex_home_fingerprint.trim().is_empty() {
        return Err("这个备份缺少 Codex Home 绑定信息，请先为当前目录重新创建备份。".into());
    }
    let expected = pinned_home_fingerprint(pinned_home);
    if backup.codex_home_fingerprint != expected {
        return Err(format!(
            "备份属于 {}，固定的当前目录是 {}。为避免误回滚，请为当前目录重新创建备份。",
            backup.codex_home,
            pinned_home.canonical_path().display()
        ));
    }
    Ok(())
}

fn ensure_backup_matches_pinned_roots(
    backup: &ProviderRepairBackupInfo,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
) -> Result<(), String> {
    ensure_backup_matches_pinned_home(backup, pinned_home)?;
    if backup.sqlite_home_fingerprint.trim().is_empty() {
        return Err(
            "这个恢复点缺少 SQLite Home 绑定信息，请为当前目录重新创建恢复点。".into(),
        );
    }
    if Path::new(&backup.sqlite_home) != sqlite_home.canonical_path() {
        return Err(format!(
            "恢复点记录的 SQLite Home 路径是 {}，当前固定目录是 {}。即使 fingerprint 碰巧相同，也已拒绝回滚。",
            backup.sqlite_home,
            sqlite_home.canonical_path().display()
        ));
    }
    let expected = pinned_home_fingerprint(sqlite_home);
    if backup.sqlite_home_fingerprint != expected {
        return Err(format!(
            "恢复点的 SQLite 库位于 {}，当前生效 SQLite Home 是 {}。为避免修错数据库，已拒绝回滚。",
            backup.sqlite_home,
            sqlite_home.canonical_path().display()
        ));
    }
    Ok(())
}

pub(super) fn restore_provider_backup_files_with_verification(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
    verify: impl FnOnce(&PinnedHome) -> Result<(), String>,
) -> Result<(), String> {
    let roots = ProviderStorageRoots::open(codex_home)?;
    let mut probe = crate::platform::codex_desktop_is_running;
    restore_provider_backup_files_with_home(
        &roots.codex_home,
        &roots.sqlite_home,
        backup,
        &mut noop_restore_hook,
        &mut probe,
        verify,
        None,
    )
    .map(|_| ())
}

pub(super) fn restore_provider_backup_files_with_pinned_roots_verification(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    backup: &ProviderRepairBackupInfo,
    verify: impl FnOnce(&PinnedHome) -> Result<(), String>,
) -> Result<(), String> {
    let backup_path = PathBuf::from(&backup.path);
    let backup_root = backup_path
        .parent()
        .ok_or_else(|| "备份目录缺少父目录".to_string())?;
    reconcile_unfinished_restore_transactions_with_roots(
        backup_root,
        pinned_home,
        sqlite_home,
    )?;
    let mut probe = || Ok(false);
    restore_provider_backup_files_with_home(
        pinned_home,
        sqlite_home,
        backup,
        &mut noop_restore_hook,
        &mut probe,
        verify,
        None,
    )
    .map(|_| ())
}

pub(super) fn restore_provider_backup_files_with_pinned_verification(
    pinned_home: &PinnedHome,
    backup: &ProviderRepairBackupInfo,
    verify: impl FnOnce(&PinnedHome) -> Result<(), String>,
) -> Result<(), String> {
    let backup_path = PathBuf::from(&backup.path);
    let backup_root = backup_path
        .parent()
        .ok_or_else(|| "备份目录缺少父目录".to_string())?;
    reconcile_unfinished_restore_transactions_with_home(backup_root, pinned_home)?;
    let mut probe = || Ok(false);
    restore_provider_backup_files_with_home(
        pinned_home,
        pinned_home,
        backup,
        &mut noop_restore_hook,
        &mut probe,
        verify,
        None,
    )
    .map(|_| ())
}

#[cfg(test)]
pub(super) fn restore_provider_backup_files_at(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
) -> Result<(), String> {
    restore_provider_backup_files_at_with_verification_and_hook(
        codex_home,
        backup,
        |_, _, _| Ok(()),
        |_| Ok(()),
    )
}

#[cfg(test)]
pub(super) fn restore_provider_backup_files_at_with_hook(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
    hook: impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    restore_provider_backup_files_at_with_verification_and_hook(
        codex_home,
        backup,
        hook,
        |_| Ok(()),
    )
}

pub(super) fn restore_provider_backup_files_at_with_verification_and_hook(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
    mut hook: impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
    verify: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<(), String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    let backup_path = PathBuf::from(&backup.path);
    let backup_root = backup_path
        .parent()
        .ok_or_else(|| "备份目录缺少父目录".to_string())?;
    reconcile_unfinished_restore_transactions_with_home(backup_root, &pinned_home)?;
    let mut probe = || Ok(false);
    restore_provider_backup_files_with_home(
        &pinned_home,
        &pinned_home,
        backup,
        &mut hook,
        &mut probe,
        |pinned_home| verify(pinned_home.canonical_path()),
        None,
    )
    .map(|_| ())
}

#[cfg(test)]
pub(super) fn restore_provider_backup_files_at_with_probe_and_hook(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
    mut probe: impl FnMut() -> Result<bool, String>,
    mut hook: impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
    verify: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<(), String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    let backup_path = PathBuf::from(&backup.path);
    let backup_root = backup_path
        .parent()
        .ok_or_else(|| "备份目录缺少父目录".to_string())?;
    reconcile_unfinished_restore_transactions_with_home(backup_root, &pinned_home)?;
    restore_provider_backup_files_with_home(
        &pinned_home,
        &pinned_home,
        backup,
        &mut hook,
        &mut probe,
        |pinned_home| verify(pinned_home.canonical_path()),
        None,
    )
    .map(|_| ())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RestoreStopPoint {
    Prepared,
    MidApply,
    Verified,
    Committed,
}

fn restore_provider_backup_files_with_home(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    backup: &ProviderRepairBackupInfo,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
    probe: &mut impl FnMut() -> Result<bool, String>,
    verify: impl FnOnce(&PinnedHome) -> Result<(), String>,
    stop: Option<RestoreStopPoint>,
) -> Result<Option<PathBuf>, String> {
    ensure_backup_matches_pinned_roots(backup, pinned_home, sqlite_home)?;
    let backup_path = PathBuf::from(&backup.path);
    let manifest = validate_backup_manifest(&backup_path)?;
    if manifest.id != backup.id || manifest.codex_home_fingerprint != backup.codex_home_fingerprint
    {
        return Err("备份 manifest 与所选恢复点身份不一致。".into());
    }
    if manifest
        .sqlite_home
        .as_deref()
        .unwrap_or(&manifest.codex_home)
        != backup.sqlite_home
        || manifest
            .sqlite_home_fingerprint
            .as_deref()
            .unwrap_or(&manifest.codex_home_fingerprint)
            != backup.sqlite_home_fingerprint
    {
        return Err("备份 manifest 与所选恢复点的 SQLite Home 身份不一致。".into());
    }
    let codex_member_paths = manifest
        .members
        .iter()
        .filter(|member| !is_sqlite_member(member))
        .map(|member| manifest_path(&member.relative_path))
        .collect::<Result<Vec<_>, _>>()?;
    let sqlite_member_paths = manifest
        .members
        .iter()
        .filter(|member| is_sqlite_member(member))
        .map(|member| manifest_path(&member.relative_path))
        .collect::<Result<Vec<_>, _>>()?;
    let initial_guard = pinned_home.capture_mutation_guard(&codex_member_paths)?;
    let initial_sqlite_guard = sqlite_home.capture_storage_guard(&sqlite_member_paths)?;

    let backup_root = backup_path
        .parent()
        .ok_or_else(|| "备份目录缺少父目录".to_string())?;
    let (recovery_id, recovery_path) = create_unique_directory(backup_root, ".restore-recovery-")?;
    let mut journal = match capture_and_publish_live_state(
        pinned_home,
        sqlite_home,
        backup_root,
        &recovery_path,
        &recovery_id,
        &backup_path,
        &manifest,
        hook,
    ) {
        Ok(journal) => journal,
        Err(error) => {
            return Err(error_with_recovery_cleanup(
                format!("恢复前状态暂存失败：{error}"),
                backup_root,
                &recovery_path,
                hook,
            ))
        }
    };
    if stop == Some(RestoreStopPoint::Prepared) {
        return Ok(Some(recovery_path));
    }

    let mut mutation_started = false;
    let restore_result: Result<bool, String> = (|| {
        ensure_codex_stopped(probe, "恢复首次写入前")?;
        pinned_home.verify_mutation_guard(&initial_guard)?;
        sqlite_home.verify_storage_guard(&initial_sqlite_guard)?;
        if validate_backup_manifest(&backup_path)? != manifest {
            return Err("恢复源 manifest 在首次写入前发生变化，已拒绝写入。".into());
        }
        transition_restore_journal(
            &recovery_path,
            &mut journal,
            RestoreJournalPhase::Applying,
            RestorePhase::JournalApplying,
            hook,
        )?;
        mutation_started = true;
        if apply_restore_members(
            pinned_home,
            sqlite_home,
            &backup_path,
            &manifest.members,
            hook,
            stop == Some(RestoreStopPoint::MidApply),
        )? {
            return Ok(true);
        }
        hook(RestorePhase::Verify, 0, pinned_home.canonical_path())?;
        verify_installed_members(pinned_home, sqlite_home, &manifest.members)?;
        verify(pinned_home)
            .map_err(|error| format!("恢复后的 Provider 强验证失败：{error}"))?;
        pinned_home.verify_mutation_scope(&initial_guard)?;
        sqlite_home.verify_storage_scope(&initial_sqlite_guard)?;
        let committed_guard = pinned_home.capture_mutation_guard(&codex_member_paths)?;
        let committed_sqlite_guard =
            sqlite_home.capture_storage_guard(&sqlite_member_paths)?;
        transition_restore_journal(
            &recovery_path,
            &mut journal,
            RestoreJournalPhase::Verified,
            RestorePhase::JournalVerified,
            hook,
        )?;
        if stop == Some(RestoreStopPoint::Verified) {
            return Ok(true);
        }
        ensure_codex_stopped(probe, "恢复最终提交前")?;
        pinned_home.verify_mutation_scope(&initial_guard)?;
        sqlite_home.verify_storage_scope(&initial_sqlite_guard)?;
        pinned_home.verify_mutation_guard(&committed_guard)?;
        sqlite_home.verify_storage_guard(&committed_sqlite_guard)?;
        if validate_backup_manifest(&backup_path)? != manifest {
            return Err("恢复源 manifest 在最终提交前发生变化，已拒绝提交。".into());
        }
        transition_restore_journal(
            &recovery_path,
            &mut journal,
            RestoreJournalPhase::Committed,
            RestorePhase::JournalCommitted,
            hook,
        )?;
        Ok(stop == Some(RestoreStopPoint::Committed))
    })();

    if let Ok(true) = restore_result {
        return Ok(Some(recovery_path));
    }
    if let Err(error) = restore_result {
        if !mutation_started {
            return Err(error_with_recovery_cleanup(
                format!("恢复在首次 Home 写入前已拒绝：{error}"),
                backup_root,
                &recovery_path,
                hook,
            ));
        }
        let compensation_errors =
            compensate_restore(
                pinned_home,
                sqlite_home,
                &recovery_path,
                &journal.members,
                hook,
            );
        if compensation_errors.is_empty() {
            if let Err(verification_error) =
                verify_installed_members(pinned_home, sqlite_home, &journal.members)
            {
                return Err(format!(
                    "恢复失败：{error}；恢复补偿强验证失败：{verification_error}；恢复材料保留于 {}，原恢复点仍保留。",
                    recovery_path.display()
                ));
            }
            let message = format!("恢复失败：{error}；已补偿回恢复前状态，原恢复点仍保留。");
            return Err(error_with_recovery_cleanup(
                message,
                backup_root,
                &recovery_path,
                hook,
            ));
        }
        return Err(format!(
            "恢复失败：{error}；恢复补偿未完成：{}；恢复材料保留于 {}，原恢复点仍保留。",
            compensation_errors.join("；"),
            recovery_path.display()
        ));
    }

    cleanup_recovery_path(backup_root, &recovery_path, hook)
        .map_err(|error| format!("恢复已完成，但敏感恢复材料清理失败：{error}"))?;
    Ok(None)
}

fn capture_and_publish_live_state(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    backup_root: &Path,
    recovery_path: &Path,
    recovery_id: &str,
    source_backup_path: &Path,
    source_manifest: &BackupManifest,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<RestoreJournal, String> {
    let home_generation = pinned_home.generation_identity()?;
    let account_identity = pinned_home
        .account_identity_fingerprint()?
        .ok_or_else(|| {
            "恢复前无法确认非 secret 稳定账号身份，已在任何 Provider 写入前拒绝。".to_string()
        })?;
    let canonical_source_backup_path = source_backup_path.canonicalize().map_err(|error| {
        format!(
            "无法固定恢复源备份路径 {}：{error}",
            source_backup_path.display()
        )
    })?;
    let mut captured = Vec::with_capacity(source_manifest.members.len());
    for (index, member) in source_manifest.members.iter().enumerate() {
        let relative = Path::new(&member.relative_path);
        hook(RestorePhase::Capture, index, relative)?;
        if member.kind == "sqliteSidecar" {
            captured.push(absent_member(&member.relative_path, &member.kind));
            continue;
        }
        let member_home = if is_sqlite_member(member) {
            sqlite_home
        } else {
            pinned_home
        };
        let Some(source) = member_home.open_file(relative)? else {
            captured.push(absent_member(&member.relative_path, &member.kind));
            continue;
        };
        let backup_relative = PathBuf::from("live").join(relative);
        let target = recovery_path.join(&backup_relative);
        let (size, checksum_sha256) = if member.kind == "sqlite" {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            }
            drop(source);
            create_consistent_sqlite_snapshot_from_pinned_closed(sqlite_home, &target)?;
            (
                fs::metadata(&target)
                    .map_err(|error| error.to_string())?
                    .len(),
                file_sha256(&target)?,
            )
        } else if member.kind == "sessionPrefix" {
            copy_open_first_line(source, &target)?
        } else {
            copy_open_file(source, &target)?
        };
        captured.push(BackupMember {
            kind: member.kind.clone(),
            relative_path: member.relative_path.clone(),
            backup_path: Some(path_to_manifest_string(&backup_relative)?),
            present: true,
            size,
            checksum_sha256: Some(checksum_sha256),
        });
    }
    let account_identity_after_capture = pinned_home
        .account_identity_fingerprint()?
        .ok_or_else(|| "恢复状态捕获期间账号身份变为未知，已拒绝发布 journal。".to_string())?;
    if account_identity_after_capture != account_identity {
        return Err("恢复状态捕获期间账号身份发生变化，已拒绝发布 journal。".into());
    }
    let journal = RestoreJournal {
        schema_version: RESTORE_JOURNAL_SCHEMA_VERSION,
        transaction_id: recovery_id.to_string(),
        phase: RestoreJournalPhase::Prepared,
        codex_home: source_manifest.codex_home.clone(),
        codex_home_fingerprint: source_manifest.codex_home_fingerprint.clone(),
        home_generation,
        account_identity,
        sqlite_home: Some(sqlite_home.canonical_path().display().to_string()),
        sqlite_home_fingerprint: Some(pinned_home_fingerprint(sqlite_home)),
        sqlite_home_generation: Some(sqlite_home.generation_identity()?),
        source_backup_id: source_manifest.id.clone(),
        source_backup_path: canonical_source_backup_path.display().to_string(),
        members: captured.clone(),
    };
    sync_directory_tree(recovery_path)?;
    hook(
        RestorePhase::PublishRecoveryManifest,
        0,
        &recovery_path.join("recovery-manifest.json"),
    )?;
    write_restore_journal(recovery_path, &journal)?;
    hook(RestorePhase::JournalPrepared, 0, recovery_path)?;
    sync_directory(backup_root)?;
    hook(RestorePhase::SyncRecoveryRoot, 0, backup_root)?;
    Ok(journal)
}

fn apply_restore_members(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    source_root: &Path,
    members: &[BackupMember],
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
    stop_after_first_change: bool,
) -> Result<bool, String> {
    for (index, member) in ordered_restore_members(members).into_iter().enumerate() {
        let relative = Path::new(&member.relative_path);
        hook(RestorePhase::Apply, index, relative)?;
        install_logical_member(
            pinned_home,
            sqlite_home,
            source_root,
            member,
            index,
            hook,
        )
            .map_err(|error| format!("应用恢复成员 {} 失败：{error}", member.relative_path))?;
        if stop_after_first_change && member.kind != "sqliteSidecar" && member.present {
            return Ok(true);
        }
    }
    Ok(false)
}

fn compensate_restore(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    recovery_path: &Path,
    recovery_members: &[BackupMember],
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Vec<String> {
    let mut errors = Vec::new();
    for (index, member) in ordered_restore_members(recovery_members)
        .into_iter()
        .enumerate()
    {
        let relative = Path::new(&member.relative_path);
        let result = match hook(RestorePhase::Compensate, index, relative) {
            Ok(()) => {
                let mut install_hook = noop_restore_hook;
                install_logical_member(
                    pinned_home,
                    sqlite_home,
                    recovery_path,
                    member,
                    index,
                    &mut install_hook,
                )
            }
            Err(error) => Err(error),
        };
        if let Err(error) = result {
            errors.push(format!("{}：{error}", member.relative_path));
        }
    }
    errors
}

fn ordered_restore_members(members: &[BackupMember]) -> Vec<&BackupMember> {
    let mut ordered = Vec::with_capacity(members.len().saturating_sub(2));
    if let Some(sqlite) = members.iter().find(|member| member.kind == "sqlite") {
        ordered.push(sqlite);
    }
    ordered.extend(
        members
            .iter()
            .filter(|member| member.kind != "sqlite" && member.kind != "sqliteSidecar"),
    );
    ordered
}

fn is_sqlite_member(member: &BackupMember) -> bool {
    member.kind == "sqlite" || member.kind == "sqliteSidecar"
}

fn install_logical_member(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    source_root: &Path,
    member: &BackupMember,
    index: usize,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    if member.kind == "sqlite" {
        return install_sqlite_unit(sqlite_home, source_root, member, index, hook);
    }
    let pinned_home = if member.kind == "sqliteSidecar" {
        sqlite_home
    } else {
        pinned_home
    };
    let relative = manifest_path(&member.relative_path)?;
    validate_relative_member_path(&relative, &member.kind)?;
    if member.kind == "sessionPrefix" {
        if !member.present {
            return Err(format!(
                "会话首行差量成员不能是 tombstone：{}",
                member.relative_path
            ));
        }
        let backup_relative = member
            .backup_path
            .as_deref()
            .ok_or_else(|| format!("备份成员缺少源文件：{}", member.relative_path))?;
        let source = source_root.join(manifest_path(backup_relative)?);
        reject_symlink_or_non_file(&source)
            .map_err(|error| format!("验证备份成员源文件 {} 失败：{error}", source.display()))?;
        let replacement = fs::read(&source).map_err(|error| error.to_string())?;
        pinned_home
            .transform_first_line_atomically(
                &relative,
                |current| {
                    if current == replacement {
                        Ok(None)
                    } else {
                        Ok(Some(replacement.clone()))
                    }
                },
                |phase, path| match phase {
                    AtomicInstallPhase::BeforeTempCreate => {
                        hook(RestorePhase::BeforeTempCreate, index, &relative)
                    }
                    AtomicInstallPhase::ValidateTemp => {
                        hook(RestorePhase::ValidateTemp, index, &relative).map_err(|error| {
                            format!("恢复临时文件验证失败 {}：{error}", path.display())
                        })
                    }
                    AtomicInstallPhase::BeforeReplace => {
                        hook(RestorePhase::BeforeReplace, index, &relative)
                    }
                    AtomicInstallPhase::BeforeFileSync => {
                        hook(RestorePhase::SyncDestinationFile, index, &relative)
                    }
                    AtomicInstallPhase::BeforeParentSync => {
                        hook(RestorePhase::SyncDestinationParent, index, &relative)
                    }
                    AtomicInstallPhase::CleanupTemp => {
                        hook(RestorePhase::CleanupTemp, index, &relative)
                    }
                },
            )
            .map(|_| ())
    } else {
    if !member.present {
        pinned_home.remove_file(&relative, || {
            hook(RestorePhase::SyncDestinationParent, index, &relative)
        })?;
        return Ok(());
    }
    let backup_relative = member
        .backup_path
        .as_deref()
        .ok_or_else(|| format!("备份成员缺少源文件：{}", member.relative_path))?;
    let expected_checksum = member
        .checksum_sha256
        .as_deref()
        .ok_or_else(|| format!("备份成员缺少 SHA-256 校验：{}", member.relative_path))?;
    let source = source_root.join(backup_relative);
    reject_symlink_or_non_file(&source)
        .map_err(|error| format!("验证备份成员源文件 {} 失败：{error}", source.display()))?;
    pinned_home.install_atomically(
        &relative,
        Some(member.size),
        Some(expected_checksum),
        |target| {
            let mut source_file = OpenOptions::new()
                .read(true)
                .open(&source)
                .map_err(|error| {
                    format!("打开备份成员源文件 {} 失败：{error}", source.display())
                })?;
            std::io::copy(&mut source_file, target)
                .map(|_| ())
                .map_err(|error| error.to_string())
        },
        |phase, path| match phase {
            AtomicInstallPhase::BeforeTempCreate => {
                hook(RestorePhase::BeforeTempCreate, index, &relative)
            }
            AtomicInstallPhase::ValidateTemp => hook(RestorePhase::ValidateTemp, index, &relative)
                .map_err(|error| format!("恢复临时文件验证失败 {}：{error}", path.display())),
            AtomicInstallPhase::BeforeReplace => {
                hook(RestorePhase::BeforeReplace, index, &relative)
            }
            AtomicInstallPhase::BeforeFileSync => {
                hook(RestorePhase::SyncDestinationFile, index, &relative)
            }
            AtomicInstallPhase::BeforeParentSync => {
                hook(RestorePhase::SyncDestinationParent, index, &relative)
            }
            AtomicInstallPhase::CleanupTemp => hook(RestorePhase::CleanupTemp, index, &relative),
        },
    )
    }
}

fn install_sqlite_unit(
    pinned_home: &PinnedHome,
    source_root: &Path,
    member: &BackupMember,
    index: usize,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    let relative = Path::new("state_5.sqlite");
    remove_sqlite_sidecars(pinned_home, index, hook)?;
    if !member.present {
        pinned_home.remove_file(relative, || {
            hook(RestorePhase::SyncDestinationParent, index, relative)
        })?;
        return verify_installed_sqlite(pinned_home, false);
    }

    let backup_relative = member
        .backup_path
        .as_deref()
        .ok_or_else(|| "SQLite 备份成员缺少源文件".to_string())?;
    let expected_checksum = member
        .checksum_sha256
        .as_deref()
        .ok_or_else(|| "SQLite 备份成员缺少 SHA-256 校验".to_string())?;
    let source = source_root.join(backup_relative);
    reject_symlink_or_non_file(&source)
        .map_err(|error| format!("验证 SQLite 备份源文件 {} 失败：{error}", source.display()))?;
    pinned_home.install_atomically(
        relative,
        Some(member.size),
        Some(expected_checksum),
        |target| {
            let mut source_file = OpenOptions::new()
                .read(true)
                .open(&source)
                .map_err(|error| {
                    format!("打开 SQLite 备份源文件 {} 失败：{error}", source.display())
                })?;
            std::io::copy(&mut source_file, target)
                .map(|_| ())
                .map_err(|error| error.to_string())
        },
        |phase, path| match phase {
            AtomicInstallPhase::BeforeTempCreate => {
                hook(RestorePhase::BeforeTempCreate, index, relative)
            }
            AtomicInstallPhase::ValidateTemp => hook(RestorePhase::ValidateTemp, index, relative)
                .map_err(|error| format!("恢复临时文件验证失败 {}：{error}", path.display())),
            AtomicInstallPhase::BeforeReplace => hook(RestorePhase::BeforeReplace, index, relative),
            AtomicInstallPhase::BeforeFileSync => {
                hook(RestorePhase::SyncDestinationFile, index, relative)
            }
            AtomicInstallPhase::BeforeParentSync => {
                hook(RestorePhase::SyncDestinationParent, index, relative)
            }
            AtomicInstallPhase::CleanupTemp => hook(RestorePhase::CleanupTemp, index, relative),
        },
    )?;
    verify_installed_sqlite(pinned_home, true)
}

fn remove_sqlite_sidecars(
    pinned_home: &PinnedHome,
    index: usize,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    for relative in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
        let relative = Path::new(relative);
        pinned_home.remove_file(relative, || {
            hook(RestorePhase::SyncDestinationParent, index, relative)
        })?;
    }
    Ok(())
}

fn verify_installed_sqlite(pinned_home: &PinnedHome, expected_present: bool) -> Result<(), String> {
    let relative = Path::new("state_5.sqlite");
    if !expected_present {
        if pinned_home.open_file(relative)?.is_some() {
            return Err("SQLite 恢复验证失败：主库本应不存在。".into());
        }
        for sidecar in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
            if pinned_home.open_file(Path::new(sidecar))?.is_some() {
                return Err(format!(
                    "SQLite 恢复验证失败：sidecar 本应不存在：{sidecar}"
                ));
            }
        }
        return Ok(());
    }
    if pinned_home.open_file(relative)?.is_none() {
        return Err("SQLite 恢复验证失败：主库不存在。".into());
    }
    verify_pinned_sqlite_integrity(pinned_home)?;
    for sidecar in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
        if pinned_home.open_file(Path::new(sidecar))?.is_some() {
            return Err(format!("SQLite 恢复验证失败：sidecar 未清理：{sidecar}"));
        }
    }
    Ok(())
}

fn verify_pinned_sqlite_integrity(pinned_home: &PinnedHome) -> Result<(), String> {
    let temp_root = std::env::temp_dir();
    let (_, stage) = create_unique_directory(&temp_root, ".codex-token-bar-sqlite-verify-")?;
    let database = stage.join("state_5.sqlite");
    let result = (|| {
        let source = pinned_home
            .open_file(Path::new("state_5.sqlite"))?
            .ok_or_else(|| "SQLite 恢复验证失败：主库不存在。".to_string())?;
        copy_open_file(source, &database)?;
        let database_open_path = sqlite_open_path(&database)?;
        let connection =
            Connection::open_with_flags(&database_open_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|error| format!("重新打开恢复后的 SQLite 副本失败：{error}"))?;
        let integrity: String = connection
            .query_row("PRAGMA integrity_check", [], |row| row.get(0))
            .map_err(|error| format!("恢复后的 SQLite integrity_check 失败：{error}"))?;
        if integrity != "ok" {
            return Err(format!("恢复后的 SQLite integrity_check: {integrity}"));
        }
        Ok(())
    })();
    match fs::remove_dir_all(&stage) {
        Ok(()) => {
            sync_directory(&temp_root)?;
            result
        }
        Err(error) if error.kind() == ErrorKind::NotFound => result,
        Err(error) => match result {
            Ok(()) => Err(format!(
                "SQLite 恢复验证完成，但敏感验证副本清理失败，残留于 {}：{error}",
                stage.display()
            )),
            Err(verification_error) => Err(format!(
                "{verification_error}；敏感验证副本清理失败，残留于 {}：{error}",
                stage.display()
            )),
        },
    }
}

fn verify_installed_members(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    members: &[BackupMember],
) -> Result<(), String> {
    for member in members {
        let relative = manifest_path(&member.relative_path)?;
        if member.kind == "sqlite" {
            verify_installed_sqlite(sqlite_home, member.present)?;
            if member.present {
                verify_exact_member(sqlite_home, member, &relative)?;
            }
            continue;
        }
        if member.kind == "sessionPrefix" {
            verify_first_line_member(pinned_home, member, &relative)?;
            continue;
        }
        if member.kind == "sqliteSidecar" || !member.present {
            let member_home = if member.kind == "sqliteSidecar" {
                sqlite_home
            } else {
                pinned_home
            };
            if member_home.open_file(&relative)?.is_some() {
                return Err(format!(
                    "恢复成员 tombstone 验证失败，文件仍存在：{}",
                    member.relative_path
                ));
            }
            continue;
        }
        verify_exact_member(pinned_home, member, &relative)?;
    }
    Ok(())
}

fn verify_first_line_member(
    pinned_home: &PinnedHome,
    member: &BackupMember,
    relative: &Path,
) -> Result<(), String> {
    let source = pinned_home
        .open_file(relative)?
        .ok_or_else(|| format!("恢复会话首行不存在：{}", member.relative_path))?;
    let (size, checksum) = first_line_size_and_sha256(source)?;
    let expected_checksum = member
        .checksum_sha256
        .as_deref()
        .ok_or_else(|| format!("恢复成员缺少 SHA-256：{}", member.relative_path))?;
    if size != member.size || checksum != expected_checksum {
        return Err(format!(
            "恢复会话首行 SHA-256 或大小验证失败：{}",
            member.relative_path
        ));
    }
    Ok(())
}

fn verify_exact_member(
    pinned_home: &PinnedHome,
    member: &BackupMember,
    relative: &Path,
) -> Result<(), String> {
    let Some((size, checksum)) = pinned_home.member_len_and_sha256(relative)? else {
        return Err(format!("恢复成员不存在：{}", member.relative_path));
    };
    let expected_checksum = member
        .checksum_sha256
        .as_deref()
        .ok_or_else(|| format!("恢复成员缺少 SHA-256：{}", member.relative_path))?;
    if size != member.size || checksum != expected_checksum {
        return Err(format!(
            "恢复成员 SHA-256 或大小验证失败：{}",
            member.relative_path
        ));
    }
    Ok(())
}

fn first_line_size_and_sha256(mut source: fs::File) -> Result<(u64, String), String> {
    let mut first_line = Vec::new();
    BufReader::new(&mut source)
        .read_until(b'\n', &mut first_line)
        .map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(&first_line);
    Ok((
        u64::try_from(first_line.len()).unwrap_or(u64::MAX),
        format!("{:x}", hasher.finalize()),
    ))
}

fn write_restore_journal(recovery_path: &Path, journal: &RestoreJournal) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(journal).map_err(|error| error.to_string())?;
    write_file_atomically(&recovery_path.join("recovery-manifest.json"), &bytes)?;
    sync_directory(recovery_path)
}

fn transition_restore_journal(
    recovery_path: &Path,
    journal: &mut RestoreJournal,
    phase: RestoreJournalPhase,
    event: RestorePhase,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    journal.phase = phase;
    write_restore_journal(recovery_path, journal)?;
    hook(event, 0, recovery_path)
}

#[cfg(test)]
pub(super) fn simulate_restore_crash_at(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
    point: RestoreCrashPoint,
) -> Result<PathBuf, String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    let stop = match point {
        RestoreCrashPoint::Prepared => RestoreStopPoint::Prepared,
        RestoreCrashPoint::MidApply => RestoreStopPoint::MidApply,
        RestoreCrashPoint::Verified => RestoreStopPoint::Verified,
        RestoreCrashPoint::Committed => RestoreStopPoint::Committed,
    };
    let mut hook = |_, _, _: &Path| Ok(());
    let mut probe = || Ok(false);
    restore_provider_backup_files_with_home(
        &pinned_home,
        &pinned_home,
        backup,
        &mut hook,
        &mut probe,
        |_| Ok(()),
        Some(stop),
    )?
    .ok_or_else(|| "fixture 未停在请求的恢复阶段".to_string())
}

#[cfg(test)]
pub(super) fn simulate_restore_crash_at_with_roots(
    codex_home: &Path,
    sqlite_home: &Path,
    backup: &ProviderRepairBackupInfo,
    point: RestoreCrashPoint,
) -> Result<PathBuf, String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    let pinned_sqlite_home = PinnedHome::open(sqlite_home)?;
    let stop = match point {
        RestoreCrashPoint::Prepared => RestoreStopPoint::Prepared,
        RestoreCrashPoint::MidApply => RestoreStopPoint::MidApply,
        RestoreCrashPoint::Verified => RestoreStopPoint::Verified,
        RestoreCrashPoint::Committed => RestoreStopPoint::Committed,
    };
    let mut hook = |_, _, _: &Path| Ok(());
    let mut probe = || Ok(false);
    restore_provider_backup_files_with_home(
        &pinned_home,
        &pinned_sqlite_home,
        backup,
        &mut hook,
        &mut probe,
        |_| Ok(()),
        Some(stop),
    )?
    .ok_or_else(|| "fixture 未停在请求的恢复阶段".to_string())
}

pub(super) fn reconcile_unfinished_restore_transactions_at(
    backup_root: &Path,
    codex_home: &Path,
) -> Result<(), String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    reconcile_unfinished_restore_transactions_with_home(backup_root, &pinned_home)
}

pub(super) fn reconcile_unfinished_restore_transactions_with_pinned(
    backup_root: &Path,
    pinned_home: &PinnedHome,
) -> Result<(), String> {
    reconcile_unfinished_restore_transactions_with_home(backup_root, pinned_home)
}

pub(super) fn has_unfinished_restore_transactions_for_home_with_pinned(
    backup_root: &Path,
    pinned_home: &PinnedHome,
) -> Result<bool, RestoreRecoveryBlocked> {
    Ok(!unfinished_restore_transactions_for_home(backup_root, pinned_home, pinned_home)?.is_empty())
}

pub(super) fn has_unfinished_restore_transactions_for_roots(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
) -> Result<bool, RestoreRecoveryBlocked> {
    Ok(!unfinished_restore_transactions_for_home(backup_root, pinned_home, sqlite_home)?.is_empty())
}

pub(super) fn first_unfinished_restore_transaction_for_home_with_pinned(
    backup_root: &Path,
    pinned_home: &PinnedHome,
) -> Result<Option<PathBuf>, RestoreRecoveryBlocked> {
    Ok(unfinished_restore_transactions_for_home(backup_root, pinned_home, pinned_home)?
        .into_iter()
        .map(|(path, _)| path)
        .next())
}

pub(super) fn first_unfinished_restore_transaction_for_roots(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
) -> Result<Option<PathBuf>, RestoreRecoveryBlocked> {
    Ok(unfinished_restore_transactions_for_home(backup_root, pinned_home, sqlite_home)?
        .into_iter()
        .map(|(path, _)| path)
        .next())
}

pub(super) fn sqlite_home_for_unfinished_restore_transactions(
    backup_root: &Path,
    pinned_home: &PinnedHome,
) -> Result<Option<PinnedHome>, RestoreRecoveryBlocked> {
    let candidates = unfinished_restore_transaction_paths_at(backup_root)
        .map_err(|error| recovery_blocked("journalDiscoveryFailed", None, error))?;
    let current_home_fingerprint = pinned_home_fingerprint(pinned_home);
    let mut selected_sqlite_home: Option<(PathBuf, String, PathBuf)> = None;

    for recovery_path in candidates {
        let journal = read_restore_journal(&recovery_path).map_err(|error| {
            recovery_blocked("journalInvalid", Some(&recovery_path), error)
        })?;
        validate_recovery_journal(&recovery_path, &journal).map_err(|error| {
            recovery_blocked("journalInvalid", Some(&recovery_path), error)
        })?;
        if journal.codex_home_fingerprint
            != codex_home_fingerprint_for_identity(&journal.codex_home)
        {
            return Err(recovery_blocked(
                "journalInvalid",
                Some(&recovery_path),
                "journal 的 Codex Home 路径与 fingerprint 不一致，无法安全归属",
            ));
        }
        if journal.codex_home_fingerprint != current_home_fingerprint {
            continue;
        }
        validate_journal_source_backup(backup_root, &journal).map_err(|error| {
            recovery_blocked("sourceBackupMismatch", Some(&recovery_path), error)
        })?;

        let sqlite_home = PathBuf::from(
            journal
                .sqlite_home
                .as_deref()
                .unwrap_or(&journal.codex_home),
        );
        let sqlite_home_fingerprint = journal
            .sqlite_home_fingerprint
            .clone()
            .unwrap_or_else(|| journal.codex_home_fingerprint.clone());
        if sqlite_home_fingerprint
            != codex_home_fingerprint_for_identity(&sqlite_home.to_string_lossy())
        {
            return Err(recovery_blocked(
                "journalInvalid",
                Some(&recovery_path),
                "journal 的 SQLite Home 路径与 fingerprint 不一致，无法安全归属",
            ));
        }

        if let Some((selected_path, selected_fingerprint, selected_recovery_path)) =
            selected_sqlite_home.as_ref()
        {
            if selected_path != &sqlite_home || selected_fingerprint != &sqlite_home_fingerprint {
                return Err(recovery_blocked(
                    "sqliteHomeConflict",
                    Some(&recovery_path),
                    format!(
                        "同一 Codex Home 存在互相冲突的 SQLite Home 恢复事务：{} 与 {}",
                        selected_recovery_path.display(),
                        recovery_path.display()
                    ),
                ));
            }
        } else {
            selected_sqlite_home =
                Some((sqlite_home, sqlite_home_fingerprint, recovery_path.clone()));
        }
    }

    let Some((sqlite_home, expected_fingerprint, recovery_path)) = selected_sqlite_home else {
        return Ok(None);
    };
    let pinned_sqlite_home = PinnedHome::open(&sqlite_home).map_err(|error| {
        recovery_blocked(
            "sqliteHomeUnavailable",
            Some(&recovery_path),
            format!(
                "无法固定恢复 journal 记录的 SQLite Home {}：{error}",
                sqlite_home.display()
            ),
        )
    })?;
    if pinned_sqlite_home.canonical_path() != sqlite_home
        || pinned_home_fingerprint(&pinned_sqlite_home) != expected_fingerprint
    {
        return Err(recovery_blocked(
            "sqliteHomeMismatch",
            Some(&recovery_path),
            format!(
                "恢复 journal 记录的 SQLite Home 已重定向或身份不一致：{}",
                sqlite_home.display()
            ),
        ));
    }
    Ok(Some(pinned_sqlite_home))
}

fn unfinished_restore_transaction_paths_at(backup_root: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = match fs::read_dir(backup_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(format!(
                "读取恢复事务目录失败 {}：{error}",
                backup_root.display()
            ))
        }
    };
    let mut candidates = entries
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?
        .into_iter()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name().is_some_and(|name| {
                let name = name.to_string_lossy();
                name.starts_with(".restore-recovery-") || name.starts_with(".restore-quarantine-")
            })
        })
        .collect::<Vec<_>>();
    candidates.sort();
    Ok(candidates)
}

fn reconcile_unfinished_restore_transactions_with_home(
    backup_root: &Path,
    pinned_home: &PinnedHome,
) -> Result<(), String> {
    reconcile_unfinished_restore_transactions_with_roots(backup_root, pinned_home, pinned_home)
}

pub(super) fn reconcile_unfinished_restore_transactions_with_roots(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
) -> Result<(), String> {
    reconcile_unfinished_restore_transactions_with_roots_diagnostics(
        backup_root,
        pinned_home,
        sqlite_home,
    )
    .map_err(|blocked| blocked.message)
}

pub(super) fn reconcile_unfinished_restore_transactions_with_diagnostics(
    backup_root: &Path,
    pinned_home: &PinnedHome,
) -> Result<(), RestoreRecoveryBlocked> {
    reconcile_unfinished_restore_transactions_with_roots_diagnostics(
        backup_root,
        pinned_home,
        pinned_home,
    )
}

pub(super) fn reconcile_unfinished_restore_transactions_with_roots_diagnostics(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
) -> Result<(), RestoreRecoveryBlocked> {
    let transactions =
        unfinished_restore_transactions_for_home(backup_root, pinned_home, sqlite_home)?;

    for (recovery_path, journal) in transactions {
        let mut hook = noop_restore_hook;
        if journal.phase != RestoreJournalPhase::Committed {
            let errors = compensate_restore(
                pinned_home,
                sqlite_home,
                &recovery_path,
                &journal.members,
                &mut hook,
            );
            if !errors.is_empty() {
                return Err(recovery_blocked(
                    "compensationFailed",
                    Some(&recovery_path),
                    format!("恢复事务补偿未完成：{}", errors.join("；")),
                ));
            }
            verify_installed_members(pinned_home, sqlite_home, &journal.members).map_err(
                |error| {
                    recovery_blocked(
                        "compensationVerificationFailed",
                        Some(&recovery_path),
                        error,
                    )
                },
            )?;
        }
        cleanup_recovery_path(backup_root, &recovery_path, &mut hook).map_err(|error| {
            recovery_blocked("recoveryCleanupFailed", Some(&recovery_path), error)
        })?;
    }
    Ok(())
}

fn unfinished_restore_transactions_for_home(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
) -> Result<Vec<(PathBuf, RestoreJournal)>, RestoreRecoveryBlocked> {
    let candidates = unfinished_restore_transaction_paths_at(backup_root)
        .map_err(|error| recovery_blocked("journalDiscoveryFailed", None, error))?;
    let current_home_fingerprint = pinned_home_fingerprint(pinned_home);
    let current_sqlite_home_fingerprint = pinned_home_fingerprint(sqlite_home);
    let mut current_home_identity = None;
    let mut current_sqlite_generation = None;
    let mut transactions = Vec::new();

    for recovery_path in candidates {
        let journal = read_restore_journal(&recovery_path).map_err(|error| {
            recovery_blocked("journalInvalid", Some(&recovery_path), error)
        })?;
        validate_recovery_journal(&recovery_path, &journal).map_err(|error| {
            recovery_blocked("journalInvalid", Some(&recovery_path), error)
        })?;
        if journal.codex_home_fingerprint
            != codex_home_fingerprint_for_identity(&journal.codex_home)
        {
            return Err(recovery_blocked(
                "journalInvalid",
                Some(&recovery_path),
                "journal 的 Codex Home 路径与 fingerprint 不一致，无法安全归属",
            ));
        }
        if journal.codex_home_fingerprint != current_home_fingerprint {
            continue;
        }
        validate_journal_source_backup(backup_root, &journal).map_err(|error| {
            recovery_blocked("sourceBackupMismatch", Some(&recovery_path), error)
        })?;
        let journal_sqlite_home = journal.sqlite_home.as_deref().unwrap_or(&journal.codex_home);
        let journal_sqlite_home_fingerprint = journal
            .sqlite_home_fingerprint
            .as_deref()
            .unwrap_or(&journal.codex_home_fingerprint);
        if journal_sqlite_home_fingerprint
            != codex_home_fingerprint_for_identity(journal_sqlite_home)
        {
            return Err(recovery_blocked(
                "journalInvalid",
                Some(&recovery_path),
                "journal 的 SQLite Home 路径与 fingerprint 不一致，无法安全归属",
            ));
        }
        if journal_sqlite_home_fingerprint != current_sqlite_home_fingerprint {
            return Err(recovery_blocked(
                "sqliteHomeMismatch",
                Some(&recovery_path),
                format!(
                    "journal 的 SQLite Home 是 {journal_sqlite_home}，当前生效目录是 {}",
                    sqlite_home.canonical_path().display()
                ),
            ));
        }
        let (current_generation, current_account) = match &current_home_identity {
            Some(identity) => identity,
            None => {
                let generation = pinned_home.generation_identity().map_err(|error| {
                    recovery_blocked("homeGenerationUnavailable", Some(&recovery_path), error)
                })?;
                let account = pinned_home
                    .account_identity_fingerprint()
                    .map_err(|error| {
                        recovery_blocked("accountIdentityUnknown", Some(&recovery_path), error)
                    })?
                    .ok_or_else(|| {
                        recovery_blocked(
                            "accountIdentityUnknown",
                            Some(&recovery_path),
                            "当前 Home 缺少可验证的非 secret 稳定账号身份",
                        )
                    })?;
                current_home_identity.insert((generation, account))
            }
        };
        if &journal.home_generation != current_generation {
            return Err(recovery_blocked(
                "homeGenerationMismatch",
                Some(&recovery_path),
                "journal 的 Home generation 与当前固定 Home 句柄不一致",
            ));
        }
        if &journal.account_identity != current_account {
            return Err(recovery_blocked(
                "accountIdentityMismatch",
                Some(&recovery_path),
                "journal 的账号身份与当前 Home 账号不一致",
            ));
        }
        if current_sqlite_generation.is_none() {
            current_sqlite_generation =
                Some(sqlite_home.generation_identity().map_err(|error| {
                    recovery_blocked(
                        "sqliteHomeGenerationUnavailable",
                        Some(&recovery_path),
                        error,
                    )
                })?);
        }
        let current_sqlite_generation_value =
            current_sqlite_generation.as_ref().ok_or_else(|| {
                recovery_blocked(
                    "sqliteHomeGenerationUnavailable",
                    Some(&recovery_path),
                    "当前 SQLite Home generation 未初始化，已拒绝恢复",
                )
            })?;
        let journal_sqlite_generation = journal
            .sqlite_home_generation
            .as_ref()
            .unwrap_or(&journal.home_generation);
        if journal_sqlite_generation != current_sqlite_generation_value {
            return Err(recovery_blocked(
                "sqliteHomeGenerationMismatch",
                Some(&recovery_path),
                "journal 的 SQLite Home generation 与当前固定目录句柄不一致",
            ));
        }
        transactions.push((recovery_path, journal));
    }
    Ok(transactions)
}

fn validate_journal_source_backup(
    backup_root: &Path,
    journal: &RestoreJournal,
) -> Result<(), String> {
    let canonical_root = backup_root
        .canonicalize()
        .map_err(|error| format!("无法确认备份根目录 {}：{error}", backup_root.display()))?;
    let recorded_source = PathBuf::from(&journal.source_backup_path);
    let canonical_source = recorded_source.canonicalize().map_err(|error| {
        format!(
            "journal 源备份路径不可用 {}：{error}",
            recorded_source.display()
        )
    })?;
    if recorded_source != canonical_source || canonical_source.parent() != Some(&canonical_root) {
        return Err(format!(
            "journal 源备份路径不属于当前备份根目录：{}",
            recorded_source.display()
        ));
    }
    let manifest = validate_backup_manifest(&canonical_source)?;
    if manifest.id != journal.source_backup_id
        || manifest.codex_home_fingerprint != journal.codex_home_fingerprint
        || manifest
            .sqlite_home_fingerprint
            .as_deref()
            .unwrap_or(&manifest.codex_home_fingerprint)
            != journal
                .sqlite_home_fingerprint
                .as_deref()
                .unwrap_or(&journal.codex_home_fingerprint)
    {
        return Err("journal 源备份 ID、路径或 Home/SQLite Home 身份不一致".into());
    }
    Ok(())
}

fn recovery_blocked(
    code: &str,
    recovery_path: Option<&Path>,
    detail: impl std::fmt::Display,
) -> RestoreRecoveryBlocked {
    let path_message = recovery_path
        .map(|path| format!("，恢复材料保留于 {}", path.display()))
        .unwrap_or_default();
    RestoreRecoveryBlocked {
        code: code.to_string(),
        recovery_path: recovery_path.map(Path::to_path_buf),
        message: format!("Provider recovery blocked [{code}]{path_message}：{detail}"),
    }
}

fn noop_restore_hook(_: RestorePhase, _: usize, _: &Path) -> Result<(), String> {
    Ok(())
}

fn ensure_codex_stopped(
    probe: &mut impl FnMut() -> Result<bool, String>,
    boundary: &str,
) -> Result<(), String> {
    let running = probe().map_err(|error| format!("{boundary}无法确认 Codex 运行状态：{error}"))?;
    if running {
        return Err(format!("{boundary}检测到 Codex 正在运行，已拒绝继续提交。"));
    }
    Ok(())
}

fn read_restore_journal(recovery_path: &Path) -> Result<RestoreJournal, String> {
    let metadata = fs::symlink_metadata(recovery_path).map_err(|error| error.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("恢复事务目录不是普通目录".into());
    }
    let path = recovery_path.join("recovery-manifest.json");
    reject_symlink_or_non_file(&path)?;
    let journal: RestoreJournal =
        serde_json::from_slice(&fs::read(&path).map_err(|error| error.to_string())?)
            .map_err(|error| format!("恢复事务 journal 无效：{error}"))?;
    if !matches!(
        journal.schema_version,
        PREVIOUS_RESTORE_JOURNAL_SCHEMA_VERSION | RESTORE_JOURNAL_SCHEMA_VERSION
    ) {
        return Err("恢复事务 journal 版本不受支持".into());
    }
    Ok(journal)
}

fn validate_recovery_journal(recovery_path: &Path, journal: &RestoreJournal) -> Result<(), String> {
    if recovery_path.file_name().and_then(|name| name.to_str())
        != Some(journal.transaction_id.as_str())
        && !recovery_path
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with(".restore-quarantine-"))
    {
        return Err("恢复事务 ID 与目录不一致".into());
    }
    if journal.schema_version >= 3 {
        let sqlite_home = journal
            .sqlite_home
            .as_deref()
            .ok_or_else(|| "v3 恢复 journal 缺少 sqlite_home。".to_string())?;
        let sqlite_home_fingerprint = journal
            .sqlite_home_fingerprint
            .as_deref()
            .ok_or_else(|| "v3 恢复 journal 缺少 sqlite_home_fingerprint。".to_string())?;
        if journal.sqlite_home_generation.is_none()
            || !Path::new(sqlite_home).is_absolute()
            || sqlite_home_fingerprint
                != codex_home_fingerprint_for_identity(sqlite_home)
        {
            return Err("v3 恢复 journal 的 SQLite Home 身份无效。".into());
        }
    }
    validate_member_set(
        recovery_path,
        &journal.members,
        false,
        journal.phase != RestoreJournalPhase::Committed,
        journal.schema_version,
    )
}

fn error_with_recovery_cleanup(
    message: String,
    backup_root: &Path,
    recovery_path: &Path,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> String {
    match cleanup_recovery_path(backup_root, recovery_path, hook) {
        Ok(()) => message,
        Err(cleanup_error) => format!("{message}；{cleanup_error}"),
    }
}

fn cleanup_recovery_path(
    backup_root: &Path,
    recovery_path: &Path,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    let removal = hook(RestorePhase::Cleanup, 0, recovery_path).and_then(|_| {
        match fs::remove_dir_all(recovery_path) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
            Err(error) => Err(format!("清理 {} 失败：{error}", recovery_path.display())),
        }
    });
    match removal {
        Ok(changed) => {
            if changed {
                sync_directory(backup_root)?;
                hook(RestorePhase::SyncCleanupRoot, 0, backup_root)?;
            }
            Ok(())
        }
        Err(error) => quarantine_recovery_path(backup_root, recovery_path, &error, hook),
    }
}

fn quarantine_recovery_path(
    root: &Path,
    path: &Path,
    cleanup_error: &str,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    for _ in 0..UNIQUE_DIRECTORY_ATTEMPTS {
        let quarantine = root.join(format!(".restore-quarantine-{}", collision_resistant_id()));
        match fs::rename(path, &quarantine) {
            Ok(()) => {
                sync_directory(root)?;
                hook(RestorePhase::SyncCleanupRoot, 0, root)?;
                return Err(format!(
                    "{cleanup_error}；恢复材料已隔离到 {}",
                    quarantine.display()
                ));
            }
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(format!(
                    "{cleanup_error}；隔离失败：{error}；恢复材料仍位于 {}",
                    path.display()
                ))
            }
        }
    }
    Err(format!(
        "{cleanup_error}；无法创建唯一隔离路径；恢复材料仍位于 {}",
        path.display()
    ))
}

fn validate_backup_manifest(backup_path: &Path) -> Result<BackupManifest, String> {
    let metadata = fs::symlink_metadata(backup_path).map_err(|error| error.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!("备份目录无效：{}", backup_path.display()));
    }
    let canonical_backup = backup_path
        .canonicalize()
        .map_err(|error| error.to_string())?;
    let manifest_path = backup_path.join("manifest.json");
    reject_symlink_or_non_file(&manifest_path)?;
    let manifest: BackupManifest =
        serde_json::from_slice(&fs::read(&manifest_path).map_err(|error| error.to_string())?)
            .map_err(|error| format!("备份 manifest 无效：{error}"))?;
    if !matches!(
        manifest.schema_version,
        PREVIOUS_BACKUP_MANIFEST_SCHEMA_VERSION | BACKUP_MANIFEST_SCHEMA_VERSION
    ) || !manifest.complete
    {
        return Err("备份 manifest 未完整提交或版本不受支持。".into());
    }
    if backup_path.file_name().and_then(|name| name.to_str()) != Some(manifest.id.as_str()) {
        return Err("备份 manifest ID 与目录不一致。".into());
    }
    if manifest.schema_version >= 3 {
        let sqlite_home = manifest
            .sqlite_home
            .as_deref()
            .ok_or_else(|| "v3 备份 manifest 缺少 sqlite_home。".to_string())?;
        let sqlite_home_fingerprint = manifest
            .sqlite_home_fingerprint
            .as_deref()
            .ok_or_else(|| "v3 备份 manifest 缺少 sqlite_home_fingerprint。".to_string())?;
        if !Path::new(sqlite_home).is_absolute()
            || sqlite_home_fingerprint
                != codex_home_fingerprint_for_identity(sqlite_home)
        {
            return Err("v3 备份 manifest 的 SQLite Home 路径或 fingerprint 无效。".into());
        }
    }

    validate_member_set(
        &canonical_backup,
        &manifest.members,
        true,
        true,
        manifest.schema_version,
    )?;
    Ok(manifest)
}

fn validate_member_set(
    source_root: &Path,
    members: &[BackupMember],
    standard_backup_mapping: bool,
    verify_source_files: bool,
    schema_version: u32,
) -> Result<(), String> {
    let canonical_source_root = source_root
        .canonicalize()
        .map_err(|error| format!("无法确认备份成员根目录 {}：{error}", source_root.display()))?;
    let mut destinations = HashSet::new();
    let mut backup_sources = HashSet::new();
    let mut config_members = 0_usize;
    let mut sqlite_members = 0_usize;
    let mut index_members = 0_usize;
    let mut wal_members = 0_usize;
    let mut shm_members = 0_usize;
    for member in members {
        let relative = manifest_path(&member.relative_path)?;
        validate_relative_member_path(&relative, &member.kind)?;
        let destination_identity = manifest_identity_key(&member.relative_path);
        if !destinations.insert(destination_identity) {
            return Err(format!(
                "备份 manifest 包含大小写逻辑重复或规范化重复成员：{}",
                member.relative_path
            ));
        }
        match (member.kind.as_str(), member.relative_path.as_str()) {
            ("fixed", "config.toml") => config_members += 1,
            ("sqlite", "state_5.sqlite") => sqlite_members += 1,
            ("fixed", "session_index.jsonl") => index_members += 1,
            ("sqliteSidecar", "state_5.sqlite-wal") => wal_members += 1,
            ("sqliteSidecar", "state_5.sqlite-shm") => shm_members += 1,
            ("session", _) => {
                if !member.present {
                    return Err(format!(
                        "备份 manifest 会话成员必须存在：{}",
                        member.relative_path
                    ));
                }
            }
            ("sessionPrefix", _) if schema_version >= 3 => {
                if !member.present {
                    return Err(format!(
                        "备份 manifest 会话元数据成员必须存在：{}",
                        member.relative_path
                    ));
                }
            }
            _ => {
                return Err(format!(
                    "备份 manifest 包含额外成员：{}",
                    member.relative_path
                ))
            }
        }

        let expected_backup_path = if standard_backup_mapping {
            expected_backup_path(member, schema_version)?
        } else if member.present {
            Some(path_to_manifest_string(
                &PathBuf::from("live").join(&relative),
            )?)
        } else {
            None
        };
        if member.backup_path.as_deref() != expected_backup_path.as_deref() {
            return Err(format!(
                "备份 manifest 成员源路径不符合 v2 映射：{}",
                member.relative_path
            ));
        }
        match (member.present, member.backup_path.as_deref()) {
            (false, None) if member.size == 0 && member.checksum_sha256.is_none() => {}
            (true, Some(backup_relative)) => {
                let backup_relative_path = manifest_path(backup_relative)?;
                if !backup_sources.insert(manifest_identity_key(backup_relative)) {
                    return Err(format!(
                        "备份 manifest 包含大小写逻辑重复或规范化重复源路径：{backup_relative}"
                    ));
                }
                if !verify_source_files {
                    continue;
                }
                let source = source_root.join(&backup_relative_path);
                reject_symlink_or_non_file(&source)?;
                let canonical_source = source.canonicalize().map_err(|error| error.to_string())?;
                if !canonical_source.starts_with(&canonical_source_root) {
                    return Err(format!("备份成员源路径越界：{}", source.display()));
                }
                let size = fs::metadata(&source)
                    .map_err(|error| error.to_string())?
                    .len();
                if size != member.size {
                    return Err(format!("备份成员大小不一致：{}", member.relative_path));
                }
                let expected_checksum = member.checksum_sha256.as_deref().ok_or_else(|| {
                    format!("备份成员缺少 SHA-256 校验：{}", member.relative_path)
                })?;
                let actual_checksum = file_sha256(&source)?;
                if actual_checksum != expected_checksum {
                    return Err(format!(
                        "备份成员 SHA-256 校验失败：{}",
                        member.relative_path
                    ));
                }
            }
            _ => return Err(format!("备份成员状态不完整：{}", member.relative_path)),
        }
    }
    let context_members_valid = if schema_version >= 3 {
        config_members == index_members && config_members <= 1
    } else {
        config_members == 1 && index_members == 1
    };
    if !context_members_valid
        || sqlite_members != 1
        || wal_members != 1
        || shm_members != 1
    {
        return Err(format!(
            "备份 manifest 必需成员数量无效：config={config_members}, sqlite={sqlite_members}, index={index_members}, wal={wal_members}, shm={shm_members}"
        ));
    }
    Ok(())
}

fn expected_backup_path(
    member: &BackupMember,
    schema_version: u32,
) -> Result<Option<String>, String> {
    if !member.present {
        return Ok(None);
    }
    let expected = match (member.kind.as_str(), member.relative_path.as_str()) {
        ("fixed", "config.toml") => PathBuf::from("config.toml.before"),
        ("sqlite", "state_5.sqlite") => PathBuf::from("state_5.sqlite.before"),
        ("fixed", "session_index.jsonl") => PathBuf::from("session_index.jsonl.before"),
        ("session", _) => PathBuf::from("session-jsonl").join(&member.relative_path),
        ("sessionPrefix", _) if schema_version >= 3 => {
            PathBuf::from("session-prefix").join(&member.relative_path)
        }
        ("sqliteSidecar", _) => {
            return Err(format!(
                "备份 manifest SQLite sidecar 必须是 tombstone：{}",
                member.relative_path
            ))
        }
        _ => {
            return Err(format!(
                "备份 manifest 成员类型无效：{}",
                member.relative_path
            ))
        }
    };
    path_to_manifest_string(&expected).map(Some)
}

fn validate_relative_member_path(relative: &Path, kind: &str) -> Result<(), String> {
    validate_normal_relative_path(relative)?;
    let allowed = match kind {
        "fixed" => matches!(
            relative.to_str(),
            Some("config.toml" | "session_index.jsonl")
        ),
        "sqlite" => relative == Path::new("state_5.sqlite"),
        "sqliteSidecar" => matches!(
            relative.to_str(),
            Some("state_5.sqlite-wal" | "state_5.sqlite-shm")
        ),
        "session" => {
            relative
                .extension()
                .is_some_and(|extension| extension == "jsonl")
                && matches!(
                    relative.components().next(),
                    Some(Component::Normal(root))
                        if root == "sessions" || root == "archived_sessions"
                )
        }
        "sessionPrefix" => {
            relative
                .extension()
                .is_some_and(|extension| extension == "jsonl")
                && matches!(
                    relative.components().next(),
                    Some(Component::Normal(root))
                        if root == "sessions" || root == "archived_sessions"
                )
        }
        _ => false,
    };
    if allowed {
        Ok(())
    } else {
        Err(format!(
            "备份 manifest 成员路径或类型无效：{}",
            relative.display()
        ))
    }
}

fn validate_normal_relative_path(path: &Path) -> Result<(), String> {
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(format!("备份成员路径无效：{}", path.display()));
    }
    Ok(())
}

fn manifest_path(serialized: &str) -> Result<PathBuf, String> {
    if serialized.is_empty()
        || serialized.starts_with('/')
        || serialized.ends_with('/')
        || serialized.contains('\\')
        || serialized
            .split('/')
            .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(format!("备份成员路径不是唯一非规范序列化：{serialized}"));
    }
    let mut path = PathBuf::new();
    for component in serialized.split('/') {
        path.push(component);
    }
    validate_normal_relative_path(&path)?;
    Ok(path)
}

fn manifest_identity_key(serialized: &str) -> String {
    if cfg!(any(target_os = "macos", windows)) {
        serialized.to_lowercase()
    } else {
        serialized.to_string()
    }
}

fn read_backup_info(path: &Path) -> Result<ProviderRepairBackupInfo, String> {
    let manifest_path = path.join("manifest.json");
    reject_symlink_or_non_file(&manifest_path)?;
    let bytes = fs::read(&manifest_path).map_err(|error| error.to_string())?;
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|error| format!("备份 manifest 无效：{error}"))?;
    if value.get("schema_version").is_none() {
        return read_legacy_backup_info(path, &value);
    }

    let manifest = validate_backup_manifest(path)?;
    let session_files = manifest
        .members
        .iter()
        .filter(|member| {
            (member.kind == "session" || member.kind == "sessionPrefix") && member.present
        })
        .count();
    let sqlite_home = manifest
        .sqlite_home
        .clone()
        .unwrap_or_else(|| manifest.codex_home.clone());
    let sqlite_home_fingerprint = manifest
        .sqlite_home_fingerprint
        .clone()
        .unwrap_or_else(|| manifest.codex_home_fingerprint.clone());
    Ok(ProviderRepairBackupInfo {
        id: manifest.id,
        created_at: manifest.created_at,
        path: path.display().to_string(),
        codex_home: manifest.codex_home,
        codex_home_fingerprint: manifest.codex_home_fingerprint,
        sqlite_home,
        sqlite_home_fingerprint,
        target_provider: manifest.target_provider,
        session_files: u32::try_from(session_files).unwrap_or(u32::MAX),
        state_database: manifest
            .members
            .iter()
            .any(|member| member.relative_path == "state_5.sqlite" && member.present),
        session_index: manifest
            .members
            .iter()
            .any(|member| member.relative_path == "session_index.jsonl" && member.present),
        restore_status: ProviderRepairBackupRestoreStatus::Supported,
        restore_unsupported_reason: None,
    })
}

fn read_legacy_backup_info(path: &Path, value: &Value) -> Result<ProviderRepairBackupInfo, String> {
    if value.get("members").is_some()
        || value.get("complete").is_some()
        || value
            .get("target_provider")
            .and_then(Value::as_str)
            .is_none()
    {
        return Err("备份 manifest 既不是完整 v2，也不是可识别的 v1 清单。".into());
    }
    Ok(ProviderRepairBackupInfo {
        id: value
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_else(|| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("unknown")
            })
            .into(),
        created_at: value
            .get("created_at")
            .and_then(Value::as_str)
            .unwrap_or("未知时间")
            .into(),
        path: path.display().to_string(),
        codex_home: value
            .get("codex_home")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .into(),
        codex_home_fingerprint: value
            .get("codex_home_fingerprint")
            .and_then(Value::as_str)
            .unwrap_or("")
            .into(),
        sqlite_home: value
            .get("codex_home")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .into(),
        sqlite_home_fingerprint: value
            .get("codex_home_fingerprint")
            .and_then(Value::as_str)
            .unwrap_or("")
            .into(),
        target_provider: value
            .get("target_provider")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .into(),
        session_files: value
            .get("session_files")
            .and_then(Value::as_u64)
            .and_then(|count| u32::try_from(count).ok())
            .unwrap_or(0),
        state_database: value
            .get("state_database")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        session_index: value
            .get("session_index")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        restore_status: ProviderRepairBackupRestoreStatus::LegacyUnsupported,
        restore_unsupported_reason: Some(LEGACY_UNSUPPORTED_REASON.into()),
    })
}

pub(super) fn codex_home_identity(codex_home: &Path) -> String {
    codex_home
        .canonicalize()
        .unwrap_or_else(|_| codex_home.to_path_buf())
        .display()
        .to_string()
}

pub(super) fn codex_home_fingerprint(codex_home: &Path) -> String {
    codex_home_fingerprint_for_identity(&codex_home_identity(codex_home))
}

pub(super) fn pinned_home_fingerprint(pinned_home: &PinnedHome) -> String {
    codex_home_fingerprint_for_identity(&pinned_home.canonical_path().display().to_string())
}

fn codex_home_fingerprint_for_identity(identity: &str) -> String {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in identity.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

fn no_session_copy_hook(_path: &Path) -> Result<(), String> {
    Ok(())
}

fn copy_open_first_line(mut source: fs::File, target: &Path) -> Result<(u64, String), String> {
    let opened = source.metadata().map_err(|error| error.to_string())?;
    let mut first_line = Vec::new();
    BufReader::new(&mut source)
        .read_until(b'\n', &mut first_line)
        .map_err(|error| error.to_string())?;
    let completed = source.metadata().map_err(|error| error.to_string())?;
    if completed.len() != opened.len() || completed.modified().ok() != opened.modified().ok() {
        return Err("源文件在首行差量捕获期间发生变化".into());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut target_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)
        .map_err(|error| error.to_string())?;
    target_file
        .write_all(&first_line)
        .and_then(|_| target_file.sync_all())
        .map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(&first_line);
    Ok((
        u64::try_from(first_line.len()).unwrap_or(u64::MAX),
        format!("{:x}", hasher.finalize()),
    ))
}

fn copy_open_file(mut source: fs::File, target: &Path) -> Result<(u64, String), String> {
    let opened = source.metadata().map_err(|error| error.to_string())?;
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut target_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)
        .map_err(|error| error.to_string())?;
    let size = std::io::copy(&mut source, &mut target_file).map_err(|error| error.to_string())?;
    target_file.sync_all().map_err(|error| error.to_string())?;
    drop(target_file);
    let completed = source.metadata().map_err(|error| error.to_string())?;
    if size != opened.len()
        || completed.len() != opened.len()
        || completed.modified().ok() != opened.modified().ok()
    {
        let _ = fs::remove_file(target);
        return Err("源文件在描述符复制期间发生变化，拒绝发布不完整快照".into());
    }
    Ok((size, file_sha256(target)?))
}

fn copy_open_first_line_with_hook(
    mut source: fs::File,
    target: &Path,
    after_descriptor_open: impl FnOnce() -> Result<(), String>,
    reopen_live_path: impl FnOnce() -> Result<Option<fs::File>, String>,
) -> Result<(u64, String), String> {
    let opened = source.metadata().map_err(|error| error.to_string())?;
    let opened_modified = opened.modified().map_err(|error| error.to_string())?;
    let opened_identity = physical_file_identity(&source)?;
    let mut opened_first_line = Vec::new();
    BufReader::new(&mut source)
        .read_until(b'\n', &mut opened_first_line)
        .map_err(|error| error.to_string())?;
    source
        .seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    after_descriptor_open()?;
    let mut captured_first_line = Vec::new();
    BufReader::new(&mut source)
        .read_until(b'\n', &mut captured_first_line)
        .map_err(|error| error.to_string())?;
    let completed = source.metadata().map_err(|error| error.to_string())?;
    let completed_modified = completed.modified().map_err(|error| error.to_string())?;
    let mut live = reopen_live_path()?
        .ok_or_else(|| "源文件在描述符复制期间消失".to_string())?;
    let live_metadata = live.metadata().map_err(|error| error.to_string())?;
    let live_modified = live_metadata.modified().map_err(|error| error.to_string())?;
    let live_identity = physical_file_identity(&live)?;
    let mut live_first_line = Vec::new();
    BufReader::new(&mut live)
        .read_until(b'\n', &mut live_first_line)
        .map_err(|error| error.to_string())?;
    if completed.len() != opened.len()
        || completed_modified != opened_modified
        || live_metadata.len() != opened.len()
        || live_modified != opened_modified
        || live_identity != opened_identity
        || captured_first_line != opened_first_line
        || live_first_line != opened_first_line
    {
        return Err("源文件在描述符复制期间发生变化，拒绝发布不完整快照".into());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut target_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)
        .map_err(|error| error.to_string())?;
    target_file
        .write_all(&opened_first_line)
        .and_then(|_| target_file.sync_all())
        .map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(&opened_first_line);
    Ok((
        u64::try_from(opened_first_line.len()).unwrap_or(u64::MAX),
        format!("{:x}", hasher.finalize()),
    ))
}

fn reject_symlink_or_non_file(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("拒绝读取符号链接或非普通文件：{}", path.display()));
    }
    Ok(())
}

fn file_sha256(path: &Path) -> Result<String, String> {
    let mut file = OpenOptions::new()
        .read(true)
        .open(path)
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

fn sync_directory_tree(root: &Path) -> Result<(), String> {
    let mut pending = vec![root.to_path_buf()];
    let mut directories = Vec::new();
    while let Some(directory) = pending.pop() {
        if directories.len() >= MAX_SYNC_DIRECTORIES {
            return Err(format!(
                "恢复点目录数量超过安全上限 {MAX_SYNC_DIRECTORIES}：{}",
                root.display()
            ));
        }
        let metadata = fs::symlink_metadata(&directory).map_err(|error| error.to_string())?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(format!("拒绝同步非普通目录：{}", directory.display()));
        }
        for entry in fs::read_dir(&directory).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            let metadata = fs::symlink_metadata(entry.path()).map_err(|error| error.to_string())?;
            if metadata.file_type().is_symlink() {
                return Err(format!(
                    "恢复点目录包含符号链接：{}",
                    entry.path().display()
                ));
            }
            if metadata.is_dir() {
                pending.push(entry.path());
            }
        }
        directories.push(directory);
    }
    directories.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
    for directory in directories {
        sync_directory(&directory)?;
    }
    Ok(())
}

#[cfg(not(windows))]
fn sync_directory(path: &Path) -> Result<(), String> {
    OpenOptions::new()
        .read(true)
        .open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("同步目录 {} 失败：{error}", path.display()))
}

#[cfg(any(test, windows))]
#[derive(Clone, Copy, Debug)]
struct WindowsDirectorySyncContract {
    desired_access: u32,
    share_mode: u32,
    flags_and_attributes: u32,
}

#[cfg(any(test, windows))]
fn windows_directory_sync_contract() -> WindowsDirectorySyncContract {
    WindowsDirectorySyncContract {
        desired_access: 0x4000_0000,
        share_mode: 0x0000_0001 | 0x0000_0002 | 0x0000_0004,
        flags_and_attributes: 0x0200_0000 | 0x0020_0000,
    }
}

#[cfg(windows)]
fn sync_directory(path: &Path) -> Result<(), String> {
    use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle};
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FileAttributeTagInfo, GetFileInformationByHandleEx, FILE_ATTRIBUTE_DIRECTORY,
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_ATTRIBUTE_TAG_INFO, OPEN_EXISTING,
    };

    let contract = windows_directory_sync_contract();
    let wide = windows_extended_length_path(path)?;
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            contract.desired_access,
            contract.share_mode,
            std::ptr::null(),
            OPEN_EXISTING,
            contract.flags_and_attributes,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(format!(
            "打开目录以执行持久化同步失败 {}：{}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let directory = unsafe { fs::File::from_raw_handle(handle as RawHandle) };
    let mut attributes = FILE_ATTRIBUTE_TAG_INFO::default();
    let info_ok = unsafe {
        GetFileInformationByHandleEx(
            directory.as_raw_handle() as _,
            FileAttributeTagInfo,
            (&mut attributes as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_ATTRIBUTE_TAG_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if info_ok == 0 {
        return Err(format!(
            "读取待同步目录属性失败 {}：{}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    if attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
    {
        return Err(format!("拒绝同步重解析点或非目录：{}", path.display()));
    }
    directory
        .sync_all()
        .map_err(|error| format!("同步目录 {} 失败：{error}", path.display()))
}

fn create_unique_directory(root: &Path, prefix: &str) -> Result<(String, PathBuf), String> {
    fs::create_dir_all(root).map_err(|error| error.to_string())?;
    for _ in 0..UNIQUE_DIRECTORY_ATTEMPTS {
        let id = format!("{prefix}{}", collision_resistant_id());
        let path = root.join(&id);
        match fs::create_dir(&path) {
            Ok(()) => return Ok((id, path)),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.to_string()),
        }
    }
    Err("无法创建唯一 Provider 恢复点目录".into())
}

fn cleanup_incomplete_backup(root: &Path, path: &Path, id: &str) -> String {
    cleanup_incomplete_backup_with_ops(
        root,
        path,
        id,
        |candidate| fs::remove_dir_all(candidate),
        |from, to| fs::rename(from, to),
        |parent| sync_directory(parent),
    )
}

fn cleanup_incomplete_backup_with_ops(
    root: &Path,
    path: &Path,
    id: &str,
    remove: impl FnOnce(&Path) -> std::io::Result<()>,
    mut rename: impl FnMut(&Path, &Path) -> std::io::Result<()>,
    mut sync_parent: impl FnMut(&Path) -> Result<(), String>,
) -> String {
    match remove(path) {
        Ok(()) => match sync_parent(root) {
            Ok(()) => String::new(),
            Err(sync_error) => format!(
                "；未完成目录 {} 已删除，但父目录同步失败：{sync_error}",
                path.display()
            ),
        },
        Err(remove_error) if remove_error.kind() == ErrorKind::NotFound => {
            format!("；未完成目录已不存在：{}", path.display())
        }
        Err(remove_error) => {
            let quarantine = root.join(format!(".incomplete-{id}"));
            match rename(path, &quarantine) {
                Ok(()) => match sync_parent(root) {
                    Ok(()) => format!("；未完成目录已隔离到 {}", quarantine.display()),
                    Err(sync_error) => format!(
                        "；未完成目录已隔离到 {}，但父目录同步失败：{sync_error}",
                        quarantine.display()
                    ),
                },
                Err(rename_error) if rename_error.kind() == ErrorKind::NotFound => format!(
                    "；未完成目录清理失败：{remove_error}；隔离时目录已不存在：{}",
                    path.display()
                ),
                Err(rename_error) => format!(
                    "；未完成目录清理失败：{remove_error}；隔离失败：{rename_error}；残留目录仍位于 {}",
                    path.display()
                ),
            }
        }
    }
}

fn path_to_manifest_string(path: &Path) -> Result<String, String> {
    validate_normal_relative_path(path)?;
    let serialized = path
        .components()
        .map(|component| match component {
            Component::Normal(part) => part
                .to_str()
                .map(str::to_string)
                .ok_or_else(|| format!("备份路径不是有效 UTF-8：{}", path.display())),
            _ => Err(format!("备份成员路径无效：{}", path.display())),
        })
        .collect::<Result<Vec<_>, _>>()?
        .join("/");
    manifest_path(&serialized)?;
    Ok(serialized)
}

fn collision_resistant_id() -> String {
    let timestamp = timestamp_id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = RECOVERY_POINT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!(
        "{timestamp}-{nanos:039}-{}-{sequence:020}",
        std::process::id()
    )
}

fn timestamp_id() -> String {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    OffsetDateTime::now_utc()
        .to_offset(local_offset)
        .format(format_description!(
            "[year][month][day]-[hour][minute][second]"
        ))
        .unwrap_or_else(|_| "unknown-time".into())
}

fn format_now_rfc3339() -> String {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    OffsetDateTime::now_utc()
        .to_offset(local_offset)
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown-time".into())
}

#[cfg(test)]
mod review_fix_2_tests {
    use super::*;
    use std::cell::Cell;
    use std::io;

    #[test]
    fn incomplete_backup_double_cleanup_failure_names_exact_residual_path() {
        let root = PathBuf::from("/fixture/provider-backups");
        let residual = root.join("incomplete-id");
        let message = cleanup_incomplete_backup_with_ops(
            &root,
            &residual,
            "incomplete-id",
            |_| Err(io::Error::new(ErrorKind::PermissionDenied, "remove denied")),
            |_, _| Err(io::Error::new(ErrorKind::PermissionDenied, "rename denied")),
            |_| Ok(()),
        );

        assert!(message.contains("remove denied"), "{message}");
        assert!(message.contains("rename denied"), "{message}");
        assert!(
            message.contains(&residual.display().to_string()),
            "{message}"
        );
    }

    #[test]
    fn incomplete_backup_not_found_is_distinct_and_successful_changes_sync_parent() {
        let root = PathBuf::from("/fixture/provider-backups");
        let residual = root.join("incomplete-id");
        let not_found = cleanup_incomplete_backup_with_ops(
            &root,
            &residual,
            "incomplete-id",
            |_| Err(io::Error::new(ErrorKind::NotFound, "gone")),
            |_, _| panic!("NotFound must not attempt quarantine"),
            |_| panic!("NotFound made no directory change to sync"),
        );
        assert!(not_found.contains("已不存在"), "{not_found}");
        assert!(
            not_found.contains(&residual.display().to_string()),
            "{not_found}"
        );

        let synced_after_remove = Cell::new(false);
        let removed = cleanup_incomplete_backup_with_ops(
            &root,
            &residual,
            "incomplete-id",
            |_| Ok(()),
            |_, _| panic!("successful removal must not quarantine"),
            |path| {
                assert_eq!(path, root);
                synced_after_remove.set(true);
                Ok(())
            },
        );
        assert!(removed.is_empty(), "{removed}");
        assert!(synced_after_remove.get());

        let synced_after_quarantine = Cell::new(false);
        let quarantined = cleanup_incomplete_backup_with_ops(
            &root,
            &residual,
            "incomplete-id",
            |_| Err(io::Error::new(ErrorKind::PermissionDenied, "remove denied")),
            |from, to| {
                assert_eq!(from, residual);
                assert_eq!(to, root.join(".incomplete-incomplete-id"));
                Ok(())
            },
            |path| {
                assert_eq!(path, root);
                synced_after_quarantine.set(true);
                Ok(())
            },
        );
        assert!(quarantined.contains("已隔离"), "{quarantined}");
        assert!(synced_after_quarantine.get());
    }

    #[test]
    fn windows_directory_sync_contract_requests_flush_compatible_access_and_sharing() {
        let contract = windows_directory_sync_contract();

        assert_ne!(contract.desired_access & 0x4000_0000, 0, "GENERIC_WRITE");
        assert_eq!(contract.share_mode & 0x0000_0007, 0x0000_0007);
        assert_ne!(contract.flags_and_attributes & 0x0200_0000, 0);
        assert_ne!(contract.flags_and_attributes & 0x0020_0000, 0);
    }
}
