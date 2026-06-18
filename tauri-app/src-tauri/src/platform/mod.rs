use crate::models::{
    AppSettingsSnapshot, CodexHomeStatus, DisplaySurfaceSettingsSnapshot,
    FloatingWindowPositionSnapshot, FloatingWindowSettingsSnapshot,
};
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
    let mut settings = read_app_settings();
    settings.codex_home = Some(path.display().to_string());
    write_app_settings(&settings)?;
    Ok(CodexHomeStatus {
        exists: path.exists(),
        path: path.display().to_string(),
        source: "manual".into(),
    })
}

pub fn reset_codex_home() -> Result<CodexHomeStatus, String> {
    let mut settings = read_app_settings();
    settings.codex_home = None;
    write_app_settings(&settings)?;
    Ok(default_codex_home_status())
}

pub fn read_app_settings() -> AppSettingsSnapshot {
    sanitize_app_settings(read_settings_file())
}

pub fn save_floating_settings(
    floating_window: FloatingWindowSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    let mut settings = read_app_settings();
    settings.floating_window = sanitize_floating_settings(floating_window);
    write_app_settings(&settings)?;
    Ok(settings)
}

pub fn save_floating_position(
    floating_position: FloatingWindowPositionSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    let mut settings = read_app_settings();
    settings.floating_position = sanitize_floating_position(Some(floating_position));
    write_app_settings(&settings)?;
    Ok(settings)
}

pub fn save_display_surfaces(
    display_surfaces: DisplaySurfaceSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    let mut settings = read_app_settings();
    settings.display_surfaces = display_surfaces;
    write_app_settings(&settings)?;
    Ok(settings)
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
    read_app_settings().codex_home.as_deref().map(normalize_user_path)
}

fn read_settings_file() -> AppSettingsSnapshot {
    std::fs::read(settings_path())
        .ok()
        .and_then(|bytes| serde_json::from_slice::<AppSettingsSnapshot>(&bytes).ok())
        .unwrap_or_default()
}

fn write_app_settings(settings: &AppSettingsSnapshot) -> Result<(), String> {
    let settings_path = settings_path();
    if let Some(parent) = settings_path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let sanitized = sanitize_app_settings(settings.clone());
    let bytes = serde_json::to_vec_pretty(&sanitized).map_err(|error| error.to_string())?;
    std::fs::write(settings_path, bytes).map_err(|error| error.to_string())
}

fn sanitize_app_settings(mut settings: AppSettingsSnapshot) -> AppSettingsSnapshot {
    settings.codex_home = settings.codex_home.and_then(|path| {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.into())
        }
    });
    settings.floating_window = sanitize_floating_settings(settings.floating_window);
    settings.floating_position = sanitize_floating_position(settings.floating_position);
    settings
}

fn sanitize_floating_settings(
    settings: FloatingWindowSettingsSnapshot,
) -> FloatingWindowSettingsSnapshot {
    FloatingWindowSettingsSnapshot {
        opacity: clamp_f64(settings.opacity, 0.4, 1.0, 0.92),
        scale: clamp_f64(settings.scale, 0.9, 1.38, 1.0),
    }
}

fn clamp_f64(value: f64, minimum: f64, maximum: f64, fallback: f64) -> f64 {
    if !value.is_finite() {
        return fallback;
    }

    value.clamp(minimum, maximum)
}

fn sanitize_floating_position(
    position: Option<FloatingWindowPositionSnapshot>,
) -> Option<FloatingWindowPositionSnapshot> {
    let position = position?;
    if !is_valid_coordinate(position.x) || !is_valid_coordinate(position.y) {
        return None;
    }

    Some(FloatingWindowPositionSnapshot {
        x: position.x,
        y: position.y,
        saved_at: position.saved_at.filter(|value| *value > 0),
    })
}

fn is_valid_coordinate(value: f64) -> bool {
    value.is_finite() && value.abs() <= 20_000.0
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_keep_legacy_codex_home_and_sanitize_floating_values() {
        let raw = r#"{
            "codex_home": "~/custom-codex",
            "floatingWindow": {
                "opacity": 1.4,
                "scale": 0.2
            }
        }"#;

        let settings: AppSettingsSnapshot = serde_json::from_str(raw).unwrap();
        let sanitized = sanitize_app_settings(settings);

        assert_eq!(sanitized.codex_home.as_deref(), Some("~/custom-codex"));
        assert_eq!(sanitized.floating_window.opacity, 1.0);
        assert_eq!(sanitized.floating_window.scale, 0.9);
        assert!(sanitized.display_surfaces.floating_window_enabled);
        assert!(sanitized.display_surfaces.status_tray_live_text_enabled);
    }

    #[test]
    fn settings_drop_unreasonable_floating_position() {
        let settings = AppSettingsSnapshot {
            floating_position: Some(FloatingWindowPositionSnapshot {
                x: 20_001.0,
                y: 24.0,
                saved_at: Some(1),
            }),
            ..AppSettingsSnapshot::default()
        };

        assert!(sanitize_app_settings(settings).floating_position.is_none());
    }

    #[test]
    fn settings_accept_partial_nested_objects() {
        let raw = r#"{
            "floatingWindow": {
                "opacity": 0.7
            },
            "displaySurfaces": {
                "floatingWindowEnabled": false
            }
        }"#;

        let settings: AppSettingsSnapshot = serde_json::from_str(raw).unwrap();

        assert_eq!(settings.floating_window.opacity, 0.7);
        assert_eq!(settings.floating_window.scale, 1.0);
        assert!(!settings.display_surfaces.floating_window_enabled);
        assert!(settings.display_surfaces.status_tray_live_text_enabled);
    }
}
