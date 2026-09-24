use super::*;
use super::quota_history_tests::bundle_with_plan;

struct FixtureDirectory(PathBuf);
impl Drop for FixtureDirectory {
    fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
}
fn fixture(name: &str) -> (FixtureDirectory, QuotaHistoryDatabase, QuotaHistoryIdentity) {
    let directory = FixtureDirectory(std::env::temp_dir().join(format!("quota-protection-{}-{}", std::process::id(), uuid::Uuid::new_v4())));
    std::fs::create_dir(&directory.0).unwrap();
    let database = QuotaHistoryDatabase { path: directory.0.join("quota.sqlite") };
    let identity = QuotaHistoryIdentity::from_canonical_parts(Path::new("/fixture/protection"), Some(name), "Plus", "codex").unwrap();
    (directory, database, identity)
}

fn input(used: f64, reset: i64) -> AccountQuotaBundle {
    bundle_with_plan("protection", "Plus", used, reset, 0.5, reset + 500_000)
}

#[test]
fn anomaly_filter_toggle_restores_raw_exhaustion_without_mutating_history() {
    let (_directory, database, identity) = fixture("sub:filter-toggle");
    let now = (now_unix() / 300.0).floor() * 300.0;
    let reset = (now + 10_800.0) as i64;
    let make = |used| bundle_with_plan("filter-toggle", "Plus", 0.1, reset, used, reset + 500_000);
    for (minutes, used) in [(20.0, 0.0), (15.0, 1.0), (5.0, 0.02)] {
        database.record_for_identity_at(Some(&identity), &make(used), now - minutes * 60.0).unwrap();
    }
    let rows = raw(&database, &identity, &make(0.02));
    let original: Vec<_> = rows.iter().map(|r| (r.created_at, r.seven_day_used_percent)).collect();
    let filtered = series::sanitized_rows_with_filter(rows.clone(), true);
    assert_eq!(filtered[1].seven_day_used_percent, None);
    let unfiltered = series::sanitized_rows_with_filter(rows.clone(), false);
    assert_eq!(unfiltered[1].seven_day_used_percent, Some(100));
    for enabled in [true, false, true, false] {
        let points = series::make_interval_history_with_filter(rows.clone(), 8, 300, now, enabled);
        assert_eq!(points.iter().any(|p| p.seven_day_remaining_percent == Some(0.0)), !enabled);
    }
    let filtered_daily = series::make_daily_history_with_filter(rows.clone(), now, true);
    let raw_daily = series::make_daily_history_with_filter(rows, now, false);
    let minimum = |daily: &std::collections::HashMap<String, series::DailyQuotaHistory>| {
        daily.values().filter_map(|day| day.seven_day_remaining_percent).reduce(f64::min).unwrap()
    };
    assert!(minimum(&raw_daily) < minimum(&filtered_daily));
    let reopened = QuotaHistoryDatabase { path: database.path.clone() };
    assert_eq!(raw(&reopened, &identity, &make(0.02)).iter().map(|r| (r.created_at, r.seven_day_used_percent)).collect::<Vec<_>>(), original);
}

#[test]
fn enabled_anomaly_filter_preserves_sustained_exhaustion() {
    let (_directory, database, identity) = fixture("sub:sustained-exhaustion");
    let now = now_unix();
    let reset = (now + 10_800.0) as i64;
    let make = |used| bundle_with_plan("sustained", "Plus", 0.1, reset, used, reset + 500_000);
    for (minutes, used) in [(20.0, 0.98), (15.0, 1.0), (5.0, 1.0)] {
        database.record_for_identity_at(Some(&identity), &make(used), now - minutes * 60.0).unwrap();
    }
    let rows = series::sanitized_rows(raw(&database, &identity, &make(1.0)));
    assert_eq!(rows[1].seven_day_used_percent, Some(100));
    assert_eq!(rows[2].seven_day_used_percent, Some(100));
}

fn raw(database: &QuotaHistoryDatabase, identity: &QuotaHistoryIdentity, bundle: &AccountQuotaBundle) -> Vec<QuotaHistoryRow> {
    let connection = database.open().unwrap();
    database::all_rows_for_row(&connection, &QuotaHistoryRow::from_bundle(identity, bundle, now_unix())).unwrap()
}

