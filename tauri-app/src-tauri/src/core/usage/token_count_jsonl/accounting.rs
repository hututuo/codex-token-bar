//! Component accounting for Codex: cached input is part of input and reasoning
//! is part of output. Mirrored by TokenUsageAccounting.swift.
use serde::{Deserialize, Serialize};

pub(super) const ACCOUNTING_REVISION: &str = "codex-components-v1";

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct Components {
    pub input: u64,
    pub cached: u64,
    pub output: u64,
    pub reasoning: u64,
}
impl Components {
    pub fn total(self) -> u64 { self.input.saturating_add(self.output) }
    pub fn valid(self) -> bool {
        self.cached <= self.input && self.reasoning <= self.output
            && self.total() <= i64::MAX as u64
    }
    pub fn subtract(self, other: Self) -> Option<Self> {
        let value = Self { input: self.input.checked_sub(other.input)?,
            cached: self.cached.checked_sub(other.cached)?,
            output: self.output.checked_sub(other.output)?,
            reasoning: self.reasoning.checked_sub(other.reasoning)? };
        value.valid().then_some(value)
    }
    fn add(self, other: Self) -> Option<Self> {
        let value = Self { input: self.input.checked_add(other.input)?,
            cached: self.cached.checked_add(other.cached)?,
            output: self.output.checked_add(other.output)?,
            reasoning: self.reasoning.checked_add(other.reasoning)? };
        value.valid().then_some(value)
    }
}

#[derive(Clone, Debug)]
pub(super) struct Snapshot {
    pub components: Components,
    pub reported_total: Option<u64>,
    pub has_input_and_output: bool,
    pub invalid_number: bool,
    pub signature: String,
}
impl Snapshot {
    pub fn usable(&self) -> bool {
        self.has_input_and_output && !self.invalid_number && self.components.valid()
    }
    fn unexplained(&self) -> bool {
        self.reported_total.unwrap_or(0) > 0 || self.components.total() > 0
            || self.components.cached > 0 || self.components.reasoning > 0 || self.invalid_number
    }
}

