//! One-time migration of completed-body trend data from business container A
//! into the shared multi-client usage database B.

use super::BodySpeedTrendStore;
use rusqlite::{params, types::ValueRef, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

const BODY_TABLES: [&str; 4] = [
    "speed_trend_meta",
    "speed_samples",
    "speed_sample_ids",
    "speed_5m",
];
const RECEIPT_TABLE: &str = "speed_migration_receipts";

#[derive(Clone, Debug, Eq, PartialEq)]
struct TableProof {
    rows_digest: String,
    counts: BTreeMap<String, i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
struct MigrationReceipt {
    source_identity: String,
    source_digest: String,
    rows_digest: String,
    meta_count: i64,
    sample_count: i64,
    id_count: i64,
    aggregate_count: i64,
    backup_path: String,
    completed_at: f64,
}

#[cfg(not(test))]
pub(super) fn body_speed_namespace_spec(
    legacy_path: &Path,
) -> Result<(String, crate::core::business_store_container::StoreSpec), String> {
    let source_identity = standardized_source_identity(legacy_path)?;
    let logical_path = format!(
        "body-speed/{}",
        legacy_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| "completed-body database filename is not valid UTF-8".to_owned())?
    );
    let spec = crate::core::business_store_container::StoreSpec::new(
        "body-speed",
        source_identity.clone(),
        logical_path,
    )
    .map_err(|error| error.to_string())?;
    Ok((source_identity, spec))
}

#[cfg(not(test))]
pub(super) fn migrate_body_speed_to_shared(
    legacy_path: &Path,
    shared_path: &Path,
) -> rusqlite::Result<()> {
    let (source_identity, spec) = body_speed_namespace_spec(legacy_path).map_err(to_sql_error)?;
    // Preserve SQLite BUSY/LOCKED codes for the host's bounded retry policy.
    crate::core::multi_client_usage::initialize_usage_database_at(shared_path)?;
    if verify_shared_receipt(shared_path, &spec.prefix, &source_identity)? {
        return Ok(());
    }

    // Materialize A once if an older physical source still exists. The original
    // source remains untouched; export_store_to_path creates the retained B-side
    // snapshot before any write is made to B.
    let a_identity = legacy_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| rusqlite::Error::InvalidPath(legacy_path.to_path_buf()))?;
    let a_logical_path = format!("body-speed/{a_identity}");
    // Read only the namespace already admitted by the startup migration.
    // A fresh source must not register an empty module and contend for A's
    // writer lock merely to start telemetry in B.
    let source_has_tables = if let Some(a_store) =
        crate::core::business_store_route::open_registered_store(
            "body-speed",
            a_identity,
            &a_logical_path,
        )
        .map_err(to_sql_error)?
    {
        BODY_TABLES.iter().try_fold(false, |found, table| {
            a_store
                .has_logical_object(table)
                .map(|present| found || present)
        })?
    } else {
        // An unadmitted physical legacy source is evidence requiring repair,
        // not permission to replace its history with an empty destination.
        if legacy_path.exists() {
            return Err(rusqlite::Error::InvalidQuery);
        }
        false
    };

    let backup_path = retained_backup_path(shared_path, &source_identity)?;
    if backup_path.exists() {
        return Err(rusqlite::Error::InvalidPath(backup_path));
    }
    if source_has_tables {
        crate::core::business_store_route::export_store_to_path(
            a_identity,
            "body-speed",
            &a_logical_path,
            &backup_path,
        )
        .map_err(to_sql_error)?;
    } else {
        let empty_snapshot =
            crate::core::business_store_connection::StoreConnection::open(&backup_path)?;
        BodySpeedTrendStore::create_schema(&empty_snapshot)?;
        drop(empty_snapshot);
    }
    set_private_backup_permissions(&backup_path)?;
    sync_backup_snapshot(&backup_path)?;

    let snapshot = Connection::open_with_flags(
        &backup_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    validate_body_schema(&snapshot, "")?;
    let source_proof = table_proof(&snapshot, Some(""))?;
    let source_digest = source_digest(&source_identity, &source_proof.rows_digest);

    if let Some(parent) = shared_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    }
    let mut target = crate::core::business_store_connection::StoreConnection::open_scoped(
        shared_path,
        spec.id.clone(),
        spec.prefix.clone(),
        body_speed_object_names(),
    )?;
    target.busy_timeout(std::time::Duration::from_secs(3))?;
    let transaction = target.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;

    // Another process may have completed this source while the immutable A
    // snapshot was being made. Recheck under B's writer lock before copying.
    transaction.execute_batch(&create_receipt_sql())?;
    if read_scoped_receipt(&transaction, &source_identity)?.is_some() {
        drop(transaction);
        return if verify_shared_receipt(shared_path, &spec.prefix, &source_identity)? {
            Ok(())
        } else {
            Err(rusqlite::Error::InvalidQuery)
        };
    }

    BodySpeedTrendStore::create_schema_tables(&transaction)?;
    if scoped_body_row_count(&transaction)? != 0 {
        return Err(rusqlite::Error::InvalidQuery);
    }
    copy_snapshot_tables(&snapshot, &transaction)?;
    BodySpeedTrendStore::create_schema(&transaction)?;

    let target_proof = table_proof(&transaction, None)?;
    if target_proof != source_proof {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let completed_at = unix_now();
    let receipt = MigrationReceipt {
        source_identity: source_identity.clone(),
        source_digest,
        rows_digest: source_proof.rows_digest.clone(),
        meta_count: count_for(&source_proof, "speed_trend_meta")?,
        sample_count: count_for(&source_proof, "speed_samples")?,
        id_count: count_for(&source_proof, "speed_sample_ids")?,
        aggregate_count: count_for(&source_proof, "speed_5m")?,
        backup_path: backup_path.to_string_lossy().into_owned(),
        completed_at,
    };
    transaction.execute(
        "INSERT INTO speed_migration_receipts(\
             source_identity, source_digest, rows_digest, meta_count, sample_count, id_count, \
             aggregate_count, backup_path, completed_at\
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            receipt.source_identity,
            receipt.source_digest,
            receipt.rows_digest,
            receipt.meta_count,
            receipt.sample_count,
            receipt.id_count,
            receipt.aggregate_count,
            receipt.backup_path,
            receipt.completed_at,
        ],
    )?;
    transaction.commit()?;

    if verify_shared_receipt(shared_path, &spec.prefix, &source_identity)? {
        Ok(())
    } else {
        Err(rusqlite::Error::InvalidQuery)
    }
}

