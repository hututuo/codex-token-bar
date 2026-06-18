use crate::core::{live_rate, mock_data, provider_repair, quota, quota_history, usage};
use crate::models::{
    AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, FloatingPanelSnapshot, LiveRateSnapshot,
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
    let mut snapshot = usage::state_sqlite::dashboard_snapshot(&codex_home)
        .unwrap_or_else(|_| mock_data::dashboard_snapshot());
    quota_history::apply_recent_history(&mut snapshot.recent_usage_24h);
    Ok(snapshot)
}

#[tauri::command]
pub fn read_precise_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    let codex_home = platform::default_codex_home();
    let mut snapshot = usage::token_count_jsonl::dashboard_snapshot(&codex_home)
        .or_else(|_| usage::state_sqlite::dashboard_snapshot(&codex_home))
        .unwrap_or_else(|_| mock_data::dashboard_snapshot());
    quota_history::apply_recent_history(&mut snapshot.recent_usage_24h);
    Ok(snapshot)
}

#[tauri::command]
pub fn read_account_quota() -> Result<AccountQuotaBundle, String> {
    let codex_home = platform::default_codex_home();
    quota::read_account_quota(&codex_home)
}

#[tauri::command]
pub fn read_live_rate_snapshot() -> Result<LiveRateSnapshot, String> {
    let codex_home = platform::default_codex_home();
    Ok(live_rate::read_snapshot(&codex_home))
}

#[tauri::command]
pub fn read_floating_snapshot() -> Result<FloatingPanelSnapshot, String> {
    let codex_home = platform::default_codex_home();
    Ok(live_rate::read_floating_snapshot(&codex_home))
}

#[tauri::command]
pub fn scan_provider_repair() -> Result<ProviderRepairSnapshot, String> {
    let codex_home = platform::default_codex_home();
    Ok(provider_repair::scan_provider_repair(&codex_home))
}
