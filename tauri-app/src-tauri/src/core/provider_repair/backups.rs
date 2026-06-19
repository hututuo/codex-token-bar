use crate::core::app_paths;
use crate::models::ProviderRepairBackupInfo;
use serde_json::{json, Value};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

use super::session_files::{collect_jsonl_files, find_session_files};

pub fn list_provider_backups() -> Result<Vec<ProviderRepairBackupInfo>, String> {
    let root = provider_backup_root()?;
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("读取备份列表失败：{error}")),
    };

    let mut backups = entries
        .flatten()
        .filter_map(|entry| read_backup_info(&entry.path()).ok())
        .collect::<Vec<_>>();
    backups.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(backups)
}

pub(super) fn create_provider_backup_files(
    codex_home: &Path,
    target_provider: &str,
) -> Result<ProviderRepairBackupInfo, String> {
    let id = timestamp_id();
    let backup_path = provider_backup_root()?.join(&id);
    fs::create_dir_all(&backup_path).map_err(|error| error.to_string())?;

    let state_database = copy_if_exists(
        &codex_home.join("state_5.sqlite"),
        &backup_path.join("state_5.sqlite.before"),
    )?;
    let _ = copy_if_exists(
        &codex_home.join("state_5.sqlite-wal"),
        &backup_path.join("state_5.sqlite-wal.before"),
    );
    let _ = copy_if_exists(
        &codex_home.join("state_5.sqlite-shm"),
        &backup_path.join("state_5.sqlite-shm.before"),
    );
    let session_index = copy_if_exists(
        &codex_home.join("session_index.jsonl"),
        &backup_path.join("session_index.jsonl.before"),
    )?;
    let _ = copy_if_exists(
        &codex_home.join("config.toml"),
        &backup_path.join("config.toml.before"),
    )?;

    let mut session_files = 0_u32;
    let session_backup_root = backup_path.join("session-jsonl");
    for file in find_session_files(codex_home, true) {
        let relative = file.strip_prefix(codex_home).unwrap_or(file.as_path());
        let target = session_backup_root.join(relative);
        if copy_if_exists(&file, &target)? {
            session_files = session_files.saturating_add(1);
        }
    }

    let created_at = format_now_rfc3339();
    let codex_home_identity = codex_home_identity(codex_home);
    let codex_home_fingerprint = codex_home_fingerprint(codex_home);
    let manifest = json!({
        "id": id,
        "created_at": created_at,
        "codex_home": codex_home_identity,
        "codex_home_fingerprint": codex_home_fingerprint,
        "target_provider": target_provider,
        "session_files": session_files,
        "state_database": state_database,
        "session_index": session_index
    });
    write_json_file(&backup_path.join("manifest.json"), &manifest)?;

    read_backup_info(&backup_path)
}

pub(super) fn backup_by_id(backup_id: &str) -> Result<ProviderRepairBackupInfo, String> {
    let trimmed = backup_id.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
    {
        return Err("备份 ID 无效".into());
    }
    let path = provider_backup_root()?.join(trimmed);
    read_backup_info(&path)
}

pub(super) fn ensure_backup_matches_codex_home(
    backup: &ProviderRepairBackupInfo,
    codex_home: &Path,
) -> Result<(), String> {
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

pub(super) fn restore_provider_backup_files(
    codex_home: &Path,
    backup: &ProviderRepairBackupInfo,
) -> Result<(), String> {
    let backup_path = PathBuf::from(&backup.path);
    restore_if_exists(
        &backup_path.join("config.toml.before"),
        &codex_home.join("config.toml"),
    )?;
    restore_if_exists(
        &backup_path.join("state_5.sqlite.before"),
        &codex_home.join("state_5.sqlite"),
    )?;
    restore_if_exists(
        &backup_path.join("session_index.jsonl.before"),
        &codex_home.join("session_index.jsonl"),
    )?;
    let _ = fs::remove_file(codex_home.join("state_5.sqlite-shm"));
    let _ = fs::remove_file(codex_home.join("state_5.sqlite-wal"));
    restore_session_backups(codex_home, &backup_path.join("session-jsonl"))?;
    Ok(())
}

fn provider_backup_root() -> Result<PathBuf, String> {
    app_paths::provider_repair_backup_root()
}

fn read_backup_info(path: &Path) -> Result<ProviderRepairBackupInfo, String> {
    let manifest_path = path.join("manifest.json");
    let value: Value =
        serde_json::from_slice(&fs::read(&manifest_path).map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())?;
    Ok(ProviderRepairBackupInfo {
        id: value
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_else(|| path.file_name().and_then(|name| name.to_str()).unwrap_or("unknown"))
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
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(0),
        state_database: value
            .get("state_database")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        session_index: value
            .get("session_index")
            .and_then(Value::as_bool)
            .unwrap_or(false),
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

fn copy_if_exists(source: &Path, target: &Path) -> Result<bool, String> {
    if !source.exists() {
        return Ok(false);
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    fs::copy(source, target).map_err(|error| error.to_string())?;
    Ok(true)
}

fn restore_if_exists(source: &Path, target: &Path) -> Result<bool, String> {
    copy_if_exists(source, target)
}

fn restore_session_backups(codex_home: &Path, backup_root: &Path) -> Result<u32, String> {
    let mut files = Vec::new();
    collect_jsonl_files(backup_root, &mut files);
    let mut restored = 0_u32;
    for file in files {
        let relative = file.strip_prefix(backup_root).unwrap_or(file.as_path());
        let target = codex_home.join(relative);
        if copy_if_exists(&file, &target)? {
            restored = restored.saturating_add(1);
        }
    }
    Ok(restored)
}

fn write_json_file(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let bytes = serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?;
    fs::write(path, bytes).map_err(|error| error.to_string())
}

fn timestamp_id() -> String {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    OffsetDateTime::now_utc()
        .to_offset(local_offset)
        .format(format_description!("[year][month][day]-[hour][minute][second]"))
        .unwrap_or_else(|_| "unknown-time".into())
}

fn format_now_rfc3339() -> String {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    OffsetDateTime::now_utc()
        .to_offset(local_offset)
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown-time".into())
}
