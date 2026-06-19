use crate::core::startup_trace;
use crate::models::{
    AppSettingsSnapshot, AutostartStatus, DisplaySurfaceSettingsSnapshot,
    FloatingWindowPositionSnapshot, FloatingWindowSettingsSnapshot,
};
use crate::platform;

#[tauri::command]
pub fn read_app_settings() -> Result<AppSettingsSnapshot, String> {
    startup_trace::mark_once("command read_app_settings start");
    let result = platform::read_app_settings();
    startup_trace::mark_once("command read_app_settings end");
    result
}

#[tauri::command]
pub fn read_autostart_status(app: tauri::AppHandle) -> Result<AutostartStatus, String> {
    startup_trace::mark_once("command read_autostart_status start");
    let result = platform::read_autostart_status(&app);
    startup_trace::mark_once("command read_autostart_status end");
    Ok(result)
}

#[tauri::command]
pub fn set_autostart_enabled(
    app: tauri::AppHandle,
    enabled: bool,
) -> Result<AutostartStatus, String> {
    platform::set_autostart_enabled(&app, enabled)
}

#[tauri::command]
pub fn save_floating_settings(
    settings: FloatingWindowSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    platform::save_floating_settings(settings)
}

#[tauri::command]
pub fn save_floating_position(
    position: FloatingWindowPositionSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    platform::save_floating_position(position)
}

#[tauri::command]
pub fn save_display_surfaces(
    display: DisplaySurfaceSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    platform::save_display_surfaces(display)
}

#[tauri::command]
pub fn save_setup_guide_completed(completed: bool) -> Result<AppSettingsSnapshot, String> {
    platform::save_setup_guide_completed(completed)
}
