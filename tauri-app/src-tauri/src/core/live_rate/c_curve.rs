use super::LiveRateSourceScope;
use crate::models::{CurvePoint, ModelRate};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::{Mutex, OnceLock};

const FALLBACK_BASELINE_TPS: f64 = 40.0;
const MAX_POINTS: usize = 80;
const NO_FRESH_QUANTITY_SECONDS: f64 = 20.0;
const MAX_UNRESOLVED_MODEL_THREADS: usize = 8;
const FILTER_WEIGHTS: [f64; 5] = [1.0, 2.0, 3.0, 2.0, 1.0];

static CURVES: OnceLock<Mutex<HashMap<LiveRateSourceScope, HashMap<String, ThreadCurve>>>> =
    OnceLock::new();

#[derive(Clone, Debug)]
pub(super) enum RolloutSignal {
    Context {
        thread_id: String,
        turn_id: Option<String>,
        model: Option<String>,
        at: f64,
    },
    TurnStarted {
        thread_id: String,
        turn_id: Option<String>,
        at: f64,
    },
    ReasoningCompleted {
        thread_id: String,
        turn_id: Option<String>,
        item_id: String,
        duration_seconds: f64,
        at: f64,
    },
    ItemCompleted {
        thread_id: String,
        turn_id: Option<String>,
        item_id: String,
        at: f64,
    },
    UsageSettled {
        thread_id: String,
        turn_id: Option<String>,
        output_tokens: u64,
        reasoning_tokens: u64,
        at: f64,
    },
    TurnCompleted {
        thread_id: String,
        turn_id: Option<String>,
        failed: bool,
        at: f64,
    },
}

#[derive(Clone)]
struct ThreadCurve {
    turn_id: Option<String>,
    model: Option<String>,
    started_at: Option<f64>,
    baseline_by_model: HashMap<String, VecDeque<f64>>,
    curve: Curve,
}

impl Default for ThreadCurve {
    fn default() -> Self {
        Self {
            turn_id: None,
            model: None,
            started_at: None,
            baseline_by_model: HashMap::new(),
            curve: Curve::default(),
        }
    }
}

#[derive(Clone)]
struct Curve {
    baseline_samples: VecDeque<f64>,
    budget: f64,
    moment: f64,
    debt: f64,
    rate: f64,
    pending_provisional: f64,
    pending_reasoning_duration: f64,
    last_quantity_at: Option<f64>,
    last_settlement_at: Option<f64>,
    last_tick: Option<f64>,
    completed_at: Option<f64>,
    stopped: bool,
    paused: bool,
    queue: VecDeque<f64>,
    display: f64,
    points: VecDeque<CurvePoint>,
    seen_reasoning_items: HashSet<String>,
    seen_usage_records: HashSet<String>,
}

impl Default for Curve {
    fn default() -> Self {
        Self {
            baseline_samples: VecDeque::new(),
            budget: 0.0,
            moment: 0.0,
            debt: 0.0,
            rate: 0.0,
            pending_provisional: 0.0,
            pending_reasoning_duration: 0.0,
            last_quantity_at: None,
            last_settlement_at: None,
            last_tick: None,
            completed_at: None,
            stopped: false,
            paused: false,
            queue: VecDeque::from([0.0; 5]),
            display: 0.0,
            points: VecDeque::new(),
            seen_reasoning_items: HashSet::new(),
            seen_usage_records: HashSet::new(),
        }
    }
}

impl Curve {
    fn baseline(&self) -> f64 {
        if self.baseline_samples.is_empty() {
            return FALLBACK_BASELINE_TPS;
        }
        let mut values = self.baseline_samples.iter().copied().collect::<Vec<_>>();
        values.sort_by(f64::total_cmp);
        let middle = values.len() / 2;
        if values.len() % 2 == 0 {
            (values[middle - 1] + values[middle]) / 2.0
        } else {
            values[middle]
        }
    }

    fn add_signed(&mut self, quantity: f64, horizon: f64) {
        if quantity <= 0.0 {
            let mut remaining = -quantity;
            let from_budget = self.budget.min(remaining);
            if self.budget > 0.0 && from_budget > 0.0 {
                let fraction = (self.budget - from_budget) / self.budget;
                self.moment *= fraction;
                self.budget -= from_budget;
                remaining -= from_budget;
            }
            self.debt += remaining;
            return;
        }
        let paid = quantity.min(self.debt);
        self.debt -= paid;
        let remainder = quantity - paid;
        if remainder > 0.0 {
            self.budget += remainder;
            self.moment += remainder * horizon.max(1.0);
        }
    }

    fn reasoning_completed(&mut self, duration: f64, at: f64) {
        if !duration.is_finite()
            || self
                .last_quantity_at
                .is_some_and(|last_quantity| at < last_quantity)
        {
            return;
        }
        self.advance(at);
        if self.stopped || self.completed_at.is_some() {
            return;
        }
        self.paused = false;
        let duration = duration.clamp(0.0, 3_600.0);
        let horizon = duration.max(1.0);
        let provisional = self.baseline() * duration;
        if provisional > 0.0 {
            self.add_signed(provisional, horizon);
            self.pending_provisional += provisional;
        }
        self.pending_reasoning_duration += duration.max(0.0);
        self.last_quantity_at = Some(at);
    }

