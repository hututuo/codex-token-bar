use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const CLAUDE_CLIENTS: [&str; 2] = ["claudeCode", "claudeDesktop"];
const RUNTIME_CLIENTS: [&str; 6] = [
    "codex",
    "claudeCode",
    "claudeDesktop",
    "deepseek",
    "gemini",
    "opencode",
];
const OTHER_CLIENTS: [&str; 3] = ["deepseek", "gemini", "opencode"];
const MAX_RUNTIME_LINE_BYTES: usize = 256 * 1024;
const MAX_SOURCE_READ_LINE_BYTES: usize = 4096;
const MAX_SOURCE_READ_BYTES: usize = 4 * 1024 * 1024;
const MAX_COUNTER: u64 = 10_000;
// Upstream clamps each input/output field to 1e12; total is their sum.
const MAX_OUTPUT_TOKENS: u64 = 1_000_000_000_000;
const MAX_TOTAL_TOKENS: u64 = 2 * MAX_OUTPUT_TOKENS;
const MAX_RATE: f64 = 1_000_000_000.0;
const MAX_RESPONSE_EVENTS: usize = 32;
const SNAPSHOT_MAX_AGE: Duration = Duration::from_secs(10);
const IDLE_AGENT_MAX_AGE_SECONDS: i64 = 5 * 60;
const HELPER_ENV_ALLOWLIST: &[&str] = &[
    "SystemRoot",
    "WINDIR",
    "USERPROFILE",
    "HOMEDRIVE",
    "HOMEPATH",
    "LOCALAPPDATA",
    "TEMP",
    "TMP",
];

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeLocalRuntimeSnapshot {
    pub enabled: bool,
    pub captured_at: Option<String>,
    pub source_available: BTreeMap<String, bool>,
    pub live_output_tps: f64,
    pub live_total_tps: f64,
    pub estimated_share: f64,
    pub model_rates: Vec<ClaudeLocalModelRate>,
    pub main_agents: Vec<ClaudeLocalRuntimeAgent>,
    pub subagents: Vec<ClaudeLocalRuntimeAgent>,
    pub latest_response: Option<ClaudeLocalLatestResponse>,
    #[serde(default)]
    pub response_events: Vec<ClaudeLocalActivityEvent>,
    pub configuration_issue: Option<String>,
}

impl ClaudeLocalRuntimeSnapshot {
    fn unavailable(enabled: bool, issue: Option<&str>) -> Self {
        Self::unavailable_for(enabled, issue, &[])
    }

