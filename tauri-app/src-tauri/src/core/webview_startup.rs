#![cfg_attr(not(target_os = "windows"), allow(dead_code))]

use super::{app_paths, atomic_file};
use std::{
    fs,
    path::{Path, PathBuf},
};

const PREFERRED_FILE: &str = "preferred-profile";
const INCOMPLETE_FILE: &str = "incomplete-profile";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WebviewProfile {
    Default,
    RecoveryA,
    RecoveryB,
}

impl WebviewProfile {
    fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "default" => Some(Self::Default),
            "recovery-a" => Some(Self::RecoveryA),
            "recovery-b" => Some(Self::RecoveryB),
            _ => None,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::RecoveryA => "recovery-a",
            Self::RecoveryB => "recovery-b",
        }
    }

    fn recovery_directory(self, root: &Path) -> Option<PathBuf> {
        match self {
            Self::Default => None,
            Self::RecoveryA => Some(root.join("profile-a")),
            Self::RecoveryB => Some(root.join("profile-b")),
        }
    }
}

fn next_profile_after_incomplete(profile: WebviewProfile) -> WebviewProfile {
    match profile {
        WebviewProfile::Default => WebviewProfile::RecoveryA,
        WebviewProfile::RecoveryA => WebviewProfile::RecoveryB,
        WebviewProfile::RecoveryB => WebviewProfile::RecoveryA,
    }
}

pub(crate) struct WebviewStartupAttempt {
    root: PathBuf,
    profile: WebviewProfile,
}

impl WebviewStartupAttempt {
    pub(crate) fn data_directory(&self) -> Option<PathBuf> {
        self.profile.recovery_directory(&self.root)
    }

    pub(crate) fn profile_label(&self) -> &'static str {
        self.profile.label()
    }
}

pub(crate) fn begin() -> Result<WebviewStartupAttempt, String> {
    let root = app_paths::webview_startup_recovery_dir()
        .ok_or_else(|| "无法定位 WebView 启动恢复目录".to_string())?;
    fs::create_dir_all(&root)
        .map_err(|error| format!("无法创建 WebView 启动恢复目录 {}：{error}", root.display()))?;
    let preferred = read_profile(&root.join(PREFERRED_FILE)).unwrap_or(WebviewProfile::Default);
    let profile = read_profile(&root.join(INCOMPLETE_FILE))
        .map(next_profile_after_incomplete)
        .unwrap_or(preferred);
    atomic_file::write_atomically(&root.join(INCOMPLETE_FILE), profile.label().as_bytes())
        .map_err(|error| format!("无法记录 WebView 启动哨兵：{error}"))?;
    Ok(WebviewStartupAttempt { root, profile })
}

pub(crate) fn complete(attempt: &WebviewStartupAttempt) -> Result<(), String> {
    atomic_file::write_atomically(
        &attempt.root.join(PREFERRED_FILE),
        attempt.profile.label().as_bytes(),
    )
    .map_err(|error| format!("无法保存 WebView 恢复配置：{error}"))?;
    match fs::remove_file(attempt.root.join(INCOMPLETE_FILE)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法清除 WebView 启动哨兵：{error}")),
    }
}

fn read_profile(path: &Path) -> Option<WebviewProfile> {
    fs::read_to_string(path)
        .ok()
        .and_then(|value| WebviewProfile::parse(&value))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn incomplete_profiles_rotate_between_two_recovery_slots() {
        assert_eq!(
            next_profile_after_incomplete(WebviewProfile::Default),
            WebviewProfile::RecoveryA
        );
        assert_eq!(
            next_profile_after_incomplete(WebviewProfile::RecoveryA),
            WebviewProfile::RecoveryB
        );
        assert_eq!(
            next_profile_after_incomplete(WebviewProfile::RecoveryB),
            WebviewProfile::RecoveryA
        );
    }

    #[test]
    fn only_recovery_profiles_override_tauris_default_data_directory() {
        let root = Path::new("/tmp/webview-startup");
        assert_eq!(WebviewProfile::Default.recovery_directory(root), None);
        assert_eq!(
            WebviewProfile::RecoveryA.recovery_directory(root),
            Some(root.join("profile-a"))
        );
        assert_eq!(
            WebviewProfile::RecoveryB.recovery_directory(root),
            Some(root.join("profile-b"))
        );
    }

    #[test]
    fn unfinished_default_profile_recovers_without_deleting_the_original() {
        let cache = std::env::temp_dir().join(format!(
            "codex-token-bar-webview-recovery-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _environment = app_paths::app_path_test_env_guard(&[(
            "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
            cache.clone(),
        )]);

        let interrupted = begin().unwrap();
        assert_eq!(interrupted.profile, WebviewProfile::Default);
        assert_eq!(interrupted.data_directory(), None);

        let recovered = begin().unwrap();
        assert_eq!(recovered.profile, WebviewProfile::RecoveryA);
        assert_eq!(
            recovered.data_directory(),
            Some(cache.join("webview-startup-recovery").join("profile-a"))
        );
        complete(&recovered).unwrap();

        let next = begin().unwrap();
        assert_eq!(next.profile, WebviewProfile::RecoveryA);
        complete(&next).unwrap();

        fs::remove_dir_all(cache).unwrap();
    }
}
