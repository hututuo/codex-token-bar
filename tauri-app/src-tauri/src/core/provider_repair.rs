use crate::models::{ProviderRepairActionResult, ProviderRepairSnapshot};
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

mod backups;
mod report;
mod safe_fs;
mod session_files;
mod session_index;
mod sqlite_state;
mod target_provider;

use backups::{
    backup_by_id, ensure_backup_matches_codex_home, provider_backup_root,
    restore_provider_backup_files_with_pinned_verification,
    restore_provider_backup_files_with_verification,
};
#[cfg(test)]
use backups::{codex_home_fingerprint, codex_home_identity};
use report::{action_result, error_snapshot, snapshot_from_report, ProviderRepairReport};
use safe_fs::PinnedHome;
#[cfg(test)]
use session_files::rewrite_session_provider;
use session_files::{
    find_session_files, rewrite_session_provider_relative_in, scan_session_providers,
};
#[cfg(test)]
use session_index::repair_session_index;
use session_index::{latest_thread_index_missing, repair_session_index_in, scan_session_index};
#[cfg(test)]
use sqlite_state::sync_sqlite_provider;
use sqlite_state::{scan_sqlite, sync_sqlite_provider_from_snapshot_in, SQLiteScan};
use target_provider::detect_target_provider;

const MAX_FINISHED_PROVIDER_OPERATIONS: usize = 256;

