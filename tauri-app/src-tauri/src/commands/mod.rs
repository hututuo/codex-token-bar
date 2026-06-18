use crate::core::{
    dashboard::{DashboardDataSource, LocalCodexDataSource},
    provider_repair,
};
use crate::models::{
    AccountQuotaBundle, AppSettingsSnapshot, CodexHomeStatus, DashboardSnapshot,
    FloatingPanelSnapshot, FloatingWindowPositionSnapshot, FloatingWindowSettingsSnapshot,
    LiveRateSnapshot, PlatformCapabilities, ProviderRepairActionResult, ProviderRepairBackupInfo,
    ProviderRepairSnapshot,
};
use crate::platform;

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
pub fn read_platform_capabilities() -> Result<PlatformCapabilities, String> {
    Ok(platform::platform_capabilities())
}

#[tauri::command]
pub fn read_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    Ok(local_source().read_dashboard_snapshot())
}

#[tauri::command]
pub fn read_precise_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    Ok(local_source().read_precise_dashboard_snapshot())
}

#[tauri::command]
pub fn read_account_quota() -> Result<AccountQuotaBundle, String> {
    local_source().read_account_quota()
}

#[tauri::command]
pub fn read_live_rate_snapshot() -> Result<LiveRateSnapshot, String> {
    Ok(local_source().read_live_rate_snapshot())
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
