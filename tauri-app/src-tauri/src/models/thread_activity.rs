use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadModelBreakdown {
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub count: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadMember {
    pub thread_id: String,
    pub title: Option<String>,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadGroup {
    pub main_thread: RunningThreadMember,
    pub subagents: Vec<RunningThreadMember>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadSummary {
    pub total: Option<u32>,
    pub main_threads: Option<u32>,
    pub subagents: Option<u32>,
    pub main_models: Vec<RunningThreadModelBreakdown>,
    pub subagent_models: Vec<RunningThreadModelBreakdown>,
    pub groups: Vec<RunningThreadGroup>,
    pub unassigned_subagents: Vec<RunningThreadMember>,
    pub status: String,
    pub updated_at: Option<i64>,
    pub detail: String,
    pub liveness_lease_hours: u32,
}
