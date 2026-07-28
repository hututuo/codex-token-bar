use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadSummary {
    pub total: Option<u32>,
    pub main_threads: Option<u32>,
    pub subagents: Option<u32>,
    pub status: String,
    pub updated_at: Option<i64>,
    pub detail: String,
    pub liveness_lease_hours: u32,
}
