use serde::{Deserialize, Serialize};

use super::{AccountInfo, LocalDataWarning, QuotaDiagnostic, QuotaSnapshot};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DashboardSnapshot {
    pub generated_at: String,
    pub account: AccountInfo,
    pub stats: DashboardStats,
    pub quota: QuotaSnapshot,
    pub activity_days: Vec<ActivityDay>,
    pub recent_usage_24h: Vec<RecentUsagePoint>,
    pub recent_usage_7d: Vec<RecentUsagePoint>,
    pub recent_usage_30d: Vec<RecentUsagePoint>,
    pub cache_hit_ranking: Vec<CacheHitRankingItem>,
    pub cache_usage: TokenCacheUsage,
    pub warnings: Vec<LocalDataWarning>,
    #[serde(default)]
    pub diagnostics: Vec<QuotaDiagnostic>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DashboardStats {
    pub total_tokens: u64,
    pub peak_day_tokens: u64,
    pub peak_thread_tokens: u64,
    pub current_streak_days: u32,
    pub longest_streak_days: u32,
    pub total_calls: u32,
    pub total_threads: u32,
    #[serde(default)]
    pub total_input_tokens: u64,
    #[serde(default)]
    pub total_cached_input_tokens: u64,
    #[serde(default)]
    pub total_output_tokens: u64,
    #[serde(default)]
    pub first_usage_at: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityDay {
    pub date: String,
    pub tokens: u64,
    pub calls: u32,
    pub cache_hit_rate: f64,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentUsagePoint {
    pub label: String,
    pub start_unix: i64,
    pub tokens: u64,
    pub calls: u32,
    pub input_tokens: u64,
    pub cached_input_tokens: u64,
    pub output_tokens: u64,
    pub cache_hit_rate: Option<f64>,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheHitRankingItem {
    pub rank: u32,
    pub title: String,
    pub subtitle: String,
    pub hit_rate: f64,
    pub input_tokens: u64,
    pub cached_tokens: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenCacheUsage {
    pub sessions: Vec<SessionCacheUsage>,
    pub turns: Vec<TurnCacheUsage>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenCacheBreakdown {
    pub input_tokens: u64,
    pub cached_input_tokens: u64,
    pub output_tokens: u64,
    pub total_tokens: u64,
    pub calls: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCacheUsage {
    pub id: String,
    pub title: String,
    pub last_updated: Option<String>,
    pub breakdown: TokenCacheBreakdown,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnCacheUsage {
    pub id: String,
    pub session_id: String,
    pub session_title: String,
    pub timestamp: String,
    pub turn_index_in_session: u32,
    pub user_prompt: String,
    pub assistant_response: String,
    pub breakdown: TokenCacheBreakdown,
}