    fn observed_output(&mut self, tokens: u32, at: f64) {
        if self
            .last_quantity_at
            .is_some_and(|last_quantity| at < last_quantity)
        {
            return;
        }
        self.advance(at);
        if self.stopped || self.completed_at.is_some() || tokens == 0 {
            return;
        }
        self.paused = false;
        let quantity = f64::from(tokens);
        self.add_signed(quantity, 1.0);
        self.pending_provisional += quantity;
        self.last_quantity_at = Some(at);
    }

    fn settle(&mut self, output_tokens: u64, reasoning_tokens: u64, at: f64) {
        if self
            .last_quantity_at
            .is_some_and(|last_quantity| at < last_quantity)
        {
            return;
        }
        self.advance(at);
        if self.stopped || self.paused || self.completed_at.is_some() {
            return;
        }
        let correction = output_tokens as f64 - self.pending_provisional;
        let gap = self
            .last_settlement_at
            .map(|previous| (at - previous).max(0.0))
            .unwrap_or(self.pending_reasoning_duration)
            .max(1.0);
        self.add_signed(correction, gap);
        if self.pending_reasoning_duration >= 1.0 && reasoning_tokens > 0 {
            self.baseline_samples
                .push_back(reasoning_tokens as f64 / self.pending_reasoning_duration);
            while self.baseline_samples.len() > 5 {
                self.baseline_samples.pop_front();
            }
        }
        self.pending_provisional = 0.0;
        self.pending_reasoning_duration = 0.0;
        self.last_settlement_at = Some(at);
        self.last_quantity_at = Some(at);
    }

    fn complete(&mut self, at: f64, failed: bool) {
        if self.completed_at.is_some()
            || self
                .last_quantity_at
                .is_some_and(|last_quantity| at < last_quantity)
        {
            return;
        }
        self.advance(at);
        if failed {
            self.clear_quantity();
            self.points.clear();
            self.stopped = true;
            self.paused = false;
            self.completed_at = Some(at);
            return;
        }
        self.completed_at = Some(at);
        self.advance(at);
    }

    fn clear_quantity(&mut self) {
        self.budget = 0.0;
        self.moment = 0.0;
        self.debt = 0.0;
        self.rate = 0.0;
        self.pending_provisional = 0.0;
        self.pending_reasoning_duration = 0.0;
        self.last_quantity_at = None;
        self.queue = VecDeque::from([0.0; 5]);
        self.display = 0.0;
    }

    fn advance(&mut self, now: f64) -> f64 {
        if !now.is_finite() {
            return 0.0;
        }
        if let Some(completed_at) = self.completed_at {
            let age = (now - completed_at).max(0.0);
            if age >= 5.0 {
                self.clear_quantity();
                self.points.clear();
                return 0.0;
            }
        }
        if self
            .last_quantity_at
            .is_some_and(|last| now - last >= NO_FRESH_QUANTITY_SECONDS)
        {
            self.clear_quantity();
            self.points.clear();
            self.last_tick = Some(now.floor());
            return 0.0;
        }
        if self.stopped || self.paused {
            self.clear_quantity();
            self.last_tick = Some(now.floor());
            return 0.0;
        }
        let Some(mut tick) = self.last_tick else {
            self.last_tick = Some(now.floor());
            return self.display;
        };
        while tick + 1.0 <= now {
            tick += 1.0;
            let target = if self.budget > 0.0 && self.moment > 0.0 {
                self.budget / (self.moment / self.budget).max(1.0)
            } else {
                0.0
            };
            let alpha: f64 = if target >= self.rate { 0.28 } else { 0.18 };
            self.rate += (target - self.rate) * alpha;
            let consumed = self.budget.min(self.rate.max(0.0));
            if consumed > 0.0 && self.budget > 0.0 {
                let remaining_fraction = (self.budget - consumed) / self.budget;
                self.budget -= consumed;
                self.moment *= remaining_fraction;
            }
            for (index, weight) in FILTER_WEIGHTS.iter().enumerate() {
                if let Some(slot) = self.queue.get_mut(index) {
                    *slot += consumed * weight / 9.0;
                }
            }
            self.display = self.queue.pop_front().unwrap_or_default();
            self.queue.push_back(0.0);
            if let Some(done) = self.completed_at {
                let age = tick - done;
                if age > 3.0 {
                    let x = ((done + 5.0 - tick) / 2.0).clamp(0.0, 1.0);
                    self.display *= x * x * (3.0 - 2.0 * x);
                }
            }
            if self.display > 0.0 || self.budget > 0.0 {
                self.points.push_back(CurvePoint {
                    timestamp: tick,
                    tokens_per_second: self.display,
                    remaining_budget: self.budget,
                    thread_id: String::new(),
                    turn_id: String::new(),
                    model: None,
                    status: if self.completed_at.is_some() {
                        "completed"
                    } else {
                        "provisional"
                    }
                    .into(),
                });
                while self.points.len() > MAX_POINTS {
                    self.points.pop_front();
                }
            }
        }
        self.last_tick = Some(tick);
        self.display
    }
}

