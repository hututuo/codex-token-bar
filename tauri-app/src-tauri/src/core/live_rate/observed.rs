use super::c_curve;
use super::speed_trend::{BodySpeedTrendPoint, BodySpeedTrendStore};
use super::stream::{
    estimate_observed_tokens, LiveTokenCategory, LogRow, ObservedStreamEvent,
    ObservedTokenEstimator,
};
use super::LiveRateSourceScope;
use crate::models::{ModelSpeedSummary, SpeedSample};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const MAX_RETURNED_SAMPLES: usize = 10;
const MAX_ACTIVE_TEXT_BYTES: usize = 1024 * 1024;
const IDLE_FINALIZE_SECONDS: f64 = 10.0;
const SUMMARY_5M_SECONDS: f64 = 5.0 * 60.0;
const SUMMARY_15M_SECONDS: f64 = 15.0 * 60.0;
const SUMMARY_30M_SECONDS: f64 = 30.0 * 60.0;
const SUMMARY_WINDOW_SECONDS: f64 = 7.0 * 24.0 * 60.0 * 60.0;
const BODY_HISTORY_WINDOW_SECONDS: f64 = 30.0 * 24.0 * 60.0 * 60.0;
const DEFAULT_BODY_RETENTION_DAYS: u16 = 30;
const BODY_RETENTION_CLEANUP_INTERVAL: std::time::Duration =
    std::time::Duration::from_secs(15 * 60);
const SEEN_ROW_LIMIT: usize = 10_000;
const MAX_ACTIVE_ITEMS: usize = 32;
const INITIAL_LOAD_RETRY_INTERVAL: Duration = Duration::from_secs(5);

static SPEED_STORES: OnceLock<Mutex<HashMap<LiveRateSourceScope, SpeedStore>>> = OnceLock::new();

#[derive(Default)]
struct SpeedStore {
    loaded: bool,
    samples: VecDeque<SpeedSample>,
    persisted_body_samples: HashMap<String, SpeedSample>,
    trend_store: Option<BodySpeedTrendStore>,
    summary_cache: Option<CachedSummaries>,
    active: HashMap<(String, String), ActiveSample>,
    item_starts: HashMap<(String, String), f64>,
    seen_rows: HashSet<i64>,
    seen_row_order: VecDeque<i64>,
    storage_error: Option<String>,
    persistence_blocked: bool,
    load_failure_permanent: bool,
    load_retry_at: Option<Instant>,
    persistence_retry_at: Option<f64>,
    last_persistence_attempt_at: f64,
    pending_prune: bool,
    body_retention_days: Option<u16>,
    last_body_retention_cleanup: Option<std::time::Instant>,
}

#[derive(Clone)]
struct CachedSummaries {
    refreshed_at: f64,
    next_change_at: f64,
    model_speeds_5m: Vec<ModelSpeedSummary>,
    model_speeds_15m: Vec<ModelSpeedSummary>,
    model_speeds_30m: Vec<ModelSpeedSummary>,
    model_speeds_7d: Vec<ModelSpeedSummary>,
    latest_model_speeds_30m: Vec<ModelSpeedSummary>,
}

struct ActiveSample {
    source: String,
    thread_id: String,
    turn_id: String,
    item_id: String,
    model: Option<String>,
    category: LiveTokenCategory,
    started_at: f64,
    ended_at: f64,
    last_timestamp: f64,
    estimated_tokens: u32,
    token_estimator: ObservedTokenEstimator,
    first_text: String,
    all_text: String,
    output_characters: u64,
    output_bytes: u64,
    chunk_count: u32,
    max_gap: f64,
    network_warning: bool,
    saw_item_start: bool,
    saw_finish_marker: bool,
}

pub(super) struct Snapshot {
    pub speed_samples: Vec<SpeedSample>,
    pub model_speeds: Vec<ModelSpeedSummary>,
    pub model_speeds_5m: Vec<ModelSpeedSummary>,
    pub model_speeds_15m: Vec<ModelSpeedSummary>,
    pub model_speeds_30m: Vec<ModelSpeedSummary>,
    pub latest_model_speeds_30m: Vec<ModelSpeedSummary>,
    pub storage_warning: Option<String>,
    pub has_observed_samples: bool,
    pub has_active_sample: bool,
}

pub(super) fn process_rows(scope: &LiveRateSourceScope, rows: &[LogRow], now: f64) -> Snapshot {
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut all = stores
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let store = all.entry(scope.clone()).or_default();
    ensure_loaded(store, scope, now);
    store
        .item_starts
        .retain(|_, at| now.is_finite() && *at <= now + 1.0 && now - *at <= 20.0);
    let retention_changed = cleanup_body_retention_if_due(store, now);
    let mut changed = retention_changed;

    for row in rows {
        if !is_retry_row(row) {
            if let Some(
                ObservedStreamEvent::Delta {
                    thread_id, item_id, ..
                }
                | ObservedStreamEvent::ItemStarted {
                    thread_id, item_id, ..
                },
            ) = super::stream::observed_stream_event(row)
            {
                if store
                    .active
                    .get(&(thread_id, item_id))
                    .is_some_and(|sample| sample.source == "codex_desktop.forwarded_text_stream")
                {
                    continue;
                }
            }
        }
        if !store.seen_rows.insert(row.id) {
            continue;
        }
        store.seen_row_order.push_back(row.id);
        while store.seen_row_order.len() > SEEN_ROW_LIMIT {
            if let Some(old) = store.seen_row_order.pop_front() {
                store.seen_rows.remove(&old);
            }
        }
        if is_retry_row(row) {
            let Some(thread_id) = row.thread_id.as_deref() else {
                continue;
            };
            let timestamp = row.timestamp();
            if c_curve::pause_for_retry(scope, thread_id, timestamp, now) {
                let current_turn =
                    c_curve::current_context(scope, thread_id).map(|context| context.0);
                let keys = store
                    .active
                    .iter()
                    .filter(|((thread, _), active)| {
                        thread == thread_id
                            && current_turn.as_deref() == Some(active.turn_id.as_str())
                    })
                    .map(|(key, _)| key.clone())
                    .collect::<Vec<_>>();
                for key in keys {
                    if let Some(mut active) = store.active.remove(&key) {
                        mark_finished(&mut active, timestamp, true);
                        if let Some(sample) = finalize_active(&mut active, now, true) {
                            changed |= add_sample(store, sample);
                        }
                    }
                }
            }
            continue;
        }
        match super::stream::observed_stream_event(row) {
            Some(ObservedStreamEvent::ItemStarted {
                thread_id,
                item_id,
                timestamp,
            }) => {
                if !timestamp.is_finite() || timestamp > now + 1.0 {
                    continue;
                }
                if thread_id.is_empty() || thread_id.len() > 512 || item_id.len() > 512 {
                    continue;
                }
                let key = (thread_id, item_id);
                store.item_starts.insert(key.clone(), timestamp);
                if let Some(active) = store.active.get_mut(&key) {
                    active.saw_item_start |= timestamp <= active.started_at;
                }
            }
            Some(ObservedStreamEvent::Delta {
                thread_id,
                item_id,
                timestamp,
                retry,
                category,
                delta,
                ..
            }) => {
                if !timestamp.is_finite() || !now.is_finite() || timestamp > now + 1.0 {
                    continue;
                }
                let Some((turn_id, model, turn_started_at)) =
                    c_curve::current_context(scope, &thread_id)
                else {
                    continue;
                };
                if timestamp < turn_started_at
                    || thread_id.is_empty()
                    || thread_id.len() > 512
                    || turn_id.is_empty()
                    || turn_id.len() > 512
                    || item_id.len() > 512
                {
                    continue;
                }
                let key = (thread_id.clone(), item_id.clone());
                let restart = store
                    .active
                    .get(&key)
                    .is_some_and(|active| active.turn_id != turn_id);
                if restart {
                    if let Some(mut active) = store.active.remove(&key) {
                        if let Some(sample) = finalize_active(&mut active, now, true) {
                            changed |= add_sample(store, sample);
                        }
                    }
                }
                if let Some(active) = store.active.get_mut(&key) {
                    let added_tokens = accumulate(active, timestamp, &delta, retry);
                    c_curve::add_observed_output(
                        scope,
                        &thread_id,
                        &turn_id,
                        added_tokens,
                        timestamp,
                    );
                } else {
                    if store.active.len() >= MAX_ACTIVE_ITEMS {
                        continue;
                    }
                    let saw_item_start = store
                        .item_starts
                        .remove(&key)
                        .is_some_and(|started| started <= timestamp);
                    let added_tokens = start_active(
                        store,
                        key,
                        thread_id.clone(),
                        turn_id.clone(),
                        model,
                        item_id,
                        category,
                        timestamp,
                        delta,
                        retry,
                        saw_item_start,
                    );
                    c_curve::add_observed_output(
                        scope,
                        &thread_id,
                        &turn_id,
                        added_tokens,
                        timestamp,
                    );
                }
            }
            Some(ObservedStreamEvent::Finished {
                thread_id,
                turn_id,
                item_id,
                failed,
                timestamp,
            }) => {
                if !timestamp.is_finite() || timestamp > now + 1.0 {
                    continue;
                }
                if turn_id.is_none() && item_id.is_none() {
                    continue;
                }
                let keys = store
                    .active
                    .iter()
                    .filter(|((candidate, candidate_item), active)| {
                        candidate == &thread_id
                            && finished_matches(
                                active,
                                turn_id.as_deref(),
                                item_id.as_deref(),
                                timestamp,
                            )
                            && (candidate_item == &active.item_id)
                    })
                    .map(|(key, _)| key.clone())
                    .collect::<Vec<_>>();
                for key in keys {
                    if let Some(mut active) = store.active.remove(&key) {
                        mark_finished(&mut active, timestamp, failed);
                        if let Some(sample) = finalize_active(&mut active, now, failed) {
                            changed |= add_sample(store, sample);
                        }
                    }
                }
            }
            None => {}
        }
    }

    let idle = store
        .active
        .iter()
        .filter(|(_, active)| now - active.ended_at >= IDLE_FINALIZE_SECONDS)
        .map(|(key, _)| key.clone())
        .collect::<Vec<_>>();
    for key in idle {
        if let Some(mut active) = store.active.remove(&key) {
            active.network_warning = true;
            if let Some(sample) = finalize_active(&mut active, now, true) {
                changed |= add_sample(store, sample);
            }
        }
    }

    changed |= backfill_unknown_models(store, scope, now);

    if changed { store.summary_cache = None; }
    if changed || persistence_is_due(store, now) {
        if let Err(error) = persist(store, scope, now, retention_changed) {
            store.storage_error = Some(error);
        } else {
            store.storage_error = None;
        }
    }
    let speed_samples = display_speed_samples(&store.samples);
    let refresh_summaries = store.summary_cache.as_ref().is_none_or(|cache| {
        !now.is_finite() || now < cache.refreshed_at || now >= cache.next_change_at
    });
    if refresh_summaries {
        store.summary_cache = Some(CachedSummaries {
            refreshed_at: now,
            next_change_at: next_summary_change(&store.samples, now),
            model_speeds_5m: display_summarize(
                &store.samples,
                &store.active,
                now,
                SUMMARY_5M_SECONDS,
            ),
            model_speeds_15m: display_summarize(
                &store.samples,
                &store.active,
                now,
                SUMMARY_15M_SECONDS,
            ),
            model_speeds_30m: display_summarize(
                &store.samples,
                &store.active,
                now,
                SUMMARY_30M_SECONDS,
            ),
            model_speeds_7d: display_summarize(
                &store.samples,
                &store.active,
                now,
                SUMMARY_WINDOW_SECONDS,
            ),
            latest_model_speeds_30m: display_latest_model_speeds_30m(&store.samples, now),
        });
    }
    let summaries = store
        .summary_cache
        .as_ref()
        .expect("summary cache was populated");
    Snapshot {
        has_observed_samples: store.samples.iter().any(is_completed_body_sample),
        has_active_sample: !store.active.is_empty(),
        speed_samples,
        model_speeds: summaries.model_speeds_7d.clone(),
        model_speeds_5m: summaries.model_speeds_5m.clone(),
        model_speeds_15m: summaries.model_speeds_15m.clone(),
        model_speeds_30m: summaries.model_speeds_30m.clone(),
        latest_model_speeds_30m: summaries.latest_model_speeds_30m.clone(),
        storage_warning: store.storage_error.clone(),
    }
}

