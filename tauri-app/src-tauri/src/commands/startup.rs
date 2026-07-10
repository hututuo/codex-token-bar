use crate::core::{provider_repair, startup_trace};
use crate::platform;
use provider_repair::{ProviderRecoveryState, ProviderRecoveryStatus};
use std::path::Path;

pub(crate) fn initialize_provider_recovery(
    recovery_state: &ProviderRecoveryState,
) -> ProviderRecoveryStatus {
    let codex_home = platform::default_codex_home();
    let status = match provider_repair::provider_recovery_backup_root() {
        Ok(backup_root) => initialize_provider_recovery_at(
            recovery_state,
            &codex_home,
            &backup_root,
            platform::codex_desktop_is_running,
        ),
        Err(error) => {
            let status = provider_repair::provider_recovery_blocked_status_for_home(
                &codex_home,
                "backupRootUnavailable",
                None,
                error,
            );
            recovery_state.replace(status.clone());
            status
        }
    };
    startup_trace::mark(&format!(
        "provider recovery startup {}",
        if status.blocked { "blocked" } else { "ready" }
    ));
    status
}

pub(crate) fn initialize_provider_recovery_at(
    recovery_state: &ProviderRecoveryState,
    codex_home: &Path,
    backup_root: &Path,
    probe: impl FnOnce() -> Result<bool, String>,
) -> ProviderRecoveryStatus {
    let status =
        provider_repair::reconcile_provider_recovery_on_startup_at(codex_home, backup_root, probe);
    recovery_state.replace(status.clone());
    status
}

#[tauri::command]
pub fn record_startup_event(label: String) -> Result<bool, String> {
    startup_trace::mark(&format!("frontend {label}"));
    Ok(true)
}

#[tauri::command]
pub fn record_performance_event(label: String) -> Result<bool, String> {
    startup_trace::mark_performance(label);
    Ok(true)
}
