use crate::commands::local_source;
use crate::core::dashboard::DashboardDataSource;
use crate::core::startup_trace;
use crate::models::{
    AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, PlatformCapabilities,
};
use crate::platform;
use tauri::async_runtime;

async fn run_blocking_command<T, F>(work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub fn get_codex_home() -> Result<CodexHomeStatus, String> {
    startup_trace::mark("command get_codex_home start");
    let result = platform::default_codex_home_status();
    startup_trace::mark("command get_codex_home end");
    Ok(result)
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
pub fn read_platform_capabilities() -> Result<PlatformCapabilities, String> {
    startup_trace::mark("command read_platform_capabilities start");
    let result = platform::platform_capabilities();
    startup_trace::mark("command read_platform_capabilities end");
    Ok(result)
}

#[tauri::command]
pub async fn read_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    startup_trace::mark("command read_dashboard_snapshot start");
    let result = run_blocking_command(|| local_source().read_dashboard_snapshot()).await;
    startup_trace::mark("command read_dashboard_snapshot end");
    result
}

#[tauri::command]
pub async fn read_precise_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    run_blocking_command(|| local_source().read_precise_dashboard_snapshot()).await
}

#[tauri::command]
pub async fn read_account_quota(force_refresh: Option<bool>) -> Result<AccountQuotaBundle, String> {
    startup_trace::mark_once("command read_account_quota start");
    let result = run_blocking_command(move || {
        local_source().read_account_quota(force_refresh.unwrap_or(false))
    })
    .await;
    startup_trace::mark_once("command read_account_quota end");
    result
}
