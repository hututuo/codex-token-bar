//! Pure retrospective projection for one identity/plan/limit timeline.
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct HistoryPolicy {
    pub new_cycle_reset_delta: f64,
    pub maximum_new_cycle_used_percent: i32,
    pub reset_jitter_tolerance: f64,
}
impl HistoryPolicy {
    pub const FIVE_HOUR: Self = Self { new_cycle_reset_delta: 1800.0, maximum_new_cycle_used_percent: 100, reset_jitter_tolerance: 5.0 };
    pub const SEVEN_DAY: Self = Self { new_cycle_reset_delta: 900.0, maximum_new_cycle_used_percent: 100, reset_jitter_tolerance: 5.0 };
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
pub(super) enum Reason { ReturnToBaseline, Jump, ResetReturned, ResetUnchanged }
#[derive(Debug)]
pub(super) struct Rejection { pub baseline: usize, pub start: usize, pub end: usize, pub reason: Reason }
#[derive(Default)]
pub(super) struct Projection {
    pub five_rejected: HashSet<usize>,
    pub seven_rejected: HashSet<usize>,
    pub five_bridges: HashMap<usize, usize>,
    pub seven_bridges: HashMap<usize, usize>,
    pub events: Vec<Rejection>,
}
#[derive(Clone, Copy)]
struct Candidate { baseline: usize, start: usize, last: usize, left_band: bool, reset_left: bool, reset_unchanged: bool }
const EPSILON: f64 = 0.000_001;
pub(super) fn valid(used: Option<i32>) -> Option<i32> { used.filter(|v| (0..=100).contains(v)) }
fn same_reset(a: Option<f64>, b: Option<f64>) -> bool {
    a.zip(b).is_some_and(|(a,b)| a.is_finite() && b.is_finite() && (a-b).abs() <= 5.0 + EPSILON)
}
impl Projection {
    fn reject(&mut self, c: Candidate, reason: Reason, samples: &[Sample]) {
        if c.last <= c.start { return; }
        self.seven_rejected.extend(c.start..c.last);
        // Preserve the existing 90-minute carry horizon before the event.
        if samples[c.start].at - samples[c.baseline].at <= 90.0 * 60.0 + EPSILON {
            self.seven_bridges.insert(c.baseline, c.last);
        }
        self.events.push(Rejection { baseline: c.baseline, start: c.start, end: c.last, reason });
    }
    fn settle(&mut self, c: Candidate, samples: &[Sample]) {
        if c.reset_unchanged && samples[c.start].at + 300.0 - samples[c.last].at <= 120.0 + EPSILON {
            self.reject(c, Reason::ResetUnchanged, samples);
        }
    }
}
pub(super) fn project(samples: &[Sample], plan: Option<&str>, now: f64) -> Projection {
    let mut result = Projection::default();
    let mut candidate: Option<Candidate> = None;
    let mut previous: Option<usize> = None;
    let mut seen: Option<f64> = None;
    let mut suppressed = false;
    let mut fresh = HashSet::new();
    let rate = match plan.map(|p| p.trim().to_ascii_lowercase()).as_deref() {
        Some("plus") => Some(10.0), Some("pro") => Some(2.0), _ => None,
    };
    for (i, sample) in samples.iter().enumerate() {
        if !sample.at.is_finite() || sample.at > now + EPSILON || seen.is_some_and(|last| sample.at <= last + EPSILON) { continue; }
        seen = Some(sample.at);
        fresh.insert(i);
        if let Some(c) = candidate {
            if sample.at > samples[c.start].at + 300.0 + EPSILON {
                result.settle(c, samples);
                candidate = None;
                suppressed = valid(samples[c.last].seven_used).unwrap_or(0) <= 2;
            }
        }
        let Some(used) = valid(sample.seven_used) else {
            if let Some(c) = candidate.as_mut() { c.reset_unchanged = false; }
            continue;
        };
        if let Some(mut c) = candidate {
            let base = &samples[c.baseline];
            let last = &samples[c.last];
            let in_band = (used - base.seven_used.unwrap()).abs() <= 3;
            let reset_same = same_reset(sample.seven_reset, base.seven_reset);
            let reset_return = c.reset_left && reset_same;
            let returned = c.left_band && in_band && used > last.seven_used.unwrap();
            let jumped = rate.is_some_and(|rate| f64::from(used - last.seven_used.unwrap()) * 60.0 / (sample.at-last.at) > rate + EPSILON);
            c.reset_unchanged = c.reset_unchanged && reset_same && sample.at-last.at <= 120.0+EPSILON;
            if sample.seven_reset.is_some_and(f64::is_finite) && base.seven_reset.is_some_and(f64::is_finite) && !reset_same { c.reset_left = true; }
            c.left_band |= !in_band;
            c.last = i;
            if returned || jumped || reset_return {
                result.reject(c, if returned { Reason::ReturnToBaseline } else if jumped { Reason::Jump } else { Reason::ResetReturned }, samples);
                candidate = None;
                suppressed = used <= 2;
            } else if sample.at >= samples[c.start].at + 300.0 - EPSILON {
                result.settle(c, samples);
                candidate = None;
                suppressed = used <= 2;
            } else { candidate = Some(c); }
        } else {
            if used > 2 { suppressed = false; }
            if !suppressed {
                if let Some(prev) = previous {
                    if valid(samples[prev].seven_used).is_some_and(|prior| used < prior && used <= 2) {
                        let same = same_reset(sample.seven_reset, samples[prev].seven_reset);
                        let has_resets = sample.seven_reset.is_some_and(f64::is_finite) && samples[prev].seven_reset.is_some_and(f64::is_finite);
                        candidate = Some(Candidate { baseline: prev, start: i, last: i,
                            left_band: (used-samples[prev].seven_used.unwrap()).abs()>3,
                            reset_left: has_resets && !same, reset_unchanged: same });
                    }
                }
            }
        }
        previous = Some(i);
    }
    if let Some(c) = candidate {
        if now >= samples[c.start].at + 300.0 - EPSILON { result.settle(c, samples); }
    }
    // Reject bidirectional provider excursions only on an abrupt return to
    // the old level/reset. Gradual normal consumption is not a rebound.
    let seven: Vec<_> = samples.iter().enumerate().filter(|(i,s)| fresh.contains(i) && valid(s.seven_used).is_some()).map(|(i,_)| i).collect();
    let mut cursor = 1;
    while cursor < seven.len() {
        let (base, first) = (seven[cursor-1], seven[cursor]);
        let (base_used, first_used) = (samples[base].seven_used.unwrap(), samples[first].seven_used.unwrap());
        if !result.seven_rejected.contains(&base) && !result.seven_rejected.contains(&first) && (first_used-base_used).abs() >= 5 {
            let mut endpoint = None;
            for n in cursor+1..seven.len() {
                let (end, prior) = (seven[n],seven[n-1]);
                if samples[end].at-samples[first].at > 5400.0 { break; }
                let (used, previous_used) = (samples[end].seven_used.unwrap(),samples[prior].seven_used.unwrap());
                if (used-base_used).abs() <= 3 && (used-previous_used).abs() >= 5
                    && (first_used-base_used)*(used-previous_used) < 0
                    && same_reset(samples[end].seven_reset,samples[base].seven_reset) {
                    endpoint = Some(n); break;
                }
            }
            if let Some(endpoint) = endpoint {
                result.reject(Candidate {baseline:base,start:first,last:seven[endpoint],left_band:true,reset_left:false,reset_unchanged:false},Reason::ReturnToBaseline,samples);
                cursor=endpoint+1; continue;
            }
        }
        cursor+=1;
    }
    let five: Vec<usize> = samples.iter().enumerate().filter(|(i,s)| fresh.contains(i) && valid(s.five_used).is_some()).map(|(i,_)|i).collect();
    for triple in five.windows(3) {
        let (a,b,c) = (triple[0], triple[1], triple[2]);
        if result.seven_rejected.contains(&b) && samples[a].five_used.unwrap()>0 && samples[b].five_used==Some(0) && samples[c].five_used.unwrap()>0
            && samples[c].at > samples[b].at + EPSILON && samples[c].at - samples[b].at <= 120.0+EPSILON
            && (samples[c].five_used.unwrap()-samples[a].five_used.unwrap()).abs()<=1
            && same_reset(samples[a].five_reset,samples[b].five_reset) && same_reset(samples[a].five_reset,samples[c].five_reset) {
            result.five_rejected.insert(b);
            if samples[b].at - samples[a].at <= 90.0 * 60.0 + EPSILON {
                result.five_bridges.insert(a,c);
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Case {
        name: String, plan: Option<String>, now: f64, samples: Vec<Sample>,
        five_rejected: Vec<usize>, seven_rejected: Vec<usize>,
        five_bridges: Vec<(usize,usize)>, seven_bridges: Vec<(usize,usize)>,
    }
    #[test]
    fn shared_retrospective_scenarios() {
        let cases: Vec<Case> = serde_json::from_str(include_str!("../../../../../Tests/SharedFixtures/quota-retrospective-v1.json")).unwrap();
        assert!(cases.len()>40);
        for case in cases {
            let p = project(&case.samples, case.plan.as_deref(), case.now);
            assert_eq!(p.five_rejected, case.five_rejected.into_iter().collect(), "{}", case.name);
            assert_eq!(p.seven_rejected, case.seven_rejected.into_iter().collect(), "{}", case.name);
            assert_eq!(p.five_bridges, case.five_bridges.into_iter().collect(), "{}", case.name);
            assert_eq!(p.seven_bridges, case.seven_bridges.into_iter().collect(), "{}", case.name);
        }
    }
}
