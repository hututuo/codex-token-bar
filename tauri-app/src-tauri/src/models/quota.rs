use serde::Serialize;

use super::{AccountInfo, LocalDataWarning};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountQuotaBundle {
    pub account: AccountInfo,
    pub quota: QuotaSnapshot,
    pub quota_history_24h: Vec<QuotaHistoryPoint>,
    pub warnings: Vec<LocalDataWarning>,
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
