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
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::async_runtime;
use tauri::State;

#[derive(Clone, Default)]
pub struct LiveRateMonitorRegistry {
    monitor: Arc<Mutex<Option<LiveRateMonitorService>>>,
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

    fn reset(&self) -> Result<(), String> {
        let monitor = self.monitor.lock().map_err(|error| error.to_string())?;
        if let Some(monitor) = monitor.as_ref() {
            monitor.reset();
        }
        Ok(())
    }
}

async fn run_blocking_command<T, F>(work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn read_live_rate_snapshot(
    state: State<'_, LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
) -> Result<LiveRateSnapshot, String> {
    startup_trace::mark_once("command read_live_rate_snapshot start");
    let started = Instant::now();
    let registry = state.inner().clone();
    let result = run_blocking_command(move || registry.snapshot(selected_thread_id.as_deref())).await;
    startup_trace::mark_performance(format!(
        "read_live_rate_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    startup_trace::mark_once("command read_live_rate_snapshot end");
    result
}

#[tauri::command]
pub async fn read_live_thread_options() -> Result<Vec<LiveThreadOption>, String> {
    let started = Instant::now();
    let result = run_blocking_command(|| local_source().try_read_live_thread_options()).await;
    startup_trace::mark_performance(format!(
        "read_live_thread_options {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn start_live_rate_stream(
    state: State<'_, LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
) -> Result<bool, String> {
    startup_trace::mark_once("command start_live_rate_stream start");
    let started = Instant::now();
    let registry = state.inner().clone();
    let result = run_blocking_command(move || {
        let _ = registry.snapshot(selected_thread_id.as_deref())?;
        Ok(true)
    })
    .await;
    startup_trace::mark_performance(format!(
        "start_live_rate_stream {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    startup_trace::mark_once("command start_live_rate_stream end");
    result
}

#[tauri::command]
pub fn stop_live_rate_stream() -> Result<bool, String> {
    Ok(false)
}

#[tauri::command]
pub async fn read_floating_snapshot(
    state: State<'_, LiveRateMonitorRegistry>,
) -> Result<FloatingPanelSnapshot, String> {
    let started = Instant::now();
    let registry = state.inner().clone();
    let result = run_blocking_command(move || registry.floating_snapshot()).await;
    startup_trace::mark_performance(format!(
        "read_floating_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn read_unread_summary() -> Result<UnreadSummary, String> {
    let started = Instant::now();
    let result = run_blocking_command(|| Ok(local_source().read_unread_summary())).await;
    startup_trace::mark_performance(format!(
        "read_unread_summary {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn reset_live_rate_monitor(
    state: State<'_, LiveRateMonitorRegistry>,
) -> Result<bool, String> {
    let started = Instant::now();
    let registry = state.inner().clone();
    let result = run_blocking_command(move || {
        registry.reset()?;
        Ok(true)
    })
    .await;
    startup_trace::mark_performance(format!(
        "reset_live_rate_monitor {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

fn result_status<T>(result: &Result<T, String>) -> &'static str {
    if result.is_ok() {
        "ok"
    } else {
        "error"
    }
}
