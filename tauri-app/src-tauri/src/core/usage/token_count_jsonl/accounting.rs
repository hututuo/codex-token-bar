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
/// A compaction marker names a response but no matching per-response usage
/// record is available yet.  The zero-valued columns on this diagnostic row
/// are explicitly unknown and must never be treated as measured usage.
pub(super) const UNREPORTED_COMPACTION: i64 = 4;
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
    #[serde(default)]
    pub compaction: CompactionTrackingState,
}

pub(super) const MAX_RECENT_COMPACTION_RECORDS: usize = 128;

/// A bounded, replay-safe association point for one modern Codex request.
/// Optional numeric fields preserve the difference between an observed zero
/// and missing usage. `cache_write_tokens` is kept as evidence only; Codex
/// subscription pricing does not bill it separately.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct CompactionUsageRecord {
    pub response_id: String,
    pub input_tokens: Option<u64>,
    pub cached_input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub reasoning_output_tokens: Option<u64>,
    pub reported_total_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    #[serde(default)]
    pub has_usage_object: bool,
    #[serde(default)]
    pub invalid_number: bool,
    #[serde(default)]
    pub invalid_cache_write: bool,
    #[serde(default)]
    pub emitted_kind: Option<i64>,
    pub timestamp_unix_seconds: i64,
    pub raw_offset: u64,
    #[serde(default)]
    pub was_mirrored: bool,
    #[serde(default)]
    pub was_emitted: bool,
    #[serde(default)]
    pub legacy_association_attempted: bool,
    #[serde(default)]
    pub compacted_offset: Option<u64>,
    #[serde(default)]
    pub compacted_timestamp_unix_seconds: Option<i64>,
    #[serde(default)]
    pub compacted_user_prompt: Option<(u64, u64)>,
    #[serde(default)]
    pub compacted_assistant_response: Option<(u64, u64)>,
}

impl CompactionUsageRecord {
    pub fn components(&self) -> Option<Components> {
        if self.invalid_number { return None; }
        let components = Components {
            input: self.input_tokens?,
            cached: self.cached_input_tokens.unwrap_or(0),
            output: self.output_tokens?,
            reasoning: self.reasoning_output_tokens.unwrap_or(0),
        };
        components.valid().then_some(components)
    }
}

/// These records live inside the existing per-source accounting checkpoint.
/// Keeping only the newest bounded window avoids an unbounded checkpoint while
/// retaining response IDs needed across append/restart boundaries.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct CompactionTrackingState {
    #[serde(default)]
    pub records: Vec<CompactionUsageRecord>,
    #[serde(default)]
    pub zero_io_anchor_pending: bool,
    #[serde(default)]
    pub latest_modern_request_offset: Option<u64>,
    #[serde(default)]
    pub latest_modern_response_id: Option<String>,
}

impl CompactionTrackingState {
    pub fn push(&mut self, record: CompactionUsageRecord) -> usize {
        self.latest_modern_request_offset = Some(record.raw_offset);
        self.latest_modern_response_id = Some(record.response_id.clone());
        if let Some(index) = self.records.iter().rposition(|item| item.response_id == record.response_id) {
            let prior = self.records.remove(index);
            let mut record = record;
            if !record.has_usage_object && prior.has_usage_object {
                record.input_tokens = prior.input_tokens;
                record.cached_input_tokens = prior.cached_input_tokens;
                record.output_tokens = prior.output_tokens;
                record.reasoning_output_tokens = prior.reasoning_output_tokens;
                record.reported_total_tokens = prior.reported_total_tokens;
                record.cache_write_tokens = prior.cache_write_tokens;
                record.has_usage_object = true;
                record.invalid_number = prior.invalid_number;
                record.invalid_cache_write = prior.invalid_cache_write;
                record.timestamp_unix_seconds = prior.timestamp_unix_seconds;
                record.raw_offset = prior.raw_offset;
            }
            let was_mirrored = prior.was_mirrored;
            let was_emitted = prior.was_emitted;
            let legacy_association_attempted = prior.legacy_association_attempted;
            let compacted_offset = prior.compacted_offset;
            let compacted_timestamp_unix_seconds = prior.compacted_timestamp_unix_seconds;
            let compacted_user_prompt = prior.compacted_user_prompt;
            let compacted_assistant_response = prior.compacted_assistant_response;
            let emitted_kind = prior.emitted_kind;
            record.was_mirrored |= was_mirrored;
            record.was_emitted |= was_emitted;
            record.legacy_association_attempted |= legacy_association_attempted;
            record.compacted_offset = compacted_offset;
            record.compacted_timestamp_unix_seconds = compacted_timestamp_unix_seconds;
            record.compacted_user_prompt = compacted_user_prompt;
            record.compacted_assistant_response = compacted_assistant_response;
            record.emitted_kind = emitted_kind;
            self.records.push(record);
            return self.records.len() - 1;
        }
        self.records.push(record);
        if self.records.len() > MAX_RECENT_COMPACTION_RECORDS {
            self.records.remove(0);
        }
        self.records.len() - 1
    }