    fn unavailable_for(enabled: bool, issue: Option<&str>, clients: &[String]) -> Self {
        let mut source_available = CLAUDE_CLIENTS
            .into_iter()
            .map(|client| (client.to_string(), false))
            .collect::<BTreeMap<_, _>>();
        for client in clients
            .iter()
            .filter(|client| RUNTIME_CLIENTS.contains(&client.as_str()))
        {
            source_available.insert(client.clone(), false);
        }
        Self {
            enabled,
            source_available,
            configuration_issue: issue.map(str::to_owned),
            ..Self::default()
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeLocalModelRate {
    pub client: String,
    pub model: String,
    pub output_tps: f64,
    pub total_tps: f64,
    pub generating_agents: u32,
    pub tools_agents: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeLocalRuntimeAgent {
    pub id: String,
    pub client: String,
    pub parent_id: Option<String>,
    pub phase: String,
    pub model: Option<String>,
    pub last_activity: String,
    pub live_output_tps: f64,
    pub live_total_tps: f64,
    pub recent_speed: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeLocalLatestResponse {
    pub client: String,
    pub model: Option<String>,
    pub output_tokens: u64,
    pub total_tokens: u64,
    pub duration_ms: Option<u64>,
    pub speed: Option<f64>,
    pub ended_at: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeLocalActivityEvent {
    pub id: String,
    pub r#type: String,
    pub client: String,
    pub model: Option<String>,
    pub output_tokens: u64,
    pub total_tokens: u64,
    pub duration_ms: Option<u64>,
    pub speed: Option<f64>,
    pub ended_at: String,
}

#[derive(Clone, Default)]
pub struct ClaudeLocalRuntimeRegistry {
    inner: Arc<Mutex<RegistryState>>,
    reconcile_gate: Arc<Mutex<()>>,
}

#[derive(Default)]
struct RegistryState {
    worker: Option<RuntimeWorker>,
    failed_config: Option<RuntimeConfigKey>,
    retry_after: Option<Instant>,
    last_global_enabled: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RuntimeConfigKey {
    claude_root: Option<String>,
    codex_root: Option<String>,
    enabled_clients: Vec<String>,
    other_roots: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
struct RuntimeRoots {
    claude_root: Option<std::path::PathBuf>,
    codex_root: Option<std::path::PathBuf>,
    other_roots: BTreeMap<String, std::path::PathBuf>,
}

struct RuntimeWorker {
    key: RuntimeConfigKey,
    child: std::process::Child,
    stdin: Arc<Mutex<Option<std::process::ChildStdin>>>,
    frame: Arc<Mutex<RuntimeFrame>>,
}

#[derive(Clone, Default)]
struct RuntimeFrame {
    snapshot: Option<ClaudeLocalRuntimeSnapshot>,
    received_at: Option<Instant>,
    issue: Option<&'static str>,
}

impl ClaudeLocalRuntimeRegistry {
    pub fn read_snapshot(&self, app: &tauri::AppHandle) -> ClaudeLocalRuntimeSnapshot {
        #[cfg(not(windows))]
        {
            let _ = app;
            ClaudeLocalRuntimeSnapshot::unavailable(false, Some("unsupported_platform"))
        }

        #[cfg(windows)]
        {
            self.read_snapshot_windows(app)
        }
    }

    fn read_snapshot_windows(&self, app: &tauri::AppHandle) -> ClaudeLocalRuntimeSnapshot {
        let _reconcile = self
            .reconcile_gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let settings = match crate::platform::read_app_settings() {
            Ok(settings) => settings,
            Err(_) => {
                self.lock_state().last_global_enabled = None;
                self.stop_worker();
                return ClaudeLocalRuntimeSnapshot::unavailable(
                    false,
                    Some("settings_unavailable"),
                );
            }
        };
        self.lock_state().last_global_enabled = Some(settings.display_surfaces.live_rate_enabled);
        let codex_opted_in =
            codex_local_activity_enabled(settings.display_surfaces.live_rate_enabled);
        if !settings.display_surfaces.live_rate_enabled {
            self.stop_worker();
            let disabled_clients = if codex_opted_in {
                vec!["codex".to_owned()]
            } else {
                Vec::new()
            };
            return ClaudeLocalRuntimeSnapshot::unavailable_for(false, None, &disabled_clients);
        }

        let preferences = match read_enabled_claude_preferences() {
            Ok(preferences) => preferences,
            Err(issue) => {
                self.stop_worker();
                let codex_client = if codex_opted_in {
                    vec!["codex".to_owned()]
                } else {
                    Vec::new()
                };
                return ClaudeLocalRuntimeSnapshot::unavailable_for(
                    false,
                    Some(issue),
                    &codex_client,
                );
            }
        };
        let codex_root = codex_opted_in.then(|| {
            std::path::PathBuf::from(crate::platform::default_codex_home_status().path)
                .join("sessions")
        });
        let mut requested_clients = preferences
            .iter()
            .map(|preference| preference.client.clone())
            .collect::<Vec<_>>();
        if codex_opted_in {
            requested_clients.push("codex".into());
        }
        let (key, roots) = match runtime_configuration(&preferences, codex_root) {
            Ok(Some(configuration)) => configuration,
            Ok(None) => {
                self.stop_worker();
                return ClaudeLocalRuntimeSnapshot::unavailable(false, None);
            }
            Err(issue) => {
                self.stop_worker();
                return ClaudeLocalRuntimeSnapshot::unavailable_for(
                    true,
                    Some(issue),
                    &requested_clients,
                );
            }
        };
        let enabled_clients = key.enabled_clients.clone();
        if enabled_clients.is_empty() {
            self.stop_worker();
            return ClaudeLocalRuntimeSnapshot::unavailable(false, None);
        }
        let helper = match packaged_helper_path(app) {
            Ok(helper) => helper,
            Err(issue) => {
                self.stop_worker();
                return ClaudeLocalRuntimeSnapshot::unavailable_for(
                    true,
                    Some(issue),
                    &enabled_clients,
                );
            }
        };

        let mut state = self.lock_state();
        if state
            .worker
            .as_ref()
            .is_some_and(|worker| worker.key != key)
        {
            stop_worker(state.worker.take());
            state.failed_config = None;
            state.retry_after = None;
        }

        let worker_exited = state
            .worker
            .as_mut()
            .is_some_and(|worker| !matches!(worker.child.try_wait(), Ok(None)));
        if worker_exited {
            stop_worker(state.worker.take());
            state.failed_config = Some(key.clone());
            state.retry_after = Some(Instant::now() + Duration::from_secs(5));
        }

        if state.worker.is_none() {
            let is_backing_off = state.failed_config.as_ref() == Some(&key)
                && state
                    .retry_after
                    .is_some_and(|retry_after| Instant::now() < retry_after);
            if !is_backing_off {
                match start_worker(helper, roots.clone(), key.clone()) {
                    Ok(worker) => {
                        state.worker = Some(worker);
                        state.failed_config = None;
                        state.retry_after = None;
                    }
                    Err(_) => {
                        state.failed_config = Some(key);
                        state.retry_after = Some(Instant::now() + Duration::from_secs(5));
                        return ClaudeLocalRuntimeSnapshot::unavailable_for(
                            true,
                            Some("helper_start_failed"),
                            &enabled_clients,
                        );
                    }
                }
            }
        }

        let Some(worker) = state.worker.as_ref() else {
            return ClaudeLocalRuntimeSnapshot::unavailable_for(
                true,
                Some("helper_unavailable"),
                &enabled_clients,
            );
        };
        let Ok(frame) = worker.frame.lock() else {
            return ClaudeLocalRuntimeSnapshot::unavailable_for(
                true,
                Some("helper_output_invalid"),
                &enabled_clients,
            );
        };
        let Some(received_at) = frame.received_at else {
            return ClaudeLocalRuntimeSnapshot::unavailable_for(
                true,
                frame.issue.or(Some("waiting_for_local_snapshot")),
                &enabled_clients,
            );
        };
        if received_at.elapsed() > SNAPSHOT_MAX_AGE {
            return ClaudeLocalRuntimeSnapshot::unavailable_for(
                true,
                Some("helper_output_stale"),
                &enabled_clients,
            );
        }
        let snapshot = match frame.snapshot.clone() {
            Some(mut snapshot) => {
                snapshot.enabled = true;
                snapshot.configuration_issue = None;
                snapshot
            }
            None => ClaudeLocalRuntimeSnapshot::unavailable_for(
                true,
                frame.issue.or(Some("helper_output_invalid")),
                &enabled_clients,
            ),
        };
        drop(frame);
        if snapshot.configuration_issue.is_none() {
            capture_activity_rates(&snapshot, &key);
        }
        snapshot
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, RegistryState> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn stop_worker(&self) {
        let mut state = self.lock_state();
        stop_worker(state.worker.take());
        state.failed_config = None;
        state.retry_after = None;
    }

    /// Apply a persisted global monitoring preference immediately. Turning monitoring off
    /// must not depend on another window polling this snapshot command.
    pub fn set_live_rate_enabled(&self, enabled: bool) {
        let _reconcile = self
            .reconcile_gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut state = self.lock_state();
        let should_stop =
            !enabled && (state.last_global_enabled != Some(false) || state.worker.is_some());
        if should_stop {
            stop_worker(state.worker.take());
        }
        if !enabled {
            state.failed_config = None;
            state.retry_after = None;
        }
        state.last_global_enabled = Some(enabled);
    }

    /// Reconcile the running helper against the saved source enablement and roots. Cosmetic
    /// preference edits leave an identical worker alone; source changes stop it before the
    /// save command returns, and a later snapshot request may start the new configuration.
    pub fn reconcile_preferences(
        &self,
        preferences: &[crate::core::multi_client_usage::MultiClientUsagePreference],
    ) {
        let enabled = enabled_claude_preferences(preferences);
        let last_global_enabled = self.lock_state().last_global_enabled;
        let codex_live_rate_enabled = last_global_enabled.unwrap_or_else(|| {
            crate::platform::read_app_settings()
                .map(|settings| settings.display_surfaces.live_rate_enabled)
                .unwrap_or(false)
        });
        let codex_root = codex_local_activity_enabled(codex_live_rate_enabled).then(|| {
            std::path::PathBuf::from(crate::platform::default_codex_home_status().path)
                .join("sessions")
        });
        let next_key = runtime_configuration(&enabled, codex_root)
            .ok()
            .flatten()
            .map(|(key, _)| key);

        let _reconcile = self
            .reconcile_gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut state = self.lock_state();
        let worker_changed = state
            .worker
            .as_ref()
            .is_some_and(|worker| Some(&worker.key) != next_key.as_ref());
        if worker_changed || next_key.is_none() {
            stop_worker(state.worker.take());
        }
        if state
            .failed_config
            .as_ref()
            .is_some_and(|failed| Some(failed) != next_key.as_ref())
            || next_key.is_none()
        {
            state.failed_config = None;
            state.retry_after = None;
        }
    }

    pub fn stop(&self) {
        let _reconcile = self
            .reconcile_gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.stop_worker();
    }
}

impl Drop for RegistryState {
    fn drop(&mut self) {
        stop_worker(self.worker.take());
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreferencesFile {
    schema_version: u32,
    preferences: Vec<ClaudePreference>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudePreference {
    client: String,
    enabled: bool,
    #[serde(default)]
    path: String,
}

#[derive(Clone, Debug)]
struct EnabledClaudePreference {
    client: String,
    path: String,
}

fn enabled_claude_preferences(
    preferences: &[crate::core::multi_client_usage::MultiClientUsagePreference],
) -> Vec<EnabledClaudePreference> {
    preferences
        .iter()
        .filter(|preference| {
            RUNTIME_CLIENTS.contains(&preference.client.as_str())
                && preference.client != "codex"
                && preference.enabled
        })
        .map(|preference| EnabledClaudePreference {
            client: preference.client.clone(),
            path: preference.path.clone(),
        })
        .collect()
}

fn read_enabled_claude_preferences() -> Result<Vec<EnabledClaudePreference>, &'static str> {
    use std::{fs, io::Read};

    let path =
        crate::core::app_paths::multi_client_usage_settings_path().ok_or("settings_unavailable")?;
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err("settings_unavailable"),
    };
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > 1024 * 1024
    {
        return Err("settings_invalid");
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt as _;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err("settings_invalid");
        }
    }

    let file = fs::File::open(path).map_err(|_| "settings_unavailable")?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "settings_unavailable")?;
    if bytes.len() > 1024 * 1024 {
        return Err("settings_invalid");
    }
    let parsed: PreferencesFile = serde_json::from_slice(&bytes).map_err(|_| "settings_invalid")?;
    if parsed.schema_version != 1 {
        return Err("settings_invalid");
    }
    let mut selected = BTreeMap::new();
    for preference in parsed.preferences {
        if !RUNTIME_CLIENTS.contains(&preference.client.as_str())
            || preference.client == "codex"
            || !preference.enabled
        {
            continue;
        }
        selected
            .entry(preference.client.clone())
            .or_insert(EnabledClaudePreference {
                client: preference.client,
                path: preference.path,
            });
    }
    Ok(selected.into_values().collect())
}

fn shared_local_root(
    preferences: &[EnabledClaudePreference],
) -> Result<std::path::PathBuf, &'static str> {
    let mut roots = preferences
        .iter()
        .map(|preference| preference_root(&preference.path))
        .collect::<Result<Vec<_>, _>>()?;
    let Some(root) = roots.pop() else {
        return Err("claude_usage_disabled");
    };
    let key = normalized_path_key(&root);
    if roots
        .iter()
        .any(|candidate| normalized_path_key(candidate) != key)
    {
        return Err("claude_sources_must_share_a_local_root");
    }
    Ok(root)
}

fn runtime_configuration(
    preferences: &[EnabledClaudePreference],
    codex_root: Option<std::path::PathBuf>,
) -> Result<Option<(RuntimeConfigKey, RuntimeRoots)>, &'static str> {
    let claude_preferences = preferences
        .iter()
        .filter(|p| CLAUDE_CLIENTS.contains(&p.client.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    let claude_root = if claude_preferences.is_empty() {
        None
    } else {
        Some(shared_local_root(&claude_preferences)?)
    };
    let mut other_roots = BTreeMap::new();
    for preference in preferences
        .iter()
        .filter(|p| OTHER_CLIENTS.contains(&p.client.as_str()))
    {
        let root = other_client_root(&preference.client, &preference.path)?;
        other_roots.insert(preference.client.clone(), root);
    }
    if claude_root.is_none() && codex_root.is_none() && other_roots.is_empty() {
        return Ok(None);
    }
    let mut enabled_clients = preferences
        .iter()
        .map(|preference| preference.client.clone())
        .collect::<Vec<_>>();
    if let Some(root) = codex_root.as_ref() {
        validate_local_absolute_path(root)?;
        enabled_clients.push("codex".into());
    }
    enabled_clients.sort();
    let key = RuntimeConfigKey {
        claude_root: claude_root.as_deref().map(normalized_path_key),
        codex_root: codex_root.as_deref().map(normalized_path_key),
        enabled_clients: enabled_clients.clone(),
        other_roots: other_roots
            .iter()
            .map(|(client, root)| (client.clone(), normalized_path_key(root)))
            .collect(),
    };
    Ok(Some((
        key,
        RuntimeRoots {
            claude_root,
            codex_root,
            other_roots,
        },
    )))
}

fn other_client_root(client: &str, path: &str) -> Result<std::path::PathBuf, &'static str> {
    use std::path::PathBuf;
    let home = crate::core::app_paths::home_dir();
    let env_path = |name: &str| {
        std::env::var_os(name)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    };
    let mut root = if path.trim().is_empty() {
        match client {
            "deepseek" => env_path("DSH_HOME")
                .unwrap_or_else(|| home.join(".dsh"))
                .join("sessions"),
            "gemini" => env_path("GEMINI_CLI_HOME")
                .unwrap_or_else(|| home.clone())
                .join(".gemini")
                .join("tmp"),
            "opencode" => env_path("OPENCODE_DATA_DIR").unwrap_or_else(|| {
                env_path("XDG_DATA_HOME")
                    .unwrap_or_else(|| home.join(".local").join("share"))
                    .join("opencode")
            }),
            _ => return Err("unsupported_local_source"),
        }
    } else if path.trim() == "~" {
        home.clone()
    } else if let Some(suffix) = path
        .trim()
        .strip_prefix("~/")
        .or_else(|| path.trim().strip_prefix("~\\"))
    {
        home.join(suffix)
    } else {
        PathBuf::from(path.trim())
    };
    if client == "opencode" && root.file_name().is_some_and(|name| name == "opencode.db") {
        root.pop();
    }
    validate_local_absolute_path(&root)?;
    Ok(root)
}

/// Same resolver as the display helper; this returns only non-Claude roots
/// for the opt-in reporter's local startup pipe, never an upload document.
pub(crate) fn selected_reporting_local_roots() -> Result<BTreeMap<String, String>, &'static str> {
    read_enabled_claude_preferences()?
        .iter()
        .filter(|p| OTHER_CLIENTS.contains(&p.client.as_str()))
        .map(|p| {
            let root = other_client_root(&p.client, &p.path)?
                .to_string_lossy()
                .to_string();
            if root.chars().count() > 1024 || root.chars().any(char::is_control) {
                return Err("local_source_root_invalid");
            }
            Ok((p.client.clone(), root))
        })
        .collect()
}

fn codex_local_activity_enabled(live_rate_enabled: bool) -> bool {
    live_rate_enabled
}

fn preference_root(path: &str) -> Result<std::path::PathBuf, &'static str> {
    use std::path::PathBuf;

    let trimmed = path.trim();
    let root = if trimmed.is_empty() {
        default_claude_root()
    } else {
        let expanded = if trimmed == "~" {
            crate::core::app_paths::home_dir()
        } else if let Some(suffix) = trimmed
            .strip_prefix("~/")
            .or_else(|| trimmed.strip_prefix("~\\"))
        {
            crate::core::app_paths::home_dir().join(suffix)
        } else {
            PathBuf::from(trimmed)
        };
        expanded
    };
    validate_local_absolute_path(&root)?;
    Ok(root)
}

fn default_claude_root() -> std::path::PathBuf {
    use std::path::PathBuf;

    std::env::var_os("CLAUDE_CONFIG_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::core::app_paths::home_dir().join(".claude"))
        .join("projects")
}

// A canonical Windows disk path uses this prefix too; it is not a UNC share.
// Permit only drive-qualified disks, never device namespaces or verbatim UNC.
fn is_verbatim_local_disk_path(text: &str) -> bool {
    let Some(rest) = text.strip_prefix(r"\\?\") else {
        return false;
    };
    let bytes = rest.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/')
}

fn validate_local_absolute_path(path: &std::path::Path) -> Result<(), &'static str> {
    let text = path.to_string_lossy();
    let unc =
        (text.starts_with("\\\\") || text.starts_with("//")) && !is_verbatim_local_disk_path(&text);
    if unc || !path.is_absolute() {
        return Err("claude_root_must_be_local_absolute");
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt as _;
        let mut current = path.to_path_buf();
        while current.file_name().is_some() {
            if let Ok(metadata) = std::fs::symlink_metadata(&current) {
                const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
                if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                    return Err("claude_root_must_be_local_absolute");
                }
            }
            if !current.pop() {
                break;
            }
        }
    }
    Ok(())
}

fn normalized_path_key(path: &std::path::Path) -> String {
    path.to_string_lossy()
        .replace('/', "\\")
        .trim_end_matches('\\')
        .to_lowercase()
}

fn capture_activity_rates(
    snapshot: &ClaudeLocalRuntimeSnapshot,
    key: &RuntimeConfigKey,
) {
    let Some(captured_at) = snapshot
        .captured_at
        .as_deref()
        .and_then(|value| parse_timestamp(value).ok())
    else {
        return;
    };
    let now = captured_at.unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    for client in &key.enabled_clients {
        let root = match client.as_str() {
            "codex" => key.codex_root.as_deref(),
            "claudeCode" | "claudeDesktop" => key.claude_root.as_deref(),
            other => key.other_roots.get(other).map(String::as_str),
        };
        let Some(root) = root else { continue };
        // Codex's monitor receives <home>/sessions; keep Bar and Agent Speed
        // samples under the same home identity rather than two folder hashes.
        let activity_root = if client == "codex" {
            codex_activity_root(root)
        } else {
            root
        };
        let source_signature = crate::core::activity_speed_capture::root_identity(activity_root);
        let rates = snapshot
            .model_rates
            .iter()
            .filter(|rate| rate.client == *client)
            .map(|rate| (rate.model.clone(), rate.output_tps))
            .collect();
        let available = snapshot
            .source_available
            .get(client)
            .copied()
            .unwrap_or(false);
        crate::core::activity_speed_capture::record(
            client,
            &source_signature,
            "agentSpeed",
            rates,
            now,
            available,
        );
    }
}

fn codex_activity_root(root: &str) -> &str {
    root.strip_suffix("\\sessions")
        .or_else(|| root.strip_suffix("/sessions"))
        .unwrap_or(root)
}

fn packaged_helper_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, &'static str> {
    use tauri::Manager as _;

    #[cfg(windows)]
    use std::os::windows::fs::MetadataExt as _;
    #[cfg(windows)]
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|_| "helper_unavailable")?;
    let path = resource_dir
        .join("ClaudeLocalReader")
        .join("ClaudeLocalReader.exe");
    let metadata = std::fs::symlink_metadata(&path).map_err(|_| "helper_unavailable")?;
    if !metadata.file_type().is_file() {
        return Err("helper_unavailable");
    }
    #[cfg(windows)]
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err("helper_unavailable");
    }
    let resource_dir = std::fs::canonicalize(resource_dir).map_err(|_| "helper_unavailable")?;
    let helper_path = std::fs::canonicalize(path).map_err(|_| "helper_unavailable")?;
    if !helper_path.starts_with(resource_dir) {
        return Err("helper_unavailable");
    }
    Ok(helper_path)
}

fn start_worker(
    helper: std::path::PathBuf,
    roots: RuntimeRoots,
    key: RuntimeConfigKey,
) -> Result<RuntimeWorker, ()> {
    #[cfg(windows)]
    use std::os::windows::process::CommandExt as _;
    use std::{
        io::BufReader,
        process::{Command, Stdio},
        thread,
    };

    #[cfg(windows)]
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let source_roots = runtime_source_read_roots(&roots, &key);
    let mut command = Command::new(helper);
    command
        .arg("--watch")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(root) = roots.claude_root {
        command.arg("--root").arg(root);
    }
    if let Some(root) = roots.codex_root {
        command.arg("--codex-root").arg(root);
    }
    for (client, root) in roots.other_roots {
        let flag = match client.as_str() {
            "deepseek" => "--dsh-root",
            "gemini" => "--gemini-root",
            "opencode" => "--opencode-root",
            _ => return Err(()),
        };
        command.arg(flag).arg(root);
    }
    // Keep process startup deterministic and prevent forwarding unrelated credential variables.
    command.env_clear();
    for key in HELPER_ENV_ALLOWLIST {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    for client in &key.enabled_clients {
        command.arg("--source").arg(client);
    }
    let mut child = command.spawn().map_err(|_| ())?;
    let Some(stdin) = child.stdin.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(());
    };
    let Some(stdout) = child.stdout.take() else {
        drop(stdin);
        let _ = child.kill();
        let _ = child.wait();
        return Err(());
    };
    let stdin = Arc::new(Mutex::new(Some(stdin)));
    let frame = Arc::new(Mutex::new(RuntimeFrame::default()));
    let reader_frame = frame.clone();
    let reader_stdin = Arc::clone(&stdin);
    let client_allowlist = key.enabled_clients.clone();
    let reader_thread = thread::Builder::new()
        .name("claude-local-runtime-reader".into())
        .spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_bounded_line(&mut reader) {
                    Ok(Some(Ok(bytes))) => {
                        if is_source_read_request(&bytes) {
                            if let Some(reply) = source_read_reply(&bytes, &source_roots) {
                                let write_result = {
                                    let mut writer = reader_stdin
                                        .lock()
                                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                                    if let Some(stdin) = writer.as_mut() {
                                        stdin
                                            .write_all(&reply.header)
                                            .and_then(|()| stdin.write_all(&reply.payload))
                                            .and_then(|()| stdin.flush())
                                    } else {
                                        break;
                                    }
                                };
                                if write_result.is_err() {
                                    break;
                                }
                            }
                            continue;
                        }

                        let parsed = parse_runtime_snapshot(&bytes, &client_allowlist);
                        if let Ok(mut frame) = reader_frame.lock() {
                            match parsed {
                                Ok(snapshot) => {
                                    frame.snapshot = Some(snapshot);
                                    frame.received_at = Some(Instant::now());
                                    frame.issue = None;
                                }
                                Err(issue) => {
                                    frame.snapshot = None;
                                    frame.received_at = Some(Instant::now());
                                    frame.issue = Some(issue);
                                }
                            }
                        }
                    }
                    Ok(Some(Err(()))) => {
                        if let Ok(mut frame) = reader_frame.lock() {
                            frame.snapshot = None;
                            frame.received_at = Some(Instant::now());
                            frame.issue = Some("helper_output_too_large");
                        }
                    }
                    Ok(None) | Err(_) => break,
                }
            }
            if let Ok(mut frame) = reader_frame.lock() {
                frame.snapshot = None;
                frame.received_at = None;
                frame.issue = Some("helper_exited");
            }
        });
    if reader_thread.is_err() {
        drop(stdin);
        let _ = child.kill();
        let _ = child.wait();
        return Err(());
    }

    Ok(RuntimeWorker {
        key,
        child,
        stdin,
        frame,
    })
}

