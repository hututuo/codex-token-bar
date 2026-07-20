use super::window_auth::require_window_label;
use crate::core::thread_delete::{self, ThreadDeleteBridgeStatus};

#[tauri::command]
pub fn read_thread_delete_bridge_status(
    window: tauri::WebviewWindow,
) -> Result<ThreadDeleteBridgeStatus, String> {
    require_window_label(&window, "read_thread_delete_bridge_status")?;
    Ok(thread_delete::bridge_status())
}

#[tauri::command]
pub fn reconnect_thread_delete_bridge(
    window: tauri::WebviewWindow,
) -> Result<ThreadDeleteBridgeStatus, String> {
    require_window_label(&window, "reconnect_thread_delete_bridge")?;
    Ok(thread_delete::request_reconnect())
}

#[tauri::command]
pub async fn enable_thread_delete_bridge(
    window: tauri::WebviewWindow,
) -> Result<ThreadDeleteBridgeStatus, String> {
    require_window_label(&window, "enable_thread_delete_bridge")?;
    tauri::async_runtime::spawn_blocking(thread_delete::enable_with_codex_restart)
        .await
        .map_err(|error| format!("启用 Codex 会话增强任务失败：{error}"))?
}
