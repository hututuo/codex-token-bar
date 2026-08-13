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
use crate::models::DisplaySurfaceSettingsSnapshot;
use crate::platform;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use tauri::async_runtime;
use tauri::{AppHandle, Emitter, State};

const LIVE_RATE_SNAPSHOT_EVENT: &str = "live-rate-snapshot";
const UNREAD_SUMMARY_CHANGED_EVENT: &str = "unread-summary-changed";
const FAST_STREAM_INTERVAL: Duration = Duration::from_millis(250);
const WEBVIEW_STREAM_INTERVAL: Duration = Duration::from_secs(1);
const IDLE_STREAM_INTERVAL: Duration = Duration::from_secs(1);
const ACTIVE_STREAM_HOLD: Duration = Duration::from_secs(10);
const UNREAD_OBSERVATION_CADENCE: Duration = Duration::from_secs(15);
const UNREAD_CACHE_LIMIT: usize = 8;
// 等待其他线程完成未读刷新的上限：慢盘上的刷新持有者可能长时间不返回，
// 并发 IPC 超时后用过期缓存（或中性摘要）兜底，绝不无上限阻塞。
const UNREAD_REFRESH_WAIT_TIMEOUT: Duration = Duration::from_millis(200);
const UNREAD_REFRESH_RETRY_BACKOFF: Duration = Duration::from_secs(5);

