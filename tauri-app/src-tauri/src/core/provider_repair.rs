use crate::models::{ProviderRepairActionResult, ProviderRepairSnapshot};
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

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

static PROVIDER_OPERATION_LEASES: OnceLock<Mutex<HashMap<PathBuf, String>>> = OnceLock::new();

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ProviderOperationError {
    Busy {
        #[serde(rename = "activeOperationId")]
        active_operation_id: String,
        message: String,
    },
    Failed {
        message: String,
    },
}

impl From<String> for ProviderOperationError {
    fn from(message: String) -> Self {
        Self::Failed { message }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderOperationStatus {
    pub operation_id: String,
    pub active: bool,
}

struct ProviderOperationLease {
    canonical_home: PathBuf,
    operation_id: String,
}

impl Drop for ProviderOperationLease {
    fn drop(&mut self) {
        let mut leases = provider_operation_leases()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if leases.get(&self.canonical_home) == Some(&self.operation_id) {
            leases.remove(&self.canonical_home);
        }
    }
}

fn validated_provider_candidate(value: &str) -> Option<String> {
    let provider = value.trim();
    if provider.is_empty() || provider == "(missing)" {
        None
    } else {
        Some(provider.to_string())
    }
}

fn provider_for_mutation(value: &str) -> Result<String, String> {
    validated_provider_candidate(value)
        .ok_or_else(|| "拒绝使用空值或缺失哨兵作为 provider 写入目标。".into())
}

pub fn scan_provider_repair(codex_home: &Path) -> ProviderRepairSnapshot {
    match scan_provider_repair_result(codex_home) {
        Ok(report) => snapshot_from_report(report),
        Err(error) => error_snapshot(codex_home, error.to_string()),
    }
}

pub use backups::list_provider_backups;

pub fn create_provider_backup(
    codex_home: &Path,
    operation_id: &str,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    run_provider_mutation(codex_home, operation_id, || {
        let report = scan_provider_repair_result(codex_home)?;
        let backup = create_provider_backup_files(codex_home, &report.target.provider)?;
        Ok(action_result(
            scan_provider_repair(codex_home),
            format!("已创建备份：{}", backup.id),
            Some(backup),
        ))
    })
}

pub fn sync_provider_history(
    codex_home: &Path,
    backup_id: &str,
    operation_id: &str,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    run_provider_mutation(codex_home, operation_id, || {
        let backup = backup_by_id(backup_id)?;
        ensure_backup_matches_codex_home(&backup, codex_home)?;
        let report = scan_provider_repair_result(codex_home)?;
        let target_provider = provider_for_mutation(&report.target.provider)?;
        let mut rewritten_sessions = 0_u32;
        for file in find_session_files(codex_home, true) {
            if rewrite_session_provider(&file, &target_provider)? {
                rewritten_sessions = rewritten_sessions.saturating_add(1);
            }
        }

        let sqlite_rows = sync_sqlite_provider(codex_home, &target_provider)?;
        let index_changed = repair_session_index(codex_home)?;
        let snapshot = scan_provider_repair(codex_home);
        let message = format!(
            "已同步为 {}：JSONL {} 个，SQLite {} 行，session_index {}。",
            target_provider,
            rewritten_sessions,
            sqlite_rows,
            if index_changed { "已补齐" } else { "无需修改" }
        );
        Ok(action_result(snapshot, message, Some(backup)))
    })
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
    operation_id: &str,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    run_provider_mutation(codex_home, operation_id, || {
        let backup = backup_by_id(backup_id)?;
        ensure_backup_matches_codex_home(&backup, codex_home)?;
        restore_provider_backup_files(codex_home, &backup)?;

        Ok(action_result(
            scan_provider_repair(codex_home),
            format!("已回滚备份：{}", backup.id),
            Some(backup),
        ))
    })
}

pub fn read_provider_operation_status(
    codex_home: &Path,
    operation_id: &str,
) -> Result<ProviderOperationStatus, ProviderOperationError> {
    let canonical_home = canonical_codex_home(codex_home)?;
    let leases = provider_operation_leases()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Ok(ProviderOperationStatus {
        operation_id: operation_id.to_string(),
        active: leases.get(&canonical_home).map(String::as_str) == Some(operation_id),
    })
}

fn provider_operation_leases() -> &'static Mutex<HashMap<PathBuf, String>> {
    PROVIDER_OPERATION_LEASES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn canonical_codex_home(codex_home: &Path) -> Result<PathBuf, ProviderOperationError> {
    codex_home
        .canonicalize()
        .map_err(|error| ProviderOperationError::Failed {
            message: format!(
                "无法确认 Codex Home {}：{error}",
                codex_home.display()
            ),
        })
}

fn acquire_provider_operation_lease(
    codex_home: &Path,
    operation_id: &str,
) -> Result<ProviderOperationLease, ProviderOperationError> {
    if operation_id.trim().is_empty() {
        return Err(ProviderOperationError::Failed {
            message: "Provider 操作缺少 operation ID。".into(),
        });
    }

    let canonical_home = canonical_codex_home(codex_home)?;
    let mut leases = provider_operation_leases()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(active_operation_id) = leases.get(&canonical_home) {
        return Err(ProviderOperationError::Busy {
            active_operation_id: active_operation_id.clone(),
            message: "同一 Codex Home 正在执行另一个 Provider 写操作。".into(),
        });
    }
    leases.insert(canonical_home.clone(), operation_id.to_string());
    Ok(ProviderOperationLease {
        canonical_home,
        operation_id: operation_id.to_string(),
    })
}

fn run_provider_mutation<T>(
    codex_home: &Path,
    operation_id: &str,
    mutation: impl FnOnce() -> Result<T, String>,
) -> Result<T, ProviderOperationError> {
    let _lease = acquire_provider_operation_lease(codex_home, operation_id)?;
    mutation().map_err(|message| ProviderOperationError::Failed { message })
}

fn scan_provider_repair_result(codex_home: &Path) -> Result<ProviderRepairReport, String> {
    let session_files = find_session_files(codex_home, true);
    let mut session_scan = scan_session_providers(&session_files);
    session_scan.newest_provider = session_scan
        .newest_provider
        .as_deref()
        .and_then(validated_provider_candidate);
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