// Nonzero kinds are diagnostic rows, never calls or billable token events.
pub(super) const COUNTED: i64 = 0;
pub(super) const REPORTED_ONLY: i64 = 1;
pub(super) const INVALID: i64 = 2;
#[derive(Clone, Copy, Debug)]
pub(super) struct AccountingResult { pub components: Components, pub kind: i64 }
impl AccountingResult {
    pub fn tokens(self) -> u64 { if self.kind == COUNTED { self.components.total() } else { 0 } }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct AccountingState {
    pub previous: Option<Components>,
    pub unreflected: Components,
    pub can_start_from_zero: bool,
    pub counter_reset: bool,
    pub last_snapshot: Option<String>,
    #[serde(default)]
    pub paginated_own_start_ordinal: Option<u64>,
    #[serde(default)]
    pub paginated_pending_turn_id: Option<String>,
    #[serde(default)]
    pub paginated_pending_turn_ordinal: Option<u64>,
    #[serde(default)]
    pub paginated_pending_is_context: Option<bool>,
}
impl AccountingState {
    pub fn fresh() -> Self { Self { can_start_from_zero: true, ..Self::default() } }
    pub fn decode(value: Option<String>) -> Result<Option<Self>, String> {
        value.map(|value| serde_json::from_str(&value)
            .map_err(|e| format!("Invalid accounting checkpoint: {e}"))).transpose()
    }
    pub fn encode(&self) -> String {
        serde_json::to_string(self).expect("integer accounting checkpoint")
    }
    pub fn observe(&mut self, last: Option<&Snapshot>, total: Option<&Snapshot>) -> Option<AccountingResult> {
        let anchor = self.previous.or_else(|| self.can_start_from_zero.then(Components::default));
        let cumulative = total.filter(|t| t.usable() && !(t.components.total() == 0 && t.reported_total.unwrap_or(0) > 0)).map(|t| t.components);
        let pending = self.unreflected;
        let mut delta = None;
        if let Some(cumulative) = cumulative {
            if let Some(anchor) = anchor {
                delta = cumulative.subtract(anchor).and_then(|v| v.subtract(pending));
                if cumulative.input < anchor.input || cumulative.cached < anchor.cached
                    || cumulative.output < anchor.output || cumulative.reasoning < anchor.reasoning {
                    self.counter_reset = true;
                }
            }
            self.previous = Some(cumulative);
            self.unreflected = Components::default();
            self.can_start_from_zero = false;
        }
        if let Some(last) = last.filter(|l| l.usable() && l.components.total() > 0) {
            if cumulative.is_none() {
                if let Some(next) = self.unreflected.add(last.components) { self.unreflected = next; }
                else { self.previous = None; self.unreflected = Components::default(); }
            }
            return Some(AccountingResult { components: last.components, kind: COUNTED });
        }
        if let Some(last) = last.filter(|l| l.invalid_number || (l.has_input_and_output && !l.components.valid())) {
            return Some(AccountingResult { components: last.components, kind: INVALID });
        }
        if let Some(delta) = delta.filter(|d| d.total() > 0) {
            return Some(AccountingResult { components: delta, kind: COUNTED });
        }
        if let Some(last) = last.filter(|l| l.unexplained()) {
            return Some(AccountingResult { components: last.components, kind: REPORTED_ONLY });
        }
        if delta.is_none() || total.is_some_and(|t| t.components.total() == 0) {
            if let Some(total) = total.filter(|t| t.unexplained()) {
                return Some(AccountingResult { components: total.components,
                    kind: if total.usable() { REPORTED_ONLY } else { INVALID } });
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(
        components: Components,
        reported_total: Option<u64>,
        has_input_and_output: bool,
        invalid_number: bool,
        signature: &str,
    ) -> Snapshot {
        Snapshot {
            components,
            reported_total,
            has_input_and_output,
            invalid_number,
            signature: signature.to_owned(),
        }
    }

    fn complete(
        input: u64,
        cached: u64,
        output: u64,
        reasoning: u64,
        reported_total: Option<u64>,
        signature: &str,
    ) -> Snapshot {
        snapshot(
            Components { input, cached, output, reasoning },
            reported_total,
            true,
            false,
            signature,
        )
    }

    #[test]
    fn formula_counts_input_plus_output_and_keeps_reasoning_as_detail() {
        let mut state = AccountingState::fresh();
        let last = complete(100, 40, 10, 7, None, "last-only");

        let result = state.observe(Some(&last), None).expect("complete last usage");

        assert_eq!(result.kind, COUNTED);
        assert_eq!(result.components, Components { input: 100, cached: 40, output: 10, reasoning: 7 });
        assert_eq!(result.tokens(), 110);
        assert_eq!(result.components.total(), 110);
    }

    #[test]
    fn total_only_53707_is_retained_as_diagnostic_and_following_usage_counts_57590() {
        let mut state = AccountingState::fresh();
        let total_only = complete(0, 0, 0, 0, Some(53_707), "total-only");
        let following = complete(57_038, 18_176, 552, 447, Some(57_590), "following");

        let diagnostic = state
            .observe(None, Some(&total_only))
            .expect("total-only row is retained for diagnosis");
        let counted = state
            .observe(None, Some(&following))
            .expect("following cumulative components");

        assert_eq!(diagnostic.kind, REPORTED_ONLY);
        assert_eq!(diagnostic.tokens(), 0);
        assert_eq!(diagnostic.components, Components::default());
        assert_eq!(counted.kind, COUNTED);
        assert_eq!(counted.tokens(), 57_590);
        assert_eq!(counted.components, Components { input: 57_038, cached: 18_176, output: 552, reasoning: 447 });
    }

    #[test]
    fn cumulative_fallback_uses_component_deltas() {
        let mut state = AccountingState::fresh();
        let snapshots = [
            complete(100, 40, 10, 2, Some(110), "cumulative-1"),
            complete(130, 50, 20, 5, Some(150), "cumulative-2"),
            complete(160, 60, 25, 6, Some(185), "cumulative-3"),
        ];
        let results: Vec<_> = snapshots
            .iter()
            .map(|total| state.observe(None, Some(total)).expect("cumulative delta"))
            .collect();

        assert_eq!(results.iter().map(|result| result.kind).collect::<Vec<_>>(), vec![COUNTED; 3]);
        assert_eq!(results.iter().map(|result| result.tokens()).collect::<Vec<_>>(), vec![110, 40, 35]);
        assert_eq!(results[0].components, Components { input: 100, cached: 40, output: 10, reasoning: 2 });
        assert_eq!(results[1].components, Components { input: 30, cached: 10, output: 10, reasoning: 3 });
        assert_eq!(results[2].components, Components { input: 30, cached: 10, output: 5, reasoning: 1 });
    }

    #[test]
    fn last_only_then_matching_cumulative_snapshot_is_not_counted_twice() {
        let mut state = AccountingState::fresh();
        let last = complete(100, 40, 10, 2, None, "last-only");
        let matching_total = complete(100, 40, 10, 2, Some(110), "matching-total");
        let following_total = complete(130, 50, 20, 5, Some(150), "following-total");

        let first = state.observe(Some(&last), None).expect("last-only usage");
        let duplicate = state.observe(None, Some(&matching_total));
        let following = state
            .observe(None, Some(&following_total))
            .expect("new cumulative usage");

        assert_eq!(first.kind, COUNTED);
        assert_eq!(first.tokens(), 110);
        assert!(duplicate.is_none());
        assert_eq!(following.kind, COUNTED);
        assert_eq!(following.tokens(), 40);
    }

    #[test]
    fn cumulative_reset_allows_same_last_tuple_as_a_real_request() {
        let mut state = AccountingState::fresh();
        let first_total = complete(200, 80, 20, 4, Some(220), "first-total");
        let request = complete(100, 40, 10, 2, Some(110), "same-request");
        let first = state
            .observe(Some(&request), Some(&first_total))
            .expect("first request");

        let reset_total = complete(100, 40, 10, 2, Some(110), "reset-total");
        let second = state
            .observe(Some(&request), Some(&reset_total))
            .expect("request after cumulative reset");

        assert_eq!(first.kind, COUNTED);
        assert_eq!(second.kind, COUNTED);
        assert_eq!(first.tokens(), 110);
        assert_eq!(second.tokens(), 110);
        assert!(state.counter_reset);
    }

    #[test]
    fn invalid_cache_and_negative_number_diagnostics_are_not_billable() {
        let mut state = AccountingState::fresh();
        let cache_exceeds_input = snapshot(
            Components { input: 10, cached: 11, output: 3, reasoning: 1 },
            Some(24),
            true,
            false,
            "invalid-cache",
        );
        let negative_number = snapshot(
            Components { input: 0, cached: 0, output: 3, reasoning: 0 },
            Some(2),
            false,
            true,
            "invalid-negative",
        );

        let cache_result = state
            .observe(Some(&cache_exceeds_input), None)
            .expect("cache diagnostic");
        let negative_result = state
            .observe(Some(&negative_number), None)
            .expect("negative-number diagnostic");

        assert_eq!(cache_result.kind, INVALID);
        assert_eq!(cache_result.tokens(), 0);
        assert_eq!(cache_result.components.cached, 11);
        assert_eq!(negative_result.kind, INVALID);
        assert_eq!(negative_result.tokens(), 0);
    }

    #[test]
    fn accounting_state_round_trips_through_json() {
        let state = AccountingState {
            previous: Some(Components { input: 130, cached: 50, output: 20, reasoning: 5 }),
            unreflected: Components { input: 7, cached: 3, output: 2, reasoning: 1 },
            can_start_from_zero: false,
            counter_reset: true,
            last_snapshot: Some("snapshot-signature".to_owned()),
            ..AccountingState::default()
        };

        let encoded = state.encode();
        let decoded = AccountingState::decode(Some(encoded))
            .expect("valid checkpoint JSON")
            .expect("checkpoint value");

        assert_eq!(decoded, state);
        assert!(AccountingState::decode(Some("{".to_owned())).is_err());
    }
}
