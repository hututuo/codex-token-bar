use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeStatus {
    pub path: String,
    pub exists: bool,
    pub source: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformCapabilities {
    pub platform: String,
    pub shell: String,
    pub floating_window: PlatformFeatureCapability,
    pub floating_transparency: PlatformFeatureCapability,
    pub floating_drag: PlatformFeatureCapability,
    pub floating_lock: PlatformFeatureCapability,
    pub status_tray: PlatformFeatureCapability,
    pub status_tray_live_text: PlatformFeatureCapability,
    pub autostart: PlatformFeatureCapability,
    pub notifications: PlatformFeatureCapability,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformFeatureCapability {
    pub available: bool,
    pub status: String,
    pub label: String,
    pub note: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettingsSnapshot {
    #[serde(default, alias = "codex_home")]
    pub codex_home: Option<String>,
    #[serde(default)]
    pub floating_window: FloatingWindowSettingsSnapshot,
    #[serde(default)]
    pub floating_position: Option<FloatingWindowPositionSnapshot>,
    #[serde(default)]
    pub display_surfaces: DisplaySurfaceSettingsSnapshot,
    #[serde(default)]
    pub setup_guide_completed: bool,
}

impl Default for AppSettingsSnapshot {
    fn default() -> Self {
        Self {
            codex_home: None,
            floating_window: FloatingWindowSettingsSnapshot::default(),
            floating_position: None,
            display_surfaces: DisplaySurfaceSettingsSnapshot::default(),
            setup_guide_completed: false,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingWindowSettingsSnapshot {
    #[serde(default = "default_floating_opacity")]
    pub opacity: f64,
    #[serde(default = "default_floating_scale")]
    pub scale: f64,
    #[serde(default = "default_floating_unread_effect")]
    pub unread_effect: String,
}

impl Default for FloatingWindowSettingsSnapshot {
    fn default() -> Self {
        Self {
            opacity: default_floating_opacity(),
            scale: default_floating_scale(),
            unread_effect: default_floating_unread_effect(),
        }
    }
}

fn default_floating_opacity() -> f64 {
    0.92
}

fn default_floating_scale() -> f64 {
    1.0
}

fn default_floating_unread_effect() -> String {
    "ripple".into()
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingWindowPositionSnapshot {
    pub x: f64,
    pub y: f64,
    pub saved_at: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplaySurfaceSettingsSnapshot {
    #[serde(default = "default_enabled")]
    pub floating_window_enabled: bool,
    #[serde(default = "default_enabled")]
    pub status_tray_live_text_enabled: bool,
}

impl Default for DisplaySurfaceSettingsSnapshot {
    fn default() -> Self {
        Self {
            floating_window_enabled: default_enabled(),
            status_tray_live_text_enabled: default_enabled(),
        }
    }
}

fn default_enabled() -> bool {
    true
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DashboardSnapshot {
    pub generated_at: String,
    pub account: AccountInfo,
    pub stats: DashboardStats,
    pub quota: QuotaSnapshot,
    pub activity_days: Vec<ActivityDay>,
    pub recent_usage_24h: Vec<RecentUsagePoint>,
    pub cache_hit_ranking: Vec<CacheHitRankingItem>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountQuotaBundle {
    pub account: AccountInfo,
    pub quota: QuotaSnapshot,
    pub quota_history_24h: Vec<QuotaHistoryPoint>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountInfo {
    pub display_name: String,
    pub plan_label: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DashboardStats {
    pub total_tokens: u64,
    pub peak_day_tokens: u64,
    pub peak_thread_tokens: u64,
    pub current_streak_days: u32,
    pub longest_streak_days: u32,
    pub total_calls: u32,
    pub total_threads: u32,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub five_hour: QuotaLimit,
    pub seven_day: QuotaLimit,
    pub reset_credit: ResetCreditSummary,
    pub pace_label: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaLimit {
    pub label: String,
    pub remaining_percent: f64,
    pub used_percent: f64,
    pub resets_at: String,
    pub resets_at_unix: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaHistoryPoint {
    pub label: String,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCreditSummary {
    pub available_count: u32,
    pub status: String,
    pub credits: Vec<ResetCreditDetail>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCreditDetail {
    pub title: String,
    pub status: String,
    pub summary: String,
    pub issued_at: String,
    pub expires_at: String,
    pub redeemed_at: String,
    pub source: String,
    pub associated_user: String,
    pub short_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityDay {
    pub date: String,
    pub tokens: u64,
    pub calls: u32,
    pub cache_hit_rate: f64,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentUsagePoint {
    pub label: String,
    pub tokens: u64,
    pub calls: u32,
    pub cache_hit_rate: Option<f64>,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheHitRankingItem {
    pub rank: u32,
    pub title: String,
    pub subtitle: String,
    pub hit_rate: f64,
    pub input_tokens: u64,
    pub cached_tokens: u64,
}

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
