use super::*;

#[test]
fn dashboard_aggregate_version_thirteen_is_rejected_by_the_current_cache_schema() {
    let old_cache = PersistentDashboardAggregateCache {
        version: 13,
        signature: DashboardScanSignature {
            codex_home: PathBuf::from("old-home"),
            local_date: "2026-07-10".into(),
            utc_offset_seconds: 8 * 60 * 60,
            index_revision: 0,
            aggregate_boundary_unix: 0,
        },
        snapshot: None,
        summary: TokenUsageSummary::default(),
    };

    assert_eq!(DASHBOARD_AGGREGATE_CACHE_VERSION, 20);
    assert_ne!(old_cache.version, DASHBOARD_AGGREGATE_CACHE_VERSION);
    let encoded = serde_json::to_vec(&old_cache).unwrap();
    assert!(decode_persistent_dashboard_aggregate(&encoded).is_none());
}

#[test]
fn dashboard_aggregate_v19_is_rejected_after_event_time_timezone_projection_upgrade() {
    let encoded = serde_json::to_vec(&serde_json::json!({
        "version": 19,
        "canonicalHome": "/tmp/legacy-home"
    }))
    .unwrap();

    assert!(decode_persistent_dashboard_aggregate(&encoded).is_none());
}
