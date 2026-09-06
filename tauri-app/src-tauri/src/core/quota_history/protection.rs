//! Deterministic, per-window history projection. Input rows remain raw.
//! Local observation timestamps establish freshness, not server event time.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct HistoryPolicy {
    pub new_cycle_reset_delta: f64,
    pub maximum_new_cycle_used_percent: i32,
    pub reset_jitter_tolerance: f64,
    pub correction_sample_count: u32,
    pub correction_evidence_duration: f64,
}

impl HistoryPolicy {
    // Independent definitions intentionally start equal. The weekly policy
    // can later be tightened without changing the short window.
    pub const FIVE_HOUR: Self = Self { new_cycle_reset_delta: 1800.0, maximum_new_cycle_used_percent: 100, reset_jitter_tolerance: 5.0, correction_sample_count: 3, correction_evidence_duration: 300.0 };
    pub const SEVEN_DAY: Self = Self { new_cycle_reset_delta: 1800.0, maximum_new_cycle_used_percent: 100, reset_jitter_tolerance: 5.0, correction_sample_count: 3, correction_evidence_duration: 300.0 };
}

pub(super) struct HistoryProtection {
    policy: HistoryPolicy,
    last_observed: Option<f64>,
    accepted_used: Option<i32>,
    accepted_reset: Option<f64>,
    generation: i64,
    lower: Option<(f64, u32)>,
}

impl Default for HistoryProtection {
    fn default() -> Self {
        Self { policy: HistoryPolicy::FIVE_HOUR, last_observed: None, accepted_used: None, accepted_reset: None, generation: 0, lower: None }
    }
}

pub(super) struct Decision {
    pub used: Option<i32>,
    pub reset: Option<f64>,
    pub generation: i64,
    pub is_anchor: bool,
    pub needs_evidence: bool,
    pub is_correction: bool,
}

impl HistoryProtection {
    pub(super) fn new(policy: HistoryPolicy) -> Self { Self { policy, ..Self::default() } }

    pub(super) fn observe(&mut self, used: Option<i32>, reset: Option<f64>, at: f64) -> Decision {
        if !at.is_finite() || self.last_observed.is_some_and(|last| at <= last + 0.000_001) {
            return self.result(None, false, false, false);
        }
        self.last_observed = Some(at);
        let Some(used) = used.filter(|used| (0..=100).contains(used)) else {
            self.lower = None;
            return self.result(None, false, true, false);
        };
        let reset = reset.filter(|reset| reset.is_finite());
        if self.accepted_used.is_none() {
            self.accepted_used = Some(used);
            self.accepted_reset = reset;
            let expired = reset.is_some_and(|reset| at >= reset);
            return self.result((!expired).then_some(used), reset.is_some(), expired, false);
        }
        if reset.zip(self.accepted_reset).is_some_and(|(current, anchor)| current - anchor > self.policy.new_cycle_reset_delta + 0.000_001) {
            if used > self.policy.maximum_new_cycle_used_percent {
                self.lower = None;
                return self.result(None, false, true, false);
            }
            self.generation = self.generation.saturating_add(1);
            self.accepted_reset = reset;
            self.accepted_used = Some(used);
            self.lower = None;
            return self.result(Some(used), true, false, false);
        }
        if self.accepted_reset.is_some_and(|anchor| at >= anchor)
            || reset.zip(self.accepted_reset).is_some_and(|(current, anchor)| current < anchor - self.policy.reset_jitter_tolerance - 0.000_001)
        {
            self.lower = None;
            return self.result(None, false, true, false);
        }
        let establishing_anchor = self.accepted_reset.is_none() && reset.is_some();
        if establishing_anchor {
            self.accepted_reset = reset;
            if reset.is_some_and(|reset| at >= reset) {
                self.lower = None;
                return self.result(None, true, true, false);
            }
        }
        if used >= self.accepted_used.unwrap() {
            self.accepted_used = Some(used);
            self.lower = None;
            return self.result(Some(used), establishing_anchor, false, false);
        }
        if !reset.zip(self.accepted_reset).is_some_and(|(current, anchor)| (current - anchor).abs() <= self.policy.reset_jitter_tolerance + 0.000_001) {
            self.lower = None;
            return self.result(None, establishing_anchor, true, false);
        }
        let (first, count) = self.lower.get_or_insert((at, 0));
        *count = count.saturating_add(1);
        if *count >= self.policy.correction_sample_count && at - *first + 0.000_001 >= self.policy.correction_evidence_duration {
            self.accepted_used = Some(used);
            self.lower = None;
            return self.result(Some(used), establishing_anchor, true, true);
        }
        self.result(None, establishing_anchor, true, false)
    }

