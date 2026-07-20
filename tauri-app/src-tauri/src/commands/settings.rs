use crate::core::startup_trace;
use crate::models::{
    AppSettingsSnapshot, AutoResumeSettingsSnapshot, AutostartStatus,
    DisplaySurfaceSettingsSnapshot, FloatingWindowPositionSnapshot,
    FloatingWindowSettingsSnapshot, SessionEnhancementSettingsSnapshot,
};
use super::window_auth::require_window_label;
use crate::platform;

#[tauri::command]
pub fn read_app_settings() -> Result<AppSettingsSnapshot, String> {
    startup_trace::mark_once("command read_app_settings start");
    let result = platform::read_app_settings();
    startup_trace::mark_once("command read_app_settings end");
    result
}

#[tauri::command]
pub fn read_autostart_status(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<AutostartStatus, String> {
    require_window_label(&window, "read_autostart_status")?;
    startup_trace::mark_once("command read_autostart_status start");
    let result = platform::read_autostart_status(&app);
    startup_trace::mark_once("command read_autostart_status end");
    Ok(result)
}

#[tauri::command]
pub fn set_autostart_enabled(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    enabled: bool,
) -> Result<AutostartStatus, String> {
    require_window_label(&window, "set_autostart_enabled")?;
    platform::set_autostart_enabled(&app, enabled)
}

#[tauri::command]
pub fn save_floating_settings(
    window: tauri::WebviewWindow,
    settings: FloatingWindowSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_floating_settings")?;
    platform::save_floating_settings(settings)
}

#[tauri::command]
pub fn save_floating_position(
    window: tauri::WebviewWindow,
    position: FloatingWindowPositionSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_floating_position")?;
    platform::save_floating_position(position)
}

#[tauri::command]
pub fn save_display_surfaces(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    live_rate: tauri::State<'_, crate::commands::live::LiveRateMonitorRegistry>,
    display: DisplaySurfaceSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_display_surfaces")?;
    save_display_surfaces_with_sync(
        display,
        platform::save_display_surfaces,
        |saved| live_rate.sync_status_tray_interest(&app, &saved.display_surfaces),
        |error| eprintln!("Codex Token Bar: saved display settings but native tray sync failed: {error}"),
    )
}

fn save_display_surfaces_with_sync(
    display: DisplaySurfaceSettingsSnapshot,
    save: impl FnOnce(DisplaySurfaceSettingsSnapshot) -> Result<AppSettingsSnapshot, String>,
    sync: impl FnOnce(&AppSettingsSnapshot) -> Result<(), String>,
    on_sync_error: impl FnOnce(&str),
) -> Result<AppSettingsSnapshot, String> {
    let saved = save(display)?;
    if let Err(error) = sync(&saved) {
        on_sync_error(&error);
    }
    Ok(saved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn successful_display_save_synchronously_updates_native_runtime() {
        let display = DisplaySurfaceSettingsSnapshot::default();
        let mut sync_calls = 0;
        let saved = save_display_surfaces_with_sync(
            display.clone(),
            |display| {
                let mut settings = AppSettingsSnapshot::default();
                settings.display_surfaces = display;
                Ok(settings)
            },
            |settings| {
                sync_calls += 1;
                assert_eq!(settings.display_surfaces.status_tray_live_text_enabled, display.status_tray_live_text_enabled);
                Ok(())
            },
            |_| {},
        ).unwrap();
        assert_eq!(sync_calls, 1);
        assert_eq!(saved.display_surfaces.live_rate_enabled, display.live_rate_enabled);
    }


    #[test]
    fn persisted_display_save_returns_snapshot_when_native_sync_fails() {
        let display = DisplaySurfaceSettingsSnapshot::default();
        let mut errors = Vec::new();
        let saved = save_display_surfaces_with_sync(
            display.clone(),
            |display| {
                let mut settings = AppSettingsSnapshot::default();
                settings.display_surfaces = display;
                Ok(settings)
            },
            |_| Err("tray missing".into()),
            |error| errors.push(error.to_string()),
        ).unwrap();
        assert_eq!(saved.display_surfaces.live_rate_enabled, display.live_rate_enabled);
        assert_eq!(errors, vec!["tray missing"]);
    }
}

#[tauri::command]
pub fn save_custom_account_display_name(
    window: tauri::WebviewWindow,
    custom_account_display_name: String,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_custom_account_display_name")?;
    platform::save_custom_account_display_name(custom_account_display_name)
}

#[tauri::command]
pub fn save_quota_refresh_interval_ms(
    window: tauri::WebviewWindow,
    interval_ms: u64,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_quota_refresh_interval_ms")?;
    platform::save_quota_refresh_interval_ms(interval_ms)
}

#[tauri::command]
pub fn save_auto_resume_settings(
    window: tauri::WebviewWindow,
    registry: tauri::State<'_, crate::commands::auto_resume::AutoResumeRegistry>,
    settings: AutoResumeSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_auto_resume_settings")?;
    let saved = platform::save_auto_resume_settings(settings)?;
    registry.update_settings(saved.auto_resume.clone());
    Ok(saved)
}

#[tauri::command]
pub fn save_session_enhancement_settings(
    window: tauri::WebviewWindow,
    settings: SessionEnhancementSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_session_enhancement_settings")?;
    let saved = platform::save_session_enhancement_settings(settings)?;
    crate::core::thread_delete::request_reconnect();
    Ok(saved)
}

#[tauri::command]
pub fn save_setup_guide_completed(
    window: tauri::WebviewWindow,
    completed: bool,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_setup_guide_completed")?;
    platform::save_setup_guide_completed(completed)
}
