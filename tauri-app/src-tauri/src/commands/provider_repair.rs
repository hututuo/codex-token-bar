use crate::commands::local_source;
use crate::core::{
    dashboard::DashboardDataSource,
    provider_repair as provider_repair_core,
};
use crate::models::{
    ProviderRepairActionResult, ProviderRepairBackupInfo, ProviderRepairSnapshot,
};

#[tauri::command]
pub fn scan_provider_repair() -> Result<ProviderRepairSnapshot, String> {
    Ok(local_source().scan_provider_repair())
}

#[tauri::command]
pub fn list_provider_backups() -> Result<Vec<ProviderRepairBackupInfo>, String> {
    provider_repair_core::list_provider_backups()
}

#[tauri::command]
pub fn create_provider_backup() -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    provider_repair_core::create_provider_backup(source.codex_home())
}

#[tauri::command]
pub fn sync_provider_history(backup_id: String) -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    provider_repair_core::sync_provider_history(source.codex_home(), &backup_id)
}

#[tauri::command]
pub fn verify_provider_repair() -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    Ok(provider_repair_core::verify_provider_repair(source.codex_home()))
}

#[tauri::command]
pub fn rollback_provider_backup(backup_id: String) -> Result<ProviderRepairActionResult, String> {
    let source = local_source();
    provider_repair_core::rollback_provider_backup(source.codex_home(), &backup_id)
}
