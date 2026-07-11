use super::window_auth::require_window_label;
use crate::commands::dashboard::{
    capture_codex_home_source, emit_detected_source_transition,
    pin_captured_codex_home_source, validate_captured_codex_home_source,
    validate_codex_home_source, with_valid_codex_home_source, CapturedCodexHomeSource,
    CodexHomeSourceToken,
};
use crate::core::{
    live_rate::{self, LiveRateMonitorService, LiveRateSourceScope},
    startup_trace, unread,
};
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption, UnreadSummary};
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
const UNREAD_OBSERVATION_CADENCE: Duration = Duration::from_secs(15);
const UNREAD_REFRESH_RETRY_BACKOFF: Duration = Duration::from_secs(5);

#[derive(Clone, Default)]
pub struct LiveRateMonitorRegistry {
    monitor: Arc<Mutex<Option<Arc<LiveRateMonitorService>>>>,
    stream: Arc<Mutex<LiveRateStreamState>>,
    unread_cache: Arc<Mutex<HashMap<String, CachedUnreadSummary>>>,
}

#[derive(Clone)]
struct CachedUnreadSummary {
    summary: UnreadSummary,
    refreshed_at: Instant,
    last_attempt: Instant,
    retry_after: Option<Instant>,
    failed_attempts: u32,
    last_error: Option<String>,
}

#[derive(Default)]
struct LiveRateStreamState {
    leases: HashMap<String, LiveRateSubscription>,
    latest_owner_version: HashMap<String, LiveRateOwnerVersion>,
    next_lease_id: u64,
    next_registration_sequence: u64,
    loop_generation: u64,
    running: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
struct LiveRateOwnerVersion {
    session_epoch: u64,
    generation: u64,
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
    owner_session_epoch: u64,
    owner_generation: u64,
    registration_sequence: u64,
    selected_thread_id: Option<String>,
    controls_selected_thread: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveRateStreamLease {
    pub lease_id: String,
    pub registered: bool,
}

struct LiveRateSubscriptionStart {
    lease: LiveRateStreamLease,
    loop_generation: u64,
    should_spawn: bool,
    registered: bool,
}

struct LiveRateStreamRequest {
    source: LiveRateSubscriptionSource,
    selected_thread_id: Option<String>,
}

impl LiveRateMonitorRegistry {
    fn unread_summary_for_source(
        &self,
        captured: &CapturedCodexHomeSource,
        force_refresh: bool,
    ) -> Result<UnreadSummary, String> {
        self.unread_summary_for_source_with_validator(captured, force_refresh, || {
            validate_captured_codex_home_source(captured)
        })
    }

    fn unread_summary_for_source_with_validator(
        &self,
        captured: &CapturedCodexHomeSource,
        force_refresh: bool,
        validate_before_write: impl FnOnce() -> Result<(), String>,
    ) -> Result<UnreadSummary, String> {
        self.unread_summary_for_source_with_refresh(captured, force_refresh, || {
            let pinned = pin_captured_codex_home_source(captured)?;
            unread::try_read_unread_summary_for_source(
                pinned.read_path(),
                &pinned.source_scope_key,
                validate_before_write,
            )
        })
    }

