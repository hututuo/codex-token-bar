use super::*;

#[test]
fn dashboard_aggregate_version_ten_is_explicitly_rejected_after_quota_availability_change() {
    let old_cache = PersistentDashboardAggregateCache {
        version: 10,
        signature: DashboardScanSignature {
            codex_home: PathBuf::from("old-home"),
            local_date: "2026-07-10".into(),
            utc_offset_seconds: 8 * 60 * 60,
            session_files: Vec::new(),
        },
        snapshot: None,
        summary: TokenUsageSummary::default(),
    };

    assert_eq!(DASHBOARD_AGGREGATE_CACHE_VERSION, 11);
    assert_ne!(old_cache.version, DASHBOARD_AGGREGATE_CACHE_VERSION);
    let encoded = serde_json::to_vec(&old_cache).unwrap();
    assert!(decode_persistent_dashboard_aggregate(&encoded).is_none());
}
