use crate::core::{
    dashboard::{DashboardDataSource, LocalCodexDataSource},
    provider_repair,
};
use crate::models::{
    AccountQuotaBundle, AppSettingsSnapshot, CodexHomeStatus, DashboardSnapshot,
    DisplaySurfaceSettingsSnapshot, FloatingPanelSnapshot, FloatingWindowPositionSnapshot,
    FloatingWindowSettingsSnapshot, LiveRateSnapshot, PlatformCapabilities,
    LiveThreadOption, ProviderRepairActionResult, ProviderRepairBackupInfo, ProviderRepairSnapshot,
};
use crate::platform;
use std::{
    sync::{mpsc, Mutex},
    thread::{self, JoinHandle},
    time::Duration,
};
use tauri::{Emitter, State};

const LIVE_RATE_SNAPSHOT_EVENT: &str = "live-rate-snapshot";
const LIVE_RATE_STREAM_INTERVAL_MS: u64 = 250;

#[derive(Default)]
pub struct LiveRateStreamState {
    handle: Mutex<Option<LiveRateStreamHandle>>,
}

struct LiveRateStreamHandle {
    selected_thread_id: Option<String>,
    stop_sender: mpsc::Sender<()>,
    join_handle: Option<JoinHandle<()>>,
}

impl Drop for LiveRateStreamHandle {
    fn drop(&mut self) {
        let _ = self.stop_sender.send(());
        if let Some(join_handle) = self.join_handle.take() {
            let _ = join_handle.join();
        }
    }
}

#[tauri::command]
pub fn get_codex_home() -> Result<CodexHomeStatus, String> {
    Ok(platform::default_codex_home_status())
}

#[tauri::command]
pub fn set_codex_home(path: String) -> Result<CodexHomeStatus, String> {
    platform::save_codex_home(&path)
}

#[tauri::command]
pub fn reset_codex_home() -> Result<CodexHomeStatus, String> {
    platform::reset_codex_home()
}

#[tauri::command]
pub fn read_app_settings() -> Result<AppSettingsSnapshot, String> {
    Ok(platform::read_app_settings())
}

#[tauri::command]
pub fn save_floating_settings(
    settings: FloatingWindowSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    platform::save_floating_settings(settings)
}

#[tauri::command]
pub fn save_floating_position(
    position: FloatingWindowPositionSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    platform::save_floating_position(position)
}

#[tauri::command]
pub fn save_display_surfaces(
    display: DisplaySurfaceSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    platform::save_display_surfaces(display)
}

#[tauri::command]
pub fn save_setup_guide_completed(completed: bool) -> Result<AppSettingsSnapshot, String> {
    platform::save_setup_guide_completed(completed)
}

#[tauri::command]
pub fn read_platform_capabilities() -> Result<PlatformCapabilities, String> {
    Ok(platform::platform_capabilities())
}

#[tauri::command]
pub fn read_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    local_source().read_dashboard_snapshot()
}

#[tauri::command]
pub fn read_precise_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    local_source().read_precise_dashboard_snapshot()
}

#[tauri::command]
pub fn read_account_quota(force_refresh: Option<bool>) -> Result<AccountQuotaBundle, String> {
    local_source().read_account_quota(force_refresh.unwrap_or(false))
}

#[tauri::command]
pub fn read_live_rate_snapshot(
    selected_thread_id: Option<String>,
) -> Result<LiveRateSnapshot, String> {
    local_source().try_read_live_rate_snapshot(selected_thread_id.as_deref())
}

#[tauri::command]
pub fn read_live_thread_options() -> Result<Vec<LiveThreadOption>, String> {
    local_source().try_read_live_thread_options()
}

