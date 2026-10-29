use super::run_blocking_command;
use crate::core::claude_local_runtime::{ClaudeLocalRuntimeRegistry, ClaudeLocalRuntimeSnapshot};
use super::window_auth::require_window_label;
#[tauri::command]
pub(crate) async fn read_claude_local_runtime_snapshot(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, ClaudeLocalRuntimeRegistry>,
) -> Result<ClaudeLocalRuntimeSnapshot, String> {
    require_window_label(&window, "read_claude_local_runtime_snapshot")?;
    let registry = registry.inner().clone();
    run_blocking_command(move || Ok(registry.read_snapshot(&app))).await
}

#[tauri::command]
pub(crate) async fn read_activity_speed_history(
    window: tauri::WebviewWindow,
    window_seconds: Option<u64>,
) -> Result<serde_json::Value,String> {
    require_window_label(&window, "read_activity_speed_history")?;
    run_blocking_command(move || {
        let now=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|e|e.to_string())?.as_secs_f64();
        match window_seconds {
            Some(window_seconds) => crate::core::activity_speed_capture::activity_history(now,window_seconds),
            None => crate::core::activity_speed_capture::query(now),
        }
    }).await
}

#[tauri::command]
pub(crate) async fn read_activity_speed_mode(window: tauri::WebviewWindow) -> Result<String,String> {
    require_window_label(&window, "read_activity_speed_mode")?;
    run_blocking_command(|| crate::platform::read_app_settings().map(|settings|settings.display_surfaces.speed_display_mode)).await
}

#[tauri::command]
pub(crate) async fn save_activity_speed_mode(window: tauri::WebviewWindow, app: tauri::AppHandle, mode: String) -> Result<String,String> {
    use tauri::Emitter;
    require_window_label(&window, "save_activity_speed_mode")?;
    let saved=run_blocking_command(move || crate::platform::save_activity_speed_mode(mode)).await?;
    let _=app.emit("activity-speed-mode-changed",&saved);
    Ok(saved)
}
