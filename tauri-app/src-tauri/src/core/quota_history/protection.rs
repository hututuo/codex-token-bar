//! Reversible presentation repair over one identity/plan/limit timeline.
//! Raw quota observations and both usage ledgers remain untouched.
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct HistoryPolicy {
    pub new_cycle_reset_delta: f64,
    pub maximum_new_cycle_used_percent: i32,
    pub reset_jitter_tolerance: f64,
}
impl HistoryPolicy {
    pub const FIVE_HOUR: Self = Self {
        new_cycle_reset_delta: 1800.0,
        maximum_new_cycle_used_percent: 100,
        reset_jitter_tolerance: 5.0,
    };
    pub const SEVEN_DAY: Self = Self {
        new_cycle_reset_delta: 900.0,
        maximum_new_cycle_used_percent: 100,
        reset_jitter_tolerance: 5.0,
    };
}

#[derive(Clone, Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Sample {
    pub at: f64,
    pub five_used: Option<i32>,
    pub five_reset: Option<f64>,
    pub seven_used: Option<i32>,
    pub seven_reset: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Reason {
    ReturnToBaseline,
    Jump,
    ResetReturned,
    ResetUnchanged,
}

#[derive(Debug)]
pub(super) struct Rejection {
    pub baseline: usize,
    pub start: usize,
    pub end: usize,
    pub reason: Reason,
}

#[derive(Default)]
pub(super) struct Projection {
    pub five_rejected: HashSet<usize>,
    pub seven_rejected: HashSet<usize>,
    pub five_bridges: HashMap<usize, usize>,
    pub seven_bridges: HashMap<usize, usize>,
    pub events: Vec<Rejection>,
}

const EPSILON: f64 = 0.000_001;

pub(super) fn valid(used: Option<i32>) -> Option<i32> {
    used.filter(|value| (0..=100).contains(value))
}

fn same_reset(a: Option<f64>, b: Option<f64>) -> bool {
    a.zip(b)
        .is_some_and(|(a, b)| a.is_finite() && b.is_finite() && (a - b).abs() <= 5.0 + EPSILON)
}

pub(super) fn project(samples: &[Sample], plan: Option<&str>, now: f64) -> Projection {
    project_with_evidence(samples, plan, now, |_, _| {
        super::cycles::ConsumptionEvidence::Unknown
    })
}

pub(super) fn project_with_evidence(
    samples: &[Sample],
    _plan: Option<&str>,
    now: f64,
    mut consumption: impl FnMut(f64, f64) -> super::cycles::ConsumptionEvidence,
) -> Projection {
    let mut result = Projection::default();
    let mut raw_indices = Vec::new();
    let mut values = Vec::new();
    let mut fresh = HashSet::new();
    let mut seen = f64::NEG_INFINITY;
    for (index, sample) in samples.iter().enumerate() {
        if !sample.at.is_finite() || sample.at > now || sample.at <= seen + EPSILON {
            continue;
        }
        seen = sample.at;
        fresh.insert(index);
        if let Some(used) = valid(sample.seven_used) {
            raw_indices.push(index);
            values.push((sample.at, used));
        }
    }

    for reversal in
        super::cycles::quota_cycle_reversals(&values, |from, through| consumption(from, through))
    {
        let baseline = raw_indices[reversal.before_index];
        let start = raw_indices[reversal.drop_index];
        let end = raw_indices[reversal.return_index];
        // Exclude the transient dip, then carry the previous value through the
        // return point. This matches actual-cycle boundary withdrawal.
        result.seven_rejected.extend(start..end);
        result.seven_bridges.insert(baseline, end);
        result.events.push(Rejection {
            baseline,
            start,
            end,
            reason: Reason::ReturnToBaseline,
        });
    }

    // Preserve the existing five-hour paired repair: only a single 5h zero
    // point paired with an independently rejected 7d observation can be
    // repaired, and only with the same-reset A-B-A evidence.
    let five: Vec<usize> = samples
        .iter()
        .enumerate()
        .filter(|(index, sample)| fresh.contains(index) && valid(sample.five_used).is_some())
        .map(|(index, _)| index)
        .collect();
    for triple in five.windows(3) {
        let (a, b, c) = (triple[0], triple[1], triple[2]);
        if result.seven_rejected.contains(&b)
            && samples[a].five_used.unwrap_or(0) > 0
            && samples[b].five_used == Some(0)
            && samples[c].five_used.unwrap_or(0) > 0
            && samples[c].at > samples[b].at + EPSILON
            && samples[c].at - samples[b].at <= 120.0 + EPSILON
            && (samples[c].five_used.unwrap_or(0) - samples[a].five_used.unwrap_or(0)).abs() <= 1
            && same_reset(samples[a].five_reset, samples[b].five_reset)
            && same_reset(samples[a].five_reset, samples[c].five_reset)
        {
            result.five_rejected.insert(b);
            if samples[b].at - samples[a].at <= 90.0 * 60.0 + EPSILON {
                result.five_bridges.insert(a, c);
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::super::cycles::ConsumptionEvidence;
    use super::*;

    fn sample(at: f64, seven: i32, five: Option<i32>, reset: Option<f64>) -> Sample {
        Sample {
            at,
            five_used: five,
            five_reset: reset,
            seven_used: Some(seven),
            seven_reset: reset,
        }
    }

    #[test]
    fn unknown_and_present_consumption_preserve_the_drop() {
        let samples = [
            sample(0.25, 70, None, None),
            sample(60.125, 0, None, None),
            sample(120.875, 70, None, None),
        ];
        assert!(project(&samples, None, 121.0).seven_rejected.is_empty());
        let present =
            project_with_evidence(&samples, None, 121.0, |_, _| ConsumptionEvidence::Present);
        assert!(present.seven_rejected.is_empty());
    }

    #[test]
    fn absent_exact_interval_withdraws_only_matching_drop() {
        let samples = [
            sample(0.25, 80, None, Some(1000.0)),
            sample(60.125, 0, None, Some(5000.0)),
            sample(120.875, 20, None, Some(1000.0)),
            sample(180.25, 0, None, Some(2000.0)),
            sample(240.75, 20, None, Some(2000.0)),
        ];
        let projection = project_with_evidence(&samples, None, 241.0, |from, through| {
            if (from, through) == (180.25, 240.75) {
                ConsumptionEvidence::Absent
            } else {
                ConsumptionEvidence::Unknown
            }
        });
        assert_eq!(projection.seven_rejected, [3].into_iter().collect());
        assert_eq!(projection.seven_bridges, [(2, 4)].into_iter().collect());
        assert_eq!(projection.events.len(), 1);
        assert_eq!(projection.events[0].baseline, 2);
    }

    #[test]
    fn paired_five_hour_repair_keeps_its_previous_rules() {
        let samples = [
            sample(0.0, 60, Some(50), Some(1000.0)),
            sample(60.0, 0, Some(0), Some(1000.0)),
            sample(120.0, 60, Some(49), Some(1000.0)),
        ];
        let projection =
            project_with_evidence(&samples, None, 121.0, |_, _| ConsumptionEvidence::Absent);
        assert_eq!(projection.seven_rejected, [1].into_iter().collect());
        assert_eq!(projection.five_rejected, [1].into_iter().collect());
        assert_eq!(projection.five_bridges, [(0, 2)].into_iter().collect());
    }
}
