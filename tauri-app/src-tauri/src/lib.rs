mod commands;
mod core;
mod models;
mod platform;

use tauri::{
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, WebviewUrl, WebviewWindowBuilder,
};

const FLOATING_WINDOW_WIDTH: f64 = 296.0;
const FLOATING_WINDOW_HEIGHT: f64 = 98.0;
const STATUS_TRAY_ID: &str = "codex-token-bar-status";

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            create_floating_window(app)?;
            create_status_tray(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_codex_home,
            commands::read_account_quota,
            commands::read_dashboard_snapshot,
            commands::read_precise_dashboard_snapshot,
            commands::read_live_rate_snapshot,
            commands::scan_provider_repair,
            commands::list_provider_backups,
            commands::create_provider_backup,
            commands::sync_provider_history,
            commands::verify_provider_repair,
            commands::rollback_provider_backup,
            commands::read_floating_snapshot,
            commands::show_floating_window,
            commands::hide_floating_window,
            commands::set_status_tray_readout,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Codex Token Bar");
}

fn create_status_tray(app: &tauri::App) -> tauri::Result<()> {
    if app.tray_by_id(STATUS_TRAY_ID).is_some() {
        return Ok(());
    }

    TrayIconBuilder::with_id(STATUS_TRAY_ID)
        .title("0.0/s")
        .tooltip("Codex Token Bar")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if let Some(window) = tray.app_handle().get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        })
        .build(app)?;

    Ok(())
}

fn create_floating_window(app: &tauri::App) -> tauri::Result<()> {
    if app.get_webview_window("floating").is_some() {
        return Ok(());
    }

    WebviewWindowBuilder::new(app, "floating", WebviewUrl::App("index.html".into()))
        .title("Codex Token Bar Floating")
        .inner_size(FLOATING_WINDOW_WIDTH, FLOATING_WINDOW_HEIGHT)
        .min_inner_size(FLOATING_WINDOW_WIDTH, FLOATING_WINDOW_HEIGHT)
        .max_inner_size(FLOATING_WINDOW_WIDTH, FLOATING_WINDOW_HEIGHT)
        .position(48.0, 86.0)
        .decorations(false)
        .resizable(false)
        .focused(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .shadow(false)
        .transparent(true)
        .build()?;

    Ok(())
}
