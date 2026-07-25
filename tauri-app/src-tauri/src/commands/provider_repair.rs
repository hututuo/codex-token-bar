use super::window_auth::require_window_label;
use crate::commands::local_source;
use crate::core::{dashboard::DashboardDataSource, provider_repair as provider_repair_core};
use crate::models::{ProviderRepairActionResult, ProviderRepairBackupInfo, ProviderRepairSnapshot};
use provider_repair_core::{
    ProviderOperationError, ProviderOperationOwnershipDiscovery, ProviderOperationStatus,
    ProviderRecoveryState,
};
use std::path::Path;

fn execute_provider_mutation_command<T>(
    _entrypoint: &'static str,
    codex_home: &Path,
    recovery_state: &ProviderRecoveryState,
    operation_id: &str,
    mutation: impl FnOnce(&Path, &str) -> Result<T, ProviderOperationError>,
) -> Result<T, ProviderOperationError> {
    provider_repair_core::reconcile_provider_recovery_for_action(recovery_state, codex_home)?;
    mutation(codex_home, operation_id)
}

#[tauri::command]
pub async fn scan_provider_repair(
    window: tauri::WebviewWindow,
) -> Result<ProviderRepairSnapshot, String> {
    require_window_label(&window, "scan_provider_repair")?;
    let codex_home = local_source().codex_home().to_path_buf();
    tauri::async_runtime::spawn_blocking(move || {
        provider_repair_core::scan_provider_repair(&codex_home)
    })
    .await
    .map_err(|error| format!("Provider 扫描后台任务异常结束：{error}"))
}

#[tauri::command]
pub async fn list_provider_backups(
    window: tauri::WebviewWindow,
) -> Result<Vec<ProviderRepairBackupInfo>, String> {
    require_window_label(&window, "list_provider_backups")?;
    tauri::async_runtime::spawn_blocking(provider_repair_core::list_provider_backups)
        .await
        .map_err(|error| format!("Provider 备份列表后台任务异常结束：{error}"))?
}

#[tauri::command]
pub async fn create_provider_backup(
    window: tauri::WebviewWindow,
    recovery_state: tauri::State<'_, ProviderRecoveryState>,
    operation_id: String,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    require_window_label(&window, "create_provider_backup")?;
    let codex_home = local_source().codex_home().to_path_buf();
    let recovery_state = recovery_state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        execute_provider_mutation_command(
            "create_provider_backup",
            &codex_home,
            &recovery_state,
            &operation_id,
            provider_repair_core::create_provider_backup,
        )
    })
    .await
    .map_err(provider_background_task_error)?
}

#[tauri::command]
pub async fn sync_provider_history(
    window: tauri::WebviewWindow,
    recovery_state: tauri::State<'_, ProviderRecoveryState>,
    operation_id: String,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    require_window_label(&window, "sync_provider_history")?;
    let codex_home = local_source().codex_home().to_path_buf();
    let recovery_state = recovery_state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        execute_provider_mutation_command(
            "sync_provider_history",
            &codex_home,
            &recovery_state,
            &operation_id,
            provider_repair_core::sync_provider_history,
        )
    })
    .await
    .map_err(provider_background_task_error)?
}

#[tauri::command]
pub async fn migrate_provider_history(
    window: tauri::WebviewWindow,
    recovery_state: tauri::State<'_, ProviderRecoveryState>,
    target_provider: String,
    operation_id: String,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    require_window_label(&window, "migrate_provider_history")?;
    let codex_home = local_source().codex_home().to_path_buf();
    let recovery_state = recovery_state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        execute_provider_mutation_command(
            "migrate_provider_history",
            &codex_home,
            &recovery_state,
            &operation_id,
            |home, operation_id| {
                provider_repair_core::migrate_provider_history(
                    home,
                    &target_provider,
                    operation_id,
                )
            },
        )
    })
    .await
    .map_err(provider_background_task_error)?
}

#[tauri::command]
pub async fn verify_provider_repair(
    window: tauri::WebviewWindow,
) -> Result<ProviderRepairActionResult, String> {
    require_window_label(&window, "verify_provider_repair")?;
    let codex_home = local_source().codex_home().to_path_buf();
    tauri::async_runtime::spawn_blocking(move || {
        provider_repair_core::verify_provider_repair(&codex_home)
    })
    .await
    .map_err(|error| format!("Provider 验证后台任务异常结束：{error}"))
}

