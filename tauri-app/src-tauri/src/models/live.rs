use serde::{Deserialize, Serialize};

use super::LocalDataWarning;

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CacheAdvice {
    pub thread_id: String,
    pub thread_title: Option<String>,
    pub hit_rate: f64,
    pub low: bool,
    pub timestamp: f64,
    pub affected_threads: usize,
    pub idle_gap_seconds: Option<f64>,
    pub model: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveRateSnapshot {
    pub scope_label: String,
    pub thread_title: String,
    pub selected_thread_id: Option<String>,
    pub selected_thread_title: String,
    pub selected_tokens_per_second: f64,
    pub tokens_per_second: f64,
    pub total_tokens: u64,
    pub total_tokens_today: u64,
    pub requests_today: u32,
    pub max_tokens_per_second: f64,
    pub precise_enabled: bool,
    #[serde(default)]
    pub c_curve: Vec<CurvePoint>,
    #[serde(default)]
    pub speed_samples: Vec<SpeedSample>,
    #[serde(default)]
    pub model_speeds: Vec<ModelSpeedSummary>,
    #[serde(default)]
    pub model_speeds_15m: Vec<ModelSpeedSummary>,
    #[serde(default)]
    pub model_speeds_30m: Vec<ModelSpeedSummary>,
    #[serde(default)]
    pub measurement_status: String,
    pub cache_advice: Option<CacheAdvice>,
    pub unread_summary: UnreadSummary,
    pub warnings: Vec<LocalDataWarning>,
}

/// A completed sample based only on timestamped response stream deltas.
/// Content itself is deliberately never serialized or persisted.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SpeedSample {
    pub id: String,
    pub thread_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub model: Option<String>,
    pub started_at: f64,
    pub ended_at: f64,
    pub output_tokens: u32,
    pub output_characters: u64,
    pub output_bytes: u64,
    pub chunk_count: u32,
    pub duration_seconds: f64,
    pub tokens_per_second: f64,
    pub confidence: String,
    #[serde(default, deserialize_with = "deserialize_network_warning")]
    pub network_warning: Option<String>,
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub measurement_kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokenizer: Option<String>,
}

fn deserialize_network_warning<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    match value {
        None | Some(serde_json::Value::Null) | Some(serde_json::Value::Bool(false)) => Ok(None),
        Some(serde_json::Value::Bool(true)) => Ok(Some("历史记录标记为采样不完整".to_owned())),
        Some(serde_json::Value::String(value)) => Ok((!value.is_empty()).then_some(value)),
        Some(_) => Err(serde::de::Error::custom(
            "networkWarning must be a string, boolean, or null",
        )),
    }
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CurvePoint {
    pub timestamp: f64,
    pub tokens_per_second: f64,
    pub remaining_budget: f64,
    pub thread_id: String,
    pub turn_id: String,
    pub model: Option<String>,
    pub status: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelSpeedSummary {
    pub model: String,
    pub tokens_per_second: f64,
    pub sample_count: u32,
    pub output_tokens: u64,
    pub duration_seconds: f64,
    #[serde(default)]
    pub active_sample_count: u32,
    #[serde(default)]
    pub qualified_sample_count: u32,
    #[serde(default = "default_model_speed_confidence")]
    pub confidence: String,
}

fn default_model_speed_confidence() -> String {
    "low".into()
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
    pub max_tokens_per_second: f64,
    pub cache_advice: Option<CacheAdvice>,
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