    fn unread_summary_for_source_with_refresh(
        &self,
        captured: &CapturedCodexHomeSource,
        force_refresh: bool,
        refresh: impl FnOnce() -> Result<UnreadSummary, String>,
    ) -> Result<UnreadSummary, String> {
        let source_scope_key = format!(
            "{}|{}",
            captured.source_token.canonical_home_key,
            captured.source_token.physical_home_key
        );
        let requested_at = Instant::now();
        let mut cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
        if force_refresh {
            if let Some(cached) = cache.get(&source_scope_key) {
                if cached.last_attempt >= requested_at {
                    return match cached.last_error.as_ref() {
                        Some(error) => Err(error.clone()),
                        None => Ok(cached.summary.clone()),
                    };
                }
            }
        }
        if !force_refresh {
            if let Some(cached) = cache.get(&source_scope_key) {
                if cached.refreshed_at.elapsed() < UNREAD_OBSERVATION_CADENCE {
                    return Ok(cached.summary.clone());
                }
                if cached
                    .retry_after
                    .is_some_and(|retry_after| Instant::now() < retry_after)
                {
                    return Ok(stale_unread_summary(
                        &cached.summary,
                        "refresh retry is backing off",
                    ));
                }
            }
        }
        let attempted_at = Instant::now();
        let summary = match refresh() {
            Ok(summary) => summary,
            Err(error) if !force_refresh => {
                if let Some(cached) = cache.get_mut(&source_scope_key) {
                    cached.last_attempt = attempted_at;
                    cached.failed_attempts = cached.failed_attempts.saturating_add(1);
                    cached.retry_after = Some(
                        attempted_at + unread_retry_backoff(cached.failed_attempts),
                    );
                    cached.last_error = Some(error.clone());
                    return Ok(stale_unread_summary(&cached.summary, &error));
                }
                let neutral = neutral_unread_summary(&error);
                cache.retain(|key, _| key == &source_scope_key);
                cache.insert(
                    source_scope_key,
                    CachedUnreadSummary {
                        summary: neutral.clone(),
                        refreshed_at: attempted_at - UNREAD_OBSERVATION_CADENCE,
                        last_attempt: attempted_at,
                        retry_after: Some(attempted_at + unread_retry_backoff(1)),
                        failed_attempts: 1,
                        last_error: Some(error),
                    },
                );
                return Ok(neutral);
            }
            Err(error) => {
                if let Some(cached) = cache.get_mut(&source_scope_key) {
                    cached.last_attempt = attempted_at;
                    cached.failed_attempts = cached.failed_attempts.saturating_add(1);
                    cached.retry_after = Some(
                        attempted_at + unread_retry_backoff(cached.failed_attempts),
                    );
                    cached.last_error = Some(error.clone());
                } else {
                    cache.retain(|key, _| key == &source_scope_key);
                    cache.insert(
                        source_scope_key,
                        CachedUnreadSummary {
                            summary: neutral_unread_summary(&error),
                            refreshed_at: attempted_at - UNREAD_OBSERVATION_CADENCE,
                            last_attempt: attempted_at,
                            retry_after: Some(attempted_at + unread_retry_backoff(1)),
                            failed_attempts: 1,
                            last_error: Some(error.clone()),
                        },
                    );
                }
                return Err(error);
            }
        };
        cache.retain(|key, _| key == &source_scope_key);
        cache.insert(
            source_scope_key,
            CachedUnreadSummary {
                summary: summary.clone(),
                refreshed_at: attempted_at,
                last_attempt: attempted_at,
                retry_after: None,
                failed_attempts: 0,
                last_error: None,
            },
        );
        Ok(summary)
    }

    fn store_unread_summary(
        &self,
        source_token: &CodexHomeSourceToken,
        summary: UnreadSummary,
    ) -> Result<(), String> {
        let source_scope_key = format!(
            "{}|{}",
            source_token.canonical_home_key, source_token.physical_home_key
        );
        let mut cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
        cache.retain(|key, _| key == &source_scope_key);
        cache.insert(
            source_scope_key,
            CachedUnreadSummary {
                summary,
                refreshed_at: Instant::now(),
                last_attempt: Instant::now(),
                retry_after: None,
                failed_attempts: 0,
                last_error: None,
            },
        );
        Ok(())
    }
    fn snapshot_at_with_unread(
        &self,
        source_token: CodexHomeSourceToken,
        codex_home: PathBuf,
        selected_thread_id: Option<&str>,
        unread_summary: UnreadSummary,
    ) -> Result<LiveRateSnapshot, String> {
        let monitor = self.monitor_for_source(source_token, codex_home)?;
        Ok(monitor.snapshot_with_unread(selected_thread_id, unread_summary))
    }

    fn floating_snapshot_with_unread(
        &self,
        source_token: CodexHomeSourceToken,
        codex_home: PathBuf,
        unread_summary: UnreadSummary,
    ) -> Result<FloatingPanelSnapshot, String> {
        let monitor = self.monitor_for_source(source_token, codex_home)?;
        Ok(monitor.floating_snapshot_with_unread(unread_summary))
    }

    fn monitor_for_source(
        &self,
        source_token: CodexHomeSourceToken,
        codex_home: PathBuf,
    ) -> Result<Arc<LiveRateMonitorService>, String> {
        let mut monitor = self.monitor.lock().map_err(|error| error.to_string())?;
        if monitor
            .as_ref()
            .is_none_or(|current| {
                current.codex_home() != codex_home
                    || current.source_scope() != &live_rate_source_scope(&source_token)
            })
        {
            *monitor = Some(Arc::new(LiveRateMonitorService::new_scoped(
                codex_home,
                live_rate_source_scope(&source_token),
            )));
        }
        Ok(Arc::clone(monitor
            .as_ref()
            .expect("live rate monitor should be initialized")))
    }

    fn reset(&self) -> Result<(), String> {
        let monitor = self
            .monitor
            .lock()
            .map_err(|error| error.to_string())?
            .clone();
        if let Some(monitor) = monitor {
            monitor.reset();
        }
        Ok(())
    }