/// Merge numeric completed-body samples into the same versioned detail store.
/// Their canonical IDs make replayed worker results safe and idempotent.
pub(super) fn process_completed_body(
    scope: &LiveRateSourceScope,
    samples: &[SpeedSample],
    now: f64,
) {
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut all = stores
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let store = all.entry(scope.clone()).or_default();
    ensure_loaded(store, scope, now);
    let retention_changed = cleanup_body_retention_if_due(store, now);
    let mut changed = retention_changed;
    let mut existing_ids = store
        .samples
        .iter()
        .enumerate()
        .filter(|(_, sample)| is_completed_body_sample(sample))
        .map(|(index, sample)| (sample.id.clone(), index))
        .collect::<HashMap<_, _>>();
    for sample in samples {
        if !is_completed_body_sample(sample)
            || !sample.ended_at.is_finite()
            || sample.ended_at > now + 2.0
            || now - sample.ended_at > BODY_HISTORY_WINDOW_SECONDS
            || !valid_sample(sample)
        {
            continue;
        }
        if let Some(index) = existing_ids.get(&sample.id).copied() {
            if let Some(existing) = store.samples.get_mut(index) {
                let mut enriched = false;
                if existing
                    .body_phase
                    .as_ref()
                    .is_none_or(|phase| phase.trim().is_empty())
                    && sample
                        .body_phase
                        .as_ref()
                        .is_some_and(|phase| !phase.trim().is_empty() && phase.len() <= 64)
                {
                    existing.body_phase = sample.body_phase.clone();
                    enriched = true;
                }
                if existing
                    .model
                    .as_deref()
                    .is_none_or(|model| model.trim().is_empty() || model == "unknown")
                    && sample
                        .model
                        .as_deref()
                        .is_some_and(|model| !model.trim().is_empty() && model != "unknown")
                {
                    existing.model = sample.model.clone();
                    enriched = true;
                }
                if enriched {
                    super::completed_body::apply_body_quality(existing);
                    changed = true;
                }
            }
        } else {
            let mut sample = sample.clone();
            super::completed_body::apply_body_quality(&mut sample);
            existing_ids.insert(sample.id.clone(), store.samples.len());
            store.samples.push_back(sample);
            changed = true;
        }
    }
    if changed {
        store.summary_cache = None;
        if let Err(error) = persist(store, scope, now, retention_changed) {
            store.storage_error = Some(error);
        } else {
            store.storage_error = None;
        }
    }
}

pub(super) fn retained_body_samples(
    scope: &LiveRateSourceScope,
    requested_retention_days: Option<u16>,
) -> (Vec<SpeedSample>, u16) {
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut all = stores
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let store = all.entry(scope.clone()).or_default();
    let now = current_time_seconds();
    ensure_loaded(store, scope, now);
    let mut changed = cleanup_body_retention_if_due(store, now);
    if let Some(days) = requested_retention_days.filter(|days| matches!(days, 15 | 30)) {
        if store.body_retention_days != Some(days) {
            store.body_retention_days = Some(days);
            changed |= prune_expired_body_samples(store, now);
            store.last_body_retention_cleanup = Some(std::time::Instant::now());
            store.summary_cache = None;
            changed = true;
        }
    }
    if changed {
        if let Err(error) = persist(store, scope, now, true) {
            store.storage_error = Some(error);
        } else {
            store.storage_error = None;
        }
    }
    let retention_days = effective_body_retention_days(store);
    let cutoff = now - f64::from(retention_days) * 86_400.0;
    let samples = store
        .samples
        .iter()
        .filter(|sample| {
            is_completed_body_sample(sample)
                && sample.ended_at.is_finite()
                && sample.ended_at >= cutoff
                && sample.ended_at <= now
        })
        .cloned()
        .collect();
    (samples, retention_days)
}

fn is_completed_body_sample(sample: &SpeedSample) -> bool {
    sample.measurement_kind.as_deref() == Some("completed_body")
        && sample.tokenizer.as_deref() == Some("o200k_base")
}

pub(super) fn has_active_sample(scope: &LiveRateSourceScope) -> bool {
    let Some(stores) = SPEED_STORES.get() else {
        return false;
    };
    stores
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(scope)
        .is_some_and(|store| !store.active.is_empty())
}

/// Desktop carries explicit turn/item identity, unlike legacy log deltas. Never infer its turn
/// from the currently selected chat or the latest rollout context.
pub(super) fn process_desktop(
    scope: &LiveRateSourceScope,
    events: &[crate::core::desktop_stream::DesktopStreamEvent],
    now: f64,
) {
    use crate::core::desktop_stream::DesktopStreamEventKind as Kind;
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut all = stores.lock().unwrap_or_else(|e| e.into_inner());
    let store = all.entry(scope.clone()).or_default();
    ensure_loaded(store, scope, now);
    let mut changed = false;
    for event in events {
        if !event.at.is_finite() || event.at > now + 1.0 {
            continue;
        }
        match event.kind {
            Kind::Status => {}
            Kind::Start => {
                if let Some(item) = &event.item_id {
                    store
                        .item_starts
                        .insert((event.thread_id.clone(), item.clone()), event.at);
                }
            }
            Kind::Delta => {
                let (Some(turn), Some(item)) = (&event.turn_id, &event.item_id) else {
                    continue;
                };
                if event.text.is_empty()
                    || event.thread_id.is_empty()
                    || turn.is_empty()
                    || item.is_empty()
                    || now - event.at > 20.0
                {
                    continue;
                }
                // Snapshot params.model may be null. Resolve only the exact explicit turn;
                // a different currently selected/running turn cannot supply its model.
                let model = if !event.model.is_empty() && event.model != "unknown" {
                    Some(event.model.clone())
                } else {
                    c_curve::current_context(scope, &event.thread_id)
                        .filter(|context| context.0 == *turn)
                        .and_then(|context| context.1)
                        .filter(|model| !model.is_empty() && model != "unknown")
                };
                let key = (event.thread_id.clone(), item.clone());
                if store.active.get(&key).is_some_and(|a| {
                    a.turn_id != *turn || a.source != "codex_desktop.forwarded_text_stream"
                }) {
                    if let Some(mut active) = store.active.remove(&key) {
                        if let Some(sample) = finalize_active(&mut active, now, true) {
                            changed |= add_sample(store, sample);
                        }
                    }
                }
                let added = if let Some(active) = store.active.get_mut(&key) {
                    if model.is_some() {
                        active.model = model.clone();
                    }
                    accumulate(active, event.at, &event.text, false)
                } else {
                    if store.active.len() >= MAX_ACTIVE_ITEMS {
                        continue;
                    }
                    let saw_start = store
                        .item_starts
                        .remove(&key)
                        .is_some_and(|at| at <= event.at);
                    let added = start_active(
                        store,
                        key.clone(),
                        event.thread_id.clone(),
                        turn.clone(),
                        model.clone(),
                        item.clone(),
                        LiveTokenCategory::VisibleText,
                        event.at,
                        event.text.clone(),
                        false,
                        saw_start,
                    );
                    if let Some(active) = store.active.get_mut(&key) {
                        active.source = "codex_desktop.forwarded_text_stream".into();
                    }
                    added
                };
                c_curve::apply_signals(
                    scope,
                    &[c_curve::RolloutSignal::Context {
                        thread_id: event.thread_id.clone(),
                        turn_id: Some(turn.clone()),
                        model: model.clone(),
                        at: event.at,
                    }],
                    now,
                );
                c_curve::add_observed_output(scope, &event.thread_id, turn, added, event.at);
            }
            Kind::Finish | Kind::Interrupted | Kind::Reset => {
                let keys = store
                    .active
                    .iter()
                    .filter(|(_, active)| {
                        active.source == "codex_desktop.forwarded_text_stream"
                            && (event.thread_id.is_empty() || event.thread_id == active.thread_id)
                            && event.turn_id.as_ref().is_none_or(|t| *t == active.turn_id)
                            && event.item_id.as_ref().is_none_or(|i| *i == active.item_id)
                    })
                    .map(|(key, _)| key.clone())
                    .collect::<Vec<_>>();
                for key in keys {
                    if let Some(mut active) = store.active.remove(&key) {
                        mark_finished(&mut active, event.at, event.kind != Kind::Finish);
                        if let Some(sample) =
                            finalize_active(&mut active, now, event.kind != Kind::Finish)
                        {
                            changed |= add_sample(store, sample);
                        }
                    }
                }
            }
        }
    }
    if changed {
        if let Err(e) = persist(store, scope, now, false) {
            store.storage_error = Some(e);
        } else {
            store.storage_error = None;
        }
    }
}

pub(super) fn desktop_active(
    scope: &LiveRateSourceScope,
    thread: &str,
    item: Option<&str>,
) -> bool {
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let all = stores.lock().unwrap_or_else(|e| e.into_inner());
    all.get(scope).is_some_and(|s| {
        s.active.values().any(|a| {
            a.source == "codex_desktop.forwarded_text_stream"
                && a.thread_id == thread
                && item.is_none_or(|i| i == a.item_id)
        })
    })
}

pub(super) fn reset_desktop(scope: &LiveRateSourceScope, now: f64) {
    process_desktop(
        scope,
        &[crate::core::desktop_stream::DesktopStreamEvent {
            kind: crate::core::desktop_stream::DesktopStreamEventKind::Reset,
            thread_id: String::new(),
            turn_id: None,
            item_id: None,
            model: "unknown".into(),
            text: String::new(),
            at: now,
        }],
        now,
    );
}

pub(super) fn finish_item(
    scope: &LiveRateSourceScope,
    thread_id: &str,
    turn_id: Option<&str>,
    item_id: &str,
    now: f64,
    failed: bool,
) {
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut all = stores
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let store = all.entry(scope.clone()).or_default();
    ensure_loaded(store, scope, now);
    let key = (thread_id.to_owned(), item_id.to_owned());
    let Some(active) = store.active.get(&key) else {
        return;
    };
    if turn_id.is_some_and(|turn| turn != active.turn_id) {
        return;
    }
    if turn_id.is_none() || now < active.ended_at {
        return;
    }
    let Some(mut active) = store.active.remove(&key) else {
        return;
    };
    mark_finished(&mut active, now, failed);
    if let Some(sample) = finalize_active(&mut active, now, failed) {
        if add_sample(store, sample) {
            if let Err(error) = persist(store, scope, now, false) {
                store.storage_error = Some(error);
            } else {
                store.storage_error = None;
            }
        }
    }
}

pub(super) fn finish_turn(
    scope: &LiveRateSourceScope,
    thread_id: &str,
    turn_id: Option<&str>,
    now: f64,
    failed: bool,
) {
    let Some(turn_id) = turn_id else {
        return;
    };
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut all = stores
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let store = all.entry(scope.clone()).or_default();
    ensure_loaded(store, scope, now);
    let keys = store
        .active
        .iter()
        .filter(|((thread, _), active)| {
            thread == thread_id && active.turn_id == turn_id && now >= active.ended_at
        })
        .map(|(key, _)| key.clone())
        .collect::<Vec<_>>();
    let mut changed = false;
    for key in keys {
        if let Some(mut active) = store.active.remove(&key) {
            mark_finished(&mut active, now, failed);
            if let Some(sample) = finalize_active(&mut active, now, failed) {
                changed |= add_sample(store, sample);
            }
        }
    }
    if changed {
        if let Err(error) = persist(store, scope, now, false) {
            store.storage_error = Some(error);
        } else {
            store.storage_error = None;
        }
    }
}

fn finished_matches(
    active: &ActiveSample,
    turn_id: Option<&str>,
    item_id: Option<&str>,
    timestamp: f64,
) -> bool {
    let has_identity = turn_id.is_some() || item_id.is_some();
    has_identity
        && turn_id.is_none_or(|turn| turn == active.turn_id)
        && item_id.is_none_or(|item| item == active.item_id)
        && timestamp >= active.started_at
        && timestamp >= active.ended_at
}

