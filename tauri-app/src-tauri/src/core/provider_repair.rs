use crate::core::{
    app_operation_lock::AppOperationGuard,
    cross_process_lock::CrossProcessFileLock,
};
use crate::models::{ProviderRepairActionResult, ProviderRepairSnapshot};
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

mod backups;
mod report;
pub(crate) mod safe_fs;
mod session_files;
mod sqlite_state;
mod storage_roots;
mod target_provider;

pub(crate) use storage_roots::resolve_sqlite_home_path;

use backups::{
    backup_by_id, ensure_backup_matches_codex_home, provider_backup_root,
    create_provider_backup_files_at_with_pinned_roots_selection_stopped_hook,
    restore_provider_backup_files_with_verification,
};
#[cfg(test)]
use backups::{codex_home_fingerprint, codex_home_identity};
use report::{action_result, error_snapshot, snapshot_from_report, ProviderRepairReport};
use safe_fs::PinnedHome;
#[cfg(test)]
use session_files::rewrite_session_provider;
use session_files::{
    find_session_files, parse_session_provider_record, rewrite_session_provider_relative_in,
    SessionScan,
};
#[cfg(test)]
use sqlite_state::sync_sqlite_provider;
use sqlite_state::{
    repair_sqlite_providers_from_snapshot_in, scan_sqlite_in,
    sync_sqlite_provider_from_snapshot_in,
};
use storage_roots::{open_sqlite_home_for_pinned, ProviderStorageRoots};
use target_provider::detect_target_provider_from_config;

const MAX_FINISHED_PROVIDER_OPERATIONS: usize = 256;
const PROVIDER_OPERATION_LOCK_RELATIVE_PATH: &str =
    "backups_state/codex-token-bar/provider-operation.lock";

static PROVIDER_OPERATION_REGISTRY: OnceLock<Mutex<ProviderOperationRegistry>> = OnceLock::new();
static STARTUP_RECOVERY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

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
    RecoveryBlocked {
        code: String,
        message: String,
        #[serde(rename = "recoveryPath")]
        recovery_path: Option<PathBuf>,
    },
}