#[derive(Clone, Default)]
pub struct LiveRateMonitorRegistry {
    monitor: Arc<Mutex<Option<Arc<LiveRateMonitorService>>>>,
    stream: Arc<Mutex<LiveRateStreamState>>,
    unread_cache: Arc<Mutex<HashMap<String, CachedUnreadSummary>>>,
    unread_refreshes: Arc<Mutex<HashMap<String, Arc<UnreadRefreshSlot>>>>,
    unread_background_refreshes: Arc<Mutex<HashSet<String>>>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct UnreadSummaryChangedPayload {
    source_token: CodexHomeSourceToken,
    summary: UnreadSummary,
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
struct UnreadRefreshSlot {
    refreshing: Mutex<bool>,
    ready: Condvar,
}

struct UnreadRefreshOwner {
    slot: Arc<UnreadRefreshSlot>,
}

impl Drop for UnreadRefreshOwner {
    fn drop(&mut self) {
        let mut refreshing = self
            .slot
            .refreshing
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        *refreshing = false;
        drop(refreshing);
        self.slot.ready.notify_all();
    }
}

struct UnreadBackgroundRefreshOwner {
    sources: Arc<Mutex<HashSet<String>>>,
    source_scope_key: String,
}

impl Drop for UnreadBackgroundRefreshOwner {
    fn drop(&mut self) {
        let mut sources = self
            .sources
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        sources.remove(&self.source_scope_key);
    }
}

#[derive(Default)]
struct LiveRateStreamState {
    leases: HashMap<String, LiveRateSubscription>,
    latest_owner_version: HashMap<String, LiveRateOwnerVersion>,
    next_lease_id: u64,
    next_registration_sequence: u64,
    loop_generation: u64,
    running: bool,
    native_tray_enabled: bool,
    native_tray_source: Option<CodexHomeSourceToken>,
    native_tray_smoothed_rate: Option<f64>,
    native_tray_last_readout: Option<(String, String)>,
    native_tray_settings_key: Option<(bool, bool)>,
    native_tray_revision: u64,
    native_tray_desired_readout: Option<(String, String)>,
    native_tray_retry_running: bool,
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
    emit_webview: bool,
    update_native_tray: bool,
}

const TRAY_RATE_THRESHOLD: f64 = 0.05;
const TRAY_ALPHA_UP: f64 = 0.28;
const TRAY_ALPHA_DOWN: f64 = 0.18;
const NATIVE_TRAY_CORRECTION_RETRY_LIMIT: usize = 3;
const NATIVE_TRAY_CORRECTION_RETRY_DELAY: Duration = Duration::from_millis(250);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NativeTrayRetryFinish {
    Stop,
    Continue(u64),
}

impl LiveRateMonitorRegistry {
    pub fn sync_status_tray_interest(
        &self,
        app: &AppHandle,
        display: &DisplaySurfaceSettingsSnapshot,
    ) -> Result<(), String> {
        let composed_owner_active = composed_status_owner_active(display);
        platform::set_status_indicator_enabled_native(
            app,
            display.status_tray_live_text_enabled,
            composed_owner_active,
        )?;
        // Empty metric selection still belongs to the composed owner and must never revive
        // the legacy rate-only writer.
        self.suspend_native_tray_writer_for_composed_status()?;
        Ok(())
    }

    fn suspend_native_tray_writer_for_composed_status(&self) -> Result<(), String> {
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        stream.native_tray_revision = stream.native_tray_revision.saturating_add(1);
        stream.native_tray_enabled = false;
        stream.native_tray_source = None;
        stream.native_tray_smoothed_rate = None;
        stream.native_tray_settings_key = None;
        stream.native_tray_desired_readout = None;
        if active_subscription_count(&stream) == 0 {
            stream.running = false;
        }
        Ok(())
    }

    fn apply_status_tray_interest_with_writer_and_scheduler(
        &self,
        display: &DisplaySurfaceSettingsSnapshot,
        supported: bool,
        writer: impl FnMut(String, String) -> Result<bool, String>,
        schedule_correction: impl FnOnce(),
    ) -> Result<Option<u64>, String> {
        let stream_enabled = native_tray_settings(display, supported).0;
        let result = self.apply_status_tray_settings_with_writer(display, supported, writer);
        // A clean/disabled presentation has no live tick to repair a failed write. Its
        // correction owner is presentation-only and never enables the stream.
        if result.is_err() && !stream_enabled {
            schedule_correction();
        }
        result
    }

    fn apply_status_tray_settings_with_writer(
        &self,
        display: &DisplaySurfaceSettingsSnapshot,
        supported: bool,
        mut writer: impl FnMut(String, String) -> Result<bool, String>,
    ) -> Result<Option<u64>, String> {
        let settings_key = (
            supported && display.status_tray_live_text_enabled,
            display.live_rate_enabled,
        );
        let (stream_enabled, readout) = native_tray_settings(
            display,
            supported,
        );
        let revision = {
            let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
            if stream.native_tray_settings_key == Some(settings_key)
                && stream.native_tray_enabled == stream_enabled
                && stream.native_tray_last_readout.as_ref() == Some(&readout)
            {
                return Ok(None);
            }
            stream.native_tray_revision = stream.native_tray_revision.saturating_add(1);
            stream.native_tray_enabled = false;
            if active_subscription_count(&stream) == 0 {
                stream.running = false;
            }
            stream.native_tray_settings_key = None;
            stream.native_tray_desired_readout = Some(readout.clone());
            stream.native_tray_revision
        };
        self.write_native_presentation_revisioned(revision, readout, &mut writer)?;
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        if stream.native_tray_revision != revision {
            return Ok(None);
        }
        stream.native_tray_source = None;
        stream.native_tray_smoothed_rate = None;
        stream.native_tray_settings_key = Some(settings_key);
        let should_spawn = configure_native_tray_stream(&mut stream, stream_enabled);
        Ok(should_spawn.then_some(stream.loop_generation))
    }

    fn write_native_presentation_revisioned(
        &self,
        mut revision: u64,
        mut readout: (String, String),
        writer: &mut impl FnMut(String, String) -> Result<bool, String>,
    ) -> Result<(), String> {
        loop {
            if !writer(readout.0.clone(), readout.1.clone())? {
                return Err("status tray is not available".into());
            }
            let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
            stream.native_tray_last_readout = Some(readout.clone());
            if stream.native_tray_revision == revision {
                return Ok(());
            }
            revision = stream.native_tray_revision;
            readout = stream
                .native_tray_desired_readout
                .clone()
                .ok_or_else(|| "native tray desired readout is unavailable".to_string())?;
        }
    }

    fn unread_summary_for_source(
        &self,
        captured: &CapturedCodexHomeSource,
        force_refresh: bool,
    ) -> Result<UnreadSummary, String> {
        self.unread_summary_for_source_with_validator(captured, force_refresh, || {
            validate_captured_codex_home_source(captured)
        })
    }

    fn immediate_unread_summary_for_source(
        &self,
        source_token: &CodexHomeSourceToken,
    ) -> Result<(UnreadSummary, bool), String> {
        let source_scope_key = unread_registry_source_key(source_token);
        let requested_at = Instant::now();
        let cache = self
            .unread_cache
            .lock()
            .map_err(|error| error.to_string())?;
        match cached_unread_result(&cache, &source_scope_key, false, requested_at) {
            Some(result) => Ok((result?, false)),
            None => Ok((pending_unread_summary(), true)),
        }
    }

    fn schedule_unread_refresh(
        &self,
        app: AppHandle,
        captured: CapturedCodexHomeSource,
        refresh_needed: bool,
    ) -> Result<(), String> {
        if !refresh_needed {
            return Ok(());
        }
        let source_scope_key = unread_registry_source_key(&captured.source_token);
        {
            let mut sources = self
                .unread_background_refreshes
                .lock()
                .map_err(|error| error.to_string())?;
            if !sources.insert(source_scope_key.clone()) {
                return Ok(());
            }
        }

        let registry = self.clone();
        async_runtime::spawn_blocking(move || {
            let _owner = UnreadBackgroundRefreshOwner {
                sources: registry.unread_background_refreshes.clone(),
                source_scope_key,
            };
            let source_token = captured.source_token.clone();
            match registry.unread_summary_for_source(&captured, false) {
                Ok(summary) => match validate_codex_home_source(&source_token) {
                    Ok(()) => {
                        let payload = UnreadSummaryChangedPayload {
                            source_token,
                            summary,
                        };
                        if let Err(error) = app.emit(UNREAD_SUMMARY_CHANGED_EVENT, payload) {
                            startup_trace::mark_performance(format!(
                                "unread_background_event_error {error}"
                            ));
                        }
                    }
                    Err(error) => startup_trace::mark_performance(format!(
                        "unread_background_source_retired {error}"
                    )),
                },
                Err(error) => startup_trace::mark_performance(format!(
                    "unread_background_refresh_error {error}"
                )),
            }
        });
        Ok(())
    }

    fn unread_summary_for_source_with_validator(
        &self,
        captured: &CapturedCodexHomeSource,
        force_refresh: bool,
        validate_before_write: impl FnOnce() -> Result<(), String>,
    ) -> Result<UnreadSummary, String> {
        self.unread_summary_for_source_with_refresh(captured, force_refresh, || {
            let pinned = pin_captured_codex_home_source(captured)?;
            match pinned.observation() {
                Some(observation) => unread::try_read_unread_summary_for_observation(
                    observation,
                    &captured.codex_home,
                    &pinned.source_scope_key,
                    validate_before_write,
                ),
                None => unread::try_read_unread_summary_for_source(
                    pinned.read_path(),
                    &pinned.source_scope_key,
                    validate_before_write,
                ),
            }
        })
    }

    fn unread_summary_for_source_with_refresh(
        &self,
        captured: &CapturedCodexHomeSource,
        force_refresh: bool,
        refresh: impl FnOnce() -> Result<UnreadSummary, String>,
    ) -> Result<UnreadSummary, String> {
        let source_scope_key = unread_registry_source_key(&captured.source_token);
        let requested_at = Instant::now();
        let slot = loop {
            {
                let cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
                if let Some(result) = cached_unread_result(
                    &cache,
                    &source_scope_key,
                    force_refresh,
                    requested_at,
                ) {
                    return result;
                }
            }

            let slot = {
                let mut refreshes = self
                    .unread_refreshes
                    .lock()
                    .map_err(|error| error.to_string())?;
                refreshes.retain(|key, slot| {
                    key == &source_scope_key || Arc::strong_count(slot) > 1
                });
                refreshes
                    .entry(source_scope_key.clone())
                    .or_insert_with(|| Arc::new(UnreadRefreshSlot::default()))
                    .clone()
            };
            let mut refreshing = slot
                .refreshing
                .lock()
                .map_err(|error| error.to_string())?;
            while *refreshing {
                let (guard, wait_result) = slot
                    .ready
                    .wait_timeout(refreshing, UNREAD_REFRESH_WAIT_TIMEOUT)
                    .map_err(|error| error.to_string())?;
                refreshing = guard;
                if wait_result.timed_out() && *refreshing {
                    // 刷新持有者超时未归（慢盘/大目录）：返回过期缓存兜底，没有
                    // 任何缓存时返回中性摘要，不让并发 IPC 无上限陪等。
                    let cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
                    return Ok(match cache.get(&source_scope_key) {
                        Some(cached) => stale_unread_summary(
                            &cached.summary,
                            "unread refresh timed out; serving the stale summary",
                        ),
                        None => neutral_unread_summary("unread refresh wait timed out"),
                    });
                }
            }

            let cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
            if let Some(result) = cached_unread_result(
                &cache,
                &source_scope_key,
                force_refresh,
                requested_at,
            ) {
                return result;
            }
            drop(cache);
            *refreshing = true;
            drop(refreshing);
            break slot;
        };
        let _refresh_owner = UnreadRefreshOwner { slot };
        let attempted_at = Instant::now();
        let summary = match refresh() {
            Ok(summary) => summary,
            Err(error) if !force_refresh => {
                let mut cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
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
                prune_unread_cache(&mut cache);
                return Ok(neutral);
            }
            Err(error) => {
                let mut cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
                if unread::is_sidebar_snapshot_unavailable_error(&error) {
                    let unavailable = sidebar_unavailable_unread_summary(&error);
                    let failed_attempts = cache.get(&source_scope_key).map_or(1, |cached| {
                        if cached.summary.source == "codex_sidebar_unavailable" {
                            cached.failed_attempts.saturating_add(1)
                        } else {
                            1
                        }
                    });
                    cache.insert(
                        source_scope_key,
                        CachedUnreadSummary {
                            summary: unavailable.clone(),
                            refreshed_at: attempted_at - UNREAD_OBSERVATION_CADENCE,
                            last_attempt: attempted_at,
                            retry_after: Some(attempted_at + unread_retry_backoff(failed_attempts)),
                            failed_attempts,
                            last_error: None,
                        },
                    );
                    prune_unread_cache(&mut cache);
                    return Ok(unavailable);
                }
                if let Some(cached) = cache.get_mut(&source_scope_key) {
                    cached.last_attempt = attempted_at;
                    cached.failed_attempts = cached.failed_attempts.saturating_add(1);
                    cached.retry_after = Some(
                        attempted_at + unread_retry_backoff(cached.failed_attempts),
                    );
                    cached.last_error = Some(error.clone());
                } else {
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
                    prune_unread_cache(&mut cache);
                }
                return Err(error);
            }
        };
        let mut cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
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
        prune_unread_cache(&mut cache);
        Ok(summary)
    }

    fn store_unread_summary(
        &self,
        source_token: &CodexHomeSourceToken,
        summary: UnreadSummary,
    ) -> Result<(), String> {
        let source_scope_key = unread_registry_source_key(source_token);
        let mut cache = self.unread_cache.lock().map_err(|error| error.to_string())?;
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
        prune_unread_cache(&mut cache);
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

    fn immediate_snapshot_at_with_unread(
        &self,
        source_token: CodexHomeSourceToken,
        codex_home: PathBuf,
        selected_thread_id: Option<&str>,
        unread_summary: UnreadSummary,
    ) -> Result<LiveRateSnapshot, String> {
        let monitor = self.monitor_for_source(source_token, codex_home)?;
        Ok(monitor.immediate_snapshot_with_unread(selected_thread_id, unread_summary))
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
        let should_spawn = !stream.running && stream_interest_count(&stream) > 0;
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
            if stream_interest_count(&stream) == 0 {
                stream.running = false;
            }
        }
        Ok(true)
    }

    fn stop_subscription(&self, lease_id: &str) -> Result<bool, String> {
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        stream.leases.remove(lease_id);
        if stream_interest_count(&stream) == 0 {
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
        let selected = selected_subscription_for_source(&stream, &current_source.source_token).cloned();
        let native_enabled = stream.native_tray_enabled;
        if selected.is_none() && !native_enabled {
                stream.running = false;
                return Err("live rate stream has no current-source subscribers".into());
        }
        if native_enabled
            && stream.native_tray_source.as_ref() != Some(&current_source.source_token)
        {
            stream.native_tray_source = Some(current_source.source_token.clone());
            stream.native_tray_smoothed_rate = None;
            stream.native_tray_last_readout = None;
        }
        let emit_webview = selected.is_some();
        let selected_thread_id = selected.as_ref().and_then(|selected| {
            selected.controls_selected_thread.then(|| selected.selected_thread_id.clone()).flatten()
        });
        Ok(LiveRateStreamRequest {
            source: selected.as_ref().map(|selected| selected.source.clone()).unwrap_or(
                LiveRateSubscriptionSource {
                    source_token: current_source.source_token,
                    codex_home: current_source.codex_home,
                },
            ),
            selected_thread_id,
            emit_webview,
            update_native_tray: native_enabled,
        })
    }

    fn publish_native_tray_if_current(
        &self,
        app: &AppHandle,
        loop_generation: u64,
        source: &CodexHomeSourceToken,
        raw_rate: f64,
    ) -> Result<(), String> {
        let result = self.publish_native_tray_with_writer(loop_generation, source, raw_rate, |title, tooltip| {
            platform::set_status_tray_readout_native(app, title, tooltip)
        });
        if result.is_err() {
            self.schedule_native_tray_correction_retry(app.clone());
        }
        result
    }

    fn publish_native_tray_with_writer(
        &self,
        loop_generation: u64,
        source: &CodexHomeSourceToken,
        raw_rate: f64,
        mut writer: impl FnMut(String, String) -> Result<bool, String>,
    ) -> Result<(), String> {
        let mut stream = self.stream.lock().map_err(|error| error.to_string())?;
        if !stream.running || stream.loop_generation != loop_generation {
            return Ok(());
        }
        let Some(readout) = apply_native_tray_rate(&mut stream, source, raw_rate) else {
            return Ok(());
        };
        stream.native_tray_revision = stream.native_tray_revision.saturating_add(1);
        let revision = stream.native_tray_revision;
        stream.native_tray_desired_readout = Some(readout.clone());
        drop(stream);
        self.write_native_presentation_revisioned(revision, readout, &mut writer)
    }

    fn retry_native_presentation_with_writer(
        &self,
        mut writer: impl FnMut(String, String) -> Result<bool, String>,
    ) -> Result<(), String> {
        let (revision, readout) = {
            let stream = self.stream.lock().map_err(|error| error.to_string())?;
            (
                stream.native_tray_revision,
                stream
                    .native_tray_desired_readout
                    .clone()
                    .ok_or_else(|| "native tray desired readout is unavailable".to_string())?,
            )
        };
        self.write_native_presentation_revisioned(revision, readout, &mut writer)
    }

    fn claim_native_tray_retry_owner(&self) -> Option<u64> {
        let mut stream = self.stream.lock().ok()?;
        let pending = stream.native_tray_desired_readout.is_some()
            && stream.native_tray_desired_readout != stream.native_tray_last_readout;
        if stream.native_tray_retry_running || !pending {
            return None;
        }
        stream.native_tray_retry_running = true;
        Some(stream.native_tray_revision)
    }

    fn finish_native_tray_retry_cycle(&self, cycle_revision: u64) -> NativeTrayRetryFinish {
        let Ok(mut stream) = self.stream.lock() else {
            return NativeTrayRetryFinish::Stop;
        };
        let pending = stream.native_tray_desired_readout.is_some()
            && stream.native_tray_desired_readout != stream.native_tray_last_readout;
        if pending && stream.native_tray_revision != cycle_revision {
            // Keep ownership while atomically observing a newer pending revision. This closes
            // the success-before-teardown lost-wakeup window without creating a second owner.
            NativeTrayRetryFinish::Continue(stream.native_tray_revision)
        } else {
            stream.native_tray_retry_running = false;
            NativeTrayRetryFinish::Stop
        }
    }

    fn run_native_tray_retry_owner_with_writer(
        &self,
        mut cycle_revision: u64,
        mut writer: impl FnMut(String, String) -> Result<bool, String>,
        mut sleeper: impl FnMut(Duration),
        mut before_finish: impl FnMut(u64),
    ) {
        loop {
            for attempt in 0..NATIVE_TRAY_CORRECTION_RETRY_LIMIT {
                sleeper(NATIVE_TRAY_CORRECTION_RETRY_DELAY * (attempt as u32 + 1));
                if self
                    .retry_native_presentation_with_writer(&mut writer)
                    .is_ok()
                {
                    break;
                }
            }
            before_finish(cycle_revision);
            match self.finish_native_tray_retry_cycle(cycle_revision) {
                NativeTrayRetryFinish::Stop => return,
                NativeTrayRetryFinish::Continue(revision) => cycle_revision = revision,
            }
        }
    }

    fn schedule_native_tray_correction_retry(&self, app: AppHandle) {
        let Some(revision) = self.claim_native_tray_retry_owner() else { return; };
        let registry = self.clone();
        async_runtime::spawn_blocking(move || {
            registry.run_native_tray_retry_owner_with_writer(
                revision,
                |title, tooltip| {
                    platform::set_status_tray_readout_native(&app, title, tooltip)
                },
                std::thread::sleep,
                |_| {},
            );
        });
    }

    fn publish_stream_if_current(
        &self,
        loop_generation: u64,
        publish: impl FnOnce() -> Result<(), String>,
    ) -> Result<bool, String> {
        {
            let stream = self.stream.lock().map_err(|error| error.to_string())?;
            if !stream.running || stream.loop_generation != loop_generation {
                return Ok(false);
            }
        }
        publish()?;
        let stream = self.stream.lock().map_err(|error| error.to_string())?;
        Ok(stream.running && stream.loop_generation == loop_generation)
    }

    fn spawn_stream_loop(&self, app: AppHandle, loop_generation: u64) {
        let registry = self.clone();
        async_runtime::spawn(async move {
            let mut last_active_at: Option<Instant> = None;
            let mut last_webview_emit_at: Option<Instant> = None;
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
                let unread_captured = captured.clone();
                let needs_unread = snapshot_needs_unread(request.emit_webview);
                let snapshot = async_runtime::spawn_blocking(move || {
                    let (unread_summary, refresh_needed) = if needs_unread {
                        snapshot_registry
                            .immediate_unread_summary_for_source(&captured.source_token)?
                    } else {
                        (
                            neutral_unread_summary("native tray lightweight snapshot"),
                            false,
                        )
                    };
                    let snapshot = snapshot_registry.snapshot_at_with_unread(
                        captured.source_token.clone(),
                        captured.codex_home.clone(),
                        selected_for_snapshot.as_deref(),
                        unread_summary,
                    )?;
                    Ok::<_, String>((snapshot, refresh_needed))
                })
                .await;
                let (snapshot, refresh_needed) = match snapshot {
                    Ok(Ok(result)) => result,
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
                if let Err(error) =
                    registry.schedule_unread_refresh(app.clone(), unread_captured, refresh_needed)
                {
                    startup_trace::mark_performance(format!(
                        "unread_background_schedule_error {error}"
                    ));
                }

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
                let emit_webview = request.emit_webview;
                let update_native_tray = request.update_native_tray;
                let should_emit_webview = should_emit_webview_snapshot(
                    emit_webview,
                    last_webview_emit_at.map(|last_emitted| last_emitted.elapsed()),
                );
                if !emit_webview {
                    last_webview_emit_at = None;
                }
                match with_valid_codex_home_source(&source_token, || {
                    if update_native_tray {
                        registry.publish_native_tray_if_current(
                            &app,
                            loop_generation,
                            &source_token,
                            snapshot.tokens_per_second,
                        )?;
                    }
                    registry.publish_stream_if_current(loop_generation, || {
                        if should_emit_webview {
                            app.emit(LIVE_RATE_SNAPSHOT_EVENT, snapshot)
                                .map_err(|error| error.to_string())?;
                        }
                        Ok(())
                    })
                }) {
                    Ok(true) => {
                        if should_emit_webview {
                            last_webview_emit_at = Some(Instant::now());
                        }
                    }
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

fn unread_registry_source_key(source_token: &CodexHomeSourceToken) -> String {
    format!(
        "{}|{}|{}",
        source_token.transition_generation,
        source_token.canonical_home_key,
        source_token.physical_home_key
    )
}

fn prune_unread_cache(cache: &mut HashMap<String, CachedUnreadSummary>) {
    while cache.len() > UNREAD_CACHE_LIMIT {
        let Some(oldest_key) = cache
            .iter()
            .min_by(|(left_key, left), (right_key, right)| {
                left.last_attempt
                    .cmp(&right.last_attempt)
                    .then_with(|| left_key.cmp(right_key))
            })
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        cache.remove(&oldest_key);
    }
}

fn stale_unread_summary(summary: &UnreadSummary, error: &str) -> UnreadSummary {
    // A cached active value is not safe for this indicator: Codex Desktop's
    // sidebar is the authority, and a missing/failed CDP snapshot may mean
    // that the user has already read the row.  Hide the previous value until
    // a fresh sidebar snapshot is available instead of keeping a flashing dot.
    UnreadSummary {
        active: false,
        count: 0,
        label: "未读状态暂不可用".into(),
        detail: format!("当前侧栏未读快照不可用，已隐藏上次状态：{error}"),
        source: if summary.source == "codex_sidebar_unavailable" {
            summary.source.clone()
        } else {
            format!("{}_hidden", summary.source.trim_end_matches("_stale"))
        },
    }
}

fn cached_unread_result(
    cache: &HashMap<String, CachedUnreadSummary>,
    source_scope_key: &str,
    force_refresh: bool,
    requested_at: Instant,
) -> Option<Result<UnreadSummary, String>> {
    let cached = cache.get(source_scope_key)?;
    if force_refresh {
        return (cached.last_attempt >= requested_at).then(|| match cached.last_error.as_ref() {
            Some(error) => Err(error.clone()),
            None => Ok(cached.summary.clone()),
        });
    }
    if cached.refreshed_at.elapsed() < UNREAD_OBSERVATION_CADENCE {
        return Some(Ok(cached.summary.clone()));
    }
    if cached
        .retry_after
        .is_some_and(|retry_after| Instant::now() < retry_after)
    {
        return Some(Ok(stale_unread_summary(
            &cached.summary,
            "refresh retry is backing off",
        )));
    }
    None
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

fn pending_unread_summary() -> UnreadSummary {
    UnreadSummary {
        active: false,
        count: 0,
        label: "未读状态读取中".into(),
        detail: "正在读取 Codex 左侧列表的实时未读状态。".into(),
        source: "codex_sidebar_pending".into(),
    }
}

fn sidebar_unavailable_unread_summary(error: &str) -> UnreadSummary {
    UnreadSummary {
        active: false,
        count: 0,
        label: "未读状态暂不可用".into(),
        detail: format!("Codex 左侧栏实时未读快照暂不可用，已停止提醒并继续重试：{error}"),
        source: "codex_sidebar_unavailable".into(),
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

fn stream_interest_count(stream: &LiveRateStreamState) -> usize {
    active_subscription_count(stream) + usize::from(stream.native_tray_enabled)
}

fn configure_native_tray_stream(stream: &mut LiveRateStreamState, enabled: bool) -> bool {
    stream.native_tray_enabled = enabled;
    let should_spawn = enabled && !stream.running;
    if should_spawn {
        stream.running = true;
        stream.loop_generation = stream.loop_generation.saturating_add(1);
    } else if !enabled && active_subscription_count(stream) == 0 {
        stream.running = false;
    }
    should_spawn
}

fn snapshot_needs_unread(emit_webview: bool) -> bool {
    emit_webview
}

fn apply_native_tray_rate(
    stream: &mut LiveRateStreamState,
    source: &CodexHomeSourceToken,
    raw_rate: f64,
) -> Option<(String, String)> {
    if !stream.native_tray_enabled || stream.native_tray_source.as_ref() != Some(source) {
        return None;
    }
    let smoothed = smooth_native_tray_rate(stream.native_tray_smoothed_rate, raw_rate);
    stream.native_tray_smoothed_rate = Some(smoothed);
    let readout = native_tray_readout(smoothed);
    if stream.native_tray_last_readout.as_ref() == Some(&readout) {
        return None;
    }
    Some(readout)
}

fn smooth_native_tray_rate(previous: Option<f64>, raw: f64) -> f64 {
    if !raw.is_finite() || raw < TRAY_RATE_THRESHOLD {
        return 0.0;
    }
    let Some(previous) = previous.filter(|value| value.is_finite() && *value >= TRAY_RATE_THRESHOLD) else {
        return raw;
    };
    let alpha = if raw > previous { TRAY_ALPHA_UP } else { TRAY_ALPHA_DOWN };
    previous + (raw - previous) * alpha
}

fn native_tray_readout(rate: f64) -> (String, String) {
    let formatted = if rate.is_finite() && rate >= TRAY_RATE_THRESHOLD {
        format!("{rate:.1}")
    } else {
        "0.0".into()
    };
    (
        format!("{formatted}/s"),
        format!("Codex Token Bar · {formatted} tok/s"),
    )
}

fn native_tray_settings(
    display: &DisplaySurfaceSettingsSnapshot,
    supported: bool,
) -> (bool, (String, String)) {
    if !supported || !display.status_tray_live_text_enabled {
        return (false, ("CTB".into(), "Codex Token Bar".into()));
    }
    (
        display.live_rate_enabled,
        native_tray_readout(0.0),
    )
}

fn composed_status_owner_active(_display: &DisplaySurfaceSettingsSnapshot) -> bool {
    true
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

fn should_emit_webview_snapshot(
    has_webview_subscriber: bool,
    elapsed_since_last_emit: Option<Duration>,
) -> bool {
    has_webview_subscriber
        && elapsed_since_last_emit
            .is_none_or(|elapsed| elapsed >= WEBVIEW_STREAM_INTERVAL)
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
    let observation_home = captured.codex_home.clone();
    let pinned = pin_captured_codex_home_source(&captured)?;
    after_pin()?;
    match pinned.observation() {
        Some(observation) => unread::acknowledge_current_unread_for_observation(
            observation,
            &observation_home,
            &pinned.source_scope_key,
            validate_before_write,
        ),
        None => unread::acknowledge_current_unread_for_source(
            pinned.read_path(),
            &pinned.source_scope_key,
            validate_before_write,
        ),
    }
}

#[tauri::command]
pub async fn publish_status_indicator_readout(
    window: tauri::WebviewWindow,
    app: AppHandle,
    title: String,
    tooltip: String,
    width: f64,
    columns: Vec<platform::StatusTrayColumn>,
) -> Result<bool, String> {
    require_window_label(&window, "publish_status_indicator_readout")?;
    platform::publish_status_indicator_readout_native(&app, title, tooltip, width, columns).await
}

#[tauri::command]
pub async fn read_live_rate_snapshot(
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    selected_thread_id: Option<String>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<LiveRateSnapshot, String> {
    require_window_label(&window, "read_live_rate_snapshot")?;
    startup_trace::mark_once("command read_live_rate_snapshot start");
    let started = Instant::now();
    let registry = state.inner().clone();
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(source_token.as_ref())?;
    let completed_source_token = captured.source_token.clone();
    let unread_captured = captured.clone();
    let snapshot_registry = registry.clone();
    let result = run_blocking_command(move || {
        let (unread_summary, refresh_needed) =
            snapshot_registry.immediate_unread_summary_for_source(&captured.source_token)?;
        let snapshot = snapshot_registry.immediate_snapshot_at_with_unread(
            captured.source_token.clone(),
            captured.codex_home.clone(),
            selected_thread_id.as_deref(),
            unread_summary,
        )?;
        Ok::<_, String>((snapshot, refresh_needed))
    })
    .await
    .and_then(|(snapshot, refresh_needed)| {
        emit_detected_source_transition(&app)?;
        validate_codex_home_source(&completed_source_token)?;
        registry.schedule_unread_refresh(app.clone(), unread_captured, refresh_needed)?;
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
    require_window_label(&window, "claim_live_rate_owner_session")?;
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
    require_window_label(&window, "start_live_rate_stream")?;
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
    window: tauri::WebviewWindow,
    state: State<'_, LiveRateMonitorRegistry>,
    lease_id: String,
) -> Result<bool, String> {
    require_window_label(&window, "stop_live_rate_stream")?;
    let registry = state.inner().clone();
    run_blocking_command(move || registry.stop_subscription(&lease_id)).await
}

#[tauri::command]
pub async fn read_floating_snapshot(
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<FloatingPanelSnapshot, String> {
    require_window_label(&window, "read_floating_snapshot")?;
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
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<UnreadSummary, String> {
    require_window_label(&window, "read_unread_summary")?;
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
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: State<'_, LiveRateMonitorRegistry>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<UnreadSummary, String> {
    require_window_label(&window, "acknowledge_current_unread")?;
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
    fn active_live_rate_stream_preserves_collection_and_limits_surface_publication() {
        assert_eq!(FAST_STREAM_INTERVAL, Duration::from_millis(250));
        assert_eq!(WEBVIEW_STREAM_INTERVAL, Duration::from_secs(1));
        assert!(should_emit_webview_snapshot(true, None));
        assert!(!should_emit_webview_snapshot(
            true,
            Some(Duration::from_millis(999))
        ));
        assert!(should_emit_webview_snapshot(
            true,
            Some(Duration::from_secs(1))
        ));
        assert!(!should_emit_webview_snapshot(false, None));
    }

    #[test]
    fn initial_tray_write_failure_keeps_interest_off_and_same_settings_retryable() {
        let registry = LiveRateMonitorRegistry::default();
        let display = DisplaySurfaceSettingsSnapshot::default();
        assert!(registry
            .apply_status_tray_settings_with_writer(&display, true, |_, _| Ok(false))
            .is_err());
        assert!(registry
            .apply_status_tray_settings_with_writer(&display, true, |_, _| Err("setter failed".into()))
            .is_err());
        {
            let stream = registry.stream.lock().unwrap();
            assert!(!stream.native_tray_enabled);
            assert!(!stream.running);
            assert!(stream.native_tray_settings_key.is_none());
        }
        let generation = registry
            .apply_status_tray_settings_with_writer(&display, true, |_, _| Ok(true))
            .unwrap();
        assert!(generation.is_some());
        assert!(registry.stream.lock().unwrap().native_tray_enabled);
    }

    #[test]
    fn composed_status_suspends_legacy_rate_writer() {
        let registry = LiveRateMonitorRegistry::default();
        {
            let mut stream = registry.stream.lock().unwrap();
            stream.native_tray_enabled = true;
            stream.running = true;
            stream.native_tray_source = Some(live_source_for_test("source-a", 1).source_token);
            stream.native_tray_smoothed_rate = Some(12.0);
            stream.native_tray_desired_readout = Some(("12.0/s".into(), "12 tok/s".into()));
        }
        registry.suspend_native_tray_writer_for_composed_status().unwrap();
        let stream = registry.stream.lock().unwrap();
        assert!(!stream.native_tray_enabled);
        assert!(!stream.running);
        assert!(stream.native_tray_source.is_none());
        assert!(stream.native_tray_desired_readout.is_none());
    }

    #[test]
    fn empty_metric_order_keeps_composed_owner() {
        let mut display = DisplaySurfaceSettingsSnapshot::default();
        display.status_metric_order.clear();
        assert!(composed_status_owner_active(&display));
    }

    #[test]
    fn identical_tick_retries_after_error_or_missing_tray_without_false_dedupe() {
        for first_result in [Err("setter failed".to_string()), Ok(false)] {
            let registry = LiveRateMonitorRegistry::default();
            let display = DisplaySurfaceSettingsSnapshot::default();
            let generation = registry
                .apply_status_tray_settings_with_writer(&display, true, |_, _| Ok(true))
                .unwrap().unwrap();
            let source = live_source_for_test("source-a", 1).source_token;
            registry.stream.lock().unwrap().native_tray_source = Some(source.clone());
            let mut first = Some(first_result);
            assert!(registry.publish_native_tray_with_writer(generation, &source, 10.0, |_, _| first.take().unwrap()).is_err());
            let mut retry_calls = 0;
            registry.publish_native_tray_with_writer(generation, &source, 10.0, |title, _| {
                retry_calls += 1;
                assert_eq!(title, "10.0/s");
                Ok(true)
            }).unwrap();
            assert_eq!(retry_calls, 1);
        }
    }

    #[test]
    fn disabled_settings_failure_schedules_presentation_owner_without_stream() {
        for initial_failure in [Err("setter failed".to_string()), Ok(false)] {
            let registry = LiveRateMonitorRegistry::default();
            let enabled = DisplaySurfaceSettingsSnapshot::default();
            let mut disabled = enabled.clone();
            disabled.status_tray_live_text_enabled = false;
            let source = live_source_for_test("source-a", 1).source_token;
            let generation = registry
                .apply_status_tray_settings_with_writer(&enabled, true, |_, _| Ok(true))
                .unwrap()
                .unwrap();
            registry.stream.lock().unwrap().native_tray_source = Some(source.clone());
            registry
                .publish_native_tray_with_writer(generation, &source, 12.0, |_, _| Ok(true))
                .unwrap();

            let mut scheduled = false;
            let mut failure = Some(initial_failure);
            assert!(registry
                .apply_status_tray_interest_with_writer_and_scheduler(
                    &disabled,
                    true,
                    |_, _| failure.take().unwrap(),
                    || scheduled = true,
                )
                .is_err());
            assert!(scheduled);
            let revision = registry.claim_native_tray_retry_owner().unwrap();
            let mut writes = 0;
            let mut sleeps = 0;
            registry.run_native_tray_retry_owner_with_writer(
                revision,
                |title, _| {
                    writes += 1;
                    assert_eq!(title, "CTB");
                    Ok(true)
                },
                |_| sleeps += 1,
                |_| {},
            );
            let stream = registry.stream.lock().unwrap();
            assert_eq!(writes, 1);
            assert_eq!(sleeps, 1);
            assert!(!stream.native_tray_enabled);
            assert!(!stream.running);
            assert!(!stream.native_tray_retry_running);
            assert_eq!(stream.native_tray_last_readout.as_ref().map(|value| value.0.as_str()), Some("CTB"));
        }
    }

    #[test]
    fn retry_owner_atomically_hands_off_new_failure_before_teardown() {
        let registry = LiveRateMonitorRegistry::default();
        let enabled = DisplaySurfaceSettingsSnapshot::default();
        let mut disabled = enabled.clone();
        disabled.status_tray_live_text_enabled = false;
        assert!(registry
            .apply_status_tray_settings_with_writer(&disabled, true, |_, _| Err("old failure".into()))
            .is_err());
        let old_revision = registry.claim_native_tray_retry_owner().unwrap();
        let mut injected = false;
        let mut writes = Vec::new();
        registry.run_native_tray_retry_owner_with_writer(
            old_revision,
            |title, _| {
                writes.push(title);
                Ok(true)
            },
            |_| {},
            |_| {
                if !injected {
                    injected = true;
                    let mut zero = enabled.clone();
                    zero.live_rate_enabled = false;
                    assert!(registry
                        .apply_status_tray_settings_with_writer(&zero, true, |_, _| {
                            Err("new failure".into())
                        })
                        .is_err());
                    // A concurrent scheduler sees the existing owner; finish must retain it.
                    assert!(registry.claim_native_tray_retry_owner().is_none());
                }
            },
        );
        let stream = registry.stream.lock().unwrap();
        assert_eq!(writes, vec!["CTB", "0.0/s"]);
        assert_eq!(stream.native_tray_desired_readout, stream.native_tray_last_readout);
        assert!(!stream.native_tray_retry_running);
        assert!(!stream.native_tray_enabled);
        assert!(!stream.running);
    }

    #[test]
    fn retry_owner_is_bounded_and_later_event_can_reclaim() {
        let registry = LiveRateMonitorRegistry::default();
        let mut disabled = DisplaySurfaceSettingsSnapshot::default();
        disabled.status_tray_live_text_enabled = false;
        assert!(registry
            .apply_status_tray_settings_with_writer(&disabled, true, |_, _| Err("initial".into()))
            .is_err());
        let revision = registry.claim_native_tray_retry_owner().unwrap();
        let mut attempts = 0;
        let mut sleeps = 0;
        registry.run_native_tray_retry_owner_with_writer(
            revision,
            |_, _| {
                attempts += 1;
                Err("still failing".into())
            },
            |_| sleeps += 1,
            |_| {},
        );
        assert_eq!(attempts, NATIVE_TRAY_CORRECTION_RETRY_LIMIT);
        assert_eq!(sleeps, NATIVE_TRAY_CORRECTION_RETRY_LIMIT);
        assert!(!registry.stream.lock().unwrap().native_tray_retry_running);

        let next_revision = registry.claim_native_tray_retry_owner().unwrap();
        registry.run_native_tray_retry_owner_with_writer(
            next_revision,
            |title, _| {
                assert_eq!(title, "CTB");
                Ok(true)
            },
            |_| {},
            |_| {},
        );
        let stream = registry.stream.lock().unwrap();
        assert_eq!(stream.native_tray_desired_readout, stream.native_tray_last_readout);
        assert!(!stream.native_tray_retry_running);
    }

    #[test]
    fn revisioned_writer_makes_disable_ctb_win_over_old_tick_in_both_orders() {
        use std::sync::mpsc;
        use std::thread;

        let source = live_source_for_test("source-a", 1).source_token;
        let enabled = DisplaySurfaceSettingsSnapshot::default();
        let mut disabled = enabled.clone();
        disabled.status_tray_live_text_enabled = false;
        let registry = LiveRateMonitorRegistry::default();
        let writes = Arc::new(Mutex::new(Vec::new()));
        let generation = registry
            .apply_status_tray_settings_with_writer(&enabled, true, |title, _| {
                writes.lock().unwrap().push(title);
                Ok(true)
            })
            .unwrap()
            .unwrap();
        registry.stream.lock().unwrap().native_tray_source = Some(source.clone());

        let (tick_ready_tx, tick_ready_rx) = mpsc::channel();
        let (release_tick_tx, release_tick_rx) = mpsc::channel();
        let tick_registry = registry.clone();
        let tick_source = source.clone();
        let tick_writes = writes.clone();
        let tick = thread::spawn(move || {
            let mut first_write = true;
            tick_registry
                .publish_native_tray_with_writer(generation, &tick_source, 12.0, |title, _| {
                    if first_write {
                        first_write = false;
                        tick_ready_tx.send(()).unwrap();
                        release_tick_rx.recv().unwrap();
                    }
                    tick_writes.lock().unwrap().push(title);
                    Ok(true)
                })
                .unwrap();
        });
        tick_ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        registry
            .apply_status_tray_settings_with_writer(&disabled, true, |title, _| {
                writes.lock().unwrap().push(title);
                Ok(true)
            })
            .unwrap();
        release_tick_tx.send(()).unwrap();
        tick.join().unwrap();
        assert_eq!(writes.lock().unwrap().last().map(String::as_str), Some("CTB"));

        let registry = LiveRateMonitorRegistry::default();
        let mut ordered = Vec::new();
        let generation = registry
            .apply_status_tray_settings_with_writer(&enabled, true, |title, _| { ordered.push(title); Ok(true) })
            .unwrap().unwrap();
        registry.stream.lock().unwrap().native_tray_source = Some(source.clone());
        registry.publish_native_tray_with_writer(generation, &source, 12.0, |title, _| { ordered.push(title); Ok(true) }).unwrap();
        registry.apply_status_tray_settings_with_writer(&disabled, true, |title, _| { ordered.push(title); Ok(true) }).unwrap();
        assert_eq!(ordered.last().map(String::as_str), Some("CTB"));
    }

    #[test]
    fn native_interest_shares_ui_loop_and_survives_dashboard_stop() {
        let registry = LiveRateMonitorRegistry::default();
        {
            let mut stream = registry.stream.lock().unwrap();
            assert!(configure_native_tray_stream(&mut stream, true));
            assert!(stream.running);
        }
        let ui = registry.test_start_subscription(
            live_source_for_test("source-a", 1),
            "dashboard-owner",
            1,
            None,
            true,
        );
        assert!(!ui.should_spawn);
        assert!(registry.test_stop_subscription(&ui.lease.lease_id));
        assert!(registry.stream.lock().unwrap().running);
    }

    #[test]
    fn native_disable_stops_only_when_no_ui_interest_remains() {
        let registry = LiveRateMonitorRegistry::default();
        let ui = registry.test_start_subscription(
            live_source_for_test("source-a", 1),
            "dashboard-owner",
            1,
            None,
            true,
        );
        {
            let mut stream = registry.stream.lock().unwrap();
            configure_native_tray_stream(&mut stream, true);
            configure_native_tray_stream(&mut stream, false);
            assert!(stream.running, "UI lease keeps the shared loop alive");
        }
        registry.test_stop_subscription(&ui.lease.lease_id);
        assert!(!registry.stream.lock().unwrap().running);
    }

    #[test]
    fn persisted_tray_settings_cover_disabled_zero_and_streaming_modes() {
        let mut display = DisplaySurfaceSettingsSnapshot::default();
        display.status_tray_live_text_enabled = false;
        assert_eq!(native_tray_settings(&display, true), (false, ("CTB".into(), "Codex Token Bar".into())));
        display.status_tray_live_text_enabled = true;
        display.live_rate_enabled = false;
        assert_eq!(native_tray_settings(&display, true), (false, native_tray_readout(0.0)));
        display.live_rate_enabled = true;
        assert_eq!(native_tray_settings(&display, true), (true, native_tray_readout(0.0)));
        assert_eq!(
            native_tray_settings(&display, false),
            (false, ("CTB".into(), "Codex Token Bar".into())),
            "unsupported Windows/Linux targets must ignore the default-enabled setting"
        );
    }

    #[test]
    fn native_source_switch_rejects_late_old_snapshot_and_resets_dedupe() {
        let mut stream = LiveRateStreamState::default();
        configure_native_tray_stream(&mut stream, true);
        let source_a = live_source_for_test("source-a", 1).source_token;
        let source_b = live_source_for_test("source-b", 2).source_token;
        stream.native_tray_source = Some(source_a.clone());
        assert!(apply_native_tray_rate(&mut stream, &source_a, 10.0).is_some());
        stream.native_tray_last_readout = Some(native_tray_readout(10.0));
        assert!(apply_native_tray_rate(&mut stream, &source_a, 10.0).is_none(), "same formatted readout is deduped");
        stream.native_tray_source = Some(source_b.clone());
        stream.native_tray_smoothed_rate = None;
        stream.native_tray_last_readout = None;
        assert!(apply_native_tray_rate(&mut stream, &source_a, 99.0).is_none());
        assert!(apply_native_tray_rate(&mut stream, &source_b, 10.0).is_some());
    }

    #[test]
    fn native_only_snapshot_skips_unread_and_formats_smoothed_rate() {
        assert!(!snapshot_needs_unread(false));
        assert!(snapshot_needs_unread(true));
        assert_eq!(smooth_native_tray_rate(Some(10.0), 40.0), 18.4);
        assert_eq!(smooth_native_tray_rate(Some(40.0), 10.0), 34.6);
        assert_eq!(native_tray_readout(f64::NAN), native_tray_readout(0.0));
        assert_eq!(native_tray_readout(9.94).0, "9.9/s");
    }

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
    fn stream_publish_callback_can_reenter_registry_without_stream_lock() {
        let registry = LiveRateMonitorRegistry::default();
        let source = live_source_for_test("source-a", 1);
        let active = registry.test_start_subscription(
            source,
            "compact-owner",
            1,
            None,
            false,
        );
        let callback_registry = registry.clone();
        let lease_id = active.lease.lease_id.clone();

        let still_current = registry
            .test_publish_stream_if_current(active.loop_generation, || {
                assert!(!callback_registry.test_stop_subscription(&lease_id));
                Ok(())
            })
            .unwrap();

        assert!(
            !still_current,
            "post-publish validation must observe the reentrant stop"
        );
        assert_eq!(registry.test_stream_state(), (0, false, None));
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
    fn production_unread_cadence_creates_no_disk_snapshot_or_source_copy() {
        use std::os::unix::fs::MetadataExt;

        let _counter_guard = super::super::dashboard::pinned_source_counter_test_guard();
        super::super::dashboard::reset_pinned_source_observation_counters_for_test();
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
            super::super::dashboard::pinned_sqlite_view_create_count_for_test(),
            0
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn expired_cache_refresh_failure_hides_trusted_summary_and_backs_off() {
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
        let key = unread_registry_source_key(&captured.source_token);
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
            assert_eq!(summary.count, 0);
            assert!(!summary.active);
            assert!(summary.source.ends_with("_hidden"));
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
    fn immediate_unread_snapshot_is_typed_pending_until_cache_is_ready() {
        let registry = LiveRateMonitorRegistry::default();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "immediate-unread".into(),
                physical_home_key: "physical-immediate-unread".into(),
                transition_generation: 4,
            },
            codex_home: PathBuf::from("immediate-unread"),
            source_path: PathBuf::from("immediate-unread"),
        };

        let (pending, refresh_needed) = registry
            .immediate_unread_summary_for_source(&captured.source_token)
            .unwrap();
        assert!(refresh_needed);
        assert!(!pending.active);
        assert_eq!(pending.count, 0);
        assert_eq!(pending.source, "codex_sidebar_pending");

        registry
            .unread_summary_for_source_with_refresh(&captured, false, || {
                Ok(UnreadSummary {
                    active: true,
                    count: 2,
                    label: "fresh".into(),
                    detail: "fresh".into(),
                    source: "codex_unread_state".into(),
                })
            })
            .unwrap();
        let (cached, refresh_needed) = registry
            .immediate_unread_summary_for_source(&captured.source_token)
            .unwrap();
        assert!(!refresh_needed);
        assert_eq!(cached.count, 2);
        assert_eq!(cached.source, "codex_unread_state");
    }

    #[test]
    fn retired_unread_attempt_cannot_evict_new_generation_cache() {
        use std::sync::{Arc, Barrier};

        let registry = LiveRateMonitorRegistry::default();
        let old = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "same-home".into(),
                physical_home_key: "same-physical-home".into(),
                transition_generation: 10,
            },
            codex_home: PathBuf::from("same-home"),
            source_path: PathBuf::from("same-home"),
        };
        let current = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                transition_generation: 11,
                ..old.source_token.clone()
            },
            ..old.clone()
        };
        let started = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let old_refresh = {
            let registry = registry.clone();
            let old = old.clone();
            let started = started.clone();
            let release = release.clone();
            std::thread::spawn(move || {
                registry
                    .unread_summary_for_source_with_refresh(&old, false, || {
                        started.wait();
                        release.wait();
                        Ok(UnreadSummary {
                            active: true,
                            count: 1,
                            label: "retired".into(),
                            detail: "retired".into(),
                            source: "retired".into(),
                        })
                    })
                    .unwrap()
            })
        };
        started.wait();
        registry
            .unread_summary_for_source_with_refresh(&current, false, || {
                Ok(UnreadSummary {
                    active: true,
                    count: 7,
                    label: "current".into(),
                    detail: "current".into(),
                    source: "current".into(),
                })
            })
            .unwrap();
        release.wait();
        assert_eq!(old_refresh.join().unwrap().count, 1);

        let (current_cached, refresh_needed) = registry
            .immediate_unread_summary_for_source(&current.source_token)
            .unwrap();
        assert!(!refresh_needed);
        assert_eq!(current_cached.count, 7);
        assert_eq!(current_cached.source, "current");
        assert_eq!(registry.unread_cache.lock().unwrap().len(), 2);
    }

    #[test]
    fn unread_cache_is_bounded_and_keeps_the_newest_generations() {
        let now = Instant::now();
        let mut cache = HashMap::new();
        for generation in 0..(UNREAD_CACHE_LIMIT + 3) {
            cache.insert(
                format!("generation-{generation}"),
                CachedUnreadSummary {
                    summary: pending_unread_summary(),
                    refreshed_at: now,
                    last_attempt: now + Duration::from_millis(generation as u64),
                    retry_after: None,
                    failed_attempts: 0,
                    last_error: None,
                },
            );
        }

        prune_unread_cache(&mut cache);

        assert_eq!(cache.len(), UNREAD_CACHE_LIMIT);
        assert!(!cache.contains_key("generation-0"));
        assert!(!cache.contains_key("generation-1"));
        assert!(!cache.contains_key("generation-2"));
        assert!(cache.contains_key(&format!(
            "generation-{}",
            UNREAD_CACHE_LIMIT + 2
        )));
    }

    #[test]
    fn native_unread_wait_budget_is_below_initial_frontend_ipc_budget() {
        assert!(UNREAD_REFRESH_WAIT_TIMEOUT < Duration::from_millis(1_500));
    }

    #[test]
    fn unread_refresh_wait_times_out_and_hides_the_stale_summary() {
        use std::sync::{Arc, Barrier};

        let registry = LiveRateMonitorRegistry::default();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "wait-timeout".into(),
                physical_home_key: "physical-wait-timeout".into(),
                transition_generation: 1,
            },
            codex_home: PathBuf::from("wait-timeout"),
            source_path: PathBuf::from("wait-timeout"),
        };
        let key = unread_registry_source_key(&captured.source_token);
        registry.unread_cache.lock().unwrap().insert(
            key,
            CachedUnreadSummary {
                summary: UnreadSummary {
                    active: true,
                    count: 5,
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
        let started = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let holder = {
            let registry = registry.clone();
            let captured = captured.clone();
            let started = started.clone();
            let release = release.clone();
            std::thread::spawn(move || {
                registry
                    .unread_summary_for_source_with_refresh(&captured, false, || {
                        started.wait();
                        release.wait();
                        Ok(UnreadSummary {
                            active: true,
                            count: 9,
                            label: "fresh".into(),
                            detail: "fresh".into(),
                            source: "test".into(),
                        })
                    })
                    .unwrap()
            })
        };

        started.wait();
        let waited_from = Instant::now();
        let summary = registry
            .unread_summary_for_source_with_refresh(&captured, false, || {
                panic!("waiter must not start its own refresh while one is in flight")
            })
            .unwrap();
        let waited = waited_from.elapsed();
        assert!(
            waited
                >= UNREAD_REFRESH_WAIT_TIMEOUT.saturating_sub(Duration::from_millis(50)),
            "waiter returned materially before the timeout: {waited:?}"
        );
        assert_eq!(summary.count, 0);
        assert!(!summary.active);
        assert!(summary.source.ends_with("_hidden"));
        release.wait();
        assert_eq!(holder.join().unwrap().count, 9);
    }

    #[test]
    fn unread_refresh_runs_without_holding_the_cache_mutex() {
        let registry = LiveRateMonitorRegistry::default();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "reentrant-unread".into(),
                physical_home_key: "physical-reentrant-unread".into(),
                transition_generation: 1,
            },
            codex_home: PathBuf::from("reentrant-unread"),
            source_path: PathBuf::from("reentrant-unread"),
        };
        let observed = registry.clone();

        let summary = registry
            .unread_summary_for_source_with_refresh(&captured, false, || {
                let cache = observed
                    .unread_cache
                    .try_lock()
                    .expect("refresh callback must run outside the unread cache mutex");
                assert!(cache.is_empty());
                drop(cache);
                Ok(UnreadSummary {
                    active: true,
                    count: 2,
                    label: "fresh".into(),
                    detail: "fresh".into(),
                    source: "test".into(),
                })
            })
            .unwrap();

        assert_eq!(summary.count, 2);
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
    fn forced_unread_read_soft_fails_only_while_sidebar_snapshot_is_unavailable() {
        let registry = LiveRateMonitorRegistry::default();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "sidebar-unavailable".into(),
                physical_home_key: "physical-sidebar-unavailable".into(),
                transition_generation: 1,
            },
            codex_home: PathBuf::from("sidebar-unavailable"),
            source_path: PathBuf::from("sidebar-unavailable"),
        };

        let summary = registry
            .unread_summary_for_source_with_refresh(&captured, true, || {
                Err(unread::SIDEBAR_SNAPSHOT_UNAVAILABLE_ERROR.into())
            })
            .unwrap();

        assert!(!summary.active);
        assert_eq!(summary.count, 0);
        assert_eq!(summary.source, "codex_sidebar_unavailable");
        let cache = registry.unread_cache.lock().unwrap();
        let cached = cache.values().next().unwrap();
        assert!(cached.retry_after.is_some());
        assert_eq!(cached.failed_attempts, 1);
        assert!(cached.last_error.is_none());
    }

    #[test]
    fn forced_unread_read_still_reports_unexpected_failures() {
        let registry = LiveRateMonitorRegistry::default();
        let captured = CapturedCodexHomeSource {
            source_token: CodexHomeSourceToken {
                canonical_home_key: "unexpected-unread-failure".into(),
                physical_home_key: "physical-unexpected-unread-failure".into(),
                transition_generation: 1,
            },
            codex_home: PathBuf::from("unexpected-unread-failure"),
            source_path: PathBuf::from("unexpected-unread-failure"),
        };

        let error = registry
            .unread_summary_for_source_with_refresh(&captured, true, || {
                Err("injected persistence failure".into())
            })
            .unwrap_err();

        assert_eq!(error, "injected persistence failure");
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
    fn pinned_acknowledgement_fails_closed_without_a_live_sidebar_snapshot() {
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

        let error = result.unwrap_err();
        assert!(error.contains("pinned native unread observation is unavailable"));
        assert!(!support.join("unread-acknowledgement.json").exists());

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
