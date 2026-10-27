pub(crate) mod probe;
pub(crate) mod scoring;
pub(crate) mod store;
use serde::{Deserialize, Serialize};

pub const DEFAULT_MODEL: &str = "gpt-6.1-sol";
pub const EFFORT: &str = "low";
pub const PROBE_COUNTS: [usize; 3] = [307, 319, 331];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AutoSettings {
    pub enabled: bool,
    pub interval_hours: u16,
    pub next_run_at: Option<i64>,
    pub scope_key: Option<String>,
}
impl Default for AutoSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            interval_hours: 24,
            next_run_at: None,
            scope_key: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub id: String,
    pub model: String,
    pub effort: String,
    pub started_at: i64,
    pub completed_at: Option<i64>,
    pub status: String,
    pub attempts: usize,
    pub valid_samples: usize,
    pub message: Option<String>,
    pub attribution: Option<scoring::Attribution>,
    pub samples: Vec<probe::Sample>,
}
pub fn request_models() -> Vec<String> {
    let mut models = vec![DEFAULT_MODEL.to_owned()];
    models.extend(scoring::models());
    models
}
pub fn result_message(model: &str, attribution: &scoring::Attribution) -> String {
    if model == DEFAULT_MODEL {
        format!("更接近 {} 特征。参考库未收录 6.1 Sol；本配置未经独立验证，不能据此确认模型身份或排除 Luna。", attribution.prediction)
    } else {
        format!(
            "更接近 {} 特征；相对匹配分值不是模型身份正确率。",
            attribution.prediction
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_use_three_distinct_queries_and_low_effort() {
        assert_eq!(request_models()[0], "gpt-6.1-sol");
        assert_eq!(PROBE_COUNTS.len(), 3);
        assert_eq!(EFFORT, "low");
        assert!(!scoring::models().contains(&DEFAULT_MODEL.to_owned()));
    }
}