fn mark_finished(active: &mut ActiveSample, timestamp: f64, failed: bool) {
    if timestamp.is_finite() && timestamp >= active.ended_at {
        active.saw_finish_marker = true;
    }
    active.network_warning |= failed;
}

fn start_active(
    store: &mut SpeedStore,
    key: (String, String),
    thread_id: String,
    turn_id: String,
    model: Option<String>,
    item_id: String,
    category: LiveTokenCategory,
    timestamp: f64,
    delta: String,
    retry: bool,
    saw_item_start: bool,
) -> u32 {
    let safe_delta = truncate_utf8(&delta, MAX_ACTIVE_TEXT_BYTES);
    let mut token_estimator = ObservedTokenEstimator::new(category);
    let tokens = token_estimator.extend(&safe_delta);
    store.active.insert(
        key,
        ActiveSample {
            source: "logs_2.sqlite.response_stream".into(),
            thread_id,
            turn_id,
            item_id,
            model,
            category,
            started_at: timestamp,
            ended_at: timestamp,
            last_timestamp: timestamp,
            estimated_tokens: tokens,
            token_estimator,
            first_text: safe_delta.clone(),
            all_text: safe_delta,
            output_characters: 0,
            output_bytes: 0,
            chunk_count: 1,
            max_gap: 0.0,
            network_warning: retry || delta.len() > MAX_ACTIVE_TEXT_BYTES,
            saw_item_start,
            saw_finish_marker: false,
        },
    );
    tokens
}

fn accumulate(active: &mut ActiveSample, timestamp: f64, delta: &str, retry: bool) -> u32 {
    if timestamp < active.last_timestamp {
        return 0;
    }
    let previous_tokens = active.estimated_tokens;
    let gap = (timestamp - active.last_timestamp).max(0.0);
    if gap > active.max_gap {
        active.max_gap = gap;
    }
    if gap > 2.0 || retry {
        active.network_warning = true;
    }
    if timestamp > active.last_timestamp {
        active.ended_at = timestamp;
        active.last_timestamp = timestamp;
    }
    active.chunk_count = active.chunk_count.saturating_add(1);
    let remaining = MAX_ACTIVE_TEXT_BYTES.saturating_sub(active.all_text.len());
    let safe_delta = truncate_utf8(delta, remaining);
    if safe_delta.len() < delta.len() {
        active.network_warning = true;
    }
    active.output_characters = active
        .output_characters
        .saturating_add(safe_delta.chars().count() as u64);
    active.output_bytes = active.output_bytes.saturating_add(safe_delta.len() as u64);
    active.all_text.push_str(&safe_delta);
    let next_tokens = active.token_estimator.extend(&safe_delta);
    active.estimated_tokens = next_tokens;
    next_tokens.saturating_sub(previous_tokens)
}

fn finalize_active(active: &mut ActiveSample, _now: f64, incomplete: bool) -> Option<SpeedSample> {
    let duration = (active.ended_at - active.started_at).max(0.0);
    if duration <= 0.0 || active.chunk_count < 2 {
        return None;
    }
    let total_tokens = estimate_observed_tokens(&active.all_text, active.category);
    let first_tokens = estimate_observed_tokens(&active.first_text, active.category);
    let output_tokens = total_tokens.saturating_sub(first_tokens);
    if output_tokens == 0 || active.output_bytes == 0 {
        return None;
    }
    if incomplete || !active.saw_item_start {
        // `network_warning` also carries observer-quality exclusions such as a
        // midstream start so legacy persisted records can be rejected uniformly.
        active.network_warning = true;
    }
    let confidence = if output_tokens >= 500
        && duration >= 5.0
        && active.chunk_count >= 10
        && active.max_gap <= 2.0
        && active.saw_item_start
        && active.saw_finish_marker
        && !incomplete
        && !active.network_warning
    {
        "high"
    } else if output_tokens >= 100
        && duration >= 2.0
        && active.chunk_count >= 4
        && active.saw_item_start
        && active.saw_finish_marker
        && !incomplete
        && !active.network_warning
    {
        "medium"
    } else {
        "low"
    };
    let id = sample_id(
        &active.thread_id,
        &active.turn_id,
        &active.item_id,
        active.started_at,
        active.ended_at,
    );
    Some(SpeedSample {
        id,
        thread_id: active.thread_id.clone(),
        turn_id: active.turn_id.clone(),
        item_id: active.item_id.clone(),
        model: active.model.clone(),
        started_at: active.started_at,
        ended_at: active.ended_at,
        output_tokens,
        output_characters: active.output_characters,
        output_bytes: active.output_bytes,
        chunk_count: active.chunk_count,
        duration_seconds: duration,
        tokens_per_second: output_tokens as f64 / duration,
        confidence: confidence.into(),
        network_warning: active
            .network_warning
            .then(|| "流式增量采样可能不完整".to_owned()),
        source: active.source.clone(),
        measurement_kind: None,
        tokenizer: None,
        body_phase: None,
        quality_reason: None,
    })
}

fn add_sample(store: &mut SpeedStore, sample: SpeedSample) -> bool {
    if store
        .samples
        .iter()
        .any(|existing| existing.id == sample.id)
    {
        return false;
    }
    store.samples.push_back(sample);
    store.summary_cache = None;
    true
}

fn backfill_unknown_models(store: &mut SpeedStore, scope: &LiveRateSourceScope, now: f64) -> bool {
    let mut thread_turns = Vec::<(String, Vec<String>)>::new();
    let mut positions = HashMap::<String, usize>::new();
    let mut turns_by_thread = HashMap::<String, HashSet<String>>::new();

    // Prioritize active live curves so startup usage records without a nearby
    // turn_context can still resolve their own exact model metadata.
    for (thread, turns) in c_curve::unresolved_model_requests(scope, now) {
        for turn in turns {
            append_model_request(
                &mut thread_turns,
                &mut positions,
                &mut turns_by_thread,
                thread.clone(),
                turn,
            );
        }
    }

    let mut active = store
        .active
        .values()
        .filter(|sample| is_unknown_model(sample.model.as_deref()))
        .map(|sample| {
            (
                sample.thread_id.clone(),
                sample.turn_id.clone(),
                sample.last_timestamp,
            )
        })
        .collect::<Vec<_>>();
    active.sort_by(|left, right| {
        right
            .2
            .total_cmp(&left.2)
            .then_with(|| left.0.cmp(&right.0))
    });
    for (thread, turn, _) in active {
        append_model_request(
            &mut thread_turns,
            &mut positions,
            &mut turns_by_thread,
            thread,
            turn,
        );
    }

    let mut samples = store
        .samples
        .iter()
        .filter(|sample| should_resolve_sample_model(sample, now))
        .map(|sample| {
            (
                sample.thread_id.clone(),
                sample.turn_id.clone(),
                sample.ended_at,
            )
        })
        .collect::<Vec<_>>();
    samples.sort_by(|left, right| {
        right
            .2
            .total_cmp(&left.2)
            .then_with(|| left.0.cmp(&right.0))
    });
    for (thread, turn, _) in samples {
        append_model_request(
            &mut thread_turns,
            &mut positions,
            &mut turns_by_thread,
            thread,
            turn,
        );
    }

    if thread_turns.is_empty() {
        return false;
    }
    let source_key =
        super::speed_models::source_key(&scope.canonical_home_key, &scope.physical_home_key);
    let resolved = super::speed_models::poll(
        source_key,
        Path::new(&scope.canonical_home_key),
        &thread_turns,
    );
    c_curve::resolve_models(scope, &resolved, now);
    let mut changed = false;
    for sample in &mut store.samples {
        if !is_unknown_model(sample.model.as_deref()) {
            continue;
        }
        if let Some(model) = resolved
            .get(&sample.thread_id)
            .and_then(|turns| turns.get(&sample.turn_id))
        {
            sample.model = Some(model.clone());
            changed = true;
        }
    }
    for sample in store.active.values_mut() {
        if !is_unknown_model(sample.model.as_deref()) {
            continue;
        }
        if let Some(model) = resolved
            .get(&sample.thread_id)
            .and_then(|turns| turns.get(&sample.turn_id))
        {
            sample.model = Some(model.clone());
        }
    }
    changed
}

fn should_resolve_sample_model(sample: &SpeedSample, now: f64) -> bool {
    is_unknown_model(sample.model.as_deref())
        && sample.ended_at <= now + 1.0
        && now - sample.ended_at <= SUMMARY_30M_SECONDS
}

fn append_model_request(
    requested: &mut Vec<(String, Vec<String>)>,
    positions: &mut HashMap<String, usize>,
    turns_by_thread: &mut HashMap<String, HashSet<String>>,
    thread: String,
    turn: String,
) {
    if thread.is_empty() || turn.is_empty() || turn.len() > 512 {
        return;
    }
    let position = if let Some(position) = positions.get(&thread).copied() {
        Some(position)
    } else if requested.len() < 8 {
        let position = requested.len();
        requested.push((thread.clone(), Vec::new()));
        positions.insert(thread.clone(), position);
        turns_by_thread.insert(thread.clone(), HashSet::new());
        Some(position)
    } else {
        None
    };
    let Some(position) = position else {
        return;
    };
    let turns = turns_by_thread.entry(thread).or_default();
    if turns.len() < 64 && turns.insert(turn.clone()) {
        requested[position].1.push(turn);
    }
}

fn is_unknown_model(model: Option<&str>) -> bool {
    model.is_none_or(|model| model.is_empty() || model == "unknown")
}

fn is_recognized_speed_model(model: Option<&str>) -> bool {
    model.is_some_and(|model| {
        let model = model.trim();
        !model.is_empty() && !model.eq_ignore_ascii_case("unknown")
    })
}

fn display_speed_samples(samples: &VecDeque<SpeedSample>) -> Vec<SpeedSample> {
    samples
        .iter()
        .rev()
        .filter(|sample| {
            is_completed_body_sample(sample) && is_recognized_speed_model(sample.model.as_deref())
        })
        .take(MAX_RETURNED_SAMPLES)
        .cloned()
        .map(|mut sample| {
            super::completed_body::apply_body_quality(&mut sample);
            sample
        })
        .collect()
}

#[derive(Default)]
struct SummaryParts {
    output_tokens: u64,
    duration_seconds: f64,
    chunk_count: u64,
    sample_count: u32,
    active_sample_count: u32,
    qualified_sample_count: u32,
    last_measured_at: Option<f64>,
}

fn display_latest_model_speeds_30m(
    samples: &VecDeque<SpeedSample>,
    now: f64,
) -> Vec<ModelSpeedSummary> {
    if !now.is_finite() {
        return Vec::new();
    }
    let mut latest_by_model = HashMap::<String, &SpeedSample>::new();
    for sample in samples.iter().filter(|sample| {
        is_completed_body_sample(sample)
            && is_recognized_speed_model(sample.model.as_deref())
            && sample.output_tokens > 0
            && sample.duration_seconds.is_finite()
            && sample.duration_seconds > 0.0
            && sample.tokens_per_second.is_finite()
            && sample.ended_at.is_finite()
            && sample.ended_at <= now
            && now - sample.ended_at <= SUMMARY_30M_SECONDS
            && body_sample_is_qualified(sample)
    }) {
        let model = sample.model.as_ref().expect("filtered model").clone();
        let is_newer = latest_by_model.get(&model).is_none_or(|current| {
            sample.ended_at > current.ended_at
                || (sample.ended_at == current.ended_at && sample.id < current.id)
        });
        if is_newer {
            latest_by_model.insert(model, sample);
        }
    }

    let mut summaries = latest_by_model
        .into_iter()
        .map(|(model, sample)| ModelSpeedSummary {
            model,
            tokens_per_second: sample.tokens_per_second,
            sample_count: 1,
            output_tokens: u64::from(sample.output_tokens),
            duration_seconds: sample.duration_seconds,
            active_sample_count: 0,
            qualified_sample_count: 1,
            confidence: if sample.duration_seconds >= 5.0 {
                "high"
            } else {
                "medium"
            }
            .into(),
            last_measured_at: Some(sample.ended_at),
        })
        .collect::<Vec<_>>();
    summaries.sort_by(|left, right| {
        right
            .last_measured_at
            .unwrap_or(f64::NEG_INFINITY)
            .total_cmp(&left.last_measured_at.unwrap_or(f64::NEG_INFINITY))
            .then_with(|| left.model.cmp(&right.model))
    });
    summaries
}

