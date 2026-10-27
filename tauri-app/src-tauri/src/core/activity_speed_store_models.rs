use serde::Serialize;

pub(in crate::core) const LEGACY_SOURCE_IDENTITY: &str = "legacy/unscoped";

#[derive(Clone, Debug)]
pub(in crate::core) struct ActivitySpeedSample {
    pub id: String,
    pub source_identity: String,
    pub display_mode: String,
    pub estimator_id: String,
    pub estimator_version: String,
    pub metric_kind: String,
    pub client: String,
    pub model: String,
    pub started_at: f64,
    pub ended_at: f64,
    pub output_rate: f64,
    pub covered_seconds: f64,
}

#[derive(Clone, Default, Debug)]
pub(in crate::core) struct ActivitySpeedFilter {
    pub source_identity: Option<String>,
    pub display_mode: Option<String>,
    pub estimator_id: Option<String>,
    pub estimator_version: Option<String>,
    pub metric_kind: Option<String>,
    pub client: Option<String>,
    pub model: Option<String>,
    pub trend_since: Option<f64>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::core) struct ActivitySpeedDimensions {
    pub source_identity: String,
    pub display_mode: String,
    pub estimator_id: String,
    pub estimator_version: String,
    pub metric_kind: String,
    pub client: String,
    pub model: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::core) struct ActivitySpeedAggregate {
    pub weighted_output: f64,
    pub covered_seconds: f64,
    pub output_rate: f64,
}

impl ActivitySpeedAggregate {
    pub(super) fn new(weighted_output: f64, covered_seconds: f64) -> Self {
        Self {
            weighted_output,
            covered_seconds,
            output_rate: weighted_output / covered_seconds,
        }
    }

    pub fn output_rate(&self) -> f64 {
        self.output_rate
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::core) struct ActivitySpeedTrendPoint {
    pub bucket_start: i64,
    pub value: ActivitySpeedAggregate,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::core) struct ActivitySpeedSeries {
    pub dimensions: ActivitySpeedDimensions,
    pub rolling_5m: Option<ActivitySpeedAggregate>,
    pub rolling_15m: Option<ActivitySpeedAggregate>,
    pub rolling_30m: Option<ActivitySpeedAggregate>,
    pub five_minute_trend: Vec<ActivitySpeedTrendPoint>,
    pub thirty_minute_trend: Vec<ActivitySpeedTrendPoint>,
}

impl ActivitySpeedSeries {
    pub(super) fn new(dimensions: ActivitySpeedDimensions) -> Self {
        Self {
            dimensions,
            rolling_5m: None,
            rolling_15m: None,
            rolling_30m: None,
            five_minute_trend: Vec::new(),
            thirty_minute_trend: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::core) struct ActivitySpeedQueryResult {
    pub series: Vec<ActivitySpeedSeries>,
}
