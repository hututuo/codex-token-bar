use crate::core::app_paths;
use crate::models::{
    ProviderRepairActionResult, ProviderRepairBackupInfo, ProviderRepairSnapshot,
    ProviderRepairStep,
};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::io::Write;
use std::path::{Path, PathBuf};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

mod session_files;
mod sqlite_state;

use session_files::{
    collect_jsonl_files, find_session_files, rewrite_session_provider, scan_session_providers,
    SessionScan,
};
use sqlite_state::{latest_thread_index_entry, scan_sqlite, sync_sqlite_provider, SQLiteScan};

pub fn scan_provider_repair(codex_home: &Path) -> ProviderRepairSnapshot {
    match scan_provider_repair_result(codex_home) {
        Ok(report) => snapshot_from_report(report),
        Err(error) => error_snapshot(codex_home, error.to_string()),
    }
}

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

pub fn create_provider_backup(codex_home: &Path) -> Result<ProviderRepairActionResult, String> {
    let report = scan_provider_repair_result(codex_home)?;
    let backup = create_backup_from_report(codex_home, &report)?;
    Ok(action_result(
        scan_provider_repair(codex_home),
        format!("已创建备份：{}", backup.id),
        Some(backup),
    ))
}

pub fn sync_provider_history(
    codex_home: &Path,
    backup_id: &str,
) -> Result<ProviderRepairActionResult, String> {
    let backup = backup_by_id(backup_id)?;
    ensure_backup_matches_codex_home(&backup, codex_home)?;
    let report = scan_provider_repair_result(codex_home)?;
    let mut rewritten_sessions = 0_u32;
    for file in find_session_files(codex_home, true) {
        if rewrite_session_provider(&file, &report.target.provider)? {
            rewritten_sessions = rewritten_sessions.saturating_add(1);
        }
    }

    let sqlite_rows = sync_sqlite_provider(codex_home, &report.target.provider)?;
    let index_changed = repair_session_index(codex_home)?;
    let snapshot = scan_provider_repair(codex_home);
    let message = format!(
        "已同步为 {}：JSONL {} 个，SQLite {} 行，session_index {}。",
        report.target.provider,
        rewritten_sessions,
        sqlite_rows,
        if index_changed { "已补齐" } else { "无需修改" }
    );
    Ok(action_result(snapshot, message, Some(backup)))
}

pub fn verify_provider_repair(codex_home: &Path) -> ProviderRepairActionResult {
    let snapshot = scan_provider_repair(codex_home);
    let message = if snapshot.inconsistent_count == 0 {
        "验证完成：未发现不一致。".into()
    } else {
        format!("验证完成：仍有 {} 条不一致。", snapshot.inconsistent_count)
    };
    action_result(snapshot, message, None)
}

pub fn rollback_provider_backup(
    codex_home: &Path,
    backup_id: &str,
) -> Result<ProviderRepairActionResult, String> {
    let backup = backup_by_id(backup_id)?;
    ensure_backup_matches_codex_home(&backup, codex_home)?;
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

    Ok(action_result(
        scan_provider_repair(codex_home),
        format!("已回滚备份：{}", backup.id),
        Some(backup),
    ))
}

fn scan_provider_repair_result(codex_home: &Path) -> Result<ProviderRepairReport, String> {
    let session_files = find_session_files(codex_home, true);
    let session_scan = scan_session_providers(&session_files);
    let sqlite_scan = scan_sqlite(codex_home).unwrap_or_else(|error| SQLiteScan {
        integrity: format!("读取失败：{error}"),
        ..SQLiteScan::default()
    });
    let session_index = scan_session_index(codex_home);
    let target = detect_target_provider(codex_home, &sqlite_scan, &session_scan);
    let session_mismatches = session_scan.count_provider_mismatches(&target.provider);
    let index_missing = latest_thread_index_missing(&sqlite_scan, &session_index);
    let inconsistent_count = session_mismatches
        + sqlite_scan.rows_to_repair(&target.provider)
        + session_scan.invalid_files
        + u32::from(index_missing);

    Ok(ProviderRepairReport {
        codex_home: codex_home.to_path_buf(),
        target,
        session_scan,
        sqlite_scan,
        session_index,
        session_mismatches,
        index_missing,
        inconsistent_count,
    })
}

