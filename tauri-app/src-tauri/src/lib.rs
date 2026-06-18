mod commands;
mod core;
mod models;
mod platform;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(commands::LiveRateStreamState::default())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--autostart"]),
        ))
        .setup(|app| {
            platform::setup_desktop_surfaces(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_codex_home,
            commands::set_codex_home,
            commands::reset_codex_home,
            commands::read_app_settings,
            commands::read_autostart_status,
            commands::set_autostart_enabled,
            commands::save_floating_settings,
            commands::save_floating_position,
            commands::save_display_surfaces,
            commands::save_setup_guide_completed,
            commands::read_platform_capabilities,
            commands::read_account_quota,
            commands::read_dashboard_snapshot,
            commands::read_precise_dashboard_snapshot,
            commands::read_live_rate_snapshot,
            commands::read_live_thread_options,
            commands::start_live_rate_stream,
            commands::stop_live_rate_stream,
            commands::scan_provider_repair,
            commands::list_provider_backups,
            commands::create_provider_backup,
            commands::sync_provider_history,
            commands::verify_provider_repair,
            commands::rollback_provider_backup,
            commands::read_floating_snapshot,
            commands::show_floating_window,
            commands::hide_floating_window,
            commands::show_dashboard_window,
            commands::show_status_panel_window,
            commands::hide_status_panel_window,
            commands::set_status_tray_readout,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Codex Token Bar");
}
