use std::path::PathBuf;

const APP_DIRECTORY_NAME: &str = "CodexTokenBar";
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
    app_support_dir().map(|path| path.join("quota-history.sqlite"))
}

pub fn startup_trace_log_path() -> Option<PathBuf> {
    app_support_dir().map(|path| path.join("startup-trace.log"))
}

pub fn performance_trace_log_path() -> Option<PathBuf> {
    app_support_dir().map(|path| path.join("performance-trace.log"))
}

pub fn token_event_cache_path() -> Option<PathBuf> {
    #[cfg(test)]
    {
        None
    }

    #[cfg(not(test))]
    {
        app_cache_dir().map(|path| path.join("token-events-cache-v2.json"))
    }
}

pub fn token_aggregate_cache_path() -> Option<PathBuf> {
    #[cfg(test)]
    {
        std::env::var_os("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH").map(PathBuf::from)
    }

    #[cfg(not(test))]
    {
        app_cache_dir().map(|path| path.join("token-aggregate-cache-v1.json"))
    }
}

pub fn provider_repair_backup_root() -> Result<PathBuf, String> {
    app_support_base_dir()
        .map(|path| path.join(HISTORY_REPAIR_DIRECTORY_NAME).join("backups"))
        .ok_or_else(|| "无法定位系统应用支持目录，不能创建会话修复备份".into())
}

fn app_support_dir() -> Option<PathBuf> {
    app_support_base_dir().map(|path| path.join(APP_DIRECTORY_NAME))
}

#[cfg(not(test))]
fn app_cache_dir() -> Option<PathBuf> {
    app_cache_base_dir().map(|path| path.join(APP_DIRECTORY_NAME))
}

fn app_support_base_dir() -> Option<PathBuf> {
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

#[cfg(not(test))]
fn app_cache_base_dir() -> Option<PathBuf> {
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
