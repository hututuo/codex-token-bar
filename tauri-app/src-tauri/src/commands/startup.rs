use crate::core::startup_trace;

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
