use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRepairSnapshot {
    pub detected_provider: String,
    pub provider_source: String,
    pub sqlite_home: String,
    pub session_files_found: u32,
    pub inconsistent_count: u32,
    pub migration_candidate_count: u32,
    pub invalid_session_files: u32,
    pub ambiguous_thread_count: u32,
    pub status: String,
    pub steps: Vec<ProviderRepairStep>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRepairStep {
    pub label: String,
    pub status: String,
    pub done: bool,
    pub healthy: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderRepairBackupRestoreStatus {
    Supported,
    LegacyUnsupported,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRepairBackupInfo {
    pub id: String,
    pub created_at: String,
    pub path: String,
    pub codex_home: String,
    pub codex_home_fingerprint: String,
    pub sqlite_home: String,
    pub sqlite_home_fingerprint: String,
    pub target_provider: String,
    pub session_files: u32,
    pub state_database: bool,
    pub session_index: bool,
    pub restore_status: ProviderRepairBackupRestoreStatus,
    pub restore_unsupported_reason: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRepairActionResult {
    pub snapshot: ProviderRepairSnapshot,
    pub message: String,
    pub backup: Option<ProviderRepairBackupInfo>,
    pub backups: Vec<ProviderRepairBackupInfo>,
}
