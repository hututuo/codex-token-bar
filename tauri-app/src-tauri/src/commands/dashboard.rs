use crate::commands::local_source;
use crate::core::dashboard::DashboardDataSource;
use crate::core::startup_trace;
use crate::models::{
    AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, PlatformCapabilities,
};
use crate::platform;

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
pub fn read_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    startup_trace::mark("command read_dashboard_snapshot start");
    let result = local_source().read_dashboard_snapshot();
    startup_trace::mark("command read_dashboard_snapshot end");
    result
}

#[tauri::command]
pub fn read_precise_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    local_source().read_precise_dashboard_snapshot()
}

#[tauri::command]
pub fn read_account_quota(force_refresh: Option<bool>) -> Result<AccountQuotaBundle, String> {
    startup_trace::mark_once("command read_account_quota start");
    let result = local_source().read_account_quota(force_refresh.unwrap_or(false));
    startup_trace::mark_once("command read_account_quota end");
    result
}