fn stop_worker(mut worker: Option<RuntimeWorker>) {
    use std::{thread, time::Duration};
    let Some(mut worker) = worker.take() else {
        return;
    };
    let stdin = worker
        .stdin
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
    drop(stdin);
    let deadline = Instant::now() + Duration::from_millis(900);
    loop {
        match worker.child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(25)),
            _ => break,
        }
    }
    let _ = worker.child.kill();
    let _ = worker.child.wait();
}

/// Roots shared by the opted-in local display reader. Only clients explicitly enabled in the
/// helper configuration are included; the reporter uses its separate non-Claude allowlist.
fn runtime_source_read_roots(roots: &RuntimeRoots, key: &RuntimeConfigKey) -> Vec<PathBuf> {
    let mut allowed = Vec::new();
    for client in &key.enabled_clients {
        match client.as_str() {
            "codex" => {
                if let Some(root) = roots.codex_root.as_ref() {
                    allowed.push(root.clone());
                    if let Some(home) = root.parent() {
                        allowed.push(home.join("archived_sessions"));
                    }
                }
            }
            "claudeCode" | "claudeDesktop" => {
                if let Some(root) = roots.claude_root.as_ref() {
                    allowed.push(root.clone());
                }
            }
            other => {
                if let Some(root) = roots.other_roots.get(other) {
                    allowed.push(root.clone());
                }
            }
        }
    }
    allowed
}

