use serde::Serialize;

use super::LocalDataWarning;

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