fn display_summarize(
    samples: &VecDeque<SpeedSample>,
    _active: &HashMap<(String, String), ActiveSample>,
    now: f64,
    window_seconds: f64,
) -> Vec<ModelSpeedSummary> {
    if !now.is_finite() || !window_seconds.is_finite() || window_seconds <= 0.0 {
        return Vec::new();
    }
    let mut by_model = HashMap::<String, SummaryParts>::new();
    for sample in samples.iter().filter(|sample| {
        is_completed_body_sample(sample)
            && sample
                .model
                .as_ref()
                .is_some_and(|model| !model.is_empty() && model != "unknown")
            && sample.output_tokens > 0
            && sample.duration_seconds.is_finite()
            && sample.duration_seconds > 0.0
            && sample.tokens_per_second.is_finite()
            && sample.ended_at.is_finite()
            && sample.ended_at <= now + 1.0
            && now - sample.ended_at <= window_seconds
            && body_sample_is_qualified(sample)
    }) {
        let model = sample.model.as_ref().expect("filtered model").clone();
        let summary = by_model.entry(model).or_default();
        summary.output_tokens = summary
            .output_tokens
            .saturating_add(u64::from(sample.output_tokens));
        summary.duration_seconds += sample.duration_seconds;
        summary.sample_count = summary.sample_count.saturating_add(1);
        summary.qualified_sample_count = summary.qualified_sample_count.saturating_add(1);
        summary.last_measured_at = Some(
            summary
                .last_measured_at
                .map_or(sample.ended_at, |last| last.max(sample.ended_at)),
        );
    }

    let mut summaries = by_model
        .into_iter()
        .filter_map(|(model, parts)| {
            if parts.duration_seconds <= 0.0 || !parts.duration_seconds.is_finite() {
                return None;
            }
            let confidence = if parts.duration_seconds >= 5.0 {
                "high"
            } else {
                "medium"
            };
            Some(ModelSpeedSummary {
                model,
                tokens_per_second: parts.output_tokens as f64 / parts.duration_seconds,
                sample_count: parts.sample_count,
                output_tokens: parts.output_tokens,
                duration_seconds: parts.duration_seconds,
                active_sample_count: 0,
                qualified_sample_count: parts.qualified_sample_count,
                confidence: confidence.into(),
                last_measured_at: parts.last_measured_at,
            })
        })
        .collect::<Vec<_>>();
    summaries.sort_by(|left, right| {
        right
            .sample_count
            .cmp(&left.sample_count)
            .then_with(|| right.output_tokens.cmp(&left.output_tokens))
            .then_with(|| left.model.cmp(&right.model))
    });
    summaries
}

fn body_sample_is_qualified(sample: &SpeedSample) -> bool {
    let mut effective = sample.clone();
    super::completed_body::apply_body_quality(&mut effective);
    matches!(effective.confidence.as_str(), "medium" | "high")
}

fn aggregate_confidence(
    output_tokens: u64,
    duration_seconds: f64,
    chunk_count: u64,
) -> &'static str {
    if output_tokens >= 500 && duration_seconds >= 5.0 && chunk_count >= 10 {
        "high"
    } else if output_tokens >= 100 && duration_seconds >= 2.0 && chunk_count >= 4 {
        "medium"
    } else {
        "low"
    }
}

#[cfg(test)]
fn summarize(
    samples: &VecDeque<SpeedSample>,
    now: f64,
    window_seconds: f64,
) -> Vec<ModelSpeedSummary> {
    let mut by_model = HashMap::<String, (u64, f64, u32, u64)>::new();
    for sample in samples.iter().filter(|sample| {
        sample
            .model
            .as_ref()
            .is_some_and(|model| !model.is_empty() && model != "unknown")
            && matches!(sample.confidence.as_str(), "medium" | "high")
            && sample.network_warning.is_none()
            && sample.output_tokens > 0
            && sample.duration_seconds > 0.0
            && sample.ended_at <= now + 1.0
            && now - sample.ended_at <= window_seconds
    }) {
        let model = sample.model.clone().unwrap_or_default();
        let entry = by_model.entry(model).or_default();
        entry.0 = entry.0.saturating_add(sample.output_tokens as u64);
        entry.1 += sample.duration_seconds;
        entry.2 = entry.2.saturating_add(1);
        entry.3 = entry.3.saturating_add(u64::from(sample.chunk_count));
    }
    let mut summaries = by_model
        .into_iter()
        .filter_map(
            |(model, (output_tokens, duration_seconds, sample_count, chunk_count))| {
                (duration_seconds > 0.0).then_some(ModelSpeedSummary {
                    model,
                    tokens_per_second: output_tokens as f64 / duration_seconds,
                    sample_count,
                    output_tokens,
                    duration_seconds,
                    active_sample_count: 0,
                    qualified_sample_count: sample_count,
                    confidence: aggregate_confidence(output_tokens, duration_seconds, chunk_count)
                        .into(),
                    last_measured_at: None,
                })
            },
        )
        .collect::<Vec<_>>();
    summaries.sort_by(|left, right| {
        right
            .output_tokens
            .cmp(&left.output_tokens)
            .then_with(|| left.model.cmp(&right.model))
    });
    summaries
}

fn ensure_loaded(store: &mut SpeedStore, scope: &LiveRateSourceScope, now: f64) {
    if store.loaded || store.load_failure_permanent {
        return;
    }
    let attempt_at = Instant::now();
    if !initial_load_retry_due(store, attempt_at) {
        return;
    }
    store.load_retry_at = None;
    store.persistence_blocked = true;
    let Some(path) = storage_path(scope) else {
        record_initial_load_failure(
            store,
            "observed_speed_storage_unavailable",
            false,
            attempt_at,
        );
        return;
    };
    let Some(parent) = path.parent() else {
        record_initial_load_failure(
            store,
            "observed_speed_storage_invalid_path",
            false,
            attempt_at,
        );
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        record_initial_load_failure(
            store,
            "observed_speed_storage_create_failed",
            false,
            attempt_at,
        );
        return;
    }

    #[cfg(test)]
    let database_result = BodySpeedTrendStore::open(&path);
    #[cfg(not(test))]
    let database_result = crate::core::app_paths::multi_client_usage_database_path()
        .ok_or_else(|| rusqlite::Error::InvalidPath(path.clone()))
        .and_then(|shared_path| BodySpeedTrendStore::open_shared(&path, shared_path));
    let database = match database_result {
        Ok(database) => database,
        Err(error) => {
            let retryable = is_retryable_initial_load_error(&error);
            record_initial_load_failure(
                store,
                "observed_speed_storage_invalid",
                retryable,
                Instant::now(),
            );
            return;
        }
    };
    if let Err(error) = database.import_legacy_json(now) {
        let retryable = is_retryable_initial_load_error(&error);
        record_initial_load_failure(
            store,
            "observed_speed_legacy_history_invalid",
            retryable,
            Instant::now(),
        );
        return;
    }
    let retention_days = match database.retention_days() {
        Ok(days) => days,
        Err(error) => {
            let retryable = is_retryable_initial_load_error(&error);
            record_initial_load_failure(
                store,
                "observed_speed_storage_invalid",
                retryable,
                Instant::now(),
            );
            return;
        }
    };
    let samples = match database.read_samples(now, retention_days) {
        Ok(samples) => samples,
        Err(error) => {
            let retryable = is_retryable_initial_load_error(&error);
            record_initial_load_failure(
                store,
                "observed_speed_storage_invalid",
                retryable,
                Instant::now(),
            );
            return;
        }
    };
    let persisted = merge_loaded_body_samples(store, samples);
    store.body_retention_days = Some(retention_days);
    store.persisted_body_samples = persisted;
    store.trend_store = Some(database);
    store.last_body_retention_cleanup = Some(Instant::now());
    store.summary_cache = None;
    mark_initial_load_success(store);

    // Apply raw/dedup/aggregate retention once at startup, including when the raw
    // history preference changed while the app was closed. Existing aggregates
    // are pruned only by their independent 90-day horizon.
    match persist(store, scope, now, true) {
        Ok(()) => store.storage_error = None,
        Err(error) => store.storage_error = Some(error),
    }
}

fn initial_load_retry_due(store: &SpeedStore, now: Instant) -> bool {
    !store.load_failure_permanent && store.load_retry_at.is_none_or(|retry_at| now >= retry_at)
}

fn record_initial_load_failure(
    store: &mut SpeedStore,
    message: &str,
    retryable: bool,
    now: Instant,
) {
    store.loaded = false;
    store.persistence_blocked = true;
    store.storage_error = Some(message.to_owned());
    store.load_failure_permanent = !retryable;
    store.load_retry_at = retryable.then_some(now + INITIAL_LOAD_RETRY_INTERVAL);
}

fn mark_initial_load_success(store: &mut SpeedStore) {
    store.loaded = true;
    store.persistence_blocked = false;
    store.load_failure_permanent = false;
    store.load_retry_at = None;
    store.storage_error = None;
}

fn is_retryable_initial_load_error(error: &rusqlite::Error) -> bool {
    match error {
        rusqlite::Error::SqliteFailure(error, _) => matches!(
            error.code,
            rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
        ),
        rusqlite::Error::ToSqlConversionFailure(inner) => {
            let message = inner.to_string().to_ascii_lowercase();
            message.contains("database is locked")
                || message.contains("database table is locked")
                || message.contains("database is busy")
        }
        _ => false,
    }
}

fn merge_loaded_body_samples(
    store: &mut SpeedStore,
    persisted_samples: Vec<SpeedSample>,
) -> HashMap<String, SpeedSample> {
    let mut known_ids = HashSet::new();
    store.samples.retain(|sample| {
        !is_completed_body_sample(sample) || known_ids.insert(sample.id.clone())
    });

    let mut persisted = HashMap::new();
    for sample in persisted_samples {
        if !is_completed_body_sample(&sample) || !valid_sample(&sample) {
            continue;
        }
        persisted.insert(sample.id.clone(), sample.clone());
        // Pending in-memory revisions win over the older disk row. The next
        // persist call sees the difference and writes the revision after load.
        if known_ids.insert(sample.id.clone()) {
            store.samples.push_back(sample);
        }
    }
    persisted
}

fn effective_body_retention_days(store: &SpeedStore) -> u16 {
    store
        .body_retention_days
        .filter(|days| matches!(days, 15 | 30))
        .unwrap_or(DEFAULT_BODY_RETENTION_DAYS)
}

fn prune_expired_body_samples(store: &mut SpeedStore, now: f64) -> bool {
    if !now.is_finite() {
        return false;
    }
    let cutoff = now - f64::from(effective_body_retention_days(store)) * 86_400.0;
    let previous_len = store.samples.len();
    store.samples.retain(|sample| {
        !is_completed_body_sample(sample)
            || !sample.ended_at.is_finite()
            || sample.ended_at >= cutoff
    });
    previous_len != store.samples.len()
}

fn cleanup_body_retention_if_due(store: &mut SpeedStore, now: f64) -> bool {
    let due = store
        .last_body_retention_cleanup
        .is_none_or(|last| last.elapsed() >= BODY_RETENTION_CLEANUP_INTERVAL);
    if !due {
        return false;
    }
    store.last_body_retention_cleanup = Some(std::time::Instant::now());
    let changed = prune_expired_body_samples(store, now);
    if changed {
        store.summary_cache = None;
    }
    changed
}

fn current_time_seconds() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or_default()
}

