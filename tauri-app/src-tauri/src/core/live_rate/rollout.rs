use super::state::read_recent_rollout_threads;
use super::stream::{
    latest_scheduled_timestamp, LiveMetricEvent, LiveTokenCategory, WINDOW_SECONDS,
};
use super::LiveRateSourceScope;
use crate::models::CacheAdvice;
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const RECENT_ROLLOUT_LIMIT: usize = 20;
// Main/WAL signatures are still checked on each poll and invalidate immediately.
// Only the fallback reload for an unchanged database is infrequent: repeatedly
// sorting the same threads every three seconds adds idle CPU without new data.
const RECENT_ROLLOUT_TTL: Duration = Duration::from_secs(60);
const ROLLOUT_SCOPE_LIMIT: usize = 64;
const CACHE_ADVICE_FRESHNESS_SECONDS: f64 = 120.0;
const CACHE_ADVICE_LOW_INPUT_TOKENS: u64 = 20_000;
const CACHE_ADVICE_LOW_HIT_RATE: f64 = 0.3;
const CACHE_ADVICE_THREAD_LIMIT: usize = 64;
const CACHE_ADVICE_REQUEST_ID_LIMIT: usize = 128;

static ROLLOUT_STATE: OnceLock<Mutex<RolloutState>> = OnceLock::new();

#[derive(Default)]
struct RolloutState {
    next_generation: u64,
    scope_generations: HashMap<LiveRateSourceScope, u64>,
    offsets: HashMap<(LiveRateSourceScope, PathBuf), RolloutOffset>,
    retained_metrics: HashMap<LiveRateSourceScope, Vec<LiveMetricEvent>>,
    cache_advice: HashMap<LiveRateSourceScope, CacheAdviceStore>,
    recent_threads: HashMap<LiveRateSourceScope, CachedRolloutThreads>,
    #[cfg(test)]
    load_counts: HashMap<LiveRateSourceScope, usize>,
}

#[derive(Clone, Debug)]
struct RolloutOffset {
    offset: u64,
    boundary: Option<Vec<u8>>,
    identity: Option<String>,
    modified_at: Option<SystemTime>,
}

#[derive(Clone, Debug)]
struct CacheUsageSample {
    timestamp: Option<f64>,
    input_tokens: Option<u64>,
    cached_input_tokens: Option<u64>,
    total_tokens: Option<u64>,
    request_id: Option<String>,
}

enum CacheObservation {
    Sample(CacheUsageSample),
    Context { model: Option<String> },
    Reset,
}

#[derive(Default)]
struct RecentRequestIds {
    order: VecDeque<String>,
    seen: HashSet<String>,
}

impl RecentRequestIds {
    fn insert_if_new(&mut self, request_id: String) -> bool {
        if !self.seen.insert(request_id.clone()) {
            return false;
        }
        self.order.push_back(request_id);
        while self.order.len() > CACHE_ADVICE_REQUEST_ID_LIMIT {
            if let Some(oldest) = self.order.pop_front() {
                self.seen.remove(&oldest);
            }
        }
        true
    }
}

struct CacheAdviceThreadState {
    model: Option<String>,
    total_watermark: Option<u64>,
    request_ids: RecentRequestIds,
    advice: Option<CacheAdvice>,
    touched_at: Instant,
}

impl Default for CacheAdviceThreadState {
    fn default() -> Self {
        Self {
            model: None,
            total_watermark: None,
            request_ids: RecentRequestIds::default(),
            advice: None,
            touched_at: Instant::now(),
        }
    }
}

#[derive(Default)]
struct CacheAdviceStore {
    threads: HashMap<String, CacheAdviceThreadState>,
    last_poll: Option<Instant>,
    not_before: f64,
}

impl CacheAdviceStore {
    fn begin_poll(&mut self, now: f64, monotonic: Instant) {
        if self.last_poll.is_some_and(|last| monotonic.duration_since(last) > Duration::from_secs(5)) {
            self.threads.clear();
            self.not_before = now;
        }
        self.last_poll = Some(monotonic);
    }

    fn observe(
        &mut self,
        thread_id: &str,
        observation: CacheObservation,
        now: f64,
        monotonic_now: Instant,
    ) {
        if matches!(&observation, CacheObservation::Sample(sample) if sample.timestamp.is_some_and(|at| at < self.not_before)) {
            return;
        }
        if matches!(observation, CacheObservation::Reset) {
            self.threads.remove(thread_id);
            return;
        }

        let state = self.threads.entry(thread_id.to_owned()).or_default();
        state.touched_at = monotonic_now;
        match observation {
            CacheObservation::Context { model } => {
                if state.model != model {
                    *state = CacheAdviceThreadState {
                        model,
                        touched_at: monotonic_now,
                        ..CacheAdviceThreadState::default()
                    };
                }
            }
            CacheObservation::Sample(sample) => {
                state.consume_sample(sample, thread_id, now, monotonic_now);
            }
            CacheObservation::Reset => unreachable!(),
        }
        self.evict_oldest_if_needed();
    }

    fn evict_oldest_if_needed(&mut self) {
        while self.threads.len() > CACHE_ADVICE_THREAD_LIMIT {
            let Some(oldest) = self
                .threads
                .iter()
                .min_by_key(|(_, state)| state.touched_at)
                .map(|(thread_id, _)| thread_id.clone())
            else {
                return;
            };
            self.threads.remove(&oldest);
        }
    }

