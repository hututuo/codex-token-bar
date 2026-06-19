use crate::models::{
    ProviderRepairActionResult, ProviderRepairBackupInfo, ProviderRepairSnapshot,
    ProviderRepairStep,
};
use std::fs;
use std::path::{Path, PathBuf};

mod backups;
mod session_index;
mod session_files;
mod sqlite_state;

use backups::{
    backup_by_id, create_provider_backup_files, ensure_backup_matches_codex_home,
    restore_provider_backup_files,
};
#[cfg(test)]
use backups::{codex_home_fingerprint, codex_home_identity};
use session_index::{
    latest_thread_index_missing, repair_session_index, scan_session_index, SessionIndexScan,
};
use session_files::{
    find_session_files, rewrite_session_provider, scan_session_providers, SessionScan,
};
use sqlite_state::{scan_sqlite, sync_sqlite_provider, SQLiteScan};

pub fn scan_provider_repair(codex_home: &Path) -> ProviderRepairSnapshot {
    match scan_provider_repair_result(codex_home) {
        Ok(report) => snapshot_from_report(report),
        Err(error) => error_snapshot(codex_home, error.to_string()),
    }
}

pub use backups::list_provider_backups;

pub fn create_provider_backup(codex_home: &Path) -> Result<ProviderRepairActionResult, String> {
    let report = scan_provider_repair_result(codex_home)?;
    let backup = create_provider_backup_files(codex_home, &report.target.provider)?;
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
    restore_provider_backup_files(codex_home, &backup)?;

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

#[cfg(test)]
#[path = "provider_repair_tests.rs"]
mod provider_repair_tests;
