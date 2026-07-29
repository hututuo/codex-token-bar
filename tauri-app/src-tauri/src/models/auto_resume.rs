use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AutoResumeThreadOption {
    pub id: String,
    pub title: String,
    pub cwd: String,
    pub updated_at: i64,
    pub status: String,
    pub source: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AutoResumeRuntimeStatus {
    pub state: String,
    pub message: String,
    pub is_running: bool,
    pub waiting_for_quota: bool,
    pub last_trigger: Option<String>,
    pub last_run_at: Option<i64>,
    pub next_scheduled_at: Option<i64>,
    pub runs_today: u32,
    pub revision: u64,
    #[serde(default)]
    pub task_id: Option<String>,
    #[serde(default)]
    pub running_task_id: Option<String>,
    #[serde(default)]
    pub protected_tasks: u32,
    #[serde(default)]
    pub total_tasks: u32,
    #[serde(default)]
    pub tasks: Vec<AutoResumeTaskRuntimeStatus>,
}

impl Default for AutoResumeRuntimeStatus {
    fn default() -> Self {
        Self {
            state: "disabled".into(),
            message: "自动续跑未开启".into(),
            is_running: false,
            waiting_for_quota: false,
            last_trigger: None,
            last_run_at: None,
            next_scheduled_at: None,
            runs_today: 0,
            revision: 0,
            task_id: None,
            running_task_id: None,
            protected_tasks: 0,
            total_tasks: 0,
            tasks: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AutoResumeTaskRuntimeStatus {
    pub task_id: String,
    pub state: String,
    pub message: String,
    pub is_running: bool,
    pub waiting_for_quota: bool,
    pub last_trigger: Option<String>,
    pub last_run_at: Option<i64>,
    pub next_scheduled_at: Option<i64>,
    pub runs_today: u32,
    pub revision: u64,
}