    fn retain_threads(&mut self, valid_thread_ids: &HashSet<String>) {
        self.threads
            .retain(|thread_id, _| valid_thread_ids.contains(thread_id));
    }

    fn reset_thread(&mut self, thread_id: &str) {
        self.threads.remove(thread_id);
    }

    fn latest(&self, now: f64) -> Option<CacheAdvice> {
        let fresh = self
            .threads
            .values()
            .filter_map(|state| state.advice.as_ref())
            .filter(|advice| {
                advice.timestamp.is_finite()
                    && advice.timestamp >= 0.0
                    && now >= advice.timestamp
                    && now - advice.timestamp <= CACHE_ADVICE_FRESHNESS_SECONDS
            })
            .collect::<Vec<_>>();
        let affected_threads = fresh.iter().filter(|advice| advice.low).count();
        fresh
            .into_iter()
            .filter(|advice| advice.low || affected_threads == 0)
            .max_by(|left, right| left.timestamp.total_cmp(&right.timestamp))
            .map(|advice| {
                let mut advice = advice.clone();
                advice.affected_threads = affected_threads;
                advice
            })
    }
}

impl CacheAdviceThreadState {
    fn clear_observation(&mut self) {
        self.advice = None;
    }

    fn consume_sample(
        &mut self,
        sample: CacheUsageSample,
        thread_id: &str,
        now: f64,
        _monotonic_now: Instant,
    ) {
        let Some(timestamp) = sample.timestamp.filter(|timestamp| {
            timestamp.is_finite()
                && *timestamp >= 0.0
                && *timestamp <= now + 1.0
                && now - *timestamp <= CACHE_ADVICE_FRESHNESS_SECONDS
        }) else {
            self.clear_observation();
            return;
        };

        let Some(input_tokens) = sample.input_tokens else {
            self.clear_observation();
            return;
        };
        let Some(cached_input_tokens) = sample.cached_input_tokens else {
            self.clear_observation();
            return;
        };
        if input_tokens == 0 || cached_input_tokens > input_tokens {
            self.clear_observation();
            return;
        }

        let hit_rate = cached_input_tokens as f64 / input_tokens as f64;
        if !hit_rate.is_finite() || !(0.0..=1.0).contains(&hit_rate) {
            self.clear_observation();
            return;
        }

        let request_is_new = sample
            .request_id
            .as_ref()
            .map(|request_id| !self.request_ids.seen.contains(request_id))
            .unwrap_or(false);
        if sample
            .request_id
            .as_ref()
            .is_some_and(|_| !request_is_new)
        {
            return;
        }

        let total_regressed = sample
            .total_tokens
            .zip(self.total_watermark)
            .is_some_and(|(total, previous)| total < previous);
        if total_regressed {
                self.advice = None;
            self.total_watermark = sample.total_tokens;
            return;
        }

        if let Some(total) = sample.total_tokens {
            if self.total_watermark == Some(total) && !request_is_new {
                return;
            }
            self.total_watermark = Some(total);
        }
        if let Some(request_id) = sample.request_id {
            self.request_ids.insert_if_new(request_id);
        }

        let qualifies_as_low = input_tokens >= CACHE_ADVICE_LOW_INPUT_TOKENS
            && hit_rate < CACHE_ADVICE_LOW_HIT_RATE;
        let low = qualifies_as_low;

        self.advice = Some(CacheAdvice {
            thread_id: thread_id.to_owned(),
            thread_title: None,
            hit_rate,
            low,
            timestamp,
            affected_threads: 0,
        });
    }
}

#[derive(Clone)]
struct CachedRolloutThreads {
    state_signature: StateDatabaseSignature,
    threads: Vec<super::state::RolloutThread>,
    refreshed_at: Instant,
}

#[derive(Clone, Debug)]
struct StateDatabaseSignature {
    main: FileSignature,
    wal: FileSignature,
}

impl StateDatabaseSignature {
    fn is_same_as(&self, other: &Self) -> bool {
        self.main.is_same_as(&other.main) && self.wal.is_same_as(&other.wal)
    }
}