/// Roots the Windows reporter's upstream monitor can read. The reporter keeps its complete
/// non-Claude SourceKind set; this authorization list mirrors those default roots and saved
/// DeepSeek/Gemini/OpenCode roots without using display-mode preferences.
pub(crate) fn reporting_source_read_roots(
    codex_home: &Path,
    local_source_roots: &BTreeMap<String, String>,
) -> Vec<PathBuf> {
    let home = source_read_user_home();
    let mut roots = vec![
        codex_home.join("sessions"),
        codex_home.join("archived_sessions"),
        local_source_roots
            .get("deepseek")
            .map(|root| PathBuf::from(root.as_str()))
            .unwrap_or_else(|| {
                std::env::var_os("DSH_HOME")
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home.join(".dsh"))
                    .join("sessions")
            }),
        local_source_roots
            .get("gemini")
            .map(|root| PathBuf::from(root.as_str()))
            .unwrap_or_else(|| {
                std::env::var_os("GEMINI_CLI_HOME")
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home.clone())
                    .join(".gemini")
                    .join("tmp")
            }),
        local_source_roots
            .get("opencode")
            .map(|root| PathBuf::from(root.as_str()))
            .unwrap_or_else(|| {
                std::env::var_os("XDG_DATA_HOME")
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home.join(".local").join("share"))
                    .join("opencode")
            }),
    ];

    let omp_agent = std::env::var_os("PI_CODING_AGENT_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".omp").join("agent"));
    roots.push(omp_agent.join("sessions"));
    let omp_profiles = home.join(".omp").join("profiles");
    let omp_profiles_text = omp_profiles.to_string_lossy();
    if is_local_absolute_source_path(&omp_profiles_text)
        && is_local_source_drive(&omp_profiles_text)
    {
        if let Ok(entries) = std::fs::read_dir(&omp_profiles) {
            for entry in entries.flatten() {
                if entry
                    .file_type()
                    .is_ok_and(|kind| kind.is_dir() && !kind.is_symlink())
                {
                    roots.push(entry.path().join("agent").join("sessions"));
                }
            }
        }
    }

    for store in ["antigravity-cli", "antigravity", "antigravity-ide"] {
        roots.push(home.join(".gemini").join(store).join("conversations"));
    }
    roots.push(home.join(".workbuddy").join("projects"));
    roots.push(home.join(".workbuddy-ai").join("projects"));

    let zcode_base = std::env::var_os("ZCODE_DATA_BASE_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.clone());
    roots.push(zcode_base.join(".zcode").join("cli").join("db"));
    let kimi_home = std::env::var_os("KIMI_CODE_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".kimi-code"));
    roots.push(kimi_home.join("sessions"));
    let grok_home = std::env::var_os("GROK_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".grok"));
    roots.push(grok_home.join("sessions"));
    roots
}

fn source_read_user_home() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(crate::core::app_paths::home_dir)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceReadRequest {
    #[serde(rename = "type")]
    message_type: String,
    id: i64,
    path: String,
    identity: SourceReadFileIdentity,
    offset: u64,
    count: u32,
    probe: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceReadFileIdentity {
    volume: u64,
    file_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SourceReadResponse<'a> {
    #[serde(rename = "type")]
    message_type: &'static str,
    id: i64,
    count: usize,
    error: Option<&'a str>,
}

pub(crate) struct SourceReadReply {
    pub(crate) header: Vec<u8>,
    pub(crate) payload: Vec<u8>,
}

pub(crate) fn is_source_read_request(line: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(line)
        .ok()
        .and_then(|value| {
            value
                .get("type")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
        .is_some_and(|kind| kind == "sourceRead")
}

pub(crate) fn source_read_reply(line: &[u8], roots: &[PathBuf]) -> Option<SourceReadReply> {
    let value = serde_json::from_slice::<serde_json::Value>(line).ok()?;
    if value.get("type").and_then(serde_json::Value::as_str) != Some("sourceRead") {
        return None;
    }
    let id = value
        .get("id")
        .and_then(serde_json::Value::as_i64)
        .filter(|id| *id > 0)?;
    if line.len() > MAX_SOURCE_READ_LINE_BYTES {
        return Some(source_read_error(id, "invalid_request"));
    }
    let request = match serde_json::from_value::<SourceReadRequest>(value) {
        Ok(request) => request,
        Err(_) => return Some(source_read_error(id, "invalid_request")),
    };
    if request.message_type != "sourceRead"
        || request.path.len() > MAX_SOURCE_READ_LINE_BYTES
        || request.path.chars().any(char::is_control)
        || request.count as usize > MAX_SOURCE_READ_BYTES
        || decode_file_id(&request.identity.file_id).is_none()
    {
        return Some(source_read_error(id, "invalid_request"));
    }

    let path = match resolve_source_read_path(&request.path, roots) {
        Ok(path) => path,
        Err(code) => return Some(source_read_error(id, code)),
    };
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(_) => return Some(source_read_error(id, "source_unavailable")),
    };
    if !file_matches_expected_identity(&file, &request.identity) {
        return Some(source_read_error(id, "identity_changed"));
    }

    let count = request.count as usize;
    let result = if request.probe {
        super::shared_source_io::probe_uncached(&file, request.offset, count)
    } else {
        super::shared_source_io::read_range(&file, request.offset, count)
    };
    match result {
        Ok(payload) if payload.len() <= count => Some(source_read_success(id, payload)),
        _ => Some(source_read_error(id, "source_read_failed")),
    }
}

fn source_read_success(id: i64, payload: Vec<u8>) -> SourceReadReply {
    source_read_response(id, payload, None)
}

fn source_read_error(id: i64, code: &'static str) -> SourceReadReply {
    source_read_response(id, Vec::new(), Some(code))
}

fn source_read_response(id: i64, payload: Vec<u8>, error: Option<&'static str>) -> SourceReadReply {
    let response = SourceReadResponse {
        message_type: "sourceReadResult",
        id,
        count: payload.len(),
        error,
    };
    let mut header = serde_json::to_vec(&response).expect("fixed source-read response serializes");
    header.push(b'\n');
    SourceReadReply { header, payload }
}

fn decode_file_id(text: &str) -> Option<[u8; 16]> {
    let bytes = text.as_bytes();
    if bytes.len() != 32 {
        return None;
    }
    let mut identifier = [0_u8; 16];
    for (index, pair) in bytes.chunks_exact(2).enumerate() {
        identifier[index] = (hex_nibble(pair[0])? << 4) | hex_nibble(pair[1])?;
    }
    Some(identifier)
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn resolve_source_read_path(path: &str, roots: &[PathBuf]) -> Result<PathBuf, &'static str> {
    if !is_local_absolute_source_path(path) {
        return Err("invalid_path");
    }
    if !is_local_source_drive(path) {
        return Err("root_denied");
    }
    let requested = PathBuf::from(path);
    if path_has_reparse_component(&requested) {
        return Err("root_denied");
    }
    let canonical = std::fs::canonicalize(&requested).map_err(|_| "source_unavailable")?;
    let metadata = std::fs::metadata(&canonical).map_err(|_| "source_unavailable")?;
    if !metadata.is_file() {
        return Err("source_unavailable");
    }
    let permitted = roots.iter().any(|root| {
        let root_text = root.to_string_lossy();
        if !is_local_absolute_source_path(&root_text)
            || !is_local_source_drive(&root_text)
            || path_has_reparse_component(root)
        {
            return false;
        }
        std::fs::canonicalize(root)
            .ok()
            .is_some_and(|canonical_root| canonical.starts_with(canonical_root))
    });
    if !permitted {
        return Err("root_denied");
    }
    Ok(canonical)
}

fn is_local_absolute_source_path(path: &str) -> bool {
    if path.is_empty() || path.chars().any(char::is_control) {
        return false;
    }
    source_drive_root(path).is_some()
}

fn source_drive_root(path: &str) -> Option<String> {
    let start = if path.starts_with(r"\\?\") { 4 } else { 0 };
    let bytes = path.as_bytes();
    if bytes.len() < start + 3
        || !bytes[start].is_ascii_alphabetic()
        || bytes[start + 1] != b':'
        || !matches!(bytes[start + 2], b'\\' | b'/')
    {
        return None;
    }
    Some(format!("{}:\\", char::from(bytes[start])))
}

fn source_drive_type_is_local(drive_type: u32) -> bool {
    // DRIVE_REMOVABLE, DRIVE_FIXED, DRIVE_CDROM (read-only), and DRIVE_RAMDISK.
    matches!(drive_type, 2 | 3 | 5 | 6)
}

#[cfg(windows)]
fn is_local_source_drive(path: &str) -> bool {
    use windows_sys::Win32::Storage::FileSystem::GetDriveTypeW;

    let Some(root) = source_drive_root(path) else {
        return false;
    };
    let mut wide = root.encode_utf16().collect::<Vec<_>>();
    wide.push(0);
    // Check drive type before canonicalization or metadata/open calls so mapped network drives
    // are rejected before path probing can touch their remote share.
    source_drive_type_is_local(unsafe { GetDriveTypeW(wide.as_ptr()) })
}

#[cfg(not(windows))]
fn is_local_source_drive(_path: &str) -> bool {
    false
}

#[cfg(windows)]
fn path_has_reparse_component(path: &Path) -> bool {
    use std::os::windows::fs::MetadataExt as _;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
    const FILE_ATTRIBUTE_OFFLINE: u32 = 0x1000;
    const FILE_ATTRIBUTE_RECALL_ON_OPEN: u32 = 0x0004_0000;
    const FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: u32 = 0x0040_0000;
    const SOURCE_READ_DENIED_ATTRIBUTES: u32 = FILE_ATTRIBUTE_REPARSE_POINT
        | FILE_ATTRIBUTE_OFFLINE
        | FILE_ATTRIBUTE_RECALL_ON_OPEN
        | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;
    let mut current = path.to_path_buf();
    loop {
        if std::fs::symlink_metadata(&current)
            .ok()
            .is_some_and(|metadata| metadata.file_attributes() & SOURCE_READ_DENIED_ATTRIBUTES != 0)
        {
            return true;
        }
        if !current.pop() {
            return false;
        }
    }
}

#[cfg(not(windows))]
fn path_has_reparse_component(_path: &Path) -> bool {
    false
}

#[cfg(windows)]
fn file_matches_expected_identity(file: &std::fs::File, expected: &SourceReadFileIdentity) -> bool {
    use std::os::windows::io::AsRawHandle as _;
    use windows_sys::Win32::Storage::FileSystem::{
        FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
    };
    let Some(expected_id) = decode_file_id(&expected.file_id) else {
        return false;
    };
    let mut info = FILE_ID_INFO::default();
    let ok = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileIdInfo,
            (&mut info as *mut FILE_ID_INFO).cast(),
            std::mem::size_of::<FILE_ID_INFO>() as u32,
        )
    };
    ok != 0 && info.VolumeSerialNumber == expected.volume && info.FileId.Identifier == expected_id
}

#[cfg(not(windows))]
fn file_matches_expected_identity(
    _file: &std::fs::File,
    _expected: &SourceReadFileIdentity,
) -> bool {
    false
}

fn read_bounded_line<R: std::io::BufRead>(
    reader: &mut R,
) -> std::io::Result<Option<Result<Vec<u8>, ()>>> {
    let mut line = Vec::with_capacity(1024);
    let mut too_large = false;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            if line.is_empty() && !too_large {
                return Ok(None);
            }
            return Ok(Some(if too_large { Err(()) } else { Ok(line) }));
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let chunk_len = newline.unwrap_or(available.len());
        if !too_large {
            if line.len().saturating_add(chunk_len) > MAX_RUNTIME_LINE_BYTES {
                too_large = true;
                line.clear();
            } else {
                line.extend_from_slice(&available[..chunk_len]);
            }
        }
        reader.consume(chunk_len + usize::from(newline.is_some()));
        if newline.is_some() {
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Ok(Some(if too_large { Err(()) } else { Ok(line) }));
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeWireSnapshot {
    schema: u32,
    captured_at: String,
    client: String,
    source_available: BTreeMap<String, bool>,
    live_output_tps: f64,
    live_total_tps: f64,
    estimated_share: f64,
    model_rates: Vec<RuntimeWireModelRate>,
    main_agents: Vec<RuntimeWireAgent>,
    subagents: Vec<RuntimeWireAgent>,
    latest_response: Option<RuntimeWireResponse>,
    #[serde(default)]
    response_events: Vec<RuntimeWireEvent>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeWireModelRate {
    client: String,
    model: String,
    output_tps: f64,
    total_tps: f64,
    generating_agents: u32,
    tools_agents: u32,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeWireAgent {
    id: String,
    client: String,
    parent_id: Option<String>,
    phase: String,
    model: Option<String>,
    last_activity: String,
    live_output_tps: f64,
    live_total_tps: f64,
    recent_speed: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeWireResponse {
    client: String,
    model: Option<String>,
    output_tokens: u64,
    total_tokens: u64,
    duration_ms: Option<u64>,
    speed: Option<f64>,
    ended_at: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeWireEvent {
    id: String,
    r#type: String,
    client: String,
    model: Option<String>,
    output_tokens: u64,
    total_tokens: u64,
    duration_ms: Option<u64>,
    speed: Option<f64>,
    ended_at: String,
}

fn parse_runtime_snapshot(
    bytes: &[u8],
    enabled_clients: &[String],
) -> Result<ClaudeLocalRuntimeSnapshot, &'static str> {
    if bytes.len() > MAX_RUNTIME_LINE_BYTES {
        return Err("helper_output_too_large");
    }
    let wire: RuntimeWireSnapshot =
        serde_json::from_slice(bytes).map_err(|_| "helper_output_invalid")?;
    if wire.schema != 1 || wire.client != "claude" {
        return Err("helper_output_invalid");
    }
    validate_rate(wire.live_output_tps)?;
    validate_rate(wire.live_total_tps)?;
    if !wire.estimated_share.is_finite() || !(0.0..=1.0).contains(&wire.estimated_share) {
        return Err("helper_output_invalid");
    }
    if enabled_clients
        .iter()
        .any(|client| !RUNTIME_CLIENTS.contains(&client.as_str()))
    {
        return Err("helper_source_mismatch");
    }
    let captured = parse_timestamp(&wire.captured_at)?;
    validate_snapshot_timestamp(captured)?;
    let expected_sources = CLAUDE_CLIENTS
        .iter()
        .copied()
        .chain(enabled_clients.iter().map(String::as_str))
        .collect::<std::collections::BTreeSet<_>>();
    if wire
        .source_available
        .keys()
        .map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>()
        != expected_sources
    {
        return Err("helper_source_mismatch");
    }
    for client in &wire.source_available {
        if *client.1 && !enabled_clients.iter().any(|enabled| enabled == client.0) {
            return Err("helper_source_mismatch");
        }
    }

    let mut model_rates = Vec::with_capacity(wire.model_rates.len());
    for rate in wire.model_rates {
        validate_source_client(&wire.source_available, enabled_clients, &rate.client)?;
        validate_text(&rate.model, 256, false)?;
        validate_rate(rate.output_tps)?;
        validate_rate(rate.total_tps)?;
        if u64::from(rate.generating_agents) > MAX_COUNTER
            || u64::from(rate.tools_agents) > MAX_COUNTER
        {
            return Err("helper_output_invalid");
        }
        model_rates.push(ClaudeLocalModelRate {
            client: rate.client,
            model: rate.model,
            output_tps: rate.output_tps,
            total_tps: rate.total_tps,
            generating_agents: rate.generating_agents,
            tools_agents: rate.tools_agents,
        });
    }

    let mut main_agents =
        validate_agents(wire.main_agents, &wire.source_available, enabled_clients)?;
    let mut subagents = validate_agents(wire.subagents, &wire.source_available, enabled_clients)?;
    let mut agent_clients = std::collections::HashMap::new();
    for agent in main_agents.iter().chain(subagents.iter()) {
        if agent_clients
            .insert(agent.id.clone(), agent.client.clone())
            .is_some()
        {
            return Err("helper_output_invalid");
        }
    }
    for agent in main_agents.iter_mut().chain(subagents.iter_mut()) {
        if let Some(parent) = agent.parent_id.as_ref() {
            match agent_clients.get(parent) {
                Some(parent_client) if parent_client == &agent.client => {}
                _ => agent.parent_id = None,
            }
        }
    }

    let latest_response = wire
        .latest_response
        .map(|response| {
            validate_source_client(&wire.source_available, enabled_clients, &response.client)?;
            validate_optional_text(response.model.as_deref(), 256)?;
            if response.output_tokens > MAX_OUTPUT_TOKENS
                || response.total_tokens > MAX_TOTAL_TOKENS
                || response.total_tokens < response.output_tokens
                || response
                    .duration_ms
                    .is_some_and(|duration| duration > 24 * 60 * 60 * 1000)
            {
                return Err("helper_output_invalid");
            }
            if let Some(speed) = response.speed {
                validate_rate(speed)?;
            }
            let ended = parse_timestamp(&response.ended_at)?;
            validate_not_future(ended)?;
            Ok(ClaudeLocalLatestResponse {
                client: response.client,
                model: response.model,
                output_tokens: response.output_tokens,
                total_tokens: response.total_tokens,
                duration_ms: response.duration_ms,
                speed: response.speed,
                ended_at: response.ended_at,
            })
        })
        .transpose()?;

    if wire.response_events.len() > MAX_RESPONSE_EVENTS {
        return Err("helper_output_invalid");
    }
    let mut event_ids = std::collections::HashSet::new();
    let mut response_events = Vec::with_capacity(wire.response_events.len());
    for event in wire.response_events {
        validate_safe_prefixed_id(&event.id, "event-")?;
        if !event_ids.insert(event.id.clone()) || event.r#type != "responseCompleted" {
            return Err("helper_output_invalid");
        }
        validate_source_client(&wire.source_available, enabled_clients, &event.client)?;
        validate_optional_text(event.model.as_deref(), 256)?;
        if event.output_tokens > MAX_OUTPUT_TOKENS
            || event.total_tokens > MAX_TOTAL_TOKENS
            || event.total_tokens < event.output_tokens
            || event
                .duration_ms
                .is_some_and(|duration| duration > 24 * 60 * 60 * 1000)
        {
            return Err("helper_output_invalid");
        }
        if let Some(speed) = event.speed {
            validate_rate(speed)?;
        }
        let ended = parse_timestamp(&event.ended_at)?;
        validate_not_future(ended)?;
        response_events.push(ClaudeLocalActivityEvent {
            id: event.id,
            r#type: event.r#type,
            client: event.client,
            model: event.model,
            output_tokens: event.output_tokens,
            total_tokens: event.total_tokens,
            duration_ms: event.duration_ms,
            speed: event.speed,
            ended_at: event.ended_at,
        });
    }

    Ok(ClaudeLocalRuntimeSnapshot {
        enabled: true,
        captured_at: Some(wire.captured_at),
        source_available: wire.source_available,
        live_output_tps: wire.live_output_tps,
        live_total_tps: wire.live_total_tps,
        estimated_share: wire.estimated_share,
        model_rates,
        main_agents,
        subagents,
        latest_response,
        response_events,
        configuration_issue: None,
    })
}

fn validate_agents(
    agents: Vec<RuntimeWireAgent>,
    source_available: &BTreeMap<String, bool>,
    enabled_clients: &[String],
) -> Result<Vec<ClaudeLocalRuntimeAgent>, &'static str> {
    let now = time::OffsetDateTime::now_utc();
    let mut result = Vec::with_capacity(agents.len());
    for agent in agents {
        validate_safe_id(&agent.id)?;
        if let Some(parent) = agent.parent_id.as_deref() {
            validate_safe_id(parent)?;
        }
        validate_source_client(source_available, enabled_clients, &agent.client)?;
        if !matches!(agent.phase.as_str(), "generating" | "tools" | "idle") {
            return Err("helper_output_invalid");
        }
        validate_optional_text(agent.model.as_deref(), 256)?;
        validate_rate(agent.live_output_tps)?;
        validate_rate(agent.live_total_tps)?;
        if let Some(speed) = agent.recent_speed {
            validate_rate(speed)?;
        }
        let activity = parse_timestamp(&agent.last_activity)?;
        validate_not_future(activity)?;
        if agent.phase == "idle"
            && now
                .unix_timestamp()
                .saturating_sub(activity.unix_timestamp())
                > IDLE_AGENT_MAX_AGE_SECONDS
        {
            continue;
        }
        result.push(ClaudeLocalRuntimeAgent {
            id: agent.id,
            client: agent.client,
            parent_id: agent.parent_id,
            phase: agent.phase,
            model: agent.model,
            last_activity: agent.last_activity,
            live_output_tps: agent.live_output_tps,
            live_total_tps: agent.live_total_tps,
            recent_speed: agent.recent_speed,
        });
    }
    Ok(result)
}

fn validate_source_client(
    source_available: &BTreeMap<String, bool>,
    enabled_clients: &[String],
    client: &str,
) -> Result<(), &'static str> {
    if !RUNTIME_CLIENTS.contains(&client)
        || !enabled_clients.iter().any(|enabled| enabled == client)
        || source_available.get(client) != Some(&true)
    {
        return Err("helper_source_mismatch");
    }
    Ok(())
}

fn validate_safe_prefixed_id(value: &str, prefix: &str) -> Result<(), &'static str> {
    let Some(suffix) = value.strip_prefix(prefix) else {
        return Err("helper_output_invalid");
    };
    if suffix.len() != 24
        || !suffix
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err("helper_output_invalid");
    }
    Ok(())
}

fn validate_safe_id(value: &str) -> Result<(), &'static str> {
    validate_safe_prefixed_id(value, "agent-")
}

fn validate_text(value: &str, max_chars: usize, allow_empty: bool) -> Result<(), &'static str> {
    if value.chars().count() > max_chars
        || (!allow_empty && value.trim().is_empty())
        || value.chars().any(char::is_control)
    {
        return Err("helper_output_invalid");
    }
    Ok(())
}

fn validate_optional_text(value: Option<&str>, max_chars: usize) -> Result<(), &'static str> {
    if let Some(value) = value {
        validate_text(value, max_chars, true)?;
    }
    Ok(())
}

fn validate_rate(value: f64) -> Result<(), &'static str> {
    if !value.is_finite() || !(0.0..=MAX_RATE).contains(&value) {
        return Err("helper_output_invalid");
    }
    Ok(())
}