pub(super) fn apply_signals(scope: &LiveRateSourceScope, signals: &[RolloutSignal], now: f64) {
    let mut all = CURVES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let threads = all.entry(scope.clone()).or_default();
    for signal in signals {
        let at = signal_timestamp(signal);
        if !at.is_finite() || at < now - NO_FRESH_QUANTITY_SECONDS || at > now + 2.0 {
            continue;
        }
        let thread_id = match signal {
            RolloutSignal::Context { thread_id, .. }
            | RolloutSignal::TurnStarted { thread_id, .. }
            | RolloutSignal::ReasoningCompleted { thread_id, .. }
            | RolloutSignal::ItemCompleted { thread_id, .. }
            | RolloutSignal::UsageSettled { thread_id, .. }
            | RolloutSignal::TurnCompleted { thread_id, .. } => thread_id,
        };
        let thread = threads.entry(thread_id.clone()).or_default();
        let signal_turn_id = match signal {
            RolloutSignal::Context { turn_id, .. }
            | RolloutSignal::TurnStarted { turn_id, .. }
            | RolloutSignal::ReasoningCompleted { turn_id, .. }
            | RolloutSignal::ItemCompleted { turn_id, .. }
            | RolloutSignal::UsageSettled { turn_id, .. }
            | RolloutSignal::TurnCompleted { turn_id, .. } => turn_id.as_deref(),
        };
        if let Some(turn_id) = signal_turn_id.filter(|turn_id| !turn_id.is_empty()) {
            if thread.turn_id.as_deref() != Some(turn_id) {
                let is_start = matches!(signal, RolloutSignal::TurnStarted { .. });
                let last_quantity = thread.curve.last_quantity_at.unwrap_or(0.0);
                if !is_start && at < last_quantity {
                    continue;
                }
                // A new turn must not inherit the previous turn's model when
                // its Context signal is missing or arrives later.
                let model = match signal {
                    RolloutSignal::Context { model, .. } => model.clone(),
                    _ => None,
                };
                reset_turn(thread, turn_id.to_owned(), model);
            }
        }
        thread.curve.advance(at);
        match signal {
            RolloutSignal::Context { model, at, .. } => {
                if thread.started_at.is_none() {
                    thread.started_at = Some(*at);
                }
                if let Some(model) = model.as_ref().filter(|value| !value.is_empty()) {
                    if thread.model.as_ref() != Some(model) {
                        thread.model = Some(model.clone());
                        thread.curve.baseline_samples = thread
                            .baseline_by_model
                            .get(model)
                            .cloned()
                            .unwrap_or_default();
                    }
                }
            }
            RolloutSignal::TurnStarted { at, .. } => {
                thread.started_at = Some(*at);
            }
            RolloutSignal::ReasoningCompleted {
                turn_id,
                item_id,
                duration_seconds,
                at,
                ..
            } => {
                if turn_matches(thread, turn_id.as_deref())
                    && thread.curve.seen_reasoning_items.insert(item_id.clone())
                {
                    thread.curve.reasoning_completed(*duration_seconds, *at);
                }
            }
            RolloutSignal::ItemCompleted { .. } => {}
            RolloutSignal::UsageSettled {
                turn_id,
                output_tokens,
                reasoning_tokens,
                at,
                ..
            } => {
                let fingerprint = format!("{at:.6}:{output_tokens}:{reasoning_tokens}");
                if turn_matches(thread, turn_id.as_deref())
                    && thread.curve.seen_usage_records.insert(fingerprint)
                {
                    thread.curve.settle(*output_tokens, *reasoning_tokens, *at);
                    if let Some(model) = thread.model.as_ref() {
                        thread
                            .baseline_by_model
                            .insert(model.clone(), thread.curve.baseline_samples.clone());
                    }
                }
            }
            RolloutSignal::TurnCompleted {
                turn_id,
                failed,
                at,
                ..
            } => {
                if turn_matches(thread, turn_id.as_deref()) {
                    thread.curve.complete(*at, *failed);
                }
            }
        }
    }
    for thread in threads.values_mut() {
        thread.curve.advance(now);
    }
}

fn turn_matches(thread: &ThreadCurve, turn_id: Option<&str>) -> bool {
    thread
        .turn_id
        .as_deref()
        .is_some_and(|current| Some(current) == turn_id)
}

fn unresolved_model(model: Option<&str>) -> bool {
    model.is_none_or(|model| model.is_empty() || model == "unknown")
}

fn active_curve_at(thread: &ThreadCurve, now: f64) -> bool {
    let curve = &thread.curve;
    let within_completion_tail = curve
        .completed_at
        .is_none_or(|completed_at| now - completed_at < 5.0);
    !curve.stopped
        && !curve.paused
        && within_completion_tail
        && (curve.display > 0.0
            || curve.budget > 0.0
            || curve
                .queue
                .iter()
                .any(|rate| rate.is_finite() && *rate > 0.0))
        && curve.last_quantity_at.is_some_and(|last_quantity| {
            last_quantity.is_finite()
                && now.is_finite()
                && last_quantity <= now + 2.0
                && now - last_quantity < NO_FRESH_QUANTITY_SECONDS
        })
}

