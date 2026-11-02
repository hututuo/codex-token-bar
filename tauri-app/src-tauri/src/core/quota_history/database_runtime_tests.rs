use super::*;
use std::path::Path;

#[test]
fn legacy_tauri_cycle_projection_preserves_schema_identity_and_unknown_rows() {
    let connection = Connection::open_in_memory().unwrap();
    ensure_schema(&connection).unwrap();
    for column in [
        "five_hour_cycle_generation",
        "five_hour_reset_anchor",
        "seven_day_cycle_generation",
        "seven_day_reset_anchor",
    ] {
        connection
            .execute_batch(&format!("ALTER TABLE quota_snapshots DROP COLUMN {column}"))
            .unwrap();
    }
    let identity = QuotaHistoryIdentity::from_canonical_parts(
        Path::new("/fixture/home"),
        Some("fixture-account"),
        "pro",
        "codex",
    )
    .unwrap();
    connection.execute("INSERT INTO quota_snapshots(created_at,account_key,source,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id) VALUES(1,'display','tauri','ok',?1,?2,?3,?4,?5)",
        params![identity.version,identity.home_identity,identity.stable_account_key,identity.plan_type,identity.limit_id]).unwrap();
    connection.execute_batch("INSERT INTO quota_snapshots(created_at,account_key,source,status) VALUES(2,'unclaimed','tauri','ok'); INSERT INTO quota_snapshots(created_at,account_key,source,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id) SELECT 3,'other','tauri','ok',identity_version,home_identity,'different-account',identity_plan_type,identity_limit_id FROM quota_snapshots WHERE created_at=1;").unwrap();
    let changes = connection.total_changes();
    let schema: String = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE name='quota_snapshots'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(query_stable_identity_rows(&connection, &identity, None).is_err());
    let rows = rows_since_for_legacy_store(&connection, f64::MAX, &identity).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].source.as_deref(), Some("tauri"));
    assert_eq!(rows[0].five_hour_cycle_generation, None);
    assert_eq!(rows[0].five_hour_reset_anchor, Some(0));
    let raw_test_rows = rows_since_for_read_only_peer(&connection, f64::MAX, &identity).unwrap();
    assert_eq!(raw_test_rows.len(), rows.len(), "test route must preserve production account ownership");
    assert_eq!(raw_test_rows[0].source, rows[0].source);
    assert_eq!(raw_test_rows[0].stable_identity().as_ref(), Some(&identity));
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM quota_snapshots", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        3
    );
    assert_eq!(connection.total_changes(), changes);
    assert_eq!(
        connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE name='quota_snapshots'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
        schema
    );
}

#[test]
fn unsupported_legacy_shape_is_an_error_instead_of_empty_history() {
    let connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("CREATE TABLE quota_snapshots(unrelated INTEGER)")
        .unwrap();
    let identity = QuotaHistoryIdentity::from_canonical_parts(
        Path::new("/fixture/home"),
        Some("fixture-account"),
        "pro",
        "codex",
    )
    .unwrap();
    assert!(rows_since_for_legacy_store(&connection, f64::MAX, &identity).is_err());
}
