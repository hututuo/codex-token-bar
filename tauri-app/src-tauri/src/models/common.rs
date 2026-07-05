use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalDataWarning {
    pub source: String,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaDiagnostic {
    pub source: String,
    pub category: String,
    pub severity: String,
    pub message: String,
    pub raw_cause: Option<String>,
    pub underlying_category: Option<String>,
    pub attempts: Option<u32>,
    pub http_status: Option<u16>,
    pub retryable: bool,
    pub occurred_at: String,
    pub stale_data_displayed: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountInfo {
    pub display_name: String,
    pub plan_label: String,
}