    fn start_subscription(
        &self,
        source: LiveRateSubscriptionSource,
        owner_token: String,
        owner_session_epoch: u64,
        owner_generation: u64,
        selected_thread_id: Option<String>,
        controls_selected_thread: bool,
    ) -> Result<LiveRateSubscriptionStart, String> {
        if owner_token.trim().is_empty() || owner_session_epoch == 0 || owner_generation == 0 {
            return Err(
                "live rate subscriber owner token, session epoch, and generation are required"
                    .into(),
            );
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
            registered: false,
        };
        let registration_sequence = stream.next_registration_sequence;
        let latest_owner_version = stream
            .latest_owner_version
            .get(&owner_token)
            .copied()
            .unwrap_or_default();
        let requested_version = LiveRateOwnerVersion {
            session_epoch: owner_session_epoch,
            generation: owner_generation,
        };
        if latest_owner_version.session_epoch != owner_session_epoch
            || requested_version <= latest_owner_version
        {
            return Ok(LiveRateSubscriptionStart {
                lease,
                loop_generation: stream.loop_generation,
                should_spawn: false,
                registered: false,
            });
        }
        stream.leases.retain(|_, subscription| {
            subscription.owner_token != owner_token
                || LiveRateOwnerVersion {
                    session_epoch: subscription.owner_session_epoch,
                    generation: subscription.owner_generation,
                } >= requested_version
        });
        stream
            .latest_owner_version
            .insert(owner_token.clone(), requested_version);
        let mut lease = lease;
        lease.registered = true;
        stream.leases.insert(
            lease.lease_id.clone(),
            LiveRateSubscription {
                source,
                owner_token,
                owner_session_epoch,
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
            registered: true,
        })
    }