#[cfg(not(test))]
fn verify_shared_receipt(
    shared_path: &Path,
    prefix: &str,
    source_identity: &str,
) -> rusqlite::Result<bool> {
    if !shared_path.exists() {
        return Ok(false);
    }
    let target = Connection::open_with_flags(
        shared_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    target.busy_timeout(std::time::Duration::from_secs(3))?;
    let receipt_table = physical_name(prefix, RECEIPT_TABLE);
    if !table_exists(&target, &receipt_table)? {
        ensure_empty_unreceipted_destination(&target, prefix)?;
        return Ok(false);
    }

    let mut statement = target.prepare(&format!(
        "SELECT source_identity, source_digest, rows_digest, meta_count, sample_count, id_count, \
                aggregate_count, backup_path, completed_at FROM {} ORDER BY source_identity",
        quote_identifier(&receipt_table)
    ))?;
    let receipts = statement
        .query_map([], receipt_from_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(statement);
    if receipts.is_empty() {
        ensure_empty_unreceipted_destination(&target, prefix)?;
        return Ok(false);
    }
    if receipts.len() != 1 || receipts[0].source_identity != source_identity {
        return Err(rusqlite::Error::InvalidQuery);
    }

    let receipt = &receipts[0];
    if receipt.completed_at < 0.0 || !receipt.completed_at.is_finite() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    validate_body_schema(&target, prefix)?;
    let backup_path = PathBuf::from(&receipt.backup_path);
    let backup = Connection::open_with_flags(
        &backup_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    validate_body_schema(&backup, "")?;
    let backup_proof = table_proof(&backup, Some(""))?;
    if receipt.rows_digest != backup_proof.rows_digest
        || receipt.source_digest != source_digest(source_identity, &backup_proof.rows_digest)
        || receipt.meta_count != count_for(&backup_proof, "speed_trend_meta")?
        || receipt.sample_count != count_for(&backup_proof, "speed_samples")?
        || receipt.id_count != count_for(&backup_proof, "speed_sample_ids")?
        || receipt.aggregate_count != count_for(&backup_proof, "speed_5m")?
    {
        return Err(rusqlite::Error::InvalidQuery);
    }
    Ok(true)
}

fn ensure_empty_unreceipted_destination(target: &Connection, prefix: &str) -> rusqlite::Result<()> {
    for table in BODY_TABLES {
        let name = physical_name(prefix, table);
        if table_exists(target, &name)? {
            let count: i64 = target.query_row(
                &format!("SELECT COUNT(*) FROM {}", quote_identifier(&name)),
                [],
                |row| row.get(0),
            )?;
            if count != 0 {
                return Err(rusqlite::Error::InvalidQuery);
            }
        }
    }
    Ok(())
}

fn copy_snapshot_tables<C: PrepareBodyCachedSql>(
    source: &Connection,
    target: &C,
) -> rusqlite::Result<()> {
    {
        let mut read = source
            .prepare("SELECT key, value FROM speed_trend_meta ORDER BY key COLLATE BINARY")?;
        let mut rows = read.query([])?;
        let mut write = target
            .prepare_cached_body("INSERT INTO speed_trend_meta(key, value) VALUES(?1, ?2)")?;
        while let Some(row) = rows.next()? {
            write.execute(params![row.get::<_, String>(0)?, row.get::<_, String>(1)?])?;
        }
    }
    {
        let mut read = source.prepare(
            "SELECT id, ended_at, model, included, payload_json FROM speed_samples ORDER BY id COLLATE BINARY",
        )?;
        let mut rows = read.query([])?;
        let mut write = target.prepare_cached_body(
            "INSERT INTO speed_samples(id, ended_at, model, included, payload_json) VALUES(?1, ?2, ?3, ?4, ?5)",
        )?;
        while let Some(row) = rows.next()? {
            write.execute(params![
                row.get::<_, String>(0)?,
                row.get::<_, f64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, String>(4)?,
            ])?;
        }
    }
    {
        let mut read = source.prepare(
            "SELECT id, ended_at, bucket_start, model, output_tokens, duration_seconds, trend_eligible \
             FROM speed_sample_ids ORDER BY id COLLATE BINARY",
        )?;
        let mut rows = read.query([])?;
        let mut write = target.prepare_cached_body(
            "INSERT INTO speed_sample_ids(id, ended_at, bucket_start, model, output_tokens, duration_seconds, trend_eligible) \
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )?;
        while let Some(row) = rows.next()? {
            write.execute(params![
                row.get::<_, String>(0)?,
                row.get::<_, f64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, f64>(5)?,
                row.get::<_, i64>(6)?,
            ])?;
        }
    }
    {
        let mut read = source.prepare(
            "SELECT bucket_start, model, output_tokens, duration_seconds, sample_count \
             FROM speed_5m ORDER BY bucket_start, model COLLATE BINARY",
        )?;
        let mut rows = read.query([])?;
        let mut write = target.prepare_cached_body(
            "INSERT INTO speed_5m(bucket_start, model, output_tokens, duration_seconds, sample_count) \
             VALUES(?1, ?2, ?3, ?4, ?5)",
        )?;
        while let Some(row) = rows.next()? {
            write.execute(params![
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, f64>(3)?,
                row.get::<_, i64>(4)?,
            ])?;
        }
    }
    Ok(())
}

fn scoped_body_row_count<C: PrepareBodySql>(connection: &C) -> rusqlite::Result<i64> {
    let mut total = 0_i64;
    for table in BODY_TABLES {
        let count: i64 = connection
            .prepare_body(&format!("SELECT COUNT(*) FROM {table}"))?
            .query_row([], |row| row.get(0))?;
        total = total
            .checked_add(count)
            .ok_or(rusqlite::Error::InvalidQuery)?;
    }
    Ok(total)
}

#[cfg(not(test))]
fn read_scoped_receipt(
    connection: &crate::core::business_store_connection::StoreTransaction<'_>,
    source_identity: &str,
) -> rusqlite::Result<Option<MigrationReceipt>> {
    connection
        .query_row(
            "SELECT source_identity, source_digest, rows_digest, meta_count, sample_count, id_count, \
                    aggregate_count, backup_path, completed_at \
             FROM speed_migration_receipts WHERE source_identity=?1",
            [source_identity],
            receipt_from_row,
        )
        .optional()
}

pub(super) fn body_speed_object_names() -> Vec<String> {
    [
        "speed_trend_meta",
        "speed_samples",
        "speed_samples_ended_model",
        "speed_samples_model_ended",
        "speed_sample_ids",
        "speed_sample_ids_ended",
        "speed_5m",
        RECEIPT_TABLE,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn create_receipt_sql() -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {RECEIPT_TABLE}(\
             source_identity TEXT PRIMARY KEY NOT NULL, source_digest TEXT NOT NULL, rows_digest TEXT NOT NULL, \
             meta_count INTEGER NOT NULL, sample_count INTEGER NOT NULL, id_count INTEGER NOT NULL, \
             aggregate_count INTEGER NOT NULL, backup_path TEXT NOT NULL, completed_at REAL NOT NULL\
         ) WITHOUT ROWID"
    )
}

fn table_proof<C: PrepareBodySql>(
    connection: &C,
    raw_prefix: Option<&str>,
) -> rusqlite::Result<TableProof> {
    let mut digest = Sha256::new();
    let mut counts = BTreeMap::new();
    for table in BODY_TABLES {
        digest.update((table.len() as u64).to_be_bytes());
        digest.update(table.as_bytes());
        let source_table = match raw_prefix {
            Some(prefix) => quote_identifier(&physical_name(prefix, table)),
            None => quote_identifier(table),
        };
        let order = match table {
            "speed_trend_meta" => "key COLLATE BINARY",
            "speed_samples" | "speed_sample_ids" => "id COLLATE BINARY",
            "speed_5m" => "bucket_start, model COLLATE BINARY",
            _ => return Err(rusqlite::Error::InvalidQuery),
        };
        let mut statement =
            connection.prepare_body(&format!("SELECT * FROM {source_table} ORDER BY {order}"))?;
        let columns =
            usize::try_from(statement.column_count()).map_err(|_| rusqlite::Error::InvalidQuery)?;
        let mut rows = statement.query([])?;
        let mut count = 0_i64;
        while let Some(row) = rows.next()? {
            digest.update((columns as u64).to_be_bytes());
            for column in 0..columns {
                let value = canonical_value(row.get_ref(column)?);
                digest.update((value.len() as u64).to_be_bytes());
                digest.update(value);
            }
            count = count.checked_add(1).ok_or(rusqlite::Error::InvalidQuery)?;
        }
        counts.insert(table.to_owned(), count);
    }
    Ok(TableProof {
        rows_digest: hex_digest(&digest.finalize()),
        counts,
    })
}

trait PrepareBodySql {
    fn prepare_body(&self, sql: &str) -> rusqlite::Result<rusqlite::Statement<'_>>;
}

trait PrepareBodyCachedSql {
    fn prepare_cached_body(&self, sql: &str) -> rusqlite::Result<rusqlite::CachedStatement<'_>>;
}

impl PrepareBodySql for Connection {
    fn prepare_body(&self, sql: &str) -> rusqlite::Result<rusqlite::Statement<'_>> {
        self.prepare(sql)
    }
}

impl PrepareBodyCachedSql for Connection {
    fn prepare_cached_body(&self, sql: &str) -> rusqlite::Result<rusqlite::CachedStatement<'_>> {
        self.prepare_cached(sql)
    }
}

impl PrepareBodySql for rusqlite::Transaction<'_> {
    fn prepare_body(&self, sql: &str) -> rusqlite::Result<rusqlite::Statement<'_>> {
        self.prepare(sql)
    }
}

