mod commands;
mod core;
mod models;
mod platform;

use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

const FLOATING_WINDOW_WIDTH: f64 = 296.0;
const FLOATING_WINDOW_HEIGHT: f64 = 98.0;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            create_floating_window(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_codex_home,
            commands::read_account_quota,
            commands::read_dashboard_snapshot,
            commands::read_precise_dashboard_snapshot,
            commands::read_live_rate_snapshot,
            commands::scan_provider_repair,
            commands::read_floating_snapshot,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Codex Token Bar");
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
