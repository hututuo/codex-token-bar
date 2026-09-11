//! Read-only observed quota periods. Local chart generations are not reset evidence.
use super::*;
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaCycle {
    pub id: String,
    pub start_lower_unix: Option<i64>,
    pub start_upper_unix: Option<i64>,
    pub end_lower_unix: i64,
    pub end_upper_unix: i64,
    pub first_observed_unix: i64,
    pub last_observed_unix: i64,
    pub expected_reset_unix: i64,
    pub current: bool,
    pub expired: bool,
    pub early_end: bool,
    pub pending_reset: bool,
    pub incomplete: bool,
}

/// This path never opens a writer or claims legacy rows. Missing historical
/// stable identity cannot be reconstructed from today's account display name.
pub(crate) fn read(identity: &QuotaHistoryIdentity) -> Result<Vec<QuotaCycle>, String> {
    let mut rows = Vec::new();
    for (path, optional) in [(app_paths::quota_history_database_path(), false),
        (app_paths::legacy_shared_quota_history_database_path(), true)] {
        let Some(path) = path.filter(|p| p.exists()) else { continue; };
        let result = sqlite::open_read_only(&path, Duration::from_secs(2))
            .and_then(|connection| database::query_stable_identity_rows(&connection, identity, None));
        match result {
            Ok(found) => rows.extend(found),
            Err(_) if optional => {},
            Err(error) => return Err(format!("读取周期历史失败：{error}")),
        }
    }
    let rows = series::sanitized_rows(merge_history_rows(rows, Vec::new()));
    let samples: Vec<_> = rows.iter().filter_map(|r| Some(Observation {
        at: r.created_at.floor() as i64,
        upper: r.created_at.ceil() as i64,
        used: r.seven_day_used_percent?,
        reset: r.seven_day_resets_at.filter(|value| value.is_finite())?.floor() as i64,
    })).collect();
    Ok(project(&samples, &format!("{}|{}|{}", identity.attribution_identity().scope_key,
        identity.plan_type, identity.limit_id), now_unix() as i64))
}

#[derive(Clone, Copy)]
struct Observation { at: i64, upper: i64, used: i32, reset: i64 }
fn project(samples: &[Observation], scope: &str, now: i64) -> Vec<QuotaCycle> {
    let samples: Vec<_> = samples.iter().copied().filter(|s| s.at <= now && s.reset > s.at && (0..=100).contains(&s.used)).collect();
    let Some(first) = samples.first() else { return Vec::new(); };
    let make = |s: &Observation, start: Option<(i64,i64)>| QuotaCycle {
        id: format!("observed-quota-cycle-v1|{scope}|{}", s.at),
        start_lower_unix: start.map(|s|s.0), start_upper_unix: start.map(|s|s.1),
        end_lower_unix: s.reset, end_upper_unix: s.reset,
        first_observed_unix: s.upper, last_observed_unix: s.at, expected_reset_unix: s.reset,
        current: true, expired: false, early_end: false, pending_reset: false, incomplete: start.is_none() || start.is_some_and(|s|s.0!=s.1),
    };
    let mut cycles = vec![make(first, None)];
    let mut accepted = *first;
    let mut latest_at = first.at;
    for (i, sample) in samples.iter().enumerate().skip(1) {
        if sample.at <= latest_at { continue; }
        latest_at = sample.at;
        let current = cycles.last_mut().unwrap();
        let advanced = sample.reset - current.expected_reset_unix > 900;
        let natural = advanced && accepted.at <= current.expected_reset_unix && sample.at >= current.expected_reset_unix;
        // Two apps can repeat one provider reading seconds apart. Require a
        // near-empty period sustained across a minute, not just any decrease.
        let mut confirmed = false;
        if advanced && sample.at < current.expected_reset_unix && accepted.used - sample.used >= 5 {
            for next in samples.iter().skip(i + 1) {
                if next.at <= sample.at { continue; }
                if (next.reset - sample.reset).abs() > 5 || next.used < sample.used || next.used >= accepted.used { break; }
                if next.at - sample.at >= 60 && next.used > sample.used { confirmed = true; break; }
            }
        }
        if confirmed {
            let mut prior = *sample;
            for next in samples.iter().skip(i+1) {
                if next.at-sample.at > 5400 { break; }
                if (next.used-accepted.used).abs() <= 3 && next.used-prior.used >= 5 {
                    confirmed=false; break;
                }
                prior=*next;
            }
        }
        let early = advanced && sample.at < current.expected_reset_unix && confirmed;
        if natural || early {
            let boundary = if natural { (current.expected_reset_unix,current.expected_reset_unix) }
                else { (accepted.at,sample.upper) };
            current.end_lower_unix = boundary.0;
            current.end_upper_unix = boundary.1;
            current.current = false;
            current.early_end = early;
            current.pending_reset = false;
            current.incomplete |= early;
            // A long gap can hide entire cycles. Retain the next observed
            // fragment with unknown start instead of inventing those periods.
            let start = (sample.at - accepted.at < 604800).then_some(boundary);
            cycles.push(make(sample, start));
            accepted = *sample;
        } else if (sample.reset - current.expected_reset_unix).abs() > 5 {
            current.pending_reset = true;
            current.incomplete = true;
            current.end_lower_unix = current.end_lower_unix.min(accepted.at);
            current.end_upper_unix = sample.upper;
        } else if (sample.reset - current.expected_reset_unix).abs() <= 5 {
            // Returning to the accepted reset disproves an unconfirmed change.
            current.pending_reset = false;
            current.end_lower_unix = current.expected_reset_unix;
            current.end_upper_unix = current.expected_reset_unix;
            accepted = *sample;
        }
        cycles.last_mut().unwrap().last_observed_unix = sample.at;
    }
    if let Some(last) = cycles.last_mut() {
        if now >= last.expected_reset_unix {
            last.current = false;
            last.expired = true;
            last.incomplete = true;
            last.end_lower_unix = accepted.at.min(last.expected_reset_unix);
            last.end_upper_unix = last.expected_reset_unix;
        }
    }
    cycles.reverse();
    cycles
}

