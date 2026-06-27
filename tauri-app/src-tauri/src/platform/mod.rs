use crate::models::{AutostartStatus, CodexHomeStatus};
use std::path::PathBuf;
#[cfg(any(target_os = "macos", windows, target_os = "linux"))]
use tauri_plugin_autostart::ManagerExt;

mod capabilities;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;
mod settings;
mod surfaces;

pub use capabilities::platform_capabilities;
pub use settings::{
    read_app_settings, save_display_surfaces, save_floating_position, save_floating_settings,
    save_custom_account_display_name, save_setup_guide_completed,
};
pub use surfaces::{
    hide_floating_window, hide_status_panel_window, set_status_tray_readout, setup_desktop_surfaces,
    show_dashboard_window, show_floating_window, show_status_panel_window,
};
pub(super) use surfaces::{surface_setup_status, SurfaceSetupStatus};

#[cfg(target_os = "macos")]
use macos::default_codex_home as automatic_codex_home;
#[cfg(target_os = "windows")]
use windows::default_codex_home as automatic_codex_home;

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn automatic_codex_home() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(".codex")
}

pub fn default_codex_home() -> PathBuf {
    settings::saved_codex_home().unwrap_or_else(automatic_codex_home)
}

#[cfg(target_os = "windows")]
pub fn activate_existing_instance_and_exit() -> bool {
    windows::activate_existing_instance_and_exit()
}

#[cfg(not(target_os = "windows"))]
pub fn activate_existing_instance_and_exit() -> bool {
    false
}

pub fn default_codex_home_status() -> CodexHomeStatus {
    let path = default_codex_home();
    CodexHomeStatus {
        exists: path.exists(),
        path: path.display().to_string(),
        source: if settings::saved_codex_home().is_some() {
            "manual"
        } else {
            "auto"
        }
        .into(),
    }
}

pub fn save_codex_home(path: &str) -> Result<CodexHomeStatus, String> {
    let path = settings::normalize_user_path(path);
    let mut settings = read_app_settings()?;
    settings.codex_home = Some(path.display().to_string());
    settings::write_app_settings(&settings)?;
    Ok(CodexHomeStatus {
        exists: path.exists(),
        path: path.display().to_string(),
        source: "manual".into(),
    })
}

pub fn reset_codex_home() -> Result<CodexHomeStatus, String> {
    let mut settings = read_app_settings()?;
    settings.codex_home = None;
    settings::write_app_settings(&settings)?;
    Ok(default_codex_home_status())
}

pub fn read_autostart_status(app: &tauri::AppHandle) -> AutostartStatus {
    read_autostart_status_impl(app).unwrap_or_else(|error| AutostartStatus {
        available: false,
        enabled: false,
        status: "unavailable".into(),
        message: format!("开机自启状态读取失败：{error}"),
    })
}

pub fn set_autostart_enabled(
    app: &tauri::AppHandle,
    enabled: bool,
) -> Result<AutostartStatus, String> {
    set_autostart_enabled_impl(app, enabled).map_err(|error| {
        if enabled {
            format!("开启开机自启失败：{error}")
        } else {
            format!("关闭开机自启失败：{error}")
        }
    })
}

#[cfg(any(target_os = "macos", windows, target_os = "linux"))]
fn read_autostart_status_impl(app: &tauri::AppHandle) -> Result<AutostartStatus, String> {
    let enabled = app.autolaunch().is_enabled().map_err(|error| error.to_string())?;
    Ok(AutostartStatus {
        available: true,
        enabled,
        status: if enabled { "enabled" } else { "disabled" }.into(),
        message: if enabled {
            "已开启开机自启。".into()
        } else {
            "未开启开机自启。".into()
        },
    })
}

#[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
fn read_autostart_status_impl(_app: &tauri::AppHandle) -> Result<AutostartStatus, String> {
    Ok(AutostartStatus {
        available: false,
        enabled: false,
        status: "unavailable".into(),
        message: "当前平台暂不支持开机自启。".into(),
    })
}

#[cfg(any(target_os = "macos", windows, target_os = "linux"))]
fn set_autostart_enabled_impl(
    app: &tauri::AppHandle,
    enabled: bool,
) -> Result<AutostartStatus, String> {
    if enabled {
        app.autolaunch().enable().map_err(|error| error.to_string())?;
    } else {
        app.autolaunch().disable().map_err(|error| error.to_string())?;
    }
    read_autostart_status_impl(app)
}

#[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
fn set_autostart_enabled_impl(
    _app: &tauri::AppHandle,
    _enabled: bool,
) -> Result<AutostartStatus, String> {
    Err("当前平台暂不支持开机自启。".into())
}
