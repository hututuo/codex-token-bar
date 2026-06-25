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
use std::time::{Duration, Instant};
use tauri::async_runtime;
use tauri::{AppHandle, Emitter, State};

const LIVE_RATE_SNAPSHOT_EVENT: &str = "live-rate-snapshot";
const FAST_STREAM_INTERVAL: Duration = Duration::from_millis(250);
const IDLE_STREAM_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Default)]
pub struct LiveRateMonitorRegistry {
    monitor: Arc<Mutex<Option<LiveRateMonitorService>>>,
    stream: Arc<Mutex<LiveRateStreamState>>,
}

#[derive(Default)]
struct LiveRateStreamState {
    subscriber_count: usize,
    running: bool,
    selected_thread_id: Option<String>,
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

    fn start_subscription(
        &self,
        selected_thread_id: Option<String>,
        controls_selected_thread: bool,
    ) -> Result<bool, String> {
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        stream.subscriber_count = stream.subscriber_count.saturating_add(1);
        if controls_selected_thread {
            stream.selected_thread_id = selected_thread_id;
        }
        let should_spawn = !stream.running;
        if should_spawn {
            stream.running = true;
        }
        Ok(should_spawn)
    }

    fn stop_subscription(&self) -> Result<bool, String> {
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        stream.subscriber_count = stream.subscriber_count.saturating_sub(1);
        if stream.subscriber_count == 0 {
            stream.running = false;
        }
        Ok(stream.running)
    }

    fn stream_snapshot_request(&self) -> Result<Option<String>, String> {
        let stream = self.stream.lock().map_err(|error| error.to_string())?;
        if !stream.running || stream.subscriber_count == 0 {
            return Err("live rate stream has no active subscribers".into());
        }
        Ok(stream.selected_thread_id.clone())
    }

    fn spawn_stream_loop(&self, app: AppHandle) {
        let registry = self.clone();
        async_runtime::spawn(async move {
            loop {
                let selected_thread_id = match registry.stream_snapshot_request() {
                    Ok(selected_thread_id) => selected_thread_id,
                    Err(_) => break,
                };
                let snapshot_registry = registry.clone();
                let selected_for_snapshot = selected_thread_id.clone();
                let started = Instant::now();
                let snapshot = async_runtime::spawn_blocking(move || {
                    snapshot_registry.snapshot(selected_for_snapshot.as_deref())
                })
                .await;
                let snapshot = match snapshot {
                    Ok(Ok(snapshot)) => snapshot,
                    Ok(Err(error)) => {
                        startup_trace::mark_performance(format!(
                            "live_rate_stream_tick {}ms error",
                            started.elapsed().as_millis()
                        ));
                        startup_trace::mark_performance(format!("live_rate_stream_error {error}"));
                        sleep_stream_interval(IDLE_STREAM_INTERVAL).await;
                        continue;
                    }
                    Err(error) => {
                        startup_trace::mark_performance(format!(
                            "live_rate_stream_tick {}ms error",
                            started.elapsed().as_millis()
                        ));
                        startup_trace::mark_performance(format!("live_rate_stream_join_error {error}"));
                        sleep_stream_interval(IDLE_STREAM_INTERVAL).await;
                        continue;
                    }
                };

                startup_trace::mark_performance(format!(
                    "live_rate_stream_tick {}ms ok",
                    started.elapsed().as_millis()
                ));
                let active = snapshot.tokens_per_second > 0.05
                    || snapshot.selected_tokens_per_second > 0.05;
                let _ = app.emit(LIVE_RATE_SNAPSHOT_EVENT, snapshot);
                sleep_stream_interval(if active {
                    FAST_STREAM_INTERVAL
                } else {
                    IDLE_STREAM_INTERVAL
                })
                .await;
            }
        });
    }

    #[cfg(test)]
    fn test_start_subscription(
        &self,
        selected_thread_id: Option<String>,
        controls_selected_thread: bool,
    ) -> bool {
        self.start_subscription(selected_thread_id, controls_selected_thread)
            .unwrap()
    }

    #[cfg(test)]
    fn test_stop_subscription(&self) -> bool {
        self.stop_subscription().unwrap()
    }

    #[cfg(test)]
    fn test_stream_state(&self) -> (usize, bool, Option<String>) {
        let stream = self.stream.lock().unwrap();
        (
            stream.subscriber_count,
            stream.running,
            stream.selected_thread_id.clone(),
        )
    }
}

async fn sleep_stream_interval(duration: Duration) {
    tokio::time::sleep(duration).await;
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
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
    controls_selected_thread: Option<bool>,
) -> Result<bool, String> {
    startup_trace::mark_once("command start_live_rate_stream start");
    let started = Instant::now();
    let registry = state.inner().clone();
    let result = run_blocking_command({
        let registry = registry.clone();
        move || {
            registry.start_subscription(
                selected_thread_id,
                controls_selected_thread.unwrap_or(false),
            )
        }
    })
    .await
    .map(|should_spawn| {
        if should_spawn {
            registry.spawn_stream_loop(app);
        }
        Ok(true)
    })
    .and_then(|result| result);
    startup_trace::mark_performance(format!(
        "start_live_rate_stream {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    startup_trace::mark_once("command start_live_rate_stream end");
    result
}

#[tauri::command]
pub async fn stop_live_rate_stream(
    state: State<'_, LiveRateMonitorRegistry>,
) -> Result<bool, String> {
    let registry = state.inner().clone();
    run_blocking_command(move || registry.stop_subscription()).await
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_subscription_refcount_reuses_single_background_loop() {
        let registry = LiveRateMonitorRegistry::default();

        assert!(registry.test_start_subscription(Some("thread-a".into()), true));
        assert!(!registry.test_start_subscription(None, false));
        assert_eq!(
            registry.test_stream_state(),
            (2, true, Some("thread-a".into()))
        );

        assert!(registry.test_stop_subscription());
        assert_eq!(
            registry.test_stream_state(),
            (1, true, Some("thread-a".into()))
        );

        assert!(!registry.test_stop_subscription());
        assert_eq!(
            registry.test_stream_state(),
            (0, false, Some("thread-a".into()))
        );
    }

    #[test]
    fn compact_surface_subscription_does_not_clear_dashboard_selected_thread() {
        let registry = LiveRateMonitorRegistry::default();

        assert!(registry.test_start_subscription(Some("thread-a".into()), true));
        assert!(!registry.test_start_subscription(None, false));

        assert_eq!(
            registry.test_stream_state(),
            (2, true, Some("thread-a".into()))
        );
    }
}