fn next_summary_change(samples: &VecDeque<SpeedSample>, now: f64) -> f64 {
    let mut next = f64::INFINITY;
    for sample in samples.iter().filter(|s| is_completed_body_sample(s) && s.ended_at.is_finite()) {
        // Averages historically admit one second of skew; latest-body uses wall time.
        for at in [sample.ended_at - 1.0, sample.ended_at] {
            if at > now { next = next.min(at); }
        }
        for window in [SUMMARY_5M_SECONDS, SUMMARY_15M_SECONDS, SUMMARY_30M_SECONDS, SUMMARY_WINDOW_SECONDS] {
            let at = (sample.ended_at + window).next_up();
            if at > now { next = next.min(at); }
        }
    }
    next
}

fn persistence_is_due(store: &SpeedStore, now: f64) -> bool {
    store.persistence_retry_at.is_some_and(|at| now >= at || now < store.last_persistence_attempt_at)
}

/// Failed and future-dated writes stay pending independently of sample deduplication.
fn persist(store: &mut SpeedStore, scope: &LiveRateSourceScope, now: f64, force_prune: bool) -> Result<(), String> {
    store.pending_prune |= force_prune;
    if store.storage_error.is_some() && store.persistence_retry_at.is_some() && !persistence_is_due(store, now) {
        return Err(store.storage_error.clone().unwrap());
    }
    store.last_persistence_attempt_at = now;
    let result = persist_inner(store, scope, now, store.pending_prune);
    match &result {
        Ok(()) => {
            store.pending_prune = false;
            store.persistence_retry_at = store.samples.iter()
                .filter(|s| is_completed_body_sample(s) && valid_sample(s) && s.ended_at > now)
                .map(|s| s.ended_at).min_by(f64::total_cmp);
        }
        Err(_) => store.persistence_retry_at = Some(now + 5.0),
    }
    result
}

fn persist_inner(
    store: &mut SpeedStore,
    scope: &LiveRateSourceScope,
    now: f64,
    force_prune: bool,
) -> Result<(), String> {
    if store.persistence_blocked {
        return Err(store
            .storage_error
            .clone()
            .unwrap_or_else(|| "observed_speed_storage_read_failed".into()));
    }
    if !now.is_finite() || now < 0.0 {
        return Err("observed_speed_storage_invalid_time".into());
    }
    let _path =
        storage_path(scope).ok_or_else(|| "observed_speed_storage_unavailable".to_owned())?;
    let database = store
        .trend_store
        .as_ref()
        .ok_or_else(|| "observed_speed_storage_unavailable".to_owned())?;
    let retention_days = effective_body_retention_days(store);
    let trend_cutoff = now - BODY_HISTORY_WINDOW_SECONDS;
    let mut incoming = HashMap::<String, SpeedSample>::new();
    for sample in &store.samples {
        if is_completed_body_sample(sample)
            && valid_sample(sample)
            && sample.ended_at <= now
            && sample.ended_at >= trend_cutoff
        {
            incoming.insert(sample.id.clone(), sample.clone());
        }
    }
    let mut changed = incoming
        .values()
        .filter(|sample| store.persisted_body_samples.get(&sample.id) != Some(*sample))
        .cloned()
        .collect::<Vec<_>>();
    changed.sort_by(|left, right| {
        left.ended_at
            .total_cmp(&right.ended_at)
            .then_with(|| left.id.cmp(&right.id))
    });

    if changed.is_empty() && !force_prune {
        return Ok(());
    }

    database
        .ingest(&changed, now, retention_days)
        .map_err(|_| "observed_speed_storage_write_failed".to_owned())?;

    store
        .persisted_body_samples
        .retain(|_, sample| sample.ended_at >= trend_cutoff && sample.ended_at <= now);
    for sample in changed {
        if sample.ended_at >= trend_cutoff && sample.ended_at <= now {
            store
                .persisted_body_samples
                .insert(sample.id.clone(), sample);
        }
    }
    Ok(())
}

fn valid_sample(sample: &SpeedSample) -> bool {
    sample.id.len() <= 128
        && !sample.id.is_empty()
        && sample.thread_id.len() <= 512
        && !sample.thread_id.is_empty()
        && sample.turn_id.len() <= 512
        && !sample.turn_id.is_empty()
        && sample.item_id.len() <= 512
        && !sample.item_id.is_empty()
        && sample.model.as_ref().is_none_or(|model| model.len() <= 256)
        && sample
            .network_warning
            .as_ref()
            .is_none_or(|warning| warning.len() <= 512)
        && sample.measurement_kind.as_deref().is_none_or(|kind| {
            kind == "completed_body" && sample.tokenizer.as_deref() == Some("o200k_base")
        })
        && sample
            .tokenizer
            .as_ref()
            .is_none_or(|tokenizer| tokenizer.len() <= 64)
        && sample.source.len() <= 128
        && matches!(sample.confidence.as_str(), "low" | "medium" | "high")
        && sample.started_at.is_finite()
        && sample.ended_at.is_finite()
        && sample.duration_seconds.is_finite()
        && sample.tokens_per_second.is_finite()
        && sample.started_at >= 0.0
        && sample.ended_at >= sample.started_at
        && sample.duration_seconds >= 0.0
        && sample.tokens_per_second >= 0.0
}

fn storage_path(scope: &LiveRateSourceScope) -> Option<PathBuf> {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in format!("{}\n{}", scope.canonical_home_key, scope.physical_home_key).bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    #[cfg(not(test))]
    let base = crate::core::app_paths::performance_trace_log_path();
    #[cfg(test)]
    let base = {
        // Never read a previous test run's samples (or write the installed app's history).
        static TEST_ROOT: OnceLock<PathBuf> = OnceLock::new();
        let root = TEST_ROOT.get_or_init(|| {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            std::env::temp_dir().join(format!(
                "tokenbar-observed-tests-{}-{nonce}",
                std::process::id()
            ))
        });
        Some(root.join("performance-trace.log"))
    };
    base.map(|path| path.with_file_name(format!("body-speed-{hash:016x}.sqlite")))
}

pub(super) fn cache_path(scope: &LiveRateSourceScope) -> Option<PathBuf> {
    storage_path(scope)
}

pub(super) fn trend_points(
    scope: &LiveRateSourceScope, now: f64, days: u16,
) -> Result<Vec<BodySpeedTrendPoint>, String> {
    with_numeric_trend_store(scope, now, |store| store.read_distribution(now, days))
}

/// The sidebar requires raw five-minute buckets even if the home chart later
/// selects a different grouping/distribution. Reuse the existing source owner.
pub(super) fn sidebar_trend_buckets(
    scope: &LiveRateSourceScope, now: f64,
) -> Result<Vec<BodySpeedTrendPoint>, String> {
    let end = (now / 1800.0).floor() as i64 * 1800;
    with_numeric_trend_store(scope, now, |store| store.read(now, 1))
        .map(|rows| rows.into_iter().filter(|p|
            p.bucket_start >= end - 10800 && p.bucket_start < end).collect())
}

fn with_numeric_trend_store(
    scope: &LiveRateSourceScope, now: f64,
    read: impl FnOnce(&BodySpeedTrendStore) -> rusqlite::Result<Vec<BodySpeedTrendPoint>>,
) -> Result<Vec<BodySpeedTrendPoint>, String> {
    let stores = SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut all = stores.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let store = all.entry(scope.clone()).or_default();
    ensure_loaded(store, scope, now);
    if store.persistence_blocked {
        return Err(store.storage_error.clone()
            .unwrap_or_else(|| "observed_speed_storage_read_failed".into()));
    }
    let result = read(store.trend_store.as_ref()
        .ok_or_else(|| "observed_speed_storage_unavailable".to_owned())?)
        .map_err(|_| "observed_speed_trend_read_failed".to_owned());
    if let Err(error) = &result { store.storage_error = Some(error.clone()); }
    result
}

fn sample_id(thread_id: &str, turn_id: &str, item_id: &str, start: f64, end: f64) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in format!("{thread_id}\n{turn_id}\n{item_id}\n{start:.6}\n{end:.6}").bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("speed-{hash:016x}")
}

