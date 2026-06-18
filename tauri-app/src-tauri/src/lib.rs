mod commands;
mod core;
mod models;
mod platform;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::get_codex_home,
            commands::read_dashboard_snapshot,
            commands::read_precise_dashboard_snapshot,
            commands::read_live_rate_snapshot,
            commands::scan_provider_repair,
            commands::read_floating_snapshot,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Codex Token Bar");
}