static PROVIDER_OPERATION_REGISTRY: OnceLock<Mutex<ProviderOperationRegistry>> = OnceLock::new();

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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderOperationLifecycle {
    NotStarted,
    Active,
    Finished,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderOperationStatus {
    pub operation_id: String,
    pub lifecycle: ProviderOperationLifecycle,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderOperationOwnership {
    pub operation_id: String,
    pub canonical_home: PathBuf,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderOperationOwnershipDiscovery {
    pub active_operations: Vec<ProviderOperationOwnership>,
}

#[derive(Clone, Debug)]
struct ProviderOperationRecord {
    canonical_home: PathBuf,
    lifecycle: ProviderOperationLifecycle,
}

#[derive(Default)]
struct ProviderOperationRegistry {
    active_by_home: HashMap<PathBuf, String>,
    operations: HashMap<String, ProviderOperationRecord>,
    finished_order: VecDeque<String>,
}

impl ProviderOperationRegistry {
    fn acquire(
        &mut self,
        canonical_home: PathBuf,
        operation_id: &str,
    ) -> Result<(), ProviderOperationError> {
        if let Some(active_operation_id) = self.active_by_home.get(&canonical_home) {
            return Err(ProviderOperationError::Busy {
                active_operation_id: active_operation_id.clone(),
                message: "同一 Codex Home 正在执行另一个 Provider 写操作。".into(),
            });
        }
        if self.operations.contains_key(operation_id) {
            return Err(ProviderOperationError::Failed {
                message: "Provider operation ID 已被使用，请重新发起操作。".into(),
            });
        }

        self.active_by_home
            .insert(canonical_home.clone(), operation_id.to_string());
        self.operations.insert(
            operation_id.to_string(),
            ProviderOperationRecord {
                canonical_home,
                lifecycle: ProviderOperationLifecycle::Active,
            },
        );
        Ok(())
    }

    fn finish(&mut self, operation_id: &str) {
        let Some(record) = self.operations.get_mut(operation_id) else {
            return;
        };
        if record.lifecycle != ProviderOperationLifecycle::Active {
            return;
        }

        if self
            .active_by_home
            .get(&record.canonical_home)
            .map(String::as_str)
            == Some(operation_id)
        {
            self.active_by_home.remove(&record.canonical_home);
        }
        record.lifecycle = ProviderOperationLifecycle::Finished;
        self.finished_order.push_back(operation_id.to_string());
        self.prune_finished();
    }

    fn status(&self, operation_id: &str) -> ProviderOperationStatus {
        ProviderOperationStatus {
            operation_id: operation_id.to_string(),
            lifecycle: self
                .operations
                .get(operation_id)
                .map(|record| record.lifecycle)
                .unwrap_or(ProviderOperationLifecycle::NotStarted),
        }
    }

    fn active_ownership(&self) -> Vec<ProviderOperationOwnership> {
        let mut active_operations = self
            .active_by_home
            .iter()
            .map(
                |(canonical_home, operation_id)| ProviderOperationOwnership {
                    operation_id: operation_id.clone(),
                    canonical_home: canonical_home.clone(),
                },
            )
            .collect::<Vec<_>>();
        active_operations.sort_by(|left, right| {
            left.canonical_home
                .cmp(&right.canonical_home)
                .then_with(|| left.operation_id.cmp(&right.operation_id))
        });
        active_operations
    }

    fn prune_finished(&mut self) {
        while self.finished_order.len() > MAX_FINISHED_PROVIDER_OPERATIONS {
            let Some(operation_id) = self.finished_order.pop_front() else {
                break;
            };
            if self
                .operations
                .get(&operation_id)
                .map(|record| record.lifecycle)
                == Some(ProviderOperationLifecycle::Finished)
            {
                self.operations.remove(&operation_id);
            }
        }
    }

    #[cfg(test)]
    fn finished_count(&self) -> usize {
        self.finished_order.len()
    }

    #[cfg(test)]
    fn replace_owner_for_test(&mut self, canonical_home: PathBuf, operation_id: String) {
        self.active_by_home
            .insert(canonical_home.clone(), operation_id.clone());
        self.operations.insert(
            operation_id,
            ProviderOperationRecord {
                canonical_home,
                lifecycle: ProviderOperationLifecycle::Active,
            },
        );
    }
}

struct ProviderOperationLease {
    canonical_home: PathBuf,
    operation_id: String,
}

impl Drop for ProviderOperationLease {
    fn drop(&mut self) {
        let mut registry = provider_operation_registry()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.finish(&self.operation_id);
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
    run_provider_mutation(codex_home, operation_id, |canonical_home| {
        let backup_root = provider_backup_root()?;
        let pinned_home = PinnedHome::open(canonical_home)?;
        reconcile_pending_restore_before_backup(
            &backup_root,
            &pinned_home,
            crate::platform::codex_desktop_is_running,
        )?;
        let report = scan_provider_repair_result_for_home(&pinned_home)?;
        let backup = backups::create_provider_backup_files_at_with_pinned_hook(
            &backup_root,
            &pinned_home,
            &report.target.provider,
            |_, _| Ok(()),
        )?;
        Ok(action_result(
            snapshot_from_report(scan_provider_repair_result_for_home(&pinned_home)?),
            format!("已创建备份：{}", backup.id),
            Some(backup),
        ))
    })
}

fn reconcile_pending_restore_before_backup(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    probe: impl FnOnce() -> Result<bool, String>,
) -> Result<(), String> {
    if !backups::has_unfinished_restore_transactions_at(backup_root)? {
        return Ok(());
    }
    let running = probe()
        .map_err(|error| format!("恢复未完成事务前无法确认 Codex Desktop 运行状态：{error}"))?;
    if running {
        return Err(
            "恢复未完成事务已拒绝：Codex 正在运行。请先退出 Codex Desktop，再重新创建 Provider 备份。"
                .into(),
        );
    }
    backups::reconcile_unfinished_restore_transactions_with_pinned(backup_root, pinned_home)
}

pub fn sync_provider_history(
    codex_home: &Path,
    operation_id: &str,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    run_provider_mutation_with_running_probe(
        codex_home,
        operation_id,
        "同步",
        crate::platform::codex_desktop_is_running,
        |canonical_home| {
            let backup_root = provider_backup_root()?;
            let outcome = sync_provider_history_transaction_at(
                canonical_home,
                &backup_root,
                scan_provider_repair_result,
            )?;
            Ok(action_result(
                outcome.snapshot,
                outcome.message,
                Some(outcome.backup),
            ))
        },
    )
}

#[derive(Debug)]
struct ProviderSyncTransactionOutcome {
    backup: crate::models::ProviderRepairBackupInfo,
    snapshot: ProviderRepairSnapshot,
    message: String,
}

fn sync_provider_history_transaction_at(
    codex_home: &Path,
    backup_root: &Path,
    verify: impl FnOnce(&Path) -> Result<ProviderRepairReport, String>,
) -> Result<ProviderSyncTransactionOutcome, String> {
    sync_provider_history_transaction_at_with_backup_hook(
        codex_home,
        backup_root,
        verify,
        |_, _| Ok(()),
    )
}

fn sync_provider_history_transaction_at_with_backup_hook(
    codex_home: &Path,
    backup_root: &Path,
    verify: impl FnOnce(&Path) -> Result<ProviderRepairReport, String>,
    hook: impl FnMut(backups::BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderSyncTransactionOutcome, String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    backups::reconcile_unfinished_restore_transactions_with_pinned(backup_root, &pinned_home)?;
    let report = scan_provider_repair_result_for_home(&pinned_home)?;
    let target_provider = provider_for_mutation(&report.target.provider)?;
    let backup = backups::create_provider_backup_files_at_with_pinned_stopped_hook(
        backup_root,
        &pinned_home,
        &target_provider,
        hook,
    )?;

    let transaction = perform_provider_sync(&pinned_home, &target_provider, &backup).and_then(
        |(rewritten_sessions, sqlite_rows, index_changed)| {
            let verified_report = verify(pinned_home.canonical_path())?;
            validate_provider_sync_report(&verified_report, &backup, &target_provider)?;
            let snapshot = snapshot_from_report(verified_report);
            let message = format!(
                "已同步为 {}：JSONL {} 个，SQLite {} 行，session_index {}；恢复点 {}。",
                target_provider,
                rewritten_sessions,
                sqlite_rows,
                if index_changed {
                    "已补齐"
                } else {
                    "无需修改"
                },
                backup.id
            );
            Ok((snapshot, message))
        },
    );

    match transaction {
        Ok((snapshot, message)) => Ok(ProviderSyncTransactionOutcome {
            backup,
            snapshot,
            message,
        }),
        Err(original_error) => match restore_provider_backup_files_with_pinned_verification(
            &pinned_home,
            &backup,
            |_| Ok(()),
        ) {
            Ok(()) => Err(format!(
                "Provider 同步或验证失败：{original_error}；已自动恢复恢复点 {}。",
                backup.id
            )),
            Err(restore_error) => Err(format!(
                "Provider 同步或验证失败：{original_error}；自动恢复恢复点 {} 失败：{restore_error}；恢复点保留于 {}。",
                backup.id,
                backup.path
            )),
        },
    }
}

fn perform_provider_sync(
    pinned_home: &PinnedHome,
    target_provider: &str,
    backup: &crate::models::ProviderRepairBackupInfo,
) -> Result<(u32, u32, bool), String> {
    let mut rewritten_sessions = 0_u32;
    for relative in backups::verified_session_relative_paths(backup)? {
        if rewrite_session_provider_relative_in(pinned_home, &relative, target_provider, |_, _| {
            Ok(())
        })? {
            rewritten_sessions = rewritten_sessions.saturating_add(1);
        }
    }
    let sqlite_snapshot = backups::verified_sqlite_snapshot(backup)?;
    let sqlite_rows = if let Some(snapshot) = sqlite_snapshot {
        sync_sqlite_provider_from_snapshot_in(
            pinned_home,
            target_provider,
            &snapshot.path,
            snapshot.size,
            &snapshot.checksum_sha256,
        )?
    } else {
        0
    };
    let index_changed = repair_session_index_in(pinned_home)?;
    Ok((rewritten_sessions, sqlite_rows, index_changed))
}

fn validate_provider_sync_report(
    report: &ProviderRepairReport,
    backup: &crate::models::ProviderRepairBackupInfo,
    expected_provider: &str,
) -> Result<(), String> {
    if report.target.provider != expected_provider {
        return Err(format!(
            "Provider 验证目标不匹配：预期 {expected_provider}，实际 {}。",
            report.target.provider
        ));
    }
    if report.inconsistent_count != 0 || report.session_scan.invalid_files != 0 {
        return Err(format!(
            "Provider 验证仍有 {} 条不一致，其中异常会话文件 {} 个。",
            report.inconsistent_count, report.session_scan.invalid_files
        ));
    }
    if backup.session_files > 0 && report.session_scan.files_found == 0 {
        return Err("Provider 验证没有读取到预期会话文件。".into());
    }
    if backup.state_database && report.sqlite_scan.integrity != "ok" {
        return Err(format!(
            "Provider 验证 SQLite integrity_check: {}",
            report.sqlite_scan.integrity
        ));
    }
    Ok(())
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
    run_provider_mutation_with_running_probe(
        codex_home,
        operation_id,
        "回滚",
        crate::platform::codex_desktop_is_running,
        |canonical_home| {
            let backup = backup_by_id(backup_id)?;
            ensure_backup_matches_codex_home(&backup, canonical_home)?;
            let mut verified_report = None;
            restore_provider_backup_files_with_verification(
                canonical_home,
                &backup,
                |restored_home| {
                    verified_report =
                        Some(verify_restored_provider_backup(restored_home, &backup)?);
                    Ok(())
                },
            )?;
            let report = verified_report
                .ok_or_else(|| "回滚后的 Provider 强验证未返回结果。".to_string())?;

            Ok(action_result(
                snapshot_from_report(report),
                format!("已回滚备份：{}", backup.id),
                Some(backup),
            ))
        },
    )
}

fn verify_restored_provider_backup(
    codex_home: &Path,
    backup: &crate::models::ProviderRepairBackupInfo,
) -> Result<ProviderRepairReport, String> {
    let report = scan_provider_repair_result(codex_home)
        .map_err(|error| format!("恢复后的 Provider 扫描失败：{error}"))?;
    if report.target.provider != backup.target_provider {
        return Err(format!(
            "恢复后的 Provider 目标不匹配：预期 {}，实际 {}。",
            backup.target_provider, report.target.provider
        ));
    }
    if report.session_scan.files_found < backup.session_files {
        return Err(format!(
            "恢复后的 Provider 会话文件不足：预期至少 {}，实际 {}。",
            backup.session_files, report.session_scan.files_found
        ));
    }
    if backup.state_database && report.sqlite_scan.integrity != "ok" {
        return Err(format!(
            "恢复后的 SQLite integrity_check: {}",
            report.sqlite_scan.integrity
        ));
    }
    Ok(report)
}

pub fn read_provider_operation_status(operation_id: &str) -> ProviderOperationStatus {
    let registry = provider_operation_registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.status(operation_id)
}

pub fn discover_provider_operation_ownership() -> ProviderOperationOwnershipDiscovery {
    let registry = provider_operation_registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    ProviderOperationOwnershipDiscovery {
        active_operations: registry.active_ownership(),
    }
}

fn provider_operation_registry() -> &'static Mutex<ProviderOperationRegistry> {
    PROVIDER_OPERATION_REGISTRY.get_or_init(|| Mutex::new(ProviderOperationRegistry::default()))
}

fn canonical_codex_home(codex_home: &Path) -> Result<PathBuf, ProviderOperationError> {
    codex_home
        .canonicalize()
        .map_err(|error| ProviderOperationError::Failed {
            message: format!("无法确认 Codex Home {}：{error}", codex_home.display()),
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
    let mut registry = provider_operation_registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.acquire(canonical_home.clone(), operation_id)?;
    Ok(ProviderOperationLease {
        canonical_home,
        operation_id: operation_id.to_string(),
    })
}

fn run_provider_mutation<T>(
    codex_home: &Path,
    operation_id: &str,
    mutation: impl FnOnce(&Path) -> Result<T, String>,
) -> Result<T, ProviderOperationError> {
    let lease = acquire_provider_operation_lease(codex_home, operation_id)?;
    mutation(&lease.canonical_home).map_err(|message| ProviderOperationError::Failed { message })
}

fn run_provider_mutation_with_running_probe<T>(
    codex_home: &Path,
    operation_id: &str,
    operation: &str,
    probe: impl FnOnce() -> Result<bool, String>,
    mutation: impl FnOnce(&Path) -> Result<T, String>,
) -> Result<T, ProviderOperationError> {
    let lease = acquire_provider_operation_lease(codex_home, operation_id)?;
    let running = probe().map_err(|error| ProviderOperationError::Failed {
        message: format!("{operation}前无法确认 Codex Desktop 运行状态：{error}"),
    })?;
    if running {
        return Err(ProviderOperationError::Failed {
            message: format!(
                "{operation}已拒绝：Codex 正在运行。请先退出 Codex Desktop，再重新执行 Provider 修复。"
            ),
        });
    }
    mutation(&lease.canonical_home).map_err(|message| ProviderOperationError::Failed { message })
}

fn scan_provider_repair_result(codex_home: &Path) -> Result<ProviderRepairReport, String> {
    let session_files = find_session_files(codex_home, true)?;
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

fn scan_provider_repair_result_for_home(
    pinned_home: &PinnedHome,
) -> Result<ProviderRepairReport, String> {
    pinned_home.ensure_canonical_path_identity()?;
    let mut report = scan_provider_repair_result(&pinned_home.access_path())?;
    report.codex_home = pinned_home.canonical_path().to_path_buf();
    Ok(report)
}

#[cfg(test)]
#[path = "provider_repair_tests.rs"]
mod provider_repair_tests;
