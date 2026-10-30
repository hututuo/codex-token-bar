use crate::models::{AgentSpeedReportingSettingsSnapshot, AgentSpeedReportingTransport};
use serde::{Deserialize, Serialize};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
#[cfg(windows)]
use tauri::Manager as _;

#[cfg(windows)]
use std::{io, os::windows::process::CommandExt, process::Stdio, time::Duration};
#[cfg(windows)]
use tokio::{
    io::{AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, Command},
    sync::{watch, Mutex as AsyncMutex},
};

const STATUS_LINE_LIMIT: usize = 4096;
const MAX_TPS: f64 = 1_000_000_000.0;
const REPORTER_DENIED_SOURCE_IDS: &[&str] = &["claudeCode", "claudeDesktop"];
const REPORTING_RETRY_BACKOFF_SECONDS: [u64; 7] = [5, 10, 20, 40, 80, 160, 300];

fn reporting_retry_delay_seconds(attempt: u32, retry_after_seconds: Option<u64>) -> u64 {
    let index = attempt
        .saturating_sub(1)
        .min((REPORTING_RETRY_BACKOFF_SECONDS.len() - 1) as u32) as usize;
    let backoff = REPORTING_RETRY_BACKOFF_SECONDS[index];
    retry_after_seconds
        .map(|seconds| backoff.max(seconds.clamp(5, 86_400)))
        .unwrap_or(backoff)
}

fn helper_failure_is_retryable(message_code: Option<&str>) -> bool {
    matches!(message_code, None | Some("service_unavailable"))
}

fn reporter_start_payload(
    username: &str,
    local_roots: &std::collections::BTreeMap<String, String>,
) -> serde_json::Value {
    let mut payload = serde_json::json!({
        "enabled": true,
        "username": username,
        "deniedSourceIds": REPORTER_DENIED_SOURCE_IDS,
    });
    if !local_roots.is_empty() {
        payload["localSourceRoots"] = serde_json::json!(local_roots);
    }
    payload
}