#[test]
fn raw_lower_samples_survive_restart_and_maintenance_then_confirm_same_cycle() {
    let (_directory, database, identity) = fixture("sub:correction");
    let at = now_unix() - 1000.0;
    let reset = (at + 20_000.0) as i64;
    let baseline = input(0.12, reset);
    let lower = input(0.08, reset);
    database.record_for_identity_at(Some(&identity), &baseline, at).unwrap();
    database.record_for_identity_at(Some(&identity), &lower, at + 10.0).unwrap();
    database.record_for_identity_at(Some(&identity), &lower, at + 160.0).unwrap();
    let reopened = QuotaHistoryDatabase { path: database.path.clone() };
    let pending = series::sanitized_rows(raw(&reopened, &identity, &lower));
    assert_eq!(pending.iter().map(|r| r.five_hour_used_percent).collect::<Vec<_>>(), vec![Some(12), Some(8), Some(8)]);
    reopened.record_for_identity_at(Some(&identity), &lower, at + 310.0).unwrap();
    let mut connection = reopened.open().unwrap();
    maintain_if_due(&mut connection, at + 2.0 * 86400.0).unwrap();
    let rows = raw(&reopened, &identity, &lower);
    assert_eq!(rows.iter().map(|r| r.five_hour_used_percent).collect::<Vec<_>>(), vec![Some(12), Some(8), Some(8), Some(8)]);
    assert!(rows.iter().all(|r| r.five_hour_cycle_generation == Some(0)));
    let accepted = series::sanitized_rows(rows);
    assert_eq!(accepted.last().unwrap().five_hour_used_percent, Some(8));
    assert!(accepted.iter().all(|r| r.seven_day_used_percent == Some(50)));
}

#[test]
fn equal_success_preserves_freshness_watermark_and_cached_or_late_responses_do_not_count() {
    let (_directory, database, identity) = fixture("sub:freshness");
    let at = now_unix() - 1000.0;
    let reset = (at + 20_000.0) as i64;
    let mut baseline = input(0.12, reset);
    baseline.updated_at = OffsetDateTime::from_unix_timestamp(at as i64).unwrap().format(&time::format_description::well_known::Rfc3339).unwrap();
    assert!(database.record_for_identity(Some(&identity), &baseline).unwrap());
    assert!(!database.record_for_identity(Some(&identity), &baseline).unwrap());
    assert!(database.record_for_identity_at(Some(&identity), &baseline, at + 20.0).unwrap());
    let reopened = QuotaHistoryDatabase { path: database.path.clone() };
    let lower = input(0.08, reset);
    assert!(!reopened.record_for_identity_at(Some(&identity), &lower, at + 15.0).unwrap());
    for offset in [30.0, 330.0] {
        assert!(reopened.record_for_identity_at(Some(&identity), &lower, at + offset).unwrap());
        assert!(!reopened.record_for_identity_at(Some(&identity), &lower, at + offset).unwrap());
    }
    assert_eq!(series::sanitized_rows(raw(&reopened, &identity, &lower)).last().unwrap().five_hour_used_percent, Some(8));
    reopened.record_for_identity_at(Some(&identity), &lower, at + 331.0).unwrap();
    assert_eq!(series::sanitized_rows(raw(&reopened, &identity, &lower)).last().unwrap().five_hour_used_percent, Some(8));
    assert_eq!(raw(&reopened, &identity, &lower).len(), 5);
}

#[test]
fn high_used_new_boundaries_are_independent_and_read_ranges_replay_prior_baselines() {
    let (_directory, database, identity) = fixture("sub:boundary");
    let at = now_unix() - 1000.0;
    let reset = (at + 20_000.0) as i64;
    let baseline = input(0.9, reset);
    database.record_for_identity_at(Some(&identity), &baseline, at).unwrap();
    let mut next = input(0.8, reset + 1801);
    next.quota.seven_day.resets_at_unix = baseline.quota.seven_day.resets_at_unix;
    database.record_for_identity_at(Some(&identity), &next, at + 600.0).unwrap();
    next.quota.seven_day.resets_at_unix = baseline.quota.seven_day.resets_at_unix.map(|v| v + 1801);
    next.quota.seven_day.used_percent = Some(1.0);
    database.record_for_identity_at(Some(&identity), &next, at + 700.0).unwrap();
    let rows = raw(&database, &identity, &next);
    assert_eq!((rows[1].five_hour_cycle_generation, rows[1].seven_day_cycle_generation), (Some(1), Some(0)));
    assert_eq!((rows[2].five_hour_cycle_generation, rows[2].seven_day_cycle_generation), (Some(1), Some(1)));
    let projected = series::sanitized_rows(rows);
    assert_eq!(projected[1].five_hour_used_percent, Some(80));
    assert_eq!(projected[2].seven_day_used_percent, Some(100));
    let connection = database.open().unwrap();
    let filter = QuotaHistoryRow::from_bundle(&identity, &next, now_unix());
    let narrow = database.history_rows_for_identity(&connection, &identity, &filter, 1.0).unwrap();
    let wide = database.history_rows_for_identity(&connection, &identity, &filter, 86400.0).unwrap();
    assert_eq!(narrow.len(), wide.len());
    assert_eq!(narrow.first().unwrap().created_at, at);
}

