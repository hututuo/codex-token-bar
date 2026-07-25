use super::backups::list_provider_backups;
use super::session_files::SessionScan;
use super::session_index::SessionIndexScan;
use super::sqlite_state::SQLiteScan;
use super::target_provider::TargetProvider;
use crate::models::{
    ProviderRepairActionResult, ProviderRepairBackupInfo, ProviderRepairSnapshot,
    ProviderRepairStep,
};
use std::path::{Path, PathBuf};

pub(super) struct ProviderRepairReport {
    #[allow(dead_code)]
    pub(super) codex_home: PathBuf,
    pub(super) target: TargetProvider,
    pub(super) session_scan: SessionScan,
    pub(super) sqlite_scan: SQLiteScan,
    pub(super) session_index: SessionIndexScan,
    pub(super) session_mismatches: u32,
    pub(super) sqlite_metadata_mismatches: u32,
    pub(super) ambiguous_threads: u32,
    pub(super) index_missing: bool,
    pub(super) inconsistent_count: u32,
}

pub(super) fn snapshot_from_report(report: ProviderRepairReport) -> ProviderRepairSnapshot {
    let status = if report.inconsistent_count == 0 {
        format!(
            "扫描完成：安全修复未发现 SQLite 元数据不一致。另有 {} 个会话可在显式迁移时切换到 {}；异常文件 {}，歧义线程 {}；SQLite {}。",
            report.session_mismatches,
            report.target.provider,
            report.session_scan.invalid_files,
            report.ambiguous_threads,
            report.sqlite_scan.integrity
        )
    } else {
        format!(
            "扫描完成：安全修复发现 {} 条不一致（SQLite 元数据 {}，异常文件 {}，歧义线程 {}）。另有 {} 个会话属于显式 Provider 迁移，不会自动改写。",
            report.inconsistent_count,
            report.sqlite_metadata_mismatches,
            report.session_scan.invalid_files,
            report.ambiguous_threads,
            report.session_mismatches
        )
    };

    ProviderRepairSnapshot {
        detected_provider: report.target.provider.clone(),
        provider_source: report.target.source.clone(),
        session_files_found: report.session_scan.files_found,
        inconsistent_count: report.inconsistent_count,
        migration_candidate_count: report.session_mismatches,
        invalid_session_files: report.session_scan.invalid_files,
        ambiguous_thread_count: report.ambiguous_threads,
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

pub(super) fn error_snapshot(codex_home: &Path, message: String) -> ProviderRepairSnapshot {
    ProviderRepairSnapshot {
        detected_provider: "openai".into(),
        provider_source: "读取失败".into(),
        session_files_found: 0,
        inconsistent_count: 1,
        migration_candidate_count: 0,
        invalid_session_files: 0,
        ambiguous_thread_count: 0,
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

pub(super) fn action_result(
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
