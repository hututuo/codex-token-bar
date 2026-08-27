use serde::{Deserialize, Serialize};

use super::{AccountInfo, LocalDataWarning, QuotaDiagnostic};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountQuotaBundle {
    #[serde(default)]
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attribution_identity: Option<QuotaAttributionIdentity>,
    pub account: AccountInfo,
    pub quota: QuotaSnapshot,
    pub quota_history_daily: Vec<QuotaHistoryDailyPoint>,
    pub quota_history_24h: Vec<QuotaHistoryPoint>,
    pub quota_history_7d: Vec<QuotaHistoryPoint>,
    pub quota_history_30d: Vec<QuotaHistoryPoint>,
    pub warnings: Vec<LocalDataWarning>,
    #[serde(default)]
    pub diagnostics: Vec<QuotaDiagnostic>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCreditBundle {
    pub updated_at: String,
    pub reset_credit: ResetCreditSummary,
    pub warnings: Vec<LocalDataWarning>,
    #[serde(default)]
    pub diagnostics: Vec<QuotaDiagnostic>,
    pub successful: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaAttributionIdentity {
    /// A one-way, domain-separated hash of the pinned Codex Home, stable account key,
    /// and selected quota limit. Raw account and filesystem identities never cross IPC.
    pub scope_key: String,
    pub plan: String,
    pub limit: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub five_hour: QuotaLimit,
    pub seven_day: QuotaLimit,
    pub reset_credit: ResetCreditSummary,
    pub pace_label: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaLimit {
    pub label: String,
    pub availability: QuotaAvailability,
    pub remaining_percent: Option<f64>,
    pub used_percent: Option<f64>,
    pub resets_at: String,
    pub resets_at_unix: Option<i64>,
    /// Opaque cycle token. IPC consumers may compare it but must not parse it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cycle_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaAvailability {
    Measured,
    Unavailable,
    Absent,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaHistoryPoint {
    pub label: String,
    pub start_unix: i64,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub five_hour_cycle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seven_day_cycle_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaHistoryDailyPoint {
    pub date: String,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCreditSummary {
    pub available_count: u32,
    pub status: String,
    pub credits: Vec<ResetCreditDetail>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCreditDetail {
    pub card_id: String,
    pub title: String,
    pub status: String,
    pub summary: String,
    pub reset_type: String,
    pub issued_at: String,
    pub granted_at_unix: Option<i64>,
    pub expires_at: String,
    pub expires_at_unix: Option<i64>,
    pub redeem_started_at: String,
    pub redeemed_at: String,
    pub source: String,
    pub detail_note: String,
    pub associated_user: String,
    pub profile_image_url: String,
    pub short_id: String,
}
