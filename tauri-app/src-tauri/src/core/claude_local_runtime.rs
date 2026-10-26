use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const CLAUDE_CLIENTS: [&str; 2] = ["claudeCode", "claudeDesktop"];
const MAX_RUNTIME_LINE_BYTES: usize = 256 * 1024;
const MAX_COUNTER: u64 = 10_000;
const MAX_RATE: f64 = 1_000_000_000.0;
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
    pub configuration_issue: Option<String>,
}

impl ClaudeLocalRuntimeSnapshot {
    fn unavailable(enabled: bool, issue: Option<&str>) -> Self {
        Self {
            enabled,
            source_available: CLAUDE_CLIENTS
                .into_iter()
                .map(|client| (client.to_string(), false))
                .collect(),
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
    root: String,
    enabled_clients: Vec<String>,
}

struct RuntimeWorker {
    key: RuntimeConfigKey,
    child: std::process::Child,
    stdin: Option<std::process::ChildStdin>,
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
        if !settings.display_surfaces.live_rate_enabled {
            self.stop_worker();
            return ClaudeLocalRuntimeSnapshot::unavailable(false, None);
        }

        let preferences = match read_enabled_claude_preferences() {
            Ok(preferences) => preferences,
            Err(issue) => {
                self.stop_worker();
                return ClaudeLocalRuntimeSnapshot::unavailable(false, Some(issue));
            }
        };
        let enabled_clients = preferences
            .iter()
            .map(|preference| preference.client.clone())
            .collect::<Vec<_>>();
        if enabled_clients.is_empty() {
            self.stop_worker();
            return ClaudeLocalRuntimeSnapshot::unavailable(false, None);
        }

        let root = match shared_local_root(&preferences) {
            Ok(root) => root,
            Err(issue) => {
                self.stop_worker();
                return ClaudeLocalRuntimeSnapshot::unavailable(true, Some(issue));
            }
        };
        let key = RuntimeConfigKey {
            root: normalized_path_key(&root),
            enabled_clients: enabled_clients.clone(),
        };
        let helper = match packaged_helper_path(app) {
            Ok(helper) => helper,
            Err(issue) => {
                self.stop_worker();
                return ClaudeLocalRuntimeSnapshot::unavailable(true, Some(issue));
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
                match start_worker(helper, root, key.clone(), enabled_clients) {
                    Ok(worker) => {
                        state.worker = Some(worker);
                        state.failed_config = None;
                        state.retry_after = None;
                    }
                    Err(_) => {
                        state.failed_config = Some(key);
                        state.retry_after = Some(Instant::now() + Duration::from_secs(5));
                        return ClaudeLocalRuntimeSnapshot::unavailable(
                            true,
                            Some("helper_start_failed"),
                        );
                    }
                }
            }
        }

        let Some(worker) = state.worker.as_ref() else {
            return ClaudeLocalRuntimeSnapshot::unavailable(true, Some("helper_unavailable"));
        };
        let Ok(frame) = worker.frame.lock() else {
            return ClaudeLocalRuntimeSnapshot::unavailable(true, Some("helper_output_invalid"));
        };
        let Some(received_at) = frame.received_at else {
            return ClaudeLocalRuntimeSnapshot::unavailable(
                true,
                frame.issue.or(Some("waiting_for_local_snapshot")),
            );
        };
        if received_at.elapsed() > SNAPSHOT_MAX_AGE {
            return ClaudeLocalRuntimeSnapshot::unavailable(true, Some("helper_output_stale"));
        }
        match frame.snapshot.clone() {
            Some(mut snapshot) => {
                snapshot.enabled = true;
                snapshot.configuration_issue = None;
                snapshot
            }
            None => ClaudeLocalRuntimeSnapshot::unavailable(
                true,
                frame.issue.or(Some("helper_output_invalid")),
            ),
        }
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
        let next_key = runtime_configuration(&enabled)
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
            CLAUDE_CLIENTS.contains(&preference.client.as_str()) && preference.enabled
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
        if !CLAUDE_CLIENTS.contains(&preference.client.as_str()) || !preference.enabled {
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
) -> Result<Option<(RuntimeConfigKey, std::path::PathBuf)>, &'static str> {
    if preferences.is_empty() {
        return Ok(None);
    }
    let root = shared_local_root(preferences)?;
    let mut enabled_clients = preferences
        .iter()
        .map(|preference| preference.client.clone())
        .collect::<Vec<_>>();
    enabled_clients.sort();
    let key = RuntimeConfigKey {
        root: normalized_path_key(&root),
        enabled_clients,
    };
    Ok(Some((key, root)))
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

fn validate_local_absolute_path(path: &std::path::Path) -> Result<(), &'static str> {
    let text = path.to_string_lossy();
    let unc = text.starts_with("\\\\") || text.starts_with("//");
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
    root: std::path::PathBuf,
    key: RuntimeConfigKey,
    enabled_clients: Vec<String>,
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
    let mut command = Command::new(helper);
    command
        .arg("--watch")
        .arg("--root")
        .arg(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    // Keep process startup deterministic and prevent forwarding unrelated credential variables.
    command.env_clear();
    for key in HELPER_ENV_ALLOWLIST {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    for client in &enabled_clients {
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
    let frame = Arc::new(Mutex::new(RuntimeFrame::default()));
    let reader_frame = frame.clone();
    let client_allowlist = enabled_clients.clone();
    let reader_thread = thread::Builder::new()
        .name("claude-local-runtime-reader".into())
        .spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_bounded_line(&mut reader) {
                    Ok(Some(Ok(bytes))) => {
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
        stdin: Some(stdin),
        frame,
    })
}

fn stop_worker(mut worker: Option<RuntimeWorker>) {
    use std::{thread, time::Duration};
    let Some(mut worker) = worker.take() else {
        return;
    };
    drop(worker.stdin.take());
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
    let captured = parse_timestamp(&wire.captured_at)?;
    validate_snapshot_timestamp(captured)?;
    if wire.source_available.len() != CLAUDE_CLIENTS.len()
        || CLAUDE_CLIENTS
            .iter()
            .any(|client| !wire.source_available.contains_key(*client))
        || wire
            .source_available
            .keys()
            .any(|client| !CLAUDE_CLIENTS.contains(&client.as_str()))
    {
        return Err("helper_output_invalid");
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
            if response.output_tokens > MAX_COUNTER
                || response.total_tokens > MAX_COUNTER
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
    if !CLAUDE_CLIENTS.contains(&client)
        || !enabled_clients.iter().any(|enabled| enabled == client)
        || source_available.get(client) != Some(&true)
    {
        return Err("helper_source_mismatch");
    }
    Ok(())
}

fn validate_safe_id(value: &str) -> Result<(), &'static str> {
    let Some(suffix) = value.strip_prefix("agent-") else {
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

    fn fresh_fixture() -> String {
        VALID.replace(
            "2026-10-26T00:00:00Z",
            &time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        )
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
                root: "c:\\users\\example\\.claude\\projects".into(),
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
                root: "c:\\users\\example\\.claude\\projects".into(),
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
        let first = runtime_configuration(&enabled_claude_preferences(&preferences))
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
        let same_configuration = runtime_configuration(&enabled_claude_preferences(&cosmetic_edit))
            .unwrap()
            .unwrap()
            .0;
        assert_eq!(first, same_configuration);

        let code = preferences
            .iter_mut()
            .find(|preference| preference.client == "claudeCode")
            .unwrap();
        code.path = format!("{root}-changed");
        assert!(runtime_configuration(&enabled_claude_preferences(&preferences)).is_err());

        for preference in &mut preferences {
            preference.enabled = false;
        }
        assert!(
            runtime_configuration(&enabled_claude_preferences(&preferences))
                .unwrap()
                .is_none()
        );
    }
}
