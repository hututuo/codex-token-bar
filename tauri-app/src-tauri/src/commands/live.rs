use super::window_auth::require_window_label;
use crate::commands::dashboard::{
    capture_codex_home_source, validate_codex_home_source, with_valid_codex_home_source,
    CodexHomeSourceToken,
};
use crate::commands::local_source;
use crate::core::{
    dashboard::DashboardDataSource, live_rate::LiveRateMonitorService, startup_trace, unread,
};
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption, UnreadSummary};
use crate::platform;
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::async_runtime;
use tauri::{AppHandle, Emitter, State};

const LIVE_RATE_SNAPSHOT_EVENT: &str = "live-rate-snapshot";
const FAST_STREAM_INTERVAL: Duration = Duration::from_millis(250);
const IDLE_STREAM_INTERVAL: Duration = Duration::from_secs(1);
const ACTIVE_STREAM_HOLD: Duration = Duration::from_secs(10);

#[derive(Clone, Default)]
pub struct LiveRateMonitorRegistry {
    monitor: Arc<Mutex<Option<LiveRateMonitorService>>>,
    stream: Arc<Mutex<LiveRateStreamState>>,
}

#[derive(Default)]
struct LiveRateStreamState {
    leases: HashMap<String, LiveRateSubscription>,
    latest_owner_generation: HashMap<String, u64>,
    next_lease_id: u64,
    next_registration_sequence: u64,
    loop_generation: u64,
    running: bool,
}

#[derive(Clone, Debug)]
struct LiveRateSubscriptionSource {
    source_token: CodexHomeSourceToken,
    codex_home: PathBuf,
}

#[derive(Clone, Debug)]
struct LiveRateSubscription {
    source: LiveRateSubscriptionSource,
    owner_token: String,
    owner_generation: u64,
    registration_sequence: u64,
    selected_thread_id: Option<String>,
    controls_selected_thread: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveRateStreamLease {
    pub lease_id: String,
}

struct LiveRateSubscriptionStart {
    lease: LiveRateStreamLease,
    loop_generation: u64,
    should_spawn: bool,
}

struct LiveRateStreamRequest {
    source: LiveRateSubscriptionSource,
    selected_thread_id: Option<String>,
}

impl LiveRateMonitorRegistry {
    fn snapshot(&self, selected_thread_id: Option<&str>) -> Result<LiveRateSnapshot, String> {
        let codex_home = platform::default_codex_home();
        self.snapshot_at(codex_home, selected_thread_id)
    }

    fn snapshot_at(
        &self,
        codex_home: PathBuf,
        selected_thread_id: Option<&str>,
    ) -> Result<LiveRateSnapshot, String> {
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
        source: LiveRateSubscriptionSource,
        owner_token: String,
        owner_generation: u64,
        selected_thread_id: Option<String>,
        controls_selected_thread: bool,
    ) -> Result<LiveRateSubscriptionStart, String> {
        if owner_token.trim().is_empty() || owner_generation == 0 {
            return Err("live rate subscriber owner token and generation are required".into());
        }
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        stream.next_lease_id = stream
            .next_lease_id
            .checked_add(1)
            .ok_or_else(|| "live rate lease id overflow".to_string())?;
        stream.next_registration_sequence = stream
            .next_registration_sequence
            .checked_add(1)
            .ok_or_else(|| "live rate registration sequence overflow".to_string())?;
        let lease = LiveRateStreamLease {
            lease_id: format!("live-rate-{}", stream.next_lease_id),
        };
        let registration_sequence = stream.next_registration_sequence;
        let latest_owner_generation = stream
            .latest_owner_generation
            .get(&owner_token)
            .copied()
            .unwrap_or(0);
        if owner_generation < latest_owner_generation {
            return Ok(LiveRateSubscriptionStart {
                lease,
                loop_generation: stream.loop_generation,
                should_spawn: false,
            });
        }
        if owner_generation > latest_owner_generation {
            stream.leases.retain(|_, subscription| {
                subscription.owner_token != owner_token
                    || subscription.owner_generation >= owner_generation
            });
            stream
                .latest_owner_generation
                .insert(owner_token.clone(), owner_generation);
        }
        stream.leases.insert(
            lease.lease_id.clone(),
            LiveRateSubscription {
                source,
                owner_token,
                owner_generation,
                registration_sequence,
                selected_thread_id,
                controls_selected_thread,
            },
        );
        let should_spawn = !stream.running && active_subscription_count(&stream) > 0;
        if should_spawn {
            stream.running = true;
            stream.loop_generation = stream.loop_generation.saturating_add(1);
        }
        Ok(LiveRateSubscriptionStart {
            lease,
            loop_generation: stream.loop_generation,
            should_spawn,
        })
    }

