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
    assert!(
        rows_since_for_read_only_peer(&connection, f64::MAX, &identity)
            .unwrap()
            .is_empty()
    );
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

struct CyclelessQuotaDatabase(std::path::PathBuf);

impl CyclelessQuotaDatabase {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!(
            "quota-published-rows-{}.sqlite",
            uuid::Uuid::new_v4()
        )))
    }

    fn create_old_schema(&self) -> Connection {
        let connection = Connection::open(&self.0).unwrap();
        ensure_schema(&connection).unwrap();
        for column in [
            "five_hour_cycle_generation",
            "five_hour_reset_anchor",
            "seven_day_cycle_generation",
            "seven_day_reset_anchor",
        ] {
            connection
                .execute_batch(&format!(
                    "ALTER TABLE quota_snapshots DROP COLUMN {column}"
                ))
                .unwrap();
        }
        connection
    }

    fn create_current_schema(&self) -> Connection {
        let connection = Connection::open(&self.0).unwrap();
        ensure_schema(&connection).unwrap();
        connection
    }

    fn open_read_only(&self) -> Connection {
        crate::core::sqlite::open_read_only(&self.0, std::time::Duration::from_secs(2)).unwrap()
    }
}

impl Drop for CyclelessQuotaDatabase {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let mut name = self.0.as_os_str().to_os_string();
            name.push(suffix);
            let _ = std::fs::remove_file(std::path::PathBuf::from(name));
        }
    }
}

fn published_test_identity(account_key: &str) -> QuotaHistoryIdentity {
    QuotaHistoryIdentity::from_canonical_parts(
        Path::new("/fixture/published-home"),
        Some(account_key),
        "pro",
        "codex",
    )
    .unwrap()
}

fn published_test_filter(
    identity: &QuotaHistoryIdentity,
    account_name: &str,
) -> QuotaHistoryRow {
    QuotaHistoryRow {
        created_at: 0.0,
        account_key: account_name.to_string(),
        plan_type: Some(identity.plan_type.clone()),
        limit_name: Some(identity.limit_id.clone()),
        account_name: Some(account_name.to_string()),
        source: Some("tauri".into()),
        five_hour_used_percent: None,
        five_hour_resets_at: None,
        five_hour_cycle_generation: None,
        five_hour_reset_anchor: None,
        seven_day_used_percent: None,
        seven_day_resets_at: None,
        seven_day_cycle_generation: None,
        seven_day_reset_anchor: None,
        status: "ok".into(),
        identity_version: Some(identity.version),
        home_identity: Some(identity.home_identity.clone()),
        stable_account_key: Some(identity.stable_account_key.clone()),
        identity_plan_type: Some(identity.plan_type.clone()),
        identity_limit_id: Some(identity.limit_id.clone()),
    }
}

fn insert_published_test_row(
    connection: &Connection,
    identity: &QuotaHistoryIdentity,
    account_name: &str,
    created_at: f64,
) {
    connection
        .execute(
            "INSERT INTO quota_snapshots (
                 created_at,account_key,plan_type,limit_name,account_name,source,
                 five_hour_used_percent,five_hour_resets_at,
                 seven_day_used_percent,seven_day_resets_at,status,
                 identity_version,home_identity,stable_account_key,
                 identity_plan_type,identity_limit_id
             ) VALUES (?1,?2,?3,?4,?5,'tauri',21,?6,42,?7,'ok',?8,?9,?10,?11,?12)",
            params![
                created_at,
                account_name,
                identity.plan_type,
                identity.limit_id,
                account_name,
                created_at + 1000.0,
                created_at + 2000.0,
                identity.version,
                identity.home_identity,
                identity.stable_account_key,
                identity.plan_type,
                identity.limit_id,
            ],
        )
        .unwrap();
}