/// Returns bounded exact `(thread, turn)` requests for active curves whose
/// model is unresolved. Curves are sorted by thread ID so lookup priority is
/// stable across polls.
pub(super) fn unresolved_model_requests(
    scope: &LiveRateSourceScope,
    now: f64,
) -> Vec<(String, Vec<String>)> {
    let all = CURVES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(threads) = all.get(scope) else {
        return Vec::new();
    };
    let mut requests = threads
        .iter()
        .filter_map(|(thread_id, state)| {
            let turn_id = state.turn_id.as_deref()?;
            (!thread_id.is_empty()
                && !turn_id.is_empty()
                && turn_id.len() <= 512
                && unresolved_model(state.model.as_deref())
                && active_curve_at(state, now))
            .then(|| (thread_id.clone(), vec![turn_id.to_owned()]))
        })
        .collect::<Vec<_>>();
    requests.sort_by(|left, right| left.0.cmp(&right.0));
    requests.truncate(MAX_UNRESOLVED_MODEL_THREADS);
    requests
}

/// Applies resolved model metadata to the exact current turn only.
/// No curve quantity, timing, lifecycle, or smoothing state is changed.
pub(super) fn resolve_models(
    scope: &LiveRateSourceScope,
    resolved: &HashMap<String, HashMap<String, String>>,
    now: f64,
) -> bool {
    if resolved.is_empty() || !now.is_finite() {
        return false;
    }
    let mut all = CURVES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(threads) = all.get_mut(scope) else {
        return false;
    };
    let mut changed = false;
    for (thread_id, turns) in resolved {
        let Some(state) = threads.get_mut(thread_id) else {
            continue;
        };
        let Some(turn_id) = state.turn_id.as_deref() else {
            continue;
        };
        if !unresolved_model(state.model.as_deref()) || !active_curve_at(state, now) {
            continue;
        }
        let Some(model) = turns.get(turn_id).filter(|model| {
            !model.trim().is_empty() && !model.trim().eq_ignore_ascii_case("unknown")
        }) else {
            continue;
        };
        state.model = Some(model.clone());
        changed = true;
    }
    changed
}

fn reset_turn(thread: &mut ThreadCurve, turn_id: String, model: Option<String>) {
    let baseline_samples = model
        .as_ref()
        .and_then(|model| thread.baseline_by_model.get(model).cloned())
        .unwrap_or_default();
    thread.turn_id = Some(turn_id);
    thread.model = model;
    thread.started_at = None;
    thread.curve = Curve {
        baseline_samples,
        ..Curve::default()
    };
}

pub(super) fn snapshot(
    scope: &LiveRateSourceScope,
    now: f64,
    selected_thread_id: Option<&str>,
) -> (f64, f64, Vec<ModelRate>, Vec<CurvePoint>) {
    let mut all = CURVES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(threads) = all.get_mut(scope) else {
        return (0.0, 0.0, Vec::new(), Vec::new());
    };
    let mut rates_by_model = BTreeMap::<String, f64>::new();
    let mut selected = 0.0;
    let mut points = Vec::new();
    for (thread_id, state) in threads.iter_mut() {
        let rate = state.curve.advance(now);
        if rate.is_finite() && rate > 0.0 {
            let model = state
                .model
                .as_deref()
                .filter(|model| !model.is_empty())
                .unwrap_or("unknown");
            *rates_by_model.entry(model.to_owned()).or_default() += rate;
        }
        if selected_thread_id == Some(thread_id.as_str()) {
            selected = rate;
        }
        for point in &state.curve.points {
            let mut point = point.clone();
            point.thread_id.clone_from(thread_id);
            point.turn_id = state.turn_id.clone().unwrap_or_default();
            point.model = state.model.clone();
            point.status = if state.curve.completed_at.is_some() {
                "completed"
            } else {
                "provisional"
            }
            .into();
            if selected_thread_id.is_none() || selected_thread_id == Some(thread_id.as_str()) {
                points.push(point);
            }
        }
    }
    points.sort_by(|left, right| left.timestamp.total_cmp(&right.timestamp));
    let model_rates = rates_by_model
        .into_iter()
        .map(|(model, tokens_per_second)| ModelRate {
            model,
            tokens_per_second,
        })
        .collect::<Vec<_>>();
    let total = model_rates.iter().map(|rate| rate.tokens_per_second).sum();
    (total, selected, model_rates, points)
}

pub(super) fn current_context(
    scope: &LiveRateSourceScope,
    thread_id: &str,
) -> Option<(String, Option<String>, f64)> {
    let all = CURVES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let thread = all.get(scope)?.get(thread_id)?;
    Some((
        thread.turn_id.clone()?,
        thread.model.clone(),
        thread.started_at?,
    ))
}

pub(super) fn add_observed_output(
    scope: &LiveRateSourceScope,
    thread_id: &str,
    turn_id: &str,
    tokens: u32,
    at: f64,
) {
    if !at.is_finite() {
        return;
    }
    let mut all = CURVES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(thread) = all
        .get_mut(scope)
        .and_then(|threads| threads.get_mut(thread_id))
    else {
        return;
    };
    if thread.turn_id.as_deref() != Some(turn_id) || at < thread.started_at.unwrap_or(at) {
        return;
    }
    thread.curve.observed_output(tokens, at);
}