pub(super) fn read_rollout_metrics(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    now: f64,
) -> rusqlite::Result<Vec<LiveMetricEvent>> {
    let (threads, generation) = recent_rollout_threads(codex_home, source_scope)?;
    let mut metrics = Vec::new();
    let mut cache_observations = Vec::new();

    for thread in threads {
        let path = thread.rollout_path;
        let signature = file_signature(&path);
        if !signature.exists || !signature.regular {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) == Some(&generation) {
                state.offsets.remove(&(source_scope.clone(), path));
                state
                    .cache_advice
                    .entry(source_scope.clone())
                    .or_default()
                    .reset_thread(&thread.id);
            }
            continue;
        }
        let file_size = signature.len;
        let key = (source_scope.clone(), path.clone());
        let (offset, reset_for_rewrite) = {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) != Some(&generation) {
                return Ok(Vec::new());
            }
            if let Some(previous) = state.offsets.get(&key).cloned() {
                let identity_changed = matches!(
                    (&previous.identity, &signature.identity),
                    (Some(previous), Some(current)) if previous != current
                );
                let same_length_rewrite = previous.offset == file_size
                    && previous.modified_at != signature.modified_at;
                let boundary_changed = (previous.modified_at != signature.modified_at || previous.offset != file_size)
                    && previous.boundary.as_ref().is_some_and(|expected|
                        read_boundary(&path, previous.offset).as_ref() != Some(expected));
                let reset = previous.offset > file_size || identity_changed || same_length_rewrite || boundary_changed;
                if reset {
                    state.offsets.insert(
                        key.clone(),
                        RolloutOffset {
                            offset: file_size,
                            boundary: read_boundary(&path, file_size),
                            identity: signature.identity.clone(),
                            modified_at: signature.modified_at,
                        },
                    );
                    (file_size, true)
                } else {
                    (previous.offset, false)
                }
            } else {
                state.offsets.insert(
                    key.clone(),
                    RolloutOffset {
                        offset: file_size,
                        boundary: read_boundary(&path, file_size),
                        identity: signature.identity.clone(),
                        modified_at: signature.modified_at,
                    },
                );
                (file_size, false)
            }
        };
        if reset_for_rewrite {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) == Some(&generation) {
                state
                    .cache_advice
                    .entry(source_scope.clone())
                    .or_default()
                    .reset_thread(&thread.id);
            }
            continue;
        }

        let (new_offset, lines) = match read_new_lines(&path, offset) {
            Ok(result) => result,
            Err(_) => {
                cache_observations.push((thread.id.clone(), CacheObservation::Reset));
                continue;
            }
        };
        {
            let mut state = rollout_state();
            if state.scope_generations.get(source_scope) != Some(&generation) {
                return Ok(Vec::new());
            }
            let boundary = if new_offset != offset { read_boundary(&path, new_offset) }
                else { state.offsets.get(&key).and_then(|previous| previous.boundary.clone()) };
            state.offsets.insert(
                key,
                RolloutOffset {
                    offset: new_offset,
                    boundary,
                    identity: signature.identity.clone(),
                    modified_at: signature.modified_at,
                },
            );
        }
        let mut call_starts = HashMap::new();
        for line in lines {
            let thread_id = thread.id.clone();
            let mut observe = |observation| {
                cache_observations.push((thread_id.clone(), observation));
            };
            metrics.extend(rollout_line_metrics(
                &thread.id,
                &path,
                line.offset,
                &line.text,
                now,
                &mut call_starts,
                &mut observe,
            ));
        }
    }

    let mut state = rollout_state();
    if state.scope_generations.get(source_scope) != Some(&generation) {
        return Ok(Vec::new());
    }
    let cache_advice = state.cache_advice.entry(source_scope.clone()).or_default();
    cache_advice.begin_poll(now, Instant::now());
    for (thread_id, observation) in cache_observations {
        cache_advice.observe(&thread_id, observation, now, Instant::now());
    }
    let retained = state
        .retained_metrics
        .entry(source_scope.clone())
        .or_default();
    retained.retain(|metric| now - latest_scheduled_timestamp(metric) <= WINDOW_SECONDS);
    let mut fingerprints = retained
        .iter()
        .map(LiveMetricEvent::fingerprint)
        .collect::<HashSet<_>>();
    retained.extend(
        metrics
            .into_iter()
            .filter(|metric| fingerprints.insert(metric.fingerprint())),
    );
    Ok(retained.clone())
}

pub(super) fn latest_cache_advice(
    source_scope: &LiveRateSourceScope,
    now: f64,
) -> Option<CacheAdvice> {
    rollout_state()
        .cache_advice
        .get(source_scope)
        .and_then(|store| store.latest(now))
}

pub(super) fn clear_cache_advice(source_scope: &LiveRateSourceScope) {
    rollout_state().cache_advice.remove(source_scope);
}

pub(super) fn rollout_file_signatures(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
) -> Vec<RolloutFileSignature> {
    let Ok((threads, _)) = recent_rollout_threads(codex_home, source_scope) else {
        return Vec::new();
    };
    threads
        .into_iter()
        .map(|thread| {
            let signature = file_signature(&thread.rollout_path);
            RolloutFileSignature {
                path: thread.rollout_path,
                len: signature.len,
                modified_at: signature.modified_at,
            }
        })
        .collect()
}

fn recent_rollout_threads(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
) -> rusqlite::Result<(Vec<super::state::RolloutThread>, u64)> {
    recent_rollout_threads_with_reader(codex_home, source_scope, || {
        read_recent_rollout_threads(codex_home, RECENT_ROLLOUT_LIMIT)
    })
}