const DISPLAY_STATUS_LINE_LIMIT: usize = 65_536;
const DISPLAY_STALE_AFTER_MS: i64 = 2_000;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentSpeedDisplayRate {
    pub model: String,
    pub tokens_per_second: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentSpeedDisplaySnapshot {
    pub available: bool,
    pub tokens_per_second: f64,
    pub model_rates: Vec<AgentSpeedDisplayRate>,
    pub client_rates: Vec<AgentSpeedDisplayRate>,
    pub status: String,
    pub updated_at_ms: i64,
}

impl AgentSpeedDisplaySnapshot {
    fn empty(status: &str, available: bool) -> Self {
        Self {
            available,
            tokens_per_second: 0.0,
            model_rates: Vec::new(),
            client_rates: Vec::new(),
            status: status.into(),
            updated_at_ms: current_time_ms(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentSpeedSourceStatus {
    pub id: String,
    pub name: String,
    pub tps: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentSpeedReportingStatus {
    pub enabled: bool,
    pub invitation_handled: bool,
    pub username: String,
    pub transport: AgentSpeedReportingTransport,
    pub phase: String,
    #[serde(rename = "message")]
    pub status_message: String,
    pub live_output_tps: f64,
    pub estimated_share: f64,
    pub last_report_at: Option<String>,
    pub sources: Vec<AgentSpeedSourceStatus>,
    pub profile_url: Option<String>,
}

impl AgentSpeedReportingStatus {
    fn from_settings(settings: &AgentSpeedReportingSettingsSnapshot) -> Self {
        Self {
            enabled: settings.enabled,
            invitation_handled: settings.invitation_handled,
            username: settings.username.clone(),
            transport: settings.transport,
            phase: if settings.enabled { "starting" } else { "off" }.into(),
            status_message: if settings.enabled {
                "正在启动实时速度上报".into()
            } else {
                "未开启".into()
            },
            live_output_tps: 0.0,
            estimated_share: 0.0,
            last_report_at: None,
            sources: Vec::new(),
            profile_url: None,
        }
    }
}

#[derive(Default)]
struct RegistryData {
    status: Option<AgentSpeedReportingStatus>,
    active_username: Option<String>,
    #[cfg(windows)]
    active_codex_home: Option<std::path::PathBuf>,
    #[cfg(windows)]
    active_local_source_roots: std::collections::BTreeMap<String, String>,
    active_transport: Option<AgentSpeedReportingTransport>,
    active_local_display: bool,
    active_reporting: bool,
    display_snapshot: Option<AgentSpeedDisplaySnapshot>,
    retry_attempt: u32,
    #[cfg(any(windows, test))]
    generation: u64,
}

#[cfg(any(windows, test))]
fn status_writer_is_current(data: &RegistryData, generation: u64, username: &str) -> bool {
    data.generation == generation && data.active_username.as_deref() == Some(username)
}

#[derive(Clone, Default)]
pub struct AgentSpeedReportingRegistry {
    data: Arc<Mutex<RegistryData>>,
    #[cfg(windows)]
    child: Arc<Mutex<Option<Child>>>,
    #[cfg(windows)]
    stdin: Arc<AsyncMutex<Option<ChildStdin>>>,
    #[cfg(windows)]
    transition: Arc<AsyncMutex<()>>,
    #[cfg(windows)]
    retry_cancel: Arc<Mutex<Option<watch::Sender<bool>>>>,
}

impl AgentSpeedReportingRegistry {
    pub fn read_status(
        &self,
        settings: &AgentSpeedReportingSettingsSnapshot,
    ) -> AgentSpeedReportingStatus {
        if !settings.enabled {
            return AgentSpeedReportingStatus::from_settings(settings);
        }

        #[cfg(windows)]
        self.mark_exited_child();

        let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        let mut status = data
            .status
            .take()
            .unwrap_or_else(|| AgentSpeedReportingStatus::from_settings(settings));
        status.enabled = settings.enabled;
        status.invitation_handled = settings.invitation_handled;
        status.username = settings.username.clone();
        status.transport = settings.transport;
        data.status = Some(status.clone());
        status
    }

    pub fn read_display_snapshot(&self) -> AgentSpeedDisplaySnapshot {
        let data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        if !data.active_local_display {
            return AgentSpeedDisplaySnapshot::empty("stale", false);
        }

        let Some(snapshot) = data.display_snapshot.clone() else {
            return AgentSpeedDisplaySnapshot::empty("starting", false);
        };
        let age = current_time_ms().saturating_sub(snapshot.updated_at_ms);
        if age > DISPLAY_STALE_AFTER_MS && snapshot.available {
            return AgentSpeedDisplaySnapshot::empty("stale", false);
        }
        snapshot
    }

    pub fn initialize_error(&self, settings: &AgentSpeedReportingSettingsSnapshot, code: &str) {
        self.set_error_status(settings, code);
    }

    pub fn dismiss_status(&self) -> AgentSpeedReportingStatus {
        let data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        data.status
            .clone()
            .unwrap_or_else(|| AgentSpeedReportingStatus {
                enabled: false,
                invitation_handled: true,
                username: String::new(),
                transport: AgentSpeedReportingTransport::Http,
                phase: "off".into(),
                status_message: "未开启".into(),
                live_output_tps: 0.0,
                estimated_share: 0.0,
                last_report_at: None,
                sources: Vec::new(),
                profile_url: None,
            })
    }

    pub fn start<'a>(
        &'a self,
        app: &'a tauri::AppHandle,
        settings: &'a AgentSpeedReportingSettingsSnapshot,
        local_display: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), String>> + Send + 'a>> {
        Box::pin(self.start_inner(app, settings, local_display))
    }

    async fn start_inner<'a>(
        &'a self,
        app: &'a tauri::AppHandle,
        settings: &'a AgentSpeedReportingSettingsSnapshot,
        local_display: bool,
    ) -> Result<(), String> {
        if !settings.enabled && !local_display {
            #[cfg(windows)]
            {
                let _transition = self.transition.lock().await;
                self.invalidate_generation();
                self.stop_process().await;
            }
            let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
            data.active_username = None;
            data.active_reporting = false;
            data.active_local_display = false;
            data.retry_attempt = 0;
            data.display_snapshot = Some(AgentSpeedDisplaySnapshot::empty("disabled", false));
            data.status = Some(AgentSpeedReportingStatus::from_settings(settings));
            #[cfg(windows)]
            {
                data.active_transport = None;
            }
            return Ok(());
        }

        #[cfg(not(windows))]
        {
            let _ = app;
            if settings.enabled {
                self.set_error_status(settings, "windows_only");
                Err("Agent Speed reporting is available on Windows only.".into())
            } else {
                let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
                data.active_local_display = false;
                data.display_snapshot =
                    Some(AgentSpeedDisplaySnapshot::empty("unsupported", false));
                Ok(())
            }
        }

        #[cfg(windows)]
        {
            let _transition = self.transition.lock().await;
            let username = if settings.enabled {
                match safe_username(&settings.username) {
                    Ok(username) => username,
                    Err(error) => {
                        self.set_error_status(settings, "username_invalid");
                        return Err(error);
                    }
                }
            } else {
                String::new()
            };
            let codex_home =
                std::path::PathBuf::from(crate::platform::default_codex_home_status().path);
            let local_source_roots =
                match crate::core::claude_local_runtime::selected_reporting_local_roots() {
                    Ok(roots) => roots,
                    Err(_) => {
                        self.invalidate_generation();
                        self.stop_process().await;
                        self.set_error_status(settings, "local_source_unavailable");
                        return Err("Local activity source configuration is unavailable.".into());
                    }
                };
            if self.child_is_running_for(
                &username,
                &codex_home,
                &local_source_roots,
                settings.transport,
                settings.enabled,
                local_display,
            ) {
                return Ok(());
            }
            let source_read_roots = crate::core::claude_local_runtime::reporting_source_read_roots(
                &codex_home,
                &local_source_roots,
            );

            self.invalidate_generation();
            self.stop_process().await;
            if settings.enabled {
                self.set_phase(settings, "starting", "正在启动实时速度上报");
            }
            let helper = helper_path(app).map_err(|_| {
                if settings.enabled {
                    self.set_error_status(settings, "helper_unavailable");
                }
                if local_display {
                    self.set_display_snapshot(AgentSpeedDisplaySnapshot::empty("error", false));
                }
                "Agent Speed reporter helper is unavailable.".to_owned()
            })?;

            let mut command = Command::new(helper);
            command
                .kill_on_drop(true)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .env_clear();
            copy_safe_environment(&mut command, &username);
            // The app-selected home wins over an unrelated parent-process CODEX_HOME.
            command.env("CODEX_HOME", &codex_home);
            if let Some(profile) = std::env::var_os("USERPROFILE") {
                command.current_dir(profile);
            }
            command.as_std_mut().creation_flags(0x08000000); // CREATE_NO_WINDOW.

            let mut child = command.spawn().map_err(|_| {
                self.set_error_status(settings, "helper_unavailable");
                "Agent Speed reporter helper could not start.".to_owned()
            })?;
            let mut child_stdin = child.stdin.take().ok_or_else(|| {
                self.set_error_status(settings, "helper_unavailable");
                "Agent Speed reporter helper could not start.".to_owned()
            })?;
            let child_stdout = child.stdout.take().ok_or_else(|| {
                self.set_error_status(settings, "helper_unavailable");
                "Agent Speed reporter helper could not start.".to_owned()
            })?;

            let mut startup = if settings.enabled {
                serde_json::json!({
                    "enabled": true,
                    "localDisplay": local_display,
                    "username": username.clone(),
                    "transport": settings.transport.as_str(),
                })
            } else {
                serde_json::json!({"enabled": false, "localDisplay": true})
            };
            startup["deniedSourceIds"] = serde_json::json!(REPORTER_DENIED_SOURCE_IDS);
            if !local_source_roots.is_empty() {
                startup["localSourceRoots"] = serde_json::json!(local_source_roots);
            }
            let mut line = serde_json::to_vec(&startup)
                .map_err(|_| "Agent Speed reporter helper could not start.".to_owned())?;
            if line.len() >= STATUS_LINE_LIMIT {
                return Err(
                    "Local activity source configuration exceeds the startup limit.".into(),
                );
            }
            line.push(b'\n');
            child_stdin.write_all(&line).await.map_err(|_| {
                self.set_error_status(settings, "helper_unavailable");
                "Agent Speed reporter helper could not start.".to_owned()
            })?;
            child_stdin.flush().await.map_err(|_| {
                self.set_error_status(settings, "helper_unavailable");
                "Agent Speed reporter helper could not start.".to_owned()
            })?;

            {
                let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
                data.active_username = Some(username.clone());
                data.active_codex_home = Some(codex_home);
                data.active_local_source_roots = local_source_roots;
                data.active_transport = Some(settings.transport);
                data.active_reporting = settings.enabled;
                data.active_local_display = local_display;
                data.display_snapshot = Some(if local_display {
                    AgentSpeedDisplaySnapshot::empty("starting", false)
                } else {
                    AgentSpeedDisplaySnapshot::empty("disabled", false)
                });
                if settings.enabled {
                    data.status = Some(AgentSpeedReportingStatus::from_settings(settings));
                }
            }
            *self.stdin.lock().await = Some(child_stdin);
            *self.child.lock().unwrap_or_else(|error| error.into_inner()) = Some(child);
            let (retry_cancel_tx, mut retry_cancel_rx) = watch::channel(false);
            *self
                .retry_cancel
                .lock()
                .unwrap_or_else(|error| error.into_inner()) = Some(retry_cancel_tx);

            let data = Arc::clone(&self.data);
            let status_username = username.clone();
            let status_stdin = Arc::clone(&self.stdin);
            let status_transport = settings.transport;
            let reporting_enabled = settings.enabled;
            let display_enabled = local_display;
            let retry_registry = self.clone();
            let retry_app = app.clone();
            let retry_settings = settings.clone();
            let generation = self
                .data
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .generation;
            tauri::async_runtime::spawn(async move {
                let failure_code = read_helper_status(
                    child_stdout,
                    data,
                    status_stdin,
                    source_read_roots,
                    status_username,
                    status_transport,
                    reporting_enabled,
                    display_enabled,
                    generation,
                )
                .await;
                if !reporting_enabled || !helper_failure_is_retryable(failure_code.as_deref()) {
                    return;
                }

                let Some(delay) = retry_registry.next_retry_delay(generation, None) else {
                    return;
                };
                if !retry_registry.reap_helper_for_retry(generation).await {
                    return;
                }

                // The existing Tokio feature set has time/sync, not macros.
                // Any cancellation-channel change invalidates this retry owner.
                if tokio::time::timeout(delay, retry_cancel_rx.changed())
                    .await
                    .is_ok()
                {
                    return;
                }
                if !retry_registry.generation_is_current(generation) {
                    return;
                }

                if let Err(error) = retry_registry
                    .start(&retry_app, &retry_settings, display_enabled)
                    .await
                {
                    eprintln!(
                        "Codex Token Bar: Agent Speed reporter retry could not start: {error}"
                    );
                }
            });
            Ok(())
        }
    }

    pub async fn stop(&self) -> Result<(), String> {
        #[cfg(windows)]
        {
            let _transition = self.transition.lock().await;
            self.invalidate_generation();
            self.stop_process().await;
        }

        let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        data.active_username = None;
        data.active_reporting = false;
        data.active_local_display = false;
        data.retry_attempt = 0;
        data.display_snapshot = Some(AgentSpeedDisplaySnapshot::empty("disabled", false));
        #[cfg(windows)]
        {
            data.active_transport = None;
        }
        let transport = data
            .status
            .as_ref()
            .map(|status| status.transport)
            .unwrap_or(AgentSpeedReportingTransport::Http);
        data.status = Some(AgentSpeedReportingStatus {
            enabled: false,
            invitation_handled: true,
            username: data
                .status
                .as_ref()
                .map(|status| status.username.clone())
                .unwrap_or_default(),
            transport,
            phase: "off".into(),
            status_message: "未开启".into(),
            live_output_tps: 0.0,
            estimated_share: 0.0,
            last_report_at: None,
            sources: Vec::new(),
            profile_url: None,
        });
        Ok(())
    }

    pub fn shutdown_now(&self) {
        #[cfg(windows)]
        {
            self.invalidate_generation();
            if let Ok(mut stdin) = self.stdin.try_lock() {
                let _ = stdin.take(); // EOF is the helper's cancellation signal.
            }
            if let Ok(mut child) = self.child.lock() {
                if let Some(mut child) = child.take() {
                    let _ = child.start_kill();
                }
            }
        }
        self.set_display_snapshot(AgentSpeedDisplaySnapshot::empty("helperExit", false));
    }

    fn set_error_status(&self, settings: &AgentSpeedReportingSettingsSnapshot, code: &str) {
        let mut status = AgentSpeedReportingStatus::from_settings(settings);
        status.phase = "error".into();
        status.status_message = message_for(code).into();
        let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        data.status = Some(status);
    }

    fn set_phase(
        &self,
        settings: &AgentSpeedReportingSettingsSnapshot,
        phase: &str,
        message: &str,
    ) {
        let mut status = AgentSpeedReportingStatus::from_settings(settings);
        status.phase = phase.into();
        status.status_message = message.into();
        let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        data.status = Some(status);
    }

    fn set_display_snapshot(&self, snapshot: AgentSpeedDisplaySnapshot) {
        let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        data.display_snapshot = Some(snapshot);
    }

    #[cfg(windows)]
    fn invalidate_generation(&self) {
        {
            let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
            data.generation = data.generation.wrapping_add(1).max(1);
            data.active_username = None;
            data.active_transport = None;
            data.active_reporting = false;
            data.active_local_display = false;
        }
        if let Some(cancel) = self
            .retry_cancel
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
        {
            let _ = cancel.send(true);
        }
    }

    #[cfg(windows)]
    fn generation_is_current(&self, generation: u64) -> bool {
        self.data
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .generation
            == generation
    }

    #[cfg(windows)]
    fn next_retry_delay(
        &self,
        generation: u64,
        retry_after_seconds: Option<u64>,
    ) -> Option<Duration> {
        let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
        if data.generation != generation {
            return None;
        }
        data.retry_attempt = data.retry_attempt.saturating_add(1);
        Some(Duration::from_secs(reporting_retry_delay_seconds(
            data.retry_attempt,
            retry_after_seconds,
        )))
    }

    #[cfg(windows)]
    async fn reap_helper_for_retry(&self, generation: u64) -> bool {
        let _transition = self.transition.lock().await;
        if !self.generation_is_current(generation) {
            return false;
        }
        self.stop_process().await;
        true
    }

    #[cfg(windows)]
    fn child_is_running_for(
        &self,
        username: &str,
        codex_home: &std::path::Path,
        local_source_roots: &std::collections::BTreeMap<String, String>,
        transport: AgentSpeedReportingTransport,
        reporting_enabled: bool,
        display_enabled: bool,
    ) -> bool {
        let mut child = self.child.lock().unwrap_or_else(|error| error.into_inner());
        let running = match child.as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            None => false,
        };
        if running {
            let data = self.data.lock().unwrap_or_else(|error| error.into_inner());
            return data.active_username.as_deref() == Some(username)
                && data.active_codex_home.as_deref() == Some(codex_home)
                && &data.active_local_source_roots == local_source_roots
                && data.active_transport == Some(transport)
                && data.active_reporting == reporting_enabled
                && data.active_local_display == display_enabled;
        }

        child.take();
        false
    }

    #[cfg(windows)]
    fn mark_exited_child(&self) {
        let mut child = self.child.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(handle) = child.as_mut() {
            if matches!(handle.try_wait(), Ok(Some(_)) | Err(_)) {
                child.take();
                let mut data = self.data.lock().unwrap_or_else(|error| error.into_inner());
                if let Some(status) = data.status.as_mut() {
                    if status.enabled && status.phase != "error" {
                        status.phase = "error".into();
                        status.status_message = "上报程序意外停止".into();
                    }
                }
                data.active_username = None;
                data.active_transport = None;
                data.active_reporting = false;
                data.active_local_display = false;
                data.display_snapshot = Some(AgentSpeedDisplaySnapshot::empty("helperExit", false));
            }
        }
    }

    #[cfg(windows)]
    async fn stop_process(&self) {
        self.stdin.lock().await.take();
        let mut child = self
            .child
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take();
        if let Some(mut child) = child.take() {
            if tokio::time::timeout(Duration::from_millis(750), child.wait())
                .await
                .is_err()
            {
                let _ = child.start_kill();
                let _ = child.wait().await;
            }
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawStatusLine {
    version: u8,
    phase: String,
    message_code: String,
    live_output_tps: f64,
    estimated_share: f64,
    last_report_at: Option<String>,
    sources: Vec<RawSourceLine>,
    profile_url: Option<String>,
    #[serde(default)]
    local_display: Option<RawDisplaySnapshot>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawSourceLine {
    id: String,
    name: String,
    tps: f64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawDisplaySnapshot {
    available: bool,
    tokens_per_second: f64,
    model_rates: Vec<RawDisplayRate>,
    client_rates: Vec<RawDisplayRate>,
    status: String,
    updated_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawDisplayRate {
    model: String,
    tokens_per_second: f64,
}

#[cfg(windows)]
async fn read_helper_status(
    stdout: tokio::process::ChildStdout,
    data: Arc<Mutex<RegistryData>>,
    stdin: Arc<AsyncMutex<Option<ChildStdin>>>,
    source_read_roots: Vec<std::path::PathBuf>,
    username: String,
    transport: AgentSpeedReportingTransport,
    reporting_enabled: bool,
    display_enabled: bool,
    generation: u64,
) -> Option<String> {
    let mut reader = BufReader::new(stdout);
    let mut failure_code = None;
    loop {
        let line = match read_bounded_line(
            &mut reader,
            DISPLAY_STATUS_LINE_LIMIT.max(STATUS_LINE_LIMIT),
        )
        .await
        {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(error) => {
                if error.kind() == io::ErrorKind::InvalidData {
                    failure_code = Some("reporting_failed".into());
                }
                break;
            }
        };
        if crate::core::claude_local_runtime::is_source_read_request(&line) {
            let roots = source_read_roots.clone();
            let reply = tokio::task::spawn_blocking(move || {
                crate::core::claude_local_runtime::source_read_reply(&line, &roots)
            })
            .await
            .ok()
            .flatten();
            let Some(reply) = reply else {
                continue;
            };
            let mut writer = stdin.lock().await;
            let Some(pipe) = writer.as_mut() else {
                break;
            };
            if pipe.write_all(&reply.header).await.is_err()
                || pipe.write_all(&reply.payload).await.is_err()
                || pipe.flush().await.is_err()
            {
                break;
            }
            continue;
        }
        let raw = match serde_json::from_slice::<RawStatusLine>(&line) {
            Ok(raw) => raw,
            Err(_) => {
                failure_code = Some("reporting_failed".into());
                continue;
            }
        };
        let raw_phase = raw.phase.clone();
        let raw_message_code = raw.message_code.clone();
        let display = raw
            .local_display
            .clone()
            .and_then(sanitize_display_snapshot);
        let status = reporting_enabled
            .then(|| sanitize_status(raw, &username, transport))
            .flatten();
        if reporting_enabled && status.is_none() {
            failure_code = Some("reporting_failed".into());
        }
        let mut state = data.lock().unwrap_or_else(|error| error.into_inner());
        if status_writer_is_current(&state, generation, &username) {
            if let Some(status) = status {
                state.status = Some(status);
                if reporting_enabled {
                    if raw_phase == "error" {
                        failure_code = Some(raw_message_code);
                    } else {
                        failure_code = None;
                    }
                    if matches!(
                        raw_phase.as_str(),
                        "connected" | "reporting" | "waiting_for_activity"
                    ) {
                        state.retry_attempt = 0;
                    }
                }
            }
            if display_enabled {
                if let Some(display) = display {
                    state.display_snapshot = Some(display);
                }
            }
        }
    }

    let mut state = data.lock().unwrap_or_else(|error| error.into_inner());
    if status_writer_is_current(&state, generation, &username) {
        if reporting_enabled {
            if let Some(status) = state.status.as_mut() {
                if status.enabled && status.phase != "error" {
                    status.phase = "error".into();
                    status.status_message = "上报程序意外停止".into();
                }
            }
        }
        state.active_username = None;
        state.active_transport = None;
        state.active_reporting = false;
        state.active_local_display = false;
        if display_enabled {
            state.display_snapshot = Some(AgentSpeedDisplaySnapshot::empty("helperExit", false));
        }
    }
    failure_code
}

#[cfg(windows)]
async fn read_bounded_line<R>(reader: &mut R, limit: usize) -> io::Result<Option<Vec<u8>>>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    use tokio::io::AsyncBufReadExt as _;

    let mut output = Vec::with_capacity(512);
    let mut overflow = false;
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            if output.is_empty() && !overflow {
                return Ok(None);
            }
            return Ok(Some(output));
        }

        let count = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if !overflow {
            let useful = count - usize::from(available[count - 1] == b'\n');
            if output.len().saturating_add(useful) > limit {
                overflow = true;
                output.clear();
            } else {
                output.extend_from_slice(&available[..useful]);
            }
        }
        let ended = available[count - 1] == b'\n';
        reader.consume(count);
        if ended {
            return if overflow {
                Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "status line too large",
                ))
            } else {
                Ok(Some(output))
            };
        }
    }
}

fn sanitize_status(
    raw: RawStatusLine,
    username: &str,
    transport: AgentSpeedReportingTransport,
) -> Option<AgentSpeedReportingStatus> {
    if raw.version != 1
        || !matches!(
            raw.phase.as_str(),
            "waiting_for_snapshot"
                | "waiting_for_activity"
                | "discovering"
                | "registering"
                | "connected"
                | "reporting"
                | "reconnecting"
                | "error"
        )
        || raw.message_code.len() > 48
    {
        return None;
    }

    let has_unreportable_source = raw
        .sources
        .iter()
        .any(|source| reportable_source_name(&source.id).is_none());
    let sources: Vec<AgentSpeedSourceStatus> = raw
        .sources
        .into_iter()
        .filter_map(|source| {
            let name = reportable_source_name(&source.id)?;
            if source.name != name || !source.tps.is_finite() {
                return None;
            }
            Some(AgentSpeedSourceStatus {
                id: source.id,
                name: name.into(),
                tps: source.tps.clamp(0.0, MAX_TPS),
            })
        })
        .take(32)
        .collect();

    let live_output_tps = if has_unreportable_source {
        sources
            .iter()
            .map(|source| source.tps)
            .sum::<f64>()
            .clamp(0.0, MAX_TPS)
    } else if raw.live_output_tps.is_finite() {
        raw.live_output_tps.clamp(0.0, MAX_TPS)
    } else {
        0.0
    };

    let last_report_at = raw.last_report_at.and_then(sanitize_timestamp);
    let profile_url = raw.profile_url.and_then(sanitize_profile_url);
    Some(AgentSpeedReportingStatus {
        enabled: true,
        invitation_handled: true,
        username: username.to_owned(),
        transport,
        phase: if raw.phase == "reporting" {
            "running".into()
        } else {
            raw.phase
        },
        status_message: message_for(&raw.message_code).into(),
        live_output_tps,
        estimated_share: if has_unreportable_source {
            0.0
        } else if raw.estimated_share.is_finite() {
            raw.estimated_share.clamp(0.0, 1.0)
        } else {
            0.0
        },
        last_report_at,
        sources,
        profile_url,
    })
}

fn sanitize_display_snapshot(raw: RawDisplaySnapshot) -> Option<AgentSpeedDisplaySnapshot> {
    let now = current_time_ms();
    if !matches!(
        raw.status.as_str(),
        "starting"
            | "running"
            | "idle"
            | "noSources"
            | "stale"
            | "error"
            | "unsupported"
            | "helperExit"
            | "disabled"
            | "unavailable"
    ) || raw.status.len() > 32
        || !raw.tokens_per_second.is_finite()
        || !(0.0..=MAX_TPS).contains(&raw.tokens_per_second)
        || raw.updated_at_ms < 0
        || raw.updated_at_ms > now.saturating_add(2_000)
    {
        return None;
    }

    let model_rates = sanitize_display_rates(raw.model_rates, false)?;
    let client_rates = sanitize_display_rates(raw.client_rates, true)?;
    let model_total = model_rates
        .iter()
        .map(|rate| rate.tokens_per_second)
        .sum::<f64>();
    let client_total = client_rates
        .iter()
        .map(|rate| rate.tokens_per_second)
        .sum::<f64>();
    let tolerance = (raw.tokens_per_second.max(1.0)) * 1e-6;
    if !model_total.is_finite()
        || !client_total.is_finite()
        || (model_total - raw.tokens_per_second).abs() > tolerance
        || (client_total - raw.tokens_per_second).abs() > tolerance
        || (!raw.available
            && (raw.tokens_per_second != 0.0
                || !model_rates.is_empty()
                || !client_rates.is_empty()))
    {
        return None;
    }

    Some(AgentSpeedDisplaySnapshot {
        available: raw.available,
        tokens_per_second: raw.tokens_per_second,
        model_rates,
        client_rates,
        status: raw.status,
        updated_at_ms: raw.updated_at_ms,
    })
}

fn sanitize_display_rates(
    raw: Vec<RawDisplayRate>,
    clients: bool,
) -> Option<Vec<AgentSpeedDisplayRate>> {
    if raw.len() > 512 {
        return None;
    }
    let mut seen = std::collections::HashSet::new();
    raw.into_iter()
        .map(|rate| {
            if rate.model.len() > 1024
                || rate.model.chars().any(char::is_control)
                || rate.model.is_empty() && clients
                || !seen.insert(rate.model.clone())
                || !rate.tokens_per_second.is_finite()
                || rate.tokens_per_second <= 0.0
                || rate.tokens_per_second > MAX_TPS
                || clients && !is_display_client_key(&rate.model)
            {
                return None;
            }
            Some(AgentSpeedDisplayRate {
                model: rate.model,
                tokens_per_second: rate.tokens_per_second,
            })
        })
        .collect()
}

fn is_display_client_key(value: &str) -> bool {
    let Some(source) = value.strip_prefix("client:") else {
        return false;
    };
    matches!(
        source,
        "codex"
            | "claudeCode"
            | "claudeDesktop"
            | "deepseek"
            | "opencode"
            | "gemini"
            | "omp"
            | "antigravity"
            | "workbuddy"
            | "workbuddyAi"
            | "zcode"
            | "kimi"
            | "grokBuild"
    )
}

fn current_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .unwrap_or_default()
}

fn canonical_source_name(id: &str) -> Option<&'static str> {
    match id {
        "codex" => Some("Codex"),
        "claudeCode" => Some("Claude Code"),
        "claudeDesktop" => Some("Claude Desktop"),
        "deepseek" => Some("DeepSeek"),
        "opencode" => Some("OpenCode"),
        "gemini" => Some("Gemini CLI"),
        "omp" => Some("omp"),
        "antigravity" => Some("Antigravity"),
        "workbuddy" => Some("WorkBuddy"),
        "workbuddyAi" => Some("WorkBuddy AI"),
        "zcode" => Some("ZCode"),
        "kimi" => Some("Kimi"),
        "grokBuild" => Some("Grok Build"),
        _ => None,
    }
}

fn reportable_source_name(id: &str) -> Option<&'static str> {
    if REPORTER_DENIED_SOURCE_IDS.contains(&id) {
        None
    } else {
        canonical_source_name(id)
    }
}