pub(super) fn pause_for_retry(
    scope: &LiveRateSourceScope,
    thread_id: &str,
    at: f64,
    now: f64,
) -> bool {
    if !at.is_finite() || at < now - NO_FRESH_QUANTITY_SECONDS || at > now + 1.0 {
        return false;
    }
    let mut all = CURVES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(thread) = all
        .get_mut(scope)
        .and_then(|threads| threads.get_mut(thread_id))
    else {
        return false;
    };
    if thread.started_at.is_none_or(|started_at| at < started_at)
        || thread
            .curve
            .last_quantity_at
            .is_none_or(|last_quantity| at < last_quantity)
        || thread.curve.stopped
        || thread.curve.completed_at.is_some()
    {
        return false;
    }
    thread.curve.advance(at);
    thread.curve.clear_quantity();
    thread.curve.paused = true;
    true
}

fn signal_timestamp(signal: &RolloutSignal) -> f64 {
    match signal {
        RolloutSignal::Context { at, .. }
        | RolloutSignal::TurnStarted { at, .. }
        | RolloutSignal::ReasoningCompleted { at, .. }
        | RolloutSignal::ItemCompleted { at, .. }
        | RolloutSignal::UsageSettled { at, .. }
        | RolloutSignal::TurnCompleted { at, .. } => *at,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add_active_test_turn(
        signals: &mut Vec<RolloutSignal>,
        thread_id: &str,
        model: Option<&str>,
        at: f64,
    ) {
        let turn_id = format!("{thread_id}-turn");
        signals.push(RolloutSignal::Context {
            thread_id: thread_id.into(),
            turn_id: Some(turn_id.clone()),
            model: model.map(ToOwned::to_owned),
            at,
        });
        signals.push(RolloutSignal::ReasoningCompleted {
            thread_id: thread_id.into(),
            turn_id: Some(turn_id),
            item_id: format!("{thread_id}-reasoning"),
            duration_seconds: 2.0,
            at: at + 0.5,
        });
    }

    fn usage_without_context(thread_id: &str, turn_id: &str, at: f64) -> RolloutSignal {
        RolloutSignal::UsageSettled {
            thread_id: thread_id.into(),
            turn_id: Some(turn_id.into()),
            output_tokens: 100,
            reasoning_tokens: 0,
            at,
        }
    }

    #[test]
    fn smoothed_curve_spends_budget_and_clears_after_completion() {
        let mut curve = Curve::default();
        curve.reasoning_completed(2.0, 10.0);
        curve.advance(11.0);
        assert!(curve.rate > 0.0);
        assert!(curve.budget < 80.0);
        curve.complete(11.0, false);
        assert!(curve.advance(14.0) > 0.0);
        assert_eq!(curve.advance(16.0), 0.0);
        assert_eq!(curve.budget, 0.0);
    }

    #[test]
    fn negative_settlement_consumes_pending_budget_then_debt() {
        let mut curve = Curve::default();
        curve.reasoning_completed(1.0, 10.0);
        curve.budget = 2.0;
        curve.moment = 2.0;
        curve.settle(5, 5, 10.5);
        assert_eq!(curve.budget, 0.0);
        assert!(curve.debt > 0.0);
        curve.add_signed(10.0, 1.0);
        assert!(curve.debt > 0.0);
        curve.add_signed(100.0, 1.0);
        assert_eq!(curve.debt, 0.0);
        assert!(curve.budget > 0.0);
    }

    #[test]
    fn baseline_is_median_of_last_five_valid_settlements() {
        let mut curve = Curve::default();
        for (duration, tokens) in [
            (1.0, 10),
            (2.0, 40),
            (1.0, 30),
            (2.0, 20),
            (1.0, 50),
            (1.0, 60),
        ] {
            curve.pending_reasoning_duration = duration;
            curve.pending_provisional = 0.0;
            curve.settle(tokens, tokens, 20.0);
        }
        assert_eq!(curve.baseline_samples.len(), 5);
        assert_eq!(curve.baseline(), 30.0);
    }

    #[test]
    fn zero_millisecond_reasoning_contributes_no_provisional_quantity() {
        let mut curve = Curve::default();
        curve.reasoning_completed(0.0, 10.0);
        assert_eq!(curve.budget, 0.0);
        assert_eq!(curve.pending_provisional, 0.0);
        assert_eq!(curve.last_quantity_at, Some(10.0));
    }

    #[test]
    fn one_second_budget_ticks_feed_the_five_bin_causal_filter_without_unbacked_rate() {
        let mut curve = Curve {
            last_tick: Some(10.0),
            budget: 9.0,
            moment: 9.0,
            rate: 9.0,
            ..Curve::default()
        };
        assert_eq!(curve.advance(11.0), 1.0);
        assert_eq!(curve.budget, 0.0);
        assert_eq!(
            curve.queue.iter().copied().collect::<Vec<_>>(),
            vec![2.0, 3.0, 2.0, 1.0, 0.0]
        );
        assert_eq!(curve.advance(12.0), 2.0);
        assert_eq!(curve.advance(13.0), 3.0);
        assert_eq!(curve.advance(14.0), 2.0);
        assert_eq!(curve.advance(15.0), 1.0);
        assert_eq!(curve.advance(16.0), 0.0);
    }

    #[test]
    fn retry_pause_clears_budget_late_usage_cannot_resume_and_new_output_can() {
        let mut curve = Curve::default();
        curve.reasoning_completed(2.0, 10.0);
        curve.advance(11.0);
        curve.clear_quantity();
        curve.paused = true;
        curve.settle(100, 100, 10.5);
        assert!(curve.paused);
        assert_eq!(curve.budget, 0.0);
        curve.observed_output(10, 11.0);
        assert!(!curve.paused);
        assert_eq!(curve.budget, 10.0);
    }

    #[test]
    fn completed_and_failed_turns_reject_late_settlement() {
        let mut failed = Curve::default();
        failed.reasoning_completed(1.0, 10.0);
        failed.complete(11.0, true);
        failed.settle(1_000, 1_000, 12.0);
        assert_eq!(failed.advance(12.0), 0.0);
        assert_eq!(failed.budget, 0.0);

        let mut completed = Curve::default();
        completed.reasoning_completed(1.0, 10.0);
        completed.complete(11.0, false);
        let display_after_tick = completed.advance(12.0);
        let budget_at_settlement = completed.budget;
        completed.settle(1_000, 1_000, 12.0);
        assert_eq!(completed.budget, budget_at_settlement);
        assert!(display_after_tick > 0.0);
    }

    #[test]
    fn baseline_history_is_partitioned_by_model_and_survives_turn_reset() {
        let scope = LiveRateSourceScope::new("c-curve-baseline-test", "c-curve-baseline-test");
        let signals = [
            RolloutSignal::Context {
                thread_id: "t".into(),
                turn_id: Some("turn-a".into()),
                model: Some("model-a".into()),
                at: 1.0,
            },
            RolloutSignal::ReasoningCompleted {
                thread_id: "t".into(),
                turn_id: Some("turn-a".into()),
                item_id: "reason-1".into(),
                duration_seconds: 1.0,
                at: 1.5,
            },
            RolloutSignal::UsageSettled {
                thread_id: "t".into(),
                turn_id: Some("turn-a".into()),
                output_tokens: 100,
                reasoning_tokens: 100,
                at: 2.0,
            },
            RolloutSignal::TurnStarted {
                thread_id: "t".into(),
                turn_id: Some("turn-b".into()),
                at: 3.0,
            },
        ];
        apply_signals(&scope, &signals, 3.0);
        let all = CURVES.get().unwrap().lock().unwrap();
        let thread = all.get(&scope).unwrap().get("t").unwrap();
        assert_eq!(thread.model, None);
        assert_eq!(thread.curve.baseline(), FALLBACK_BASELINE_TPS);
        drop(all);
        let resolved_model = [RolloutSignal::Context {
            thread_id: "t".into(),
            turn_id: Some("turn-b".into()),
            model: Some("model-a".into()),
            at: 3.5,
        }];
        apply_signals(&scope, &resolved_model, 3.5);
        let all = CURVES.get().unwrap().lock().unwrap();
        let thread = all.get(&scope).unwrap().get("t").unwrap();
        assert_eq!(thread.curve.baseline(), 100.0);
        drop(all);
        let new_model = [RolloutSignal::Context {
            thread_id: "t".into(),
            turn_id: Some("turn-c".into()),
            model: Some("model-b".into()),
            at: 4.0,
        }];
        apply_signals(&scope, &new_model, 4.0);
        let all = CURVES.get().unwrap().lock().unwrap();
        let thread = all.get(&scope).unwrap().get("t").unwrap();
        assert_eq!(thread.curve.baseline(), FALLBACK_BASELINE_TPS);
    }

    #[test]
    fn snapshot_aggregates_current_display_by_sorted_model_and_keeps_unknown_quantity() {
        let scope = LiveRateSourceScope::new(
            "c-curve-model-rates-aggregate-test",
            "c-curve-model-rates-aggregate-test",
        );
        let mut signals = Vec::new();
        add_active_test_turn(&mut signals, "thread-z-a", Some("model-z"), 10.0);
        add_active_test_turn(&mut signals, "thread-z-b", Some("model-z"), 10.0);
        add_active_test_turn(&mut signals, "thread-a", Some("model-a"), 10.0);
        add_active_test_turn(&mut signals, "thread-unknown", None, 10.0);
        apply_signals(&scope, &signals, 16.0);

        let (total, _, model_rates, _) = snapshot(&scope, 16.0, None);
        assert_eq!(
            model_rates
                .iter()
                .map(|rate| rate.model.as_str())
                .collect::<Vec<_>>(),
            vec!["model-a", "model-z", "unknown"]
        );
        let model_a = model_rates
            .iter()
            .find(|rate| rate.model == "model-a")
            .unwrap()
            .tokens_per_second;
        let model_z = model_rates
            .iter()
            .find(|rate| rate.model == "model-z")
            .unwrap()
            .tokens_per_second;
        let unknown = model_rates
            .iter()
            .find(|rate| rate.model == "unknown")
            .unwrap()
            .tokens_per_second;
        assert!(model_a > 0.0);
        assert!(model_z > model_a);
        assert!(unknown > 0.0);
        assert_eq!(
            total,
            model_rates
                .iter()
                .map(|rate| rate.tokens_per_second)
                .sum::<f64>()
        );
    }

    #[test]
    fn stopped_turn_clears_current_model_rate_immediately() {
        let scope = LiveRateSourceScope::new(
            "c-curve-model-rates-stop-test",
            "c-curve-model-rates-stop-test",
        );
        let mut signals = Vec::new();
        add_active_test_turn(&mut signals, "thread", Some("model-a"), 10.0);
        apply_signals(&scope, &signals, 16.0);
        let (running_total, _, running_model_rates, _) = snapshot(&scope, 16.0, None);
        assert!(running_total > 0.0);
        assert!(!running_model_rates.is_empty());

        apply_signals(
            &scope,
            &[RolloutSignal::TurnCompleted {
                thread_id: "thread".into(),
                turn_id: Some("thread-turn".into()),
                failed: true,
                at: 16.5,
            }],
            16.5,
        );
        let (stopped_total, _, stopped_model_rates, _) = snapshot(&scope, 16.5, None);
        assert_eq!(stopped_total, 0.0);
        assert!(stopped_model_rates.is_empty());
    }

    #[test]
    fn startup_usage_without_context_resolves_exact_turn_without_changing_curve_quantity() {
        let scope = LiveRateSourceScope::new(
            "c-curve-startup-model-resolution-test",
            "c-curve-startup-model-resolution-test",
        );
        apply_signals(
            &scope,
            &[usage_without_context("thread", "active-turn", 10.5)],
            16.0,
        );

        let (total_before, _, rates_before, _) = snapshot(&scope, 16.0, None);
        assert!(total_before > 0.0);
        assert_eq!(rates_before.len(), 1);
        assert_eq!(rates_before[0].model, "unknown");
        assert_eq!(
            unresolved_model_requests(&scope, 16.0),
            vec![("thread".into(), vec!["active-turn".into()])]
        );

        let mut wrong_turn = HashMap::new();
        wrong_turn.insert(
            "thread".into(),
            HashMap::from([("neighbor-turn".into(), "model-wrong".into())]),
        );
        assert!(!resolve_models(&scope, &wrong_turn, 16.0));
        let (total_after_wrong_turn, _, rates_after_wrong_turn, _) = snapshot(&scope, 16.0, None);
        assert_eq!(total_after_wrong_turn, total_before);
        assert_eq!(rates_after_wrong_turn[0].model, "unknown");

        let before_metadata_update = {
            let all = CURVES.get().unwrap().lock().unwrap();
            let thread = all.get(&scope).unwrap().get("thread").unwrap();
            (
                thread.turn_id.clone(),
                thread.started_at,
                thread.curve.budget,
                thread.curve.moment,
                thread.curve.debt,
                thread.curve.rate,
                thread.curve.pending_provisional,
                thread.curve.pending_reasoning_duration,
                thread.curve.last_quantity_at,
                thread.curve.last_settlement_at,
                thread.curve.last_tick,
            )
        };
        let mut exact_turn = HashMap::new();
        exact_turn.insert(
            "thread".into(),
            HashMap::from([("active-turn".into(), "model-a".into())]),
        );
        assert!(resolve_models(&scope, &exact_turn, 16.0));
        let after_metadata_update = {
            let all = CURVES.get().unwrap().lock().unwrap();
            let thread = all.get(&scope).unwrap().get("thread").unwrap();
            assert_eq!(thread.model.as_deref(), Some("model-a"));
            (
                thread.turn_id.clone(),
                thread.started_at,
                thread.curve.budget,
                thread.curve.moment,
                thread.curve.debt,
                thread.curve.rate,
                thread.curve.pending_provisional,
                thread.curve.pending_reasoning_duration,
                thread.curve.last_quantity_at,
                thread.curve.last_settlement_at,
                thread.curve.last_tick,
            )
        };
        assert_eq!(after_metadata_update, before_metadata_update);

        let (total_after_resolution, _, rates_after_resolution, _) = snapshot(&scope, 16.0, None);
        assert_eq!(total_after_resolution, total_before);
        assert_eq!(rates_after_resolution.len(), 1);
        assert_eq!(rates_after_resolution[0].model, "model-a");
        assert_eq!(rates_after_resolution[0].tokens_per_second, total_before);
    }

    #[test]
    fn stopped_or_known_curve_turn_rejects_model_metadata_updates() {
        let stopped_scope = LiveRateSourceScope::new(
            "c-curve-stopped-model-resolution-test",
            "c-curve-stopped-model-resolution-test",
        );
        apply_signals(
            &stopped_scope,
            &[usage_without_context("thread", "stopped-turn", 10.5)],
            16.0,
        );
        apply_signals(
            &stopped_scope,
            &[RolloutSignal::TurnCompleted {
                thread_id: "thread".into(),
                turn_id: Some("stopped-turn".into()),
                failed: true,
                at: 16.25,
            }],
            16.25,
        );
        let stopped_resolution = HashMap::from([(
            "thread".into(),
            HashMap::from([("stopped-turn".into(), "model-a".into())]),
        )]);
        assert!(!resolve_models(&stopped_scope, &stopped_resolution, 16.25));
        assert!(unresolved_model_requests(&stopped_scope, 16.25).is_empty());
        let (stopped_total, _, stopped_rates, _) = snapshot(&stopped_scope, 16.25, None);
        assert_eq!(stopped_total, 0.0);
        assert!(stopped_rates.is_empty());

        let known_scope = LiveRateSourceScope::new(
            "c-curve-known-model-resolution-test",
            "c-curve-known-model-resolution-test",
        );
        let mut signals = Vec::new();
        add_active_test_turn(&mut signals, "thread", Some("model-known"), 10.0);
        apply_signals(&known_scope, &signals, 16.0);
        let known_resolution = HashMap::from([(
            "thread".into(),
            HashMap::from([("thread-turn".into(), "model-overwrite".into())]),
        )]);
        assert!(!resolve_models(&known_scope, &known_resolution, 16.0));
        let all = CURVES.get().unwrap().lock().unwrap();
        let thread = all.get(&known_scope).unwrap().get("thread").unwrap();
        assert_eq!(thread.model.as_deref(), Some("model-known"));
    }

    #[test]
    fn completed_curve_tail_can_resolve_model_until_its_quantity_expires() {
        let scope = LiveRateSourceScope::new(
            "c-curve-completed-model-resolution-test",
            "c-curve-completed-model-resolution-test",
        );
        apply_signals(
            &scope,
            &[usage_without_context("thread", "completed-turn", 10.5)],
            11.0,
        );
        apply_signals(
            &scope,
            &[RolloutSignal::TurnCompleted {
                thread_id: "thread".into(),
                turn_id: Some("completed-turn".into()),
                failed: false,
                at: 11.25,
            }],
            11.25,
        );

        let requests = unresolved_model_requests(&scope, 12.0);
        assert_eq!(
            requests,
            vec![("thread".into(), vec!["completed-turn".into()])]
        );
        let resolution = HashMap::from([(
            "thread".into(),
            HashMap::from([("completed-turn".into(), "model-tail".into())]),
        )]);
        assert!(resolve_models(&scope, &resolution, 12.0));
        let (total, _, rates, _) = snapshot(&scope, 12.0, None);
        assert!(total > 0.0);
        assert_eq!(rates.len(), 1);
        assert_eq!(rates[0].model, "model-tail");

        let (expired_total, _, expired_rates, _) = snapshot(&scope, 17.0, None);
        assert_eq!(expired_total, 0.0);
        assert!(expired_rates.is_empty());
        assert!(unresolved_model_requests(&scope, 17.0).is_empty());
    }

    #[test]
    fn new_non_context_turn_does_not_inherit_prior_model_and_can_resolve_exactly() {
        let scope = LiveRateSourceScope::new(
            "c-curve-new-turn-model-resolution-test",
            "c-curve-new-turn-model-resolution-test",
        );
        let signals = [
            RolloutSignal::Context {
                thread_id: "thread".into(),
                turn_id: Some("previous-turn".into()),
                model: Some("model-previous".into()),
                at: 10.0,
            },
            RolloutSignal::ReasoningCompleted {
                thread_id: "thread".into(),
                turn_id: Some("previous-turn".into()),
                item_id: "previous-reasoning".into(),
                duration_seconds: 1.0,
                at: 10.1,
            },
            RolloutSignal::UsageSettled {
                thread_id: "thread".into(),
                turn_id: Some("previous-turn".into()),
                output_tokens: 10,
                reasoning_tokens: 10,
                at: 10.5,
            },
            RolloutSignal::TurnStarted {
                thread_id: "thread".into(),
                turn_id: Some("current-turn".into()),
                at: 11.0,
            },
            usage_without_context("thread", "current-turn", 11.5),
        ];
        apply_signals(&scope, &signals, 16.0);

        let (total_before, _, rates_before, _) = snapshot(&scope, 16.0, None);
        assert!(total_before > 0.0);
        assert_eq!(rates_before.len(), 1);
        assert_eq!(rates_before[0].model, "unknown");
        assert_eq!(
            unresolved_model_requests(&scope, 16.0),
            vec![("thread".into(), vec!["current-turn".into()])]
        );
        {
            let all = CURVES.get().unwrap().lock().unwrap();
            let thread = all.get(&scope).unwrap().get("thread").unwrap();
            assert_eq!(thread.model, None);
            assert_eq!(thread.baseline_by_model["model-previous"].len(), 1);
        }

        let resolution = HashMap::from([(
            "thread".into(),
            HashMap::from([("current-turn".into(), "model-current".into())]),
        )]);
        assert!(resolve_models(&scope, &resolution, 16.0));
        let (total_after, _, rates_after, _) = snapshot(&scope, 16.0, None);
        assert_eq!(total_after, total_before);
        assert_eq!(rates_after.len(), 1);
        assert_eq!(rates_after[0].model, "model-current");
        assert_eq!(rates_after[0].tokens_per_second, total_before);
    }
}
