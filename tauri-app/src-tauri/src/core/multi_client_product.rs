use crate::core::{app_paths, multi_client_usage::ClaudeLocalQuotaSnapshot};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const DETECTION_CACHE_TTL: Duration = Duration::from_secs(60);
const CLIENTS: [&str; 5] = [
    "claudeCode",
    "claudeDesktop",
    "deepseek",
    "gemini",
    "opencode",
];
const QUOTA_CLIENTS: [&str; 5] = [
    "claudeCode",
    "claudeDesktop",
    "deepseek",
    "gemini",
    "opencode",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProductDetection {
    pub client: String,
    pub evidence: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaProviderWindow {
    pub label: String,
    pub used_percent: Option<f64>,
    pub resets_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaProviderSnapshot {
    pub client: String,
    pub state: String,
    pub source: String,
    pub windows: Vec<QuotaProviderWindow>,
    pub notice: String,
}

#[derive(Clone, Debug, Default)]
struct DetectionInputs {
    path_directories: Vec<PathBuf>,
    applications: Vec<(String, PathBuf, String)>,
    data_roots: Vec<(String, PathBuf, String)>,
}

#[derive(Default)]
struct DetectionCache {
    scanned_at: Option<Instant>,
    detections: Vec<ProductDetection>,
}

static DETECTION_CACHE: OnceLock<Mutex<DetectionCache>> = OnceLock::new();

/// Detects only from cheap filesystem metadata checks. It never launches a client, scans its
/// history, reads secrets, changes settings, or contacts a provider.
pub fn detect_clients_cached() -> Vec<ProductDetection> {
    let cache = DETECTION_CACHE.get_or_init(|| Mutex::new(DetectionCache::default()));
    let Ok(mut cache) = cache.lock() else {
        return detect_clients_from(&system_detection_inputs());
    };
    if cache
        .scanned_at
        .is_some_and(|scanned_at| scanned_at.elapsed() < DETECTION_CACHE_TTL)
    {
        return cache.detections.clone();
    }
    let detections = detect_clients_from(&system_detection_inputs());
    cache.scanned_at = Some(Instant::now());
    cache.detections = detections.clone();
    detections
}

/// Projects the local Claude statusline reader into the shared provider shape. Codex is
/// deliberately absent here: its already-loaded snapshot is adapted by the UI layer.
pub fn quota_provider_snapshots(claude: &ClaudeLocalQuotaSnapshot) -> Vec<QuotaProviderSnapshot> {
    let (state, windows, notice) = match claude.state.as_str() {
        "available" => (
            "available",
            vec![
                claude.five_hour.as_ref().map(|window| QuotaProviderWindow {
                    label: "5 小时".into(),
                    used_percent: Some(window.used_percent),
                    resets_at: window.resets_at.clone(),
                }),
                claude.seven_day.as_ref().map(|window| QuotaProviderWindow {
                    label: "7 天".into(),
                    used_percent: Some(window.used_percent),
                    resets_at: window.resets_at.clone(),
                }),
            ]
            .into_iter()
            .flatten()
            .collect(),
            "该额度未绑定到具体账号，只反映最近 Claude 进程的状态栏缓存；缓存超过 10 分钟会过期。",
        ),
        "missing" => (
            "notConnected",
            Vec::new(),
            "可手动配置 Claude 本地 statusLine 命令：Windows 使用 ClaudeLocalReader --capture-statusline，Mac 使用 TokenBarClaudeLocal；也兼容已有 claude-monitor --statusline 缓存。使用 Claude 生成新记录后刷新。此流程不会自动修改你的 Claude 配置。额度未绑定到具体账号，只反映最近 Claude 进程；缓存超过 10 分钟会过期。",
        ),
        "stale" => (
            "unavailable",
            Vec::new(),
            "Claude 状态栏缓存超过 10 分钟，已过期。请使用 Claude 生成新的本地状态栏记录；额度未绑定到具体账号。",
        ),
        _ => (
            "unavailable",
            Vec::new(),
            "Claude 本地状态栏缓存无效或暂不可用。可手动配置本地状态栏命令（Windows：ClaudeLocalReader --capture-statusline；Mac：TokenBarClaudeLocal；兼容已有 claude-monitor --statusline），使用 Claude 生成新记录后刷新。此流程不会自动修改配置；额度未绑定到具体账号，缓存超过 10 分钟会过期。",
        ),
    };

    QUOTA_CLIENTS
        .iter()
        .map(|client| {
            if *client == "claudeCode" {
                QuotaProviderSnapshot {
                    client: (*client).into(),
                    state: state.into(),
                    source: "local-statusline".into(),
                    windows: windows.clone(),
                    notice: notice.into(),
                }
            } else {
                QuotaProviderSnapshot {
                    client: (*client).into(),
                    state: "unavailable".into(),
                    source: "unsupported".into(),
                    windows: Vec::new(),
                    notice: "暂不支持读取此客户端的订阅额度。".into(),
                }
            }
        })
        .collect()
}

fn detect_clients_from(inputs: &DetectionInputs) -> Vec<ProductDetection> {
    let mut evidence: HashMap<String, Vec<String>> = HashMap::new();

    for (client, command) in [
        ("claudeCode", "claude"),
        ("deepseek", "dsh"),
        ("gemini", "gemini"),
        ("opencode", "opencode"),
    ] {
        if inputs
            .path_directories
            .iter()
            .any(|directory| command_is_on_path(directory, command))
        {
            evidence
                .entry(client.into())
                .or_default()
                .push(format!("PATH 中找到可执行命令 {command}"));
        }
    }

    for (client, path, label) in &inputs.applications {
        if path_exists(path) {
            evidence
                .entry(client.clone())
                .or_default()
                .push(label.clone());
        }
    }
    for (client, path, label) in &inputs.data_roots {
        if path_exists(path) {
            evidence
                .entry(client.clone())
                .or_default()
                .push(label.clone());
        }
    }

    CLIENTS
        .iter()
        .filter_map(|client| {
            let mut items = evidence.remove(*client)?;
            items.sort();
            items.dedup();
            Some(ProductDetection {
                client: (*client).into(),
                evidence: items.join("；"),
            })
        })
        .collect()
}

fn system_detection_inputs() -> DetectionInputs {
    let home = app_paths::home_dir();
    let mut inputs = DetectionInputs {
        path_directories: std::env::var_os("PATH")
            .map(|path| std::env::split_paths(&path).collect())
            .unwrap_or_default(),
        ..DetectionInputs::default()
    };

    let claude_root = env_path("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home.join(".claude"));
    inputs.data_roots.push((
        "claudeCode".into(),
        claude_root,
        "存在 Claude Code 本地数据目录".into(),
    ));

    let dsh_root = env_path("DSH_HOME").unwrap_or_else(|| home.join(".dsh"));
    inputs.data_roots.push((
        "deepseek".into(),
        dsh_root,
        "存在 DeepSeek 本地会话目录".into(),
    ));

    let gemini_home = env_path("GEMINI_CLI_HOME").unwrap_or_else(|| home.clone());
    inputs.data_roots.push((
        "gemini".into(),
        gemini_home.join(".gemini").join("tmp"),
        "存在 Gemini CLI 本地会话目录".into(),
    ));
    inputs.data_roots.push((
        "gemini".into(),
        home.join(".cache").join(".gemini").join("tmp"),
        "存在 Gemini CLI 缓存会话目录".into(),
    ));

    let opencode_root = env_path("OPENCODE_DATA_DIR").unwrap_or_else(|| {
        env_path("XDG_DATA_HOME")
            .unwrap_or_else(|| home.join(".local").join("share"))
            .join("opencode")
    });
    inputs.data_roots.push((
        "opencode".into(),
        opencode_root,
        "存在 OpenCode 本地数据目录".into(),
    ));

    #[cfg(target_os = "macos")]
    {
        let application_roots = [PathBuf::from("/Applications"), home.join("Applications")];
        for root in application_roots {
            for (client, app, label) in [
                ("claudeDesktop", "Claude.app", "检测到 Claude Desktop 应用"),
                ("deepseek", "DeepSeek.app", "检测到 DeepSeek 应用"),
                ("gemini", "Gemini.app", "检测到 Gemini 应用"),
                ("opencode", "OpenCode.app", "检测到 OpenCode 应用"),
            ] {
                inputs
                    .applications
                    .push((client.into(), root.join(app), label.into()));
            }
        }
        inputs.data_roots.push((
            "claudeDesktop".into(),
            home.join("Library/Application Support/Claude"),
            "存在 Claude Desktop 本地数据目录".into(),
        ));
    }

    #[cfg(windows)]
    {
        let local_app_data = env_path("LOCALAPPDATA");
        let mut application_roots = Vec::new();
        if let Some(local_app_data) = local_app_data.as_ref() {
            application_roots.push(local_app_data.join("Programs"));
        }
        for key in ["PROGRAMFILES", "PROGRAMFILES(X86)"] {
            if let Some(program_files) = env_path(key) {
                application_roots.push(program_files);
            }
        }
        for root in application_roots {
            for (client, relative, label) in [
                (
                    "claudeDesktop",
                    "Claude/Claude.exe",
                    "检测到 Claude Desktop 应用",
                ),
                ("deepseek", "DeepSeek/DeepSeek.exe", "检测到 DeepSeek 应用"),
                ("gemini", "Gemini/Gemini.exe", "检测到 Gemini 应用"),
                ("opencode", "OpenCode/OpenCode.exe", "检测到 OpenCode 应用"),
            ] {
                inputs
                    .applications
                    .push((client.into(), root.join(relative), label.into()));
            }
        }
        if let Some(app_data) = env_path("APPDATA") {
            inputs.data_roots.push((
                "claudeDesktop".into(),
                app_data.join("Claude"),
                "存在 Claude Desktop 本地数据目录".into(),
            ));
        }
    }

    inputs
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn command_is_on_path(directory: &Path, command: &str) -> bool {
    if is_executable(&directory.join(command)) {
        return true;
    }
    #[cfg(windows)]
    {
        ["exe", "cmd", "bat", "com"]
            .iter()
            .any(|extension| is_executable(&directory.join(format!("{command}.{extension}"))))
    }
    #[cfg(not(windows))]
    {
        false
    }
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(windows)]
    {
        path.extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| {
                ["exe", "cmd", "bat", "com"]
                    .iter()
                    .any(|candidate| extension.eq_ignore_ascii_case(candidate))
            })
    }
    #[cfg(not(any(unix, windows)))]
    {
        true
    }
}

fn path_exists(path: &Path) -> bool {
    fs::metadata(path).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::multi_client_usage::{ClaudeLocalQuotaSnapshot, ClaudeLocalQuotaWindow};
    use std::time::SystemTime;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "codex-tokenbar-product-{label}-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn detection_uses_only_known_roots_bundles_and_path_executables() {
        let temporary = TempDir::new("detect");
        let home = temporary.0.join("home");
        let bin = temporary.0.join("bin");
        let applications = temporary.0.join("Applications");
        let gemini_data = home.join(".gemini/tmp");
        let claude_cli = bin.join("claude");
        fs::create_dir_all(&gemini_data).unwrap();
        fs::create_dir_all(&claude_cli.parent().unwrap()).unwrap();
        fs::write(&claude_cli, "fixture").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&claude_cli, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let claude_app = applications.join("Claude.app");
        fs::create_dir_all(&claude_app).unwrap();

        let inputs = DetectionInputs {
            path_directories: vec![bin],
            applications: vec![(
                "claudeDesktop".into(),
                claude_app,
                "检测到 Claude Desktop 应用".into(),
            )],
            data_roots: vec![(
                "gemini".into(),
                gemini_data,
                "存在 Gemini CLI 本地会话目录".into(),
            )],
        };
        let detections = detect_clients_from(&inputs);
        assert_eq!(
            detections
                .iter()
                .map(|item| item.client.as_str())
                .collect::<Vec<_>>(),
            vec!["claudeCode", "claudeDesktop", "gemini"]
        );
        assert!(detections[0].evidence.contains("PATH"));
        assert!(detections[1].evidence.contains("Claude Desktop"));
        assert!(detections[2].evidence.contains("会话目录"));
    }

    #[test]
    fn quota_projection_is_local_and_reports_manual_statusline_setup() {
        let available = ClaudeLocalQuotaSnapshot {
            state: "available".into(),
            captured_at: Some("2026-10-25T00:00:00Z".into()),
            five_hour: Some(ClaudeLocalQuotaWindow {
                used_percent: 25.0,
                resets_at: Some("2026-10-25T05:00:00Z".into()),
            }),
            seven_day: None,
        };
        let snapshots = quota_provider_snapshots(&available);
        assert_eq!(snapshots.len(), QUOTA_CLIENTS.len());
        assert!(snapshots.iter().all(|snapshot| snapshot.client != "codex"));
        assert_eq!(snapshots[0].state, "available");
        assert_eq!(snapshots[0].source, "local-statusline");
        assert_eq!(snapshots[0].windows[0].label, "5 小时");
        assert!(snapshots[0].notice.contains("未绑定到具体账号"));
        assert_eq!(snapshots[1].state, "unavailable");
        assert_eq!(snapshots[1].source, "unsupported");

        let missing = ClaudeLocalQuotaSnapshot {
            state: "missing".into(),
            captured_at: None,
            five_hour: None,
            seven_day: None,
        };
        let disconnected = quota_provider_snapshots(&missing);
        assert_eq!(disconnected[0].state, "notConnected");
        assert!(disconnected[0]
            .notice
            .contains("ClaudeLocalReader --capture-statusline"));
        assert!(disconnected[0].notice.contains("10 分钟"));
    }
}
