use super::window_auth::require_window_label;
use crate::platform;

#[tauri::command]
pub async fn show_floating_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "show_floating_window")?;
    platform::show_floating_window_from_command(&app).await
}

#[tauri::command]
pub fn hide_floating_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "hide_floating_window")?;
    platform::hide_floating_window(&app)
}

#[tauri::command]
pub fn show_dashboard_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "show_dashboard_window")?;
    platform::show_dashboard_window(&app)
}

#[tauri::command]
pub fn show_status_panel_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "show_status_panel_window")?;
    platform::show_status_panel_window(&app)
}

#[tauri::command]
pub fn hide_status_panel_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "hide_status_panel_window")?;
    platform::hide_status_panel_window(&app)
}

#[tauri::command]
pub fn dismiss_status_panel_on_blur(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "dismiss_status_panel_on_blur")?;
    platform::dismiss_status_panel_on_blur(&app)
}
