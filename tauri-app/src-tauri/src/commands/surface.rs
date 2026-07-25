use crate::platform;

#[tauri::command]
pub async fn show_floating_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::show_floating_window_from_command(&app).await
}

#[tauri::command]
pub fn hide_floating_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::hide_floating_window(&app)
}

#[tauri::command]
pub fn show_dashboard_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::show_dashboard_window(&app)
}

#[tauri::command]
pub fn show_status_panel_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::show_status_panel_window(&app)
}

#[tauri::command]
pub fn hide_status_panel_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::hide_status_panel_window(&app)
}

#[tauri::command]
pub fn dismiss_status_panel_on_blur(app: tauri::AppHandle) -> Result<bool, String> {
    platform::dismiss_status_panel_on_blur(&app)
}
