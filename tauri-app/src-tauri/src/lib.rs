mod commands;
mod core;
mod models;
mod platform;

use tauri::Manager as _;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 必须最先执行：此刻进程还是单线程，time crate 才允许读取本地时区
    // 偏移；一旦任何线程被创建，读取必然失败并回退 UTC。
    core::localtime::cache_local_offset_at_startup();
    let launch_mode = platform::StartupLaunchMode::from_args(std::env::args_os());
    match platform::prepare_single_instance(launch_mode) {
        platform::SingleInstanceLaunchOutcome::ContinueAsPrimary => {}
        platform::SingleInstanceLaunchOutcome::SecondaryExit => return,
        platform::SingleInstanceLaunchOutcome::FatalFailure(error) => {
            platform::report_startup_failure(&error);
            return;
        }
    }
    core::startup_trace::begin("primary process start");

    let app_result = tauri::Builder::default()
        .manage(commands::live::LiveRateMonitorRegistry::default())
        .manage(commands::thread_activity::ThreadActivityRegistry::default())
        .manage(commands::update::UpdateMonitorRegistry::default())
        .manage(commands::auto_resume::AutoResumeRegistry::default())
        .manage(core::provider_repair::ProviderRecoveryState::default())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--autostart"]),
        ))
        .setup(move |app| {
            core::startup_trace::mark("tauri setup entered");
            #[cfg(target_os = "windows")]
            tauri::async_runtime::spawn_blocking(|| match tauri::webview_version() {
                Ok(version) => core::startup_trace::mark(&format!(
                    "webview2 runtime version {version}"
                )),
                Err(error) => core::startup_trace::mark(&format!(
                    "webview2 runtime version unavailable: {error}"
                )),
            });
            // Start listening before any WebView or filesystem initialization. A second launch
            // can now distinguish a responsive primary from one stuck during startup.
            platform::start_instance_activation_listener(app.handle().clone());
            #[cfg(target_os = "windows")]
            if let Err(error) = platform::repair_windows_autostart_registration(app.handle()) {
                core::startup_trace::mark(&format!(
                    "windows autostart repair skipped: {error}"
                ));
            }

            let recovery_state = app
                .state::<core::provider_repair::ProviderRecoveryState>()
                .inner()
                .clone();
            tauri::async_runtime::spawn_blocking(move || {
                commands::startup::initialize_provider_recovery(&recovery_state);
            });
            app.handle()
                .plugin(tauri_plugin_updater::Builder::new().build())?;
            // The first visible surface must not wait for roaming AppData, recovery-candidate
            // scanning, or task-state hydration. Manual launch needs only the dashboard; the
            // persisted floating/tray preferences are applied after the event loop can run.
            platform::setup_desktop_surfaces(app, launch_mode, false)?;
            app.state::<commands::update::UpdateMonitorRegistry>()
                .initialize_and_start(app.handle().clone());
            app.state::<commands::auto_resume::AutoResumeRegistry>()
                .initialize_and_start(app.handle().clone());
            let deferred_app = app.handle().clone();
            let deferred_live = app
                .state::<commands::live::LiveRateMonitorRegistry>()
                .inner()
                .clone();
            tauri::async_runtime::spawn(async move {
                core::startup_trace::mark("deferred settings read scheduled");
                let settings = tauri::async_runtime::spawn_blocking(platform::read_app_settings)
                    .await
                    .map_err(|error| error.to_string())
                    .and_then(|result| result)
                    .unwrap_or_else(|error| {
                        eprintln!(
                            "Codex Token Bar: deferred settings read recovered with defaults: {error}"
                        );
                        models::AppSettingsSnapshot::default()
                    });
                core::startup_trace::mark("deferred settings read finished");
                if launch_mode == platform::StartupLaunchMode::Autostart
                    && settings.display_surfaces.floating_window_enabled
                {
                    if let Err(error) =
                        platform::show_floating_window_from_command(&deferred_app).await
                    {
                        eprintln!(
                            "Codex Token Bar: deferred floating window setup failed: {error}"
                        );
                    }
                }
                if let Err(error) = deferred_live
                    .sync_status_tray_interest(&deferred_app, &settings.display_surfaces)
                {
                    eprintln!("Codex Token Bar: status tray live text setup failed: {error}");
                }
            });
            core::thread_delete::start_supervisor();
            core::startup_trace::mark("tauri setup returning");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::dashboard::get_codex_home,
            commands::dashboard::set_codex_home,
            commands::dashboard::reset_codex_home,
            commands::settings::read_app_settings,
            commands::startup::record_startup_event,
            commands::settings::read_autostart_status,
            commands::settings::set_autostart_enabled,
            commands::settings::save_floating_settings,
            commands::settings::complete_floating_paging_guide,
            commands::settings::save_floating_position,
            commands::settings::save_display_surfaces,
            commands::settings::save_custom_account_display_name,
            commands::settings::save_quota_refresh_interval_ms,
            commands::settings::save_usage_refresh_settings,
            commands::settings::save_auto_resume_settings,
            commands::settings::save_session_enhancement_settings,
            commands::settings::save_setup_guide_completed,
            commands::startup::record_performance_event,
            commands::dashboard::read_platform_capabilities,
            commands::dashboard::read_account_quota,
            commands::dashboard::read_account_reset_credits,
            commands::dashboard::read_dashboard_snapshot,
            commands::dashboard::read_precise_dashboard_snapshot,
            commands::dashboard::schedule_precise_dashboard_aggregate,
            commands::dashboard::rebuild_precise_index_for_current_version,
            commands::dashboard::read_precise_dashboard_progress,
            commands::dashboard::read_precise_dashboard_source_probe,
            commands::dashboard::acknowledge_attribution_safety,
            commands::dashboard::read_usage_summary_snapshot,
            commands::dashboard::read_usage_cache_status,
            commands::codex_instances::list_codex_instances,
            commands::codex_instances::create_codex_instance,
            commands::codex_instances::import_codex_instance,
            commands::codex_instances::update_codex_instance,
            commands::codex_instances::delete_codex_instance,
            commands::codex_instances::read_codex_instance_runtime_status,
            commands::codex_instances::list_codex_instance_runtime_statuses,
            commands::codex_instances::launch_codex_instance,
            commands::codex_instances::focus_codex_instance,
            commands::codex_instances::stop_codex_instance,
            commands::codex_instances::preview_codex_instance_sync,
            commands::codex_instances::sync_codex_instances,
            commands::codex_instances::list_codex_instance_sync_transactions,
            commands::codex_instances::rollback_codex_instance_sync,
            commands::live::read_live_rate_snapshot,
            commands::live::read_live_thread_options,
            commands::live::reset_live_rate_monitor,
            commands::live::publish_status_indicator_readout,
            commands::live::claim_live_rate_owner_session,
            commands::live::start_live_rate_stream,
            commands::live::stop_live_rate_stream,
            commands::provider_repair::scan_provider_repair,
            commands::provider_repair::list_provider_backups,
            commands::provider_repair::create_provider_backup,
            commands::provider_repair::sync_provider_history,
            commands::provider_repair::migrate_provider_history,
            commands::provider_repair::verify_provider_repair,
            commands::provider_repair::rollback_provider_backup,
            commands::provider_repair::rebuild_conversation_visibility,
            commands::provider_repair::read_provider_operation_status,
            commands::provider_repair::discover_provider_operation_ownership,
            commands::codex_radar::read_codex_radar_full_snapshot,
            commands::codex_radar::read_codex_radar_window_countdown,
            commands::codex_radar::read_codex_crowd_radar_payload,
            commands::live::read_floating_snapshot,
            commands::live::read_unread_summary,
            commands::thread_activity::read_running_thread_summary,
            commands::live::acknowledge_current_unread,
            commands::surface::show_floating_window,
            commands::surface::hide_floating_window,
            commands::surface::show_dashboard_window,
            commands::surface::show_status_panel_window,
            commands::surface::hide_status_panel_window,
            commands::surface::dismiss_status_panel_on_blur,
            commands::update::read_app_update_state,
            commands::update::check_app_update,
            commands::update::install_app_update,
            commands::thread_delete::read_thread_delete_bridge_status,
            commands::thread_delete::reconnect_thread_delete_bridge,
            commands::thread_delete::enable_thread_delete_bridge,
            commands::auto_resume::list_auto_resume_threads,
            commands::auto_resume::read_auto_resume_status,
            commands::auto_resume::run_auto_resume_now,
            commands::auto_resume::cancel_auto_resume_run,
            commands::session_management::list_session_management_catalog,
            commands::session_management::read_session_context_page,
            commands::session_management::archive_session_threads,
            commands::session_management::unarchive_session_threads,
            commands::session_management::prepare_session_delete_confirmation,
            commands::session_management::delete_session_threads,
            commands::session_management::create_session_recovery_archives,
        ])
        .build(tauri::generate_context!());
    let run_result = app_result.map(|app| {
        app.run(|app, event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen {
                has_visible_windows,
                ..
            } = event
            {
                if let Err(error) =
                    platform::handle_application_reopen(app, has_visible_windows)
                {
                    core::startup_trace::mark(&format!(
                        "dashboard reopen failed: {error}"
                    ));
                }
            }
            #[cfg(not(target_os = "macos"))]
            let _ = (app, event);
        });
    });
    if let Err(error) = run_result {
        platform::report_startup_failure(&format!(
            "Codex Token Bar 运行时启动失败：{error}\n\n请检查 WebView2 Runtime、显卡驱动和应用数据目录权限。"
        ));
    }
}
