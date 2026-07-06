use crate::models::{AutostartStatus, CodexHomeStatus};
use std::path::{Path, PathBuf};
#[cfg(any(target_os = "macos", windows, target_os = "linux"))]
use tauri_plugin_autostart::ManagerExt;

const CODEX_HOME_FILE_MARKERS: &[&str] = &[
    "auth.json",
    "state_5.sqlite",
    "config.toml",
    "logs_2.sqlite",
    ".codex-global-state.json",
];
const CODEX_HOME_DIRECTORY_MARKERS: &[&str] = &["sessions", "archived_sessions"];
const CODEX_HOME_MARKERS: &[&str] = &[
    "auth.json",
    "state_5.sqlite",
    "sessions",
    "archived_sessions",
    "config.toml",
    "logs_2.sqlite",
    ".codex-global-state.json",
];

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
    let path = validate_codex_home(path)?;
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

fn validate_codex_home(path: &str) -> Result<PathBuf, String> {
    if path.trim().is_empty() {
        return Err("Codex Home 不能为空。".into());
    }

    let normalized = settings::normalize_user_path(path);
    let canonical = std::fs::canonicalize(&normalized).map_err(|error| {
        format!(
            "Codex Home 必须是已存在的目录：{}（{}）",
            normalized.display(),
            error
        )
    })?;

    if !canonical.is_dir() {
        return Err(format!(
            "Codex Home 必须是已存在的目录：{}",
            canonical.display()
        ));
    }

    if !has_codex_home_marker(&canonical) {
        return Err(format!(
            "所选目录不像 Codex Home：未找到 {} 中任一标记。",
            codex_home_marker_names().join("、")
        ));
    }

    Ok(canonical)
}

fn has_codex_home_marker(path: &Path) -> bool {
    CODEX_HOME_FILE_MARKERS
        .iter()
        .any(|marker| path.join(marker).is_file())
        || CODEX_HOME_DIRECTORY_MARKERS
            .iter()
            .any(|marker| path.join(marker).is_dir())
}

fn codex_home_marker_names() -> &'static [&'static str] {
    CODEX_HOME_MARKERS
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        path::{Path, PathBuf},
        sync::{Mutex, MutexGuard},
        time::{SystemTime, UNIX_EPOCH},
    };

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn save_codex_home_rejects_blank_path() {
        let _guard = lock_env();
        let _support = ScopedEnv::set(
            "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR",
            unique_temp_path("support"),
        );

        let error = save_codex_home("   ").unwrap_err();

        assert!(error.contains("不能为空"));
    }

    #[test]
    fn save_codex_home_rejects_file_path() {
        let _guard = lock_env();
        let support = unique_temp_path("support");
        let _support = ScopedEnv::set("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", &support);
        let root = unique_temp_path("file-path");
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("state_5.sqlite");
        std::fs::write(&file, b"not a directory").unwrap();

        let error = save_codex_home(file.to_str().unwrap()).unwrap_err();

        assert!(error.contains("已存在的目录"));
    }

    #[test]
    fn save_codex_home_rejects_unmarked_directory() {
        let _guard = lock_env();
        let support = unique_temp_path("support");
        let _support = ScopedEnv::set("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", &support);
        let codex_home = unique_temp_path("unmarked-codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();

        let error = save_codex_home(codex_home.to_str().unwrap()).unwrap_err();

        assert!(error.contains("不像 Codex Home"));
    }

    #[test]
    fn save_codex_home_accepts_sessions_marker_and_stores_canonical_path() {
        let _guard = lock_env();
        let support = unique_temp_path("support");
        let _support = ScopedEnv::set("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", &support);
        let codex_home = unique_temp_path("sessions-codex-home");
        std::fs::create_dir_all(codex_home.join("sessions")).unwrap();

        let status = save_codex_home(codex_home.to_str().unwrap()).unwrap();
        let expected = std::fs::canonicalize(&codex_home).unwrap();
        let settings = settings::read_app_settings().unwrap();

        assert!(status.exists);
        assert_eq!(status.path, expected.display().to_string());
        assert_eq!(settings.codex_home.as_deref(), Some(status.path.as_str()));
    }

    #[test]
    fn save_codex_home_accepts_state_database_marker() {
        let _guard = lock_env();
        let support = unique_temp_path("support");
        let _support = ScopedEnv::set("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", &support);
        let codex_home = unique_temp_path("state-codex-home");
        std::fs::create_dir_all(&codex_home).unwrap();
        std::fs::write(codex_home.join("state_5.sqlite"), b"").unwrap();

        let status = save_codex_home(codex_home.to_str().unwrap()).unwrap();

        assert_eq!(
            status.path,
            std::fs::canonicalize(&codex_home).unwrap().display().to_string()
        );
        assert_eq!(status.source, "manual");
    }

    #[test]
    fn save_codex_home_expands_tilde_and_stores_canonical_path() {
        let _guard = lock_env();
        let support = unique_temp_path("support");
        let home = unique_temp_path("home");
        let _support = ScopedEnv::set("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", &support);
        let _home = ScopedEnv::set("HOME", &home);
        let codex_home = home.join("custom-codex");
        std::fs::create_dir_all(&codex_home).unwrap();
        std::fs::write(codex_home.join("state_5.sqlite"), b"").unwrap();

        let status = save_codex_home("~/custom-codex").unwrap();

        assert_eq!(
            status.path,
            std::fs::canonicalize(&codex_home).unwrap().display().to_string()
        );
    }

    struct ScopedEnv {
        key: &'static str,
        previous: Option<std::ffi::OsString>,
    }

    impl ScopedEnv {
        fn set(key: &'static str, value: impl AsRef<Path>) -> Self {
            let previous = std::env::var_os(key);
            std::env::set_var(key, value.as_ref());
            Self { key, previous }
        }
    }

    impl Drop for ScopedEnv {
        fn drop(&mut self) {
            match &self.previous {
                Some(value) => std::env::set_var(self.key, value),
                None => std::env::remove_var(self.key),
            }
        }
    }

    fn unique_temp_path(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "codex-token-bar-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    fn lock_env() -> MutexGuard<'static, ()> {
        ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}
