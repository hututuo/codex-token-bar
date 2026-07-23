use std::path::PathBuf;

const APP_DIRECTORY_NAME: &str = "CodexTokenBar";
const TAURI_DIRECTORY_NAME: &str = "CodexTokenBarTauri";
// Keep the established namespace so existing aggregate-cache cleanup and
// migration behavior remain stable across this release.
pub const TAURI_USAGE_CACHE_NAMESPACE: &str = "tauri-usage-cache-2026-07-v6";
const HISTORY_REPAIR_DIRECTORY_NAME: &str = "CodexHistoryRepair";

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn settings_path() -> Option<PathBuf> {
    app_support_dir().map(|path| path.join("settings.json"))
}

pub fn quota_history_database_path() -> Option<PathBuf> {
    tauri_app_support_dir().map(|path| path.join("quota-history.sqlite"))
}

pub fn startup_trace_log_path() -> Option<PathBuf> {
    tauri_app_support_dir().map(|path| path.join("startup-trace.log"))
}

pub fn performance_trace_log_path() -> Option<PathBuf> {
    tauri_app_support_dir().map(|path| path.join("performance-trace.log"))
}

pub fn unread_acknowledgement_path() -> Option<PathBuf> {
    tauri_app_support_dir().map(|path| path.join("unread-acknowledgement.json"))
}

pub fn auto_resume_state_path() -> Option<PathBuf> {
    tauri_app_support_dir().map(|path| path.join("auto-resume-state.json"))
}

pub fn token_aggregate_cache_path() -> Option<PathBuf> {
    #[cfg(test)]
    {
        std::env::var_os("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH").map(PathBuf::from)
    }

    #[cfg(not(test))]
    {
        tauri_usage_cache_dir().map(|path| path.join("dashboard-aggregate.json"))
    }
}

pub fn tauri_usage_cache_namespace() -> &'static str {
    TAURI_USAGE_CACHE_NAMESPACE
}

pub fn tauri_cache_state_path() -> Option<PathBuf> {
    tauri_app_support_dir().map(|path| path.join("cache-state.json"))
}

pub(crate) fn legacy_shared_quota_history_database_path() -> Option<PathBuf> {
    app_support_dir().map(|path| path.join("quota-history.sqlite"))
}

pub fn tauri_usage_cache_dir() -> Option<PathBuf> {
    #[cfg(test)]
    {
        if let Some(path) = std::env::var_os("CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR") {
            return Some(PathBuf::from(path));
        }
    }

    tauri_app_cache_dir().map(|path| path.join(TAURI_USAGE_CACHE_NAMESPACE))
}

pub fn discardable_usage_cache_cleanup_targets() -> Vec<PathBuf> {
    let mut targets = Vec::new();

    if let Some(shared_cache) = app_cache_dir() {
        targets.push(shared_cache.join("token-events-cache-v2.json"));
        targets.push(shared_cache.join("token-events-cache-v3"));
        targets.push(shared_cache.join("token-aggregate-cache-v1.json"));
        targets.push(shared_cache.join("session-token-events-v2"));
        targets.push(shared_cache.join("session-token-events-v3"));
        targets.push(shared_cache.join("session-token-events-v4"));
        targets.push(shared_cache.join("session-token-events-v5"));
        targets.push(shared_cache.join("session-token-events-v6"));
        targets.push(shared_cache.join("usage-snapshot-cache-v1.json"));
    }

    if let Some(tauri_cache_root) = tauri_app_cache_dir() {
        if let Ok(entries) = std::fs::read_dir(&tauri_cache_root) {
            for entry in entries.flatten() {
                let path = entry.path();
                let is_current_namespace = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name == TAURI_USAGE_CACHE_NAMESPACE);
                if !is_current_namespace {
                    targets.push(path);
                }
            }
        }
    }

    targets
}

pub fn provider_repair_backup_root() -> Result<PathBuf, String> {
    app_support_base_dir()
        .map(|path| path.join(HISTORY_REPAIR_DIRECTORY_NAME).join("backups"))
        .ok_or_else(|| "无法定位系统应用支持目录，不能创建会话修复备份".into())
}

fn app_support_dir() -> Option<PathBuf> {
    app_support_base_dir().map(|path| path.join(APP_DIRECTORY_NAME))
}

fn app_cache_dir() -> Option<PathBuf> {
    app_cache_base_dir().map(|path| path.join(APP_DIRECTORY_NAME))
}

fn tauri_app_support_dir() -> Option<PathBuf> {
    #[cfg(test)]
    {
        if let Some(path) = std::env::var_os("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR") {
            return Some(PathBuf::from(path));
        }
    }

    app_support_base_dir().map(|path| path.join(TAURI_DIRECTORY_NAME))
}

fn tauri_app_cache_dir() -> Option<PathBuf> {
    #[cfg(test)]
    {
        if let Some(path) = std::env::var_os("CODEX_TOKEN_BAR_TAURI_CACHE_DIR") {
            return Some(PathBuf::from(path));
        }
    }

    app_cache_base_dir().map(|path| path.join(TAURI_DIRECTORY_NAME))
}

fn app_support_base_dir() -> Option<PathBuf> {
    #[cfg(test)]
    {
        if let Some(path) = std::env::var_os("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR") {
            return Some(PathBuf::from(path));
        }
    }

    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("USERPROFILE")
                    .map(|home| PathBuf::from(home).join("AppData").join("Roaming"))
            })
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library").join("Application Support"))
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(|home| PathBuf::from(home).join(".local").join("share"))
            })
    }
}

fn app_cache_base_dir() -> Option<PathBuf> {
    #[cfg(test)]
    {
        if let Some(path) = std::env::var_os("CODEX_TOKEN_BAR_CACHE_BASE_DIR") {
            return Some(PathBuf::from(path));
        }
    }

    if cfg!(target_os = "windows") {
        std::env::var_os("LOCALAPPDATA")
            .or_else(|| std::env::var_os("APPDATA"))
            .map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library").join("Caches"))
    } else {
        std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache"))
            })
    }
}
#[cfg(test)]
static APP_PATH_TEST_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
pub(crate) struct AppPathTestEnvGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
    originals: Vec<(&'static str, Option<std::ffi::OsString>)>,
}

#[cfg(test)]
pub(crate) fn app_path_test_env_guard(
    overrides: &[(&'static str, PathBuf)],
) -> AppPathTestEnvGuard {
    let lock = APP_PATH_TEST_ENV_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let originals = overrides
        .iter()
        .map(|(key, _)| (*key, std::env::var_os(key)))
        .collect::<Vec<_>>();
    for (key, value) in overrides {
        std::env::set_var(key, value);
    }
    AppPathTestEnvGuard { _lock: lock, originals }
}

#[cfg(test)]
pub(crate) fn app_path_test_env_lock_is_held() -> bool {
    matches!(APP_PATH_TEST_ENV_LOCK.try_lock(), Err(std::sync::TryLockError::WouldBlock))
}

#[cfg(test)]
impl Drop for AppPathTestEnvGuard {
    fn drop(&mut self) {
        for (key, value) in &self.originals {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
    }
}
