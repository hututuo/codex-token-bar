use super::c_curve;
use super::stream::{
    estimate_observed_tokens, LiveTokenCategory, LogRow, ObservedStreamEvent,
    ObservedTokenEstimator,
};
use super::LiveRateSourceScope;
use crate::models::{ModelSpeedSummary, SpeedSample};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

const MAX_PERSISTED_SAMPLES: usize = 10_000;
const MAX_RETURNED_SAMPLES: usize = 200;
const MAX_ACTIVE_TEXT_BYTES: usize = 1024 * 1024;
const IDLE_FINALIZE_SECONDS: f64 = 10.0;
const SUMMARY_15M_SECONDS: f64 = 15.0 * 60.0;
const SUMMARY_30M_SECONDS: f64 = 30.0 * 60.0;
const SUMMARY_WINDOW_SECONDS: f64 = 7.0 * 24.0 * 60.0 * 60.0;
const MAX_STORAGE_BYTES: u64 = 16 * 1024 * 1024;
const SEEN_ROW_LIMIT: usize = 10_000;
const MAX_ACTIVE_ITEMS: usize = 32;

static SPEED_STORES: OnceLock<Mutex<HashMap<LiveRateSourceScope, SpeedStore>>> = OnceLock::new();

#[derive(Default)]
struct SpeedStore {
    loaded: bool,
    samples: VecDeque<SpeedSample>,
    sample_revision: u64,
    summary_cache: Option<CachedSummaries>,
    active: HashMap<(String, String), ActiveSample>,
    item_starts: HashMap<(String, String), f64>,
    seen_rows: HashSet<i64>,
    seen_row_order: VecDeque<i64>,
    storage_error: Option<String>,
    persistence_blocked: bool,
}

#[derive(Clone)]
struct CachedSummaries {
    revision: u64,
    minute: i64,
    model_speeds_15m: Vec<ModelSpeedSummary>,
    model_speeds_30m: Vec<ModelSpeedSummary>,
    model_speeds_7d: Vec<ModelSpeedSummary>,
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

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct StoredSamples {
    version: u32,
    samples: Vec<SpeedSample>,
}

pub(super) struct Snapshot {
    pub speed_samples: Vec<SpeedSample>,
    pub model_speeds: Vec<ModelSpeedSummary>,
    pub model_speeds_15m: Vec<ModelSpeedSummary>,
    pub model_speeds_30m: Vec<ModelSpeedSummary>,
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
    ensure_loaded(store, scope);
    store
        .item_starts
        .retain(|_, at| now.is_finite() && *at <= now + 1.0 && now - *at <= 20.0);
    let mut changed = false;

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