impl PrepareBodyCachedSql for rusqlite::Transaction<'_> {
    fn prepare_cached_body(&self, sql: &str) -> rusqlite::Result<rusqlite::CachedStatement<'_>> {
        self.prepare_cached(sql)
    }
}

#[cfg(not(test))]
impl PrepareBodySql for crate::core::business_store_connection::StoreConnection {
    fn prepare_body(&self, sql: &str) -> rusqlite::Result<rusqlite::Statement<'_>> {
        self.prepare(sql)
    }
}

#[cfg(not(test))]
impl PrepareBodyCachedSql for crate::core::business_store_connection::StoreConnection {
    fn prepare_cached_body(&self, sql: &str) -> rusqlite::Result<rusqlite::CachedStatement<'_>> {
        self.prepare_cached(sql)
    }
}

#[cfg(not(test))]
impl PrepareBodySql for crate::core::business_store_connection::StoreTransaction<'_> {
    fn prepare_body(&self, sql: &str) -> rusqlite::Result<rusqlite::Statement<'_>> {
        self.prepare(sql)
    }
}

#[cfg(not(test))]
impl PrepareBodyCachedSql for crate::core::business_store_connection::StoreTransaction<'_> {
    fn prepare_cached_body(&self, sql: &str) -> rusqlite::Result<rusqlite::CachedStatement<'_>> {
        self.prepare_cached(sql)
    }
}