    fn stop_subscription(&self, lease_id: &str) -> Result<bool, String> {
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        stream.leases.remove(lease_id);
        if active_subscription_count(&stream) == 0 {
            stream.running = false;
        }
        Ok(stream.running)
    }

    fn stream_snapshot_request(
        &self,
        loop_generation: u64,
    ) -> Result<LiveRateStreamRequest, String> {
        let current_source = capture_codex_home_source(None)?;
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        if !stream.running || stream.loop_generation != loop_generation {
            return Err("live rate stream has no active subscribers".into());
        }
        let selected = match selected_subscription_for_source(&stream, &current_source.source_token)
            .cloned()
        {
            Some(selected) => selected,
            None => {
                stream.running = false;
                return Err("live rate stream has no current-source subscribers".into());
            }
        };
        Ok(LiveRateStreamRequest {
            source: selected.source,
            selected_thread_id: if selected.controls_selected_thread {
                selected.selected_thread_id
            } else {
                None
            },
        })
    }

    fn spawn_stream_loop(&self, app: AppHandle, loop_generation: u64) {
        let registry = self.clone();
        async_runtime::spawn(async move {
            let mut last_active_at: Option<Instant> = None;
            loop {
                let request = match registry.stream_snapshot_request(loop_generation) {
                    Ok(request) => request,
                    Err(_) => break,
                };
                let snapshot_registry = registry.clone();
                let selected_for_snapshot = request.selected_thread_id.clone();
                let source_token = request.source.source_token.clone();
                let codex_home = request.source.codex_home;
                let started = Instant::now();
                let snapshot = async_runtime::spawn_blocking(move || {
                    snapshot_registry.snapshot_at(codex_home, selected_for_snapshot.as_deref())
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
                        startup_trace::mark_performance(format!(
                            "live_rate_stream_join_error {error}"
                        ));
                        sleep_stream_interval(IDLE_STREAM_INTERVAL).await;
                        continue;
                    }
                };

                let elapsed_ms = started.elapsed().as_millis();
                if elapsed_ms > 50 {
                    startup_trace::mark_performance(format!(
                        "live_rate_stream_tick {elapsed_ms}ms slow"
                    ));
                }
                let active =
                    snapshot.tokens_per_second > 0.05 || snapshot.selected_tokens_per_second > 0.05;
                if active {
                    last_active_at = Some(Instant::now());
                }
                let recently_active = last_active_at
                    .is_some_and(|last_active| last_active.elapsed() <= ACTIVE_STREAM_HOLD);
                if let Err(error) = with_valid_codex_home_source(&source_token, || {
                    app.emit(LIVE_RATE_SNAPSHOT_EVENT, snapshot)
                        .map_err(|error| error.to_string())
                }) {
                    startup_trace::mark_performance(format!(
                        "live_rate_stream_publish_skipped {error}"
                    ));
                    sleep_stream_interval(IDLE_STREAM_INTERVAL).await;
                    continue;
                }
                sleep_stream_interval(if recently_active {
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
        source: LiveRateSubscriptionSource,
        owner_token: &str,
        owner_generation: u64,
        selected_thread_id: Option<String>,
        controls_selected_thread: bool,
    ) -> LiveRateSubscriptionStart {
        self.start_subscription(
            source,
            owner_token.into(),
            owner_generation,
            selected_thread_id,
            controls_selected_thread,
        )
        .unwrap()
    }

    #[cfg(test)]
    fn test_stop_subscription(&self, lease_id: &str) -> bool {
        self.stop_subscription(lease_id).unwrap()
    }

    #[cfg(test)]
    fn test_stream_state(&self) -> (usize, bool, Option<String>) {
        let stream = self.stream.lock().unwrap();
        (
            active_subscription_count(&stream),
            stream.running,
            active_subscriptions(&stream)
                .filter(|subscription| subscription.controls_selected_thread)
                .max_by_key(|subscription| subscription.registration_sequence)
                .and_then(|subscription| subscription.selected_thread_id.clone()),
        )
    }

    #[cfg(test)]
    fn test_total_lease_count(&self) -> usize {
        self.stream.lock().unwrap().leases.len()
    }
}

fn active_subscriptions(
    stream: &LiveRateStreamState,
) -> impl Iterator<Item = &LiveRateSubscription> {
    stream.leases.values().filter(|subscription| {
        stream
            .latest_owner_generation
            .get(&subscription.owner_token)
            .is_some_and(|generation| *generation == subscription.owner_generation)
    })
}

fn active_subscription_count(stream: &LiveRateStreamState) -> usize {
    active_subscriptions(stream).count()
}

fn selected_subscription_for_source<'a>(
    stream: &'a LiveRateStreamState,
    source_token: &CodexHomeSourceToken,
) -> Option<&'a LiveRateSubscription> {
    active_subscriptions(stream)
        .filter(|subscription| subscription.source.source_token == *source_token)
        .filter(|subscription| subscription.controls_selected_thread)
        .max_by_key(|subscription| subscription.registration_sequence)
        .or_else(|| {
            active_subscriptions(stream)
                .filter(|subscription| subscription.source.source_token == *source_token)
                .max_by_key(|subscription| subscription.registration_sequence)
        })
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
    let result =
        run_blocking_command(move || registry.snapshot(selected_thread_id.as_deref())).await;
    startup_trace::mark_performance(format!(
        "read_live_rate_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    startup_trace::mark_once("command read_live_rate_snapshot end");
    result
}

#[tauri::command]
pub async fn read_live_thread_options(
    window: tauri::WebviewWindow,
) -> Result<Vec<LiveThreadOption>, String> {
    require_window_label(&window, "read_live_thread_options")?;
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
    subscriber_owner_token: String,
    owner_generation: u64,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<LiveRateStreamLease, String> {
    startup_trace::mark_once("command start_live_rate_stream start");
    let started = Instant::now();
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let captured_source_token = captured.source_token.clone();
    let subscription_source = LiveRateSubscriptionSource {
        source_token: captured.source_token,
        codex_home: captured.codex_home,
    };
    let registry = state.inner().clone();
    let result = run_blocking_command({
        let registry = registry.clone();
        move || {
            registry.start_subscription(
                subscription_source,
                subscriber_owner_token,
                owner_generation,
                selected_thread_id,
                controls_selected_thread.unwrap_or(false),
            )
        }
    })
    .await
    .and_then(|subscription| {
        if subscription.should_spawn {
            registry.spawn_stream_loop(app, subscription.loop_generation);
        }
        if let Err(error) = validate_codex_home_source(&captured_source_token) {
            let _ = registry.stop_subscription(&subscription.lease.lease_id);
            return Err(error);
        }
        Ok(subscription.lease)
    });
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
    lease_id: String,
) -> Result<bool, String> {
    let registry = state.inner().clone();
    run_blocking_command(move || registry.stop_subscription(&lease_id)).await
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
pub async fn acknowledge_current_unread(
    source_token: Option<CodexHomeSourceToken>,
) -> Result<UnreadSummary, String> {
    let started = Instant::now();
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let completed_source_token = captured.source_token.clone();
    let codex_home = captured.codex_home;
    let result = run_blocking_command(move || unread::acknowledge_current_unread(&codex_home))
        .await
        .and_then(|summary| {
            validate_codex_home_source(&completed_source_token)?;
            Ok(summary)
        });
    startup_trace::mark_performance(format!(
        "acknowledge_current_unread {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn reset_live_rate_monitor(
    window: tauri::WebviewWindow,
    state: State<'_, LiveRateMonitorRegistry>,
) -> Result<bool, String> {
    require_window_label(&window, "reset_live_rate_monitor")?;
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
        let source = live_source_for_test("source-a", 1);

        let first = registry.test_start_subscription(
            source.clone(),
            "dashboard-owner",
            1,
            Some("thread-a".into()),
            true,
        );
        let second = registry.test_start_subscription(source, "compact-owner", 1, None, false);
        assert!(first.should_spawn);
        assert!(!second.should_spawn);
        assert_eq!(
            registry.test_stream_state(),
            (2, true, Some("thread-a".into()))
        );

        assert!(registry.test_stop_subscription(&first.lease.lease_id));
        assert_eq!(registry.test_stream_state(), (1, true, None));

        assert!(!registry.test_stop_subscription(&second.lease.lease_id));
        assert_eq!(registry.test_stream_state(), (0, false, None));
    }

    #[test]
    fn compact_surface_subscription_does_not_clear_dashboard_selected_thread() {
        let registry = LiveRateMonitorRegistry::default();
        let source = live_source_for_test("source-a", 1);

        registry.test_start_subscription(
            source.clone(),
            "dashboard-owner",
            1,
            Some("thread-a".into()),
            true,
        );
        registry.test_start_subscription(source, "compact-owner", 1, None, false);

        assert_eq!(
            registry.test_stream_state(),
            (2, true, Some("thread-a".into()))
        );
    }

    #[test]
    fn delayed_older_owner_lease_cannot_replace_or_release_newer_selection() {
        let registry = LiveRateMonitorRegistry::default();
        let source_a = live_source_for_test("source-a", 1);
        let source_b = live_source_for_test("source-b", 2);

        let newer = registry.test_start_subscription(
            source_b,
            "dashboard-owner",
            2,
            Some("thread-b".into()),
            true,
        );
        let delayed_older = registry.test_start_subscription(
            source_a,
            "dashboard-owner",
            1,
            Some("thread-a".into()),
            true,
        );

        assert_eq!(
            registry.test_stream_state(),
            (1, true, Some("thread-b".into()))
        );
        assert_eq!(registry.test_total_lease_count(), 1);
        assert!(registry.test_stop_subscription(&delayed_older.lease.lease_id));
        assert_eq!(
            registry.test_stream_state(),
            (1, true, Some("thread-b".into()))
        );
        assert!(!registry.test_stop_subscription(&newer.lease.lease_id));
    }

    #[test]
    fn delayed_stale_source_from_an_old_owner_cannot_override_current_source() {
        let registry = LiveRateMonitorRegistry::default();
        let source_a = live_source_for_test("source-a", 1);
        let source_b = live_source_for_test("source-b", 2);
        let source_b_token = source_b.source_token.clone();

        registry.test_start_subscription(
            source_b,
            "dashboard-owner-b",
            1,
            Some("thread-b".into()),
            true,
        );
        registry.test_start_subscription(
            source_a,
            "dashboard-owner-a",
            1,
            Some("thread-a".into()),
            true,
        );

        let stream = registry.stream.lock().unwrap();
        let selected = selected_subscription_for_source(&stream, &source_b_token)
            .expect("B should remain selected for the current source");
        assert_eq!(selected.selected_thread_id.as_deref(), Some("thread-b"));
    }

    fn live_source_for_test(
        canonical_home_key: &str,
        transition_generation: u64,
    ) -> LiveRateSubscriptionSource {
        LiveRateSubscriptionSource {
            source_token: super::super::dashboard::CodexHomeSourceToken {
                canonical_home_key: canonical_home_key.into(),
                transition_generation,
            },
            codex_home: std::path::PathBuf::from(canonical_home_key),
        }
    }
}