impl From<String> for ProviderOperationError {
    fn from(message: String) -> Self {
        Self::Failed { message }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRecoveryHomeScope {
    pub canonical_home_fingerprint: String,
    pub home_generation: String,
}

impl ProviderRecoveryHomeScope {
    fn from_pinned(pinned_home: &PinnedHome) -> Result<Self, String> {
        let home_generation = serde_json::to_string(&pinned_home.generation_identity()?)
            .map_err(|error| format!("序列化 Codex Home generation 失败：{error}"))?;
        Ok(Self {
            canonical_home_fingerprint: backups::pinned_home_fingerprint(pinned_home),
            home_generation,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRecoveryStatus {
    pub blocked: bool,
    pub code: Option<String>,
    pub message: Option<String>,
    pub recovery_path: Option<PathBuf>,
    pub home_scope: Option<ProviderRecoveryHomeScope>,
}

impl ProviderRecoveryStatus {
    fn ready(home_scope: ProviderRecoveryHomeScope) -> Self {
        Self {
            blocked: false,
            code: None,
            message: None,
            recovery_path: None,
            home_scope: Some(home_scope),
        }
    }

    pub(crate) fn blocked(
        code: impl Into<String>,
        recovery_path: Option<PathBuf>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            blocked: true,
            code: Some(code.into()),
            message: Some(message.into()),
            recovery_path,
            home_scope: None,
        }
    }

    fn blocked_for_scope(
        home_scope: ProviderRecoveryHomeScope,
        code: impl Into<String>,
        recovery_path: Option<PathBuf>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            blocked: true,
            code: Some(code.into()),
            message: Some(message.into()),
            recovery_path,
            home_scope: Some(home_scope),
        }
    }
}

#[derive(Clone)]
pub struct ProviderRecoveryState {
    status: Arc<Mutex<ProviderRecoveryStatus>>,
}

impl Default for ProviderRecoveryState {
    fn default() -> Self {
        Self {
            status: Arc::new(Mutex::new(ProviderRecoveryStatus::blocked(
                "startupNotInitialized",
                None,
                "Provider startup recovery 尚未完成，写操作保持禁用。",
            ))),
        }
    }
}

impl ProviderRecoveryState {
    pub fn snapshot(&self) -> ProviderRecoveryStatus {
        self.status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub(crate) fn replace(&self, status: ProviderRecoveryStatus) {
        *self
            .status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = status;
    }

    pub fn status_for_home(&self, codex_home: &Path) -> ProviderRecoveryStatus {
        let home_scope = match provider_recovery_home_scope(codex_home) {
            Ok(scope) => scope,
            Err(error) => {
                return ProviderRecoveryStatus::blocked("homeUnavailable", None, error)
            }
        };
        let status = self.snapshot();
        if status.home_scope.as_ref() == Some(&home_scope) {
            return status;
        }
        ProviderRecoveryStatus::blocked_for_scope(
            home_scope,
            "homeNotCoordinated",
            None,
            "当前 Codex Home generation 尚未完成 Provider recovery 协调，写操作保持禁用。",
        )
    }

    pub fn guard_destructive_action_for_home(
        &self,
        codex_home: &Path,
    ) -> Result<(), ProviderOperationError> {
        let status = self.status_for_home(codex_home);
        if !status.blocked {
            return Ok(());
        }
        Err(ProviderOperationError::RecoveryBlocked {
            code: status.code.unwrap_or_else(|| "recoveryBlocked".into()),
            message: status
                .message
                .unwrap_or_else(|| "Provider recovery blocked。".into()),
            recovery_path: status.recovery_path,
        })
    }
}

#[cfg(test)]
pub(crate) fn initialize_provider_recovery_state_for_test(
    state: &ProviderRecoveryState,
    codex_home: &Path,
) {
    state.replace(ProviderRecoveryStatus::ready(
        provider_recovery_home_scope(codex_home).unwrap(),
    ));
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
    pub recovery_status: ProviderRecoveryStatus,
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

    fn cancel_acquire(&mut self, operation_id: &str) {
        let Some(record) = self.operations.get(operation_id) else {
            return;
        };
        if record.lifecycle != ProviderOperationLifecycle::Active {
            return;
        }
        let canonical_home = record.canonical_home.clone();
        if self
            .active_by_home
            .get(&canonical_home)
            .map(String::as_str)
            == Some(operation_id)
        {
            self.active_by_home.remove(&canonical_home);
        }
        self.operations.remove(operation_id);
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
    _app_operation_lock: AppOperationGuard,
    operation_id: String,
    _cross_process_lock: CrossProcessFileLock,
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
    let _app_operation_lock = match AppOperationGuard::acquire(codex_home) {
        Ok(lock) => lock,
        Err(error) => return error_snapshot(codex_home, error),
    };
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
        let roots = ProviderStorageRoots::open(canonical_home)?;
        let pinned_home = &roots.codex_home;
        reconcile_pending_restore_before_backup(
            &backup_root,
            pinned_home,
            &roots.sqlite_home,
            crate::platform::codex_desktop_is_running,
        )?;
        let report = scan_provider_repair_result_for_roots(pinned_home, &roots.sqlite_home)?;
        let session_relative_paths = report
            .session_scan
            .records
            .iter()
            .map(|record| {
                record
                    .file
                    .strip_prefix(pinned_home.canonical_path())
                    .map(Path::to_path_buf)
                    .map_err(|_| format!("会话文件不在固定 Codex Home 内：{}", record.file.display()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let backup = create_provider_backup_files_at_with_pinned_roots_selection_stopped_hook(
            &backup_root,
            pinned_home,
            &roots.sqlite_home,
            &report.target.provider,
            &session_relative_paths,
            |_, _| Ok(()),
        )?;
        Ok(action_result(
            snapshot_from_report(scan_provider_repair_result_for_roots(
                pinned_home,
                &roots.sqlite_home,
            )?),
            format!("已创建备份：{}", backup.id),
            Some(backup),
        ))
    })
}

fn reconcile_pending_restore_before_backup(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    probe: impl FnOnce() -> Result<bool, String>,
) -> Result<(), String> {
    if !backups::has_unfinished_restore_transactions_for_roots(
        backup_root,
        pinned_home,
        sqlite_home,
    )
    .map_err(|blocked| blocked.message)?
    {
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
    backups::reconcile_unfinished_restore_transactions_with_roots(
        backup_root,
        pinned_home,
        sqlite_home,
    )
    .map(|_| ())
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
            let outcome = sync_provider_history_transaction_at_with_backup_hook_and_probe_mode(
                canonical_home,
                &backup_root,
                ProviderSyncMode::Repair,
                None,
                scan_provider_repair_result_for_home,
                |_, _| Ok(()),
                crate::platform::codex_desktop_is_running,
            )?;
            Ok(action_result(
                outcome.snapshot,
                outcome.message,
                Some(outcome.backup),
            ))
        },
    )
}

pub fn migrate_provider_history(
    codex_home: &Path,
    target_provider: &str,
    operation_id: &str,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    let target_provider = provider_for_mutation(target_provider)
        .map_err(|message| ProviderOperationError::Failed { message })?;
    run_provider_mutation_with_running_probe(
        codex_home,
        operation_id,
        "迁移",
        crate::platform::codex_desktop_is_running,
        |canonical_home| {
            let backup_root = provider_backup_root()?;
            let outcome = sync_provider_history_transaction_at_with_backup_hook_and_probe_mode(
                canonical_home,
                &backup_root,
                ProviderSyncMode::Migrate,
                Some(&target_provider),
                scan_provider_repair_result_for_home,
                |_, _| Ok(()),
                crate::platform::codex_desktop_is_running,
            )?;
            Ok(action_result(
                outcome.snapshot,
                outcome.message,
                Some(outcome.backup),
            ))
        },
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProviderSyncMode {
    Repair,
    Migrate,
}

#[derive(Debug)]
struct ProviderSyncTransactionOutcome {
    backup: crate::models::ProviderRepairBackupInfo,
    snapshot: ProviderRepairSnapshot,
    message: String,
}

#[cfg(test)]
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

#[cfg(test)]
fn sync_provider_history_transaction_at_with_backup_hook(
    codex_home: &Path,
    backup_root: &Path,
    verify: impl FnOnce(&Path) -> Result<ProviderRepairReport, String>,
    hook: impl FnMut(backups::BackupPublicationPhase, &Path) -> Result<(), String>,
) -> Result<ProviderSyncTransactionOutcome, String> {
    sync_provider_history_transaction_at_with_backup_hook_and_probe(
        codex_home,
        backup_root,
        |pinned_home| verify(pinned_home.canonical_path()),
        hook,
        || Ok(false),
    )
}

#[cfg(test)]
fn sync_provider_history_transaction_at_with_commit_hook(
    codex_home: &Path,
    backup_root: &Path,
    verify: impl FnOnce(&Path) -> Result<ProviderRepairReport, String>,
    commit_hook: &mut dyn FnMut(backups::MutationCommitPhase) -> Result<(), String>,
) -> Result<ProviderSyncTransactionOutcome, String> {
    sync_provider_history_transaction_at_with_backup_hook_probe_mode_and_commit_hook(
        codex_home,
        backup_root,
        ProviderSyncMode::Migrate,
        None,
        |pinned_home| verify(pinned_home.canonical_path()),
        |_, _| Ok(()),
        || Ok(false),
        commit_hook,
    )
}

fn sync_provider_history_transaction_at_with_backup_hook_and_probe(
    codex_home: &Path,
    backup_root: &Path,
    verify: impl FnOnce(&PinnedHome) -> Result<ProviderRepairReport, String>,
    hook: impl FnMut(backups::BackupPublicationPhase, &Path) -> Result<(), String>,
    probe: impl FnMut() -> Result<bool, String>,
) -> Result<ProviderSyncTransactionOutcome, String> {
    sync_provider_history_transaction_at_with_backup_hook_and_probe_mode(
        codex_home,
        backup_root,
        ProviderSyncMode::Migrate,
        None,
        verify,
        hook,
        probe,
    )
}

fn sync_provider_history_transaction_at_with_backup_hook_and_probe_mode(
    codex_home: &Path,
    backup_root: &Path,
    mode: ProviderSyncMode,
    requested_provider: Option<&str>,
    verify: impl FnOnce(&PinnedHome) -> Result<ProviderRepairReport, String>,
    hook: impl FnMut(backups::BackupPublicationPhase, &Path) -> Result<(), String>,
    probe: impl FnMut() -> Result<bool, String>,
) -> Result<ProviderSyncTransactionOutcome, String> {
    sync_provider_history_transaction_at_with_backup_hook_probe_mode_and_commit_hook(
        codex_home,
        backup_root,
        mode,
        requested_provider,
        verify,
        hook,
        probe,
        &mut |_| Ok(()),
    )
}

fn sync_provider_history_transaction_at_with_backup_hook_probe_mode_and_commit_hook(
    codex_home: &Path,
    backup_root: &Path,
    mode: ProviderSyncMode,
    requested_provider: Option<&str>,
    verify: impl FnOnce(&PinnedHome) -> Result<ProviderRepairReport, String>,
    hook: impl FnMut(backups::BackupPublicationPhase, &Path) -> Result<(), String>,
    mut probe: impl FnMut() -> Result<bool, String>,
    commit_hook: &mut dyn FnMut(backups::MutationCommitPhase) -> Result<(), String>,
) -> Result<ProviderSyncTransactionOutcome, String> {
    let roots = ProviderStorageRoots::open(codex_home)?;
    let pinned_home = &roots.codex_home;
    let sqlite_home = &roots.sqlite_home;
    backups::reconcile_unfinished_restore_transactions_with_roots(
        backup_root,
        pinned_home,
        sqlite_home,
    )?;
    let report = scan_provider_repair_result_for_roots(pinned_home, sqlite_home)?;
    let target_provider =
        provider_for_mutation(requested_provider.unwrap_or(&report.target.provider))?;
    if mode == ProviderSyncMode::Migrate && report.target.provider != target_provider {
        return Err(format!(
            "显式迁移目标 {target_provider} 与当前 config.toml 生效 Provider {} 不一致；请先切换配置再迁移。",
            report.target.provider
        ));
    }
    if mode == ProviderSyncMode::Migrate
        && report.target.source != "config.toml"
        && target_provider != "openai"
    {
        return Err(format!(
            "显式迁移到 {target_provider} 前，必须先在 config.toml 中明确设置 model_provider；当前目标仅由 {} 推断，已拒绝改写历史。",
            report.target.source
        ));
    }
    let session_relative_paths = if mode == ProviderSyncMode::Migrate {
        report
            .session_scan
            .records
            .iter()
            .filter(|record| record.provider != target_provider)
            .map(|record| {
                record
                    .file
                    .strip_prefix(pinned_home.canonical_path())
                    .map(Path::to_path_buf)
                    .map_err(|_| {
                        format!(
                            "会话文件不在固定 Codex Home 内：{}",
                            record.file.display()
                        )
                    })
            })
            .collect::<Result<Vec<_>, _>>()?
    } else {
        Vec::new()
    };
    let session_providers = report.session_scan.canonical_thread_providers();
    let codex_guard_paths = [
        "config.toml",
        "session_index.jsonl",
    ]
    .into_iter()
    .map(PathBuf::from)
    .collect::<Vec<_>>();
    let sqlite_guard_paths = [
        "state_5.sqlite",
        "state_5.sqlite-wal",
        "state_5.sqlite-shm",
    ]
    .into_iter()
    .map(PathBuf::from)
    .collect::<Vec<_>>();
    let initial_guard = pinned_home.capture_mutation_guard(&codex_guard_paths)?;
    let initial_sqlite_guard = sqlite_home.capture_storage_guard(&sqlite_guard_paths)?;
    let backup = create_provider_backup_files_at_with_pinned_roots_selection_stopped_hook(
        backup_root,
        pinned_home,
        sqlite_home,
        &target_provider,
        &session_relative_paths,
        hook,
    )?;
    let mut backup_member_paths = backups::verified_member_relative_paths(&backup)?;
    backup_member_paths.sort();
    let mut expected_member_paths = sqlite_guard_paths
        .iter()
        .cloned()
        .chain(session_relative_paths.iter().cloned())
        .collect::<Vec<_>>();
    expected_member_paths.sort();
    if backup_member_paths != expected_member_paths {
        return Err("Provider fresh backup 的成员 expected set 在首写前不一致。".into());
    }
    ensure_provider_codex_stopped(&mut probe, "同步首次写入前")?;
    pinned_home.verify_mutation_guard(&initial_guard)?;
    sqlite_home.verify_storage_guard(&initial_sqlite_guard)?;
    let mut mutation_journal = backups::begin_provider_mutation_journal(
        backup_root,
        pinned_home,
        sqlite_home,
        &backup,
        match mode {
            ProviderSyncMode::Repair => "repair",
            ProviderSyncMode::Migrate => "migrate",
        },
        &target_provider,
    )?;
    ensure_provider_codex_stopped(&mut probe, "同步 journal 持久化后首次写入前")?;
    pinned_home.verify_mutation_guard(&initial_guard)?;
    sqlite_home.verify_storage_guard(&initial_sqlite_guard)?;

    let transaction = perform_provider_sync(
        pinned_home,
        sqlite_home,
        &target_provider,
        &backup,
        mode,
        &session_providers,
    )
    .and_then(|(rewritten_sessions, sqlite_rows)| {
            let verified_report = verify(pinned_home)?;
            validate_provider_sync_report(
                &verified_report,
                &backup,
                &target_provider,
                mode,
            )?;
            pinned_home.verify_mutation_scope(&initial_guard)?;
            sqlite_home.verify_storage_scope(&initial_sqlite_guard)?;
            let committed_guard = pinned_home.capture_mutation_guard(&codex_guard_paths)?;
            let committed_sqlite_guard =
                sqlite_home.capture_storage_guard(&sqlite_guard_paths)?;
            ensure_provider_codex_stopped(&mut probe, "同步最终提交前")?;
            pinned_home.verify_mutation_scope(&initial_guard)?;
            sqlite_home.verify_storage_scope(&initial_sqlite_guard)?;
            pinned_home.verify_mutation_guard(&committed_guard)?;
            sqlite_home.verify_storage_guard(&committed_sqlite_guard)?;
            let mut current_backup_members = backups::verified_member_relative_paths(&backup)?;
            current_backup_members.sort();
            if current_backup_members != expected_member_paths {
                return Err("Provider fresh backup 的成员 expected set 在最终提交前变化。".into());
            }
            Ok((verified_report, rewritten_sessions, sqlite_rows))
        });

    // 提交前的任何失败：journal 仍为 Prepared，回滚是安全且期望的动作。
    let (verified_report, rewritten_sessions, sqlite_rows) = match transaction {
        Ok(values) => values,
        Err(original_error) => {
            return Err(provider_sync_failure_with_reconcile(
                backup_root,
                pinned_home,
                sqlite_home,
                &backup,
                &original_error,
            ));
        }
    };

    let success_summary = match mode {
        ProviderSyncMode::Repair => format!(
            "已安全修复 Provider 元数据：JSONL 未改写，SQLite {} 行按各会话 canonical metadata 对齐；恢复点 {}。",
            sqlite_rows, backup.id
        ),
        ProviderSyncMode::Migrate => format!(
            "已显式迁移到 {}：JSONL 首行 {} 个，SQLite {} 行；未改写模型、消息、时间戳或 session_index；恢复点 {}。",
            target_provider, rewritten_sessions, sqlite_rows, backup.id
        ),
    };
    let snapshot = snapshot_from_report(verified_report);

    match backups::commit_provider_mutation_journal_with_hook(
        backup_root,
        &mut mutation_journal,
        commit_hook,
    ) {
        Ok(()) => Ok(ProviderSyncTransactionOutcome {
            backup,
            snapshot,
            message: success_summary,
        }),
        Err(backups::MutationCommitError::NotCommitted { detail }) => {
            // 提交标记确定未生效：与提交前失败同路径，回滚叙事是真实的。
            Err(provider_sync_failure_with_reconcile(
                backup_root,
                pinned_home,
                sqlite_home,
                &backup,
                &format!("提交标记写入未生效：{detail}"),
            ))
        }
        Err(backups::MutationCommitError::Uncertain { detail }) => {
            // 提交标记可能已生效：禁止回滚叙事，重读磁盘 journal 收敛。
            match backups::converge_provider_mutation_commit(backup_root, &mutation_journal) {
                backups::MutationCommitConvergence::Committed => {
                    Ok(ProviderSyncTransactionOutcome {
                        backup,
                        snapshot,
                        message: format!(
                            "{success_summary}提交标记首次持久化失败（{detail}），已重试同步并确认。"
                        ),
                    })
                }
                backups::MutationCommitConvergence::MarkerNotDurable { detail: sync_detail } => {
                    Ok(ProviderSyncTransactionOutcome {
                        backup,
                        snapshot,
                        message: format!(
                            "{success_summary}数据已写入并通过完整性验证，但提交标记持久化未完成（{sync_detail}）；journal 保留于 {}，下次启动将自动收敛。",
                            mutation_journal.path().display()
                        ),
                    })
                }
                backups::MutationCommitConvergence::StillPrepared => {
                    // 重读确认提交未生效，可安全按未提交回滚。
                    Err(provider_sync_failure_with_reconcile(
                        backup_root,
                        pinned_home,
                        sqlite_home,
                        &backup,
                        &format!("提交标记写入未生效：{detail}"),
                    ))
                }
                backups::MutationCommitConvergence::Unknown { detail: read_detail } => {
                    Ok(ProviderSyncTransactionOutcome {
                        backup,
                        snapshot,
                        message: format!(
                            "{success_summary}数据已写入并通过完整性验证，但提交标记状态未知（{detail}；{read_detail}）；journal 保留于 {}，下次启动将自动处理。",
                            mutation_journal.path().display()
                        ),
                    })
                }
            }
        }
    }
}

fn provider_sync_failure_with_reconcile(
    backup_root: &Path,
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    backup: &crate::models::ProviderRepairBackupInfo,
    original_error: &str,
) -> String {
    match backups::reconcile_unfinished_restore_transactions_with_roots(
        backup_root,
        pinned_home,
        sqlite_home,
    ) {
        Ok(actions) => {
            if actions.contains(&backups::MutationReconcileAction::KeptCommittedState) {
                format!(
                    "Provider 同步或验证失败：{original_error}；检测到事务已提交，已保留新状态并清理 journal；恢复点 {} 仍可用。",
                    backup.id
                )
            } else if actions.contains(&backups::MutationReconcileAction::RolledBackToBackup) {
                format!(
                    "Provider 同步或验证失败：{original_error}；已自动恢复恢复点 {}。",
                    backup.id
                )
            } else {
                format!(
                    "Provider 同步或验证失败：{original_error}；未发现需要回滚的事务，磁盘保持原状；恢复点 {} 保留于 {}。",
                    backup.id, backup.path
                )
            }
        }
        Err(restore_error) => format!(
            "Provider 同步或验证失败：{original_error}；自动恢复恢复点 {} 失败：{restore_error}；恢复点保留于 {}。",
            backup.id, backup.path
        ),
    }
}

fn ensure_provider_codex_stopped(
    probe: &mut impl FnMut() -> Result<bool, String>,
    boundary: &str,
) -> Result<(), String> {
    let running = probe().map_err(|error| format!("{boundary}无法确认 Codex 运行状态：{error}"))?;
    if running {
        return Err(format!("{boundary}检测到 Codex 正在运行，已拒绝继续提交。"));
    }
    Ok(())
}

fn perform_provider_sync(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
    target_provider: &str,
    backup: &crate::models::ProviderRepairBackupInfo,
    mode: ProviderSyncMode,
    session_providers: &HashMap<String, String>,
) -> Result<(u32, u32), String> {
    let mut rewritten_sessions = 0_u32;
    if mode == ProviderSyncMode::Migrate {
        for relative in backups::verified_session_relative_paths(backup)? {
            if rewrite_session_provider_relative_in(
                pinned_home,
                &relative,
                target_provider,
                |_, _| Ok(()),
            )? {
                rewritten_sessions = rewritten_sessions.saturating_add(1);
            }
        }
    }
    let sqlite_snapshot = backups::verified_sqlite_snapshot(backup)?;
    let sqlite_rows = if let Some(snapshot) = sqlite_snapshot {
        match mode {
            ProviderSyncMode::Repair => repair_sqlite_providers_from_snapshot_in(
                sqlite_home,
                session_providers,
                &snapshot.path,
                snapshot.size,
                &snapshot.checksum_sha256,
            )?,
            ProviderSyncMode::Migrate => sync_sqlite_provider_from_snapshot_in(
                sqlite_home,
                target_provider,
                &snapshot.path,
                snapshot.size,
                &snapshot.checksum_sha256,
            )?,
        }
    } else {
        0
    };
    Ok((rewritten_sessions, sqlite_rows))
}

fn validate_provider_sync_report(
    report: &ProviderRepairReport,
    backup: &crate::models::ProviderRepairBackupInfo,
    expected_provider: &str,
    mode: ProviderSyncMode,
) -> Result<(), String> {
    if report.target.provider != expected_provider {
        return Err(format!(
            "Provider 验证目标不匹配：预期 {expected_provider}，实际 {}。",
            report.target.provider
        ));
    }
    match mode {
        ProviderSyncMode::Repair if report.sqlite_metadata_mismatches != 0 => {
            return Err(format!(
                "Provider 安全修复验证仍有 {} 条 SQLite 元数据不一致。",
                report.sqlite_metadata_mismatches
            ));
        }
        ProviderSyncMode::Migrate
            if report.session_mismatches != 0
                || report.sqlite_scan.rows_to_repair(expected_provider) != 0 =>
        {
            return Err(format!(
                "Provider 显式迁移验证仍有 JSONL {} 个、SQLite {} 行未对齐。",
                report.session_mismatches,
                report.sqlite_scan.rows_to_repair(expected_provider)
            ));
        }
        _ => {}
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
                        Some(verify_restored_provider_backup_for_home(restored_home, &backup)?);
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

#[cfg(test)]
fn verify_restored_provider_backup(
    codex_home: &Path,
    backup: &crate::models::ProviderRepairBackupInfo,
) -> Result<ProviderRepairReport, String> {
    let report = scan_provider_repair_result(codex_home)
        .map_err(|error| format!("恢复后的 Provider 扫描失败：{error}"))?;
    validate_restored_provider_report(report, backup)
}

fn verify_restored_provider_backup_for_home(
    pinned_home: &PinnedHome,
    backup: &crate::models::ProviderRepairBackupInfo,
) -> Result<ProviderRepairReport, String> {
    let report = scan_provider_repair_result_for_home(pinned_home)
        .map_err(|error| format!("恢复后的 Provider 扫描失败：{error}"))?;
    validate_restored_provider_report(report, backup)
}

fn validate_restored_provider_report(
    report: ProviderRepairReport,
    backup: &crate::models::ProviderRepairBackupInfo,
) -> Result<ProviderRepairReport, String> {
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

pub fn discover_provider_operation_ownership(
    recovery_status: ProviderRecoveryStatus,
) -> ProviderOperationOwnershipDiscovery {
    let registry = provider_operation_registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    ProviderOperationOwnershipDiscovery {
        active_operations: registry.active_ownership(),
        recovery_status,
    }
}

pub fn discover_provider_operation_ownership_for_home(
    recovery_state: &ProviderRecoveryState,
    codex_home: &Path,
) -> ProviderOperationOwnershipDiscovery {
    discover_provider_operation_ownership(recovery_state.status_for_home(codex_home))
}

pub(crate) fn provider_recovery_backup_root() -> Result<PathBuf, String> {
    provider_backup_root()
}

pub(crate) fn reconcile_provider_recovery_on_startup_at(
    codex_home: &Path,
    backup_root: &Path,
    probe: impl FnOnce() -> Result<bool, String>,
) -> ProviderRecoveryStatus {
    let preliminary_scope = provider_recovery_home_scope(codex_home).ok();
    let operation_id = format!(
        "provider-startup-recovery-{}",
        STARTUP_RECOVERY_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    );
    let lease = match acquire_provider_operation_lease(codex_home, &operation_id) {
        Ok(lease) => lease,
        Err(ProviderOperationError::Busy { message, .. }) => {
            return provider_recovery_blocked_for_optional_scope(
                preliminary_scope,
                "backendGuardBusy",
                None,
                message,
            )
        }
        Err(ProviderOperationError::Failed { message })
        | Err(ProviderOperationError::RecoveryBlocked { message, .. }) => {
            return provider_recovery_blocked_for_optional_scope(
                preliminary_scope,
                "backendGuardFailed",
                None,
                message,
            )
        }
    };
    let pinned_home = match PinnedHome::open(&lease.canonical_home) {
        Ok(pinned_home) => pinned_home,
        Err(error) => {
            return provider_recovery_blocked_for_optional_scope(
                preliminary_scope,
                "codexHomeUnavailable",
                None,
                error,
            )
        }
    };
    let home_scope = match ProviderRecoveryHomeScope::from_pinned(&pinned_home) {
        Ok(scope) => scope,
        Err(error) => {
            return provider_recovery_blocked_for_optional_scope(
                preliminary_scope,
                "homeGenerationUnavailable",
                None,
                error,
            )
        }
    };
    let sqlite_home = match backups::sqlite_home_for_unfinished_restore_transactions(
        backup_root,
        &pinned_home,
    ) {
        Ok(Some(sqlite_home)) => sqlite_home,
        Ok(None) => return ProviderRecoveryStatus::ready(home_scope),
        Err(blocked) => {
            return ProviderRecoveryStatus::blocked_for_scope(
                home_scope,
                blocked.code,
                blocked.recovery_path,
                blocked.message,
            )
        }
    };
    let pending_path = match backups::first_unfinished_restore_transaction_for_roots(
        backup_root,
        &pinned_home,
        &sqlite_home,
    ) {
        Ok(Some(path)) => path,
        Ok(None) => return ProviderRecoveryStatus::ready(home_scope),
        Err(blocked) => {
            return ProviderRecoveryStatus::blocked_for_scope(
                home_scope,
                blocked.code,
                blocked.recovery_path,
                blocked.message,
            )
        }
    };
    let running = match probe() {
        Ok(running) => running,
        Err(error) => {
            return ProviderRecoveryStatus::blocked_for_scope(
                home_scope,
                "runningProbeFailed",
                Some(pending_path),
                format!("启动恢复前无法确认 Codex Desktop 运行状态：{error}"),
            )
        }
    };
    if running {
        return ProviderRecoveryStatus::blocked_for_scope(
            home_scope,
            "codexRunning",
            Some(pending_path),
            "启动恢复已阻止：Codex Desktop 正在运行，journal 保持不变。",
        );
    }
    match backups::reconcile_unfinished_restore_transactions_with_roots_diagnostics(
        backup_root,
        &pinned_home,
        &sqlite_home,
    ) {
        Ok(_) => ProviderRecoveryStatus::ready(home_scope),
        Err(blocked) => ProviderRecoveryStatus::blocked_for_scope(
            home_scope,
            blocked.code,
            blocked.recovery_path,
            blocked.message,
        ),
    }
}

pub(crate) fn reconcile_provider_recovery_for_action(
    recovery_state: &ProviderRecoveryState,
    codex_home: &Path,
) -> Result<ProviderRecoveryStatus, ProviderOperationError> {
    let backup_root = match provider_recovery_backup_root() {
        Ok(root) => root,
        Err(error) => {
            let status = provider_recovery_blocked_status_for_home(
                codex_home,
                "backupRootUnavailable",
                None,
                error,
            );
            recovery_state.replace(status.clone());
            recovery_state.guard_destructive_action_for_home(codex_home)?;
            return Ok(status);
        }
    };
    reconcile_provider_recovery_for_action_at(
        recovery_state,
        codex_home,
        &backup_root,
        crate::platform::codex_desktop_is_running,
    )
}

pub(crate) fn reconcile_provider_recovery_for_action_at(
    recovery_state: &ProviderRecoveryState,
    codex_home: &Path,
    backup_root: &Path,
    probe: impl FnOnce() -> Result<bool, String>,
) -> Result<ProviderRecoveryStatus, ProviderOperationError> {
    let status = reconcile_provider_recovery_on_startup_at(codex_home, backup_root, probe);
    recovery_state.replace(status.clone());
    recovery_state.guard_destructive_action_for_home(codex_home)?;
    Ok(status)
}

pub(crate) fn provider_recovery_blocked_status_for_home(
    codex_home: &Path,
    code: &str,
    recovery_path: Option<PathBuf>,
    message: impl Into<String>,
) -> ProviderRecoveryStatus {
    let message = message.into();
    match provider_recovery_home_scope(codex_home) {
        Ok(scope) => {
            ProviderRecoveryStatus::blocked_for_scope(scope, code, recovery_path, message)
        }
        Err(scope_error) => ProviderRecoveryStatus::blocked(
            code,
            recovery_path,
            format!("{message}；无法绑定当前 Codex Home scope：{scope_error}"),
        ),
    }
}

fn provider_recovery_blocked_for_optional_scope(
    home_scope: Option<ProviderRecoveryHomeScope>,
    code: &str,
    recovery_path: Option<PathBuf>,
    message: impl Into<String>,
) -> ProviderRecoveryStatus {
    let message = message.into();
    match home_scope {
        Some(scope) => {
            ProviderRecoveryStatus::blocked_for_scope(scope, code, recovery_path, message)
        }
        None => ProviderRecoveryStatus::blocked(code, recovery_path, message),
    }
}

fn provider_recovery_home_scope(codex_home: &Path) -> Result<ProviderRecoveryHomeScope, String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    ProviderRecoveryHomeScope::from_pinned(&pinned_home)
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
    {
        let mut registry = provider_operation_registry()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.acquire(canonical_home.clone(), operation_id)?;
    }
    // Preserve the existing typed Busy/operation-ID behavior above. Once this
    // provider operation owns its registry slot, wait for the shared Tauri
    // Home lane before touching session files or SQLite.
    let app_operation_lock = match AppOperationGuard::acquire(&canonical_home) {
        Ok(lock) => lock,
        Err(message) => {
            provider_operation_registry()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .cancel_acquire(operation_id);
            return Err(ProviderOperationError::Failed { message });
        }
    };

    let cross_process_lock = match (|| {
        let pinned_home = PinnedHome::open(&canonical_home)?;
        let relative = Path::new(PROVIDER_OPERATION_LOCK_RELATIVE_PATH);
        pinned_home.ensure_parent_directories(relative)?;
        CrossProcessFileLock::acquire(
            &canonical_home.join(relative),
            "当前 Codex Home 的 Provider 修复",
        )
    })() {
        Ok(lock) => lock,
        Err(message) => {
            provider_operation_registry()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .cancel_acquire(operation_id);
            return Err(ProviderOperationError::Failed { message });
        }
    };
    Ok(ProviderOperationLease {
        canonical_home,
        _app_operation_lock: app_operation_lock,
        operation_id: operation_id.to_string(),
        _cross_process_lock: cross_process_lock,
    })
}

pub(crate) fn run_provider_mutation<T>(
    codex_home: &Path,
    operation_id: &str,
    mutation: impl FnOnce(&Path) -> Result<T, String>,
) -> Result<T, ProviderOperationError> {
    let lease = acquire_provider_operation_lease(codex_home, operation_id)?;
    mutation(&lease.canonical_home).map_err(|message| ProviderOperationError::Failed { message })
}

pub(crate) fn run_provider_stopped_operation<T>(
    codex_home: &Path,
    operation_id: &str,
    operation: &str,
    mutation: impl FnOnce(&Path) -> Result<T, String>,
) -> Result<T, ProviderOperationError> {
    run_provider_mutation_with_running_probe(
        codex_home,
        operation_id,
        operation,
        crate::platform::codex_desktop_is_running,
        mutation,
    )
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
    let roots = ProviderStorageRoots::open(codex_home)?;
    scan_provider_repair_result_for_roots(&roots.codex_home, &roots.sqlite_home)
}

fn scan_provider_repair_result_for_home(
    pinned_home: &PinnedHome,
) -> Result<ProviderRepairReport, String> {
    let sqlite_home = open_sqlite_home_for_pinned(pinned_home)?;
    scan_provider_repair_result_for_roots(pinned_home, &sqlite_home)
}

fn scan_provider_repair_result_for_roots(
    pinned_home: &PinnedHome,
    sqlite_home: &PinnedHome,
) -> Result<ProviderRepairReport, String> {
    pinned_home.ensure_canonical_path_identity()?;
    sqlite_home.ensure_canonical_path_identity()?;
    let session_files = find_session_files(pinned_home.canonical_path(), true)?;
    let mut session_scan = scan_session_providers_for_home(pinned_home, &session_files);
    session_scan.newest_provider = session_scan
        .newest_provider
        .as_deref()
        .and_then(validated_provider_candidate);
    let sqlite_scan = scan_sqlite_in(sqlite_home)
        .map_err(|error| format!("读取 Provider SQLite 失败：{error}"))?;
    let config = pinned_home.read(Path::new("config.toml")).ok();
    let target =
        detect_target_provider_from_config(config.as_deref(), &sqlite_scan, &session_scan);
    let session_mismatches = session_scan.count_provider_mismatches(&target.provider);
    let session_providers = session_scan.canonical_thread_providers();
    let sqlite_metadata_mismatches =
        sqlite_scan.rows_to_repair_from_sessions(&session_providers);
    let ambiguous_threads = session_scan.ambiguous_thread_count();
    let integrity_issues =
        u32::from(sqlite_scan.database_present && sqlite_scan.integrity != "ok");
    let inconsistent_count = sqlite_metadata_mismatches
        .saturating_add(session_scan.invalid_files)
        .saturating_add(ambiguous_threads)
        .saturating_add(integrity_issues);
    pinned_home.ensure_canonical_path_identity()?;
    sqlite_home.ensure_canonical_path_identity()?;
    Ok(ProviderRepairReport {
        codex_home: pinned_home.canonical_path().to_path_buf(),
        sqlite_home: sqlite_home.canonical_path().to_path_buf(),
        target,
        session_scan,
        sqlite_scan,
        session_mismatches,
        sqlite_metadata_mismatches,
        ambiguous_threads,
        inconsistent_count,
    })
}

fn scan_session_providers_for_home(
    pinned_home: &PinnedHome,
    files: &[PathBuf],
) -> SessionScan {
    let mut provider_counts = HashMap::<String, u32>::new();
    let mut invalid_files = 0_u32;
    let mut newest_provider = None;
    let mut newest_modified = None;
    let mut records = Vec::new();
    for file in files {
        let result: Result<
            Option<(
                session_files::SessionProviderRecord,
                Option<std::time::SystemTime>,
            )>,
            String,
        > = (|| {
            let relative = file
                .strip_prefix(pinned_home.canonical_path())
                .map_err(|_| "会话文件不在固定 Codex Home 内".to_string())?;
            let opened = pinned_home
                .open_file(relative)?
                .ok_or_else(|| "会话文件在 descriptor-relative 打开前消失".to_string())?;
            let modified = opened.metadata().and_then(|metadata| metadata.modified()).ok();
            let mut reader = BufReader::new(opened);
            let mut line = String::new();
            if reader.read_line(&mut line).map_err(|error| error.to_string())? == 0 {
                return Ok(None);
            }
            Ok(parse_session_provider_record(file, &line)?.map(|record| (record, modified)))
        })();
        match result {
            Ok(Some((record, modified))) => {
                *provider_counts.entry(record.provider.clone()).or_insert(0) += 1;
                if newest_modified
                    .is_none_or(|current| modified.is_some_and(|next| next > current))
                {
                    newest_modified = modified;
                    newest_provider = Some(record.provider.clone());
                }
                records.push(record);
            }
            Ok(None) | Err(_) => invalid_files = invalid_files.saturating_add(1),
        }
    }
    SessionScan {
        files_found: u32::try_from(files.len()).unwrap_or(u32::MAX),
        provider_counts,
        invalid_files,
        newest_provider,
        records,
    }
}

#[cfg(test)]
#[path = "provider_repair_tests.rs"]
mod provider_repair_tests;