fn message_for(code: &str) -> &'static str {
    match code {
        "waiting_for_snapshot" => "正在等待实时快照",
        "discovering" => "正在检查上报服务",
        "registering" => "正在注册此设备",
        "websocket_waiting_for_activity" => "设备已注册，正在等待活动",
        "websocket_connected" => "WebSocket 已连接，等待有效上报确认",
        "reporting" => "正在上报实时速度",
        "http_fallback" => "WebSocket 连接中断，本次运行改用 HTTP",
        "websocket_reconnecting" => "WebSocket 正在重新连接",
        "websocket_not_supported" => "此上报服务尚未支持 WebSocket",
        "websocket_configuration_mismatch" => "服务连接设置不一致，请手动重试",
        "websocket_protocol_error" => "WebSocket 服务协议不兼容",
        "websocket_replaced" => "此设备已在其他位置连接",
        "unknown_device" => "服务端找不到此设备，请稍后重试",
        "service_unavailable" => "上报服务暂不可用，将自动重试",
        "service_unsupported" => "上报服务不受支持",
        "username_invalid" => "用户名不符合服务要求",
        "username_taken" => "用户名已被使用",
        "api_key_required" => "服务要求 API 密钥",
        "forbidden" => "服务拒绝了设备注册",
        "key_unavailable" => "设备签名密钥不可用",
        "reporting_failed" => "服务错误导致上报停止",
        "helper_unavailable" => "上报程序不可用",
        "local_source_unavailable" => "本地来源配置不可用，已停止上报",
        "windows_only" => "Agent Speed 上报仅支持 Windows",
        "disabled" => "未开启",
        _ => "上报程序意外停止",
    }
}

