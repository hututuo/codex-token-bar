use crate::platform;

#[tauri::command]
pub fn show_floating_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::show_floating_window(&app)
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
pub fn set_status_tray_readout(
    app: tauri::AppHandle,
    title: String,
    tooltip: String,
) -> Result<bool, String> {
    platform::set_status_tray_readout(&app, title, tooltip)
}