    fn claim_owner_session(&self, owner_token: &str, session_epoch: u64) -> Result<bool, String> {
        if owner_token.trim().is_empty() || session_epoch == 0 {
            return Err("live rate owner token and session epoch are required".into());
        }
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        let current = stream
            .latest_owner_version
            .get(owner_token)
            .copied()
            .unwrap_or_default();
        if session_epoch < current.session_epoch {
            return Ok(false);
        }
        if session_epoch > current.session_epoch {
            stream.leases.retain(|_, subscription| {
                subscription.owner_token != owner_token
                    || subscription.owner_session_epoch >= session_epoch
            });
            stream.latest_owner_version.insert(
                owner_token.to_string(),
                LiveRateOwnerVersion {
                    session_epoch,
                    generation: 0,
                },
            );
            if active_subscription_count(&stream) == 0 {
                stream.running = false;
            }
        }
        Ok(true)
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

    fn publish_stream_if_current(
        &self,
        loop_generation: u64,
        publish: impl FnOnce() -> Result<(), String>,
    ) -> Result<bool, String> {
        let stream = self.stream.lock().map_err(|error| error.to_string())?;
        if !stream.running || stream.loop_generation != loop_generation {
            return Ok(false);
        }
        publish()?;
        Ok(true)
    }

    fn spawn_stream_loop(&self, app: AppHandle, loop_generation: u64) {
        let registry = self.clone();
        async_runtime::spawn(async move {
            let mut last_active_at: Option<Instant> = None;
            loop {
                if let Err(error) = emit_detected_source_transition(&app) {
                    startup_trace::mark_performance(format!(
                        "codex_home_source_detection_failed {error}"
                    ));
                    sleep_stream_interval(IDLE_STREAM_INTERVAL).await;
                    continue;
                }
                let request = match registry.stream_snapshot_request(loop_generation) {
                    Ok(request) => request,
                    Err(_) => break,
                };
                let snapshot_registry = registry.clone();
                let selected_for_snapshot = request.selected_thread_id.clone();
                let source_token = request.source.source_token.clone();
                let captured = match capture_codex_home_source(Some(&source_token)) {
                    Ok(captured) => captured,
                    Err(error) => {
                        startup_trace::mark_performance(format!(
                            "live_rate_stream_source_capture_failed {error}"
                        ));
                        sleep_stream_interval(IDLE_STREAM_INTERVAL).await;
                        continue;
                    }
                };
                let started = Instant::now();
                let snapshot = async_runtime::spawn_blocking(move || {
                    let unread_summary = snapshot_registry
                        .unread_summary_for_source(&captured, false)?;
                    snapshot_registry.snapshot_at_with_unread(
                        captured.source_token.clone(),
                        captured.codex_home.clone(),
                        selected_for_snapshot.as_deref(),
                        unread_summary,
                    )
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
                match with_valid_codex_home_source(&source_token, || {
                    registry.publish_stream_if_current(loop_generation, || {
                        app.emit(LIVE_RATE_SNAPSHOT_EVENT, snapshot)
                            .map_err(|error| error.to_string())
                    })
                }) {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(error) => {
                        startup_trace::mark_performance(format!(
                            "live_rate_stream_publish_skipped {error}"
                        ));
                        sleep_stream_interval(IDLE_STREAM_INTERVAL).await;
                        continue;
                    }
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
        self.claim_owner_session(owner_token, 1).unwrap();
        self.start_subscription(
            source,
            owner_token.into(),
            1,
            owner_generation,
            selected_thread_id,
            controls_selected_thread,
        )
        .unwrap()
    }

    #[cfg(test)]
    fn test_claim_owner_session(&self, owner_token: &str, session_epoch: u64) -> bool {
        self.claim_owner_session(owner_token, session_epoch)
            .unwrap()
    }

    #[cfg(test)]
    fn test_start_subscription_with_session(
        &self,
        source: LiveRateSubscriptionSource,
        owner_token: &str,
        owner_session_epoch: u64,
        owner_generation: u64,
        selected_thread_id: Option<String>,
        controls_selected_thread: bool,
    ) -> LiveRateSubscriptionStart {
        self.start_subscription(
            source,
            owner_token.into(),
            owner_session_epoch,
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

    #[cfg(test)]
    fn test_monitor_physical_scope(&self) -> Option<String> {
        self.monitor
            .lock()
            .unwrap()
            .as_ref()
            .map(|monitor| monitor.source_scope().physical_home_key.clone())
    }

    #[cfg(test)]
    fn test_monitor_service(&self) -> Arc<LiveRateMonitorService> {
        self.monitor.lock().unwrap().as_ref().unwrap().clone()
    }

    #[cfg(test)]
    fn test_publish_stream_if_current(
        &self,
        loop_generation: u64,
        publish: impl FnOnce() -> Result<(), String>,
    ) -> Result<bool, String> {
        self.publish_stream_if_current(loop_generation, publish)
    }
}

fn live_rate_source_scope(source_token: &CodexHomeSourceToken) -> LiveRateSourceScope {
    LiveRateSourceScope::new(
        source_token.canonical_home_key.clone(),
        source_token.physical_home_key.clone(),
    )
}

fn stale_unread_summary(summary: &UnreadSummary, error: &str) -> UnreadSummary {
    let mut stale = summary.clone();
    stale.detail = format!("{} · unread refresh failed; using cached value: {error}", stale.detail);
    stale.source = format!("{}_stale", stale.source.trim_end_matches("_stale"));
    stale
}

fn neutral_unread_summary(error: &str) -> UnreadSummary {
    UnreadSummary {
        active: false,
        count: 0,
        label: "Unread unavailable".into(),
        detail: format!("Unread refresh failed; retry is scheduled: {error}"),
        source: "unread_error_cached".into(),
    }
}

fn unread_retry_backoff(failed_attempts: u32) -> Duration {
    let multiplier = 1u64 << failed_attempts.saturating_sub(1).min(3);
    Duration::from_secs(
        (UNREAD_REFRESH_RETRY_BACKOFF.as_secs() * multiplier).min(30),
    )
}

fn active_subscriptions(
    stream: &LiveRateStreamState,
) -> impl Iterator<Item = &LiveRateSubscription> {
    stream.leases.values().filter(|subscription| {
        stream
            .latest_owner_version
            .get(&subscription.owner_token)
            .is_some_and(|version| {
                *version
                    == LiveRateOwnerVersion {
                        session_epoch: subscription.owner_session_epoch,
                        generation: subscription.owner_generation,
                    }
            })
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

#[cfg(test)]
fn run_source_bound_work<T>(
    mut validate_source: impl FnMut() -> Result<(), String>,
    work: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    validate_source()?;
    let result = work()?;
    validate_source()?;
    Ok(result)
}

fn acknowledge_pinned_unread(
    captured: CapturedCodexHomeSource,
    after_pin: impl FnOnce() -> Result<(), String>,
    validate_before_write: impl FnOnce() -> Result<(), String>,
) -> Result<UnreadSummary, String> {
    let pinned = pin_captured_codex_home_source(&captured)?;
    after_pin()?;
    unread::acknowledge_current_unread_for_source(
        pinned.read_path(),
        &pinned.source_scope_key,
        validate_before_write,
    )
}

#[tauri::command]
pub async fn read_live_rate_snapshot(
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<LiveRateSnapshot, String> {
    startup_trace::mark_once("command read_live_rate_snapshot start");
    let started = Instant::now();
    let registry = state.inner().clone();
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let completed_source_token = captured.source_token.clone();
    let result = run_blocking_command(move || {
        let unread_summary = registry.unread_summary_for_source(&captured, false)?;
        registry.snapshot_at_with_unread(
            captured.source_token.clone(),
            captured.codex_home.clone(),
            selected_thread_id.as_deref(),
            unread_summary,
        )
    })
    .await
    .and_then(|snapshot| {
        emit_detected_source_transition(&app)?;
        validate_codex_home_source(&completed_source_token)?;
        Ok(snapshot)
    });
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
    app: AppHandle,
    window: tauri::WebviewWindow,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<Vec<LiveThreadOption>, String> {
    require_window_label(&window, "read_live_thread_options")?;
    let started = Instant::now();
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let completed_source_token = captured.source_token.clone();
    let result = run_blocking_command(move || {
        live_rate::try_read_thread_options(&captured.codex_home).map_err(|error| error.to_string())
    })
    .await
    .and_then(|options| {
        emit_detected_source_transition(&app)?;
        validate_codex_home_source(&completed_source_token)?;
        Ok(options)
    });
    startup_trace::mark_performance(format!(
        "read_live_thread_options {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn claim_live_rate_owner_session(
    app: AppHandle,
    window: tauri::WebviewWindow,
    state: State<'_, LiveRateMonitorRegistry>,
    subscriber_owner_token: String,
    owner_session_epoch: u64,
    source_token: CodexHomeSourceToken,
) -> Result<bool, String> {
    require_live_rate_owner(window.label(), &subscriber_owner_token)?;
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(Some(&source_token))?;
    let completed_source_token = captured.source_token;
    let registry = state.inner().clone();
    run_blocking_command(move || {
        registry.claim_owner_session(&subscriber_owner_token, owner_session_epoch)
    })
    .await
    .and_then(|claimed| {
        emit_detected_source_transition(&app)?;
        validate_codex_home_source(&completed_source_token)?;
        Ok(claimed)
    })
}

#[tauri::command]
pub async fn start_live_rate_stream(
    app: AppHandle,
    window: tauri::WebviewWindow,
    state: State<'_, LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
    controls_selected_thread: Option<bool>,
    subscriber_owner_token: String,
    owner_session_epoch: u64,
    owner_generation: u64,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<LiveRateStreamLease, String> {
    require_live_rate_owner(window.label(), &subscriber_owner_token)?;
    startup_trace::mark_once("command start_live_rate_stream start");
    let started = Instant::now();
    emit_detected_source_transition(&app)?;
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
                owner_session_epoch,
                owner_generation,
                selected_thread_id,
                controls_selected_thread.unwrap_or(false),
            )
        }
    })
    .await
    .and_then(|subscription| {
        if !subscription.registered {
            return Ok(subscription.lease);
        }
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

fn require_live_rate_owner(window_label: &str, owner_token: &str) -> Result<(), String> {
    let expected = match window_label {
        "main" => "dashboard-live-rate",
        "floating" => "floating-live-rate",
        "status" => "status-live-rate",
        _ => {
            return Err(format!(
                "live rate is not available from the {window_label} window"
            ))
        }
    };
    if owner_token == expected {
        Ok(())
    } else {
        Err(format!(
            "live rate owner {owner_token} does not match the {window_label} window"
        ))
    }
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
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<FloatingPanelSnapshot, String> {
    let started = Instant::now();
    let registry = state.inner().clone();
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let completed_source_token = captured.source_token.clone();
    let result = run_blocking_command(move || {
        let unread_summary = registry.unread_summary_for_source(&captured, false)?;
        registry.floating_snapshot_with_unread(
            captured.source_token.clone(),
            captured.codex_home.clone(),
            unread_summary,
        )
    })
    .await
    .and_then(|snapshot| {
        emit_detected_source_transition(&app)?;
        validate_codex_home_source(&completed_source_token)?;
        Ok(snapshot)
    });
    startup_trace::mark_performance(format!(
        "read_floating_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn read_unread_summary(
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<UnreadSummary, String> {
    let started = Instant::now();
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let completed_source_token = captured.source_token.clone();
    let registry = state.inner().clone();
    let result = run_blocking_command(move || registry.unread_summary_for_source(&captured, true))
    .await
    .and_then(|summary| {
        emit_detected_source_transition(&app)?;
        validate_codex_home_source(&completed_source_token)?;
        Ok(summary)
    });
    startup_trace::mark_performance(format!(
        "read_unread_summary {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn acknowledge_current_unread(
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<UnreadSummary, String> {
    let started = Instant::now();
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let completed_source_token = captured.source_token.clone();
    let registry = state.inner().clone();
    let result = run_blocking_command(move || {
        let summary = acknowledge_pinned_unread(
            captured.clone(),
            || Ok(()),
            || validate_captured_codex_home_source(&captured),
        )?;
        registry.store_unread_summary(&captured.source_token, summary.clone())?;
        Ok(summary)
    })
    .await
    .and_then(|summary| {
        emit_detected_source_transition(&app)?;
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
    fn completed_tick_from_replaced_loop_generation_is_discarded() {
        use std::sync::mpsc;

        let registry = LiveRateMonitorRegistry::default();
        let source = live_source_for_test("source-a", 1);
        let old = registry.test_start_subscription(
            source.clone(),
            "compact-owner",
            1,
            None,
            false,
        );
        let (tick_started_tx, tick_started_rx) = mpsc::channel();
        let (release_tick_tx, release_tick_rx) = mpsc::channel();
        let old_registry = registry.clone();
        let old_generation = old.loop_generation;
        let old_tick = std::thread::spawn(move || {
            tick_started_tx.send(()).unwrap();
            release_tick_rx.recv().unwrap();
            let mut emitted = Vec::new();
            let published = old_registry
                .test_publish_stream_if_current(old_generation, || {
                    emitted.push("old-payload");
                    Ok(())
                })
                .unwrap();
            (published, emitted)
        });
        tick_started_rx.recv().unwrap();

        assert!(!registry.test_stop_subscription(&old.lease.lease_id));
        let new = registry.test_start_subscription(source, "compact-owner", 2, None, false);
        assert!(new.should_spawn);
        assert_ne!(new.loop_generation, old.loop_generation);

        release_tick_tx.send(()).unwrap();
        let (published, emitted) = old_tick.join().unwrap();
        assert!(!published);
        assert!(emitted.is_empty());
        assert!(registry
            .test_publish_stream_if_current(new.loop_generation, || Ok(()))
            .unwrap());
    }

    #[test]
    fn same_path_physical_source_change_replaces_monitor_service() {
        use std::sync::mpsc;

        let registry = LiveRateMonitorRegistry::default();
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-monitor-source-scope-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let unread = neutral_unread_summary("test");
        let source_a = live_source_for_test("physical-a", 1);
        let source_b = live_source_for_test("physical-b", 2);

        registry
            .snapshot_at_with_unread(source_a.source_token, root.clone(), None, unread.clone())
            .unwrap();
        assert_eq!(
            registry.test_monitor_physical_scope().as_deref(),
            Some("physical:physical-a")
        );
        let old_monitor = registry.test_monitor_service();
        old_monitor.reset();
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let slow = std::thread::spawn(move || {
            old_monitor.test_snapshot_after_claim(None, || {
                started_tx.send(()).unwrap();
                release_rx.recv().unwrap();
            })
        });
        started_rx.recv().unwrap();
        registry
            .snapshot_at_with_unread(source_b.source_token, root.clone(), None, unread)
            .unwrap();
        assert_eq!(
            registry.test_monitor_physical_scope().as_deref(),
            Some("physical:physical-b")
        );
        release_tx.send(()).unwrap();
        let _ = slow.join().unwrap();

        let _ = std::fs::remove_dir_all(root);
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

    #[test]
    fn newer_webview_session_rejects_unobserved_late_start_from_old_session() {
        let registry = LiveRateMonitorRegistry::default();
        let source = live_source_for_test("source-a", 1);

        assert!(registry.test_claim_owner_session("dashboard-live-rate", 2));
        let current = registry.test_start_subscription_with_session(
            source.clone(),
            "dashboard-live-rate",
            2,
            1,
            Some("thread-b".into()),
            true,
        );
        let late_old = registry.test_start_subscription_with_session(
            source,
            "dashboard-live-rate",
            1,
            99,
            Some("thread-a".into()),
            true,
        );

        assert!(current.registered);
        assert!(!late_old.registered);
        assert_eq!(registry.test_total_lease_count(), 1);
        assert_eq!(
            registry.test_stream_state(),
            (1, true, Some("thread-b".into()))
        );
    }

    #[test]
    fn stable_surface_owner_ids_are_bound_to_their_webview_labels() {
        assert!(require_live_rate_owner("main", "dashboard-live-rate").is_ok());
        assert!(require_live_rate_owner("floating", "floating-live-rate").is_ok());
        assert!(require_live_rate_owner("status", "status-live-rate").is_ok());
        assert!(require_live_rate_owner("status", "dashboard-live-rate").is_err());
        assert!(require_live_rate_owner("unknown", "dashboard-live-rate").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn production_unread_cadence_pins_once_across_consecutive_live_ticks() {
        use std::os::unix::fs::MetadataExt;

        let _counter_guard = super::super::dashboard::pinned_source_counter_test_guard();
        super::super::dashboard::reset_pinned_source_copy_count_for_test();
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-live-no-pinned-copy-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let registry = LiveRateMonitorRegistry::default();
        let metadata = std::fs::metadata(&root).unwrap();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: root.display().to_string(),
                physical_home_key: format!("unix:{}:{}", metadata.dev(), metadata.ino()),
                transition_generation: 1,
            },
            codex_home: root.clone(),
            source_path: root.clone(),
        };

        registry
            .unread_summary_for_source_with_validator(&captured, false, || Ok(()))
            .unwrap();
        registry
            .unread_summary_for_source_with_validator(&captured, false, || Ok(()))
            .unwrap();

        assert_eq!(
            super::super::dashboard::pinned_source_snapshot_count_for_test(),
            1
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn expired_cache_refresh_failure_backs_off_and_returns_trusted_stale_summary() {
        use std::os::unix::fs::MetadataExt;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-unread-backoff-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let metadata = std::fs::metadata(&root).unwrap();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: root.display().to_string(),
                physical_home_key: format!("unix:{}:{}", metadata.dev(), metadata.ino()),
                transition_generation: 1,
            },
            codex_home: root.clone(),
            source_path: root.clone(),
        };
        let key = format!(
            "{}|{}",
            captured.source_token.canonical_home_key,
            captured.source_token.physical_home_key
        );
        let registry = LiveRateMonitorRegistry::default();
        registry.unread_cache.lock().unwrap().insert(
            key,
            CachedUnreadSummary {
                summary: UnreadSummary {
                    active: true,
                    count: 3,
                    label: "trusted".into(),
                    detail: "trusted detail".into(),
                    source: "trusted_source".into(),
                },
                refreshed_at: Instant::now() - UNREAD_OBSERVATION_CADENCE,
                last_attempt: Instant::now() - UNREAD_OBSERVATION_CADENCE,
                retry_after: None,
                failed_attempts: 0,
                last_error: None,
            },
        );
        let attempts = AtomicUsize::new(0);

        for _ in 0..3 {
            let summary = registry
                .unread_summary_for_source_with_refresh(&captured, false, || {
                    attempts.fetch_add(1, Ordering::Relaxed);
                    Err("injected refresh failure".into())
                })
                .unwrap();
            assert_eq!(summary.count, 3);
            assert!(summary.source.ends_with("_stale"));
        }

        assert_eq!(attempts.load(Ordering::Relaxed), 1);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn concurrent_unread_refreshes_are_single_flight_per_source_scope() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::{Arc, Barrier};

        let registry = LiveRateMonitorRegistry::default();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "single-flight".into(),
                physical_home_key: "physical-single-flight".into(),
                transition_generation: 1,
            },
            codex_home: PathBuf::from("single-flight"),
            source_path: PathBuf::from("single-flight"),
        };
        let attempts = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(3));
        let handles = [(), ()].map(|_| {
            let registry = registry.clone();
            let captured = captured.clone();
            let attempts = attempts.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                registry
                    .unread_summary_for_source_with_refresh(&captured, false, || {
                        attempts.fetch_add(1, Ordering::Relaxed);
                        std::thread::sleep(Duration::from_millis(30));
                        Ok(UnreadSummary {
                            active: true,
                            count: 1,
                            label: "fresh".into(),
                            detail: "fresh".into(),
                            source: "test".into(),
                        })
                    })
                    .unwrap()
            })
        });
        barrier.wait();
        for handle in handles {
            assert_eq!(handle.join().unwrap().count, 1);
        }
        assert_eq!(attempts.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn cold_refresh_failure_is_negative_cached_for_live_ticks() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let registry = LiveRateMonitorRegistry::default();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "cold-failure".into(),
                physical_home_key: "physical-cold-failure".into(),
                transition_generation: 1,
            },
            codex_home: PathBuf::from("cold-failure"),
            source_path: PathBuf::from("cold-failure"),
        };
        let attempts = AtomicUsize::new(0);

        for _ in 0..3 {
            let summary = registry
                .unread_summary_for_source_with_refresh(&captured, false, || {
                    attempts.fetch_add(1, Ordering::Relaxed);
                    Err("cold injected failure".into())
                })
                .unwrap();
            assert!(summary.source.starts_with("unread_error_cached"));
        }
        assert_eq!(attempts.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn unread_refresh_backoff_is_bounded_exponential() {
        assert_eq!(unread_retry_backoff(1), Duration::from_secs(5));
        assert_eq!(unread_retry_backoff(2), Duration::from_secs(10));
        assert_eq!(unread_retry_backoff(3), Duration::from_secs(20));
        assert_eq!(unread_retry_backoff(4), Duration::from_secs(30));
        assert_eq!(unread_retry_backoff(20), Duration::from_secs(30));
    }

    #[test]
    fn floating_monitor_keeps_the_real_codex_home_path() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-floating-real-home-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let registry = LiveRateMonitorRegistry::default();
        let unread = UnreadSummary {
            active: false,
            count: 0,
            label: "none".into(),
            detail: "none".into(),
            source: "test".into(),
        };

        registry
            .floating_snapshot_with_unread(
                live_source_for_test("floating-physical", 1).source_token,
                root.clone(),
                unread,
            )
            .unwrap();

        assert_eq!(
            registry
                .monitor
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .codex_home(),
            root
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn stale_physical_source_guard_stops_unread_work_before_write() {
        let wrote = std::cell::Cell::new(false);
        let result = run_source_bound_work(
            || Err("physical Home replaced".into()),
            || {
                wrote.set(true);
                Ok(())
            },
        );

        assert_eq!(result.unwrap_err(), "physical Home replaced");
        assert!(!wrote.get());
    }

    #[cfg(unix)]
    #[test]
    fn a_to_b_to_a_swap_acknowledges_only_the_pinned_a_observation() {
        use std::os::unix::fs::MetadataExt;
        use std::sync::atomic::{AtomicU64, Ordering};

        let _counter_guard = super::super::dashboard::pinned_source_counter_test_guard();
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-pinned-ack-{}-{sequence}",
            std::process::id()
        ));
        let home = root.join("home");
        let displaced = root.join("home-a");
        let support = root.join("support");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&support).unwrap();
        let thread_a = "019eaaaa-0000-0000-0000-0000000000a1";
        let thread_b = "019eaaaa-0000-0000-0000-0000000000b1";
        write_unread_state_for_source_test(&home, thread_a);
        let _support_env = crate::core::usage::cache_lifecycle::usage_cache_test_state_guard(&[
            ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support.clone()),
        ]);
        let metadata = std::fs::metadata(&home).unwrap();
        let physical_home_key = format!("unix:{}:{}", metadata.dev(), metadata.ino());
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: home.display().to_string(),
                physical_home_key,
                transition_generation: 1,
            },
            codex_home: home.clone(),
            source_path: home.clone(),
        };

        let expected_physical_key = captured.source_token.physical_home_key.clone();
        let result = acknowledge_pinned_unread(captured, || {
            std::fs::rename(&home, &displaced).unwrap();
            std::fs::create_dir(&home).unwrap();
            write_unread_state_for_source_test(&home, thread_b);
            std::fs::remove_dir_all(&home).unwrap();
            std::fs::rename(&displaced, &home).unwrap();
            Ok(())
        }, || {
            let metadata = std::fs::metadata(&home).map_err(|error| error.to_string())?;
            let actual = format!("unix:{}:{}", metadata.dev(), metadata.ino());
            if actual == expected_physical_key {
                Ok(())
            } else {
                Err("physical source changed".into())
            }
        });

        assert_eq!(result.unwrap().count, 0);
        let baseline =
            std::fs::read_to_string(support.join("unread-acknowledgement.json")).unwrap();
        assert!(baseline.contains(thread_a));
        assert!(!baseline.contains(thread_b));

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    fn write_unread_state_for_source_test(home: &std::path::Path, thread_id: &str) {
        let date = time::OffsetDateTime::now_utc().date();
        let sessions = home
            .join("sessions")
            .join(format!("{:04}", date.year()))
            .join(format!("{:02}", u8::from(date.month())))
            .join(format!("{:02}", date.day()));
        std::fs::create_dir_all(&sessions).unwrap();
        let completed_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        std::fs::write(
            sessions.join("completion.jsonl"),
            format!(
                "{}\n{}\n",
                format!(r#"{{"type":"session_meta","payload":{{"id":"{thread_id}","thread_source":"user","source":"user"}}}}"#),
                format!(r#"{{"type":"event_msg","payload":{{"type":"task_complete","turn_id":"turn-1","completed_at":{completed_at}}}}}"#)
            ),
        )
        .unwrap();
    }

    fn live_source_for_test(
        canonical_home_key: &str,
        transition_generation: u64,
    ) -> LiveRateSubscriptionSource {
        LiveRateSubscriptionSource {
            source_token: super::super::dashboard::CodexHomeSourceToken {
                canonical_home_key: canonical_home_key.into(),
                physical_home_key: format!("physical:{canonical_home_key}"),
                transition_generation,
            },
            codex_home: std::path::PathBuf::from(canonical_home_key),
        }
    }
}
