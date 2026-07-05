use crate::core::app_paths;
use serde::{Deserialize, Serialize};
use std::fs;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageCacheStatus {
    pub namespace: String,
    pub initialized: bool,
    pub initialized_at: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct UsageCacheStateFile {
    usage_cache_namespace: String,
    initialized_at: String,
}

pub fn usage_cache_status() -> UsageCacheStatus {
    let namespace = app_paths::tauri_usage_cache_namespace().to_string();
    let initialized_at = app_paths::tauri_cache_state_path()
        .and_then(|path| fs::read(path).ok())
        .and_then(|data| serde_json::from_slice::<UsageCacheStateFile>(&data).ok())
        .and_then(|state| {
            (state.usage_cache_namespace == namespace).then_some(state.initialized_at)
        });

    UsageCacheStatus {
        namespace,
        initialized: initialized_at.is_some(),
        initialized_at,
    }
}

pub fn mark_usage_cache_initialized() -> Result<(), String> {
    let Some(path) = app_paths::tauri_cache_state_path() else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!("创建 Tauri 统计缓存状态目录失败：{}（{}）", parent.display(), error)
        })?;
    }

    let initialized_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    let payload = UsageCacheStateFile {
        usage_cache_namespace: app_paths::tauri_usage_cache_namespace().to_string(),
        initialized_at,
    };
    let data = serde_json::to_vec(&payload)
        .map_err(|error| format!("序列化 Tauri 统计缓存状态失败：{error}"))?;
    let temp_path = path.with_extension("json.tmp");
    fs::write(&temp_path, data).map_err(|error| {
        format!("写入 Tauri 统计缓存状态失败：{}（{}）", temp_path.display(), error)
    })?;
    fs::rename(&temp_path, &path).map_err(|error| {
        format!("替换 Tauri 统计缓存状态失败：{}（{}）", path.display(), error)
    })
}

pub fn mark_usage_cache_ready_after_success() {
    let _ = mark_usage_cache_initialized();
    cleanup_old_discardable_usage_caches_async();
}

pub fn cleanup_old_discardable_usage_caches_async() {
    let targets = app_paths::discardable_usage_cache_cleanup_targets();
    if targets.is_empty() {
        return;
    }

    #[cfg(test)]
    {
        cleanup_old_discardable_usage_caches_now();
    }

    #[cfg(not(test))]
    {
        let _ = std::thread::Builder::new()
            .name("codex-token-bar-cache-cleanup".into())
            .spawn(move || {
                for target in targets {
                    remove_cache_path(&target);
                }
            });
    }
}

#[cfg(test)]
pub fn cleanup_old_discardable_usage_caches_now() {
    for target in app_paths::discardable_usage_cache_cleanup_targets() {
        remove_cache_path(&target);
    }
}

fn remove_cache_path(path: &std::path::Path) {
    if path.is_dir() {
        let _ = fs::remove_dir_all(path);
    } else {
        let _ = fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn marker_missing_then_marked_ready() {
        let root = temp_root("marker");
        let _env = PathEnvGuard::new(&root);

        let missing = usage_cache_status();
        assert_eq!(missing.namespace, "tauri-usage-cache-2026-07-v5");
        assert!(!missing.initialized);
        assert_eq!(missing.initialized_at, None);

        mark_usage_cache_initialized().unwrap();
        let ready = usage_cache_status();
        assert!(ready.initialized);
        assert!(ready.initialized_at.is_some());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn marker_namespace_mismatch_is_not_initialized() {
        let root = temp_root("marker-mismatch");
        let _env = PathEnvGuard::new(&root);
        let marker_path = app_paths::tauri_cache_state_path().unwrap();
        fs::create_dir_all(marker_path.parent().unwrap()).unwrap();
        fs::write(
            marker_path,
            r#"{"usageCacheNamespace":"tauri-usage-cache-2026-06-v1","initializedAt":"2026-06-01T00:00:00Z"}"#,
        )
        .unwrap();

        let status = usage_cache_status();
        assert!(!status.initialized);
        assert_eq!(status.initialized_at, None);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cleanup_removes_old_discardable_caches_without_touching_current_or_quota_history() {
        let root = temp_root("cleanup");
        let _env = PathEnvGuard::new(&root);
        let cache_base = root.join("cache");
        let support_base = root.join("support");
        let old_shared = cache_base.join("CodexTokenBar").join("token-events-cache-v3");
        let old_tauri = cache_base.join("CodexTokenBarTauri").join("tauri-usage-cache-2026-06-v1");
        let current = app_paths::tauri_usage_cache_dir().unwrap();
        let quota = support_base.join("CodexTokenBar").join("quota-history.sqlite");

        fs::create_dir_all(&old_shared).unwrap();
        fs::create_dir_all(&old_tauri).unwrap();
        fs::create_dir_all(&current).unwrap();
        fs::create_dir_all(quota.parent().unwrap()).unwrap();
        fs::write(&quota, b"quota").unwrap();

        cleanup_old_discardable_usage_caches_now();

        assert!(!old_shared.exists());
        assert!(!old_tauri.exists());
        assert!(current.exists());
        assert!(quota.exists());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn quota_history_stays_in_original_app_support_directory() {
        let root = temp_root("quota-path");
        let _env = PathEnvGuard::new(&root);

        let path = app_paths::quota_history_database_path().unwrap();
        assert!(path.ends_with("CodexTokenBar/quota-history.sqlite"));
        assert!(!path.to_string_lossy().contains("CodexTokenBarTauri"));

        let _ = fs::remove_dir_all(root);
    }

    fn temp_root(label: &str) -> PathBuf {
        let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "codex-token-bar-cache-lifecycle-{label}-{}-{}-{}",
            std::process::id(),
            sequence,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    struct PathEnvGuard {
        keys: [&'static str; 4],
    }

    impl PathEnvGuard {
        fn new(root: &Path) -> Self {
            let pairs = [
                ("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", root.join("support")),
                ("CODEX_TOKEN_BAR_CACHE_BASE_DIR", root.join("cache")),
                (
                    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
                    root.join("support").join("CodexTokenBarTauri"),
                ),
                (
                    "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
                    root.join("cache").join("CodexTokenBarTauri"),
                ),
            ];
            for (key, value) in &pairs {
                std::env::set_var(key, value);
            }
            Self {
                keys: [
                    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR",
                    "CODEX_TOKEN_BAR_CACHE_BASE_DIR",
                    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
                    "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
                ],
            }
        }
    }

    impl Drop for PathEnvGuard {
        fn drop(&mut self) {
            for key in self.keys {
                std::env::remove_var(key);
            }
        }
    }
}
