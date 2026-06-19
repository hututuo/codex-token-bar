use crate::models::{ProviderRepairActionResult, ProviderRepairSnapshot};
use std::path::Path;

mod backups;
mod report;
mod session_files;
mod session_index;
mod sqlite_state;
mod target_provider;

use backups::{
    backup_by_id, create_provider_backup_files, ensure_backup_matches_codex_home,
    restore_provider_backup_files,
};
#[cfg(test)]
use backups::{codex_home_fingerprint, codex_home_identity};
use report::{action_result, error_snapshot, snapshot_from_report, ProviderRepairReport};
use session_index::{latest_thread_index_missing, repair_session_index, scan_session_index};
use session_files::{find_session_files, rewrite_session_provider, scan_session_providers};
use sqlite_state::{scan_sqlite, sync_sqlite_provider, SQLiteScan};
use target_provider::detect_target_provider;

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

#[cfg(test)]
#[path = "provider_repair_tests.rs"]
mod provider_repair_tests;