    if changed {
        if let Err(error) = persist(store, scope) {
            store.storage_error = Some(error);
        } else {
            store.storage_error = None;
        }
    }
    let sample_count_before_prune = store.samples.len();
    store
        .samples
        .retain(|sample| now - sample.ended_at <= SUMMARY_WINDOW_SECONDS);
    if store.samples.len() != sample_count_before_prune {
        store.sample_revision = store.sample_revision.saturating_add(1);
        store.summary_cache = None;
    }
    let speed_samples = store
        .samples
        .iter()
        .rev()
        .take(MAX_RETURNED_SAMPLES)
        .cloned()
        .collect::<Vec<_>>();
    let minute = (now.max(0.0) / 60.0).floor() as i64;
    if !store
        .summary_cache
        .as_ref()
        .is_some_and(|cache| cache.revision == store.sample_revision && cache.minute == minute)
    {
        store.summary_cache = Some(CachedSummaries {
            revision: store.sample_revision,
            minute,
            model_speeds_15m: summarize(&store.samples, now, SUMMARY_15M_SECONDS),
            model_speeds_30m: summarize(&store.samples, now, SUMMARY_30M_SECONDS),
            model_speeds_7d: summarize(&store.samples, now, SUMMARY_WINDOW_SECONDS),
        });
    }
    let summaries = store
        .summary_cache
        .as_ref()
        .expect("summary cache was populated");
    Snapshot {
        has_observed_samples: !store.samples.is_empty(),
        has_active_sample: !store.active.is_empty(),
        speed_samples,
        model_speeds: summaries.model_speeds_7d.clone(),
        model_speeds_15m: summaries.model_speeds_15m.clone(),
        model_speeds_30m: summaries.model_speeds_30m.clone(),
        storage_warning: store.storage_error.clone(),
    }
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
    ensure_loaded(store, scope);
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
        if let Err(e) = persist(store, scope) {
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
    ensure_loaded(store, scope);
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
            if let Err(error) = persist(store, scope) {
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
    ensure_loaded(store, scope);
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
        if let Err(error) = persist(store, scope) {
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
    if incomplete {
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
        network_warning: active.network_warning,
        source: active.source.clone(),
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
    while store.samples.len() > MAX_PERSISTED_SAMPLES {
        store.samples.pop_front();
    }
    store.sample_revision = store.sample_revision.saturating_add(1);
    store.summary_cache = None;
    true
}

fn summarize(
    samples: &VecDeque<SpeedSample>,
    now: f64,
    window_seconds: f64,
) -> Vec<ModelSpeedSummary> {
    let mut by_model = HashMap::<String, (u64, f64, u32)>::new();
    for sample in samples.iter().filter(|sample| {
        sample
            .model
            .as_ref()
            .is_some_and(|model| !model.is_empty() && model != "unknown")
            && matches!(sample.confidence.as_str(), "medium" | "high")
            && !sample.network_warning
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
    }
    let mut summaries = by_model
        .into_iter()
        .filter_map(|(model, (output_tokens, duration_seconds, sample_count))| {
            (duration_seconds > 0.0).then_some(ModelSpeedSummary {
                model,
                tokens_per_second: output_tokens as f64 / duration_seconds,
                sample_count,
                output_tokens,
                duration_seconds,
            })
        })
        .collect::<Vec<_>>();
    summaries.sort_by(|left, right| {
        right
            .output_tokens
            .cmp(&left.output_tokens)
            .then_with(|| left.model.cmp(&right.model))
    });
    summaries
}

fn ensure_loaded(store: &mut SpeedStore, scope: &LiveRateSourceScope) {
    if store.loaded {
        return;
    }
    store.loaded = true;
    let Some(path) = storage_path(scope) else {
        store.storage_error = Some("observed_speed_storage_unavailable".into());
        store.persistence_blocked = true;
        return;
    };
    if fs::metadata(&path).is_ok_and(|metadata| metadata.len() > MAX_STORAGE_BYTES) {
        store.storage_error = Some("observed_speed_storage_too_large".into());
        store.persistence_blocked = true;
        return;
    }
    match fs::read(path) {
        Ok(bytes) => match serde_json::from_slice::<StoredSamples>(&bytes) {
            Ok(loaded) if loaded.version == 1 => {
                for sample in loaded
                    .samples
                    .into_iter()
                    .rev()
                    .take(MAX_PERSISTED_SAMPLES)
                    .rev()
                {
                    if valid_sample(&sample) {
                        store.samples.push_back(sample);
                    }
                }
                store.sample_revision = 1;
            }
            Ok(_) => {
                store.storage_error = Some("observed_speed_storage_version_unsupported".into());
                store.persistence_blocked = true;
            }
            Err(_) => {
                store.storage_error = Some("observed_speed_storage_invalid".into());
                store.persistence_blocked = true;
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => {
            store.storage_error = Some("observed_speed_storage_read_failed".into());
            store.persistence_blocked = true;
        }
    }
}

fn persist(store: &SpeedStore, scope: &LiveRateSourceScope) -> Result<(), String> {
    if store.persistence_blocked {
        return Err(store
            .storage_error
            .clone()
            .unwrap_or_else(|| "observed_speed_storage_read_failed".into()));
    }
    let path =
        storage_path(scope).ok_or_else(|| "observed_speed_storage_unavailable".to_owned())?;
    let parent = path
        .parent()
        .ok_or_else(|| "observed_speed_storage_invalid_path".to_owned())?;
    fs::create_dir_all(parent).map_err(|_| "observed_speed_storage_create_failed".to_owned())?;
    let payload = StoredSamples {
        version: 1,
        samples: store.samples.iter().cloned().collect(),
    };
    let bytes = serde_json::to_vec(&payload)
        .map_err(|_| "observed_speed_storage_serialize_failed".to_owned())?;
    crate::core::atomic_file::write_atomically(&path, &bytes)
        .map_err(|_| "observed_speed_storage_publish_failed".to_owned())
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
    crate::core::app_paths::performance_trace_log_path()
        .map(|path| path.with_file_name(format!("observed-speed-{hash:016x}.json")))
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
                network_warning: warning,
                source: "logs_2.sqlite.response_stream".into(),
            });
        }
        let summary = summarize(&samples, 100.0, SUMMARY_WINDOW_SECONDS);
        assert_eq!(summary.len(), 1);
        assert_eq!(summary[0].model, "m1");
        assert_eq!(summary[0].sample_count, 1);
        assert_eq!(summary[0].tokens_per_second, 50.0);
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
                network_warning: false,
                source: "logs_2.sqlite.response_stream".into(),
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
            network_warning: false,
            source: "logs_2.sqlite.response_stream".into(),
        };
        let encoded = serde_json::to_string(&StoredSamples {
            version: 1,
            samples: vec![sample],
        })
        .unwrap();
        assert!(!encoded.contains("hello"));
        assert!(encoded.contains("outputBytes"));
    }
}

#[cfg(test)]
mod desktop_tests {
    use super::*;
    use crate::core::desktop_stream::{DesktopStreamEvent as E, DesktopStreamEventKind as K};
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
        assert_eq!(snapshot.speed_samples.len(), 1);
        let sample = &snapshot.speed_samples[0];
        assert_eq!(sample.turn_id, "explicit-turn");
        assert_eq!(sample.model.as_deref(), Some("desktop-model"));
        assert_eq!(sample.source, "codex_desktop.forwarded_text_stream");
        assert!(!sample.network_warning);
        assert_eq!(sample.chunk_count, 12);
        assert_eq!(snapshot.model_speeds_30m.len(), 1);
    }
    #[test]
    fn desktop_reset_separates_resumed_segments_and_excludes_them_from_average() {
        let scope = LiveRateSourceScope::new("desktop-test-reset", "desktop-physical-reset");
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
        assert_eq!(snapshot.speed_samples.len(), 2);
        assert!(snapshot.speed_samples[1].network_warning);
        assert!(snapshot.model_speeds_30m.is_empty());
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
            assert_eq!(snapshot.speed_samples.len(), 1);
            assert_eq!(
                snapshot.speed_samples[0].model.as_deref(),
                if matches { Some("rollout-model") } else { None }
            );
        }
    }
}
