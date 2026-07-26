use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexControlledProcess {
    pub pid: u32,
    pub executable_path: String,
    pub user_data_marker: String,
    pub started_at: i64,
    pub process_start_identity: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstance {
    pub id: String,
    pub name: String,
    pub codex_home: String,
    pub electron_data_directory: String,
    pub working_directory: Option<String>,
    pub arguments: Vec<String>,
    pub managed: bool,
    pub is_default: bool,
    pub auto_sync_enabled: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub controlled_process: Option<CodexControlledProcess>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceConflict {
    pub id: String,
    pub thread_id: String,
    pub instance_ids: Vec<String>,
    pub relative_paths: Vec<String>,
    pub hashes: Vec<String>,
    pub detected_at: i64,
    pub reason: String,
    pub resolved: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceRegistrySnapshot {
    pub schema_version: u32,
    pub updated_at: i64,
    pub instances: Vec<CodexInstance>,
    pub conflicts: Vec<CodexInstanceConflict>,
    pub registry_path: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CodexInstanceCreateMode {
    Empty,
    CopyConfiguration,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceCreateRequest {
    pub name: String,
    pub mode: CodexInstanceCreateMode,
    pub source_home: Option<String>,
    pub copy_auth: bool,
    pub working_directory: Option<String>,
    pub arguments: Vec<String>,
    pub auto_sync_enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceImportRequest {
    pub name: String,
    pub codex_home: String,
    pub working_directory: Option<String>,
    pub arguments: Vec<String>,
    pub auto_sync_enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceUpdateRequest {
    pub id: String,
    pub name: String,
    pub working_directory: Option<String>,
    pub arguments: Vec<String>,
    pub auto_sync_enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceActionResult {
    pub instance: Option<CodexInstance>,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceRuntimeStatus {
    pub id: String,
    pub running: bool,
    pub controlled: bool,
    pub pid: Option<u32>,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceSyncOperation {
    pub thread_id: String,
    pub source_instance_id: String,
    pub destination_instance_id: String,
    pub source_path: String,
    pub destination_path: String,
    pub kind: String,
    pub source_hash: String,
    pub destination_hash: Option<String>,
    pub backup_path: Option<String>,
    pub installed_hash: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceSyncPreview {
    pub instance_ids: Vec<String>,
    pub operations: Vec<CodexInstanceSyncOperation>,
    pub conflicts: Vec<CodexInstanceConflict>,
    pub unchanged_threads: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceSyncResult {
    pub transaction_id: Option<String>,
    pub operations_applied: usize,
    pub conflicts: Vec<CodexInstanceConflict>,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CodexInstanceSyncTransactionSummary {
    pub transaction_id: String,
    pub created_at: i64,
    pub state: String,
    pub instance_ids: Vec<String>,
    pub operations: usize,
    pub conflicts: usize,
}