fn recent_rollout_threads_with_reader(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    mut read_threads: impl FnMut() -> rusqlite::Result<Vec<super::state::RolloutThread>>,
) -> rusqlite::Result<(Vec<super::state::RolloutThread>, u64)> {
    for attempt in 0..2 {
        let signature_before = state_database_signature(codex_home);
        let refresh_nonce = {
            let mut state = rollout_state();
            if !state.scope_generations.contains_key(source_scope) {
                evict_oldest_scope_if_needed(&mut state);
            }
            if let Some(cached) = state.recent_threads.get(source_scope) {
                if cached.state_signature.is_same_as(&signature_before)
                    && cached.refreshed_at.elapsed() < RECENT_ROLLOUT_TTL
                {
                    return Ok((
                        cached.threads.clone(),
                        *state.scope_generations.get(source_scope).unwrap_or(&0),
                    ));
                }
            }
            state.next_generation = state.next_generation.saturating_add(1);
            let nonce = state.next_generation;
            state.scope_generations.insert(source_scope.clone(), nonce);
            nonce
        };

        let threads = read_threads()?;
        let signature_after = state_database_signature(codex_home);
        if !signature_before.is_same_as(&signature_after) {
            if rollout_state().scope_generations.get(source_scope) != Some(&refresh_nonce) {
                return Ok((threads, refresh_nonce));
            }
            if attempt == 0 {
                continue;
            }
            return Ok((threads, refresh_nonce));
        }

        let valid_paths = threads
            .iter()
            .map(|thread| thread.rollout_path.clone())
            .collect::<std::collections::HashSet<_>>();
        let valid_thread_ids = threads
            .iter()
            .map(|thread| thread.id.clone())
            .collect::<HashSet<_>>();
        let mut state = rollout_state();
        if state.scope_generations.get(source_scope) == Some(&refresh_nonce) {
            #[cfg(test)]
            {
                *state.load_counts.entry(source_scope.clone()).or_default() += 1;
            }
            state.recent_threads.insert(
                source_scope.clone(),
                CachedRolloutThreads {
                    state_signature: signature_after,
                    threads: threads.clone(),
                    refreshed_at: Instant::now(),
                },
            );
            state.offsets.retain(|(scope, path), _| {
                scope != source_scope || valid_paths.contains(path)
            });
            if let Some(cache_advice) = state.cache_advice.get_mut(source_scope) {
                cache_advice.retain_threads(&valid_thread_ids);
            }
        }
        return Ok((threads, refresh_nonce));
    }
    unreachable!("bounded rollout signature retry")
}

fn evict_oldest_scope_if_needed(state: &mut RolloutState) {
    if state.scope_generations.len() < ROLLOUT_SCOPE_LIMIT {
        return;
    }
    let Some(scope) = state
        .recent_threads
        .iter()
        .min_by_key(|(_, cached)| cached.refreshed_at)
        .map(|(scope, _)| scope.clone())
        .or_else(|| state.scope_generations.keys().next().cloned())
    else {
        return;
    };
    state.scope_generations.remove(&scope);
    state.recent_threads.remove(&scope);
    state.retained_metrics.remove(&scope);
    state.cache_advice.remove(&scope);
    state.offsets.retain(|(candidate, _), _| candidate != &scope);
    #[cfg(test)]
    state.load_counts.remove(&scope);
}

fn state_database_signature(codex_home: &Path) -> StateDatabaseSignature {
    StateDatabaseSignature {
        main: file_signature(&codex_home.join("state_5.sqlite")),
        wal: file_signature(&codex_home.join("state_5.sqlite-wal")),
    }
}

