use crate::core::startup_trace;
use crate::models::{
    AppSettingsSnapshot, AutoResumeSettingsSnapshot, AutostartStatus,
    DisplaySurfaceSettingsSnapshot, FloatingWindowPositionSnapshot,
    FloatingWindowSettingsSnapshot, SessionEnhancementSettingsSnapshot,
};
use super::run_blocking_command;
use super::window_auth::require_window_label;
use crate::platform;

#[tauri::command]
pub async fn read_app_settings(
    window: tauri::WebviewWindow,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "read_app_settings")?;
    run_blocking_command(|| {
        startup_trace::mark_once("command read_app_settings start");
        let result = platform::read_app_settings();
        startup_trace::mark_once("command read_app_settings end");
        result
    })
    .await
}

#[tauri::command]
pub async fn read_autostart_status(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<AutostartStatus, String> {
    require_window_label(&window, "read_autostart_status")?;
    run_blocking_command(move || {
        startup_trace::mark_once("command read_autostart_status start");
        let result = platform::read_autostart_status(&app);
        startup_trace::mark_once("command read_autostart_status end");
        Ok(result)
    })
    .await
}

#[tauri::command]
pub async fn set_autostart_enabled(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    enabled: bool,
) -> Result<AutostartStatus, String> {
    require_window_label(&window, "set_autostart_enabled")?;
    run_blocking_command(move || platform::set_autostart_enabled(&app, enabled)).await
}

#[tauri::command]
pub async fn save_floating_settings(
    window: tauri::WebviewWindow,
    settings: FloatingWindowSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_floating_settings")?;
    run_blocking_command(move || platform::save_floating_settings(settings)).await
}

#[tauri::command]
pub async fn save_floating_position(
    window: tauri::WebviewWindow,
    position: FloatingWindowPositionSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_floating_position")?;
    run_blocking_command(move || platform::save_floating_position(position)).await
}

#[tauri::command]
pub async fn save_display_surfaces(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    live_rate: tauri::State<'_, crate::commands::live::LiveRateMonitorRegistry>,
    display: DisplaySurfaceSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_display_surfaces")?;
    // 保存（磁盘写+fsync）在阻塞池；托盘同步沿用既有原生调用路径（live 流
    // 循环本就从异步任务调用同一原生入口），失败只记录不回滚已保存设置。
    let saved = run_blocking_command(move || platform::save_display_surfaces(display)).await?;
    Ok(sync_saved_display_surfaces(
        saved,
        |saved| live_rate.sync_status_tray_interest(&app, &saved.display_surfaces),
        |error| eprintln!("Codex Token Bar: saved display settings but native tray sync failed: {error}"),
    ))
}

fn sync_saved_display_surfaces(
    saved: AppSettingsSnapshot,
    sync: impl FnOnce(&AppSettingsSnapshot) -> Result<(), String>,
    on_sync_error: impl FnOnce(&str),
) -> AppSettingsSnapshot {
    if let Err(error) = sync(&saved) {
        on_sync_error(&error);
    }
    saved
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_and_capability_io_commands_stay_async_and_offloaded() {
        let settings_source = include_str!("settings.rs");
        for command in [
            "read_app_settings",
            "read_autostart_status",
            "set_autostart_enabled",
        ] {
            assert_async_command_uses_blocking_pool(settings_source, command);
        }
        assert_async_command_uses_blocking_pool(
            include_str!("dashboard.rs"),
            "read_platform_capabilities",
        );
    }

    fn assert_async_command_uses_blocking_pool(source: &str, command: &str) {
        let marker = format!("pub async fn {command}(");
        let start = source
            .find(&marker)
            .unwrap_or_else(|| panic!("{command} must remain async"));
        let remainder = &source[start + marker.len()..];
        let end = remainder
            .find("#[tauri::command]")
            .unwrap_or(remainder.len());
        let body = &remainder[..end];
        assert!(
            body.contains("run_blocking_command"),
            "{command} must keep blocking disk/OS work off the command executor"
        );
        assert!(
            !source.contains(&format!("pub fn {command}(")),
            "{command} must not regress to a synchronous Tauri command"
        );
    }

    #[test]
    fn successful_display_save_synchronously_updates_native_runtime() {
        let display = DisplaySurfaceSettingsSnapshot::default();
        let mut settings = AppSettingsSnapshot::default();
        settings.display_surfaces = display.clone();
        let mut sync_calls = 0;
        let saved = sync_saved_display_surfaces(
            settings,
            |settings| {
                sync_calls += 1;
                assert_eq!(settings.display_surfaces.status_tray_live_text_enabled, display.status_tray_live_text_enabled);
                Ok(())
            },
            |_| {},
        );
        assert_eq!(sync_calls, 1);
        assert_eq!(saved.display_surfaces.live_rate_enabled, display.live_rate_enabled);
    }


    #[test]
    fn persisted_display_save_returns_snapshot_when_native_sync_fails() {
        let display = DisplaySurfaceSettingsSnapshot::default();
        let mut settings = AppSettingsSnapshot::default();
        settings.display_surfaces = display.clone();
        let mut errors = Vec::new();
        let saved = sync_saved_display_surfaces(
            settings,
            |_| Err("tray missing".into()),
            |error| errors.push(error.to_string()),
        );
        assert_eq!(saved.display_surfaces.live_rate_enabled, display.live_rate_enabled);
        assert_eq!(errors, vec!["tray missing"]);
    }
}

#[tauri::command]
pub async fn save_custom_account_display_name(
    window: tauri::WebviewWindow,
    custom_account_display_name: String,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_custom_account_display_name")?;
    run_blocking_command(move || {
        platform::save_custom_account_display_name(custom_account_display_name)
    })
    .await
}

#[tauri::command]
pub async fn save_quota_refresh_interval_ms(
    window: tauri::WebviewWindow,
    interval_ms: u64,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_quota_refresh_interval_ms")?;
    run_blocking_command(move || platform::save_quota_refresh_interval_ms(interval_ms)).await
}

#[tauri::command]
pub async fn save_auto_resume_settings(
    window: tauri::WebviewWindow,
    registry: tauri::State<'_, crate::commands::auto_resume::AutoResumeRegistry>,
    settings: AutoResumeSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_auto_resume_settings")?;
    // 设置保存与注册表推进各含一次 fsync（后者内部还会持久化续跑状态），
    // 同批留在阻塞池，一次点击不再在主线程落盘两次。
    let registry = registry.inner().clone();
    run_blocking_command(move || {
        let saved = platform::save_auto_resume_settings(settings)?;
        registry.update_settings(saved.auto_resume.clone());
        Ok(saved)
    })
    .await
}

#[tauri::command]
pub async fn save_session_enhancement_settings(
    window: tauri::WebviewWindow,
    settings: SessionEnhancementSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_session_enhancement_settings")?;
    let saved =
        run_blocking_command(move || platform::save_session_enhancement_settings(settings)).await?;
    crate::core::thread_delete::request_reconnect();
    Ok(saved)
}

#[tauri::command]
pub async fn save_setup_guide_completed(
    window: tauri::WebviewWindow,
    completed: bool,
) -> Result<AppSettingsSnapshot, String> {
    require_window_label(&window, "save_setup_guide_completed")?;
    run_blocking_command(move || platform::save_setup_guide_completed(completed)).await
}