fn parse_timestamp(value: &str) -> Result<time::OffsetDateTime, &'static str> {
    use time::format_description::well_known::Rfc3339;
    time::OffsetDateTime::parse(value, &Rfc3339).map_err(|_| "helper_output_invalid")
}

fn validate_snapshot_timestamp(value: time::OffsetDateTime) -> Result<(), &'static str> {
    let age = time::OffsetDateTime::now_utc() - value;
    if age > time::Duration::seconds(SNAPSHOT_MAX_AGE.as_secs() as i64)
        || age < time::Duration::seconds(-60)
    {
        return Err("helper_output_stale");
    }
    Ok(())
}

fn validate_not_future(value: time::OffsetDateTime) -> Result<(), &'static str> {
    if value - time::OffsetDateTime::now_utc() > time::Duration::seconds(60) {
        return Err("helper_output_invalid");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = r#"{"schema":1,"capturedAt":"2026-10-26T00:00:00Z","client":"claude","sourceAvailable":{"claudeCode":true,"claudeDesktop":false},"liveOutputTps":12.5,"liveTotalTps":18.0,"estimatedShare":0.7,"modelRates":[{"client":"claudeCode","model":"claude-sonnet","outputTps":12.5,"totalTps":18.0,"generatingAgents":1,"toolsAgents":0}],"mainAgents":[{"id":"agent-0123456789abcdef01234567","client":"claudeCode","parentId":null,"phase":"generating","model":"claude-sonnet","lastActivity":"2026-10-26T00:00:00Z","liveOutputTps":12.5,"liveTotalTps":18.0,"recentSpeed":11.0}],"subagents":[],"latestResponse":null}"#;

    fn enabled() -> Vec<String> {
        vec!["claudeCode".into()]
    }

    fn codex_enabled() -> Vec<String> {
        vec!["codex".into()]
    }

    fn fresh_fixture() -> String {
        VALID.replace(
            "2026-10-26T00:00:00Z",
            &time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        )
    }

    fn fresh_codex_fixture() -> String {
        fresh_fixture()
            .replace(
                "\"claudeCode\":true",
                "\"claudeCode\":false",
            )
            .replace(
                "\"claudeDesktop\":false",
                "\"claudeDesktop\":false,\"codex\":true",
            )
            .replace("\"liveOutputTps\":12.5", "\"liveOutputTps\":8.0")
            .replace("\"liveTotalTps\":18.0", "\"liveTotalTps\":10.0")
            .replace("\"client\":\"claudeCode\",\"model\":\"claude-sonnet\"", "\"client\":\"codex\",\"model\":\"unknown\"")
            .replace("\"client\":\"claudeCode\",\"parentId\":null", "\"client\":\"codex\",\"parentId\":null")
            .replace("\"model\":\"claude-sonnet\",\"lastActivity\"", "\"model\":null,\"lastActivity\"")
            .replace(
                "\"latestResponse\":null",
                "\"latestResponse\":{\"client\":\"codex\",\"model\":null,\"outputTokens\":7,\"totalTokens\":11,\"durationMs\":3000,\"speed\":2.3,\"endedAt\":\"2026-10-26T00:00:00Z\"},\"responseEvents\":[{\"id\":\"event-0123456789abcdef01234567\",\"type\":\"responseCompleted\",\"client\":\"codex\",\"model\":null,\"outputTokens\":7,\"totalTokens\":11,\"durationMs\":3000,\"speed\":2.3,\"endedAt\":\"2026-10-26T00:00:00Z\"}]",
            )
    }

    #[test]
    fn large_valid_token_responses_do_not_discard_the_live_speed_frame() {
        let fixture = fresh_codex_fixture()
            .replace("\"outputTokens\":7", "\"outputTokens\":15000")
            .replace("\"totalTokens\":11", "\"totalTokens\":500000");
        let parsed = parse_runtime_snapshot(fixture.as_bytes(), &["codex".into()]).unwrap();
        assert_eq!(parsed.latest_response.unwrap().output_tokens, 15000);
        assert_eq!(parsed.response_events[0].total_tokens, 500000);
        let oversized = fixture.replace("\"totalTokens\":500000", "\"totalTokens\":2000000000001");
        assert!(parse_runtime_snapshot(oversized.as_bytes(), &["codex".into()]).is_err());
        let inconsistent = fixture.replace("\"totalTokens\":500000", "\"totalTokens\":100");
        assert!(parse_runtime_snapshot(inconsistent.as_bytes(), &["codex".into()]).is_err());
    }

    #[test]
    fn unavailable_snapshots_keep_selected_client_coverage_explicit() {
        let snapshot = ClaudeLocalRuntimeSnapshot::unavailable_for(
            true,
            Some("waiting_for_local_snapshot"),
            &["deepseek".into(), "gemini".into(), "opencode".into()],
        );
        for client in [
            "claudeCode",
            "claudeDesktop",
            "deepseek",
            "gemini",
            "opencode",
        ] {
            assert_eq!(snapshot.source_available.get(client), Some(&false));
        }
        assert!(snapshot.model_rates.is_empty());
    }

    #[test]
    fn canonical_windows_disk_prefix_is_not_an_unc_or_device_namespace() {
        assert!(is_verbatim_local_disk_path(r"\\?\C:\Users\local\.codex"));
        assert!(is_verbatim_local_disk_path(r"\\?\d:/Codex/sessions"));
        assert!(is_local_absolute_source_path(r"\\?\C:\Users\local\.codex"));
        assert!(is_local_absolute_source_path(r"E:/Users/local/.codex"));
        assert_eq!(source_drive_root(r"\\?\C:\Users\local"), Some("C:\\".into()));
        assert_eq!(source_drive_root(r"E:/Users/local"), Some("E:\\".into()));
        assert!(source_drive_root(r"\\server\share").is_none());
        assert!(source_drive_root(r"C:relative").is_none());
        for drive_type in [2, 3, 5, 6] {
            assert!(source_drive_type_is_local(drive_type));
        }
        for drive_type in [0, 1, 4, 99] {
            assert!(!source_drive_type_is_local(drive_type));
        }
        for path in [
            r"\\?\UNC\server\share",
            r"\\.\C:\",
            r"\\?\GLOBALROOT\Device\Harddisk0",
            r"\\server\share",
            r"\\?\C:relative",
            "//server/share",
        ] {
            assert!(!is_verbatim_local_disk_path(path), "{path}");
            assert!(!is_local_absolute_source_path(path), "{path}");
        }
        #[cfg(windows)]
        assert!(validate_local_absolute_path(std::path::Path::new(
            r"\\?\Z:\tokenbar-missing-fixture"
        ))
        .is_ok());
    }

    #[test]
    fn source_read_dispatch_is_bounded_and_never_echoes_paths() {
        let request = serde_json::json!({
            "type": "sourceRead",
            "id": 7,
            "path": r"\\server\private\session.jsonl",
            "identity": { "volume": 4, "fileId": "00112233445566778899aabbccddeeff" },
            "offset": 0,
            "count": 16,
            "probe": false
        });
        let bytes = serde_json::to_vec(&request).unwrap();
        assert!(is_source_read_request(&bytes));
        let reply = source_read_reply(&bytes, &[]).unwrap();
        assert!(reply.payload.is_empty());
        assert!(reply.header.len() <= MAX_SOURCE_READ_LINE_BYTES);
        let header = std::str::from_utf8(&reply.header).unwrap();
        assert!(!header.contains("private"));
        let response: serde_json::Value = serde_json::from_slice(header.trim().as_bytes()).unwrap();
        assert_eq!(response["type"], "sourceReadResult");
        assert_eq!(response["id"], 7);
        assert_eq!(response["count"], 0);
        assert_eq!(response["error"], "invalid_path");

        let mut oversized = request;
        oversized["path"] =
            serde_json::Value::String("C:\\".to_owned() + &"x".repeat(MAX_SOURCE_READ_LINE_BYTES));
        let bytes = serde_json::to_vec(&oversized).unwrap();
        let reply = source_read_reply(&bytes, &[]).unwrap();
        let response: serde_json::Value = serde_json::from_slice(
            std::str::from_utf8(&reply.header)
                .unwrap()
                .trim()
                .as_bytes(),
        )
        .unwrap();
        assert_eq!(response["error"], "invalid_request");
        assert!(!std::str::from_utf8(&reply.header).unwrap().contains("xxxx"));
    }

    #[test]
    fn reporter_read_roots_cover_selected_non_claude_roots_and_codex_archives() {
        let codex_home = std::env::temp_dir().join("tokenbar-source-read-codex-home");
        let deepseek = std::env::temp_dir().join("tokenbar-source-read-deepseek");
        let gemini = std::env::temp_dir().join("tokenbar-source-read-gemini");
        let opencode = std::env::temp_dir().join("tokenbar-source-read-opencode");
        let roots = reporting_source_read_roots(
            &codex_home,
            &BTreeMap::from([
                (
                    "deepseek".to_owned(),
                    deepseek.to_string_lossy().into_owned(),
                ),
                ("gemini".to_owned(), gemini.to_string_lossy().into_owned()),
                (
                    "opencode".to_owned(),
                    opencode.to_string_lossy().into_owned(),
                ),
            ]),
        );
        for expected in [
            codex_home.join("sessions"),
            codex_home.join("archived_sessions"),
            deepseek,
            gemini,
            opencode,
        ] {
            assert!(
                roots.contains(&expected),
                "missing reporter source root: {expected:?}"
            );
        }
        assert!(roots
            .iter()
            .all(|root| !root.to_string_lossy().contains(".claude")));
    }

    #[test]
    fn other_clients_have_independent_explicit_local_roots() {
        let home = std::env::temp_dir().join("tokenbar-fixture-home");
        let preferences = vec![
            EnabledClaudePreference {
                client: "deepseek".into(),
                path: home.join("dsh").to_string_lossy().into(),
            },
            EnabledClaudePreference {
                client: "gemini".into(),
                path: home.join("gemini").to_string_lossy().into(),
            },
            EnabledClaudePreference {
                client: "opencode".into(),
                path: home
                    .join("opencode")
                    .join("opencode.db")
                    .to_string_lossy()
                    .into(),
            },
        ];
        let (key, roots) = runtime_configuration(&preferences, None).unwrap().unwrap();
        assert_eq!(key.enabled_clients, vec!["deepseek", "gemini", "opencode"]);
        assert!(roots.claude_root.is_none());
        assert_eq!(
            roots.other_roots.get("opencode"),
            Some(&home.join("opencode"))
        );
        assert_eq!(key.other_roots.len(), 3);
        assert!(other_client_root("gemini", "//server/share").is_err());
    }

    #[test]
    fn parses_only_enabled_claude_sources_and_exposes_safe_projection() {
        let parsed = parse_runtime_snapshot(fresh_fixture().as_bytes(), &enabled()).unwrap();
        assert!(parsed.enabled);
        assert_eq!(parsed.model_rates[0].client, "claudeCode");
        assert_eq!(parsed.source_available.get("claudeDesktop"), Some(&false));
        assert_eq!(parsed.main_agents[0].id, "agent-0123456789abcdef01234567");
    }

    #[test]
    fn parses_opt_in_codex_activity_without_losing_unknown_models_or_safe_events() {
        let parsed =
            parse_runtime_snapshot(fresh_codex_fixture().as_bytes(), &codex_enabled()).unwrap();
        assert_eq!(parsed.source_available.get("codex"), Some(&true));
        assert_eq!(parsed.model_rates.len(), 1);
        assert_eq!(parsed.model_rates[0].client, "codex");
        assert_eq!(parsed.model_rates[0].model, "unknown");
        assert_eq!(parsed.main_agents[0].client, "codex");
        assert_eq!(parsed.main_agents[0].model, None);
        assert_eq!(parsed.latest_response.as_ref().unwrap().client, "codex");
        assert_eq!(parsed.response_events.len(), 1);
        assert_eq!(parsed.response_events[0].client, "codex");
        assert_eq!(parsed.response_events[0].r#type, "responseCompleted");
        assert!(parsed.response_events[0].id.starts_with("event-"));
    }

    #[test]
    fn rejects_unbounded_response_event_frames() {
        let mut fixture: serde_json::Value = serde_json::from_str(&fresh_codex_fixture()).unwrap();
        let event = fixture["responseEvents"][0].clone();
        fixture["responseEvents"] = serde_json::Value::Array(vec![event; MAX_RESPONSE_EVENTS + 1]);
        let bytes = serde_json::to_vec(&fixture).unwrap();
        assert_eq!(
            parse_runtime_snapshot(&bytes, &codex_enabled()).unwrap_err(),
            "helper_output_invalid"
        );
    }

    #[test]
    fn rejects_codex_runtime_data_when_the_display_mode_did_not_select_it() {
        assert_eq!(
            parse_runtime_snapshot(fresh_codex_fixture().as_bytes(), &enabled()).unwrap_err(),
            "helper_source_mismatch"
        );
    }

    #[test]
    fn rejects_cross_source_attribution_and_disabled_source_data() {
        let desktop = fresh_fixture().replace(
            "\"claudeCode\",\"model\":\"claude-sonnet\"",
            "\"claudeDesktop\",\"model\":\"claude-sonnet\"",
        );
        assert_eq!(
            parse_runtime_snapshot(desktop.as_bytes(), &enabled()).unwrap_err(),
            "helper_source_mismatch"
        );
        let enabled_wrong = vec!["claudeDesktop".to_string()];
        assert!(parse_runtime_snapshot(fresh_fixture().as_bytes(), &enabled_wrong).is_err());
    }

    #[test]
    fn drops_cross_client_parent_links() {
        let fixture = fresh_fixture()
            .replace("\"claudeDesktop\":false", "\"claudeDesktop\":true")
            .replace(
                "\"subagents\":[]",
                "\"subagents\":[{\"id\":\"agent-1123456789abcdef01234567\",\"client\":\"claudeDesktop\",\"parentId\":\"agent-0123456789abcdef01234567\",\"phase\":\"generating\",\"model\":null,\"lastActivity\":\"2026-10-26T00:00:00Z\",\"liveOutputTps\":1.0,\"liveTotalTps\":1.0,\"recentSpeed\":null}]",
            );
        let enabled = vec!["claudeCode".into(), "claudeDesktop".into()];
        let parsed = parse_runtime_snapshot(fixture.as_bytes(), &enabled).unwrap();
        assert_eq!(parsed.subagents[0].parent_id, None);
    }

    #[test]
    fn rejects_stale_snapshots_unknown_fields_bad_ids_and_phases() {
        let stale = VALID.replace("2026-10-26T00:00:00Z", "2000-01-01T00:00:00Z");
        assert_eq!(
            parse_runtime_snapshot(stale.as_bytes(), &enabled()).unwrap_err(),
            "helper_output_stale"
        );
        let private = fresh_fixture().replace(
            "\"client\":\"claude\"",
            "\"client\":\"claude\",\"cwd\":\"private\"",
        );
        assert!(parse_runtime_snapshot(private.as_bytes(), &enabled()).is_err());
        let bad_id =
            fresh_fixture().replace("agent-0123456789abcdef01234567", "raw-project-session-id");
        assert!(parse_runtime_snapshot(bad_id.as_bytes(), &enabled()).is_err());
        let bad_phase = fresh_fixture().replace("generating", "unknown-phase");
        assert!(parse_runtime_snapshot(bad_phase.as_bytes(), &enabled()).is_err());
        let bad_event_id =
            fresh_codex_fixture().replace("event-0123456789abcdef01234567", "private-session-id");
        assert!(parse_runtime_snapshot(bad_event_id.as_bytes(), &codex_enabled()).is_err());
    }

    #[test]
    fn rejects_nonfinite_or_oversized_numeric_values_and_lines() {
        let nonfinite = fresh_fixture().replace("12.5", "1e999");
        assert!(parse_runtime_snapshot(nonfinite.as_bytes(), &enabled()).is_err());
        assert_eq!(
            parse_runtime_snapshot(&vec![b' '; MAX_RUNTIME_LINE_BYTES + 1], &enabled())
                .unwrap_err(),
            "helper_output_too_large"
        );
        assert!(validate_rate(f64::INFINITY).is_err());
    }

    #[test]
    fn filters_idle_agents_older_than_five_minutes() {
        let now = time::OffsetDateTime::now_utc();
        let stale_idle = now - time::Duration::minutes(6);
        let fixture = fresh_fixture()
            .replace("\"subagents\":[]", &format!("\"subagents\":[{{\"id\":\"agent-1123456789abcdef01234567\",\"client\":\"claudeCode\",\"parentId\":null,\"phase\":\"idle\",\"model\":null,\"lastActivity\":\"{}\",\"liveOutputTps\":0.0,\"liveTotalTps\":0.0,\"recentSpeed\":null}}]", stale_idle.format(&time::format_description::well_known::Rfc3339).unwrap()));
        let parsed = parse_runtime_snapshot(fixture.as_bytes(), &enabled()).unwrap();
        assert!(parsed.subagents.is_empty());
    }

    #[test]
    fn rejects_network_or_relative_roots() {
        assert!(
            validate_local_absolute_path(std::path::Path::new("//server/share/claude")).is_err()
        );
        assert!(validate_local_absolute_path(std::path::Path::new("relative/claude")).is_err());
    }

    #[test]
    fn disabling_saved_sources_clears_runtime_retry_state() {
        let registry = ClaudeLocalRuntimeRegistry::default();
        {
            let mut state = registry.lock_state();
            state.failed_config = Some(RuntimeConfigKey {
                claude_root: Some("c:\\users\\example\\.claude\\projects".into()),
                codex_root: None,
                other_roots: BTreeMap::new(),
                enabled_clients: vec!["claudeCode".into()],
            });
            state.retry_after = Some(Instant::now() + Duration::from_secs(60));
        }
        registry.reconcile_preferences(&[]);
        let state = registry.lock_state();
        assert!(state.failed_config.is_none());
        assert!(state.retry_after.is_none());
        assert!(state.worker.is_none());
    }

    #[test]
    fn disabling_global_live_rate_stops_registry_without_waiting_for_a_read() {
        let registry = ClaudeLocalRuntimeRegistry::default();
        {
            let mut state = registry.lock_state();
            state.failed_config = Some(RuntimeConfigKey {
                claude_root: Some("c:\\users\\example\\.claude\\projects".into()),
                codex_root: None,
                other_roots: BTreeMap::new(),
                enabled_clients: vec!["claudeCode".into()],
            });
            state.retry_after = Some(Instant::now() + Duration::from_secs(60));
        }
        registry.set_live_rate_enabled(false);
        let state = registry.lock_state();
        assert!(state.failed_config.is_none());
        assert!(state.retry_after.is_none());
        assert!(state.worker.is_none());
    }

    #[test]
    fn saved_preference_reconciliation_keys_only_enabled_clients_and_roots() {
        let root = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("claude-runtime-fixture")
            .to_string_lossy()
            .into_owned();
        let mut preferences = crate::core::multi_client_usage::default_preferences();
        for preference in &mut preferences {
            if matches!(preference.client.as_str(), "claudeCode" | "claudeDesktop") {
                preference.enabled = true;
                preference.path = root.clone();
            }
        }
        let first = runtime_configuration(&enabled_claude_preferences(&preferences), None)
            .unwrap()
            .unwrap()
            .0;

        let mut cosmetic_edit = preferences.clone();
        cosmetic_edit.reverse();
        for preference in &mut cosmetic_edit {
            preference.color = "#123456".into();
            preference.order = preference.order.saturating_add(10);
            preference.style = "detailed".into();
        }
        let same_configuration =
            runtime_configuration(&enabled_claude_preferences(&cosmetic_edit), None)
                .unwrap()
                .unwrap()
                .0;
        assert_eq!(first, same_configuration);

        let code = preferences
            .iter_mut()
            .find(|preference| preference.client == "claudeCode")
            .unwrap();
        code.path = format!("{root}-changed");
        assert!(runtime_configuration(&enabled_claude_preferences(&preferences), None).is_err());

        for preference in &mut preferences {
            preference.enabled = false;
        }
        assert!(
            runtime_configuration(&enabled_claude_preferences(&preferences), None)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn selected_codex_home_uses_global_live_rate_not_strip_display_mode() {
        let default_settings: crate::models::AppSettingsSnapshot =
            serde_json::from_str("{}").unwrap();
        assert_eq!(default_settings.display_surfaces.speed_display_mode, "bar");
        let bar_settings: crate::models::AppSettingsSnapshot = serde_json::from_str(
            r#"{"displaySurfaces":{"liveRateEnabled":true,"speedDisplayMode":"bar"}}"#,
        )
        .unwrap();
        assert!(codex_local_activity_enabled(
            bar_settings.display_surfaces.live_rate_enabled
        ));
        assert_eq!(bar_settings.display_surfaces.speed_display_mode, "bar");
        let disabled_settings: crate::models::AppSettingsSnapshot = serde_json::from_str(
            r#"{"displaySurfaces":{"liveRateEnabled":false,"speedDisplayMode":"agentSpeed"}}"#,
        )
        .unwrap();
        assert!(!codex_local_activity_enabled(
            disabled_settings.display_surfaces.live_rate_enabled
        ));

        let selected_home = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("selected-codex-home")
            .join("sessions");
        let (key, roots) = runtime_configuration(&[], Some(selected_home.clone()))
            .unwrap()
            .unwrap();
        assert_eq!(key.enabled_clients, vec!["codex"]);
        assert!(key.claude_root.is_none());
        assert_eq!(roots.codex_root, Some(selected_home));
        assert!(runtime_configuration(&[], None).unwrap().is_none());

        let claude_preferences = vec![EnabledClaudePreference {
            client: "claudeCode".into(),
            path: std::env::current_exe()
                .unwrap()
                .parent()
                .unwrap()
                .join("separate-claude-projects")
                .display()
                .to_string(),
        }];
        let separate_codex_home = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("another-codex-home")
            .join("sessions");
        let (combined_key, combined_roots) =
            runtime_configuration(&claude_preferences, Some(separate_codex_home.clone()))
                .unwrap()
                .unwrap();
        assert_eq!(
            combined_key.enabled_clients,
            vec!["claudeCode".to_owned(), "codex".to_owned()]
        );
        assert_ne!(combined_key.claude_root, combined_key.codex_root);
        assert_eq!(combined_roots.codex_root, Some(separate_codex_home));
    }

    #[test]
    fn codex_activity_source_identity_uses_the_home_for_unix_and_windows_paths() {
        for (sessions, home) in [
            ("/Users/example/.codex/sessions", "/Users/example/.codex"),
            (r"C:\Users\example\.codex\sessions", r"C:\Users\example\.codex"),
        ] {
            assert_eq!(codex_activity_root(sessions), home);
            assert_eq!(
                crate::core::activity_speed_capture::root_identity(codex_activity_root(sessions)),
                crate::core::activity_speed_capture::root_identity(home)
            );
        }
        assert_eq!(codex_activity_root("/Users/example/.codex/other"), "/Users/example/.codex/other");
    }
}
