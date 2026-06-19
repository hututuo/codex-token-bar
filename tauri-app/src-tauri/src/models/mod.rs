mod common;
mod dashboard;
mod platform;
mod quota;
mod settings;

pub use common::{AccountInfo, LocalDataWarning};
pub use dashboard::{
    ActivityDay, CacheHitRankingItem, DashboardSnapshot, DashboardStats, RecentUsagePoint,
};
pub use platform::{
    AutostartStatus, CodexHomeStatus, PlatformCapabilities, PlatformFeatureCapability,
};
pub use quota::{
    AccountQuotaBundle, QuotaHistoryPoint, QuotaLimit, QuotaSnapshot, ResetCreditDetail,
    ResetCreditSummary,
};
pub use settings::{
    AppSettingsSnapshot, DisplaySurfaceSettingsSnapshot, FloatingWindowPositionSnapshot,
    FloatingWindowSettingsSnapshot,
};

use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveRateSnapshot {
    pub scope_label: String,
    pub thread_title: String,
    pub selected_thread_id: Option<String>,
    pub selected_thread_title: String,
    pub selected_tokens_per_second: f64,
    pub tokens_per_second: f64,
    pub total_tokens_today: u64,
    pub requests_today: u32,
    pub max_tokens_per_second: f64,
    pub precise_enabled: bool,
    pub warnings: Vec<LocalDataWarning>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveThreadOption {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub updated_at: String,
    pub tokens_used: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingPanelSnapshot {
    pub tokens_per_second: f64,
    pub trend_label: String,
    pub total_tokens_label: String,
    pub today_tokens_label: String,
    pub requests_label: String,
    pub five_hour_label: String,
    pub seven_day_label: String,
    pub unread: bool,
    pub unread_summary: UnreadSummary,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UnreadSummary {
    pub active: bool,
    pub count: u32,
    pub label: String,
    pub detail: String,
    pub source: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRepairSnapshot {
    pub detected_provider: String,
    pub provider_source: String,
    pub session_files_found: u32,
    pub inconsistent_count: u32,
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

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRepairBackupInfo {
    pub id: String,
    pub created_at: String,
    pub path: String,
    pub codex_home: String,
    pub codex_home_fingerprint: String,
    pub target_provider: String,
    pub session_files: u32,
    pub state_database: bool,
    pub session_index: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRepairActionResult {
    pub snapshot: ProviderRepairSnapshot,
    pub message: String,
    pub backup: Option<ProviderRepairBackupInfo>,
    pub backups: Vec<ProviderRepairBackupInfo>,
}
