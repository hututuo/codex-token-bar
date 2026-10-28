use super::window_auth::require_window_label;
use crate::core::{business_startup, provider_repair, startup_trace};
use crate::platform;
use provider_repair::{ProviderRecoveryState, ProviderRecoveryStatus};
use std::path::Path;
use tauri::{Emitter as _, Manager as _, State};

const BUSINESS_STARTUP_STATE_EVENT: &str = "business-startup-state-changed";

#[tauri::command]
pub fn read_business_startup_state(
    window: tauri::WebviewWindow,
    startup: State<'_, business_startup::BusinessStartupCoordinator>,
) -> Result<business_startup::BusinessStartupSnapshot, String> {
    require_window_label(&window, "read_business_startup_state")?;
    Ok(startup.snapshot())
}

#[tauri::command]
pub fn retry_business_startup(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    startup: State<'_, business_startup::BusinessStartupCoordinator>,
) -> Result<business_startup::BusinessStartupSnapshot, String> {
    require_window_label(&window, "retry_business_startup")?;
    let coordinator = startup.inner().clone();
    coordinator.begin_retry()?;
    schedule_business_startup(app, coordinator.clone());
    Ok(coordinator.snapshot())
}

pub(crate) fn start_initial_business_startup(
    app: tauri::AppHandle,
    coordinator: business_startup::BusinessStartupCoordinator,
) {
    if coordinator.begin_initial() {
        schedule_business_startup(app, coordinator);
    }
}

fn schedule_business_startup(
    app: tauri::AppHandle,
    coordinator: business_startup::BusinessStartupCoordinator,
) {
    startup_trace::mark("business store bootstrap scheduled");
    tauri::async_runtime::spawn(async move {
        let result =
            tauri::async_runtime::spawn_blocking(crate::core::business_store_route::bootstrap)
                .await
                .map_err(|error| format!("本地业务数据初始化任务异常结束：{error}"))
                .and_then(|result| result);
        let snapshot = coordinator.finish(result);
        match snapshot.phase {
            business_startup::BusinessStartupPhase::Ready => {
                startup_trace::mark("business store bootstrap ready");
                super::multi_client_usage::initialize_background_refresh(app.clone());
                app.state::<super::auto_resume::AutoResumeRegistry>()
                    .initialize_and_start(app.clone());
                app.state::<super::modeltrace::ModelTraceRegistry>()
                    .initialize(app.clone());
            }
            business_startup::BusinessStartupPhase::Error => {
                let message = snapshot.message.as_deref().unwrap_or("unknown error");
                startup_trace::mark(&format!("business store bootstrap failed: {message}"));
                eprintln!("Codex Token Bar: business store bootstrap failed: {message}");
            }
            business_startup::BusinessStartupPhase::Preparing => {}
        }
        let _ = app.emit(BUSINESS_STARTUP_STATE_EVENT, snapshot);
    });
}

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
    probe: impl FnMut() -> Result<bool, String>,
) -> ProviderRecoveryStatus {
    let status =
        provider_repair::reconcile_provider_recovery_on_startup_at(codex_home, backup_root, probe);
    recovery_state.replace(status.clone());
    status
}

#[tauri::command]
pub async fn record_startup_event(
    window: tauri::WebviewWindow,
    label: String,
) -> Result<bool, String> {
    require_window_label(&window, "record_startup_event")?;
    // 埋点是追加写盘，不允许占用主线程/执行器线程。
    super::run_blocking_command(move || {
        startup_trace::mark(&format!("frontend {label}"));
        Ok(true)
    })
    .await
}

#[tauri::command]
pub async fn record_performance_event(
    window: tauri::WebviewWindow,
    label: String,
) -> Result<bool, String> {
    require_window_label(&window, "record_performance_event")?;
    super::run_blocking_command(move || {
        startup_trace::mark_performance(label);
        Ok(true)
    })
    .await
}
