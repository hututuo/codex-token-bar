use crate::models::CodexHomeStatus;
use serde_json::{json, Value};
use std::path::PathBuf;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;

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
