//! Read-only observed quota periods. Reset schedules are display metadata.
use super::*;
use serde::Serialize;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ConsumptionEvidence {
    Present,
    Absent,
    Unknown,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaCycle {
    pub id: String,
    pub start_lower_unix: Option<f64>,
    pub start_upper_unix: Option<f64>,
    pub end_lower_unix: f64,
    pub end_upper_unix: f64,
    pub first_observed_unix: f64,
    pub last_observed_unix: f64,
    pub expected_reset_unix: Option<f64>,
    pub current: bool,
    pub expired: bool,
    pub early_end: bool,
    pub pending_reset: bool,
    pub incomplete: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Observation {
    at: f64,
    used: i32,
    reset: Option<f64>,
}

struct Projection {
    cycles: Vec<QuotaCycle>,
    withdrawn: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct QuotaCycleReversal {
    pub before_index: usize,
    pub drop_index: usize,
    pub return_index: usize,
}

/// This path never opens a writer or claims legacy rows. Missing historical
/// stable identity cannot be reconstructed from today's account display name.
pub(crate) fn read(identity: &QuotaHistoryIdentity) -> Result<Vec<QuotaCycle>, String> {
    let mut rows = Vec::new();
    for (path, optional) in [
        (app_paths::quota_history_database_path(), false),
        (app_paths::legacy_shared_quota_history_database_path(), true),
    ] {
        let Some(path) = path.filter(|p| p.exists()) else {
            continue;
        };
        #[cfg(test)]
        let result = sqlite::open_read_only(&path, Duration::from_secs(2)).and_then(|connection| {
            database::query_stable_identity_rows(&connection, identity, None)
        });
        #[cfg(not(test))]
        let result = (|| -> Result<Vec<QuotaHistoryRow>, String> {
            let source_identity = crate::core::business_store_route::source_identity(
                "quota_history_legacy",
                &path,
            )?;
            let logical_path = format!("legacy/quota-history/{source_identity}");
            let connection = crate::core::business_store_route::open_store(
                "quota_history_legacy",
                &source_identity,
                &logical_path,
                &[path],
            )?;
            database::query_stable_identity_rows(&connection, identity, None)
                .map_err(|error| error.to_string())
        })()
        .map_err(super::store_route_sql_error);
        match result {
            Ok(found) => rows.extend(found),
            Err(_) if optional => {}
            Err(error) => return Err(format!("读取周期历史失败：{error}")),
        }
    }

    // Cycle boundaries use the raw stable-identity ledger. The chart's
    // configurable anomaly filter must not erase the evidence from which the
    // period boundaries themselves are projected.
    let rows = merge_history_rows(rows, Vec::new());
    let mut samples: Vec<_> = rows
        .into_iter()
        .filter(|row| row.stable_identity().as_ref() == Some(identity))
        .filter_map(|row| {
            let used = row.seven_day_used_percent?;
            ((0..=100).contains(&used) && row.created_at.is_finite()).then_some(Observation {
                at: row.created_at,
                used,
                reset: row.seven_day_resets_at.filter(|value| value.is_finite()),
            })
        })
        .collect();
    samples = accepted(samples, now_unix());

    let ranges = candidate_rebound_ranges(&samples);
    let evidence = if ranges.is_empty() {
        Vec::new()
    } else {
        crate::core::usage::token_count_jsonl::quota_cycle_consumption_evidence(
            Path::new(&identity.home_identity),
            &ranges,
        )
    };
    let evidence_by_range: HashMap<_, _> = ranges
        .into_iter()
        .zip(evidence)
        .map(|(range, evidence)| ((range.0.to_bits(), range.1.to_bits()), evidence))
        .collect();
    let scope = format!(
        "{}|{}|{}",
        identity.attribution_identity().scope_key,
        identity.plan_type,
        identity.limit_id
    );
    Ok(project_with_evidence(&samples, &scope, |from, through| {
        evidence_by_range
            .get(&(from.to_bits(), through.to_bits()))
            .copied()
            .unwrap_or(ConsumptionEvidence::Unknown)
    })
    .cycles)
}

fn accepted(mut samples: Vec<Observation>, now: f64) -> Vec<Observation> {
    samples.retain(|sample| {
        sample.at.is_finite() && sample.at <= now && (0..=100).contains(&sample.used)
    });
    samples.sort_by(|left, right| left.at.total_cmp(&right.at));
    samples.dedup_by(|later, earlier| later.at == earlier.at);
    samples
}

/// Return only intervals which could actually revoke a recorded drop.
/// Evidence is queried in one read-only batch and every timestamp stays f64.
fn candidate_rebound_ranges(samples: &[Observation]) -> Vec<(f64, f64)> {
    quota_cycle_rebound_ranges(
        &samples
            .iter()
            .map(|sample| (sample.at, sample.used))
            .collect::<Vec<_>>(),
    )
}

pub(crate) fn quota_cycle_rebound_ranges(samples: &[(f64, i32)]) -> Vec<(f64, f64)> {
    let mut drops = HashMap::<i32, Vec<usize>>::new();
    let mut ranges = Vec::new();
    let mut seen_ranges = HashSet::new();
    for index in 1..samples.len() {
        let previous = samples[index - 1];
        let item = samples[index];
        if previous.1 - item.1 >= 5 {
            drops.entry(previous.1).or_default().push(index);
        } else if item.1 - previous.1 >= 5 {
            let newest_matching_drop = ((item.1 - 3).max(0)..=(item.1 + 3).min(100))
                .filter_map(|baseline| drops.get(&baseline)?.last().copied())
                .max();
            if newest_matching_drop.is_some() {
                let range = (previous.0, item.0);
                if seen_ranges.insert((range.0.to_bits(), range.1.to_bits())) {
                    ranges.push(range);
                }
            }
        }
    }
    ranges
}

pub(crate) fn quota_cycle_reversals(
    samples: &[(f64, i32)],
    mut consumption: impl FnMut(f64, f64) -> ConsumptionEvidence,
) -> Vec<QuotaCycleReversal> {
    let mut drops = HashMap::<i32, Vec<usize>>::new();
    let mut reversals = Vec::new();
    for index in 1..samples.len() {
        let (previous_at, previous_used) = samples[index - 1];
        let (at, used) = samples[index];
        if previous_used - used >= 5 {
            drops.entry(previous_used).or_default().push(index);
        } else if used - previous_used >= 5 {
            let newest_matching = ((used - 3).max(0)..=(used + 3).min(100))
                .filter_map(|baseline| {
                    drops
                        .get(&baseline)
                        .and_then(|indices| indices.last().copied())
                        .map(|drop| (baseline, drop))
                })
                .max_by_key(|(_, drop)| *drop);
            if let Some((baseline, _)) = newest_matching {
                if consumption(previous_at, at) == ConsumptionEvidence::Absent {
                    if let Some(drop_index) = drops.get_mut(&baseline).and_then(Vec::pop) {
                        reversals.push(QuotaCycleReversal {
                            before_index: drop_index - 1,
                            drop_index,
                            return_index: index,
                        });
                    }
                }
            }
        }
    }
    reversals
}

fn project_with_evidence(
    samples: &[Observation],
    scope: &str,
    mut consumption: impl FnMut(f64, f64) -> ConsumptionEvidence,
) -> Projection {
    let values: Vec<_> = samples
        .iter()
        .map(|sample| (sample.at, sample.used))
        .collect();
    // Home-local exact events cannot be assigned to an account. Any known
    // token event, and all unknown coverage, preserve the drop.
    let reversals = quota_cycle_reversals(&values, |from, through| consumption(from, through));
    let revoked: HashSet<_> = reversals.iter().map(|item| item.drop_index).collect();
    let withdrawn = reversals.len();

    let Some(first) = samples.first().copied() else {
        return Projection {
            cycles: Vec::new(),
            withdrawn,
        };
    };
    let mut cycles = Vec::new();
    let mut period_first = first;
    let mut latest = first;
    let mut start: Option<f64> = None;

    for (index, item) in samples.iter().copied().enumerate().skip(1) {
        let previous = samples[index - 1];
        if previous.used - item.used >= 5 && !revoked.contains(&index) {
            cycles.push(make_cycle(
                period_first,
                latest,
                Some(item.at),
                start,
                scope,
                false,
            ));
            period_first = item;
            start = Some(item.at);
        }
        latest = item;
    }
    cycles.push(make_cycle(period_first, latest, None, start, scope, true));
    cycles.reverse();
    Projection { cycles, withdrawn }
}

fn make_cycle(
    first: Observation,
    latest: Observation,
    end: Option<f64>,
    start: Option<f64>,
    scope: &str,
    current: bool,
) -> QuotaCycle {
    let end_at = end.unwrap_or(latest.at);
    QuotaCycle {
        id: format!("observed-quota-cycle-v3|{scope}|{}", first.at),
        start_lower_unix: start,
        start_upper_unix: start,
        end_lower_unix: end_at,
        end_upper_unix: end_at,
        first_observed_unix: first.at,
        last_observed_unix: latest.at,
        expected_reset_unix: latest.reset,
        current,
        expired: false,
        early_end: end.is_some(),
        pending_reset: false,
        incomplete: start.is_none(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Case {
        name: String,
        now: f64,
        samples: Vec<(f64, i32, f64)>,
        absent_ranges: Vec<(f64, f64)>,
        present_ranges: Vec<(f64, f64)>,
        expected_starts: Vec<Option<f64>>,
        expected_withdrawn: usize,
    }

    fn covers(ranges: &[(f64, f64)], from: f64, through: f64) -> bool {
        ranges
            .iter()
            .any(|(start, end)| *start <= from && *end >= through)
    }

    #[test]
    fn shared_observed_cycles_v3_scenarios() {
        let cases: Vec<Case> = serde_json::from_str(include_str!(
            "../../../../../Tests/SharedFixtures/quota-observed-cycles-v3.json"
        ))
        .unwrap();
        assert_eq!(cases.len(), 16);
        for case in cases {
            let samples = case
                .samples
                .iter()
                .map(|(at, used, reset)| Observation {
                    at: *at,
                    used: *used,
                    reset: Some(*reset),
                })
                .collect();
            let samples = accepted(samples, case.now);
            let ranges = candidate_rebound_ranges(&samples);
            let evidence_cache: HashMap<_, _> = ranges
                .iter()
                .map(|(from, through)| {
                    let evidence = if covers(&case.present_ranges, *from, *through) {
                        ConsumptionEvidence::Present
                    } else if covers(&case.absent_ranges, *from, *through) {
                        ConsumptionEvidence::Absent
                    } else {
                        ConsumptionEvidence::Unknown
                    };
                    ((from.to_bits(), through.to_bits()), evidence)
                })
                .collect();
            let projection = project_with_evidence(&samples, "fixture", |from, through| {
                evidence_cache
                    .get(&(from.to_bits(), through.to_bits()))
                    .copied()
                    .unwrap_or(ConsumptionEvidence::Unknown)
            });
            let starts: Vec<_> = projection
                .cycles
                .iter()
                .map(|cycle| cycle.start_lower_unix)
                .collect();
            assert_eq!(starts, case.expected_starts, "{}", case.name);
            assert_eq!(
                projection.withdrawn, case.expected_withdrawn,
                "{}",
                case.name
            );
        }
    }

    #[test]
    fn rebound_requires_matching_baseline_and_absent_coverage() {
        let input = [
            Observation {
                at: 0.25,
                used: 70,
                reset: None,
            },
            Observation {
                at: 60.125,
                used: 0,
                reset: None,
            },
            Observation {
                at: 120.875,
                used: 70,
                reset: None,
            },
        ];
        let projection = project_with_evidence(&input, "scope", |from, through| {
            assert_eq!((from, through), (60.125, 120.875));
            ConsumptionEvidence::Unknown
        });
        assert_eq!(projection.withdrawn, 0);
        assert_eq!(projection.cycles.len(), 2);
        assert_eq!(projection.cycles[0].start_lower_unix, Some(60.125));
        assert_eq!(projection.cycles[1].expected_reset_unix, None);
    }

    #[test]
    fn database_filter_isolates_home_account_plan_and_limit() {
        let c = Connection::open_in_memory().unwrap();
        database::ensure_schema(&c).unwrap();
        for (home, account, plan, limit) in [
            ("/a", "account-a", "Pro", "codex"),
            ("/b", "account-a", "Pro", "codex"),
            ("/a", "account-b", "Pro", "codex"),
            ("/a", "account-a", "Plus", "codex"),
            ("/a", "account-a", "Pro", "other"),
        ] {
            c.execute("INSERT INTO quota_snapshots(created_at,account_key,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id,seven_day_used_percent,seven_day_resets_at) VALUES(100,'legacy','ok',1,?1,?2,?3,?4,30,1000)",rusqlite::params![home,account,plan,limit]).unwrap();
        }
        let identity = QuotaHistoryIdentity::from_canonical_parts(
            Path::new("/a"),
            Some("account-a"),
            "pro",
            "codex",
        )
        .unwrap();
        assert_eq!(
            database::query_stable_identity_rows(&c, &identity, None)
                .unwrap()
                .len(),
            1
        );
    }
}
