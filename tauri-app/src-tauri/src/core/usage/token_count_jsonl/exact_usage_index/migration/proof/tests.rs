use super::Schema11MigrationFacts;
use serde_json::Value;

// Fixed persisted shape from before protected_tables became optional metadata.
// Do not generate this fixture with the current serializer: that would hide a
// field rename, an added default, or a nested receipt shape change.
const LEGACY_FACTS: &str = r#"{
    "source_count": 1,
    "event_count": 2,
    "fingerprint_count": 3,
    "chunk_count": 4,
    "enrichment_count": 5,
    "catalog_count": 6,
    "catalog_size_total": 7,
    "aggregate_total": 8,
    "aggregate_bucket_total": 9,
    "global_aggregate": {"row_count": 10, "total_tokens": 11, "calls": 12, "input_tokens": 13, "cached_input_tokens": 14, "output_tokens": 15},
    "turn_aggregate": {"row_count": 16, "total_tokens": 17, "calls": 18, "input_tokens": 19, "cached_input_tokens": 20, "output_tokens": 21},
    "attribution_aggregate": {"row_count": 22, "total_tokens": 23, "calls": 24, "input_tokens": 25, "cached_input_tokens": 26, "output_tokens": 27},
    "session_metadata_count": 28,
    "session_metadata_title_bytes": 29,
    "session_metadata_updated_at_total": 30,
    "digests": {"sources": "sources-v1", "events": "events-v1", "fingerprints": "fingerprints-v2", "chunks": "chunks-v1", "enrichment": "enrichment-v1", "file_totals": "file-totals-v1", "file_buckets": "file-buckets-v1", "global_buckets": "global-buckets-v1", "turn_candidates": "turn-candidates-v1", "attribution": "attribution-v1", "session_catalog": "catalog-v1", "session_metadata": "metadata-v1"},
    "lineage": ["31", "32", "33", null, "35", null, "37", "38", "39", "40", "epoch", null, "integrity"]
}"#;

#[test]
fn legacy_migration_facts_preserve_persisted_fields_and_default_only_protection() {
    let legacy: Value = serde_json::from_str(LEGACY_FACTS).unwrap();
    let facts: Schema11MigrationFacts = serde_json::from_str(LEGACY_FACTS).unwrap();
    assert!(facts.protected_tables.is_empty());
    let mut expected = legacy.clone();
    expected["protected_tables"] = serde_json::json!({});
    assert_eq!(serde_json::to_value(&facts).unwrap(), expected);

    for required in legacy.as_object().unwrap().keys() {
        let mut incomplete = legacy.clone();
        incomplete.as_object_mut().unwrap().remove(required);
        assert!(
            serde_json::from_value::<Schema11MigrationFacts>(incomplete).is_err(),
            "missing persisted fact must not become a successful default: {required}"
        );
    }
    let mut invalid = legacy;
    invalid["protected_tables"] = Value::Null;
    assert!(serde_json::from_value::<Schema11MigrationFacts>(invalid).is_err());
}

#[test]
fn migration_facts_allow_added_protection_but_reject_changed_or_missing_old_evidence() {
    let legacy: Schema11MigrationFacts = serde_json::from_str(LEGACY_FACTS).unwrap();
    let mut expected = legacy.clone();
    expected.protected_tables.insert("usage_ledger_bindings".into(), "retained-binding-digest".into());
    expected.protected_tables.insert("retained_usage_events".into(), "retained-events-digest".into());
    let mut actual = expected.clone();
    actual.protected_tables.insert("usage_ledger_new_evidence".into(), "new-table-digest".into());
    assert!(actual.preserves(&legacy), "old receipts lack the optional protection list");
    assert!(actual.preserves(&expected), "newly registered protection is additive");
    assert!(!expected.preserves(&actual), "coverage is directional");
    let reopened: Schema11MigrationFacts = serde_json::from_str(&serde_json::to_string(&actual).unwrap()).unwrap();
    assert_eq!(reopened, actual);
    assert!(reopened.preserves(&expected));

    let mut changed = actual.clone();
    changed.protected_tables.insert("usage_ledger_bindings".into(), "tampered".into());
    assert!(!changed.preserves(&expected));
    let mut missing = actual.clone();
    missing.protected_tables.remove("retained_usage_events");
    assert!(!missing.preserves(&expected));

    let mut same_count_corruption = actual.clone();
    same_count_corruption.digests.events = "different-content-with-the-same-count".into();
    assert_eq!(same_count_corruption.event_count, expected.event_count);
    assert!(!same_count_corruption.preserves(&expected));
    let mut different_lineage = actual;
    different_lineage.lineage[0] = Some("other-revision".into());
    assert!(!different_lineage.preserves(&expected));
}