fn insert_published_test_legacy_row(
    connection: &Connection,
    identity: &QuotaHistoryIdentity,
    account_name: &str,
    created_at: f64,
) {
    connection
        .execute(
            "INSERT INTO quota_snapshots (
                 created_at,account_key,plan_type,limit_name,account_name,source,
                 five_hour_used_percent,five_hour_resets_at,
                 seven_day_used_percent,seven_day_resets_at,status
             ) VALUES (?1,?2,?3,?4,?5,'tauri',55,?6,66,?7,'legacy')",
            params![
                created_at,
                account_name,
                identity.plan_type,
                identity.limit_id,
                account_name,
                created_at + 1000.0,
                created_at + 2000.0,
            ],
        )
        .unwrap();
}

fn insert_published_test_claim(
    connection: &Connection,
    identity: &QuotaHistoryIdentity,
    account_name: &str,
    last_seen_at: f64,
) {
    connection
        .execute(
            "INSERT INTO quota_history_legacy_claims (
                 legacy_account_name,legacy_plan_type,legacy_limit_id,bridge_kind,
                 owner_identity_version,owner_home_identity,owner_stable_account_key,
                 owner_plan_type,owner_limit_id,state,claimed_at,last_seen_at
             ) VALUES (?1,?2,?3,'exact-plan',?4,?5,?6,?7,?8,'claimed',11.0,?9)",
            params![
                account_name,
                identity.plan_type,
                identity.limit_id,
                identity.version,
                identity.home_identity,
                identity.stable_account_key,
                identity.plan_type,
                identity.limit_id,
                last_seen_at,
            ],
        )
        .unwrap();
}

#[derive(Debug, PartialEq)]
struct PublishedReadRawProof {
    schema_version: i64,
    schema: Vec<(String, String, Option<String>)>,
    snapshot_count: i64,
    snapshots: Vec<Vec<rusqlite::types::Value>>,
    claim_count: i64,
    claims: Vec<Vec<rusqlite::types::Value>>,
}

fn published_read_raw_proof(connection: &Connection) -> rusqlite::Result<PublishedReadRawProof> {
    fn table_rows(
        connection: &Connection,
        table: &str,
    ) -> rusqlite::Result<Vec<Vec<rusqlite::types::Value>>> {
        let mut statement = connection.prepare(&format!("SELECT * FROM {table} ORDER BY rowid"))?;
        let column_count = statement.column_count();
        let rows = statement
            .query_map([], |row| {
                (0..column_count)
                    .map(|column| row.get::<_, rusqlite::types::Value>(column))
                    .collect::<rusqlite::Result<Vec<_>>>()
            })?
            .collect();
        rows
    }

    let schema_version = connection.query_row("PRAGMA schema_version", [], |row| row.get(0))?;
    let mut schema_statement = connection.prepare(
        "SELECT type,name,sql FROM sqlite_master \
         WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY type,name",
    )?;
    let schema = schema_statement
        .query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let snapshot_count = connection.query_row("SELECT COUNT(*) FROM quota_snapshots", [], |row| row.get(0))?;
    let claim_count = connection.query_row("SELECT COUNT(*) FROM quota_history_legacy_claims", [], |row| row.get(0))?;
    Ok(PublishedReadRawProof {
        schema_version,
        schema,
        snapshot_count,
        snapshots: table_rows(connection, "quota_snapshots")?,
        claim_count,
        claims: table_rows(connection, "quota_history_legacy_claims")?,
    })
}