    pub fn note_modern_request(&mut self, raw_offset: u64) {
        self.latest_modern_request_offset = Some(raw_offset);
        self.latest_modern_response_id = None;
    }

    pub fn select_nearest_response(&mut self, response_id: &str, raw_offset: u64) {
        self.latest_modern_request_offset = Some(raw_offset);
        self.latest_modern_response_id = Some(response_id.to_owned());
    }

    pub fn find_response_mut(&mut self, response_id: &str) -> Option<&mut CompactionUsageRecord> {
        self.records.iter_mut().rev().find(|record| record.response_id == response_id)
    }

    pub fn nearest_preceding_mut(&mut self, raw_offset: u64) -> Option<&mut CompactionUsageRecord> {
        let latest = self.latest_modern_request_offset
            .or_else(|| self.records.last().map(|record| record.raw_offset))?;
        if latest >= raw_offset { return None; }
        if let Some(response_id) = self.latest_modern_response_id.as_deref() {
            self.records.iter_mut().rev().find(|record| record.response_id == response_id)
        } else if self.latest_modern_request_offset.is_none() {
            self.records.iter_mut().rev().find(|record| record.raw_offset == latest)
        } else {
            None
        }
    }
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

    #[test]
    fn old_checkpoints_default_the_compaction_tracker_and_new_state_round_trips() {
        let old = r#"{"previous":null,"unreflected":{"input":0,"cached":0,"output":0,"reasoning":0},"can_start_from_zero":true,"counter_reset":false,"last_snapshot":null}"#;
        let decoded = AccountingState::decode(Some(old.to_owned())).unwrap().unwrap();
        assert!(decoded.compaction.records.is_empty());
        assert!(!decoded.compaction.zero_io_anchor_pending);

        let mut state = decoded;
        state.compaction.records.push(CompactionUsageRecord {
            response_id: "resp-1".into(),
            input_tokens: Some(100),
            cached_input_tokens: Some(80),
            output_tokens: Some(20),
            reasoning_output_tokens: Some(5),
            reported_total_tokens: Some(120),
            cache_write_tokens: Some(7),
            timestamp_unix_seconds: 1_798_000_000,
            raw_offset: 123,
            has_usage_object: true,
            invalid_number: false,
            invalid_cache_write: false,
            emitted_kind: Some(COUNTED),
            was_mirrored: true,
            was_emitted: true,
            legacy_association_attempted: true,
            compacted_offset: Some(456),
            compacted_timestamp_unix_seconds: Some(1_798_000_001),
            compacted_user_prompt: Some((10, 20)),
            compacted_assistant_response: Some((20, 30)),
        });
        state.compaction.zero_io_anchor_pending = true;
        let round_trip = AccountingState::decode(Some(state.encode())).unwrap().unwrap();
        assert_eq!(round_trip, state);
    }

    #[test]
    fn compaction_tracker_stays_bounded_and_keeps_nearest_record() {
        let mut tracker = CompactionTrackingState::default();
        for offset in 0..(MAX_RECENT_COMPACTION_RECORDS as u64 + 5) {
            tracker.push(CompactionUsageRecord {
                response_id: format!("resp-{offset}"),
                input_tokens: Some(offset), cached_input_tokens: Some(0),
                output_tokens: Some(1), reasoning_output_tokens: Some(0),
                reported_total_tokens: Some(offset + 1), cache_write_tokens: None,
                timestamp_unix_seconds: offset as i64, raw_offset: offset,
                has_usage_object: true, invalid_number: false, invalid_cache_write: false,
                emitted_kind: None, was_mirrored: false, was_emitted: false,
                legacy_association_attempted: false, compacted_offset: None,
                compacted_timestamp_unix_seconds: None,
                compacted_user_prompt: None, compacted_assistant_response: None,
            });
        }
        assert_eq!(tracker.records.len(), MAX_RECENT_COMPACTION_RECORDS);
        assert!(tracker.find_response_mut("resp-0").is_none());
        assert_eq!(tracker.nearest_preceding_mut(u64::MAX).unwrap().response_id, "resp-132");
    }
}
