use crate::commands::local_source;
use crate::core::{
    dashboard::{DashboardDataSource, LocalCodexDataSource},
    startup_trace,
};
use crate::models::{
    FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption, UnreadSummary,
};
use crate::platform;
use std::{
    sync::{mpsc, Mutex},
    thread::{self, JoinHandle},
    time::Duration,
};
use tauri::{Emitter, State};

const LIVE_RATE_SNAPSHOT_EVENT: &str = "live-rate-snapshot";
const LIVE_RATE_STREAM_INTERVAL_MS: u64 = 250;

#[derive(Default)]
pub struct LiveRateStreamState {
    handle: Mutex<Option<LiveRateStreamHandle>>,
}

struct LiveRateStreamHandle {
    selected_thread_id: Option<String>,
    stop_sender: mpsc::Sender<()>,
    join_handle: Option<JoinHandle<()>>,
}

impl Drop for LiveRateStreamHandle {
    fn drop(&mut self) {
        let _ = self.stop_sender.send(());
        if let Some(join_handle) = self.join_handle.take() {
            let _ = join_handle.join();
        }
    }
}

#[tauri::command]
pub fn read_live_rate_snapshot(
    selected_thread_id: Option<String>,
) -> Result<LiveRateSnapshot, String> {
    startup_trace::mark_once("command read_live_rate_snapshot start");
    let result = local_source().try_read_live_rate_snapshot(selected_thread_id.as_deref());
    startup_trace::mark_once("command read_live_rate_snapshot end");
    result
}

#[tauri::command]
pub fn read_live_thread_options() -> Result<Vec<LiveThreadOption>, String> {
    local_source().try_read_live_thread_options()
}

#[tauri::command]
pub fn start_live_rate_stream(
    app: tauri::AppHandle,
    state: State<LiveRateStreamState>,
    selected_thread_id: Option<String>,
) -> Result<bool, String> {
    startup_trace::mark_once("command start_live_rate_stream start");
    let mut current = state.handle.lock().map_err(|error| error.to_string())?;
    if current
        .as_ref()
        .is_some_and(|handle| handle.selected_thread_id == selected_thread_id)
    {
        startup_trace::mark_once("command start_live_rate_stream end");
        return Ok(true);
    }
    current.take();

    let (stop_sender, stop_receiver) = mpsc::channel::<()>();
    let codex_home = platform::default_codex_home();
    let stream_selected_thread_id = selected_thread_id.clone();
    let join_handle = thread::Builder::new()
        .name("codex-token-bar-live-rate-stream".into())
        .spawn(move || {
            let source = LocalCodexDataSource::new(codex_home);
            let mut last_snapshot = None;
            loop {
                let snapshot =
                    source.read_live_rate_snapshot(stream_selected_thread_id.as_deref());
                if should_emit_live_rate(last_snapshot.as_ref(), &snapshot) {
                    let _ = app.emit(LIVE_RATE_SNAPSHOT_EVENT, &snapshot);
                    last_snapshot = Some(snapshot);
                }

                if stop_receiver
                    .recv_timeout(Duration::from_millis(LIVE_RATE_STREAM_INTERVAL_MS))
                    .is_ok()
                {
                    break;
                }
            }
        })
        .map_err(|error| error.to_string())?;

    *current = Some(LiveRateStreamHandle {
        selected_thread_id,
        stop_sender,
        join_handle: Some(join_handle),
    });
    startup_trace::mark_once("command start_live_rate_stream end");
    Ok(true)
}

#[tauri::command]
pub fn stop_live_rate_stream(state: State<LiveRateStreamState>) -> Result<bool, String> {
    let mut current = state.handle.lock().map_err(|error| error.to_string())?;
    current.take();
    Ok(false)
}

#[tauri::command]
pub fn read_floating_snapshot() -> Result<FloatingPanelSnapshot, String> {
    Ok(local_source().read_floating_snapshot())
}

#[tauri::command]
pub fn read_unread_summary() -> Result<UnreadSummary, String> {
    Ok(local_source().read_unread_summary())
}

fn should_emit_live_rate(
    previous: Option<&LiveRateSnapshot>,
    current: &LiveRateSnapshot,
) -> bool {
    let Some(previous) = previous else {
        return true;
    };

    (previous.tokens_per_second - current.tokens_per_second).abs() >= 0.05
        || previous.total_tokens_today != current.total_tokens_today
        || previous.requests_today != current.requests_today
        || previous.thread_title != current.thread_title
        || previous.scope_label != current.scope_label
        || previous.selected_thread_id != current.selected_thread_id
        || previous.selected_thread_title != current.selected_thread_title
        || (previous.selected_tokens_per_second - current.selected_tokens_per_second).abs() >= 0.05
        || previous.precise_enabled != current.precise_enabled
        || warning_signature(&previous.warnings) != warning_signature(&current.warnings)
}

fn warning_signature(warnings: &[crate::models::LocalDataWarning]) -> String {
    warnings
        .iter()
        .map(|warning| format!("{}:{}", warning.source, warning.message))
        .collect::<Vec<_>>()
        .join("\n")
}