#[test]
fn duplicate_stored_observations_cannot_make_a_false_gap_or_confirm_a_drop() {
    let (_directory, _database, identity) = fixture("sub:duplicate");
    let baseline = QuotaHistoryRow::from_bundle(&identity, &input(0.12, 20_000), 10.0);
    let lower = QuotaHistoryRow::from_bundle(&identity, &input(0.08, 20_000), 20.0);
    let projected = series::sanitized_rows(vec![baseline.clone(), baseline, lower.clone(), lower]);
    assert_eq!(projected.len(), 2);
    assert_eq!(projected[0].five_hour_used_percent, Some(12));
    assert_eq!(projected[1].five_hour_used_percent, Some(8));
}

#[test]
fn retrospective_projection_removes_weekly_points_before_bins_and_restores_cycle() {
    let (_directory, database, identity) = fixture("sub:retrospective");
    let now = ((now_unix() / 300.0).floor() * 300.0) + 100.0;
    let reset = (now + 5000.0) as i64;
    let make = |offset: f64, seven: f64, shift: i64, five: f64| {
        let mut bundle = input(five, reset);
        bundle.quota.seven_day.used_percent = Some(seven);
        bundle.quota.seven_day.resets_at_unix = Some(reset + shift);
        (now + offset, bundle)
    };
    let (a, first) = make(-600.0,0.42,500_000,0.2);
    let (b, glitch) = make(-310.0,0.01,540_674,0.0);
    let (c, recovery) = make(-20.0,0.42,500_000,0.2);
    for (at, bundle) in [(a,&first),(b,&glitch),(c,&recovery)] {
        database.record_for_identity_at(Some(&identity), bundle, at).unwrap();
    }
    let reopened = QuotaHistoryDatabase { path: database.path.clone() };
    let rows = raw(&reopened,&identity,&recovery);
    assert_eq!(rows.iter().map(|r|r.seven_day_used_percent).collect::<Vec<_>>(), vec![Some(42),Some(1),Some(42)]);
    let projected = series::sanitized_rows(rows.clone());
    assert_eq!(projected[1].seven_day_used_percent,None);
    assert_eq!(projected[2].seven_day_cycle_generation,Some(0));
    let before = series::make_interval_history_at(rows.clone(),4,300,now-30.0);
    assert_eq!(before.last().unwrap().seven_day_remaining_percent,Some(0.99));
    let after = series::make_interval_history_at(rows,4,300,now);
    let middle = after.iter().find(|p| { let end=p.start_unix as f64+300.0; end>b && end<c }).unwrap();
    assert_eq!(middle.seven_day_remaining_percent,Some(0.58));
    assert_eq!(projected[1].five_hour_used_percent, Some(0));
    let sample_at = middle.start_unix as f64 + 300.0;
    let expected_five = 1.0 - 0.2 * (sample_at-b)/(c-b);
    assert!((middle.five_hour_remaining_percent.unwrap()-expected_five).abs()<0.000001);
}

#[test]
fn jump_alone_bridges_upward_remaining_even_across_a_new_cycle() {
    let (_directory, database, identity) = fixture("sub:bridge");
    let now = ((now_unix() / 300.0).floor() * 300.0) + 100.0;
    let reset = (now+5000.0) as i64;
    let mut latest = input(0.2,reset);
    for (offset,used,shift) in [(-600.0,0.80,500_000),(-310.0,0.01,540_000),(-20.0,0.60,540_000)] {
        latest.quota.seven_day.used_percent=Some(used);
        latest.quota.seven_day.resets_at_unix=Some(reset+shift);
        database.record_for_identity_at(Some(&identity),&latest,now+offset).unwrap();
    }
    let history=series::make_interval_history_at(raw(&database,&identity,&latest),4,300,now);
    let middle=history.iter().find(|p|{let end=p.start_unix as f64+300.0; end>now-310.0 && end<now-20.0}).unwrap();
    let sample_at=middle.start_unix as f64+300.0;
    let expected=0.2+0.2*(sample_at-(now-600.0))/580.0;
    assert!((middle.seven_day_remaining_percent.unwrap()-expected).abs()<0.000001);
}