#[tauri::command]
pub fn start_live_rate_stream(
    app: tauri::AppHandle,
    state: State<LiveRateStreamState>,
    selected_thread_id: Option<String>,
) -> Result<bool, String> {
    let mut current = state.handle.lock().map_err(|error| error.to_string())?;
    if current
        .as_ref()
        .is_some_and(|handle| handle.selected_thread_id == selected_thread_id)
    {
        return Ok(true);
    }
    current.take();

    let (stop_sender, stop_receiver) = mpsc::channel::<()>();
    let codex_home = platform::default_codex_home();
    let stream_selected_thread_id = selected_thread_id.clone();
    let join_handle = thread::Builder::new()
        .name("codex-token-bar-live-rate-stream".into())
        .spawn(move || {
            let source = LocalCodexDataSource::new(codex_home);
            let mut last_snapshot = None;
            loop {
                let snapshot =
                    source.read_live_rate_snapshot(stream_selected_thread_id.as_deref());
                if should_emit_live_rate(last_snapshot.as_ref(), &snapshot) {
                    let _ = app.emit(LIVE_RATE_SNAPSHOT_EVENT, &snapshot);
                    last_snapshot = Some(snapshot);
                }

                if stop_receiver
                    .recv_timeout(Duration::from_millis(LIVE_RATE_STREAM_INTERVAL_MS))
                    .is_ok()
                {
                    break;
                }
            }
        })
        .map_err(|error| error.to_string())?;

    *current = Some(LiveRateStreamHandle {
        selected_thread_id,
        stop_sender,
        join_handle: Some(join_handle),
    });
    Ok(true)
}

#[tauri::command]
pub fn stop_live_rate_stream(state: State<LiveRateStreamState>) -> Result<bool, String> {
    let mut current = state.handle.lock().map_err(|error| error.to_string())?;
    current.take();
    Ok(false)
}

#[tauri::command]
pub fn read_floating_snapshot() -> Result<FloatingPanelSnapshot, String> {
    Ok(local_source().read_floating_snapshot())
}

#[tauri::command]
pub fn show_floating_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::show_floating_window(&app)
}

#[tauri::command]
pub fn hide_floating_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::hide_floating_window(&app)
}

#[tauri::command]
pub fn show_dashboard_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::show_dashboard_window(&app)
}

#[tauri::command]
pub fn show_status_panel_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::show_status_panel_window(&app)
}

#[tauri::command]
pub fn hide_status_panel_window(app: tauri::AppHandle) -> Result<bool, String> {
    platform::hide_status_panel_window(&app)
}

#[tauri::command]
pub fn set_status_tray_readout(
    app: tauri::AppHandle,
    title: String,
    tooltip: String,
) -> Result<bool, String> {
    platform::set_status_tray_readout(&app, title, tooltip)
}

#[tauri::command]
pub fn scan_provider_repair() -> Result<ProviderRepairSnapshot, String> {
    Ok(local_source().scan_provider_repair())
}

#[tauri::command]
pub fn list_provider_backups() -> Result<Vec<ProviderRepairBackupInfo>, String> {
    provider_repair::list_provider_backups()
}

#[tauri::command]
pub fn create_provider_backup() -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    provider_repair::create_provider_backup(source.codex_home())
}

#[tauri::command]
pub fn sync_provider_history(backup_id: String) -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    provider_repair::sync_provider_history(source.codex_home(), &backup_id)
}

#[tauri::command]
pub fn verify_provider_repair() -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    Ok(provider_repair::verify_provider_repair(source.codex_home()))
}

#[tauri::command]
pub fn rollback_provider_backup(backup_id: String) -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    provider_repair::rollback_provider_backup(source.codex_home(), &backup_id)
}

fn local_source() -> LocalCodexDataSource {
    LocalCodexDataSource::new(platform::default_codex_home())
}

fn should_emit_live_rate(
    previous: Option<&LiveRateSnapshot>,
    current: &LiveRateSnapshot,
) -> bool {
    let Some(previous) = previous else {
        return true;
    };

    (previous.tokens_per_second - current.tokens_per_second).abs() >= 0.05
        || previous.total_tokens_today != current.total_tokens_today
        || previous.requests_today != current.requests_today
        || previous.thread_title != current.thread_title
        || previous.scope_label != current.scope_label
        || previous.selected_thread_id != current.selected_thread_id
        || previous.selected_thread_title != current.selected_thread_title
        || (previous.selected_tokens_per_second - current.selected_tokens_per_second).abs() >= 0.05
        || previous.precise_enabled != current.precise_enabled
}