fn safe_username(username: &str) -> Result<String, String> {
    let value = username.trim();
    if value.chars().count() < 2
        || value.chars().count() > 32
        || value.chars().any(char::is_control)
    {
        return Err("Agent Speed username must contain 2 to 32 printable characters.".into());
    }
    Ok(value.to_owned())
}

fn sanitize_timestamp(value: String) -> Option<String> {
    use time::{format_description::well_known::Rfc3339, OffsetDateTime};
    if value.len() > 40 {
        return None;
    }
    OffsetDateTime::parse(&value, &Rfc3339)
        .ok()?
        .format(&Rfc3339)
        .ok()
}

fn sanitize_profile_url(value: String) -> Option<String> {
    let allowed = ["https://deng.codexradar.com/", "https://codexradar.com/"];
    if value.len() <= 2048
        && allowed.iter().any(|prefix| value.starts_with(prefix))
        && !value.contains('@')
        && !value.chars().any(char::is_control)
    {
        Some(value)
    } else {
        None
    }
}

#[cfg(windows)]
fn helper_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let path = app
        .path()
        .resource_dir()
        .map_err(|_| "resource_path")?
        .join("AgentSpeedReporter")
        .join("AgentSpeedReporter.exe");
    if path.is_file() {
        Ok(path)
    } else {
        Err("helper_missing".into())
    }
}