fn canonical_value(value: ValueRef<'_>) -> Vec<u8> {
    let (kind, bytes) = match value {
        ValueRef::Null => (5_u8, Vec::new()),
        ValueRef::Integer(value) => (1_u8, value.to_be_bytes().to_vec()),
        ValueRef::Real(value) => (2_u8, value.to_bits().to_be_bytes().to_vec()),
        ValueRef::Text(value) => (3_u8, value.to_vec()),
        ValueRef::Blob(value) => (4_u8, value.to_vec()),
    };
    let mut encoded = Vec::with_capacity(9 + bytes.len());
    encoded.push(kind);
    encoded.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
    encoded.extend_from_slice(&bytes);
    encoded
}

fn source_digest(source_identity: &str, rows_digest: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"body-speed-source-v1\0");
    digest.update(source_identity.as_bytes());
    digest.update(b"\0");
    digest.update(rows_digest.as_bytes());
    hex_digest(&digest.finalize())
}

fn receipt_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<MigrationReceipt> {
    Ok(MigrationReceipt {
        source_identity: row.get(0)?,
        source_digest: row.get(1)?,
        rows_digest: row.get(2)?,
        meta_count: row.get(3)?,
        sample_count: row.get(4)?,
        id_count: row.get(5)?,
        aggregate_count: row.get(6)?,
        backup_path: row.get(7)?,
        completed_at: row.get(8)?,
    })
}

