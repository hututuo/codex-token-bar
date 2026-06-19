use crate::commands::local_source;
use crate::core::{
    dashboard::DashboardDataSource,
    live_rate::LiveRateMonitorService,
    startup_trace,
};
use crate::models::{
    FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption, UnreadSummary,
};
use crate::platform;
use std::sync::Mutex;
use tauri::State;

#[derive(Default)]
pub struct LiveRateMonitorRegistry {
    monitor: Mutex<Option<LiveRateMonitorService>>,
}

impl LiveRateMonitorRegistry {
    fn snapshot(&self, selected_thread_id: Option<&str>) -> Result<LiveRateSnapshot, String> {
        let codex_home = platform::default_codex_home();
        let mut monitor = self.monitor.lock().map_err(|error| error.to_string())?;
        if monitor
            .as_ref()
            .is_none_or(|current| current.codex_home() != codex_home)
        {
            *monitor = Some(LiveRateMonitorService::new(codex_home));
        }
        Ok(monitor
            .as_ref()
            .expect("live rate monitor should be initialized")
            .snapshot(selected_thread_id))
    }

    fn floating_snapshot(&self) -> Result<FloatingPanelSnapshot, String> {
        let codex_home = platform::default_codex_home();
        let mut monitor = self.monitor.lock().map_err(|error| error.to_string())?;
        if monitor
            .as_ref()
            .is_none_or(|current| current.codex_home() != codex_home)
        {
            *monitor = Some(LiveRateMonitorService::new(codex_home));
        }
        Ok(monitor
            .as_ref()
            .expect("live rate monitor should be initialized")
            .floating_snapshot())
    }
}

#[tauri::command]
pub fn read_live_rate_snapshot(
    state: State<LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
) -> Result<LiveRateSnapshot, String> {
    startup_trace::mark_once("command read_live_rate_snapshot start");
    let result = state.snapshot(selected_thread_id.as_deref());
    startup_trace::mark_once("command read_live_rate_snapshot end");
    result
}

#[tauri::command]
pub fn read_live_thread_options() -> Result<Vec<LiveThreadOption>, String> {
    local_source().try_read_live_thread_options()
}

#[tauri::command]
pub fn start_live_rate_stream(
    state: State<LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
) -> Result<bool, String> {
    startup_trace::mark_once("command start_live_rate_stream start");
    let _ = state.snapshot(selected_thread_id.as_deref())?;
    startup_trace::mark_once("command start_live_rate_stream end");
    Ok(true)
}

#[tauri::command]
pub fn stop_live_rate_stream() -> Result<bool, String> {
    Ok(false)
}

#[tauri::command]
pub fn read_floating_snapshot(
    state: State<LiveRateMonitorRegistry>,
) -> Result<FloatingPanelSnapshot, String> {
    state.floating_snapshot()
}

#[tauri::command]
pub fn read_unread_summary() -> Result<UnreadSummary, String> {
    Ok(local_source().read_unread_summary())
}
