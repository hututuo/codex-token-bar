use super::window_auth::require_window_label;
use crate::commands::local_source;
use crate::core::{
    auto_resume, dashboard::DashboardDataSource, provider_repair as provider_repair_core,
};
use crate::models::{
    ConversationVisibilityRebuildResult, ProviderRepairActionResult, ProviderRepairBackupInfo,
    ProviderRepairSnapshot,
};
use provider_repair_core::{
    ProviderOperationError, ProviderOperationOwnershipDiscovery, ProviderOperationStatus,
    ProviderRecoveryState,
};
use std::path::Path;

fn execute_provider_mutation_command<T>(
    entrypoint: &'static str,
    codex_home: &Path,
    recovery_state: &ProviderRecoveryState,
    operation_id: &str,
    mutation: impl FnOnce(&Path, &str) -> Result<T, ProviderOperationError>,
) -> Result<T, ProviderOperationError> {
    execute_provider_mutation_command_with_reconciler(
        entrypoint,
        codex_home,
        recovery_state,
        operation_id,
        ProviderCommandRecoveryAdmission::Strict,
        |state, home| provider_repair_core::reconcile_provider_recovery_for_action(state, home),
        mutation,
    )
}

fn execute_provider_backup_rollback_command<T>(
    codex_home: &Path,
    recovery_state: &ProviderRecoveryState,
    operation_id: &str,
    mutation: impl FnOnce(&Path, &str) -> Result<T, ProviderOperationError>,
) -> Result<T, ProviderOperationError> {
    execute_provider_mutation_command_with_reconciler(
        "rollback_provider_backup",
        codex_home,
        recovery_state,
        operation_id,
        ProviderCommandRecoveryAdmission::ExplicitBackupRollback,
        |state, home| provider_repair_core::reconcile_provider_recovery_for_action(state, home),
        mutation,
    )
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ProviderCommandRecoveryAdmission {
    Strict,
    ExplicitBackupRollback,
}

fn execute_provider_mutation_command_with_reconciler<T>(
    entrypoint: &'static str,
    codex_home: &Path,
    recovery_state: &ProviderRecoveryState,
    operation_id: &str,
    admission: ProviderCommandRecoveryAdmission,
    mut reconcile: impl FnMut(
        &ProviderRecoveryState,
        &Path,
    ) -> Result<provider_repair_core::ProviderRecoveryStatus, ProviderOperationError>,
    mutation: impl FnOnce(&Path, &str) -> Result<T, ProviderOperationError>,
) -> Result<T, ProviderOperationError> {
    match reconcile(recovery_state, codex_home) {
        Ok(_) => {}
        Err(error)
            if entrypoint == "rollback_provider_backup"
                && admission == ProviderCommandRecoveryAdmission::ExplicitBackupRollback
                && is_matching_prepared_mutation_recovery(
                    recovery_state,
                    codex_home,
                    &error,
                ) =>
        {
            // The selected core rollback path validates the journal's exact source backup,
            // account/Home generation, and stopped-runtime gates before it writes anything.
        }
        Err(error) => return Err(error),
    }

    let result = mutation(codex_home, operation_id)?;
    if admission == ProviderCommandRecoveryAdmission::ExplicitBackupRollback {
        // The core rollback may have resolved the Prepared journal. Refresh the cached state
        // so the UI immediately sees whether recovery is ready or still requires intervention.
        reconcile(recovery_state, codex_home)?;
    }
    Ok(result)
}

fn is_matching_prepared_mutation_recovery(
    recovery_state: &ProviderRecoveryState,
    codex_home: &Path,
    error: &ProviderOperationError,
) -> bool {
    let ProviderOperationError::RecoveryBlocked {
        code,
        recovery_path,
        ..
    } = error
    else {
        return false;
    };
    if code != "mutationOwnershipUnproven" {
        return false;
    }

    let status = recovery_state.status_for_home(codex_home);
    status.blocked
        && status.code.as_deref() == Some("mutationOwnershipUnproven")
        && status.home_scope.is_some()
        && status.recovery_path.is_some()
        && status.recovery_path == *recovery_path
        && status
            .recovery_path
            .as_ref()
            .is_some_and(|path| path.is_file())
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
        execute_provider_backup_rollback_command(
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

#[tauri::command]
pub async fn rebuild_conversation_visibility(
    window: tauri::WebviewWindow,
    recovery_state: tauri::State<'_, ProviderRecoveryState>,
    operation_id: String,
) -> Result<ConversationVisibilityRebuildResult, ProviderOperationError> {
    require_window_label(&window, "rebuild_conversation_visibility")?;
    let codex_home = local_source().codex_home().to_path_buf();
    let recovery_state = recovery_state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        execute_provider_mutation_command(
            "rebuild_conversation_visibility",
            &codex_home,
            &recovery_state,
            &operation_id,
            |home, operation_id| {
                provider_repair_core::run_provider_stopped_operation(
                    home,
                    operation_id,
                    "官方会话索引重建",
                    auto_resume::rebuild_conversation_visibility_metadata,
                )
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

    fn set_blocked_recovery_for_test(
        state: &ProviderRecoveryState,
        code: &str,
        recovery_path: &Path,
    ) -> ProviderOperationError {
        let mut status = state.snapshot();
        status.blocked = true;
        status.code = Some(code.to_string());
        status.message = Some("injected recovery block".into());
        status.recovery_path = Some(recovery_path.to_path_buf());
        state.replace(status);
        ProviderOperationError::RecoveryBlocked {
            code: code.to_string(),
            message: "injected recovery block".into(),
            recovery_path: Some(recovery_path.to_path_buf()),
        }
    }

    #[test]
    fn only_matching_explicit_rollback_can_pass_prepared_recovery_admission() {
        static NEXT_FIXTURE: AtomicUsize = AtomicUsize::new(0);
        let fixture = std::env::temp_dir().join(format!(
            "provider-command-prepared-admission-{}-{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, Ordering::SeqCst)
        ));
        let home = fixture.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let journal_path = fixture.join("prepared-mutation.json");
        std::fs::write(&journal_path, "{}").unwrap();
        let state = ProviderRecoveryState::default();
        provider_repair_core::initialize_provider_recovery_state_for_test(&state, &home);

        let reconcile_calls = AtomicUsize::new(0);
        let mutation_calls = AtomicUsize::new(0);
        let restored = execute_provider_mutation_command_with_reconciler(
            "rollback_provider_backup",
            &home,
            &state,
            "explicit-prepared-rollback",
            ProviderCommandRecoveryAdmission::ExplicitBackupRollback,
            |state, _home| {
                if reconcile_calls.fetch_add(1, Ordering::SeqCst) == 0 {
                    Err(set_blocked_recovery_for_test(
                        state,
                        "mutationOwnershipUnproven",
                        &journal_path,
                    ))
                } else {
                    provider_repair_core::initialize_provider_recovery_state_for_test(
                        state, &home,
                    );
                    Ok(state.snapshot())
                }
            },
            |received_home, operation_id| {
                assert_eq!(received_home, home.as_path());
                assert_eq!(operation_id, "explicit-prepared-rollback");
                mutation_calls.fetch_add(1, Ordering::SeqCst);
                Ok("restored")
            },
        )
        .unwrap();
        assert_eq!(restored, "restored");
        assert_eq!(mutation_calls.load(Ordering::SeqCst), 1);
        assert_eq!(reconcile_calls.load(Ordering::SeqCst), 2);
        assert!(state
            .guard_destructive_action_for_home(&home)
            .is_ok());

        let strict_state = ProviderRecoveryState::default();
        provider_repair_core::initialize_provider_recovery_state_for_test(&strict_state, &home);
        let strict_mutations = AtomicUsize::new(0);
        let strict_result = execute_provider_mutation_command_with_reconciler(
            "sync_provider_history",
            &home,
            &strict_state,
            "ordinary-mutation",
            ProviderCommandRecoveryAdmission::Strict,
            |state, _home| {
                Err(set_blocked_recovery_for_test(
                    state,
                    "mutationOwnershipUnproven",
                    &journal_path,
                ))
            },
            |_, _| {
                strict_mutations.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
        );
        assert!(matches!(
            strict_result,
            Err(ProviderOperationError::RecoveryBlocked { ref code, .. })
                if code == "mutationOwnershipUnproven"
        ));
        assert_eq!(strict_mutations.load(Ordering::SeqCst), 0);

        let other_status_state = ProviderRecoveryState::default();
        provider_repair_core::initialize_provider_recovery_state_for_test(
            &other_status_state,
            &home,
        );
        let other_status_mutations = AtomicUsize::new(0);
        let other_status_result = execute_provider_mutation_command_with_reconciler(
            "rollback_provider_backup",
            &home,
            &other_status_state,
            "rollback-with-other-recovery-block",
            ProviderCommandRecoveryAdmission::ExplicitBackupRollback,
            |state, _home| {
                Err(set_blocked_recovery_for_test(
                    state,
                    "restoreTransactionIncomplete",
                    &journal_path,
                ))
            },
            |_, _| {
                other_status_mutations.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
        );
        assert!(matches!(
            other_status_result,
            Err(ProviderOperationError::RecoveryBlocked { ref code, .. })
                if code == "restoreTransactionIncomplete"
        ));
        assert_eq!(other_status_mutations.load(Ordering::SeqCst), 0);

        let other_home = fixture.join("other-home");
        std::fs::create_dir_all(&other_home).unwrap();
        let stale_home_state = ProviderRecoveryState::default();
        provider_repair_core::initialize_provider_recovery_state_for_test(
            &stale_home_state,
            &home,
        );
        let stale_home_mutations = AtomicUsize::new(0);
        let stale_home_result = execute_provider_mutation_command_with_reconciler(
            "rollback_provider_backup",
            &other_home,
            &stale_home_state,
            "rollback-with-stale-home-state",
            ProviderCommandRecoveryAdmission::ExplicitBackupRollback,
            |state, _home| {
                Err(set_blocked_recovery_for_test(
                    state,
                    "mutationOwnershipUnproven",
                    &journal_path,
                ))
            },
            |_, _| {
                stale_home_mutations.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
        );
        assert!(matches!(
            stale_home_result,
            Err(ProviderOperationError::RecoveryBlocked { ref code, .. })
                if code == "mutationOwnershipUnproven"
        ));
        assert_eq!(stale_home_mutations.load(Ordering::SeqCst), 0);

        std::fs::remove_dir_all(fixture).unwrap();
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