#[test]
fn published_rows_reads_cycleless_stable_and_claimed_legacy_rows_without_mutation() {
    let database = CyclelessQuotaDatabase::new();
    let identity = published_test_identity("current-account");
    let account_name = "Shared Display";
    let writer = database.create_old_schema();
    insert_published_test_row(&writer, &identity, account_name, 20.0);
    insert_published_test_legacy_row(&writer, &identity, account_name, 10.0);
    insert_published_test_claim(&writer, &identity, account_name, 1234.5);
    drop(writer);

    let connection = database.open_read_only();
    let before = published_read_raw_proof(&connection).unwrap();
    let changes_before = connection.total_changes();
    let mut columns_statement = connection
        .prepare("PRAGMA table_info(quota_snapshots)")
        .unwrap();
    let cycle_columns = columns_statement
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    for missing in [
        "five_hour_cycle_generation",
        "five_hour_reset_anchor",
        "seven_day_cycle_generation",
        "seven_day_reset_anchor",
    ] {
        assert!(!cycle_columns.iter().any(|column| column == missing));
    }

    let rows = published_rows_for_row(
        &connection,
        &published_test_filter(&identity, account_name),
    )
    .unwrap();

    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].created_at, 10.0);
    assert_eq!(rows[1].created_at, 20.0);
    assert_eq!(rows[1].stable_identity().as_ref(), Some(&identity));
    for row in &rows {
        assert_eq!(row.five_hour_cycle_generation, None);
        assert_eq!(row.five_hour_reset_anchor, Some(0));
        assert_eq!(row.seven_day_cycle_generation, None);
        assert_eq!(row.seven_day_reset_anchor, Some(0));
    }
    let last_seen: f64 = connection
        .query_row(
            "SELECT last_seen_at FROM quota_history_legacy_claims \
             WHERE legacy_account_name=?1 AND legacy_plan_type=?2 AND legacy_limit_id=?3",
            params![account_name, identity.plan_type, identity.limit_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(last_seen, 1234.5);
    assert_eq!(published_read_raw_proof(&connection).unwrap(), before);
    assert_eq!(connection.total_changes(), changes_before);
}

#[test]
fn published_rows_never_guesses_unclaimed_legacy_rows_or_returns_foreign_identity() {
    let database = CyclelessQuotaDatabase::new();
    let identity = published_test_identity("current-account");
    let foreign = published_test_identity("different-account");
    let account_name = "Shared Display";
    let writer = database.create_old_schema();
    insert_published_test_row(&writer, &identity, account_name, 20.0);
    insert_published_test_row(&writer, &foreign, account_name, 30.0);
    insert_published_test_legacy_row(&writer, &identity, account_name, 10.0);
    drop(writer);

    let connection = database.open_read_only();
    let before = published_read_raw_proof(&connection).unwrap();
    let changes_before = connection.total_changes();
    let rows = published_rows_for_row(
        &connection,
        &published_test_filter(&identity, account_name),
    )
    .unwrap();

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].created_at, 20.0);
    assert_eq!(rows[0].stable_identity().as_ref(), Some(&identity));
    assert!(rows.iter().all(|row| row.stable_identity().as_ref() != Some(&foreign)));
    assert_eq!(before.claim_count, 0);
    assert_eq!(published_read_raw_proof(&connection).unwrap(), before);
    assert_eq!(connection.total_changes(), changes_before);
}

#[test]
fn all_rows_for_row_keeps_its_legacy_claim_write_semantics() {
    let database = CyclelessQuotaDatabase::new();
    let identity = published_test_identity("current-account");
    let account_name = "Shared Display";
    let writer = database.create_current_schema();
    insert_published_test_row(&writer, &identity, account_name, 20.0);
    insert_published_test_legacy_row(&writer, &identity, account_name, 10.0);
    drop(writer);

    let connection = database.open_read_only();
    let before = published_read_raw_proof(&connection).unwrap();
    let rows = published_rows_for_row(
        &connection,
        &published_test_filter(&identity, account_name),
    )
    .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(published_read_raw_proof(&connection).unwrap(), before);
    drop(connection);

    let writer = Connection::open(&database.0).unwrap();
    let rows = all_rows_for_row(
        &writer,
        &published_test_filter(&identity, account_name),
    )
    .unwrap();
    assert_eq!(rows.len(), 2);
    let state: String = writer
        .query_row(
            "SELECT state FROM quota_history_legacy_claims \
             WHERE legacy_account_name=?1 AND legacy_plan_type=?2 AND legacy_limit_id=?3",
            params![account_name, identity.plan_type, identity.limit_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "claimed");
}
