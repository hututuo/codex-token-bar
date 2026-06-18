use crate::models::CodexHomeStatus;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "macos")]
pub use macos::default_codex_home;
#[cfg(target_os = "windows")]
pub use windows::default_codex_home;

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn default_codex_home() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(".codex")
}

pub fn default_codex_home_status() -> CodexHomeStatus {
    let path = default_codex_home();
    CodexHomeStatus {
        exists: path.exists(),
        path: path.display().to_string(),
        source: "auto".into(),
    }
}
