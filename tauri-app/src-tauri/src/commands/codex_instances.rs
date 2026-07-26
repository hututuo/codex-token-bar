use super::window_auth::require_window_label;
use crate::core::codex_instances;
use crate::models::{
    CodexInstanceActionResult, CodexInstanceCreateRequest, CodexInstanceImportRequest,
    CodexInstanceRegistrySnapshot, CodexInstanceRuntimeStatus, CodexInstanceSyncPreview,
    CodexInstanceSyncResult, CodexInstanceSyncTransactionSummary, CodexInstanceUpdateRequest,
};

#[tauri::command]
pub async fn list_codex_instances(
    window: tauri::WebviewWindow,
) -> Result<CodexInstanceRegistrySnapshot, String> {
    require_window_label(&window, "list_codex_instances")?;
    tauri::async_runtime::spawn_blocking(codex_instances::list_instances)
        .await
        .map_err(|error| format!("实例列表后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn create_codex_instance(
    window: tauri::WebviewWindow,
    request: CodexInstanceCreateRequest,
) -> Result<CodexInstanceActionResult, String> {
    require_window_label(&window, "create_codex_instance")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::create_instance(request))
        .await
        .map_err(|error| format!("创建实例后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn import_codex_instance(
    window: tauri::WebviewWindow,
    request: CodexInstanceImportRequest,
) -> Result<CodexInstanceActionResult, String> {
    require_window_label(&window, "import_codex_instance")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::import_instance(request))
        .await
        .map_err(|error| format!("导入实例后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn update_codex_instance(
    window: tauri::WebviewWindow,
    request: CodexInstanceUpdateRequest,
) -> Result<CodexInstanceActionResult, String> {
    require_window_label(&window, "update_codex_instance")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::update_instance(request))
        .await
        .map_err(|error| format!("修改实例后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn delete_codex_instance(
    window: tauri::WebviewWindow,
    id: String,
) -> Result<CodexInstanceActionResult, String> {
    require_window_label(&window, "delete_codex_instance")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::delete_instance(&id))
        .await
        .map_err(|error| format!("删除实例后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn read_codex_instance_runtime_status(
    window: tauri::WebviewWindow,
    id: String,
) -> Result<CodexInstanceRuntimeStatus, String> {
    require_window_label(&window, "read_codex_instance_runtime_status")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::instance_runtime_status(&id))
        .await
        .map_err(|error| format!("实例状态后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn list_codex_instance_runtime_statuses(
    window: tauri::WebviewWindow,
) -> Result<Vec<CodexInstanceRuntimeStatus>, String> {
    require_window_label(&window, "list_codex_instance_runtime_statuses")?;
    tauri::async_runtime::spawn_blocking(codex_instances::list_instance_runtime_statuses)
        .await
        .map_err(|error| format!("实例状态列表后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn launch_codex_instance(
    window: tauri::WebviewWindow,
    id: String,
) -> Result<CodexInstanceActionResult, String> {
    require_window_label(&window, "launch_codex_instance")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::launch_instance(&id))
        .await
        .map_err(|error| format!("启动实例后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn focus_codex_instance(
    window: tauri::WebviewWindow,
    id: String,
) -> Result<CodexInstanceActionResult, String> {
    require_window_label(&window, "focus_codex_instance")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::focus_instance(&id))
        .await
        .map_err(|error| format!("聚焦实例后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn stop_codex_instance(
    window: tauri::WebviewWindow,
    id: String,
) -> Result<CodexInstanceActionResult, String> {
    require_window_label(&window, "stop_codex_instance")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::stop_instance(&id))
        .await
        .map_err(|error| format!("停止实例后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn preview_codex_instance_sync(
    window: tauri::WebviewWindow,
    instance_ids: Vec<String>,
) -> Result<CodexInstanceSyncPreview, String> {
    require_window_label(&window, "preview_codex_instance_sync")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::preview_sync(instance_ids))
        .await
        .map_err(|error| format!("实例同步预览后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn sync_codex_instances(
    window: tauri::WebviewWindow,
    instance_ids: Vec<String>,
) -> Result<CodexInstanceSyncResult, String> {
    require_window_label(&window, "sync_codex_instances")?;
    tauri::async_runtime::spawn_blocking(move || codex_instances::sync_instances(instance_ids))
        .await
        .map_err(|error| format!("实例同步后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn list_codex_instance_sync_transactions(
    window: tauri::WebviewWindow,
) -> Result<Vec<CodexInstanceSyncTransactionSummary>, String> {
    require_window_label(&window, "list_codex_instance_sync_transactions")?;
    tauri::async_runtime::spawn_blocking(codex_instances::list_sync_transactions)
        .await
        .map_err(|error| format!("实例同步事务列表后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn rollback_codex_instance_sync(
    window: tauri::WebviewWindow,
    transaction_id: String,
) -> Result<CodexInstanceSyncResult, String> {
    require_window_label(&window, "rollback_codex_instance_sync")?;
    tauri::async_runtime::spawn_blocking(move || {
        codex_instances::rollback_sync_transaction(&transaction_id)
    })
    .await
    .map_err(|error| format!("实例同步回滚后台任务异常结束：{error}"))?
}