    fn result(&self, used: Option<i32>, is_anchor: bool, needs_evidence: bool, is_correction: bool) -> Decision {
        Decision { used, reset: self.accepted_reset, generation: self.generation, is_anchor, needs_evidence, is_correction }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weekly_policy_can_be_tightened_without_changing_five_hour_defaults() {
        let weekly = HistoryPolicy { maximum_new_cycle_used_percent: 30, correction_sample_count: 4, correction_evidence_duration: 600.0, ..HistoryPolicy::SEVEN_DAY };
        let mut five = HistoryProtection::new(HistoryPolicy::FIVE_HOUR);
        let mut seven = HistoryProtection::new(weekly);
        five.observe(Some(90), Some(20_000.0), 0.0);
        seven.observe(Some(90), Some(20_000.0), 0.0);
        assert_eq!(five.observe(Some(80), Some(21_801.0), 1.0).generation, 1);
        let rejected = seven.observe(Some(80), Some(21_801.0), 1.0);
        assert_eq!(rejected.used, None);
        assert_eq!(rejected.generation, 0);
        assert_eq!(seven.observe(Some(30), Some(21_801.0), 2.0).generation, 1);
        assert_eq!(HistoryPolicy::FIVE_HOUR.maximum_new_cycle_used_percent, 100);
        assert_eq!(HistoryPolicy::SEVEN_DAY.maximum_new_cycle_used_percent, 100);
    }

    #[test]
    fn forward_boundary_accepts_all_valid_percentages_for_each_window() {
        for _window in ["5h", "7d"] {
            for used in [0, 2, 50, 80, 100] {
                let mut state = HistoryProtection::default();
                state.observe(Some(90), Some(20_000.0), 0.0);
                assert_eq!(state.observe(Some(used), Some(21_800.0), 1.0).generation, 0);
                let decision = state.observe(Some(used), Some(21_801.0), 2.0);
                assert_eq!(decision.generation, 1);
                assert_eq!(decision.used, Some(used));
                assert!(decision.is_anchor);
            }
        }
    }

    #[test]
    fn lower_values_require_three_fresh_samples_across_five_minutes() {
        let mut state = HistoryProtection::default();
        state.observe(Some(12), Some(20_000.0), 0.0);
        assert_eq!(state.observe(Some(8), Some(20_000.0), 10.0).used, None);
        assert_eq!(state.observe(Some(8), Some(20_000.0), 10.0).used, None);
        state.observe(Some(8), Some(20_000.0), 9.0);
        assert_eq!(state.observe(Some(8), Some(20_000.0), 310.0).used, None);
        let result = state.observe(Some(8), Some(20_000.0), 311.0);
        assert_eq!(result.used, Some(8));
        assert_eq!(result.generation, 0);
        assert!(result.is_correction && result.needs_evidence);
        assert_eq!(state.observe(Some(9), Some(20_000.0), 312.0).used, Some(9));
    }

    #[test]
    fn fixed_anchor_rejects_backward_boundary_and_does_not_follow_creep() {
        let mut state = HistoryProtection::default();
        state.observe(Some(12), Some(20_000.0), 0.0);
        assert_eq!(state.observe(Some(0), Some(18_000.0), 1.0).used, None);
        for (i, reset) in [20_600.0, 21_200.0, 21_800.0].into_iter().enumerate() {
            assert_eq!(state.observe(Some(13), Some(reset), 100.0 + i as f64 * 300.0).generation, 0);
        }
        assert_eq!(state.observe(Some(70), Some(21_801.0), 1000.0).generation, 1);
    }

    #[test]
    fn recovery_missing_reset_and_expiry_do_not_fabricate_usage() {
        let mut state = HistoryProtection::default();
        state.observe(Some(12), Some(2000.0), 0.0);
        assert_eq!(state.observe(Some(0), Some(2000.0), 10.0).used, None);
        assert_eq!(state.observe(Some(13), Some(2000.0), 20.0).used, Some(13));
        for at in [30.0, 330.0, 630.0] {
            assert_eq!(state.observe(Some(8), None, at).used, None);
        }
        assert_eq!(state.observe(Some(101), Some(2000.0), 700.0).used, None);
        assert_eq!(state.observe(Some(14), Some(2000.0), 2000.0).used, None);
        assert_eq!(state.observe(Some(100), Some(4000.0), 2100.0).used, Some(100));
    }
}
