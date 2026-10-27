//! A bounded display-only trace. No transcript content, database or extra poller.
use super::LiveRateSourceScope;
use crate::models::ModelRate;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityRateHistoryPoint {
    pub start: f64,
    pub model_rates: Vec<ModelRate>,
}
#[derive(Default)]
struct Bucket {
    seconds: f64,
    tokens: BTreeMap<String, f64>,
}
#[derive(Default)]
struct History {
    previous_at: Option<f64>,
    previous_rates: Vec<ModelRate>,
    buckets: BTreeMap<i64, Bucket>,
}
static HISTORIES: OnceLock<Mutex<HashMap<LiveRateSourceScope, History>>> = OnceLock::new();

pub(super) fn record(scope: &LiveRateSourceScope, now: f64, rates: &[ModelRate]) {
    if !now.is_finite() || now < 0.0 {
        return;
    }
    let Ok(mut histories) = HISTORIES.get_or_init(Default::default).lock() else {
        return;
    };
    histories.retain(|_, h| h.previous_at.is_some_and(|at| now - at <= 1800.0));
    if !histories.contains_key(scope) && histories.len() >= 8 {
        if let Some(oldest) = histories
            .iter()
            .min_by(|a, b| {
                a.1.previous_at
                    .unwrap_or(0.0)
                    .total_cmp(&b.1.previous_at.unwrap_or(0.0))
            })
            .map(|(key, _)| key.clone())
        {
            histories.remove(&oldest);
        }
    }
    let h = histories.entry(scope.clone()).or_default();
    record_history(h, now, rates);
}

fn record_history(h: &mut History, now: f64, rates: &[ModelRate]) {
    if h.previous_at.is_some_and(|at| now < at) {
        *h = History::default();
    }
    if let Some(previous) = h.previous_at {
        let mut cursor = previous;
        let end = now.min(previous + 2.0);
        while cursor < end {
            let key = (cursor / 5.0).floor() as i64 * 5;
            let stop = end.min((key + 5) as f64);
            let duration = stop - cursor;
            let bucket = h.buckets.entry(key).or_default();
            bucket.seconds += duration;
            for rate in &h.previous_rates {
                *bucket.tokens.entry(rate.model.clone()).or_default() +=
                    rate.tokens_per_second * duration;
            }
            cursor = stop;
        }
    }
    h.previous_at = Some(now);
    let finite: Vec<_> = rates
        .iter()
        .filter(|r| r.tokens_per_second.is_finite() && r.tokens_per_second > 0.0)
        .collect();
    h.previous_rates = finite.iter().take(63).map(|r| (**r).clone()).collect();
    if finite.len() > 63 {
        h.previous_rates.push(ModelRate {
            model: "unknown".into(),
            tokens_per_second: finite.iter().skip(63).map(|r| r.tokens_per_second).sum(),
        });
    }
    h.buckets.retain(|key, _| *key as f64 >= now - 1800.0);
}

pub(super) fn read(scope: &LiveRateSourceScope, now: f64) -> Vec<ActivityRateHistoryPoint> {
    let Ok(histories) = HISTORIES.get_or_init(Default::default).lock() else {
        return vec![];
    };
    let Some(h) = histories.get(scope) else {
        return vec![];
    };
    read_history(h, now)
}

fn read_history(h: &History, now: f64) -> Vec<ActivityRateHistoryPoint> {
    let current = (now / 5.0).floor() as i64 * 5;
    h.buckets
        .iter()
        .filter(|(key, b)| **key < current && **key as f64 >= now - 1800.0 && b.seconds > 0.0)
        .take(360)
        .map(|(key, b)| ActivityRateHistoryPoint {
            start: *key as f64,
            model_rates: b
                .tokens
                .iter()
                .map(|(model, tokens)| ModelRate {
                    model: model.clone(),
                    tokens_per_second: tokens / b.seconds,
                })
                .collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn rates(model: &str, speed: f64) -> Vec<ModelRate> {
        vec![ModelRate {
            model: model.into(),
            tokens_per_second: speed,
        }]
    }
    #[test]
    fn elapsed_weighting_keeps_each_models_share_and_missing_intervals_stay_missing() {
        let mut h = History::default();
        record_history(&mut h, 100.0, &rates("gpt-6-astra", 40.0));
        record_history(&mut h, 101.0, &rates("gpt-6.1-sol", 80.0));
        record_history(&mut h, 103.0, &rates("gpt-6-astra", 20.0));
        record_history(&mut h, 105.0, &[]);
        let points = read_history(&h, 105.0);
        assert_eq!(points.len(), 1);
        assert_eq!(
            points[0]
                .model_rates
                .iter()
                .map(|r| r.tokens_per_second)
                .sum::<f64>(),
            48.0
        );
        assert_eq!(
            points[0]
                .model_rates
                .iter()
                .find(|r| r.model == "gpt-6-astra")
                .unwrap()
                .tokens_per_second,
            16.0
        );
        record_history(&mut h, 120.0, &[]);
        assert!(!read_history(&h, 120.0).iter().any(|p| p.start == 110.0));
        for at in 121..2200 {
            record_history(&mut h, at as f64, &[]);
        }
        let retained = read_history(&h, 2200.0);
        assert!(retained.len() <= 360);
        assert!(retained.iter().all(|p| p.start >= 400.0));
    }
}