fn rollout_state() -> std::sync::MutexGuard<'static, RolloutState> {
    ROLLOUT_STATE
        .get_or_init(|| Mutex::new(RolloutState::default()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
pub(super) fn offset_key_for_test(
    scope: &LiveRateSourceScope,
    path: &Path,
) -> (LiveRateSourceScope, PathBuf) {
    (scope.clone(), path.to_path_buf())
}

#[cfg(test)]
pub(super) fn recent_thread_ids_for_test(
    codex_home: &Path,
    scope: &LiveRateSourceScope,
) -> rusqlite::Result<Vec<String>> {
    recent_rollout_threads(codex_home, scope)
        .map(|(threads, _)| threads.into_iter().map(|thread| thread.id).collect())
}

#[cfg(test)]
pub(super) fn cache_load_count_for_test(scope: &LiveRateSourceScope) -> usize {
    rollout_state().load_counts.get(scope).copied().unwrap_or(0)
}

#[cfg(test)]
pub(super) fn age_cache_for_test(scope: &LiveRateSourceScope, age: Duration) {
    if let Some(cached) = rollout_state().recent_threads.get_mut(scope) {
        cached.refreshed_at = Instant::now() - age;
    }
}

#[cfg(test)]
pub(super) fn expire_cache_for_test(scope: &LiveRateSourceScope) {
    if let Some(cached) = rollout_state().recent_threads.get_mut(scope) {
        cached.refreshed_at = Instant::now() - RECENT_ROLLOUT_TTL;
    }
}

#[cfg(test)]
pub(super) fn publish_scope_threads_for_test(
    scope: &LiveRateSourceScope,
    thread_id: &str,
) {
    let mut state = rollout_state();
    if !state.scope_generations.contains_key(scope) {
        state.next_generation = state.next_generation.saturating_add(1);
        let generation = state.next_generation;
        state.scope_generations.insert(scope.clone(), generation);
    }
    state.recent_threads.insert(
        scope.clone(),
        CachedRolloutThreads {
            state_signature: StateDatabaseSignature {
                main: file_signature(Path::new("")),
                wal: file_signature(Path::new("")),
            },
            threads: vec![super::state::RolloutThread {
                id: thread_id.into(),
                rollout_path: PathBuf::new(),
            }],
            refreshed_at: Instant::now(),
        },
    );
}

#[cfg(test)]
pub(super) fn cached_scope_thread_ids_for_test(scope: &LiveRateSourceScope) -> Vec<String> {
    rollout_state()
        .recent_threads
        .get(scope)
        .map(|cached| cached.threads.iter().map(|thread| thread.id.clone()).collect())
        .unwrap_or_default()
}

#[cfg(test)]
pub(super) fn recent_thread_ids_after_read_hook_for_test(
    codex_home: &Path,
    scope: &LiveRateSourceScope,
    after_first_read: impl FnOnce(),
) -> rusqlite::Result<Vec<String>> {
    let mut hook = Some(after_first_read);
    recent_rollout_threads_with_reader(codex_home, scope, || {
        let threads = read_recent_rollout_threads(codex_home, RECENT_ROLLOUT_LIMIT)?;
        if let Some(hook) = hook.take() {
            hook();
        }
        Ok(threads)
    })
    .map(|(threads, _)| threads.into_iter().map(|thread| thread.id).collect())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RolloutFileSignature {
    pub(super) path: PathBuf,
    pub(super) len: u64,
    pub(super) modified_at: Option<SystemTime>,
}

struct RolloutLine {
    offset: u64,
    text: String,
}

// A bounded cursor guard, read only on binding or a changed file, never an idle poll.
fn read_boundary(path: &Path, offset: u64) -> Option<Vec<u8>> {
    let count = offset.min(256) as usize;
    let mut file = File::open(path).ok()?;
    file.seek(SeekFrom::Start(offset - count as u64)).ok()?;
    let mut bytes = vec![0; count];
    file.read_exact(&mut bytes).ok()?;
    Some(bytes)
}

fn read_new_lines(path: &Path, offset: u64) -> std::io::Result<(u64, Vec<RolloutLine>)> {
    let mut file = fs::File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    if bytes.is_empty() {
        return Ok((offset, Vec::new()));
    }

    let Some(last_newline) = bytes.iter().rposition(|byte| *byte == b'\n') else {
        return Ok((offset, Vec::new()));
    };
    let consumed = &bytes[..=last_newline];
    let new_offset = offset + consumed.len() as u64;
    let mut lines = Vec::new();
    let mut line_offset = offset;
    for line in consumed.split_inclusive(|byte| *byte == b'\n') {
        let text = String::from_utf8_lossy(line);
        let line_text = text.trim_end_matches(['\r', '\n']);
        if !line_text.trim().is_empty() {
            lines.push(RolloutLine {
                offset: line_offset,
                text: line_text.to_owned(),
            });
        }
        line_offset += line.len() as u64;
    }
    Ok((new_offset, lines))
}

fn cache_observation(
    value: &Value,
    payload: &serde_json::Map<String, Value>,
    record_type: &str,
    payload_type: &str,
    timestamp: Option<f64>,
) -> Option<CacheObservation> {
    if record_type == "turn_context" {
        return Some(CacheObservation::Context {
            model: payload
                .get("model")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        });
    }
    if record_type == "compacted"
        || matches!(payload_type, "context_compacted" | "thread_rolled_back")
    {
        return Some(CacheObservation::Reset);
    }
    if record_type != "event_msg" || payload_type != "token_count" {
        return None;
    }

    let info = payload.get("info").and_then(Value::as_object);
    let last = info
        .and_then(|info| info.get("last_token_usage"))
        .and_then(Value::as_object);
    let total = info
        .and_then(|info| info.get("total_token_usage"))
        .and_then(Value::as_object);
    let request_id = payload
        .get("response_id")
        .or_else(|| payload.get("request_id"))
        .or_else(|| value.get("response_id"))
        .or_else(|| value.get("request_id"))
        .or_else(|| info.and_then(|info| info.get("response_id")))
        .or_else(|| info.and_then(|info| info.get("request_id")))
        .and_then(Value::as_str)
        .filter(|request_id| !request_id.is_empty())
        .map(ToOwned::to_owned);

    Some(CacheObservation::Sample(CacheUsageSample {
        timestamp,
        input_tokens: last.and_then(|usage| usage.get("input_tokens")).and_then(Value::as_u64),
        cached_input_tokens: last
            .and_then(|usage| usage.get("cached_input_tokens"))
            .and_then(Value::as_u64),
        total_tokens: total
            .and_then(|usage| usage.get("total_tokens"))
            .and_then(Value::as_u64),
        request_id,
    }))
}

#[cfg(test)]
mod cache_advice_tests {
    use super::*;

    fn sample(at: f64, total: Option<u64>, cached: u64) -> CacheObservation {
        CacheObservation::Sample(CacheUsageSample { timestamp: Some(at), input_tokens: Some(20_000),
            cached_input_tokens: Some(cached), total_tokens: total, request_id: None })
    }

    #[test]
    fn shared_cross_platform_fixtures() {
        let fixtures: Value = serde_json::from_str(include_str!("../../../../../fixtures/cache-usage-advice.json")).unwrap();
        let start = Instant::now();
        for fixture in fixtures.as_array().unwrap() {
            let mut store = CacheAdviceStore::default();
            for row in fixture["steps"].as_array().unwrap() {
                let at = row["at"].as_f64().unwrap();
                store.observe(row["thread"].as_str().unwrap_or("a"), CacheObservation::Sample(CacheUsageSample {
                    timestamp: Some(at), input_tokens: row["input"].as_u64(),
                    cached_input_tokens: row["cached"].as_u64(), total_tokens: row["total"].as_u64(), request_id: None,
                }), at, start + Duration::from_secs_f64(at));
                assert_eq!(store.latest(at).map(|advice| advice.low), row["low"].as_bool(), "{} at {}", fixture["name"], at);
            }
        }
    }

    #[test]
    fn parser_extracts_cache_with_zero_reasoning_without_rate_events() {
        let line = r#"{"timestamp":"2026-09-16T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20000,"cached_input_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"total_tokens":20000}}}}"#;
        let mut observations = Vec::new();
        let events = rollout_line_metrics("a", Path::new("fixture"), 0, line, 0.0, &mut HashMap::new(), &mut |sample| observations.push(sample));
        assert!(events.is_empty());
        assert!(matches!(&observations[0], CacheObservation::Sample(sample) if sample.input_tokens == Some(20_000) && sample.cached_input_tokens == Some(0)));
        for invalid in ["true", "-1", "2.5", "null", "\"20000\""] {
            let value: Value = serde_json::from_str(&line.replace("\"input_tokens\":20000", &format!("\"input_tokens\":{invalid}"))).unwrap();
            let observation = cache_observation(&value, value["payload"].as_object().unwrap(), "event_msg", "token_count", Some(100.0)).unwrap();
            assert!(matches!(observation, CacheObservation::Sample(sample) if sample.input_tokens.is_none()));
        }
    }

    #[test]
    fn latest_prioritizes_anomalies_and_expires_without_reads() {
        let mut store = CacheAdviceStore::default();
        let now = Instant::now();
        for thread in ["a", "b"] {
            store.observe(thread, sample(100.0, Some(20_000), 100), 100.0, now);
            store.observe(thread, sample(101.0, Some(40_000), 100), 101.0, now);
        }
        store.observe("healthy", sample(102.0, Some(20_000), 19_000), 102.0, now);
        let advice = store.latest(102.0).unwrap();
        assert!(advice.low);
        assert_eq!(advice.affected_threads, 2);
        assert!(store.latest(223.0).is_none());
    }

    #[test]
    fn context_reset_recovery_and_request_identity() {
        let mut store = CacheAdviceStore::default();
        let now = Instant::now();
        for (at, total, cached) in [(100., 20_000, 100), (101., 40_000, 100), (102., 60_000, 19_000), (103., 80_000, 100), (104., 100_000, 100)] {
            store.observe("a", sample(at, Some(total), cached), at, now + Duration::from_secs_f64(at));
        }
        assert!(store.latest(104.).unwrap().low);
        store.observe("a", CacheObservation::Context { model: Some("new-model".into()) }, 105., now);
        store.observe("a", sample(106., Some(120_000), 100), 106., now);
        assert!(store.latest(106.).unwrap().low);
        store.observe("a", CacheObservation::Reset, 107., now);
        assert!(store.latest(107.).is_none());
        let identified = |at, id: &str| CacheObservation::Sample(CacheUsageSample {
            timestamp: Some(at), input_tokens: Some(20_000), cached_input_tokens: Some(0), total_tokens: None, request_id: Some(id.into()) });
        store.observe("a", identified(108., "r1"), 108., now);
        store.observe("a", identified(109., "r1"), 109., now);
        assert!(store.latest(109.).unwrap().low);
        assert_eq!(store.latest(109.).unwrap().timestamp, 108.);
        store.observe("a", identified(110., "r2"), 110., now);
        assert!(store.latest(110.).unwrap().low);
    }

    #[test]
    fn invalid_utf8_does_not_shift_byte_cursor() {
        let path = std::env::temp_dir().join(format!("cache-advice-offset-{}-{}", std::process::id(), SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        fs::write(&path, [0xff, b'\n', b'{', b'}', b'\n', b'x']).unwrap();
        let (offset, lines) = read_new_lines(&path, 0).unwrap();
        assert_eq!(offset, 5);
        assert_eq!(lines[1].offset, 2);
        assert!(read_new_lines(&path, offset).unwrap().1.is_empty());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn long_monitor_pause_drops_backlog_and_same_inode_rewrite_changes_boundary() {
        let mut store = CacheAdviceStore::default();
        let start = Instant::now();
        store.begin_poll(100., start);
        store.observe("a", sample(100., Some(20_000), 100), 100., start);
        store.begin_poll(110., start + Duration::from_secs(10));
        store.observe("a", sample(101., Some(40_000), 100), 110., start + Duration::from_secs(10));
        assert!(store.latest(110.).is_none());
        store.observe("a", sample(111., Some(60_000), 100), 111., start + Duration::from_secs(11));
        assert!(store.latest(111.).unwrap().low);
        let path = std::env::temp_dir().join(format!("cache-advice-boundary-{}", std::process::id()));
        fs::write(&path, b"original\n").unwrap();
        let original = read_boundary(&path, 9).unwrap();
        fs::write(&path, b"rewritten and longer\n").unwrap();
        assert_ne!(read_boundary(&path, 9).unwrap(), original);
        fs::remove_file(path).unwrap();
    }
}

fn rollout_line_metrics(
    thread_id: &str,
    path: &Path,
    line_offset: u64,
    line: &str,
    now: f64,
    call_starts: &mut HashMap<String, f64>,
    observe_cache: &mut impl FnMut(CacheObservation),
) -> Vec<LiveMetricEvent> {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    let Some(payload) = value.get("payload").and_then(Value::as_object) else {
        return Vec::new();
    };
    let parsed_timestamp = parse_timestamp(value.get("timestamp").and_then(Value::as_str));
    let timestamp = parsed_timestamp.unwrap_or(now);
    let record_type = value.get("type").and_then(Value::as_str).unwrap_or_default();
    let payload_type = payload.get("type").and_then(Value::as_str).unwrap_or_default();
    if let Some(observation) = cache_observation(
        &value,
        payload,
        record_type,
        payload_type,
        parsed_timestamp,
    ) {
        observe_cache(observation);
    }
    let key_prefix = payload
        .get("call_id")
        .or_else(|| payload.get("id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("{}:{line_offset}", path.display()));

    if record_type == "response_item" && payload_type == "function_call" {
        call_starts.insert(key_prefix.clone(), timestamp);
        let name = payload.get("name").and_then(Value::as_str);
        let arguments = payload.get("arguments").and_then(Value::as_str).unwrap_or("");
        if arguments.is_empty() {
            return Vec::new();
        }
        let category = if name == Some("apply_patch") {
            LiveTokenCategory::PatchInput
        } else {
            LiveTokenCategory::ToolArguments
        };
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.function_call",
            format!("{key_prefix}:{}", category.key()),
            category,
            arguments.to_owned(),
            true,
            None,
            None,
        )];
    }

    if record_type == "response_item" && payload_type == "custom_tool_call" {
        call_starts.insert(key_prefix.clone(), timestamp);
        let name = payload.get("name").and_then(Value::as_str);
        let input = payload.get("input").and_then(Value::as_str).unwrap_or("");
        if input.is_empty() {
            return Vec::new();
        }
        let category = if name == Some("apply_patch") {
            LiveTokenCategory::PatchInput
        } else {
            LiveTokenCategory::ToolArguments
        };
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.custom_tool_call",
            format!("{key_prefix}:{}", category.key()),
            category,
            input.to_owned(),
            true,
            None,
            None,
        )];
    }

    if record_type == "event_msg" && payload_type == "agent_message" {
        let text = message_text(&Value::Object(payload.clone()));
        if text.is_empty() {
            return Vec::new();
        }
        return vec![metric_with_dedupe(
            thread_id,
            timestamp,
            "rollout.agent_message",
            key_prefix,
            LiveTokenCategory::VisibleText,
            text.clone(),
            true,
            None,
            None,
            visible_text_dedupe_key(thread_id, timestamp, &text),
        )];
    }

    if record_type == "response_item"
        && (payload_type == "message" || payload_type == "assistant")
        && payload.get("role").and_then(Value::as_str).unwrap_or("assistant") == "assistant"
    {
        let text = message_text(&Value::Object(payload.clone()));
        if text.is_empty() {
            return Vec::new();
        }
        return vec![metric_with_dedupe(
            thread_id,
            timestamp,
            "rollout.assistant_message",
            key_prefix,
            LiveTokenCategory::VisibleText,
            text.clone(),
            true,
            None,
            None,
            visible_text_dedupe_key(thread_id, timestamp, &text),
        )];
    }

    if record_type == "response_item"
        && (payload_type == "function_call_output" || payload_type == "custom_tool_call_output")
    {
        let output = payload.get("output").and_then(Value::as_str).unwrap_or("");
        if output.is_empty() {
            return Vec::new();
        }
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.tool_output",
            format!("{key_prefix}:toolOutput"),
            LiveTokenCategory::ToolOutput,
            output.to_owned(),
            true,
            None,
            call_starts.get(&key_prefix).copied(),
        )];
    }

    if record_type == "event_msg" && payload_type == "patch_apply_end" {
        let text = payload
            .get("changes")
            .and_then(Value::as_object)
            .map(|changes| {
                changes
                    .values()
                    .filter_map(|change| {
                        change
                            .get("content")
                            .or_else(|| change.get("unified_diff"))
                            .and_then(Value::as_str)
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default();
        if text.is_empty() {
            return Vec::new();
        }
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.patch_apply_end",
            format!("{key_prefix}:patchApplied"),
            LiveTokenCategory::PatchApplied,
            text,
            true,
            None,
            call_starts.get(&key_prefix).copied(),
        )];
    }

    if record_type == "event_msg" && payload_type == "token_count" {
        let usage = payload
            .get("info")
            .and_then(|info| info.get("last_token_usage"));
        let reasoning = usage
            .and_then(|usage| usage.get("reasoning_output_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if reasoning == 0 {
            return Vec::new();
        }
        return vec![metric(
            thread_id,
            timestamp,
            "rollout.token_count",
            format!("{key_prefix}:reasoning"),
            LiveTokenCategory::Reasoning,
            String::new(),
            true,
            Some(reasoning.min(u64::from(u32::MAX)) as u32),
            None,
        )];
    }

    Vec::new()
}

fn metric(
    thread_id: &str,
    timestamp: f64,
    event_type: &str,
    item_id: String,
    category: LiveTokenCategory,
    delta: String,
    distributed: bool,
    exact_tokens: Option<u32>,
    start_timestamp: Option<f64>,
) -> LiveMetricEvent {
    let dedupe_key = format!("{event_type}:{thread_id}:{item_id}:{timestamp:.6}:{delta}");
    metric_with_dedupe(
        thread_id,
        timestamp,
        event_type,
        item_id,
        category,
        delta.clone(),
        distributed,
        exact_tokens,
        start_timestamp,
        dedupe_key,
    )
}

fn metric_with_dedupe(
    thread_id: &str,
    timestamp: f64,
    event_type: &str,
    item_id: String,
    category: LiveTokenCategory,
    delta: String,
    distributed: bool,
    exact_tokens: Option<u32>,
    start_timestamp: Option<f64>,
    dedupe_key: String,
) -> LiveMetricEvent {
    LiveMetricEvent {
        event_type: event_type.into(),
        timestamp,
        thread_id: Some(thread_id.into()),
        item_id,
        sequence_number: None,
        category,
        delta,
        exact_tokens,
        start_timestamp,
        distributed,
        spreads_forward: start_timestamp.is_none(),
        dedupe_key: Some(dedupe_key),
    }
}

fn visible_text_dedupe_key(thread_id: &str, timestamp: f64, text: &str) -> String {
    let bucket = timestamp.floor() as i64;
    format!("rollout.visible:{thread_id}:{bucket}:{}", fnv1a64(text))
}

fn fnv1a64(text: &str) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn message_text(value: &Value) -> String {
    if let Some(text) = value.get("text").and_then(Value::as_str) {
        return text.to_owned();
    }
    if let Some(message) = value.get("message").and_then(Value::as_str) {
        return message.to_owned();
    }
    let Some(content) = value.get("content") else {
        return String::new();
    };
    if let Some(text) = content.as_str() {
        return text.to_owned();
    }
    content
        .as_array()
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default()
}

fn parse_timestamp(text: Option<&str>) -> Option<f64> {
    let text = text?;
    let parsed = OffsetDateTime::parse(text, &Rfc3339).ok()?;
    Some(parsed.unix_timestamp() as f64 + f64::from(parsed.nanosecond()) / 1_000_000_000.0)
}

fn file_size(path: &Path) -> Option<u64> {
    fs::metadata(path)
        .ok()
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
}

fn file_signature(path: &Path) -> FileSignature {
    file_signature_with_identity(path, file_identity)
}

fn file_signature_with_identity(
    path: &Path,
    identity_reader: impl FnOnce(&File) -> Option<String>,
) -> FileSignature {
    File::open(path)
        .and_then(|file| file.metadata().map(|metadata| (file, metadata)))
        .map(|(file, metadata)| FileSignature {
            exists: true,
            regular: metadata.is_file(),
            identity: identity_reader(&file),
            len: metadata.len(),
            modified_at: metadata.modified().ok(),
        })
        .unwrap_or(FileSignature {
            exists: false,
            regular: false,
            identity: None,
            len: 0,
            modified_at: None,
        })
}

#[cfg(unix)]
fn file_identity(file: &File) -> Option<String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata().ok()?;
    Some(format!("{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn file_identity(file: &File) -> Option<String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
    };
    let mut info = FILE_ID_INFO::default();
    let succeeded = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle() as _,
            FileIdInfo,
            (&mut info as *mut FILE_ID_INFO).cast(),
            u32::try_from(std::mem::size_of::<FILE_ID_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if succeeded == 0 {
        return None;
    }
    let file_id = info
        .FileId
        .Identifier
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Some(format!("{}:{file_id}", info.VolumeSerialNumber))
}

#[cfg(not(any(unix, windows)))]
fn file_identity(_file: &File) -> Option<String> {
    None
}

#[cfg(test)]
#[test]
fn windows_file_identity_source_uses_stable_handle_api() {
    let source = include_str!("rollout.rs");
    assert!(source.contains("GetFileInformationByHandleEx"));
    assert!(source.contains("FileIdInfo"));
    assert!(source.contains("FILE_ID_INFO::default()"));
    assert!(!source.contains(&["std::os::windows::fs::", "MetadataExt"].concat()));
    assert!(!source.contains(&["volume_serial_", "number()"].concat()));
    assert!(!source.contains(&["file_", "index()"].concat()));
}

#[derive(Clone, Debug)]
struct FileSignature {
    exists: bool,
    regular: bool,
    identity: Option<String>,
    len: u64,
    modified_at: Option<SystemTime>,
}

impl FileSignature {
    fn is_same_as(&self, other: &Self) -> bool {
        if !self.exists || !other.exists {
            return self.exists == other.exists;
        }
        self.regular == other.regular
            && self.len == other.len
            && self.modified_at == other.modified_at
            && matches!(
                (&self.identity, &other.identity),
                (Some(left), Some(right)) if left == right
            )
    }
}

#[cfg(test)]
#[test]
fn file_signatures_fail_closed_when_identity_is_unavailable() {
    let path = std::env::temp_dir().join(format!(
        "codex-token-bar-rollout-signature-{}",
        std::process::id()
    ));
    fs::write(&path, b"stable metadata").unwrap();

    let unavailable_a = file_signature_with_identity(&path, |_| None);
    let unavailable_b = file_signature_with_identity(&path, |_| None);
    assert!(!unavailable_a.is_same_as(&unavailable_b));

    let known_a = file_signature_with_identity(&path, |_| Some("volume:file".into()));
    let known_b = file_signature_with_identity(&path, |_| Some("volume:file".into()));
    assert!(known_a.is_same_as(&known_b));

    let missing = path.with_extension("missing");
    let absent_a = file_signature_with_identity(&missing, |_| None);
    let absent_b = file_signature_with_identity(&missing, |_| None);
    assert!(absent_a.is_same_as(&absent_b));

    fs::remove_file(path).unwrap();
}