fn count_for(proof: &TableProof, table: &str) -> rusqlite::Result<i64> {
    proof
        .counts
        .get(table)
        .copied()
        .ok_or(rusqlite::Error::InvalidQuery)
}

fn physical_name(prefix: &str, logical: &str) -> String {
    format!("{prefix}{logical}")
}

fn quote_identifier(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn table_exists(connection: &Connection, name: &str) -> rusqlite::Result<bool> {
    let kind: Option<String> = connection
        .query_row(
            "SELECT type FROM sqlite_master WHERE name=?1",
            [name],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    match kind.as_deref() {
        None => Ok(false),
        Some("table") => Ok(true),
        Some(_) => Err(rusqlite::Error::InvalidQuery),
    }
}

fn validate_body_schema(connection: &Connection, prefix: &str) -> rusqlite::Result<()> {
    let expected: [(&str, &[&str]); 4] = [
        ("speed_trend_meta", &["key", "value"]),
        (
            "speed_samples",
            &["id", "ended_at", "model", "included", "payload_json"],
        ),
        (
            "speed_sample_ids",
            &[
                "id",
                "ended_at",
                "bucket_start",
                "model",
                "output_tokens",
                "duration_seconds",
                "trend_eligible",
            ],
        ),
        (
            "speed_5m",
            &[
                "bucket_start",
                "model",
                "output_tokens",
                "duration_seconds",
                "sample_count",
            ],
        ),
    ];
    for (table, columns) in expected {
        let name = physical_name(prefix, table);
        if !table_exists(connection, &name)? {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let mut statement =
            connection.prepare(&format!("PRAGMA table_info({})", quote_identifier(&name)))?;
        let found = statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        if found.len() != columns.len()
            || found
                .iter()
                .zip(columns)
                .any(|(found, expected)| found != expected)
        {
            return Err(rusqlite::Error::InvalidQuery);
        }
    }
    Ok(())
}

fn retained_backup_path(shared_path: &Path, source_identity: &str) -> rusqlite::Result<PathBuf> {
    let parent = shared_path
        .parent()
        .ok_or_else(|| rusqlite::Error::InvalidPath(shared_path.to_path_buf()))?;
    let backup_directory = parent.join("backups");
    std::fs::create_dir_all(&backup_directory)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    let source_key = hex_digest(&Sha256::digest(source_identity.as_bytes()));
    Ok(backup_directory.join(format!(
        "body-speed-{source_key}-{}.sqlite",
        uuid::Uuid::new_v4()
    )))
}

#[cfg(unix)]
fn set_private_backup_permissions(path: &Path) -> rusqlite::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))
}

