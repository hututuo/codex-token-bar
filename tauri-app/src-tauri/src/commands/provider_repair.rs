use crate::commands::local_source;
use crate::core::{
    dashboard::DashboardDataSource,
    provider_repair as provider_repair_core,
};
use super::window_auth::require_window_label;
use crate::models::{
    ProviderRepairActionResult, ProviderRepairBackupInfo, ProviderRepairSnapshot,
};
use provider_repair_core::{ProviderOperationError, ProviderOperationStatus};

#[tauri::command]
pub fn scan_provider_repair(
    window: tauri::WebviewWindow,
) -> Result<ProviderRepairSnapshot, String> {
    require_window_label(&window, "scan_provider_repair")?;
    Ok(local_source().scan_provider_repair())
}

#[tauri::command]
pub fn list_provider_backups(
    window: tauri::WebviewWindow,
) -> Result<Vec<ProviderRepairBackupInfo>, String> {
    require_window_label(&window, "list_provider_backups")?;
    provider_repair_core::list_provider_backups()
}

#[tauri::command]
pub fn create_provider_backup(
    window: tauri::WebviewWindow,
    operation_id: String,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    require_window_label(&window, "create_provider_backup")?;
    let source = local_source();
    provider_repair_core::create_provider_backup(source.codex_home(), &operation_id)
}

#[tauri::command]
pub fn sync_provider_history(
    window: tauri::WebviewWindow,
    backup_id: String,
    operation_id: String,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    require_window_label(&window, "sync_provider_history")?;
    let source = local_source();
    provider_repair_core::sync_provider_history(source.codex_home(), &backup_id, &operation_id)
}

#[tauri::command]
pub fn verify_provider_repair(
    window: tauri::WebviewWindow,
) -> Result<ProviderRepairActionResult, String> {
    require_window_label(&window, "verify_provider_repair")?;
    let source = local_source();
    Ok(provider_repair_core::verify_provider_repair(source.codex_home()))
}

#[tauri::command]
pub fn rollback_provider_backup(
    window: tauri::WebviewWindow,
    backup_id: String,
    operation_id: String,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    require_window_label(&window, "rollback_provider_backup")?;
    let source = local_source();
    provider_repair_core::rollback_provider_backup(source.codex_home(), &backup_id, &operation_id)
}

#[tauri::command]
pub fn read_provider_operation_status(
    window: tauri::WebviewWindow,
    operation_id: String,
) -> Result<ProviderOperationStatus, ProviderOperationError> {
    require_window_label(&window, "read_provider_operation_status")?;
    let source = local_source();
    provider_repair_core::read_provider_operation_status(source.codex_home(), &operation_id)
}
