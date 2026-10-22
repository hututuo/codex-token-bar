//! Temporary, read-only reminder for unusually low cache-hit requests.
//!
//! This module owns the reminder's parsing, observation state, and expiry. The
//! rollout reader only forwards observations and resets the tracker when its
//! source file changes. Set `CACHE_MISS_REMINDER_ENABLED` to `false` to disable
//! the Rust-to-UI adapter without touching usage accounting or rate samples.

use crate::models::{CacheAdvice, LiveRateSnapshot};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

pub(super) const CACHE_MISS_REMINDER_ENABLED: bool = true;

const FRESHNESS_SECONDS: f64 = 120.0;
const LOW_INPUT_TOKENS: u64 = 20_000;
const LOW_HIT_RATE: f64 = 0.3;
const THREAD_LIMIT: usize = 64;
const REQUEST_ID_LIMIT: usize = 128;

#[derive(Clone, Debug)]
pub(super) struct CacheUsageSample {
    timestamp: Option<f64>,
    input_tokens: Option<u64>,
    cached_input_tokens: Option<u64>,
    total_tokens: Option<u64>,
    request_total_tokens: Option<u64>,
    request_id: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) enum CacheObservation {
    Sample(CacheUsageSample),
    Context { model: Option<String> },
    ContextReset,
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
        while self.order.len() > REQUEST_ID_LIMIT {
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
    has_observed_request: bool,
    awaiting_first_after_context_reset: bool,
}

impl Default for CacheAdviceThreadState {
    fn default() -> Self {
        Self {
            model: None,
            total_watermark: None,
            request_ids: RecentRequestIds::default(),
            advice: None,
            touched_at: Instant::now(),
            has_observed_request: false,
            awaiting_first_after_context_reset: false,
        }
    }
}

#[derive(Default)]
pub(super) struct CacheReminderTracker {
    threads: HashMap<String, CacheAdviceThreadState>,
    last_poll: Option<Instant>,
    not_before: f64,
}

impl CacheReminderTracker {
    pub(super) fn begin_poll(&mut self, now: f64, monotonic: Instant) {
        if self
            .last_poll
            .is_some_and(|last| monotonic.duration_since(last) > Duration::from_secs(5))
        {
            for state in self.threads.values_mut() {
                state.advice = None;
            }
            self.not_before = now;
        }
        self.last_poll = Some(monotonic);
    }

    pub(super) fn observe(
        &mut self,
        thread_id: &str,
        observation: CacheObservation,
        now: f64,
        monotonic_now: Instant,
    ) {
        if matches!(&observation, CacheObservation::Sample(sample) if sample.timestamp.is_some_and(|at| at < self.not_before))
        {
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
                    let has_observed_request = state.has_observed_request;
                    let awaiting_first_after_context_reset =
                        state.awaiting_first_after_context_reset;
                    *state = CacheAdviceThreadState {
                        model,
                        touched_at: monotonic_now,
                        has_observed_request,
                        awaiting_first_after_context_reset,
                        ..CacheAdviceThreadState::default()
                    };
                }
            }
            CacheObservation::ContextReset => {
                let model = state.model.clone();
                *state = CacheAdviceThreadState {
                    model,
                    touched_at: monotonic_now,
                    awaiting_first_after_context_reset: true,
                    ..CacheAdviceThreadState::default()
                };
            }
            CacheObservation::Sample(sample) => {
                state.consume_sample(sample, thread_id, now);
            }
            CacheObservation::Reset => unreachable!(),
        }
        self.evict_oldest_if_needed();
    }

    pub(super) fn reset_thread(&mut self, thread_id: &str) {
        self.threads.remove(thread_id);
    }

    pub(super) fn retain_threads(&mut self, valid_thread_ids: &HashSet<String>) {
        self.threads
            .retain(|thread_id, _| valid_thread_ids.contains(thread_id));
    }

    pub(super) fn latest(&self, now: f64) -> Option<CacheAdvice> {
        let fresh = self
            .threads
            .values()
            .filter_map(|state| state.advice.as_ref())
            .filter(|advice| is_fresh(advice, now))
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

    fn evict_oldest_if_needed(&mut self) {
        while self.threads.len() > THREAD_LIMIT {
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
}

impl CacheAdviceThreadState {
    fn clear_observation(&mut self) {
        self.advice = None;
    }

    fn consume_sample(&mut self, sample: CacheUsageSample, thread_id: &str, now: f64) {
        let Some(timestamp) = sample.timestamp.filter(|timestamp| {
            timestamp.is_finite()
                && *timestamp >= 0.0
                && *timestamp <= now + 1.0
                && now - *timestamp <= FRESHNESS_SECONDS
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
        if sample.request_id.as_ref().is_some_and(|_| !request_is_new) {
            return;
        }

        let total_regressed = sample
            .total_tokens
            .zip(self.total_watermark)
            .is_some_and(|(total, previous)| total < previous);
        if total_regressed {
            self.advice = None;
            self.total_watermark = sample.total_tokens;
            self.has_observed_request = true;
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

        // A cumulative counter above this request proves that this context had
        // earlier usage, unless an explicit reset made this its first request.
        let has_prior_request = sample
            .total_tokens
            .zip(sample.request_total_tokens)
            .is_some_and(|(cumulative, request_total)| {
                request_total >= input_tokens && cumulative > request_total
            });
        let context_reset_is_cold = self.awaiting_first_after_context_reset;
        let low = (self.has_observed_request || has_prior_request)
            && !context_reset_is_cold
            && input_tokens >= LOW_INPUT_TOKENS
            && hit_rate < LOW_HIT_RATE;
        self.has_observed_request = true;
        self.awaiting_first_after_context_reset = false;
        self.advice = Some(CacheAdvice {
            thread_id: thread_id.to_owned(),
            thread_title: None,
            hit_rate,
            low,
            timestamp,
            affected_threads: 0,
            model: self.model.clone(),
        });
    }
}

/// Extracts only the reminder signal from an already parsed rollout record.
pub(super) fn parse_observation(
    value: &Value,
    payload: &Map<String, Value>,
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
        return Some(CacheObservation::ContextReset);
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
        input_tokens: last
            .and_then(|usage| usage.get("input_tokens"))
            .and_then(Value::as_u64),
        cached_input_tokens: last
            .and_then(|usage| usage.get("cached_input_tokens"))
            .and_then(Value::as_u64),
        total_tokens: total
            .and_then(|usage| usage.get("total_tokens"))
            .and_then(Value::as_u64),
        request_total_tokens: last
            .and_then(|usage| usage.get("total_tokens"))
            .and_then(Value::as_u64),
        request_id,
    }))
}

pub(super) fn is_valid_history_sample(sample: &CacheUsageSample) -> bool {
    if !sample
        .timestamp
        .is_some_and(|timestamp| timestamp.is_finite() && timestamp >= 0.0)
    {
        return false;
    }
    let Some(input_tokens) = sample.input_tokens else {
        return false;
    };
    let Some(cached_input_tokens) = sample.cached_input_tokens else {
        return false;
    };
    input_tokens > 0 && cached_input_tokens <= input_tokens
}

fn is_fresh(advice: &CacheAdvice, now: f64) -> bool {
    advice.timestamp.is_finite()
        && advice.timestamp >= 0.0
        && now >= advice.timestamp
        && now - advice.timestamp <= FRESHNESS_SECONDS
}

pub(super) fn latest(tracker: Option<&CacheReminderTracker>, now: f64) -> Option<CacheAdvice> {
    CACHE_MISS_REMINDER_ENABLED
        .then(|| tracker.and_then(|tracker| tracker.latest(now)))
        .flatten()
}

pub(super) fn clear_snapshot_advice(snapshot: &mut LiveRateSnapshot, now: f64) {
    snapshot.cache_advice = visible_advice(
        snapshot.cache_advice.take(),
        now,
        CACHE_MISS_REMINDER_ENABLED,
    );
}

fn visible_advice(advice: Option<CacheAdvice>, now: f64, enabled: bool) -> Option<CacheAdvice> {
    if enabled {
        advice.filter(|advice| is_fresh(advice, now))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(
        at: f64,
        total: Option<u64>,
        input: Option<u64>,
        cached: Option<u64>,
    ) -> CacheObservation {
        CacheObservation::Sample(CacheUsageSample {
            timestamp: Some(at),
            input_tokens: input,
            cached_input_tokens: cached,
            total_tokens: total,
            request_total_tokens: None,
            request_id: None,
        })
    }

    fn sample_with_request_total(
        at: f64,
        total: Option<u64>,
        request_total: Option<u64>,
        input: Option<u64>,
        cached: Option<u64>,
    ) -> CacheObservation {
        CacheObservation::Sample(CacheUsageSample {
            timestamp: Some(at),
            input_tokens: input,
            cached_input_tokens: cached,
            total_tokens: total,
            request_total_tokens: request_total,
            request_id: None,
        })
    }

    #[test]
    fn shared_cross_platform_fixtures() {
        let fixtures: Value = serde_json::from_str(include_str!(
            "../../../../../fixtures/cache-usage-advice.json"
        ))
        .unwrap();
        let start = Instant::now();
        for fixture in fixtures.as_array().unwrap() {
            let mut tracker = CacheReminderTracker::default();
            for row in fixture["steps"].as_array().unwrap() {
                let at = row["at"].as_f64().unwrap();
                tracker.observe(
                    row["thread"].as_str().unwrap_or("a"),
                    CacheObservation::Sample(CacheUsageSample {
                        timestamp: Some(at),
                        input_tokens: row["input"].as_u64(),
                        cached_input_tokens: row["cached"].as_u64(),
                        total_tokens: row["total"].as_u64(),
                        request_total_tokens: row["requestTotal"].as_u64(),
                        request_id: None,
                    }),
                    at,
                    start + Duration::from_secs_f64(at),
                );
                assert_eq!(
                    tracker.latest(at).map(|advice| advice.low),
                    row["low"].as_bool(),
                    "{} at {}",
                    fixture["name"],
                    at
                );
            }
        }
    }

    #[test]
    fn restored_session_uses_cumulative_usage_without_replaying_history() {
        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();
        tracker.observe(
            "restored",
            sample_with_request_total(
                100.0,
                Some(29_374_965),
                Some(154_786),
                Some(153_566),
                Some(0),
            ),
            100.0,
            monotonic,
        );
        assert!(tracker.latest(100.0).unwrap().low);

        let mut fresh = CacheReminderTracker::default();
        fresh.observe(
            "new",
            sample_with_request_total(100.0, Some(154_786), Some(154_786), Some(153_566), Some(0)),
            100.0,
            monotonic,
        );
        assert!(!fresh.latest(100.0).unwrap().low);

        let mut unknown = CacheReminderTracker::default();
        unknown.observe(
            "unknown",
            sample_with_request_total(100.0, Some(29_374_965), None, Some(153_566), Some(0)),
            100.0,
            monotonic,
        );
        assert!(!unknown.latest(100.0).unwrap().low);

        let mut inconsistent = CacheReminderTracker::default();
        inconsistent.observe(
            "inconsistent",
            sample_with_request_total(
                100.0,
                Some(29_374_965),
                Some(153_000),
                Some(153_566),
                Some(0),
            ),
            100.0,
            monotonic,
        );
        assert!(!inconsistent.latest(100.0).unwrap().low);
    }

    #[test]
    fn one_low_request_after_baseline_is_enough_and_expires_after_two_minutes() {
        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();
        tracker.observe(
            "a",
            sample(100.0, Some(20_000), Some(20_000), Some(18_000)),
            100.0,
            monotonic,
        );
        assert!(!tracker.latest(100.0).unwrap().low);
        tracker.observe(
            "a",
            sample(101.0, Some(40_000), Some(20_000), Some(100)),
            101.0,
            monotonic,
        );
        let advice = tracker.latest(101.0).unwrap();
        assert!(advice.low);
        assert_eq!(tracker.latest(221.0001), None);
    }

    #[test]
    fn threshold_boundaries_invalid_values_and_missing_cache_stay_non_alerting() {
        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();
        tracker.observe(
            "a",
            sample(100.0, Some(20_000), Some(20_000), Some(10_000)),
            100.0,
            monotonic,
        );
        tracker.observe(
            "a",
            sample(101.0, Some(40_000), Some(19_999), Some(0)),
            101.0,
            monotonic,
        );
        assert!(!tracker.latest(101.0).unwrap().low);
        tracker.observe(
            "a",
            sample(102.0, Some(60_000), Some(20_000), Some(6_000)),
            102.0,
            monotonic,
        );
        assert!(
            !tracker.latest(102.0).unwrap().low,
            "exactly 30% is not low"
        );
        tracker.observe(
            "a",
            sample(103.0, Some(80_000), Some(20_000), None),
            103.0,
            monotonic,
        );
        assert!(
            tracker.latest(103.0).is_none(),
            "unknown cache usage clears the observation"
        );
        tracker.observe(
            "a",
            sample(103.5, Some(90_000), Some(20_000), Some(20_001)),
            103.5,
            monotonic,
        );
        assert!(
            tracker.latest(103.5).is_none(),
            "cached tokens above input are invalid"
        );
        tracker.observe(
            "a",
            sample(104.0, Some(100_000), Some(20_000), Some(0)),
            104.0,
            monotonic,
        );
        assert!(tracker.latest(104.0).unwrap().low);
    }

    #[test]
    fn duplicate_requests_and_counter_regressions_do_not_reuse_old_advice() {
        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();
        let with_id = |at, total, id: &str| {
            CacheObservation::Sample(CacheUsageSample {
                timestamp: Some(at),
                input_tokens: Some(20_000),
                cached_input_tokens: Some(0),
                total_tokens: Some(total),
                request_total_tokens: None,
                request_id: Some(id.into()),
            })
        };
        tracker.observe("a", with_id(100.0, 20_000, "r1"), 100.0, monotonic);
        tracker.observe("a", with_id(101.0, 40_000, "r2"), 101.0, monotonic);
        assert!(tracker.latest(101.0).unwrap().low);
        tracker.observe("a", with_id(102.0, 60_000, "r2"), 102.0, monotonic);
        assert_eq!(tracker.latest(102.0).unwrap().timestamp, 101.0);
        tracker.observe("a", with_id(103.0, 10_000, "r3"), 103.0, monotonic);
        assert!(tracker.latest(103.0).is_none());
    }

    #[test]
    fn context_change_preserves_baseline_and_explicit_context_reset_is_cold() {
        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();
        tracker.observe(
            "a",
            sample(100.0, Some(20_000), Some(20_000), Some(0)),
            100.0,
            monotonic,
        );
        tracker.observe(
            "a",
            sample(101.0, Some(40_000), Some(20_000), Some(0)),
            101.0,
            monotonic,
        );
        assert!(tracker.latest(101.0).unwrap().low);
        tracker.observe(
            "a",
            CacheObservation::Context {
                model: Some("model-b".into()),
            },
            102.0,
            monotonic,
        );
        tracker.observe(
            "a",
            sample(103.0, Some(20_000), Some(20_000), Some(0)),
            103.0,
            monotonic,
        );
        assert!(tracker.latest(103.0).unwrap().low);
        tracker.observe("a", CacheObservation::ContextReset, 104.0, monotonic);
        tracker.observe(
            "a",
            CacheObservation::Context {
                model: Some("model-b".into()),
            },
            104.5,
            monotonic,
        );
        tracker.observe(
            "a",
            sample_with_request_total(105.0, Some(60_000), Some(20_000), Some(20_000), Some(0)),
            105.0,
            monotonic,
        );
        assert!(!tracker.latest(105.0).unwrap().low);

        tracker.observe(
            "a",
            sample_with_request_total(106.0, Some(80_000), Some(20_000), Some(20_000), Some(0)),
            106.0,
            monotonic,
        );
        assert!(tracker.latest(106.0).unwrap().low);

        tracker.observe("a", CacheObservation::Reset, 107.0, monotonic);
        tracker.observe(
            "a",
            sample_with_request_total(108.0, Some(100_000), Some(20_000), Some(20_000), Some(0)),
            108.0,
            monotonic,
        );
        assert!(
            tracker.latest(108.0).unwrap().low,
            "a structural reset must not claim a new context"
        );
    }

    #[test]
    fn reasoning_effort_change_keeps_same_model_baseline_and_uses_observed_tokens() {
        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();

        let initial_context = serde_json::json!({
            "type": "turn_context",
            "payload": { "model": "model-a", "effort": "high" }
        });
        let payload = initial_context["payload"].as_object().unwrap();
        let observation =
            parse_observation(&initial_context, payload, "turn_context", "", Some(99.0)).unwrap();
        tracker.observe("a", observation, 99.0, monotonic);
        tracker.observe(
            "a",
            sample(100.0, Some(20_000), Some(20_000), Some(19_000)),
            100.0,
            monotonic,
        );
        assert!(!tracker.latest(100.0).unwrap().low);

        let changed_effort_context = serde_json::json!({
            "type": "turn_context",
            "payload": {
                "model": "model-a",
                "effort": "minimal",
                "reasoning_effort": "low"
            }
        });
        let payload = changed_effort_context["payload"].as_object().unwrap();
        let observation = parse_observation(
            &changed_effort_context,
            payload,
            "turn_context",
            "",
            Some(101.0),
        )
        .unwrap();
        assert!(matches!(
            &observation,
            CacheObservation::Context { model: Some(model) } if model == "model-a"
        ));
        tracker.observe("a", observation, 101.0, monotonic);

        let token_count = serde_json::json!({
            "timestamp": "1970-01-01T00:01:42Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "response_id": "r2",
                "info": {
                    "last_token_usage": { "input_tokens": 20_000, "cached_input_tokens": 0 },
                    "total_token_usage": { "total_tokens": 40_000 }
                }
            }
        });
        let payload = token_count["payload"].as_object().unwrap();
        let observation = parse_observation(
            &token_count,
            payload,
            "event_msg",
            "token_count",
            Some(102.0),
        )
        .unwrap();
        tracker.observe("a", observation, 102.0, monotonic);

        let advice = tracker.latest(102.0).unwrap();
        assert!(advice.low);
        assert_eq!(advice.hit_rate, 0.0);
        assert_eq!(advice.model.as_deref(), Some("model-a"));
    }

    #[test]
    fn freshest_low_advice_wins_and_affected_threads_counts_only_low_samples() {
        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();
        for thread in ["a", "b"] {
            tracker.observe(
                thread,
                sample(100.0, Some(20_000), Some(20_000), Some(0)),
                100.0,
                monotonic,
            );
            tracker.observe(
                thread,
                sample(101.0, Some(40_000), Some(20_000), Some(0)),
                101.0,
                monotonic,
            );
        }
        tracker.observe(
            "healthy",
            sample(102.0, Some(20_000), Some(20_000), Some(19_000)),
            102.0,
            monotonic,
        );
        let advice = tracker.latest(102.0).unwrap();
        assert!(advice.low);
        assert_eq!(advice.affected_threads, 2);
        assert_eq!(advice.timestamp, 101.0);
        assert!(tracker.latest(223.0).is_none());
    }

    #[test]
    fn long_poll_pause_drops_stale_advice_and_preserves_context_evidence() {
        let mut tracker = CacheReminderTracker::default();
        let start = Instant::now();
        tracker.begin_poll(100.0, start);
        tracker.observe(
            "a",
            sample(100.0, Some(20_000), Some(20_000), Some(1)),
            100.0,
            start,
        );
        tracker.observe(
            "a",
            sample(101.0, Some(40_000), Some(20_000), Some(1)),
            101.0,
            start,
        );
        assert!(tracker.latest(101.0).unwrap().low);
        tracker.begin_poll(110.0, start + Duration::from_secs(10));
        assert!(tracker.latest(110.0).is_none());
        tracker.observe(
            "a",
            sample(110.0, Some(60_000), Some(20_000), Some(1)),
            110.0,
            start + Duration::from_secs(10),
        );
        assert!(tracker.latest(110.0).unwrap().low);
        tracker.observe(
            "b",
            sample(110.0, Some(20_000), Some(20_000), Some(20_000)),
            110.0,
            start + Duration::from_secs(10),
        );
        tracker.reset_thread("a");
        assert!(tracker.latest(110.0).is_some());
    }

    #[test]
    fn long_poll_pause_preserves_pending_context_reset_until_first_valid_sample() {
        let mut tracker = CacheReminderTracker::default();
        let start = Instant::now();
        tracker.observe("a", CacheObservation::ContextReset, 100.0, start);
        tracker.begin_poll(110.0, start + Duration::from_secs(10));
        tracker.observe(
            "a",
            sample_with_request_total(110.0, Some(60_000), Some(20_000), Some(20_000), Some(0)),
            110.0,
            start + Duration::from_secs(10),
        );
        assert!(!tracker.latest(110.0).unwrap().low);
    }

    #[test]
    fn parser_reads_token_usage_and_ignores_task_lifecycle_records() {
        let line: Value = serde_json::from_str(r#"{"timestamp":"1970-01-01T00:01:40Z","type":"event_msg","payload":{"type":"token_count","response_id":"r1","info":{"last_token_usage":{"input_tokens":20000,"cached_input_tokens":0,"total_tokens":20000},"total_token_usage":{"total_tokens":40000}}}}"#).unwrap();
        let payload = line["payload"].as_object().unwrap();
        let observation =
            parse_observation(&line, payload, "event_msg", "token_count", Some(100.0)).unwrap();
        assert!(
            matches!(observation, CacheObservation::Sample(sample) if sample.input_tokens == Some(20_000) && sample.cached_input_tokens == Some(0) && sample.total_tokens == Some(40_000) && sample.request_total_tokens == Some(20_000) && sample.request_id.as_deref() == Some("r1"))
        );

        for (record_type, payload_type) in [
            ("compacted", "compacted"),
            ("event_msg", "context_compacted"),
            ("event_msg", "thread_rolled_back"),
        ] {
            let reset = serde_json::json!({
                "timestamp": "1970-01-01T00:01:40Z",
                "type": record_type,
                "payload": { "type": payload_type }
            });
            let payload = reset["payload"].as_object().unwrap();
            assert!(matches!(
                parse_observation(&reset, payload, record_type, payload_type, Some(100.0)),
                Some(CacheObservation::ContextReset)
            ));
        }

        for payload_type in ["task_started", "task_complete"] {
            let lifecycle = serde_json::json!({
                "timestamp": "1970-01-01T00:01:40Z",
                "type": "event_msg",
                "payload": {
                    "type": payload_type,
                    "started_at": "1970-01-01T00:01:30Z",
                    "completed_at": "1970-01-01T00:01:35Z",
                    "turn_id": "t"
                }
            });
            let payload = lifecycle["payload"].as_object().unwrap();
            assert!(
                parse_observation(&lifecycle, payload, "event_msg", payload_type, Some(100.0))
                    .is_none(),
                "{payload_type} must not feed reminder timing"
            );
        }
    }

    #[test]
    fn parser_keeps_invalid_numeric_fields_unknown() {
        for input in [
            Value::Bool(true),
            serde_json::json!(-1),
            serde_json::json!(2.5),
            Value::Null,
            serde_json::json!("20000"),
        ] {
            let mut value = serde_json::json!({
                "timestamp": "1970-01-01T00:01:40Z",
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "last_token_usage": {
                            "input_tokens": 20000,
                            "cached_input_tokens": 0
                        }
                    }
                }
            });
            value["payload"]["info"]["last_token_usage"]["input_tokens"] = input;
            let payload = value["payload"].as_object().unwrap();
            let observation =
                parse_observation(&value, payload, "event_msg", "token_count", Some(100.0))
                    .unwrap();
            assert!(
                matches!(observation, CacheObservation::Sample(sample) if sample.input_tokens.is_none())
            );
        }
    }

    #[test]
    fn snapshot_adapter_obeys_switch_and_expiration_boundary() {
        let advice = CacheAdvice {
            thread_id: "thread".into(),
            thread_title: None,
            hit_rate: 0.0,
            low: true,
            timestamp: 100.0,
            affected_threads: 1,
            model: None,
        };
        assert!(visible_advice(Some(advice.clone()), 220.0, true).is_some());
        assert!(visible_advice(Some(advice.clone()), 220.0001, true).is_none());
        assert!(visible_advice(Some(advice), 100.0, false).is_none());

        let mut tracker = CacheReminderTracker::default();
        let monotonic = Instant::now();
        tracker.observe(
            "thread",
            sample(100.0, Some(20_000), Some(20_000), Some(0)),
            100.0,
            monotonic,
        );
        tracker.observe(
            "thread",
            sample(101.0, Some(40_000), Some(20_000), Some(0)),
            101.0,
            monotonic,
        );
        assert_eq!(
            latest(Some(&tracker), 101.0).is_some(),
            CACHE_MISS_REMINDER_ENABLED
        );
    }
}