#[tauri::command]
pub async fn rollback_provider_backup(
    window: tauri::WebviewWindow,
    recovery_state: tauri::State<'_, ProviderRecoveryState>,
    backup_id: String,
    operation_id: String,
) -> Result<ProviderRepairActionResult, ProviderOperationError> {
    require_window_label(&window, "rollback_provider_backup")?;
    let codex_home = local_source().codex_home().to_path_buf();
    let recovery_state = recovery_state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        execute_provider_mutation_command(
            "rollback_provider_backup",
            &codex_home,
            &recovery_state,
            &operation_id,
            |home, operation_id| {
                provider_repair_core::rollback_provider_backup(home, &backup_id, operation_id)
            },
        )
    })
    .await
    .map_err(provider_background_task_error)?
}

fn provider_background_task_error(error: impl std::fmt::Display) -> ProviderOperationError {
    ProviderOperationError::Failed {
        message: format!("Provider 后台任务异常结束：{error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use provider_repair_core::ProviderOperationLifecycle;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier};

    #[test]
    fn command_adapter_serializes_timeout_overlap_and_releases_failed_lease() {
        let home = std::env::temp_dir().join(format!(
            "provider-command-adapter-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&home).unwrap();
        let state = Arc::new(ProviderRecoveryState::default());
        provider_repair_core::initialize_provider_recovery_state_for_test(&state, &home);
        let barrier = Arc::new(Barrier::new(2));
        let first_mutations = Arc::new(AtomicUsize::new(0));
        let thread_home = home.clone();
        let thread_state = Arc::clone(&state);
        let thread_barrier = Arc::clone(&barrier);
        let thread_mutations = Arc::clone(&first_mutations);
        let first = std::thread::spawn(move || {
            execute_provider_mutation_command(
                "create_provider_backup",
                &thread_home,
                &thread_state,
                "command-first",
                |home, operation_id| {
                    provider_repair_core::run_provider_mutation(home, operation_id, |_| {
                        thread_mutations.fetch_add(1, Ordering::SeqCst);
                        thread_barrier.wait();
                        thread_barrier.wait();
                        Ok(())
                    })
                },
            )
        });
        barrier.wait();

        let second_mutations = AtomicUsize::new(0);
        let second = execute_provider_mutation_command(
            "sync_provider_history",
            &home,
            &state,
            "command-second",
            |home, operation_id| {
                provider_repair_core::run_provider_mutation(home, operation_id, |_| {
                    second_mutations.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                })
            },
        );
        assert!(matches!(
            second,
            Err(ProviderOperationError::RecoveryBlocked { ref code, .. })
                if code == "backendGuardBusy"
        ));
        assert_eq!(
            provider_repair_core::read_provider_operation_status("command-second").lifecycle,
            ProviderOperationLifecycle::NotStarted
        );
        assert_eq!(second_mutations.load(Ordering::SeqCst), 0);

        barrier.wait();
        first.join().unwrap().unwrap();
        assert_eq!(first_mutations.load(Ordering::SeqCst), 1);

        execute_provider_mutation_command(
            "rollback_provider_backup",
            &home,
            &state,
            "command-third",
            |home, operation_id| {
                provider_repair_core::run_provider_mutation(home, operation_id, |_| Ok(()))
            },
        )
        .unwrap();
        let failed: Result<(), ProviderOperationError> = execute_provider_mutation_command(
            "sync_provider_history",
            &home,
            &state,
            "command-failed",
            |home, operation_id| {
                provider_repair_core::run_provider_mutation(home, operation_id, |_| {
                    Err("injected command mutation failure".into())
                })
            },
        );
        assert!(matches!(failed, Err(ProviderOperationError::Failed { .. })));
        execute_provider_mutation_command(
            "create_provider_backup",
            &home,
            &state,
            "command-after-failure",
            |home, operation_id| {
                provider_repair_core::run_provider_mutation(home, operation_id, |_| Ok(()))
            },
        )
        .unwrap();

        std::fs::remove_dir_all(home).unwrap();
    }
}

#[tauri::command]
pub fn read_provider_operation_status(
    window: tauri::WebviewWindow,
    operation_id: String,
) -> Result<ProviderOperationStatus, ProviderOperationError> {
    require_window_label(&window, "read_provider_operation_status")?;
    Ok(provider_repair_core::read_provider_operation_status(
        &operation_id,
    ))
}

#[tauri::command]
pub fn discover_provider_operation_ownership(
    window: tauri::WebviewWindow,
    recovery_state: tauri::State<'_, ProviderRecoveryState>,
) -> Result<ProviderOperationOwnershipDiscovery, ProviderOperationError> {
    require_window_label(&window, "discover_provider_operation_ownership")?;
    let source = local_source();
    Ok(
        provider_repair_core::discover_provider_operation_ownership_for_home(
            recovery_state.inner(),
            source.codex_home(),
        ),
    )
}
