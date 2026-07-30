use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionManagementCapability {
    pub available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionManagementCapabilities {
    pub official_archive: SessionManagementCapability,
    pub official_unarchive: SessionManagementCapability,
    pub official_delete: SessionManagementCapability,
    pub recovery_archive: SessionManagementCapability,
    pub recovery_restore: SessionManagementCapability,
    pub recovery_reclaim: SessionManagementCapability,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionManagementThread {
    pub id: String,
    pub title: String,
    pub preview: String,
    pub cwd: String,
    pub created_at: Option<i64>,
    pub updated_at: Option<i64>,
    pub recency_at: Option<i64>,
    pub archived: bool,
    pub archived_at: Option<i64>,
    pub tokens_used: Option<i64>,
    pub file_bytes: Option<u64>,
    pub file_modified_at: Option<i64>,
    pub status: String,
    pub source: Option<String>,
    pub model: Option<String>,
    pub session_id: Option<String>,
    pub forked_from_id: Option<String>,
    pub parent_thread_id: Option<String>,
    pub is_subagent: bool,
    pub spawn_child_count: u64,
    pub fork_child_count: u64,
    pub similarity_group_id: Option<String>,
    pub similarity_reason: Option<String>,
    pub protection_reasons: Vec<String>,
    pub can_archive: bool,
    pub can_unarchive: bool,
    pub can_delete: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionManagementCatalog {
    pub threads: Vec<SessionManagementThread>,
    pub generated_at: i64,
    pub codex_home: String,
    pub total_bytes: Option<u64>,
    pub warnings: Vec<String>,
    pub capabilities: SessionManagementCapabilities,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionContextMessage {
    pub id: String,
    pub role: String,
    pub content: String,
    pub timestamp: Option<String>,
    pub offset: u64,
    pub kind: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionContextPage {
    pub thread_id: String,
    pub messages: Vec<SessionContextMessage>,
    pub next_before_offset: Option<u64>,
    pub has_more_before: bool,
    pub file_identity: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionDeleteRolloutSnapshot {
    pub thread_id: String,
    pub canonical_relative_path: String,
    pub physical_identity: String,
    pub size_bytes: String,
    pub modified_nanos: Option<String>,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionDeleteConfirmation {
    pub schema_version: u32,
    pub prepared_at: i64,
    pub physical_home_key: String,
    pub requested_ids: Vec<String>,
    pub effective_root_ids: Vec<String>,
    pub affected_ids: Vec<String>,
    pub rollouts: Vec<SessionDeleteRolloutSnapshot>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionActionItemResult {
    pub thread_id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_archive_path: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionBatchActionResult {
    pub results: Vec<SessionActionItemResult>,
    pub warnings: Vec<String>,
}
