use crate::core::app_paths;
use crate::models::{ProviderRepairBackupInfo, ProviderRepairBackupRestoreStatus};
use rusqlite::backup::Backup;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Read};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

use super::session_files::{find_session_files, replace_file_atomically, write_file_atomically};

const BACKUP_MANIFEST_SCHEMA_VERSION: u32 = 2;
const LEGACY_UNSUPPORTED_REASON: &str = "旧版 v1 清单缺少可验证的成员摘要。";
const UNIQUE_DIRECTORY_ATTEMPTS: usize = 64;
const UNIQUE_FILE_ATTEMPTS: usize = 64;
const MAX_SYNC_DIRECTORIES: usize = 100_000;
static RECOVERY_POINT_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static RESTORE_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BackupManifest {
    schema_version: u32,
    complete: bool,
    id: String,
    created_at: String,
    codex_home: String,
    codex_home_fingerprint: String,
    target_provider: String,
    members: Vec<BackupMember>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BackupMember {
    kind: String,
    relative_path: String,
    backup_path: Option<String>,
    present: bool,
    size: u64,
    checksum_sha256: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RestorePhase {
    Capture,
    PublishRecoveryManifest,
    Apply,
    ValidateTemp,
    Verify,
    Compensate,
    Cleanup,
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

pub(super) fn create_provider_backup_files(
    codex_home: &Path,
    target_provider: &str,
) -> Result<ProviderRepairBackupInfo, String> {
    create_provider_backup_files_at(&provider_backup_root()?, codex_home, target_provider)
}

pub(super) fn create_provider_backup_files_at(
    backup_root: &Path,
    codex_home: &Path,
    target_provider: &str,
) -> Result<ProviderRepairBackupInfo, String> {
    create_provider_backup_files_at_with_hook(backup_root, codex_home, target_provider, |_, _| {
        Ok(())
    })
}

pub(super) fn create_provider_backup_files_at_with_hook(
    backup_root: &Path,
    codex_home: &Path,
    target_provider: &str,
    mut hook: impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderRepairBackupInfo, String> {
    let canonical_home = codex_home
        .canonicalize()
        .map_err(|error| format!("无法确认 Codex Home {}：{error}", codex_home.display()))?;
    fs::create_dir_all(backup_root).map_err(|error| error.to_string())?;
    let (id, backup_path) = create_unique_directory(backup_root, "")?;

    let result = build_complete_backup(
        &id,
        &backup_path,
        backup_root,
        &canonical_home,
        target_provider,
        &mut hook,
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
    canonical_home: &Path,
    target_provider: &str,
    hook: &mut impl FnMut(BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<(), String> {
    let mut members = Vec::new();
    members.push(backup_regular_member(
        canonical_home,
        backup_path,
        "config.toml",
        "config.toml.before",
        "fixed",
    )?);
    members.push(backup_sqlite_member(canonical_home, backup_path)?);
    members.push(backup_regular_member(
        canonical_home,
        backup_path,
        "session_index.jsonl",
        "session_index.jsonl.before",
        "fixed",
    )?);
    members.push(absent_member("state_5.sqlite-wal", "sqliteSidecar"));
    members.push(absent_member("state_5.sqlite-shm", "sqliteSidecar"));

    let session_backup_root = backup_path.join("session-jsonl");
    for source in find_session_files(canonical_home, true)? {
        let relative = source
            .strip_prefix(canonical_home)
            .map_err(|_| format!("会话文件不在规范 Codex Home 内：{}", source.display()))?;
        validate_relative_member_path(relative, "session")?;
        let backup_relative = PathBuf::from("session-jsonl").join(relative);
        let target = backup_path.join(&backup_relative);
        let (size, checksum_sha256) = copy_regular_file(&source, &target)?;
        members.push(BackupMember {
            kind: "session".into(),
            relative_path: path_to_manifest_string(relative)?,
            backup_path: Some(path_to_manifest_string(&backup_relative)?),
            present: true,
            size,
            checksum_sha256: Some(checksum_sha256),
        });
    }
    if !session_backup_root.exists() {
        fs::create_dir_all(&session_backup_root).map_err(|error| error.to_string())?;
    }

    let manifest = BackupManifest {
        schema_version: BACKUP_MANIFEST_SCHEMA_VERSION,
        complete: true,
        id: id.to_string(),
        created_at: format_now_rfc3339(),
        codex_home: canonical_home.display().to_string(),
        codex_home_fingerprint: codex_home_fingerprint(canonical_home),
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
    canonical_home: &Path,
    backup_path: &Path,
    relative_path: &str,
    backup_relative_path: &str,
    kind: &str,
) -> Result<BackupMember, String> {
    let source = canonical_home.join(relative_path);
    let Some(_) = regular_file_metadata_if_exists(&source)? else {
        return Ok(absent_member(relative_path, kind));
    };
    let target = backup_path.join(backup_relative_path);
    let (size, checksum_sha256) = copy_regular_file(&source, &target)?;
    Ok(BackupMember {
        kind: kind.into(),
        relative_path: relative_path.into(),
        backup_path: Some(backup_relative_path.into()),
        present: true,
        size,
        checksum_sha256: Some(checksum_sha256),
    })
}

fn backup_sqlite_member(canonical_home: &Path, backup_path: &Path) -> Result<BackupMember, String> {
    let source = canonical_home.join("state_5.sqlite");
    let Some(_) = regular_file_metadata_if_exists(&source)? else {
        return Ok(absent_member("state_5.sqlite", "sqlite"));
    };
    let target = backup_path.join("state_5.sqlite.before");
    create_consistent_sqlite_snapshot(&source, &target)?;
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
    let source_connection = Connection::open_with_flags(source, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| format!("创建 SQLite 一致性快照失败：{error}"))?;
    let mut target_connection =
        Connection::open(target).map_err(|error| format!("创建 SQLite 一致性快照失败：{error}"))?;
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
        .open(target)
        .and_then(|file| file.sync_all())
        .map_err(|error| error.to_string())
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

pub(super) fn restore_provider_backup_files_with_verification(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
    verify: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<(), String> {
    restore_provider_backup_files_at_with_verification_and_hook(
        codex_home,
        backup,
        |_, _, _| Ok(()),
        verify,
    )
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
    let canonical_home = codex_home
        .canonicalize()
        .map_err(|error| format!("无法确认 Codex Home {}：{error}", codex_home.display()))?;
    ensure_backup_matches_codex_home(backup, &canonical_home)?;
    let backup_path = PathBuf::from(&backup.path);
    let manifest = validate_backup_manifest(&backup_path)?;
    if manifest.id != backup.id || manifest.codex_home_fingerprint != backup.codex_home_fingerprint
    {
        return Err("备份 manifest 与所选恢复点身份不一致。".into());
    }

    let backup_root = backup_path
        .parent()
        .ok_or_else(|| "备份目录缺少父目录".to_string())?;
    let (recovery_id, recovery_path) = create_unique_directory(backup_root, ".restore-recovery-")?;
    let recovery_members = match capture_and_publish_live_state(
        &canonical_home,
        &recovery_path,
        &recovery_id,
        &manifest,
        &mut hook,
    ) {
        Ok(members) => members,
        Err(error) => {
            return Err(error_with_recovery_cleanup(
                format!("恢复前状态暂存失败：{error}"),
                backup_root,
                &recovery_path,
                &mut hook,
            ))
        }
    };

    let restore_result =
        apply_restore_members(&canonical_home, &backup_path, &manifest.members, &mut hook)
            .and_then(|_| {
                hook(RestorePhase::Verify, 0, &canonical_home)?;
                verify(&canonical_home)
                    .map_err(|error| format!("恢复后的 Provider 强验证失败：{error}"))
            });

    if let Err(error) = restore_result {
        let compensation_errors = compensate_restore(
            &canonical_home,
            &recovery_path,
            &recovery_members,
            &mut hook,
        );
        if compensation_errors.is_empty() {
            let message = format!("恢复失败：{error}；已补偿回恢复前状态，原恢复点仍保留。");
            return Err(error_with_recovery_cleanup(
                message,
                backup_root,
                &recovery_path,
                &mut hook,
            ));
        }
        return Err(format!(
            "恢复失败：{error}；恢复补偿未完成：{}；恢复材料保留于 {}，原恢复点仍保留。",
            compensation_errors.join("；"),
            recovery_path.display()
        ));
    }

    cleanup_recovery_path(backup_root, &recovery_path, &mut hook)
        .map_err(|error| format!("恢复已完成，但敏感恢复材料清理失败：{error}"))
}

fn capture_and_publish_live_state(
    canonical_home: &Path,
    recovery_path: &Path,
    recovery_id: &str,
    source_manifest: &BackupManifest,
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<Vec<BackupMember>, String> {
    let mut captured = Vec::with_capacity(source_manifest.members.len());
    for (index, member) in source_manifest.members.iter().enumerate() {
        let relative = Path::new(&member.relative_path);
        hook(RestorePhase::Capture, index, relative)?;
        if member.kind == "sqliteSidecar" {
            captured.push(absent_member(&member.relative_path, &member.kind));
            continue;
        }
        let source = validated_destination(canonical_home, relative)?;
        if regular_file_metadata_if_exists(&source)?.is_none() {
            captured.push(absent_member(&member.relative_path, &member.kind));
            continue;
        }
        let backup_relative = PathBuf::from("live").join(relative);
        let target = recovery_path.join(&backup_relative);
        let (size, checksum_sha256) = if member.kind == "sqlite" {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            }
            create_consistent_sqlite_snapshot(&source, &target)?;
            (
                fs::metadata(&target)
                    .map_err(|error| error.to_string())?
                    .len(),
                file_sha256(&target)?,
            )
        } else {
            copy_regular_file(&source, &target)?
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
    let recovery_manifest = BackupManifest {
        schema_version: BACKUP_MANIFEST_SCHEMA_VERSION,
        complete: true,
        id: recovery_id.to_string(),
        created_at: format_now_rfc3339(),
        codex_home: source_manifest.codex_home.clone(),
        codex_home_fingerprint: source_manifest.codex_home_fingerprint.clone(),
        target_provider: source_manifest.target_provider.clone(),
        members: captured.clone(),
    };
    sync_directory_tree(recovery_path)?;
    hook(
        RestorePhase::PublishRecoveryManifest,
        0,
        &recovery_path.join("recovery-manifest.json"),
    )?;
    let bytes = serde_json::to_vec_pretty(&recovery_manifest).map_err(|error| error.to_string())?;
    write_file_atomically(&recovery_path.join("recovery-manifest.json"), &bytes)?;
    sync_directory(recovery_path)?;
    Ok(captured)
}

fn apply_restore_members(
    canonical_home: &Path,
    source_root: &Path,
    members: &[BackupMember],
    hook: &mut impl FnMut(RestorePhase, usize, &Path) -> Result<(), String>,
) -> Result<(), String> {
    for (index, member) in ordered_restore_members(members).into_iter().enumerate() {
        let relative = Path::new(&member.relative_path);
        hook(RestorePhase::Apply, index, relative)?;
        install_logical_member(canonical_home, source_root, member, |temp| {
            hook(RestorePhase::ValidateTemp, index, relative)
                .map_err(|error| format!("恢复临时文件验证失败 {}：{error}", temp.display()))
        })?;
    }
    Ok(())
}

fn compensate_restore(
    canonical_home: &Path,
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
        let result = hook(RestorePhase::Compensate, index, relative).and_then(|_| {
            install_logical_member(canonical_home, recovery_path, member, |_| Ok(()))
        });
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

fn install_logical_member(
    canonical_home: &Path,
    source_root: &Path,
    member: &BackupMember,
    mut validate_temp: impl FnMut(&Path) -> Result<(), String>,
) -> Result<(), String> {
    if member.kind == "sqlite" {
        return install_sqlite_unit(canonical_home, source_root, member, &mut validate_temp);
    }
    validate_relative_member_path(Path::new(&member.relative_path), &member.kind)?;
    let destination = validated_destination(canonical_home, Path::new(&member.relative_path))?;
    if !member.present {
        return match fs::remove_file(&destination) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.to_string()),
        };
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
    ensure_safe_parent_directories(canonical_home, &destination)?;
    copy_file_atomically(
        &source,
        &destination,
        member.size,
        expected_checksum,
        &mut validate_temp,
    )
}

fn install_sqlite_unit(
    canonical_home: &Path,
    source_root: &Path,
    member: &BackupMember,
    validate_temp: &mut impl FnMut(&Path) -> Result<(), String>,
) -> Result<(), String> {
    let destination = validated_destination(canonical_home, Path::new("state_5.sqlite"))?;
    remove_sqlite_sidecars(canonical_home)?;
    if !member.present {
        match fs::remove_file(&destination) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(format!("移除 SQLite 主库失败：{error}")),
        }
        return verify_installed_sqlite(canonical_home, false);
    }

    let backup_relative = member
        .backup_path
        .as_deref()
        .ok_or_else(|| "SQLite 备份成员缺少源文件".to_string())?;
    let expected_checksum = member
        .checksum_sha256
        .as_deref()
        .ok_or_else(|| "SQLite 备份成员缺少 SHA-256 校验".to_string())?;
    copy_file_atomically(
        &source_root.join(backup_relative),
        &destination,
        member.size,
        expected_checksum,
        validate_temp,
    )?;
    verify_installed_sqlite(canonical_home, true)
}

fn remove_sqlite_sidecars(canonical_home: &Path) -> Result<(), String> {
    for relative in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
        let path = validated_destination(canonical_home, Path::new(relative))?;
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "移除 SQLite sidecar {} 失败：{error}",
                    path.display()
                ))
            }
        }
    }
    Ok(())
}

fn verify_installed_sqlite(canonical_home: &Path, expected_present: bool) -> Result<(), String> {
    let database = canonical_home.join("state_5.sqlite");
    if !expected_present {
        if regular_file_metadata_if_exists(&database)?.is_some() {
            return Err("SQLite 恢复验证失败：主库本应不存在。".into());
        }
        return remove_sqlite_sidecars(canonical_home);
    }
    reject_symlink_or_non_file(&database)?;
    let connection = Connection::open_with_flags(&database, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| format!("重新打开恢复后的 SQLite 失败：{error}"))?;
    let integrity: String = connection
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|error| format!("恢复后的 SQLite integrity_check 失败：{error}"))?;
    if integrity != "ok" {
        return Err(format!("恢复后的 SQLite integrity_check: {integrity}"));
    }
    Ok(())
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
        fs::remove_dir_all(recovery_path)
            .map_err(|error| format!("清理 {} 失败：{error}", recovery_path.display()))
    });
    match removal {
        Ok(()) => Ok(()),
        Err(error) => quarantine_recovery_path(backup_root, recovery_path, &error),
    }
}

fn quarantine_recovery_path(root: &Path, path: &Path, cleanup_error: &str) -> Result<(), String> {
    for _ in 0..UNIQUE_DIRECTORY_ATTEMPTS {
        let quarantine = root.join(format!(".restore-quarantine-{}", collision_resistant_id()));
        match fs::rename(path, &quarantine) {
            Ok(()) => {
                return Err(format!(
                    "{cleanup_error}；恢复材料已隔离到 {}",
                    quarantine.display()
                ))
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

fn validated_destination(canonical_home: &Path, relative: &Path) -> Result<PathBuf, String> {
    validate_normal_relative_path(relative)?;
    let mut cursor = canonical_home.to_path_buf();
    let components = relative.components().collect::<Vec<_>>();
    for (index, component) in components.iter().enumerate() {
        let Component::Normal(part) = component else {
            return Err(format!("恢复成员路径无效：{}", relative.display()));
        };
        cursor.push(part);
        match fs::symlink_metadata(&cursor) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(format!("恢复成员路径包含符号链接：{}", cursor.display()))
            }
            Ok(metadata) if index + 1 < components.len() && !metadata.is_dir() => {
                return Err(format!("恢复成员父路径不是目录：{}", cursor.display()))
            }
            Ok(_) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    if !cursor.starts_with(canonical_home) {
        return Err(format!("恢复成员越出 Codex Home：{}", relative.display()));
    }
    Ok(cursor)
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
    if manifest.schema_version != BACKUP_MANIFEST_SCHEMA_VERSION || !manifest.complete {
        return Err("备份 manifest 未完整提交或版本不受支持。".into());
    }
    if backup_path.file_name().and_then(|name| name.to_str()) != Some(manifest.id.as_str()) {
        return Err("备份 manifest ID 与目录不一致。".into());
    }

    let mut destinations = HashSet::new();
    let mut backup_sources = HashSet::new();
    let mut config_members = 0_usize;
    let mut sqlite_members = 0_usize;
    let mut index_members = 0_usize;
    let mut wal_members = 0_usize;
    let mut shm_members = 0_usize;
    for member in &manifest.members {
        let relative = Path::new(&member.relative_path);
        validate_relative_member_path(relative, &member.kind)?;
        if !destinations.insert(member.relative_path.clone()) {
            return Err(format!(
                "备份 manifest 包含重复成员：{}",
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
            _ => {
                return Err(format!(
                    "备份 manifest 包含额外成员：{}",
                    member.relative_path
                ))
            }
        }

        let expected_backup_path = expected_backup_path(member)?;
        if member.backup_path.as_deref() != expected_backup_path.as_deref() {
            return Err(format!(
                "备份 manifest 成员源路径不符合 v2 映射：{}",
                member.relative_path
            ));
        }
        match (member.present, member.backup_path.as_deref()) {
            (false, None) if member.size == 0 && member.checksum_sha256.is_none() => {}
            (true, Some(backup_relative)) => {
                if !backup_sources.insert(backup_relative.to_string()) {
                    return Err(format!("备份 manifest 包含重复源路径：{backup_relative}"));
                }
                let backup_relative = Path::new(backup_relative);
                validate_normal_relative_path(backup_relative)?;
                let source = backup_path.join(backup_relative);
                reject_symlink_or_non_file(&source)?;
                let canonical_source = source.canonicalize().map_err(|error| error.to_string())?;
                if !canonical_source.starts_with(&canonical_backup) {
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
    if [
        ("config.toml", config_members),
        ("state_5.sqlite", sqlite_members),
        ("session_index.jsonl", index_members),
        ("state_5.sqlite-wal", wal_members),
        ("state_5.sqlite-shm", shm_members),
    ]
    .iter()
    .any(|(_, count)| *count != 1)
    {
        return Err(format!(
            "备份 manifest v2 必需成员数量无效：config={config_members}, sqlite={sqlite_members}, index={index_members}, wal={wal_members}, shm={shm_members}"
        ));
    }
    Ok(manifest)
}

fn expected_backup_path(member: &BackupMember) -> Result<Option<String>, String> {
    if !member.present {
        return Ok(None);
    }
    let expected = match (member.kind.as_str(), member.relative_path.as_str()) {
        ("fixed", "config.toml") => PathBuf::from("config.toml.before"),
        ("sqlite", "state_5.sqlite") => PathBuf::from("state_5.sqlite.before"),
        ("fixed", "session_index.jsonl") => PathBuf::from("session_index.jsonl.before"),
        ("session", _) => PathBuf::from("session-jsonl").join(&member.relative_path),
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
        .filter(|member| member.kind == "session" && member.present)
        .count();
    Ok(ProviderRepairBackupInfo {
        id: manifest.id,
        created_at: manifest.created_at,
        path: path.display().to_string(),
        codex_home: manifest.codex_home,
        codex_home_fingerprint: manifest.codex_home_fingerprint,
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
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in codex_home_identity(codex_home).as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

fn copy_regular_file(source: &Path, target: &Path) -> Result<(u64, String), String> {
    reject_symlink_or_non_file(source)?;
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let size = fs::copy(source, target).map_err(|error| error.to_string())?;
    OpenOptions::new()
        .read(true)
        .open(target)
        .and_then(|file| file.sync_all())
        .map_err(|error| error.to_string())?;
    Ok((size, file_sha256(target)?))
}

fn copy_file_atomically(
    source: &Path,
    destination: &Path,
    expected_size: u64,
    expected_checksum: &str,
    validate_temp: &mut impl FnMut(&Path) -> Result<(), String>,
) -> Result<(), String> {
    reject_symlink_or_non_file(source)?;
    let parent = destination
        .parent()
        .ok_or_else(|| format!("恢复目标缺少父目录：{}", destination.display()))?;
    if !parent.is_dir() {
        return Err(format!("恢复目标父目录不存在：{}", parent.display()));
    }
    let file_name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("恢复目标文件名无效：{}", destination.display()))?;

    for _ in 0..UNIQUE_FILE_ATTEMPTS {
        let sequence = RESTORE_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp = parent.join(format!(
            ".{file_name}.restore-{}-{sequence:020}.tmp",
            std::process::id()
        ));
        let mut target = match OpenOptions::new().write(true).create_new(true).open(&temp) {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.to_string()),
        };
        let copy_result = OpenOptions::new()
            .read(true)
            .open(source)
            .and_then(|mut source_file| std::io::copy(&mut source_file, &mut target))
            .and_then(|_| target.sync_all())
            .map_err(|error| error.to_string());
        drop(target);
        if let Err(error) = copy_result {
            return Err(cleanup_temp_after_error(&temp, error));
        }
        if let Err(error) = validate_temp(&temp) {
            return Err(cleanup_temp_after_error(&temp, error));
        }
        let copied_size = match fs::metadata(&temp) {
            Ok(metadata) => metadata.len(),
            Err(error) => {
                return Err(cleanup_temp_after_error(
                    &temp,
                    format!("读取恢复临时文件元数据失败：{error}"),
                ))
            }
        };
        let copied_checksum = match file_sha256(&temp) {
            Ok(checksum) => checksum,
            Err(error) => return Err(cleanup_temp_after_error(&temp, error)),
        };
        if copied_size != expected_size || copied_checksum != expected_checksum {
            return Err(cleanup_temp_after_error(
                &temp,
                format!(
                    "备份成员在替换前 SHA-256 或大小校验失败：{}",
                    source.display()
                ),
            ));
        }
        if let Err(error) = replace_file_atomically(&temp, destination) {
            return Err(cleanup_temp_after_error(&temp, error));
        }
        return Ok(());
    }
    Err(format!(
        "无法为恢复目标创建唯一临时文件：{}",
        destination.display()
    ))
}

fn cleanup_temp_after_error(temp: &Path, error: String) -> String {
    match fs::remove_file(temp) {
        Ok(()) => error,
        Err(remove_error) if remove_error.kind() == ErrorKind::NotFound => error,
        Err(remove_error) => {
            let parent = temp.parent().unwrap_or_else(|| Path::new("."));
            for _ in 0..UNIQUE_FILE_ATTEMPTS {
                let quarantine = parent.join(format!(
                    ".restore-quarantine-temp-{}",
                    collision_resistant_id()
                ));
                match fs::rename(temp, &quarantine) {
                    Ok(()) => {
                        return format!(
                            "{error}；临时文件清理失败：{remove_error}；已隔离到 {}",
                            quarantine.display()
                        )
                    }
                    Err(rename_error) if rename_error.kind() == ErrorKind::AlreadyExists => continue,
                    Err(rename_error) => {
                        return format!(
                            "{error}；临时文件清理失败：{remove_error}；隔离失败：{rename_error}；临时文件仍位于 {}",
                            temp.display()
                        )
                    }
                }
            }
            format!(
                "{error}；临时文件清理失败：{remove_error}；临时文件仍位于 {}",
                temp.display()
            )
        }
    }
}

fn reject_symlink_or_non_file(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("拒绝读取符号链接或非普通文件：{}", path.display()));
    }
    Ok(())
}

fn regular_file_metadata_if_exists(path: &Path) -> Result<Option<fs::Metadata>, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err(format!("拒绝读取符号链接：{}", path.display()))
        }
        Ok(metadata) if !metadata.is_file() => {
            Err(format!("拒绝读取非普通文件：{}", path.display()))
        }
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

fn ensure_safe_parent_directories(canonical_home: &Path, destination: &Path) -> Result<(), String> {
    let parent = destination
        .parent()
        .ok_or_else(|| format!("恢复目标缺少父目录：{}", destination.display()))?;
    let relative_parent = parent
        .strip_prefix(canonical_home)
        .map_err(|_| format!("恢复目标父目录越出 Codex Home：{}", parent.display()))?;
    let mut cursor = canonical_home.to_path_buf();
    for component in relative_parent.components() {
        let Component::Normal(part) = component else {
            return Err(format!("恢复目标父目录无效：{}", parent.display()));
        };
        cursor.push(part);
        match fs::symlink_metadata(&cursor) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(format!("恢复目标父目录包含符号链接：{}", cursor.display()))
            }
            Ok(metadata) if !metadata.is_dir() => {
                return Err(format!("恢复目标父路径不是目录：{}", cursor.display()))
            }
            Ok(_) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {
                fs::create_dir(&cursor).map_err(|error| error.to_string())?;
            }
            Err(error) => return Err(error.to_string()),
        }
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

#[cfg(windows)]
fn sync_directory(path: &Path) -> Result<(), String> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_FLAG_BACKUP_SEMANTICS, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };

    OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .and_then(|directory| directory.sync_all())
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
    match fs::remove_dir_all(path) {
        Ok(()) => String::new(),
        Err(remove_error) => {
            let quarantine = root.join(format!(".incomplete-{id}"));
            match fs::rename(path, &quarantine) {
                Ok(()) => format!("；未完成目录已隔离到 {}", quarantine.display()),
                Err(rename_error) => {
                    format!("；未完成目录清理失败：{remove_error}；隔离失败：{rename_error}")
                }
            }
        }
    }
}

fn path_to_manifest_string(path: &Path) -> Result<String, String> {
    path.to_str()
        .map(str::to_string)
        .ok_or_else(|| format!("备份路径不是有效 UTF-8：{}", path.display()))
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