fn detect_target_provider(
    codex_home: &Path,
    sqlite_scan: &SQLiteScan,
    session_scan: &SessionScan,
) -> TargetProvider {
    if let Some(provider) = config_provider(codex_home) {
        return TargetProvider {
            provider,
            source: "config.toml".into(),
        };
    }
    if let Some(provider) = sqlite_scan.latest_unarchived_provider.clone() {
        return TargetProvider {
            provider,
            source: "SQLite 最新会话".into(),
        };
    }
    if let Some(provider) = session_scan.newest_provider.clone() {
        return TargetProvider {
            provider,
            source: "最新 JSONL".into(),
        };
    }
    TargetProvider {
        provider: "openai".into(),
        source: "默认 openai".into(),
    }
}

fn config_provider(codex_home: &Path) -> Option<String> {
    let text = fs::read_to_string(codex_home.join("config.toml")).ok()?;
    for raw_line in text.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        let Some(value) = line.strip_prefix("model_provider") else {
            continue;
        };
        let Some((_, assigned)) = value.split_once('=') else {
            continue;
        };
        let trimmed = assigned.trim();
        let provider = trimmed
            .strip_prefix('"')
            .and_then(|value| value.split('"').next())
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if let Some(provider) = provider {
            return Some(provider.to_string());
        }
    }
    None
}

fn scan_session_index(codex_home: &Path) -> SessionIndexScan {
    let path = codex_home.join("session_index.jsonl");
    let Ok(text) = fs::read_to_string(path) else {
        return SessionIndexScan::default();
    };

    let mut ids = HashSet::new();
    let mut rows = 0;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        rows += 1;
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            if let Some(id) = value.get("id").and_then(Value::as_str) {
                ids.insert(id.to_string());
            }
        }
    }
    SessionIndexScan { ids, rows }
}

fn latest_thread_index_missing(sqlite_scan: &SQLiteScan, session_index: &SessionIndexScan) -> bool {
    sqlite_scan
        .latest_unarchived_thread_id
        .as_ref()
        .is_some_and(|thread_id| !session_index.ids.contains(thread_id))
}

fn snapshot_from_report(report: ProviderRepairReport) -> ProviderRepairSnapshot {
    let sqlite_mismatches = report.sqlite_scan.rows_to_repair(&report.target.provider);
    let index_issue = u32::from(report.index_missing);
    let status = if report.inconsistent_count == 0 {
        format!(
            "扫描完成：未发现不一致。SQLite {}，session_index {} 行。",
            report.sqlite_scan.integrity, report.session_index.rows
        )
    } else {
        format!(
            "扫描完成：发现 {} 条不一致（JSONL {}，SQLite {}，异常文件 {}，索引 {}）。",
            report.inconsistent_count,
            report.session_mismatches,
            sqlite_mismatches,
            report.session_scan.invalid_files,
            index_issue
        )
    };

    ProviderRepairSnapshot {
        detected_provider: report.target.provider.clone(),
        provider_source: report.target.source.clone(),
        session_files_found: report.session_scan.files_found,
        inconsistent_count: report.inconsistent_count,
        status,
        steps: vec![
            ProviderRepairStep {
                label: "扫描".into(),
                status: if report.inconsistent_count == 0 {
                    "未发现不一致".into()
                } else {
                    format!("发现 {} 条不一致", report.inconsistent_count)
                },
                done: true,
                healthy: report.inconsistent_count == 0,
            },
            ProviderRepairStep {
                label: "备份".into(),
                status: "未备份".into(),
                done: false,
                healthy: true,
            },
            ProviderRepairStep {
                label: "修复".into(),
                status: if report.inconsistent_count == 0 {
                    "暂无需修复".into()
                } else {
                    "未进行修复".into()
                },
                done: false,
                healthy: report.inconsistent_count == 0,
            },
            ProviderRepairStep {
                label: "验证".into(),
                status: "未验证".into(),
                done: false,
                healthy: report.inconsistent_count == 0,
            },
        ],
    }
}

