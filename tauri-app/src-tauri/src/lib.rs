mod commands;
mod core;
mod models;
mod platform;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if platform::activate_existing_instance_and_exit() {
        return;
    }

    tauri::Builder::default()
        .manage(commands::live::LiveRateMonitorRegistry::default())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--autostart"]),
        ))
        .setup(|app| {
            platform::setup_desktop_surfaces(app)?;
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
            commands::settings::save_setup_guide_completed,
            commands::startup::record_performance_event,
            commands::dashboard::read_platform_capabilities,
            commands::dashboard::read_account_quota,
            commands::dashboard::read_dashboard_snapshot,
            commands::dashboard::read_precise_dashboard_snapshot,
            commands::live::read_live_rate_snapshot,
            commands::live::read_live_thread_options,
            commands::live::reset_live_rate_monitor,
            commands::live::start_live_rate_stream,
            commands::live::stop_live_rate_stream,
            commands::provider_repair::scan_provider_repair,
            commands::provider_repair::list_provider_backups,
            commands::provider_repair::create_provider_backup,
            commands::provider_repair::sync_provider_history,
            commands::provider_repair::verify_provider_repair,
            commands::provider_repair::rollback_provider_backup,
            commands::live::read_floating_snapshot,
            commands::live::read_unread_summary,
            commands::surface::show_floating_window,
            commands::surface::hide_floating_window,
            commands::surface::show_dashboard_window,
            commands::surface::show_status_panel_window,
            commands::surface::hide_status_panel_window,
            commands::surface::set_status_tray_readout,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Codex Token Bar");
}
