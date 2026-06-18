use crate::core::{mock_data, usage};
use crate::models::{
    CodexHomeStatus, DashboardSnapshot, FloatingPanelSnapshot, LiveRateSnapshot,
    ProviderRepairSnapshot,
};
use crate::platform;

#[tauri::command]
pub fn get_codex_home() -> Result<CodexHomeStatus, String> {
    Ok(platform::default_codex_home_status())
}

#[tauri::command]
pub fn read_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    let codex_home = platform::default_codex_home();
    Ok(usage::state_sqlite::dashboard_snapshot(&codex_home)
        .unwrap_or_else(|_| mock_data::dashboard_snapshot()))
}

#[tauri::command]
pub fn read_live_rate_snapshot() -> Result<LiveRateSnapshot, String> {
    Ok(mock_data::live_rate_snapshot())
}

#[tauri::command]
pub fn read_floating_snapshot() -> Result<FloatingPanelSnapshot, String> {
    Ok(mock_data::floating_panel_snapshot())
}

#[tauri::command]
pub fn scan_provider_repair() -> Result<ProviderRepairSnapshot, String> {
    Ok(mock_data::provider_repair_snapshot())
}