fn truncate_utf8(value: &str, maximum: usize) -> String {
    if value.len() <= maximum {
        return value.to_owned();
    }
    let mut end = maximum.min(value.len());
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn is_retry_row(row: &LogRow) -> bool {
    matches!(
        row.target.as_str(),
        "codex_core::responses_retry" | "codex_api::endpoint::responses_websocket"
    ) && [
        "stream disconnected",
        "error sending request",
        "WebSocket error",
        "websocket error",
    ]
    .iter()
    .any(|marker| row.feedback_log_body.contains(marker))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn audit_body(ended_at: f64) -> SpeedSample {
        SpeedSample { id: "audit-body".into(), thread_id: "thread".into(), turn_id: "turn".into(),
            item_id: "body".into(), model: Some("model-a".into()), started_at: ended_at - 2.0, ended_at,
            output_tokens: 100, output_characters: 200, output_bytes: 200, chunk_count: 0,
            duration_seconds: 2.0, tokens_per_second: 50.0, confidence: "medium".into(),
            network_warning: None, source: "test".into(), measurement_kind: Some("completed_body".into()),
            tokenizer: Some("o200k_base".into()), body_phase: Some("final_answer".into()), quality_reason: None }
    }

    #[test]
    fn audit_failed_write_retries_without_a_new_sample_and_future_waits() {
        let root = std::env::temp_dir().join(format!("tokenbar-speed-audit-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("speed.sqlite");
        let scope = LiveRateSourceScope::new("audit-retry", "audit-retry");
        let mut store = SpeedStore::default();
        store.samples.push_back(audit_body(1001.0));
        let error = persist(&mut store, &scope, 1000.0, true).unwrap_err();
        store.storage_error = Some(error);
        assert!(!persistence_is_due(&store, 1001.0));
        assert!(persistence_is_due(&store, 1005.0));
        store.trend_store = Some(BodySpeedTrendStore::open(&path).unwrap());
        persist(&mut store, &scope, 1005.0, false).unwrap();
        store.storage_error = None;
        assert_eq!(store.trend_store.as_ref().unwrap().read_samples(1005.0, 30).unwrap().len(), 1);
        let mut future = audit_body(1007.0); future.id = "future-body".into();
        store.samples.push_back(future);
        persist(&mut store, &scope, 1006.0, false).unwrap();
        assert_eq!(store.persistence_retry_at, Some(1007.0));
        persist(&mut store, &scope, 1007.0, false).unwrap();
        assert_eq!(store.persistence_retry_at, None);
        assert_eq!(store.trend_store.as_ref().unwrap().read_samples(1007.0, 30).unwrap().len(), 2);
        drop(store);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn busy_initial_load_retries_after_backoff_and_merges_disk_ids_once() {
        let mut store = SpeedStore::default();
        let mut pending = audit_body(1001.0);
        pending.output_tokens = 200;
        pending.tokens_per_second = 100.0;
        store.samples.push_back(pending.clone());

        let started = Instant::now();
        let busy = rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
            None,
        );
        assert!(is_retryable_initial_load_error(&busy));
        record_initial_load_failure(
            &mut store,
            "observed_speed_storage_invalid",
            true,
            started,
        );
        assert!(!store.loaded);
        assert!(store.persistence_blocked);
        assert!(store.storage_error.is_some());
        assert!(!initial_load_retry_due(
            &store,
            started + Duration::from_secs(4)
        ));
        assert!(initial_load_retry_due(
            &store,
            started + INITIAL_LOAD_RETRY_INTERVAL
        ));

        let mut persisted_revision = audit_body(1001.0);
        persisted_revision.output_tokens = 100;
        persisted_revision.tokens_per_second = 50.0;
        let mut additional = audit_body(1003.0);
        additional.id = "persisted-only".into();
        let persisted = merge_loaded_body_samples(
            &mut store,
            vec![persisted_revision.clone(), additional.clone()],
        );
        assert_eq!(store.samples.len(), 2);
        assert_eq!(
            store
                .samples
                .iter()
                .find(|sample| sample.id == pending.id)
                .unwrap()
                .output_tokens,
            200,
            "pending in-memory revision must win over the older disk row"
        );
        assert_eq!(store.samples.back().unwrap().id, additional.id);
        assert_eq!(persisted[&pending.id].output_tokens, 100);

        mark_initial_load_success(&mut store);
        assert!(store.loaded);
        assert!(!store.persistence_blocked);
        assert!(store.load_retry_at.is_none());
        assert!(store.storage_error.is_none());

        let unsupported = rusqlite::Error::InvalidQuery;
        assert!(!is_retryable_initial_load_error(&unsupported));
        record_initial_load_failure(
            &mut store,
            "observed_speed_storage_invalid",
            false,
            Instant::now(),
        );
        assert!(!initial_load_retry_due(
            &store,
            Instant::now() + Duration::from_secs(60)
        ));
        assert!(store.persistence_blocked);
        assert!(store.storage_error.is_some());
    }

    #[test]
    fn audit_idle_summary_cache_is_reused_until_deadline_or_clock_reversal() {
        let scope = LiveRateSourceScope::new("audit-summary-cache", "audit-summary-cache");
        SPEED_STORES.get_or_init(|| Mutex::new(HashMap::new())).lock().unwrap().insert(scope.clone(), SpeedStore {
            loaded: true, samples: VecDeque::from([audit_body(1000.0)]),
            last_body_retention_cleanup: Some(std::time::Instant::now()), ..Default::default()
        });
        assert_eq!(process_rows(&scope, &[], 1000.0).model_speeds_5m.len(), 1);
        for now in [1001.0, 1100.0, 1299.0, 1300.0] { process_rows(&scope, &[], now); }
        assert_eq!(SPEED_STORES.get().unwrap().lock().unwrap().get(&scope).unwrap().summary_cache.as_ref().unwrap().refreshed_at, 1000.0);
        assert!(process_rows(&scope, &[], 1300.0_f64.next_up()).model_speeds_5m.is_empty());
        assert_eq!(process_rows(&scope, &[], 1001.0).model_speeds_5m.len(), 1);
        SPEED_STORES.get().unwrap().lock().unwrap().remove(&scope);
    }

    #[test]
    fn audit_summary_deadlines_track_admission_and_strict_window_expiration() {
        let samples = VecDeque::from([audit_body(1000.0)]);
        assert_eq!(next_summary_change(&samples, 998.0), 999.0);
        assert_eq!(next_summary_change(&samples, 999.0), 1000.0);
        assert_eq!(next_summary_change(&samples, 1000.0), 1300.0_f64.next_up());
        assert_eq!(display_summarize(&samples, &HashMap::new(), 1300.0, 300.0).len(), 1);
        assert!(display_summarize(&samples, &HashMap::new(), 1300.0_f64.next_up(), 300.0).is_empty());
        assert_eq!(next_summary_change(&samples, 605801.0), f64::INFINITY);
    }

    #[test]
    fn first_chunk_is_excluded_and_text_is_counted_as_a_whole() {
        let text = "hello world and more";
        let mut token_estimator = ObservedTokenEstimator::new(LiveTokenCategory::VisibleText);
        let estimated_tokens = token_estimator.extend(text);
        let mut active = ActiveSample {
            source: "logs_2.sqlite.response_stream".into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: "item".into(),
            model: Some("model-a".into()),
            category: LiveTokenCategory::VisibleText,
            started_at: 10.0,
            ended_at: 13.0,
            last_timestamp: 13.0,
            estimated_tokens,
            token_estimator,
            first_text: "hello".into(),
            all_text: "hello world and more".into(),
            output_characters: 16,
            output_bytes: 16,
            chunk_count: 4,
            max_gap: 1.0,
            network_warning: false,
            saw_item_start: true,
            saw_finish_marker: true,
        };
        let sample = finalize_active(&mut active, 13.0, false).unwrap();
        assert!(sample.output_tokens > 0);
        assert_eq!(
            sample.output_tokens,
            estimate_observed_tokens(&active.all_text, active.category).saturating_sub(
                estimate_observed_tokens(&active.first_text, active.category)
            )
        );
        assert_eq!(sample.duration_seconds, 3.0);
        assert_eq!(sample.output_characters, 16);
        assert_eq!(sample.confidence, "low");
    }

    #[test]
    fn chunked_estimator_matches_full_text_for_split_ascii_runs() {
        let text = "This is a longer ASCII run that crosses chunks 中文, with symbols!";
        let mut estimator = ObservedTokenEstimator::new(LiveTokenCategory::VisibleText);
        for chunk in [
            "This is a longer ASCII ",
            "run that crosses",
            " chunks 中文, ",
            "with symbols!",
        ] {
            estimator.extend(chunk);
        }
        assert_eq!(
            estimator.extend(""),
            estimate_observed_tokens(text, LiveTokenCategory::VisibleText)
        );
    }

    #[test]
    fn completion_markers_preserve_first_to_last_delta_duration() {
        let mut token_estimator = ObservedTokenEstimator::new(LiveTokenCategory::VisibleText);
        let text = "first chunk plus second chunk";
        let estimated_tokens = token_estimator.extend(text);
        let mut active = ActiveSample {
            source: "logs_2.sqlite.response_stream".into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: "item".into(),
            model: Some("model-a".into()),
            category: LiveTokenCategory::VisibleText,
            started_at: 0.0,
            ended_at: 6.0,
            last_timestamp: 6.0,
            estimated_tokens,
            token_estimator,
            first_text: "first chunk".into(),
            all_text: text.into(),
            output_characters: 19,
            output_bytes: 19,
            chunk_count: 2,
            max_gap: 6.0,
            network_warning: false,
            saw_item_start: true,
            saw_finish_marker: false,
        };

        mark_finished(&mut active, 20.0, false);
        let sample = finalize_active(&mut active, 20.0, false).unwrap();
        assert_eq!(sample.started_at, 0.0);
        assert_eq!(sample.ended_at, 6.0);
        assert_eq!(sample.duration_seconds, 6.0);
    }

    #[test]
    fn old_turn_completion_does_not_match_a_new_turn_sample() {
        let mut token_estimator = ObservedTokenEstimator::new(LiveTokenCategory::VisibleText);
        let estimated_tokens = token_estimator.extend("new turn content");
        let active = ActiveSample {
            source: "logs_2.sqlite.response_stream".into(),
            thread_id: "thread".into(),
            turn_id: "turn-new".into(),
            item_id: "item-new".into(),
            model: Some("model-a".into()),
            category: LiveTokenCategory::VisibleText,
            started_at: 15.0,
            ended_at: 16.0,
            last_timestamp: 16.0,
            estimated_tokens,
            token_estimator,
            first_text: "new".into(),
            all_text: "new turn content".into(),
            output_characters: 13,
            output_bytes: 13,
            chunk_count: 2,
            max_gap: 1.0,
            network_warning: false,
            saw_item_start: true,
            saw_finish_marker: false,
        };

        assert!(!finished_matches(&active, Some("turn-old"), None, 20.0));
        assert!(!finished_matches(&active, None, Some("item-old"), 20.0));
        assert!(!finished_matches(
            &active,
            Some("turn-old"),
            Some("item-new"),
            20.0
        ));
        assert!(finished_matches(&active, Some("turn-new"), None, 20.0));
        assert!(finished_matches(&active, None, Some("item-new"), 20.0));
        assert!(!finished_matches(&active, None, None, 20.0));
        assert!(!finished_matches(&active, None, Some("item-new"), 14.0));
    }

    #[test]
    fn late_stream_completions_do_not_close_a_newer_turn_on_the_same_thread() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let scope = LiveRateSourceScope {
            canonical_home_key: format!("observed-completion-test-{suffix}"),
            physical_home_key: format!("observed-completion-test-{suffix}"),
        };
        let mut token_estimator = ObservedTokenEstimator::new(LiveTokenCategory::VisibleText);
        let estimated_tokens = token_estimator.extend("new turn content");
        let mut store = SpeedStore {
            loaded: true,
            ..SpeedStore::default()
        };
        store.active.insert(
            ("thread".into(), "item-new".into()),
            ActiveSample {
                source: "logs_2.sqlite.response_stream".into(),
                thread_id: "thread".into(),
                turn_id: "turn-new".into(),
                item_id: "item-new".into(),
                model: Some("model-a".into()),
                category: LiveTokenCategory::VisibleText,
                started_at: 15.0,
                ended_at: 16.0,
                last_timestamp: 16.0,
                estimated_tokens,
                token_estimator,
                first_text: "new".into(),
                all_text: "new turn content".into(),
                output_characters: 13,
                output_bytes: 13,
                chunk_count: 2,
                max_gap: 1.0,
                network_warning: false,
                saw_item_start: true,
                saw_finish_marker: false,
            },
        );
        SPEED_STORES
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(scope.clone(), store);

        let rows = [
            LogRow {
                id: 1,
                thread_id: Some("thread".into()),
                ts: 20,
                ts_nanos: 0,
                target: "codex_api::sse::responses".into(),
                feedback_log_body:
                    r#"SSE event: {"type":"response.completed","turn_id":"turn-old"}"#.into(),
            },
            LogRow {
                id: 2,
                thread_id: Some("thread".into()),
                ts: 20,
                ts_nanos: 0,
                target: "codex_api::sse::responses".into(),
                feedback_log_body: r#"SSE event: {"type":"response.completed"}"#.into(),
            },
            LogRow {
                id: 3,
                thread_id: Some("thread".into()),
                ts: 20,
                ts_nanos: 0,
                target: "codex_api::sse::responses".into(),
                feedback_log_body:
                    r#"SSE event: {"type":"response.output_item.done","item":{"id":"item-old"}}"#
                        .into(),
            },
        ];
        let _ = process_rows(&scope, &rows, 20.5);

        let stores = SPEED_STORES.get().unwrap();
        let mut all = stores
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let store = all.get(&scope).unwrap();
        let active = store
            .active
            .get(&("thread".into(), "item-new".into()))
            .unwrap();
        assert_eq!(active.turn_id, "turn-new");
        assert_eq!(active.ended_at, 16.0);
        all.remove(&scope);
    }

    #[test]
    fn model_summary_uses_only_unwarned_medium_or_high_samples() {
        let mut samples = VecDeque::new();
        for (id, model, confidence, warning, tokens, duration) in [
            ("a", Some("m1"), "medium", false, 200, 4.0),
            ("b", Some("m1"), "high", true, 900, 5.0),
            ("c", None, "high", false, 800, 4.0),
            ("d", Some("m2"), "low", false, 600, 3.0),
        ] {
            samples.push_back(SpeedSample {
                id: id.into(),
                thread_id: "t".into(),
                turn_id: "turn".into(),
                item_id: id.into(),
                model: model.map(str::to_owned),
                started_at: 10.0,
                ended_at: 10.0 + duration,
                output_tokens: tokens,
                output_characters: 1,
                output_bytes: 1,
                chunk_count: 10,
                duration_seconds: duration,
                tokens_per_second: tokens as f64 / duration,
                confidence: confidence.into(),
                network_warning: warning.then(|| "legacy warning".to_owned()),
                source: "logs_2.sqlite.response_stream".into(),
                measurement_kind: None,
                tokenizer: None,
                body_phase: None,
                quality_reason: None,
            });
        }
        let summary = summarize(&samples, 100.0, SUMMARY_WINDOW_SECONDS);
        assert_eq!(summary.len(), 1);
        assert_eq!(summary[0].model, "m1");
        assert_eq!(summary[0].sample_count, 1);
        assert_eq!(summary[0].tokens_per_second, 50.0);
    }

    #[test]
    fn production_summary_reclassifies_body_samples_and_excludes_low_quality_records() {
        let make_sample = |id: &str,
                           output_tokens: u32,
                           duration_seconds: f64,
                           chunk_count: u32,
                           confidence: &str,
                           network_warning: bool| {
            SpeedSample {
                id: id.into(),
                thread_id: "thread".into(),
                turn_id: "turn".into(),
                item_id: id.into(),
                model: Some("model-a".into()),
                started_at: 10.0,
                ended_at: 10.0 + duration_seconds,
                output_tokens,
                output_characters: 1,
                output_bytes: 1,
                chunk_count,
                duration_seconds,
                tokens_per_second: output_tokens as f64 / duration_seconds,
                confidence: confidence.into(),
                network_warning: network_warning.then(|| "body timing diagnostic".to_owned()),
                source: "logs_2.sqlite.response_stream".into(),
                measurement_kind: Some("completed_body".into()),
                tokenizer: Some("o200k_base".into()),
                body_phase: None,
                quality_reason: None,
            }
        };
        let samples = VecDeque::from([
            make_sample("short-boundary", 2, 0.4, 2, "high", false),
            make_sample("short-accepted", 2, 0.401, 2, "low", false),
            make_sample("qualified", 8, 3.0, 4, "low", false),
            make_sample("warned", 500, 10.0, 4, "high", true),
            make_sample("midstream", 9, 4.0, 4, "low", false),
            make_sample("high", 16, 8.0, 20, "low", false),
            make_sample("anomalous", 501, 0.5, 20, "high", false),
        ]);
        let mut samples = samples;
        let mut legacy_ipc = make_sample("ipc", 1_000, 10.0, 20, "high", false);
        legacy_ipc.measurement_kind = None;
        legacy_ipc.tokenizer = None;
        samples.push_back(legacy_ipc);

        let summary = display_summarize(&samples, &HashMap::new(), 100.0, SUMMARY_WINDOW_SECONDS);
        assert_eq!(summary.len(), 1);
        assert_eq!(summary[0].sample_count, 4);
        assert_eq!(summary[0].qualified_sample_count, 4);
        assert_eq!(summary[0].active_sample_count, 0);
        assert_eq!(summary[0].output_tokens, 35);
        assert!((summary[0].duration_seconds - 15.401).abs() < 1e-12);
        assert!((summary[0].tokens_per_second - 35.0 / 15.401).abs() < 1e-12);
        assert_eq!(summary[0].confidence, "high");
    }

    #[test]
    fn five_and_fifteen_minute_summaries_filter_expired_samples_and_weight_by_duration() {
        let now = 10_000.0;
        let make_sample =
            |id: &str, model: &str, ended_at: f64, duration_seconds: f64, output_tokens: u32| {
                SpeedSample {
                    id: id.into(),
                    thread_id: "thread".into(),
                    turn_id: "turn".into(),
                    item_id: id.into(),
                    model: Some(model.into()),
                    started_at: ended_at - duration_seconds,
                    ended_at,
                    output_tokens,
                    output_characters: u64::from(output_tokens),
                    output_bytes: u64::from(output_tokens),
                    chunk_count: 5,
                    duration_seconds,
                    tokens_per_second: f64::from(output_tokens) / duration_seconds,
                    confidence: "low".into(),
                    network_warning: None,
                    source: "test".into(),
                    measurement_kind: Some("completed_body".into()),
                    tokenizer: Some("o200k_base".into()),
                    body_phase: None,
                    quality_reason: None,
                }
            };
        let samples = VecDeque::from([
            make_sample("recent-fast", "model-a", now - 200.0, 5.0, 200),
            make_sample("recent-slow", "model-a", now - 100.0, 10.0, 100),
            make_sample("short-boundary", "model-a", now - 300.0, 0.4, 2),
            make_sample("short-accepted", "model-a", now - 250.0, 0.401, 2),
            make_sample("outside-five", "model-a", now - 400.0, 5.0, 150),
            make_sample("outside-five-other-model", "model-b", now - 400.0, 4.0, 120),
        ]);

        let five_minutes = display_summarize(&samples, &HashMap::new(), now, SUMMARY_5M_SECONDS);
        let fifteen_minutes =
            display_summarize(&samples, &HashMap::new(), now, SUMMARY_15M_SECONDS);

        assert_eq!(five_minutes.len(), 1);
        assert_eq!(five_minutes[0].model, "model-a");
        assert_eq!(five_minutes[0].sample_count, 3);
        assert_eq!(five_minutes[0].output_tokens, 302);
        assert!((five_minutes[0].duration_seconds - 15.401).abs() < 1e-12);
        assert!((five_minutes[0].tokens_per_second - 302.0 / 15.401).abs() < 1e-12);

        assert_eq!(fifteen_minutes.len(), 2);
        let model_a = fifteen_minutes
            .iter()
            .find(|summary| summary.model == "model-a")
            .unwrap();
        assert_eq!(model_a.sample_count, 4);
        assert_eq!(model_a.output_tokens, 452);
        assert!((model_a.duration_seconds - 20.401).abs() < 1e-12);
        assert!((model_a.tokens_per_second - 452.0 / 20.401).abs() < 1e-12);
        assert!(fifteen_minutes
            .iter()
            .any(|summary| summary.model == "model-b"));
    }

    #[test]
    fn summary_last_measurement_uses_only_qualified_body_samples_across_windows() {
        let make_sample = |id: &str,
                           ended_at: f64,
                           duration_seconds: f64,
                           output_tokens: u32,
                           warning: bool,
                           body: bool| {
            SpeedSample {
                id: id.into(),
                thread_id: "thread".into(),
                turn_id: "turn".into(),
                item_id: id.into(),
                model: Some("model-a".into()),
                started_at: ended_at - duration_seconds,
                ended_at,
                output_tokens,
                output_characters: u64::from(output_tokens),
                output_bytes: u64::from(output_tokens),
                chunk_count: 0,
                duration_seconds,
                tokens_per_second: f64::from(output_tokens) / duration_seconds,
                confidence: "low".into(),
                network_warning: warning.then(|| "incomplete".to_owned()),
                source: "test".into(),
                measurement_kind: body.then(|| "completed_body".into()),
                tokenizer: body.then(|| "o200k_base".into()),
                body_phase: None,
                quality_reason: None,
            }
        };
        let samples = VecDeque::from([
            make_sample("qualified-old", 99_000.0, 5.0, 100, false, true),
            make_sample("newer-warning", 99_900.0, 5.0, 100, true, true),
            make_sample("newer-short", 99_950.0, 0.4, 2, false, true),
            make_sample("newer-legacy-stream", 99_980.0, 5.0, 100, false, false),
        ]);

        let recent = display_summarize(&samples, &HashMap::new(), 100_000.0, SUMMARY_15M_SECONDS);
        assert!(recent.is_empty());

        let seven_day =
            display_summarize(&samples, &HashMap::new(), 100_000.0, SUMMARY_WINDOW_SECONDS);
        assert_eq!(seven_day.len(), 1);
        assert_eq!(seven_day[0].last_measured_at, Some(99_000.0));
    }

    #[test]
    fn latest_model_speeds_use_full_store_and_ignore_newer_unqualified_samples() {
        let now = 100_000.0;
        let make_sample = |id: &str,
                           model: &str,
                           ended_at: f64,
                           duration_seconds: f64,
                           output_tokens: u32,
                           warning: bool,
                           completed_body: bool| {
            SpeedSample {
                id: id.into(),
                thread_id: "thread".into(),
                turn_id: "turn".into(),
                item_id: id.into(),
                model: Some(model.into()),
                started_at: ended_at - duration_seconds,
                ended_at,
                output_tokens,
                output_characters: u64::from(output_tokens),
                output_bytes: u64::from(output_tokens),
                chunk_count: 0,
                duration_seconds,
                tokens_per_second: f64::from(output_tokens) / duration_seconds,
                confidence: "low".into(),
                network_warning: warning.then(|| "incomplete".to_owned()),
                source: "test".into(),
                measurement_kind: completed_body.then(|| "completed_body".into()),
                tokenizer: completed_body.then(|| "o200k_base".into()),
                body_phase: None,
                quality_reason: None,
            }
        };

        let mut samples = VecDeque::new();
        for index in 0..12 {
            samples.push_back(make_sample(
                &format!("good-{index}"),
                &format!("model-{index:02}"),
                now - 100.0 + f64::from(index),
                1.0,
                10,
                false,
                true,
            ));
        }
        samples.push_back(make_sample(
            "newer-short",
            "model-09",
            now - 1.0,
            0.4,
            2,
            false,
            true,
        ));
        samples.push_back(make_sample(
            "newer-warning",
            "model-10",
            now - 2.0,
            1.0,
            10,
            true,
            true,
        ));
        samples.push_back(make_sample(
            "newer-anomaly",
            "model-11",
            now - 3.0,
            1.0,
            1_000,
            false,
            true,
        ));
        samples.push_back(make_sample(
            "expired",
            "stale-model",
            now - SUMMARY_30M_SECONDS - 1.0,
            1.0,
            10,
            false,
            true,
        ));
        samples.push_back(make_sample(
            "unrecognized-model",
            "unknown",
            now - 4.0,
            1.0,
            10,
            false,
            true,
        ));
        samples.push_back(make_sample(
            "legacy-stream",
            "legacy-model",
            now - 5.0,
            1.0,
            10,
            false,
            false,
        ));

        let latest = display_latest_model_speeds_30m(&samples, now);
        assert_eq!(
            latest.len(),
            12,
            "models are not limited to the hot 10 rows"
        );
        assert!(!latest.iter().any(|summary| {
            summary.model == "stale-model"
                || summary.model == "unknown"
                || summary.model == "legacy-model"
        }));

        for (model, expected_ended_at) in [
            ("model-09", now - 91.0),
            ("model-10", now - 90.0),
            ("model-11", now - 89.0),
        ] {
            let summary = latest
                .iter()
                .find(|summary| summary.model == model)
                .unwrap();
            assert_eq!(summary.last_measured_at, Some(expected_ended_at));
            assert_eq!(summary.sample_count, 1);
            assert_eq!(summary.output_tokens, 10);
            assert_eq!(summary.duration_seconds, 1.0);
            assert_eq!(summary.tokens_per_second, 10.0);
            assert_eq!(summary.qualified_sample_count, 1);
        }
    }

    #[test]
    fn hot_speed_samples_filter_unknown_models_before_taking_ten() {
        let make_sample = |id: &str, model: &str, ended_at: f64| SpeedSample {
            id: id.into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: id.into(),
            model: Some(model.into()),
            started_at: ended_at - 1.0,
            ended_at,
            output_tokens: 10,
            output_characters: 10,
            output_bytes: 10,
            chunk_count: 0,
            duration_seconds: 1.0,
            tokens_per_second: 10.0,
            confidence: "low".into(),
            network_warning: None,
            source: "test".into(),
            measurement_kind: Some("completed_body".into()),
            tokenizer: Some("o200k_base".into()),
            body_phase: None,
            quality_reason: None,
        };
        let mut samples = VecDeque::new();
        for index in 0..12 {
            samples.push_back(make_sample(
                &format!("known-{index}"),
                &format!("model-{index}"),
                100.0 + f64::from(index),
            ));
        }
        for index in 0..12 {
            samples.push_back(make_sample(
                &format!("unknown-{index}"),
                "  UnKnOwN  ",
                200.0 + f64::from(index),
            ));
        }

        let hot = display_speed_samples(&samples);
        assert_eq!(hot.len(), MAX_RETURNED_SAMPLES);
        assert!(hot.iter().all(|sample| {
            sample
                .model
                .as_deref()
                .is_some_and(|model| model.starts_with("model-"))
        }));
        assert_eq!(
            hot.first().map(|sample| sample.id.as_str()),
            Some("known-11")
        );
    }

    #[test]
    fn model_backfill_candidates_are_limited_to_thirty_minutes() {
        let now = 10_000.0;
        let make_sample = |model: Option<&str>, age: f64| SpeedSample {
            id: "sample".into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: "item".into(),
            model: model.map(str::to_owned),
            started_at: now - age - 1.0,
            ended_at: now - age,
            output_tokens: 10,
            output_characters: 10,
            output_bytes: 10,
            chunk_count: 2,
            duration_seconds: 1.0,
            tokens_per_second: 10.0,
            confidence: "low".into(),
            network_warning: None,
            source: "codex_desktop.forwarded_text_stream".into(),
            measurement_kind: None,
            tokenizer: None,
            body_phase: None,
            quality_reason: None,
        };

        assert!(should_resolve_sample_model(
            &make_sample(None, SUMMARY_30M_SECONDS),
            now
        ));
        assert!(!should_resolve_sample_model(
            &make_sample(None, SUMMARY_30M_SECONDS + 0.1),
            now
        ));
        assert!(!should_resolve_sample_model(
            &make_sample(Some("known-model"), 1.0),
            now
        ));
    }

    #[test]
    fn model_summary_windows_use_the_full_sample_history() {
        let mut samples = VecDeque::new();
        for (id, model, ended_at, output_tokens, duration_seconds) in [
            ("recent", "m1", 1_400.0, 300, 6.0),
            ("older", "m2", 800.0, 600, 12.0),
        ] {
            samples.push_back(SpeedSample {
                id: id.into(),
                thread_id: "thread".into(),
                turn_id: "turn".into(),
                item_id: id.into(),
                model: Some(model.into()),
                started_at: ended_at - duration_seconds,
                ended_at,
                output_tokens,
                output_characters: 1,
                output_bytes: 1,
                chunk_count: 10,
                duration_seconds,
                tokens_per_second: output_tokens as f64 / duration_seconds,
                confidence: "high".into(),
                network_warning: None,
                source: "logs_2.sqlite.response_stream".into(),
                measurement_kind: None,
                tokenizer: None,
                body_phase: None,
                quality_reason: None,
            });
        }

        let fifteen_minutes = summarize(&samples, 2_000.0, SUMMARY_15M_SECONDS);
        let thirty_minutes = summarize(&samples, 2_000.0, SUMMARY_30M_SECONDS);
        assert_eq!(fifteen_minutes.len(), 1);
        assert_eq!(fifteen_minutes[0].model, "m1");
        assert_eq!(thirty_minutes.len(), 2);
        assert_eq!(thirty_minutes[0].model, "m2");
        assert_eq!(thirty_minutes[0].tokens_per_second, 50.0);
    }

    #[test]
    fn stored_records_contain_metadata_but_no_response_content() {
        let sample = SpeedSample {
            id: "id".into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: "item".into(),
            model: Some("m".into()),
            started_at: 1.0,
            ended_at: 3.0,
            output_tokens: 100,
            output_characters: 200,
            output_bytes: 220,
            chunk_count: 5,
            duration_seconds: 2.0,
            tokens_per_second: 50.0,
            confidence: "medium".into(),
            network_warning: None,
            source: "logs_2.sqlite.response_stream".into(),
            measurement_kind: None,
            tokenizer: None,
            body_phase: None,
            quality_reason: None,
        };
        let encoded = serde_json::to_string(&sample).unwrap();
        assert!(!encoded.contains("hello"));
        assert!(encoded.contains("outputBytes"));
    }

    #[test]
    fn completed_body_sqlite_keeps_low_quality_history_outside_the_trend() {
        let unique = format!(
            "body-persist-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let scope = LiveRateSourceScope::new(&unique, &unique);
        let path = storage_path(&scope).unwrap();
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        let now = current_time_seconds();
        let body = SpeedSample {
            id: "completed-body/new".into(),
            thread_id: "thread".into(),
            turn_id: "turn-new".into(),
            item_id: "item-new".into(),
            model: Some("model-b".into()),
            started_at: now - 4.0,
            ended_at: now,
            output_tokens: 50,
            output_characters: 100,
            output_bytes: 120,
            chunk_count: 0,
            duration_seconds: 4.0,
            tokens_per_second: 12.5,
            confidence: "low".into(),
            network_warning: None,
            source: "Codex rollout completed-body / local o200k_base".into(),
            measurement_kind: Some("completed_body".into()),
            tokenizer: Some("o200k_base".into()),
            body_phase: None,
            quality_reason: None,
        };
        let mut warned = body.clone();
        warned.id = "completed-body/warned".into();
        warned.item_id = "warned-item".into();
        warned.network_warning = Some("network pause".into());
        warned.confidence = "low".into();
        process_completed_body(&scope, &[body, warned], now);
        let persisted = BodySpeedTrendStore::open(&path)
            .unwrap()
            .read_samples(now, 30)
            .unwrap();
        assert_eq!(persisted.len(), 2);
        assert!(persisted
            .iter()
            .any(|sample| sample.id == "completed-body/warned" && sample.confidence == "low"));
        let trend = BodySpeedTrendStore::open(&path)
            .unwrap()
            .read(now, 1)
            .unwrap();
        assert_eq!(trend.len(), 1);
        assert_eq!(trend[0].model, "model-b");
        assert!(path
            .extension()
            .is_some_and(|extension| extension == "sqlite"));

        SPEED_STORES.get().unwrap().lock().unwrap().remove(&scope);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn completed_body_replay_fills_missing_phase_and_unknown_model() {
        let unique = format!(
            "body-enrichment-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let scope = LiveRateSourceScope::new(&unique, &unique);
        let path = storage_path(&scope).unwrap();
        let mut sample = SpeedSample {
            id: "completed-body/enrichment".into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: "item".into(),
            model: Some("unknown".into()),
            started_at: 20.0,
            ended_at: 24.0,
            output_tokens: 500,
            output_characters: 1000,
            output_bytes: 1100,
            chunk_count: 0,
            duration_seconds: 4.0,
            tokens_per_second: 125.0,
            confidence: "low".into(),
            network_warning: None,
            source: "Codex rollout completed-body / local o200k_base".into(),
            measurement_kind: Some("completed_body".into()),
            tokenizer: Some("o200k_base".into()),
            body_phase: None,
            quality_reason: None,
        };
        process_completed_body(&scope, &[sample.clone()], 24.0);
        sample.model = Some("gpt-5.5".into());
        sample.body_phase = Some("final_answer".into());
        process_completed_body(&scope, &[sample], 24.0);

        let stores = SPEED_STORES.get().unwrap().lock().unwrap();
        let stored = stores
            .get(&scope)
            .unwrap()
            .samples
            .iter()
            .find(|sample| sample.id == "completed-body/enrichment")
            .unwrap();
        assert_eq!(stored.model.as_deref(), Some("gpt-5.5"));
        assert_eq!(stored.body_phase.as_deref(), Some("final_answer"));
        assert_eq!(stores.get(&scope).unwrap().samples.len(), 1);
        drop(stores);
        let persisted = BodySpeedTrendStore::open(&path)
            .unwrap()
            .read_samples(24.0, 30)
            .unwrap();
        assert_eq!(persisted.len(), 1);
        assert_eq!(persisted[0].model.as_deref(), Some("gpt-5.5"));
        assert_eq!(
            BodySpeedTrendStore::open(&path)
                .unwrap()
                .read(24.0, 1)
                .unwrap()
                .len(),
            1
        );
        SPEED_STORES.get().unwrap().lock().unwrap().remove(&scope);
        let _ = fs::remove_file(path);
    }
}

#[cfg(test)]
mod desktop_tests {
    use super::*;
    use crate::core::desktop_stream::{DesktopStreamEvent as E, DesktopStreamEventKind as K};
    fn saved_samples(scope: &LiveRateSourceScope) -> Vec<SpeedSample> {
        SPEED_STORES
            .get()
            .unwrap()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(scope)
            .unwrap()
            .samples
            .iter()
            .cloned()
            .collect()
    }
    fn event(kind: K, text: &str, at: f64) -> E {
        E {
            kind,
            thread_id: "desktop-thread".into(),
            turn_id: Some("explicit-turn".into()),
            item_id: Some("item".into()),
            model: "desktop-model".into(),
            text: text.into(),
            at,
        }
    }
    #[test]
    fn desktop_explicit_identity_does_not_require_or_borrow_current_rollout_turn() {
        let scope = LiveRateSourceScope::new("desktop-test-identity", "desktop-physical-identity");
        let mut events = vec![event(K::Start, "", 100.0)];
        for i in 0..12 {
            events.push(event(
                K::Delta,
                &"hello world ".repeat(50),
                101.0 + i as f64 * 0.6,
            ));
        }
        events.push(event(K::Finish, "", 108.0));
        process_desktop(&scope, &events, 108.0);
        let snapshot = process_rows(&scope, &[], 108.0);
        // Legacy stream records remain saved, but never enter the body-only UI.
        assert!(snapshot.speed_samples.is_empty());
        let saved = saved_samples(&scope);
        assert_eq!(saved.len(), 1);
        let sample = &saved[0];
        assert_eq!(sample.turn_id, "explicit-turn");
        assert_eq!(sample.model.as_deref(), Some("desktop-model"));
        assert_eq!(sample.source, "codex_desktop.forwarded_text_stream");
        assert!(sample.network_warning.is_none());
        assert_eq!(sample.chunk_count, 12);
        assert!(snapshot.model_speeds_30m.is_empty());
    }

    #[test]
    fn desktop_summary_replaces_active_segment_without_double_counting() {
        let scope = LiveRateSourceScope::new(
            "desktop-active-to-final-test",
            "desktop-active-to-final-physical",
        );
        process_desktop(
            &scope,
            &[
                event(K::Start, "", 100.0),
                event(K::Delta, "hello ", 101.0),
                event(K::Delta, "world", 102.0),
            ],
            102.0,
        );
        let active_snapshot = process_rows(&scope, &[], 102.0);
        assert!(active_snapshot.model_speeds_30m.is_empty());

        process_desktop(&scope, &[event(K::Finish, "", 103.0)], 103.0);
        let finished_snapshot = process_rows(&scope, &[], 103.0);
        assert!(finished_snapshot.speed_samples.is_empty());
        assert_eq!(saved_samples(&scope).len(), 1);
        assert!(finished_snapshot.model_speeds_30m.is_empty());

        SPEED_STORES
            .get()
            .unwrap()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&scope);
    }
    #[test]
    fn desktop_reset_separates_resumed_segments_and_excludes_them_from_average() {
        // Use a fresh physical source: numeric speed stores survive process restarts.
        // Reusing a fixed test source can load samples produced by older collector versions.
        let unique = format!(
            "desktop-test-reset-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let scope = LiveRateSourceScope::new(&unique, &unique);
        process_desktop(
            &scope,
            &[
                event(K::Start, "", 100.0),
                event(K::Delta, "hello ", 101.0),
                event(K::Delta, "world ", 102.0),
            ],
            102.0,
        );
        reset_desktop(&scope, 103.0);
        process_desktop(
            &scope,
            &[
                event(K::Delta, "new hello ", 104.0),
                event(K::Delta, "new world ", 105.0),
                event(K::Finish, "", 106.0),
            ],
            106.0,
        );
        let snapshot = process_rows(&scope, &[], 106.0);
        assert!(snapshot.speed_samples.is_empty());
        let saved = saved_samples(&scope);
        assert_eq!(saved.len(), 2);
        assert!(saved[1].network_warning.is_some());
        assert!(saved.iter().all(|sample| sample.network_warning.is_some()));
        assert!(snapshot.model_speeds_30m.is_empty());
        SPEED_STORES.get().unwrap().lock().unwrap().remove(&scope);
        if let Some(path) = storage_path(&scope) {
            let _ = fs::remove_file(path);
        }
    }
    #[test]
    fn desktop_null_model_uses_only_matching_turn_context() {
        for matches in [true, false] {
            let name = format!("desktop-model-fallback-{matches}");
            let scope = LiveRateSourceScope::new(&name, &name);
            c_curve::apply_signals(
                &scope,
                &[c_curve::RolloutSignal::Context {
                    thread_id: "desktop-thread".into(),
                    turn_id: Some(
                        if matches {
                            "explicit-turn"
                        } else {
                            "different-turn"
                        }
                        .into(),
                    ),
                    model: Some("rollout-model".into()),
                    at: 100.0,
                }],
                100.0,
            );
            let mut events = vec![
                event(K::Start, "", 100.0),
                event(K::Delta, "hello ", 101.0),
                event(K::Delta, "world ", 102.0),
                event(K::Finish, "", 103.0),
            ];
            for e in &mut events {
                e.model = "unknown".into();
            }
            process_desktop(&scope, &events, 103.0);
            let snapshot = process_rows(&scope, &[], 103.0);
            assert!(snapshot.speed_samples.is_empty());
            let saved = saved_samples(&scope);
            assert_eq!(saved.len(), 1);
            assert_eq!(
                saved[0].model.as_deref(),
                if matches { Some("rollout-model") } else { None }
            );
        }
    }
}
