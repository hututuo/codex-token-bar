mod commands;
mod core;
mod models;
mod platform;

use tauri::Manager as _;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let launch_mode = platform::StartupLaunchMode::from_args(std::env::args_os());
    match platform::prepare_single_instance(launch_mode) {
        platform::SingleInstanceLaunchOutcome::ContinueAsPrimary => {}
        platform::SingleInstanceLaunchOutcome::SecondaryExit => return,
        platform::SingleInstanceLaunchOutcome::FatalFailure(error) => {
            platform::report_startup_failure(&error);
            return;
        }
    }

    tauri::Builder::default()
        .manage(commands::live::LiveRateMonitorRegistry::default())
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
            let recovery_state =
                app.state::<core::provider_repair::ProviderRecoveryState>();
            commands::startup::initialize_provider_recovery(recovery_state.inner());
            app.handle()
                .plugin(tauri_plugin_updater::Builder::new().build())?;
            let settings = platform::read_app_settings().unwrap_or_default();
            platform::setup_desktop_surfaces(app, launch_mode, &settings)?;
            app.state::<commands::update::UpdateMonitorRegistry>()
                .initialize_and_start(app.handle().clone());
            app.state::<commands::auto_resume::AutoResumeRegistry>()
                .initialize_and_start(app.handle().clone());
            if let Err(error) = app
                .state::<commands::live::LiveRateMonitorRegistry>()
                .sync_status_tray_interest(app.handle(), &settings.display_surfaces)
            {
                eprintln!("Codex Token Bar: status tray live text setup failed: {error}");
            }
            platform::start_instance_activation_listener(app.handle().clone());
            core::thread_delete::start_supervisor();
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
            commands::settings::save_floating_position,
            commands::settings::save_display_surfaces,
            commands::settings::save_custom_account_display_name,
            commands::settings::save_quota_refresh_interval_ms,
            commands::settings::save_auto_resume_settings,
            commands::settings::save_session_enhancement_settings,
            commands::settings::save_setup_guide_completed,
            commands::startup::record_performance_event,
            commands::dashboard::read_platform_capabilities,
            commands::dashboard::read_account_quota,
            commands::dashboard::read_dashboard_snapshot,
            commands::dashboard::read_precise_dashboard_snapshot,
            commands::dashboard::read_usage_summary_snapshot,
            commands::dashboard::read_usage_cache_status,
            commands::live::read_live_rate_snapshot,
            commands::live::read_live_thread_options,
            commands::live::reset_live_rate_monitor,
            commands::live::claim_live_rate_owner_session,
            commands::live::start_live_rate_stream,
            commands::live::stop_live_rate_stream,
            commands::provider_repair::scan_provider_repair,
            commands::provider_repair::list_provider_backups,
            commands::provider_repair::create_provider_backup,
            commands::provider_repair::sync_provider_history,
            commands::provider_repair::verify_provider_repair,
            commands::provider_repair::rollback_provider_backup,
            commands::provider_repair::read_provider_operation_status,
            commands::provider_repair::discover_provider_operation_ownership,
            commands::codex_radar::read_codex_radar_full_snapshot,
            commands::live::read_floating_snapshot,
            commands::live::read_unread_summary,
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
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Codex Token Bar");
}