#[cfg(test)]
mod tests {
    use super::*;
    fn s(at:i64,used:i32,reset:i64)->Observation { Observation{at,upper:at,used,reset} }
    #[test] fn offline_replenishment_and_late_rebound() {
        let c=project(&[s(100,93,400000),s(16600,9,700000),s(16800,10,700000),s(17600,11,700000)],"a",18000);
        assert_eq!(c.len(),2); assert!(c[1].early_end);
        assert_eq!((c[0].start_lower_unix,c[0].start_upper_unix),(Some(100),Some(16600)));
        let c=project(&[s(100,50,10000),s(160,30,20000),s(280,31,20000),s(2500,50,20000),s(2560,51,20000)],"a",2600);
        assert_eq!(c.len(),1);
    }
    #[test] fn unknown_start_and_jitter_do_not_invent_cycles() {
        let c=project(&[s(100,30,1000),s(200,31,1003),s(300,32,1001)],"a",500);
        assert_eq!(c.len(),1); assert_eq!(c[0].start_lower_unix,None); assert!(c[0].incomplete);
    }
    #[test] fn natural_and_early_have_different_boundary_precision() {
        let c=project(&[s(100,60,1000),s(1100,2,700000),s(1200,3,700000)],"a",1300);
        assert_eq!(c.len(),2); assert_eq!(c[0].start_lower_unix,Some(1000)); assert!(!c[1].early_end);
        let c=project(&[s(100,60,100000),s(200,1,700000),s(300,2,700001)],"a",400);
        assert_eq!(c.len(),2); assert_eq!(c[0].start_lower_unix,Some(100)); assert_eq!(c[0].start_upper_unix,Some(200)); assert!(c[1].early_end);
    }
    #[test] fn reset_change_alone_or_unconfirmed_drop_is_pending() {
        for used in [1,60] { let c=project(&[s(100,60,100000),s(200,used,700000)],"a",300);
            assert_eq!(c.len(),1); assert!(c[0].pending_reset); assert_eq!(c[0].end_lower_unix,100); }
    }
    #[test] fn long_gap_does_not_fill_missing_periods_and_replay_is_stable() {
        let input=[s(100,60,1000),s(1000000,2,1600000)];
        let c=project(&input,"a",1000010); assert_eq!(c.len(),2); assert_eq!(c[0].start_upper_unix,None);
        assert_eq!(c[0].id,project(&input,"a",1000020)[0].id);
        assert_ne!(c[0].id,project(&input,"b",1000020)[0].id);
    }
    #[test] fn expired_without_next_observation_is_not_an_exact_end() {
        let c=project(&[s(100,30,1000),s(200,35,1000)],"a",2000);
        assert!(!c[0].current); assert!(c[0].expired);
        assert_eq!((c[0].end_lower_unix,c[0].end_upper_unix),(200,1000));
    }
    #[test] fn corrections_do_not_advance_accepted_baseline() {
        for reset in [99900,100300,102000] {
            let c=project(&[s(100,60,100000),s(200,61,reset),s(300,1,700000),s(400,2,700000)],"a",500);
            assert_eq!(c.len(),2); assert_eq!(c[1].end_lower_unix,100);
            assert_eq!(c[0].start_upper_unix,Some(300));
        }
    }
    #[test] fn rebound_cannot_confirm_early_reset() {
        let c=project(&[s(100,60,100000),s(200,1,700000),s(300,60,700000)],"a",400);
        assert_eq!(c.len(),1); assert!(c[0].pending_reset); assert_eq!(c[0].end_lower_unix,100);
    }

    #[test] fn weak_drops_and_cross_app_echoes_do_not_confirm_reset() {
        for samples in [
            vec![s(100,60,100000),s(200,59,700000),s(300,59,700000)],
            vec![s(100,60,100000),s(200,0,700000),s(203,0,700000)],
            vec![s(100,60,100000),s(200,0,700000),s(203,0,700000),s(250,60,100000)],
        ] { assert_eq!(project(&samples,"a",500).len(),1); }
        assert_eq!(project(&[s(100,60,100000),s(200,0,700000),s(203,0,700000),s(260,1,700000)],"a",500).len(),2);
    }

    #[test] fn database_filter_isolates_home_account_plan_and_limit() {
        let c=Connection::open_in_memory().unwrap();
        database::ensure_schema(&c).unwrap();
        for (home,account,plan,limit) in [("/a","account-a","Pro","codex"),("/b","account-a","Pro","codex"),
            ("/a","account-b","Pro","codex"),("/a","account-a","Plus","codex"),("/a","account-a","Pro","other")] {
            c.execute("INSERT INTO quota_snapshots(created_at,account_key,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id,seven_day_used_percent,seven_day_resets_at) VALUES(100,'legacy','ok',1,?1,?2,?3,?4,30,1000)",rusqlite::params![home,account,plan,limit]).unwrap();
        }
        let identity=QuotaHistoryIdentity::from_canonical_parts(Path::new("/a"),Some("account-a"),"pro","codex").unwrap();
        assert_eq!(database::query_stable_identity_rows(&c,&identity,None).unwrap().len(),1);
    }

}