fn error_snapshot(codex_home: &Path, message: String) -> ProviderRepairSnapshot {
    ProviderRepairSnapshot {
        detected_provider: "openai".into(),
        provider_source: "读取失败".into(),
        session_files_found: 0,
        inconsistent_count: 1,
        status: format!("扫描失败：{message}"),
        steps: vec![
            ProviderRepairStep {
                label: "扫描".into(),
                status: format!("读取失败：{}", codex_home.display()),
                done: true,
                healthy: false,
            },
            ProviderRepairStep {
                label: "备份".into(),
                status: "未备份".into(),
                done: false,
                healthy: true,
            },
            ProviderRepairStep {
                label: "修复".into(),
                status: "未进行修复".into(),
                done: false,
                healthy: false,
            },
            ProviderRepairStep {
                label: "验证".into(),
                status: "未验证".into(),
                done: false,
                healthy: false,
            },
        ],
    }
}

fn action_result(
    snapshot: ProviderRepairSnapshot,
    message: String,
    backup: Option<ProviderRepairBackupInfo>,
) -> ProviderRepairActionResult {
    ProviderRepairActionResult {
        snapshot,
        message,
        backup,
        backups: list_provider_backups().unwrap_or_default(),
    }
}

fn create_backup_from_report(
    codex_home: &Path,
    report: &ProviderRepairReport,
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
        "target_provider": report.target.provider,
        "session_files": session_files,
        "state_database": state_database,
        "session_index": session_index
    });
    write_json_file(&backup_path.join("manifest.json"), &manifest)?;

    read_backup_info(&backup_path)
}

fn provider_backup_root() -> Result<PathBuf, String> {
    app_paths::provider_repair_backup_root()
}

fn backup_by_id(backup_id: &str) -> Result<ProviderRepairBackupInfo, String> {
    let trimmed = backup_id.trim();
    if trimmed.is_empty() || trimmed.contains('/') || trimmed.contains('\\') || trimmed.contains("..")
    {
        return Err("备份 ID 无效".into());
    }
    let path = provider_backup_root()?.join(trimmed);
    read_backup_info(&path)
}

fn read_backup_info(path: &Path) -> Result<ProviderRepairBackupInfo, String> {
    let manifest_path = path.join("manifest.json");
    let value: Value = serde_json::from_slice(
        &fs::read(&manifest_path).map_err(|error| error.to_string())?,
    )
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

fn ensure_backup_matches_codex_home(
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

fn codex_home_identity(codex_home: &Path) -> String {
    codex_home
        .canonicalize()
        .unwrap_or_else(|_| codex_home.to_path_buf())
        .display()
        .to_string()
}

fn codex_home_fingerprint(codex_home: &Path) -> String {
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

fn repair_session_index(codex_home: &Path) -> Result<bool, String> {
    let sqlite = scan_sqlite(codex_home).map_err(|error| error.to_string())?;
    let Some(thread_id) = sqlite.latest_unarchived_thread_id else {
        return Ok(false);
    };
    let session_index = scan_session_index(codex_home);
    if session_index.ids.contains(&thread_id) {
        return Ok(false);
    }
    let entry = latest_thread_index_entry(codex_home, &thread_id)?;
    let path = codex_home.join("session_index.jsonl");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| error.to_string())?;
    writeln!(file, "{}", serde_json::to_string(&entry).map_err(|error| error.to_string())?)
        .map_err(|error| error.to_string())?;
    Ok(true)
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

struct ProviderRepairReport {
    #[allow(dead_code)]
    codex_home: PathBuf,
    target: TargetProvider,
    session_scan: SessionScan,
    sqlite_scan: SQLiteScan,
    session_index: SessionIndexScan,
    session_mismatches: u32,
    index_missing: bool,
    inconsistent_count: u32,
}

struct TargetProvider {
    provider: String,
    source: String,
}

#[derive(Default)]
struct SessionIndexScan {
    ids: HashSet<String>,
    rows: u32,
}

#[cfg(test)]
#[path = "provider_repair_tests.rs"]
mod provider_repair_tests;