#[cfg(windows)]
fn copy_safe_environment(command: &mut Command, username: &str) {
    const SAFE_ENV: &[&str] = &[
        "SystemRoot",
        "WINDIR",
        "USERPROFILE",
        "HOMEDRIVE",
        "HOMEPATH",
        "LOCALAPPDATA",
        "APPDATA",
        "TEMP",
        "TMP",
        "PATH",
        "CODEX_HOME",
        "CLAUDE_CONFIG_DIR",
        "DSH_HOME",
        "XDG_DATA_HOME",
        "GEMINI_CLI_HOME",
        "PI_CODING_AGENT_DIR",
        "ZCODE_DATA_BASE_DIR",
        "KIMI_CODE_HOME",
        "GROK_HOME",
    ];
    for name in SAFE_ENV {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"] {
        if let Some(value) = std::env::var(name)
            .ok()
            .filter(|value| safe_proxy_value(value, name == "NO_PROXY"))
        {
            command.env(name, value);
        }
    }
    command.env("TOKENBAR_REPORTING_USERNAME", username);
}

#[cfg(windows)]
fn safe_proxy_value(value: &str, no_proxy: bool) -> bool {
    if value.is_empty()
        || value.len() > 2048
        || value.chars().any(char::is_control)
        || value.contains('@')
        || value.contains('?')
        || value.contains('#')
    {
        return false;
    }
    if no_proxy {
        return true;
    }
    value.starts_with("http://") || value.starts_with("https://") || value.starts_with("socks5://")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_default_off_with_random_non_machine_pseudonym_when_initialized() {
        let mut settings = AgentSpeedReportingSettingsSnapshot::default();
        assert!(!settings.enabled);
        assert!(!settings.invitation_handled);
        assert!(settings.ensure_random_username());
        assert!(settings.username.starts_with("TokenBar-"));
        assert_eq!(settings.username.len(), "TokenBar-".len() + 8);
    }

    #[test]
    fn status_is_always_bounded_and_uses_known_source_names() {
        let raw = RawStatusLine {
            version: 1,
            phase: "reporting".into(),
            message_code: "reporting".into(),
            live_output_tps: f64::INFINITY,
            estimated_share: 2.0,
            last_report_at: Some("not-a-date".into()),
            sources: vec![
                RawSourceLine {
                    id: "codex".into(),
                    name: "Codex".into(),
                    tps: 12.5,
                },
                RawSourceLine {
                    id: "claudeCode".into(),
                    name: "Claude Code".into(),
                    tps: 22.0,
                },
                RawSourceLine {
                    id: "local-path".into(),
                    name: "/Users/private".into(),
                    tps: 99.0,
                },
            ],
            profile_url: Some("https://evil.example/profile".into()),
            local_display: None,
        };
        let status =
            sanitize_status(raw, "TokenBar-a1b2", AgentSpeedReportingTransport::Http).unwrap();
        assert_eq!(status.phase, "running");
        assert_eq!(status.live_output_tps, 12.5);
        assert_eq!(status.estimated_share, 0.0);
        assert_eq!(status.sources.len(), 1);
        assert_eq!(status.sources[0].name, "Codex");
        assert!(status.last_report_at.is_none());
        assert!(status.profile_url.is_none());
        let json = serde_json::to_value(status).unwrap();
        assert!(json.get("message").is_some());
        assert!(json.get("statusMessage").is_none());
    }

    #[test]
    fn http_fallback_status_keeps_the_saved_websocket_choice() {
        let status = sanitize_status(
            RawStatusLine {
                version: 1,
                phase: "reporting".into(),
                message_code: "http_fallback".into(),
                live_output_tps: 0.0,
                estimated_share: 0.5,
                last_report_at: Some("2026-10-26T00:00:00Z".into()),
                sources: Vec::new(),
                profile_url: None,
                local_display: None,
            },
            "TokenBar-a1b2",
            AgentSpeedReportingTransport::Websocket,
        )
        .unwrap();

        assert_eq!(status.transport, AgentSpeedReportingTransport::Websocket);
        assert_eq!(status.phase, "running");
        assert_eq!(
            status.status_message,
            "WebSocket 连接中断，本次运行改用 HTTP"
        );
        assert_eq!(
            status.last_report_at.as_deref(),
            Some("2026-10-26T00:00:00Z")
        );

        let waiting = sanitize_status(
            RawStatusLine {
                version: 1,
                phase: "waiting_for_activity".into(),
                message_code: "websocket_waiting_for_activity".into(),
                live_output_tps: 0.0,
                estimated_share: 0.0,
                last_report_at: None,
                sources: Vec::new(),
                profile_url: None,
                local_display: None,
            },
            "TokenBar-a1b2",
            AgentSpeedReportingTransport::Websocket,
        )
        .unwrap();
        assert_eq!(waiting.phase, "waiting_for_activity");
        assert_eq!(waiting.status_message, "设备已注册，正在等待活动");
    }

    #[test]
    fn all_source_ids_match_the_reporter_protocol() {
        let expected = [
            ("codex", "Codex"),
            ("claudeCode", "Claude Code"),
            ("claudeDesktop", "Claude Desktop"),
            ("deepseek", "DeepSeek"),
            ("opencode", "OpenCode"),
            ("gemini", "Gemini CLI"),
            ("omp", "omp"),
            ("antigravity", "Antigravity"),
            ("workbuddy", "WorkBuddy"),
            ("workbuddyAi", "WorkBuddy AI"),
            ("zcode", "ZCode"),
            ("kimi", "Kimi"),
            ("grokBuild", "Grok Build"),
        ];
        for (id, name) in expected {
            assert_eq!(canonical_source_name(id), Some(name), "source id {id}");
        }
        assert_eq!(canonical_source_name("workBuddyAi"), None);
    }

    #[test]
    fn reporter_start_contract_and_status_guard_deny_only_claude_sources() {
        let startup = reporter_start_payload("TokenBar-test", &Default::default());
        assert_eq!(startup["enabled"], true);
        assert_eq!(startup["username"], "TokenBar-test");
        assert_eq!(
            startup["deniedSourceIds"],
            serde_json::json!(["claudeCode", "claudeDesktop"])
        );
        assert_eq!(reportable_source_name("codex"), Some("Codex"));
        assert_eq!(reportable_source_name("deepseek"), Some("DeepSeek"));
        assert_eq!(reportable_source_name("claudeCode"), None);
        assert_eq!(reportable_source_name("claudeDesktop"), None);
        assert_eq!(reportable_source_name("unknown"), None);
    }

    #[test]
    fn local_roots_are_startup_only_and_the_legacy_empty_frame_is_unchanged() {
        let empty = reporter_start_payload("TokenBar-test", &Default::default());
        assert!(empty.get("localSourceRoots").is_none());
        let roots = std::collections::BTreeMap::from([
            ("gemini".to_owned(), r"C:\Local\Gemini".to_owned()),
            ("deepseek".to_owned(), r"C:\Local\DSH".to_owned()),
        ]);
        let startup = reporter_start_payload("TokenBar-test", &roots);
        assert_eq!(startup["localSourceRoots"]["gemini"], r"C:\Local\Gemini");
        assert_eq!(
            startup["deniedSourceIds"],
            serde_json::json!(["claudeCode", "claudeDesktop"])
        );
    }

    #[test]
    fn stale_helper_generation_cannot_publish_or_clear_current_state() {
        let data = RegistryData {
            active_username: Some("TokenBar-current".into()),
            #[cfg(windows)]
            active_codex_home: None,
            #[cfg(windows)]
            active_local_source_roots: Default::default(),
            generation: 9,
            ..RegistryData::default()
        };
        assert!(!status_writer_is_current(&data, 8, "TokenBar-previous"));
        assert!(!status_writer_is_current(&data, 8, "TokenBar-current"));
        assert!(!status_writer_is_current(&data, 9, "TokenBar-previous"));
        assert!(status_writer_is_current(&data, 9, "TokenBar-current"));
    }

    #[test]
    fn reporting_retry_backoff_caps_and_respects_retry_after() {
        let delays: Vec<u64> = (1..=9)
            .map(|attempt| reporting_retry_delay_seconds(attempt, None))
            .collect();
        assert_eq!(delays, [5, 10, 20, 40, 80, 160, 300, 300, 300]);
        assert_eq!(reporting_retry_delay_seconds(1, Some(60)), 60);
        assert_eq!(reporting_retry_delay_seconds(2, Some(2)), 10);
        assert_eq!(reporting_retry_delay_seconds(7, Some(172_800)), 86_400);
    }

    #[test]
    fn only_transient_service_unavailable_and_unclassified_exit_retry() {
        assert!(helper_failure_is_retryable(None));
        assert!(helper_failure_is_retryable(Some("service_unavailable")));
        for code in [
            "api_key_required",
            "forbidden",
            "username_invalid",
            "username_taken",
            "service_unsupported",
            "websocket_protocol_error",
            "websocket_configuration_mismatch",
            "unknown_device",
            "reporting_failed",
        ] {
            assert!(!helper_failure_is_retryable(Some(code)), "code {code}");
        }
    }

    #[test]
    fn status_reads_never_launch_the_reporter() {
        let registry = AgentSpeedReportingRegistry::default();
        let settings = AgentSpeedReportingSettingsSnapshot::default();
        let status = registry.read_status(&settings);
        assert!(!status.enabled);
        assert_eq!(status.phase, "off");
    }

    #[test]
    fn local_display_snapshot_requires_consistent_model_and_client_sums() {
        let now = current_time_ms();
        let raw = RawDisplaySnapshot {
            available: true,
            tokens_per_second: 12.0,
            model_rates: vec![RawDisplayRate {
                model: "gpt-6".into(),
                tokens_per_second: 12.0,
            }],
            client_rates: vec![
                RawDisplayRate {
                    model: "client:codex".into(),
                    tokens_per_second: 10.0,
                },
                RawDisplayRate {
                    model: "client:claudeCode".into(),
                    tokens_per_second: 2.0,
                },
            ],
            status: "running".into(),
            updated_at_ms: now,
        };
        let snapshot = sanitize_display_snapshot(raw.clone()).unwrap();
        let json = serde_json::to_value(snapshot).unwrap();
        let fields = json
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            fields,
            [
                "available",
                "tokensPerSecond",
                "modelRates",
                "clientRates",
                "status",
                "updatedAtMs"
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
        assert_eq!(json["tokensPerSecond"], 12.0);
        assert_eq!(json["clientRates"][0]["model"], "client:codex");
        assert!(json.get("updatedAtMs").is_some());

        let mismatch = RawDisplaySnapshot {
            client_rates: vec![RawDisplayRate {
                model: "client:codex".into(),
                tokens_per_second: 11.0,
            }],
            ..raw.clone()
        };
        assert!(sanitize_display_snapshot(mismatch).is_none());
        let private_source_key = RawDisplaySnapshot {
            client_rates: vec![RawDisplayRate {
                model: "client:C:\\Users\\name\\transcript.jsonl".into(),
                tokens_per_second: 12.0,
            }],
            ..raw
        };
        assert!(sanitize_display_snapshot(private_source_key).is_none());
    }
}
