use crate::models::CodexHomeStatus;
use serde_json::{json, Value};
use std::path::PathBuf;
use tauri::{
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, WebviewUrl, WebviewWindowBuilder,
};

mod capabilities;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;

pub use capabilities::platform_capabilities;

#[cfg(target_os = "macos")]
use macos::default_codex_home as automatic_codex_home;
#[cfg(target_os = "windows")]
use windows::default_codex_home as automatic_codex_home;

const FLOATING_WINDOW_WIDTH: f64 = 296.0;
const FLOATING_WINDOW_HEIGHT: f64 = 112.0;
const FLOATING_WINDOW_MIN_SCALE: f64 = 0.9;
const FLOATING_WINDOW_MAX_SCALE: f64 = 1.38;
const STATUS_TRAY_ID: &str = "codex-token-bar-status";

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn automatic_codex_home() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(".codex")
}

pub fn default_codex_home() -> PathBuf {
    saved_codex_home().unwrap_or_else(automatic_codex_home)
}

pub fn default_codex_home_status() -> CodexHomeStatus {
    let path = default_codex_home();
    CodexHomeStatus {
        exists: path.exists(),
        path: path.display().to_string(),
        source: if saved_codex_home().is_some() { "manual" } else { "auto" }.into(),
    }
}

pub fn save_codex_home(path: &str) -> Result<CodexHomeStatus, String> {
    let path = normalize_user_path(path);
    let settings = json!({
        "codex_home": path.display().to_string()
    });
    let settings_path = settings_path();
    if let Some(parent) = settings_path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let bytes = serde_json::to_vec_pretty(&settings).map_err(|error| error.to_string())?;
    std::fs::write(settings_path, bytes).map_err(|error| error.to_string())?;
    Ok(CodexHomeStatus {
        exists: path.exists(),
        path: path.display().to_string(),
        source: "manual".into(),
    })
}

pub fn reset_codex_home() -> Result<CodexHomeStatus, String> {
    let path = settings_path();
    if path.exists() {
        std::fs::remove_file(path).map_err(|error| error.to_string())?;
    }
    Ok(default_codex_home_status())
}

pub fn setup_desktop_surfaces(app: &tauri::App) -> tauri::Result<()> {
    create_floating_window(app)?;
    create_status_tray(app)?;
    Ok(())
}

pub fn show_floating_window(app: &tauri::AppHandle) -> Result<bool, String> {
    let window = app
        .get_webview_window("floating")
        .ok_or_else(|| "floating window is not available".to_string())?;
    window.show().map_err(|error| error.to_string())?;
    window
        .set_always_on_top(true)
        .map_err(|error| error.to_string())?;
    Ok(true)
}

pub fn hide_floating_window(app: &tauri::AppHandle) -> Result<bool, String> {
    let window = app
        .get_webview_window("floating")
        .ok_or_else(|| "floating window is not available".to_string())?;
    window.hide().map_err(|error| error.to_string())?;
    Ok(false)
}

pub fn set_status_tray_readout(
    app: &tauri::AppHandle,
    title: String,
    tooltip: String,
) -> Result<bool, String> {
    let Some(tray) = app.tray_by_id(STATUS_TRAY_ID) else {
        return Ok(false);
    };

    tray.set_title(Some(title))
        .map_err(|error| error.to_string())?;
    tray.set_tooltip(Some(tooltip))
        .map_err(|error| error.to_string())?;
    Ok(true)
}

fn create_status_tray(app: &tauri::App) -> tauri::Result<()> {
    if app.tray_by_id(STATUS_TRAY_ID).is_some() {
        return Ok(());
    }

    TrayIconBuilder::with_id(STATUS_TRAY_ID)
        .title("0.0/s")
        .tooltip("Codex Token Bar")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if let Some(window) = tray.app_handle().get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        })
        .build(app)?;

    Ok(())
}

fn create_floating_window(app: &tauri::App) -> tauri::Result<()> {
    if app.get_webview_window("floating").is_some() {
        return Ok(());
    }

    WebviewWindowBuilder::new(app, "floating", WebviewUrl::App("index.html?surface=floating".into()))
        .title("Codex Token Bar Floating")
        .inner_size(FLOATING_WINDOW_WIDTH, FLOATING_WINDOW_HEIGHT)
        .min_inner_size(
            FLOATING_WINDOW_WIDTH * FLOATING_WINDOW_MIN_SCALE,
            FLOATING_WINDOW_HEIGHT * FLOATING_WINDOW_MIN_SCALE,
        )
        .max_inner_size(
            FLOATING_WINDOW_WIDTH * FLOATING_WINDOW_MAX_SCALE,
            FLOATING_WINDOW_HEIGHT * FLOATING_WINDOW_MAX_SCALE,
        )
        .position(48.0, 86.0)
        .decorations(false)
        .resizable(false)
        .focused(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .shadow(false)
        .transparent(true)
        .build()?;

    Ok(())
}

fn saved_codex_home() -> Option<PathBuf> {
    let value: Value = serde_json::from_slice(&std::fs::read(settings_path()).ok()?).ok()?;
    value
        .get("codex_home")
        .and_then(Value::as_str)
        .map(normalize_user_path)
}

fn normalize_user_path(path: &str) -> PathBuf {
    let trimmed = path.trim();
    if trimmed == "~" {
        return home_dir();
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        return home_dir().join(rest);
    }
    PathBuf::from(trimmed)
}

fn settings_path() -> PathBuf {
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(home_dir)
            .join("CodexTokenBar")
            .join("settings.json")
    } else {
        home_dir()
            .join("Library")
            .join("Application Support")
            .join("CodexTokenBar")
            .join("settings.json")
    }
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}