#[cfg(not(unix))]
fn set_private_backup_permissions(_path: &Path) -> rusqlite::Result<()> {
    Ok(())
}

fn sync_backup_snapshot(path: &Path) -> rusqlite::Result<()> {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    if let Some(parent) = path.parent() {
        crate::core::atomic_file::sync_parent(parent)
            .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    }
    Ok(())
}

fn standardized_source_identity(path: &Path) -> Result<String, String> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| error.to_string())?
            .join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                let _ = normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    if !normalized.is_absolute() {
        return Err("completed-body source path is not absolute".to_owned());
    }
    normalized
        .to_str()
        .map(str::to_owned)
        .ok_or_else(|| "completed-body source path is not valid UTF-8".to_owned())
}

fn hex_digest(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(not(test))]
fn unix_now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or_default()
}

#[cfg(not(test))]
fn to_sql_error(error: impl std::fmt::Display) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error.to_string())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn body_snapshot_proof_is_stable_and_covers_all_four_tables() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("snapshot.sqlite");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE speed_trend_meta(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_samples(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,model TEXT NOT NULL,included INTEGER NOT NULL,payload_json TEXT NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_sample_ids(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,trend_eligible INTEGER NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_5m(bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,sample_count INTEGER NOT NULL,PRIMARY KEY(bucket_start,model)) WITHOUT ROWID;\
                 INSERT INTO speed_trend_meta VALUES('body_retention_days','15'),('schema_version','1');\
                 INSERT INTO speed_samples VALUES('sample-a',100.25,'model-a',1,'{\"output_tokens\":42}');\
                 INSERT INTO speed_sample_ids VALUES('sample-a',100.25,0,'model-a',42,2.0,1);\
                 INSERT INTO speed_5m VALUES(0,'model-a',42,2.0,1);",
            )
            .unwrap();
        let first = table_proof(&connection, Some("")).unwrap();
        let second = table_proof(&connection, Some("")).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.counts["speed_trend_meta"], 2);
        assert_eq!(first.counts["speed_samples"], 1);
        assert_eq!(first.counts["speed_sample_ids"], 1);
        assert_eq!(first.counts["speed_5m"], 1);
        assert_eq!(
            source_digest("/tmp/body-speed-a.sqlite", &first.rows_digest),
            source_digest("/tmp/body-speed-a.sqlite", &second.rows_digest)
        );
        assert_ne!(
            source_digest("/tmp/body-speed-a.sqlite", &first.rows_digest),
            source_digest("/tmp/body-speed-b.sqlite", &first.rows_digest)
        );
    }

    #[test]
    fn snapshot_copy_is_exact_and_receipt_rolls_back_with_all_four_tables() {
        let directory = tempdir().unwrap();
        let source_path = directory.path().join("legacy-snapshot.sqlite");
        let target_path = directory.path().join("shared.sqlite");
        let source = Connection::open(&source_path).unwrap();
        source
            .execute_batch(
                "CREATE TABLE speed_trend_meta(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_samples(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,model TEXT NOT NULL,included INTEGER NOT NULL,payload_json TEXT NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_sample_ids(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,trend_eligible INTEGER NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_5m(bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,sample_count INTEGER NOT NULL,PRIMARY KEY(bucket_start,model)) WITHOUT ROWID;\
                 INSERT INTO speed_trend_meta VALUES('body_retention_days','15'),('schema_version','1');\
                 INSERT INTO speed_samples VALUES('sample-a',100.25,'model-a',1,'{\"output_tokens\":42}');\
                 INSERT INTO speed_sample_ids VALUES('sample-a',100.25,0,'model-a',42,2.0,1);\
                 INSERT INTO speed_5m VALUES(0,'model-a',42,2.0,1);",
            )
            .unwrap();
        let source_proof = table_proof(&source, Some("")).unwrap();

        let mut target = Connection::open(&target_path).unwrap();
        target
            .execute_batch(
                "CREATE TABLE speed_trend_meta(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_samples(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,model TEXT NOT NULL,included INTEGER NOT NULL,payload_json TEXT NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_sample_ids(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,trend_eligible INTEGER NOT NULL) WITHOUT ROWID;\
                 CREATE TABLE speed_5m(bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,sample_count INTEGER NOT NULL,PRIMARY KEY(bucket_start,model)) WITHOUT ROWID;",
            )
            .unwrap();
        let transaction = target.transaction().unwrap();
        copy_snapshot_tables(&source, &transaction).unwrap();
        transaction.execute_batch(&create_receipt_sql()).unwrap();
        let target_proof = table_proof(&transaction, Some("")).unwrap();
        assert_eq!(target_proof, source_proof);
        transaction
            .execute(
                "INSERT INTO speed_migration_receipts(source_identity,source_digest,rows_digest,meta_count,sample_count,id_count,aggregate_count,backup_path,completed_at) \
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                params![
                    "/stable/body-speed.sqlite",
                    source_digest("/stable/body-speed.sqlite", &source_proof.rows_digest),
                    source_proof.rows_digest,
                    2_i64,
                    1_i64,
                    1_i64,
                    1_i64,
                    source_path.to_string_lossy(),
                    100.0_f64,
                ],
            )
            .unwrap();
        transaction.rollback().unwrap();

        assert!(source_path.is_file());
        assert!(!table_exists(&target, RECEIPT_TABLE).unwrap());
        assert_eq!(
            scoped_body_row_count(&target).unwrap(),
            0,
            "a failed copy must leave no partial body rows"
        );
        ensure_empty_unreceipted_destination(&target, "").unwrap();
    }

    #[test]
    fn source_identity_standardizes_relative_components() {
        let path = Path::new("./support/../support/body-speed.sqlite");
        let identity = standardized_source_identity(path).unwrap();
        let expected_suffix = Path::new("support").join("body-speed.sqlite");
        assert!(Path::new(&identity).ends_with(expected_suffix));
    }
}
