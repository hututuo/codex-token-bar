//! Versioned, per-store partitions for business databases (container A).
//!
//! The shared container keeps each legacy module's schema and rows behind a
//! deterministic private table prefix. It never mutates a source snapshot.

use crate::core::atomic_file;
use crate::core::business_store_connection::StoreConnection;
use crate::core::business_store_sql::{BindingError, SQLiteStoreNamespace, StoreSqlBinding};
use rusqlite::{backup::Backup, params, types::ValueRef, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

const SCHEMA: &str =
    include_str!("../../../../Sources/CodexTokenBar/Resources/codex-ledger-schema.sql");
const CONTAINER_SCHEMA_VERSION: &str = "1";
const IMPORT_ALIAS: &str = "tb_import_source";
const EXPORT_ALIAS: &str = "tb_export_source";
static BACKUP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub(crate) type BusinessStoreResult<T> = Result<T, BusinessStoreError>;

#[derive(Debug)]
pub(crate) enum BusinessStoreError {
    Sql(rusqlite::Error),
    Io(std::io::Error),
    InvalidContainerVersion,
    InvalidStore,
    InvalidTimestamp,
    UnsupportedSchema(String),
    ProofMismatch,
    Binding(BindingError),
}

impl From<rusqlite::Error> for BusinessStoreError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}

impl From<std::io::Error> for BusinessStoreError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<BindingError> for BusinessStoreError {
    fn from(value: BindingError) -> Self {
        Self::Binding(value)
    }
}

impl fmt::Display for BusinessStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sql(error) => write!(f, "business store SQLite error: {error}"),
            Self::Io(error) => write!(f, "business store I/O error: {error}"),
            Self::InvalidContainerVersion => {
                f.write_str("business store container version is unsupported")
            }
            Self::InvalidStore => f.write_str("business store identity or state is invalid"),
            Self::InvalidTimestamp => f.write_str("business store import timestamp is invalid"),
            Self::UnsupportedSchema(name) => write!(f, "unsupported business store schema: {name}"),
            Self::ProofMismatch => f.write_str("business store snapshot proof did not match"),
            Self::Binding(error) => write!(f, "business store SQL binding failed: {error:?}"),
        }
    }
}

impl std::error::Error for BusinessStoreError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct StoreSpec {
    pub(crate) id: String,
    pub(crate) module: String,
    pub(crate) source_identity: String,
    pub(crate) logical_path: String,
    pub(crate) prefix: String,
}

impl StoreSpec {
    pub(crate) fn new(
        module: impl Into<String>,
        source_identity: impl Into<String>,
        logical_path: impl Into<String>,
    ) -> BusinessStoreResult<Self> {
        let module = module.into();
        let source_identity = source_identity.into();
        let logical_path = logical_path.into();
        if module.is_empty() || source_identity.is_empty() || logical_path.is_empty() {
            return Err(BusinessStoreError::InvalidStore);
        }
        let mut digest = Sha256::new();
        digest.update(b"tokenbar-store-v1\0");
        digest.update(module.as_bytes());
        digest.update(b"\0");
        digest.update(source_identity.as_bytes());
        let id = hex_digest(digest.finalize().as_slice());
        Ok(Self {
            prefix: format!("s{id}_"),
            id,
            module,
            source_identity,
            logical_path,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StoreProof {
    pub(crate) row_count: i64,
    pub(crate) rows_digest: String,
    pub(crate) schema_digest: String,
    pub(crate) table_counts: BTreeMap<String, i64>,
    pub(crate) module_user_version: i64,
}

#[derive(Clone, Debug)]
pub(crate) struct LegacyInputReceipt {
    pub(crate) source_path: String,
    pub(crate) logical_path: String,
    pub(crate) store_id: String,
    pub(crate) module: String,
    pub(crate) source_digest: String,
    pub(crate) backup_path: String,
    pub(crate) retired: bool,
}

struct LegacyReceiptWrite {
    source_path: String,
    module: String,
    store_id: String,
    logical_path: String,
    source_digest: String,
    backup_path: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum StoreState {
    Ready,
    Staging,
    Sealed,
}

impl StoreState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Staging => "staging",
            Self::Sealed => "sealed",
        }
    }
}

pub(crate) struct Container {
    path: PathBuf,
    connection: Connection,
}

impl Container {
    pub(crate) fn open(path: impl AsRef<Path>) -> BusinessStoreResult<Self> {
        let path = path.as_ref().to_path_buf();
        if std::fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_symlink())
        {
            return Err(BusinessStoreError::InvalidContainerVersion);
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let connection = Connection::open(&path)?;
        connection.busy_timeout(Duration::from_secs(30))?;
        let physical_version: i64 =
            connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if physical_version > 1 || physical_version < 0 {
            return Err(BusinessStoreError::InvalidContainerVersion);
        }
        if physical_version == 1 {
            // An existing v1 is never repaired by CREATE IF NOT EXISTS. Prove
            // its container contract before any journal/DDL mutation.
            validate_container_catalog(&connection)?;
            connection.execute_batch(
                "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
            )?;
            return Ok(Self { path, connection });
        }
        if physical_version == 0 {
            let user_objects: i64 = connection.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
                [],
                |row| row.get(0),
            )?;
            if user_objects != 0 {
                return Err(BusinessStoreError::InvalidContainerVersion);
            }
            // Configure a brand new empty A before its first table is created.
            // Existing v1 files keep their original auto_vacuum mode.
            connection.execute_batch("PRAGMA auto_vacuum=INCREMENTAL;")?;
        }
        connection.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
        )?;
        connection.execute_batch("BEGIN IMMEDIATE")?;
        let schema_result = connection
            .execute_batch(SCHEMA)
            .and_then(|_| connection.execute_batch("PRAGMA user_version=1; COMMIT"));
        if let Err(error) = schema_result {
            let _ = connection.execute_batch("ROLLBACK");
            return Err(error.into());
        }
        let version: Option<String> = connection
            .query_row(
                "SELECT value FROM tb_container_meta WHERE key='schema_version'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if version.as_deref() != Some(CONTAINER_SCHEMA_VERSION) {
            return Err(BusinessStoreError::InvalidContainerVersion);
        }
        Ok(Self { path, connection })
    }

    /// Open an already initialized container without CREATE or DDL. Ordinary
    /// store callers use this path so a missing A can never be silently
    /// replaced with an empty database.
    pub(crate) fn open_existing(path: impl AsRef<Path>) -> BusinessStoreResult<Self> {
        let path = path.as_ref().to_path_buf();
        if std::fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_symlink())
        {
            return Err(BusinessStoreError::InvalidContainerVersion);
        }
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_URI,
        )?;
        connection.busy_timeout(Duration::from_secs(30))?;
        let physical_version: i64 =
            connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if physical_version != 1 {
            return Err(BusinessStoreError::InvalidContainerVersion);
        }
        connection.execute_batch("PRAGMA foreign_keys=ON;")?;
        let version: Option<String> = connection
            .query_row(
                "SELECT value FROM tb_container_meta WHERE key='schema_version'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if version.as_deref() != Some(CONTAINER_SCHEMA_VERSION) {
            return Err(BusinessStoreError::InvalidContainerVersion);
        }
        Ok(Self { path, connection })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn connection(&self) -> &Connection {
        &self.connection
    }

    pub(crate) fn connection_mut(&mut self) -> &mut Connection {
        &mut self.connection
    }

    /// Consume the container and expose exactly one logical store through a
    /// SQL-binding facade. The physical connection remains the shared A file.
    pub(crate) fn into_store_connection(
        self,
        store: &StoreSpec,
    ) -> BusinessStoreResult<StoreConnection> {
        self.ensure_registered(store)?;
        let names = {
            let mut statement = self.connection.prepare(
                "SELECT substr(name,?1) FROM main.sqlite_master WHERE substr(name,1,?2)=?3 AND name NOT LIKE 'sqlite_%' ORDER BY name",
            )?;
            let names = statement
                .query_map(
                    params![
                        store.prefix.len() as i64 + 1,
                        store.prefix.len() as i64,
                        store.prefix
                    ],
                    |row| row.get::<_, String>(0),
                )?
                .collect::<Result<Vec<_>, _>>()?;
            names
        };
        let binding = StoreSqlBinding::new(store.id.clone(), store.prefix.clone(), names)?;
        Ok(StoreConnection::bound(self.connection, binding)?)
    }

    pub(crate) fn has_imported_objects(&self, store: &StoreSpec) -> BusinessStoreResult<bool> {
        self.ensure_registered(store)?;
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM tb_store_objects WHERE store_id=?1 AND type='table')",
            [&store.id],
            |row| row.get(0),
        )?)
    }

    /// Make a SQLite online-backup snapshot of an old module database. The
    /// source is opened read-only and is never removed or rewritten.
    pub(crate) fn backup_snapshot(
        source_path: impl AsRef<Path>,
        backup_path: impl AsRef<Path>,
    ) -> BusinessStoreResult<()> {
        let source_path = source_path.as_ref();
        let backup_path = backup_path.as_ref();
        let expected_digest = Self::snapshot_digest(source_path)?;
        Self::ensure_verified_backup(source_path, backup_path, &expected_digest)
    }

    /// Ensure a complete, verified backup exists at `backup_path`. Existing
    /// matching backups are reused. Any other existing destination is moved
    /// aside before rebuilding, so an interrupted or corrupt backup is never
    /// mistaken for a committed one and its bytes remain recoverable.
    pub(crate) fn ensure_verified_backup(
        source_path: impl AsRef<Path>,
        backup_path: impl AsRef<Path>,
        expected_digest: &str,
    ) -> BusinessStoreResult<()> {
        Self::ensure_verified_backup_with(
            source_path.as_ref(),
            backup_path.as_ref(),
            expected_digest,
            Self::write_backup_snapshot,
        )
    }

    fn ensure_verified_backup_with(
        source_path: &Path,
        backup_path: &Path,
        expected_digest: &str,
        build: impl FnOnce(&Path, &Path) -> BusinessStoreResult<()>,
    ) -> BusinessStoreResult<()> {
        if backup_path.file_name().is_none() {
            return Err(BusinessStoreError::InvalidStore);
        }
        reject_backup_target_aliasing_source(source_path, backup_path)?;
        if backup_path_matches(backup_path, expected_digest) {
            return Ok(());
        }

        let parent = backup_parent(backup_path);
        fs::create_dir_all(parent)?;
        if Self::snapshot_digest(source_path)? != expected_digest {
            return Err(BusinessStoreError::ProofMismatch);
        }

        if backup_path_matches(backup_path, expected_digest) {
            return Ok(());
        }
        if backup_set_has_files(backup_path)? {
            quarantine_backup_set(backup_path)?;
        }

        let temporary = create_backup_temporary_path(backup_path)?;
        let build_result = build(source_path, &temporary);
        if let Err(error) = build_result {
            cleanup_backup_temporary(&temporary);
            return Err(error);
        }

        let verify_result = verify_backup(&temporary);
        match verify_result {
            Ok(digest) if digest == expected_digest => {}
            Ok(_) => {
                cleanup_backup_temporary(&temporary);
                return Err(BusinessStoreError::ProofMismatch);
            }
            Err(error) => {
                cleanup_backup_temporary(&temporary);
                return Err(error);
            }
        }

        let sync_result = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&temporary)
            .and_then(|file| file.sync_all());
        if let Err(error) = sync_result {
            cleanup_backup_temporary(&temporary);
            return Err(error.into());
        }

        // A no-replace publish prevents a concurrent, already-verified backup
        // from being overwritten. If another writer wins, accept its result
        // only after proving that it matches this expected snapshot.
        match rename_without_replacement(&temporary, backup_path) {
            Ok(()) => atomic_file::sync_parent(parent)?,
            Err(_error) if path_exists(backup_path)? => {
                if backup_path_matches(backup_path, expected_digest) {
                    cleanup_backup_temporary(&temporary);
                    return Ok(());
                }
                quarantine_backup_set(backup_path)?;
                if let Err(publish_error) = rename_without_replacement(&temporary, backup_path) {
                    if backup_path_matches(backup_path, expected_digest) {
                        cleanup_backup_temporary(&temporary);
                        return Ok(());
                    }
                    cleanup_backup_temporary(&temporary);
                    return Err(publish_error.into());
                }
                atomic_file::sync_parent(parent)?;
            }
            Err(error) => {
                cleanup_backup_temporary(&temporary);
                return Err(error.into());
            }
        }
        Ok(())
    }

    fn write_backup_snapshot(source_path: &Path, backup_path: &Path) -> BusinessStoreResult<()> {
        let source = Connection::open_with_flags(
            source_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        )?;
        let mut target = Connection::open(backup_path)?;
        {
            let backup = Backup::new(&source, &mut target)?;
            backup.run_to_completion(128, Duration::from_millis(10), None)?;
        }
        // The backup API may copy the source's WAL journal mode. Publish a
        // self-contained image, never a main file depending on temp sidecars.
        target.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")?;
        let check: String = target.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
        if check != "ok" {
            return Err(BusinessStoreError::ProofMismatch);
        }
        Ok(())
    }

    pub(crate) fn register(&self, store: &StoreSpec) -> BusinessStoreResult<()> {
        self.register_with_state(store, StoreState::Ready)
    }

    pub(crate) fn is_registered(&self, store: &StoreSpec) -> BusinessStoreResult<bool> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1 AND module=?2 AND source_identity=?3 AND logical_path=?4 AND namespace_prefix=?5)",
            params![store.id, store.module, store.source_identity, store.logical_path, store.prefix],
            |row| row.get(0),
        )?)
    }

    pub(crate) fn logical_object_names(
        &self,
        store: &StoreSpec,
    ) -> BusinessStoreResult<Vec<String>> {
        self.ensure_registered(store)?;
        let mut statement = self.connection.prepare(
            "SELECT substr(name,?1) FROM main.sqlite_master WHERE substr(name,1,?2)=?3 AND name NOT LIKE 'sqlite_%' ORDER BY name COLLATE BINARY",
        )?;
        let rows = statement.query_map(
            params![
                store.prefix.len() as i64 + 1,
                store.prefix.len() as i64,
                store.prefix
            ],
            |row| row.get::<_, String>(0),
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub(crate) fn register_with_state(
        &self,
        store: &StoreSpec,
        state: StoreState,
    ) -> BusinessStoreResult<()> {
        if !valid_store_spec(store) {
            return Err(BusinessStoreError::InvalidStore);
        }
        self.connection.execute(
            "INSERT INTO tb_stores(store_id,module,source_identity,logical_path,namespace_prefix,state) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(store_id) DO NOTHING",
            params![store.id, store.module, store.source_identity, store.logical_path, store.prefix, state.as_str()],
        )?;
        let matching: bool = self.connection.query_row(
            "SELECT module=?2 AND source_identity=?3 AND logical_path=?4 AND namespace_prefix=?5 FROM tb_stores WHERE store_id=?1",
            params![store.id, store.module, store.source_identity, store.logical_path, store.prefix],
            |row| row.get(0),
        ).optional()?.unwrap_or(false);
        if !matching {
            return Err(BusinessStoreError::InvalidStore);
        }
        Ok(())
    }

    pub(crate) fn user_version(&self, store: &StoreSpec) -> BusinessStoreResult<i64> {
        self.ensure_registered(store)?;
        Ok(self.connection.query_row(
            "SELECT user_version FROM tb_stores WHERE store_id=?1",
            [&store.id],
            |row| row.get(0),
        )?)
    }

    pub(crate) fn set_user_version(
        &self,
        store: &StoreSpec,
        user_version: i64,
    ) -> BusinessStoreResult<()> {
        self.ensure_registered(store)?;
        if user_version < 0 {
            return Err(BusinessStoreError::InvalidStore);
        }
        self.connection.execute(
            "UPDATE tb_stores SET user_version=?1,revision=revision+1 WHERE store_id=?2",
            params![user_version, store.id],
        )?;
        Ok(())
    }

    pub(crate) fn proof(&self, store: &StoreSpec) -> BusinessStoreResult<StoreProof> {
        self.ensure_registered(store)?;
        proof_for(
            &self.connection,
            "main",
            &store.prefix,
            true,
            Some(self.user_version(store)?),
        )
    }

    /// Import one immutable SQLite snapshot into a single store namespace.
    /// The source is attached read-only and never modified; receipt and table
    /// replacement are committed together in the container transaction.
    pub(crate) fn import_snapshot(
        &mut self,
        source_path: impl AsRef<Path>,
        store: &StoreSpec,
        backup_path: impl AsRef<Path>,
        now: f64,
        replace_existing: bool,
    ) -> BusinessStoreResult<StoreProof> {
        self.import_snapshot_inner(
            source_path.as_ref(),
            store,
            backup_path.as_ref(),
            now,
            replace_existing,
            None,
        )
    }

    /// Import a legacy input and durably record its original path in the same
    /// transaction as the row copy. A retired receipt remains after the
    /// private namespace is removed, preventing an old physical stage file
    /// from being replayed during a later bootstrap.
    pub(crate) fn import_legacy_snapshot(
        &mut self,
        snapshot_path: impl AsRef<Path>,
        store: &StoreSpec,
        original_source_path: impl AsRef<Path>,
        backup_path: impl AsRef<Path>,
        now: f64,
        replace_existing: bool,
    ) -> BusinessStoreResult<Option<StoreProof>> {
        if !now.is_finite() {
            return Err(BusinessStoreError::InvalidTimestamp);
        }
        self.register(store)?;

        let source_path = canonical_input_path(original_source_path.as_ref())?;
        let source_digest = Self::snapshot_digest(snapshot_path.as_ref())?;
        if let Some(receipt) = self.legacy_input_receipt_by_key(&source_path)? {
            if receipt.source_digest == source_digest {
                if receipt.retired {
                    // A retained source is evidence only after its namespace
                    // has been retired. Never resurrect that old job.
                    return Ok(None);
                }
                if receipt.store_id == store.id
                    && receipt.module == store.module
                    && receipt.logical_path == store.logical_path
                {
                    return Ok(Some(self.proof(store)?));
                }
                return Err(BusinessStoreError::InvalidStore);
            }
            if !receipt.retired {
                // An active source changed underneath its receipt. Replacing
                // it would make the import history ambiguous.
                return Err(BusinessStoreError::ProofMismatch);
            }
        }

        let receipt = LegacyReceiptWrite {
            source_path,
            module: store.module.clone(),
            store_id: store.id.clone(),
            logical_path: store.logical_path.clone(),
            source_digest,
            backup_path: backup_path.as_ref().to_string_lossy().into_owned(),
        };
        let proof = self.import_snapshot_inner(
            snapshot_path.as_ref(),
            store,
            backup_path.as_ref(),
            now,
            replace_existing,
            Some(receipt),
        )?;
        Ok(Some(proof))
    }

    /// Record another byte source that is proof-identical to the namespace
    /// already imported. This avoids replaying a duplicate baseline while
    /// still retaining a receipt for every original input path.
    pub(crate) fn record_identical_legacy_input(
        &mut self,
        snapshot_path: impl AsRef<Path>,
        store: &StoreSpec,
        original_source_path: impl AsRef<Path>,
        backup_path: impl AsRef<Path>,
        now: f64,
    ) -> BusinessStoreResult<()> {
        if !now.is_finite() {
            return Err(BusinessStoreError::InvalidTimestamp);
        }
        self.ensure_registered(store)?;
        let source_digest = Self::snapshot_digest(snapshot_path.as_ref())?;
        let proof = self.proof(store)?;
        if source_digest != format!("{}:{}", proof.schema_digest, proof.rows_digest) {
            return Err(BusinessStoreError::ProofMismatch);
        }
        let source_path = canonical_input_path(original_source_path.as_ref())?;
        if let Some(existing) = self.legacy_input_receipt_by_key(&source_path)? {
            if existing.source_digest == source_digest
                && !existing.retired
                && existing.store_id == store.id
                && existing.module == store.module
                && existing.logical_path == store.logical_path
            {
                return Ok(());
            }
            if !existing.retired {
                return Err(BusinessStoreError::ProofMismatch);
            }
        }
        self.connection.execute(
            "INSERT INTO tb_legacy_inputs(source_path,logical_path,store_id,module,source_digest,backup_path,retired) VALUES (?1,?2,?3,?4,?5,?6,0) ON CONFLICT(source_path) DO UPDATE SET logical_path=excluded.logical_path,store_id=excluded.store_id,module=excluded.module,source_digest=excluded.source_digest,backup_path=excluded.backup_path,retired=0",
            params![source_path, store.logical_path, store.id, store.module, source_digest, backup_path.as_ref().to_string_lossy()],
        )?;
        Ok(())
    }

    fn import_snapshot_inner(
        &mut self,
        source_path: &Path,
        store: &StoreSpec,
        backup_path: &Path,
        now: f64,
        replace_existing: bool,
        legacy_receipt: Option<LegacyReceiptWrite>,
    ) -> BusinessStoreResult<StoreProof> {
        if !now.is_finite() {
            return Err(BusinessStoreError::InvalidTimestamp);
        }
        self.register(store)?;
        let uri = readonly_file_uri(source_path);
        self.connection
            .execute("ATTACH DATABASE ?1 AS tb_import_source", [&uri])?;
        let foreign_keys: bool = self
            .connection
            .query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
        self.connection.execute_batch("PRAGMA foreign_keys=OFF")?;
        let result =
            self.import_attached(store, backup_path, now, replace_existing, legacy_receipt);
        let detach_result = self
            .connection
            .execute_batch("DETACH DATABASE tb_import_source");
        let restore_result = self.connection.execute_batch(if foreign_keys {
            "PRAGMA foreign_keys=ON"
        } else {
            "PRAGMA foreign_keys=OFF"
        });
        match result {
            Err(error) => Err(error),
            Ok(value) => {
                detach_result?;
                restore_result?;
                Ok(value)
            }
        }
    }

    fn import_attached(
        &mut self,
        store: &StoreSpec,
        backup_path: &Path,
        now: f64,
        replace_existing: bool,
        legacy_receipt: Option<LegacyReceiptWrite>,
    ) -> BusinessStoreResult<StoreProof> {
        let tx = self.connection.transaction()?;
        let source = proof_for(&tx, IMPORT_ALIAS, "", false, None)?;
        let source_digest = format!("{}:{}", source.schema_digest, source.rows_digest);
        let existing: Option<String> = tx
            .query_row(
                "SELECT rows_digest FROM tb_store_imports WHERE store_id=?1 AND source_digest=?2",
                params![store.id, source_digest],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            if existing != source.rows_digest {
                return Err(BusinessStoreError::ProofMismatch);
            }
            if !replace_existing {
                if let Some(receipt) = legacy_receipt.as_ref() {
                    write_legacy_receipt(&tx, receipt)?;
                }
                tx.commit()?;
                return Ok(source);
            }
        }

        let objects = schema_objects(&tx, IMPORT_ALIAS, "")?;
        validate_objects(&tx, IMPORT_ALIAS, &objects)?;
        let names: HashSet<String> = objects
            .iter()
            .map(|object| object.name.to_ascii_lowercase())
            .collect();
        let mut namespace = SQLiteStoreNamespace::new(store.prefix.clone(), names.iter().cloned());
        for object in &objects {
            if object.kind == "table" {
                let columns = table_columns(&tx, IMPORT_ALIAS, &object.name)?;
                if columns
                    .iter()
                    .any(|name| names.contains(&name.to_ascii_lowercase()))
                {
                    return Err(BusinessStoreError::UnsupportedSchema(format!(
                        "object and column names overlap in {}",
                        object.name
                    )));
                }
            }
        }

        drop_store_objects(&tx, &store.prefix)?;
        tx.execute(
            "DELETE FROM tb_store_objects WHERE store_id=?1",
            [&store.id],
        )?;

        for object in objects.iter().filter(|object| object.kind == "table") {
            let sql = object
                .sql
                .as_deref()
                .ok_or_else(|| BusinessStoreError::UnsupportedSchema(object.name.clone()))?;
            if sql.to_ascii_uppercase().contains("CREATE VIRTUAL TABLE") {
                return Err(BusinessStoreError::UnsupportedSchema(object.name.clone()));
            }
            tx.execute_batch(&namespace.bind(sql)?)?;
            copy_table(
                &tx,
                IMPORT_ALIAS,
                "main",
                &object.name,
                &format!("{}{}", store.prefix, object.name),
                sql,
            )?;
        }

        copy_sequences(&tx, IMPORT_ALIAS, "main", &store.prefix, "")?;

        for object in objects.iter().filter(|object| object.kind != "table") {
            if let Some(sql) = object.sql.as_deref() {
                tx.execute_batch(&namespace.bind(sql)?)?;
            }
        }

        for object in &objects {
            tx.execute(
                "INSERT INTO tb_store_objects(store_id,name,type,original_sql) VALUES (?1,?2,?3,?4)",
                params![store.id, object.name, object.kind, object.sql],
            )?;
        }
        let user_version: i64 =
            tx.query_row("PRAGMA tb_import_source.user_version", [], |row| row.get(0))?;
        tx.execute(
            "UPDATE tb_stores SET user_version=?1,revision=revision+1 WHERE store_id=?2",
            params![user_version, store.id],
        )?;

        let actual = proof_for(&tx, "main", &store.prefix, true, Some(user_version))?;
        if actual.row_count != source.row_count
            || actual.schema_digest != source.schema_digest
            || actual.rows_digest != source.rows_digest
            || actual.table_counts != source.table_counts
        {
            return Err(BusinessStoreError::ProofMismatch);
        }
        let foreign_key_rows: i64 = tx.query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_check WHERE substr(\"table\",1,?1)=?2",
            params![store.prefix.len() as i64, store.prefix],
            |row| row.get(0),
        )?;
        if foreign_key_rows != 0 {
            return Err(BusinessStoreError::ProofMismatch);
        }
        tx.execute(
            "INSERT INTO tb_store_imports(store_id,source_digest,schema_digest,row_count,rows_digest,backup_path,imported_at) VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(store_id,source_digest) DO UPDATE SET schema_digest=excluded.schema_digest,row_count=excluded.row_count,rows_digest=excluded.rows_digest,backup_path=excluded.backup_path,imported_at=excluded.imported_at",
            params![store.id, source_digest, source.schema_digest, source.row_count, source.rows_digest, backup_path.to_string_lossy(), now],
        )?;
        if let Some(receipt) = legacy_receipt.as_ref() {
            write_legacy_receipt(&tx, receipt)?;
        }
        tx.commit()?;
        Ok(source)
    }

    pub(crate) fn legacy_input_receipt(
        &self,
        source_path: impl AsRef<Path>,
    ) -> BusinessStoreResult<Option<LegacyInputReceipt>> {
        let source_path = canonical_input_path(source_path.as_ref())?;
        self.legacy_input_receipt_by_key(&source_path)
    }

    pub(crate) fn legacy_input_is_retired_unchanged(
        &self,
        source_path: impl AsRef<Path>,
    ) -> BusinessStoreResult<bool> {
        let source_path = canonical_input_path(source_path.as_ref())?;
        let Some(receipt) = self.legacy_input_receipt_by_key(&source_path)? else {
            return Ok(false);
        };
        if !receipt.retired {
            return Ok(false);
        }
        let digest = Self::snapshot_digest(Path::new(&source_path))?;
        Ok(receipt.source_digest == digest)
    }

    fn legacy_input_receipt_by_key(
        &self,
        source_path: &str,
    ) -> BusinessStoreResult<Option<LegacyInputReceipt>> {
        Ok(self.connection.query_row(
            "SELECT source_path,logical_path,store_id,module,source_digest,backup_path,retired FROM tb_legacy_inputs WHERE source_path=?1",
            [source_path],
            |row| Ok(LegacyInputReceipt {
                source_path: row.get(0)?,
                logical_path: row.get(1)?,
                store_id: row.get(2)?,
                module: row.get(3)?,
                source_digest: row.get(4)?,
                backup_path: row.get(5)?,
                retired: row.get::<_, i64>(6)? != 0,
            }),
        ).optional()?)
    }

    /// Remove only this module's physical namespace. Receipt retirement and
    /// namespace deletion commit together; the shared A database and every
    /// other store remain intact.
    pub(crate) fn remove_store_namespace(&mut self, store: &StoreSpec) -> BusinessStoreResult<()> {
        self.ensure_registered(store)?;
        let tx = self.connection.transaction()?;
        tx.execute(
            "UPDATE tb_legacy_inputs SET retired=1 WHERE store_id=?1",
            [&store.id],
        )?;
        drop_store_objects(&tx, &store.prefix)?;
        tx.execute("DELETE FROM tb_store_seals WHERE store_id=?1", [&store.id])?;
        tx.execute(
            "DELETE FROM tb_store_imports WHERE store_id=?1",
            [&store.id],
        )?;
        tx.execute(
            "DELETE FROM tb_store_objects WHERE store_id=?1",
            [&store.id],
        )?;
        tx.execute("DELETE FROM tb_stores WHERE store_id=?1", [&store.id])?;
        tx.commit()?;
        Ok(())
    }

    pub(crate) fn seal_store(
        &mut self,
        store: &StoreSpec,
        sealed_at: f64,
    ) -> BusinessStoreResult<StoreProof> {
        self.ensure_registered(store)?;
        if !sealed_at.is_finite() {
            return Err(BusinessStoreError::InvalidTimestamp);
        }
        let proof = self.proof(store)?;
        let byte_count = logical_footprint(&self.connection, &store.prefix)?;
        let tx = self.connection.transaction()?;
        tx.execute(
            "INSERT INTO tb_store_seals(store_id,byte_count,row_count,rows_digest,sealed_at) VALUES (?1,?2,?3,?4,?5) ON CONFLICT(store_id) DO UPDATE SET byte_count=excluded.byte_count,row_count=excluded.row_count,rows_digest=excluded.rows_digest,sealed_at=excluded.sealed_at",
            params![store.id, byte_count as i64, proof.row_count, proof.rows_digest, sealed_at],
        )?;
        tx.execute(
            "UPDATE tb_stores SET state='sealed',revision=revision+1 WHERE store_id=?1",
            [&store.id],
        )?;
        tx.commit()?;
        Ok(proof)
    }

    pub(crate) fn seal_observation(
        &self,
        store: &StoreSpec,
    ) -> BusinessStoreResult<Option<(u64, i64, String, f64)>> {
        self.ensure_registered(store)?;
        let row = self
            .connection
            .query_row(
                "SELECT byte_count,row_count,rows_digest,sealed_at FROM tb_store_seals WHERE store_id=?1",
                [&store.id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, f64>(3)?,
                    ))
                },
            )
            .optional()?;
        row.map(|(bytes, rows, digest, sealed_at)| {
            if bytes < 0 || rows < 0 || !sealed_at.is_finite() {
                return Err(BusinessStoreError::ProofMismatch);
            }
            Ok((bytes as u64, rows, digest, sealed_at))
        })
        .transpose()
    }

    fn snapshot_digest(path: &Path) -> BusinessStoreResult<String> {
        let connection = Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        )?;
        let proof = proof_for(&connection, "main", "", false, None)?;
        Ok(format!("{}:{}", proof.schema_digest, proof.rows_digest))
    }

    pub(crate) fn snapshot_digest_path(path: impl AsRef<Path>) -> BusinessStoreResult<String> {
        Self::snapshot_digest(path.as_ref())
    }

    /// Export one namespace into a caller-provided destination connection.
    /// The target's current user_version is replaced by this store's legacy
    /// module version; the container's own PRAGMA user_version is untouched.
    pub(crate) fn export_to(
        &self,
        store: &StoreSpec,
        target: &mut Connection,
    ) -> BusinessStoreResult<StoreProof> {
        self.ensure_registered(store)?;
        let expected = self.proof(store)?;
        let module_version = self.user_version(store)?;
        let uri = readonly_file_uri(&self.path);
        target.execute("ATTACH DATABASE ?1 AS tb_export_source", [&uri])?;
        let foreign_keys: bool = target.query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
        target.execute_batch("PRAGMA foreign_keys=OFF")?;
        let result = export_attached(store, target, module_version, &expected);
        let detach_result = target.execute_batch("DETACH DATABASE tb_export_source");
        let restore_result = target.execute_batch(if foreign_keys {
            "PRAGMA foreign_keys=ON"
        } else {
            "PRAGMA foreign_keys=OFF"
        });
        match result {
            Err(error) => Err(error),
            Ok(value) => {
                detach_result?;
                restore_result?;
                Ok(value)
            }
        }
    }

    /// Replace one module namespace with a transactionally cloned namespace.
    /// The source and target remain inside the same physical container; a
    /// failed clone leaves every other store and the old target intact.
    pub(crate) fn clone_store_namespace(
        &mut self,
        source: &StoreSpec,
        target: &StoreSpec,
    ) -> BusinessStoreResult<StoreProof> {
        // Match verified snapshot import: tables are not necessarily emitted
        // in FK dependency order, and cycles cannot be topologically sorted.
        // Disable enforcement on this private handle only, prove every target
        // FK before commit, then restore the caller's setting on every exit.
        let foreign_keys: bool = self.connection.query_row("PRAGMA foreign_keys", [], |r| r.get(0))?;
        self.connection.execute_batch("PRAGMA foreign_keys=OFF")?;
        let result = self.clone_store_namespace_inner(source, target);
        let restored = self.connection.execute_batch(if foreign_keys {
            "PRAGMA foreign_keys=ON"
        } else {
            "PRAGMA foreign_keys=OFF"
        });
        restored?;
        result
    }

    fn clone_store_namespace_inner(
        &mut self,
        source: &StoreSpec,
        target: &StoreSpec,
    ) -> BusinessStoreResult<StoreProof> {
        self.ensure_registered(source)?;
        if source.id == target.id {
            return Err(BusinessStoreError::InvalidStore);
        }
        let source_proof = self.proof(source)?;
        let module_version = self.user_version(source)?;
        let objects = schema_objects(&self.connection, "main", &source.prefix)?;
        let names = objects
            .iter()
            .map(|object| object.name[source.prefix.len()..].to_ascii_lowercase())
            .collect::<HashSet<_>>();
        let source_namespace =
            SQLiteStoreNamespace::new(source.prefix.clone(), names.iter().cloned());
        let mut target_namespace = SQLiteStoreNamespace::new(target.prefix.clone(), names);
        self.register_with_state(target, StoreState::Staging)?;

        let tx = self.connection.transaction()?;
        drop_store_objects(&tx, &target.prefix)?;
        tx.execute(
            "DELETE FROM tb_store_objects WHERE store_id=?1",
            [&target.id],
        )?;
        for object in objects.iter().filter(|object| object.kind == "table") {
            let physical_sql = object
                .sql
                .as_deref()
                .ok_or_else(|| BusinessStoreError::UnsupportedSchema(object.name.clone()))?;
            let logical_sql = source_namespace.unbind(physical_sql)?;
            if logical_sql
                .to_ascii_uppercase()
                .contains("CREATE VIRTUAL TABLE")
            {
                return Err(BusinessStoreError::UnsupportedSchema(object.name.clone()));
            }
            tx.execute_batch(&target_namespace.bind(&logical_sql)?)?;
            let logical_name = object.name[source.prefix.len()..].to_owned();
            copy_table(
                &tx,
                "main",
                "main",
                &object.name,
                &format!("{}{}", target.prefix, logical_name),
                &logical_sql,
            )?;
        }
        copy_sequences(&tx, "main", "main", &target.prefix, &source.prefix)?;
        for object in objects.iter().filter(|object| object.kind != "table") {
            if let Some(physical_sql) = object.sql.as_deref() {
                let logical_sql = source_namespace.unbind(physical_sql)?;
                tx.execute_batch(&target_namespace.bind(&logical_sql)?)?;
            }
        }
        for object in &objects {
            let original_sql = object
                .sql
                .as_deref()
                .map(|sql| source_namespace.unbind(sql))
                .transpose()?;
            tx.execute(
                "INSERT INTO tb_store_objects(store_id,name,type,original_sql) VALUES (?1,?2,?3,?4)",
                params![
                    target.id,
                    object.name[source.prefix.len()..].to_owned(),
                    object.kind,
                    original_sql,
                ],
            )?;
        }
        tx.execute(
            "UPDATE tb_stores SET user_version=?1,state='staging',revision=revision+1 WHERE store_id=?2",
            params![module_version, target.id],
        )?;
        let actual = proof_for(&tx, "main", &target.prefix, true, Some(module_version))?;
        if actual != source_proof {
            return Err(BusinessStoreError::ProofMismatch);
        }
        let broken: i64 = tx.query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_check WHERE substr(\"table\",1,?1)=?2",
            params![target.prefix.len() as i64, target.prefix], |r| r.get(0),
        )?;
        if broken != 0 { return Err(BusinessStoreError::ProofMismatch); }
        tx.commit()?;
        Ok(actual)
    }

    fn ensure_registered(&self, store: &StoreSpec) -> BusinessStoreResult<()> {
        let matches: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1 AND module=?2 AND source_identity=?3 AND logical_path=?4 AND namespace_prefix=?5)",
            params![store.id, store.module, store.source_identity, store.logical_path, store.prefix],
            |row| row.get(0),
        )?;
        if !matches || !valid_store_spec(store) {
            return Err(BusinessStoreError::InvalidStore);
        }
        Ok(())
    }
}

fn backup_parent(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn path_exists(path: &Path) -> std::io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn verify_backup(path: &Path) -> BusinessStoreResult<String> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(BusinessStoreError::ProofMismatch);
    }
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    let check: String = connection.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
    if check != "ok" {
        return Err(BusinessStoreError::ProofMismatch);
    }
    drop(connection);
    Container::snapshot_digest(path)
}

fn backup_path_matches(path: &Path, expected_digest: &str) -> bool {
    verify_backup(path).is_ok_and(|digest| digest == expected_digest)
}

fn reject_backup_target_aliasing_source(
    source_path: &Path,
    backup_path: &Path,
) -> BusinessStoreResult<()> {
    if source_path == backup_path || !path_exists(source_path)? || !path_exists(backup_path)? {
        return if source_path == backup_path {
            Err(BusinessStoreError::InvalidStore)
        } else {
            Ok(())
        };
    }
    let source = match fs::canonicalize(source_path) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    let backup = match fs::canonicalize(backup_path) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if source == backup {
        return Err(BusinessStoreError::InvalidStore);
    }
    Ok(())
}

fn backup_sidecar_paths(path: &Path) -> [PathBuf; 3] {
    let sidecar = |suffix: &str| {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        PathBuf::from(name)
    };
    [sidecar("-wal"), sidecar("-shm"), sidecar("-journal")]
}

fn backup_set_has_files(path: &Path) -> std::io::Result<bool> {
    if path_exists(path)? {
        return Ok(true);
    }
    for sidecar in backup_sidecar_paths(path) {
        if path_exists(&sidecar)? {
            return Ok(true);
        }
    }
    Ok(false)
}

fn quarantine_backup_set(path: &Path) -> BusinessStoreResult<()> {
    let parent = backup_parent(path);
    let quarantine = quarantine_backup_path(path)?;
    let sources = std::iter::once(path.to_path_buf()).chain(backup_sidecar_paths(path));
    let targets = std::iter::once(quarantine.clone()).chain(backup_sidecar_paths(&quarantine));
    for (member, destination) in sources.zip(targets) {
        if !path_exists(&member)? {
            continue;
        }
        rename_without_replacement(&member, &destination)?;
        atomic_file::sync_parent(parent)?;
    }
    Ok(())
}

fn create_backup_temporary_path(backup_path: &Path) -> std::io::Result<PathBuf> {
    let parent = backup_parent(backup_path);
    // Production backup basenames already contain three SHA-256 hashes.
    // Keep temporary/quarantine names short enough for SQLite's -journal
    // suffix on filesystems with a 255-byte component limit.
    for _ in 0..64 {
        let sequence = BACKUP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let candidate = parent.join(format!(
            ".tokenbar-backup-{}-{sequence:020}.sqlite",
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => {
                drop(file);
                return Ok(candidate);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate a unique SQLite backup temporary file",
    ))
}

fn quarantine_backup_path(backup_path: &Path) -> std::io::Result<PathBuf> {
    let parent = backup_parent(backup_path);
    // Production backup basenames already contain three SHA-256 hashes.
    // Keep temporary/quarantine names short enough for SQLite's -journal
    // suffix on filesystems with a 255-byte component limit.
    for _ in 0..64 {
        let candidate = parent.join(format!(
            ".tokenbar-backup-quarantine-{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        if !path_exists(&candidate)? {
            return Ok(candidate);
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate a unique SQLite backup quarantine path",
    ))
}

fn cleanup_backup_temporary(path: &Path) {
    let _ = fs::remove_file(path);
    for suffix in ["-journal", "-wal", "-shm"] {
        let mut sidecar = path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let _ = fs::remove_file(PathBuf::from(sidecar));
    }
}

fn rename_without_replacement(source: &Path, destination: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use rustix::fs::{open, renameat_with, Mode, OFlags, RenameFlags};
        let parent = backup_parent(source);
        let directory = open(
            parent,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|error| std::io::Error::other(error.to_string()))?;
        let source_name = source
            .file_name()
            .ok_or_else(|| std::io::Error::other("source path has no filename"))?;
        let destination_name = destination
            .file_name()
            .ok_or_else(|| std::io::Error::other("destination path has no filename"))?;
        renameat_with(
            &directory,
            source_name,
            &directory,
            destination_name,
            RenameFlags::NOREPLACE,
        )
        .map_err(|error| std::io::Error::other(error.to_string()))
    }
    #[cfg(windows)]
    {
        let source = crate::core::windows_path::extended_length_path(source)
            .map_err(std::io::Error::other)?;
        let destination = crate::core::windows_path::extended_length_path(destination)
            .map_err(std::io::Error::other)?;
        // MoveFileExW without MOVEFILE_REPLACE_EXISTING is an atomic,
        // same-volume move that fails when the destination already exists.
        let moved = unsafe {
            windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                0,
            )
        };
        if moved == 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
    #[cfg(not(any(unix, windows)))]
    {
        if path_exists(destination)? {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination already exists",
            ));
        }
        fs::rename(source, destination)
    }
}

fn validate_container_catalog(connection: &Connection) -> BusinessStoreResult<()> {
    fn catalog(c: &Connection) -> BusinessStoreResult<BTreeMap<String, (String, String, String)>> {
        let mut statement = c.prepare(
            "SELECT name,type,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
        )?;
        let rows = statement.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            ))
        })?;
        let mut result = BTreeMap::new();
        for row in rows {
            let (name, kind, table, sql) = row?;
            result.insert(
                name,
                (kind, table, SQLiteStoreNamespace::canonical_sql(&sql)?),
            );
        }
        Ok(result)
    }
    let reference = Connection::open_in_memory()?;
    reference.execute_batch(SCHEMA)?;
    let expected = catalog(&reference)?;
    let actual = catalog(connection)?;
    if expected
        .iter()
        .any(|(name, object)| actual.get(name) != Some(object))
    {
        return Err(BusinessStoreError::InvalidContainerVersion);
    }
    let version: String = connection.query_row(
        "SELECT value FROM tb_container_meta WHERE key='schema_version'",
        [],
        |r| r.get(0),
    )?;
    if version != CONTAINER_SCHEMA_VERSION {
        return Err(BusinessStoreError::InvalidContainerVersion);
    }
    let mut statement = connection.prepare(
        "SELECT store_id,module,source_identity,logical_path,namespace_prefix FROM tb_stores",
    )?;
    let rows = statement.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
        ))
    })?;
    let mut prefixes = Vec::new();
    for row in rows {
        let (id, module, source, logical, prefix) = row?;
        let spec = StoreSpec::new(module, source, logical)?;
        if spec.id != id || spec.prefix != prefix {
            return Err(BusinessStoreError::InvalidStore);
        }
        prefixes.push(prefix);
    }
    for (name, (_, table, _)) in &actual {
        if !expected.contains_key(name)
            && !prefixes
                .iter()
                .any(|prefix| name.starts_with(prefix) && table.starts_with(prefix))
        {
            return Err(BusinessStoreError::InvalidContainerVersion);
        }
    }
    Ok(())
}

fn export_attached(
    store: &StoreSpec,
    target: &mut Connection,
    module_version: i64,
    expected: &StoreProof,
) -> BusinessStoreResult<StoreProof> {
    let tx = target.transaction()?;
    let objects = schema_objects(&tx, EXPORT_ALIAS, &store.prefix)?;
    let names: HashSet<String> = objects
        .iter()
        .map(|object| object.name[store.prefix.len()..].to_ascii_lowercase())
        .collect();
    let namespace = SQLiteStoreNamespace::new(store.prefix.clone(), names);
    drop_all_objects(&tx, "main")?;

    for object in objects.iter().filter(|object| object.kind == "table") {
        let sql = object
            .sql
            .as_deref()
            .ok_or_else(|| BusinessStoreError::UnsupportedSchema(object.name.clone()))?;
        let logical_sql = namespace.unbind(sql)?;
        tx.execute_batch(&logical_sql)?;
        let logical = object.name[store.prefix.len()..].to_string();
        copy_table(
            &tx,
            EXPORT_ALIAS,
            "main",
            &object.name,
            &logical,
            &logical_sql,
        )?;
    }
    for object in objects.iter().filter(|object| object.kind != "table") {
        if let Some(sql) = object.sql.as_deref() {
            tx.execute_batch(&namespace.unbind(sql)?)?;
        }
    }
    copy_sequences(&tx, EXPORT_ALIAS, "main", "", &store.prefix)?;
    tx.execute_batch(&format!("PRAGMA user_version={module_version}"))?;

    let actual = proof_for(&tx, "main", "", false, Some(module_version))?;
    if actual.row_count != expected.row_count
        || actual.rows_digest != expected.rows_digest
        || actual.table_counts != expected.table_counts
        || actual.module_user_version != expected.module_user_version
    {
        return Err(BusinessStoreError::ProofMismatch);
    }
    tx.commit()?;
    Ok(actual)
}

#[derive(Clone, Debug)]
struct SchemaObject {
    name: String,
    kind: String,
    sql: Option<String>,
}

fn schema_objects(
    connection: &Connection,
    schema: &str,
    prefix: &str,
) -> BusinessStoreResult<Vec<SchemaObject>> {
    let sql = format!(
        "SELECT name,type,sql FROM {schema}.sqlite_master WHERE name NOT LIKE 'sqlite_%' AND substr(name,1,?1)=?2 ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 WHEN 'trigger' THEN 3 ELSE 4 END,name"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![prefix.len() as i64, prefix], |row| {
        Ok(SchemaObject {
            name: row.get(0)?,
            kind: row.get(1)?,
            sql: row.get(2)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

fn validate_objects(
    connection: &Connection,
    schema: &str,
    objects: &[SchemaObject],
) -> BusinessStoreResult<()> {
    for object in objects {
        if !["table", "index", "view", "trigger"].contains(&object.kind.as_str()) {
            return Err(BusinessStoreError::UnsupportedSchema(object.kind.clone()));
        }
        if object.kind == "table" {
            let sql = object
                .sql
                .as_deref()
                .unwrap_or_default()
                .to_ascii_uppercase();
            if sql.contains("CREATE VIRTUAL TABLE") {
                return Err(BusinessStoreError::UnsupportedSchema(object.name.clone()));
            }
            let _ = table_columns(connection, schema, &object.name)?;
        }
    }
    Ok(())
}

fn table_columns(
    connection: &Connection,
    schema: &str,
    table: &str,
) -> BusinessStoreResult<Vec<String>> {
    Ok(table_xinfo_columns(connection, schema, table)?
        .into_iter()
        .filter(|(_, hidden)| *hidden == 0)
        .map(|(name, _)| name)
        .collect())
}

fn table_xinfo_columns(
    connection: &Connection,
    schema: &str,
    table: &str,
) -> BusinessStoreResult<Vec<(String, i64)>> {
    let sql = format!(
        "PRAGMA {schema}.table_xinfo({})",
        SQLiteStoreNamespace::quote(table)
    );
    let mut statement = connection.prepare(&sql)?;
    let columns = statement.query_map([], |row| {
        Ok((row.get::<_, String>(1)?, row.get::<_, i64>(6)?))
    })?;
    Ok(columns.collect::<Result<Vec<_>, _>>()?)
}

fn copy_table(
    connection: &Connection,
    source_schema: &str,
    target_schema: &str,
    source_table: &str,
    target_table: &str,
    logical_sql: &str,
) -> BusinessStoreResult<()> {
    let table_info = table_xinfo_columns(connection, source_schema, source_table)?;
    let rowid_columns = table_info
        .iter()
        .filter(|(_, hidden)| *hidden != 1)
        .map(|(name, _)| name.clone())
        .collect::<Vec<_>>();
    let mut columns = rowid_alias(logical_sql, &rowid_columns)?
        .into_iter()
        .collect::<Vec<_>>();
    columns.extend(
        table_info
            .iter()
            .filter(|(_, hidden)| *hidden == 0)
            .map(|(name, _)| name.clone()),
    );
    let source_ref = format!(
        "{source_schema}.{}",
        SQLiteStoreNamespace::quote(source_table)
    );
    let target_ref = format!(
        "{target_schema}.{}",
        SQLiteStoreNamespace::quote(target_table)
    );
    if columns.is_empty() {
        let count: i64 =
            connection.query_row(&format!("SELECT COUNT(*) FROM {source_ref}"), [], |row| {
                row.get(0)
            })?;
        for _ in 0..count {
            connection.execute(&format!("INSERT INTO {target_ref} DEFAULT VALUES"), [])?;
        }
        return Ok(());
    }
    let columns_sql = columns
        .iter()
        .map(|column| SQLiteStoreNamespace::quote(column))
        .collect::<Vec<_>>()
        .join(",");
    connection.execute(
        &format!("INSERT INTO {target_ref} ({columns_sql}) SELECT {columns_sql} FROM {source_ref}"),
        [],
    )?;
    Ok(())
}

fn copy_sequences(
    connection: &Connection,
    source_schema: &str,
    target_schema: &str,
    target_prefix: &str,
    source_prefix: &str,
) -> BusinessStoreResult<()> {
    if !has_table(connection, source_schema, "sqlite_sequence")? {
        return Ok(());
    }
    let sql = format!(
        "SELECT name,seq FROM {source_schema}.sqlite_sequence WHERE substr(name,1,?1)=?2 ORDER BY name"
    );
    let mut statement = connection.prepare(&sql)?;
    let sequences = statement
        .query_map(params![source_prefix.len() as i64, source_prefix], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if !has_table(connection, target_schema, "sqlite_sequence")? && !sequences.is_empty() {
        return Err(BusinessStoreError::UnsupportedSchema(
            "sqlite_sequence is absent in target".into(),
        ));
    }
    // Copying an empty AUTOINCREMENT table may create a zero sequence in
    // the destination even when the source has no sqlite_sequence row.
    // Replace only this partition's complete sequence set, including absence.
    if has_table(connection, target_schema, "sqlite_sequence")? {
        connection.execute(
            &format!("DELETE FROM {target_schema}.sqlite_sequence WHERE substr(name,1,?1)=?2"),
            params![target_prefix.len() as i64, target_prefix],
        )?;
    }
    for (source_name, sequence) in sequences {
        let logical = source_name
            .strip_prefix(source_prefix)
            .ok_or(BusinessStoreError::InvalidStore)?;
        let target_name = format!("{target_prefix}{logical}");
        connection.execute(
            &format!("DELETE FROM {target_schema}.sqlite_sequence WHERE name=?1"),
            [&target_name],
        )?;
        connection.execute(
            &format!("INSERT INTO {target_schema}.sqlite_sequence(name,seq) VALUES (?1,?2)"),
            params![target_name, sequence],
        )?;
    }
    Ok(())
}

fn has_table(connection: &Connection, schema: &str, table: &str) -> BusinessStoreResult<bool> {
    let sql = format!(
        "SELECT EXISTS(SELECT 1 FROM {schema}.sqlite_master WHERE type='table' AND name=?1)"
    );
    Ok(connection.query_row(&sql, [table], |row| row.get(0))?)
}

fn drop_store_objects(connection: &Connection, prefix: &str) -> BusinessStoreResult<()> {
    let mut statement = connection.prepare(
        "SELECT name,type FROM main.sqlite_master WHERE substr(name,1,?1)=?2 ORDER BY CASE type WHEN 'view' THEN 0 WHEN 'trigger' THEN 1 WHEN 'index' THEN 2 ELSE 3 END,name",
    )?;
    let objects = statement
        .query_map(params![prefix.len() as i64, prefix], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for (name, kind) in objects {
        drop_object(connection, "main", &kind, &name)?;
    }
    if has_table(connection, "main", "sqlite_sequence")? {
        connection.execute(
            "DELETE FROM main.sqlite_sequence WHERE substr(name,1,?1)=?2",
            params![prefix.len() as i64, prefix],
        )?;
    }
    Ok(())
}

fn canonical_input_path(path: &Path) -> BusinessStoreResult<String> {
    let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical
        .to_str()
        .map(str::to_owned)
        .ok_or(BusinessStoreError::InvalidStore)
}

fn write_legacy_receipt(
    connection: &Connection,
    receipt: &LegacyReceiptWrite,
) -> BusinessStoreResult<()> {
    connection.execute(
        "INSERT INTO tb_legacy_inputs(source_path,logical_path,store_id,module,source_digest,backup_path,retired) VALUES (?1,?2,?3,?4,?5,?6,0) ON CONFLICT(source_path) DO UPDATE SET logical_path=excluded.logical_path,store_id=excluded.store_id,module=excluded.module,source_digest=excluded.source_digest,backup_path=excluded.backup_path,retired=0 WHERE tb_legacy_inputs.retired=1",
        params![
            receipt.source_path,
            receipt.logical_path,
            receipt.store_id,
            receipt.module,
            receipt.source_digest,
            receipt.backup_path,
        ],
    )?;
    let matches: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM tb_legacy_inputs WHERE source_path=?1 AND logical_path=?2 AND store_id=?3 AND module=?4 AND source_digest=?5 AND backup_path=?6 AND retired=0)",
        params![
            receipt.source_path,
            receipt.logical_path,
            receipt.store_id,
            receipt.module,
            receipt.source_digest,
            receipt.backup_path,
        ],
        |row| row.get(0),
    )?;
    if !matches {
        return Err(BusinessStoreError::InvalidStore);
    }
    Ok(())
}

fn drop_all_objects(connection: &Connection, schema: &str) -> BusinessStoreResult<()> {
    let sql = format!(
        "SELECT name,type FROM {schema}.sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'view' THEN 0 WHEN 'trigger' THEN 1 WHEN 'index' THEN 2 ELSE 3 END,name"
    );
    let mut statement = connection.prepare(&sql)?;
    let objects = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for (name, kind) in objects {
        drop_object(connection, schema, &kind, &name)?;
    }
    Ok(())
}

fn drop_object(
    connection: &Connection,
    schema: &str,
    kind: &str,
    name: &str,
) -> BusinessStoreResult<()> {
    let kind = match kind {
        "table" => "TABLE",
        "index" => "INDEX",
        "view" => "VIEW",
        "trigger" => "TRIGGER",
        other => return Err(BusinessStoreError::UnsupportedSchema(other.to_string())),
    };
    connection.execute_batch(&format!(
        "DROP {kind} IF EXISTS {schema}.{}",
        SQLiteStoreNamespace::quote(name)
    ))?;
    Ok(())
}

fn proof_for(
    connection: &Connection,
    schema: &str,
    prefix: &str,
    unbind_schema: bool,
    module_version: Option<i64>,
) -> BusinessStoreResult<StoreProof> {
    if prefix.is_empty() && !unbind_schema {
        let sql = format!("PRAGMA {schema}.quick_check");
        let mut statement = connection.prepare(&sql)?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let checks = rows.collect::<Result<Vec<_>, _>>()?;
        if checks.len() != 1 || checks.first().map(String::as_str) != Some("ok") {
            return Err(BusinessStoreError::ProofMismatch);
        }
    }
    let module_user_version = if let Some(version) = module_version {
        version
    } else if prefix.is_empty() {
        connection.query_row(&format!("PRAGMA {schema}.user_version"), [], |row| {
            row.get(0)
        })?
    } else {
        connection.query_row(
            "SELECT user_version FROM main.tb_stores WHERE namespace_prefix=?1",
            [prefix],
            |row| row.get(0),
        )?
    };

    let raw_objects = if prefix.is_empty() {
        let mut statement = connection.prepare(&format!(
            "SELECT type,name,tbl_name,sql FROM {schema}.sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
        ))?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    } else {
        let mut statement = connection.prepare(&format!(
            "SELECT type,name,tbl_name,sql FROM {schema}.sqlite_master WHERE name NOT LIKE 'sqlite_%' AND (substr(name,1,?1)=?2 OR substr(tbl_name,1,?1)=?2) ORDER BY type,name"
        ))?;
        let rows = statement.query_map(params![prefix.len() as i64, prefix], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    let mut objects = Vec::with_capacity(raw_objects.len());
    for (kind, physical_name, physical_table, sql) in raw_objects {
        let name = if prefix.is_empty() {
            physical_name
        } else {
            strip_prefix_case_insensitive(&physical_name, prefix)
                .ok_or(BusinessStoreError::ProofMismatch)?
                .to_owned()
        };
        let table = if prefix.is_empty() {
            physical_table
        } else {
            strip_prefix_case_insensitive(&physical_table, prefix)
                .unwrap_or(&physical_table)
                .to_owned()
        };
        objects.push((
            kind.to_ascii_lowercase(),
            name,
            table,
            sql.unwrap_or_default(),
        ));
    }
    objects.sort_by_key(|(kind, name, _, _)| (kind.clone(), name.to_lowercase()));

    let logical_names = objects
        .iter()
        .map(|(_, name, _, _)| name.clone())
        .collect::<Vec<_>>();
    let namespace = SQLiteStoreNamespace::new(prefix.to_string(), logical_names);
    let mut rows_hash = Sha256::new();
    let mut schema_hash = Sha256::new();
    let mut table_counts = BTreeMap::new();
    let mut total = 0i64;
    update_text_fields(
        &mut schema_hash,
        &[
            "tokenbar-schema-proof-v1",
            "module-user-version",
            &module_user_version.to_string(),
        ],
    );

    for (kind, name, table, sql) in &objects {
        let logical_sql = if unbind_schema {
            namespace.unbind(sql)?
        } else {
            sql.clone()
        };
        let canonical_sql = SQLiteStoreNamespace::canonical_sql(&logical_sql)?;
        update_text_fields(
            &mut schema_hash,
            &["object", kind, &name.to_lowercase(), &table.to_lowercase()],
        );
        update_text_fields(&mut schema_hash, &[&canonical_sql]);
    }

    for (_kind, name, _, logical_sql) in objects.iter().filter(|(kind, _, _, _)| kind == "table") {
        let physical = format!("{prefix}{name}");
        let quoted = SQLiteStoreNamespace::quote(&physical);
        let xinfo = table_xinfo_rows(connection, schema, &physical)?;
        update_text_fields(&mut schema_hash, &["table-xinfo", &name.to_lowercase()]);
        for row_fields in &xinfo {
            for value in &row_fields.canonical_values {
                update_binary_field(&mut schema_hash, value);
            }
        }

        let foreign_key_sql = format!("PRAGMA {schema}.foreign_key_list({quoted})");
        let mut statement = connection.prepare(&foreign_key_sql)?;
        let mut rows = statement.query([])?;
        update_text_fields(
            &mut schema_hash,
            &["foreign-key-list", &name.to_lowercase()],
        );
        while let Some(row) = rows.next()? {
            let target: String = row.get::<_, Option<String>>(2)?.unwrap_or_default();
            let target = strip_prefix_case_insensitive(&target, prefix).unwrap_or(&target);
            let fields = [
                row.get::<_, i64>(0)?.to_string(),
                row.get::<_, i64>(1)?.to_string(),
                target.to_lowercase(),
                row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                row.get::<_, Option<String>>(6)?.unwrap_or_default(),
                row.get::<_, Option<String>>(7)?.unwrap_or_default(),
            ];
            update_text_fields(
                &mut schema_hash,
                &fields.iter().map(String::as_str).collect::<Vec<_>>(),
            );
        }

        let index_list_sql = format!("PRAGMA {schema}.index_list({quoted})");
        let mut statement = connection.prepare(&index_list_sql)?;
        let mut rows = statement.query([])?;
        let mut indexes = Vec::new();
        while let Some(row) = rows.next()? {
            let physical_index: String = row.get(1)?;
            indexes.push((
                logical_index_name(&physical_index, prefix),
                physical_index,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
            ));
        }
        indexes.sort_by_key(|(logical, _, _, _, _)| logical.to_lowercase());
        update_text_fields(&mut schema_hash, &["index-list", &name.to_lowercase()]);
        for (logical_index, physical_index, unique, origin, partial) in indexes {
            update_text_fields(
                &mut schema_hash,
                &[
                    &logical_index.to_lowercase(),
                    &unique.to_string(),
                    &origin,
                    &partial.to_string(),
                ],
            );
            let index_sql = format!(
                "PRAGMA {schema}.index_xinfo({})",
                SQLiteStoreNamespace::quote(&physical_index)
            );
            let mut statement = connection.prepare(&index_sql)?;
            let width = statement.column_count();
            let mut rows = statement.query([])?;
            while let Some(row) = rows.next()? {
                for column in 0..width {
                    update_canonical_value(&mut schema_hash, row.get_ref(column)?);
                }
            }
        }

        let columns = xinfo
            .iter()
            .filter(|column| column.hidden != 1)
            .map(|column| column.name.clone())
            .collect::<Vec<_>>();
        if columns.is_empty() {
            return Err(BusinessStoreError::UnsupportedSchema(name.clone()));
        }
        let rowid = rowid_alias(logical_sql, &columns)?;
        let projection = rowid
            .iter()
            .cloned()
            .chain(columns.iter().cloned())
            .map(|column| SQLiteStoreNamespace::quote(&column))
            .collect::<Vec<_>>();
        let order_by = projection
            .iter()
            .map(|column| format!("{column} COLLATE BINARY"))
            .collect::<Vec<_>>()
            .join(",");
        let table_ref = format!("{schema}.{quoted}");
        let query = format!(
            "SELECT {} FROM {table_ref} ORDER BY {order_by}",
            projection.join(",")
        );
        let mut statement = connection.prepare(&query)?;
        let width = statement.column_count();
        let mut rows = statement.query([])?;
        let mut count = 0i64;
        update_text_fields(&mut rows_hash, &["table", &name.to_lowercase()]);
        while let Some(row) = rows.next()? {
            for column in 0..width {
                update_canonical_value(&mut rows_hash, row.get_ref(column)?);
            }
            count += 1;
        }
        total += count;
        table_counts.insert(name.clone(), count);
    }

    // A logical proof must not depend on another module's AUTOINCREMENT use.
    update_text_fields(&mut rows_hash, &["sqlite-sequence"]);
    if has_table(connection, schema, "sqlite_sequence")? {
        let mut statement = connection.prepare(&format!(
            "SELECT name,seq FROM {schema}.sqlite_sequence ORDER BY name"
        ))?;
        let sequences = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter_map(|(physical, sequence)| {
                if prefix.is_empty() {
                    Some((physical, sequence))
                } else {
                    strip_prefix_case_insensitive(&physical, prefix)
                        .map(|logical| (logical.to_owned(), sequence))
                }
            })
            .collect::<Vec<_>>();
        for (name, sequence) in &sequences {
            update_text_fields(
                &mut rows_hash,
                &[&name.to_lowercase(), &sequence.to_string()],
            );
        }
        if !sequences.is_empty() {
            let sequence_count = sequences.len() as i64;
            total += sequence_count;
            table_counts.insert("sqlite_sequence".to_string(), sequence_count);
        }
    }

    Ok(StoreProof {
        row_count: total,
        rows_digest: hex_digest(&rows_hash.finalize()),
        schema_digest: hex_digest(&schema_hash.finalize()),
        table_counts,
        module_user_version,
    })
}

fn logical_footprint(connection: &Connection, prefix: &str) -> BusinessStoreResult<u64> {
    let mut statement = connection.prepare(
        "SELECT substr(name,?1) FROM main.sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND substr(name,1,?2)=?3 ORDER BY name",
    )?;
    let tables = statement
        .query_map(
            params![prefix.len() as i64 + 1, prefix.len() as i64, prefix],
            |row| row.get::<_, String>(0),
        )?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    let mut bytes = 0u64;
    for table in tables {
        bytes = bytes.saturating_add(table.len() as u64 + 1);
        let physical = format!("{prefix}{table}");
        let query = format!(
            "SELECT * FROM main.{}",
            SQLiteStoreNamespace::quote(&physical)
        );
        let mut statement = connection.prepare(&query)?;
        let width = statement.column_count();
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            for column in 0..width {
                bytes =
                    bytes.saturating_add(canonical_value_bytes(row.get_ref(column)?).len() as u64);
            }
        }
    }
    Ok(bytes)
}

struct TableXInfo {
    name: String,
    hidden: i64,
    canonical_values: Vec<Vec<u8>>,
}

fn table_xinfo_rows(
    connection: &Connection,
    schema: &str,
    table: &str,
) -> BusinessStoreResult<Vec<TableXInfo>> {
    let sql = format!(
        "PRAGMA {schema}.table_xinfo({})",
        SQLiteStoreNamespace::quote(table)
    );
    let mut statement = connection.prepare(&sql)?;
    let width = statement.column_count();
    let mut rows = statement.query([])?;
    let mut values = Vec::new();
    while let Some(row) = rows.next()? {
        let name = row.get::<_, String>(1)?;
        let hidden = row.get::<_, i64>(6)?;
        let mut canonical_values = Vec::with_capacity(width);
        for column in 0..width {
            canonical_values.push(canonical_value_bytes(row.get_ref(column)?));
        }
        values.push(TableXInfo {
            name,
            hidden,
            canonical_values,
        });
    }
    Ok(values)
}

fn update_text_fields(hash: &mut Sha256, fields: &[&str]) {
    for field in fields {
        update_binary_field(hash, field.as_bytes());
    }
}

fn update_binary_field(hash: &mut Sha256, field: &[u8]) {
    hash.update((field.len() as u64).to_be_bytes());
    hash.update(field);
}

fn update_canonical_value(hash: &mut Sha256, value: ValueRef<'_>) {
    let canonical = canonical_value_bytes(value);
    update_binary_field(hash, &canonical);
}

fn canonical_value_bytes(value: ValueRef<'_>) -> Vec<u8> {
    let (kind, bytes): (u8, Vec<u8>) = match value {
        ValueRef::Null => (5, Vec::new()),
        ValueRef::Integer(integer) => (1, integer.to_be_bytes().to_vec()),
        ValueRef::Real(real) => (2, real.to_bits().to_be_bytes().to_vec()),
        ValueRef::Text(text) => (3, text.to_vec()),
        ValueRef::Blob(blob) => (4, blob.to_vec()),
    };
    let mut canonical = Vec::with_capacity(9 + bytes.len());
    canonical.push(kind);
    canonical.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
    canonical.extend_from_slice(&bytes);
    canonical
}

fn strip_prefix_case_insensitive<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    value
        .get(..prefix.len())
        .filter(|head| head.eq_ignore_ascii_case(prefix))
        .map(|_| &value[prefix.len()..])
}

fn logical_index_name(physical: &str, prefix: &str) -> String {
    if let Some(suffix) = physical.strip_prefix("sqlite_autoindex_") {
        if let Some(logical) = strip_prefix_case_insensitive(suffix, prefix) {
            return format!("sqlite_autoindex_{logical}");
        }
    }
    strip_prefix_case_insensitive(physical, prefix)
        .unwrap_or(physical)
        .to_owned()
}

fn rowid_alias(sql: &str, columns: &[String]) -> BusinessStoreResult<Option<String>> {
    if SQLiteStoreNamespace::is_without_rowid(sql)? {
        return Ok(None);
    }
    let shadowed = columns
        .iter()
        .map(|column| column.to_lowercase())
        .collect::<HashSet<_>>();
    ["rowid", "_rowid_", "oid"]
        .iter()
        .find(|alias| !shadowed.contains(**alias))
        .map(|alias| Some((*alias).to_string()))
        .ok_or_else(|| BusinessStoreError::UnsupportedSchema("rowid is shadowed".into()))
}

fn valid_store_spec(store: &StoreSpec) -> bool {
    if store.id.len() != 64
        || !store
            .id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || store.prefix != format!("s{}_", store.id)
    {
        return false;
    }
    StoreSpec::new(
        store.module.clone(),
        store.source_identity.clone(),
        store.logical_path.clone(),
    )
    .is_ok_and(|expected| expected == *store)
}

fn hex_digest(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn readonly_file_uri(path: &Path) -> String {
    let path = path.to_string_lossy().replace('\\', "/");
    let mut encoded = String::with_capacity(path.len());
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b':' | b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            use std::fmt::Write as _;
            let _ = write!(encoded, "%{byte:02X}");
        }
    }
    format!("file:{encoded}?mode=ro")
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::OpenFlags;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let id = NEXT.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("business-container-{}-{id}", std::process::id()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn store(path: &Path, source: &str) -> StoreSpec {
        StoreSpec::new("usage", source, path.to_string_lossy().to_string()).unwrap()
    }

    #[test]
    fn namespace_clone_preserves_cyclic_foreign_keys_and_rolls_back_invalid_copy() {
        let fixture = Fixture::new();
        let original = fixture.path("cyclic.sqlite");
        let raw = Connection::open(&original).unwrap();
        raw.execute_batch("PRAGMA foreign_keys=OFF; CREATE TABLE a_child(id INTEGER PRIMARY KEY,parent_id INTEGER NOT NULL REFERENCES z_parent(id)); CREATE TABLE z_parent(id INTEGER PRIMARY KEY,child_id INTEGER NOT NULL REFERENCES a_child(id)); INSERT INTO a_child VALUES(11,22); INSERT INTO z_parent VALUES(22,11);").unwrap();
        drop(raw);
        let before = fs::read(&original).unwrap();
        let source = store(&fixture.path("source"), "source");
        let target = store(&fixture.path("target"), "target");
        let mut container = Container::open(fixture.path("a.sqlite")).unwrap();
        container.import_snapshot(&original, &source, fixture.path("backup.sqlite"), 1.0, false).unwrap();
        let proof = container.proof(&source).unwrap();
        assert_eq!(container.clone_store_namespace(&source, &target).unwrap(), proof);
        assert_eq!(container.proof(&target).unwrap(), proof);
        assert_eq!(container.connection.query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        // Corrupt only a synthetic source namespace. The rejected copy must
        // preserve the already-good target and restore FK enforcement.
        container.connection.execute_batch(&format!("PRAGMA foreign_keys=OFF; INSERT INTO {}a_child VALUES(33,999); PRAGMA foreign_keys=ON;", source.prefix)).unwrap();
        assert!(container.clone_store_namespace(&source, &target).is_err());
        assert_eq!(container.proof(&target).unwrap(), proof);
        assert_eq!(container.connection.query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        assert_eq!(fs::read(&original).unwrap(), before);
    }

    fn create_source(path: &Path, version: i64, id: i64, text: &str) -> Connection {
        let connection = Connection::open(path).unwrap();
        connection.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT, payload BLOB, maybe REAL, nullable TEXT, session_uuid TEXT); CREATE INDEX idx_records_value ON records(value);").unwrap();
        connection
            .execute(
                "INSERT INTO records(id,value,payload,maybe,nullable,session_uuid) VALUES (?1,?2,?3,?4,NULL,'same-uuid-in-each-home')",
                params![id, text, vec![0u8, 255, 7], 1.25f64],
            )
            .unwrap();
        connection
            .execute(
                "UPDATE sqlite_sequence SET seq=987 WHERE name='records'",
                [],
            )
            .unwrap();
        connection
            .execute_batch(&format!("PRAGMA user_version={version}"))
            .unwrap();
        connection
    }

    #[test]
    fn interrupted_backup_is_quarantined_and_rebuilt_without_touching_source() {
        let fixture = Fixture::new();
        let source_path = fixture.path("source.sqlite");
        let backup_path = fixture.path("backup.sqlite");
        drop(create_source(&source_path, 3, 17, "recover-me"));
        let source_digest = Container::snapshot_digest_path(&source_path).unwrap();
        let interrupted_bytes = b"partial sqlite backup from interrupted copy";
        fs::write(&backup_path, interrupted_bytes).unwrap();
        let sidecar_bytes = [
            ("-wal", b"interrupted WAL contents".as_slice()),
            ("-shm", b"interrupted shared memory".as_slice()),
            ("-journal", b"interrupted rollback journal".as_slice()),
        ];
        for (suffix, bytes) in sidecar_bytes {
            let mut sidecar = backup_path.as_os_str().to_os_string();
            sidecar.push(suffix);
            fs::write(PathBuf::from(sidecar), bytes).unwrap();
        }

        Container::ensure_verified_backup(&source_path, &backup_path, &source_digest).unwrap();

        assert_eq!(
            Container::snapshot_digest_path(&backup_path).unwrap(),
            source_digest
        );
        assert_eq!(
            Container::snapshot_digest_path(&source_path).unwrap(),
            source_digest
        );
        assert!(source_path.is_file());
        let quarantined = fs::read_dir(&fixture.0)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name().is_some_and(|name| {
                    name.to_string_lossy()
                        .starts_with(".tokenbar-backup-quarantine-")
                        && name.to_string_lossy().ends_with(".sqlite")
                })
            })
            .expect("interrupted backup should be preserved under a quarantine name");
        assert_eq!(fs::read(&quarantined).unwrap(), interrupted_bytes);
        for (suffix, expected_bytes) in sidecar_bytes {
            let mut sidecar = backup_path.as_os_str().to_os_string();
            sidecar.push(suffix);
            let sidecar = PathBuf::from(sidecar);
            assert!(
                !sidecar.exists(),
                "stale {suffix} must not be attached to the rebuilt backup"
            );
            let quarantined_sidecar = PathBuf::from(format!("{}{suffix}", quarantined.display()));
            assert_eq!(fs::read(quarantined_sidecar).unwrap(), expected_bytes);
        }
    }

    #[test]
    fn matching_backup_is_reused_without_rebuilding() {
        let fixture = Fixture::new();
        let source_path = fixture.path("source.sqlite");
        let backup_path = fixture.path("backup.sqlite");
        drop(create_source(&source_path, 3, 17, "already-backed-up"));
        Container::backup_snapshot(&source_path, &backup_path).unwrap();
        let expected_digest = Container::snapshot_digest_path(&source_path).unwrap();
        let backup_bytes = fs::read(&backup_path).unwrap();

        Container::ensure_verified_backup_with(
            &source_path,
            &backup_path,
            &expected_digest,
            |_, _| panic!("matching backup should be reused"),
        )
        .unwrap();

        assert_eq!(fs::read(backup_path).unwrap(), backup_bytes);
    }

    #[test]
    fn failed_partial_backup_is_never_published() {
        let fixture = Fixture::new();
        let source_path = fixture.path("source.sqlite");
        let backup_path = fixture.path("backup.sqlite");
        drop(create_source(&source_path, 3, 17, "source-remains"));
        let expected_digest = Container::snapshot_digest_path(&source_path).unwrap();

        let result = Container::ensure_verified_backup_with(
            &source_path,
            &backup_path,
            &expected_digest,
            |_, temporary| {
                fs::write(temporary, b"partial write")?;
                Err(BusinessStoreError::ProofMismatch)
            },
        );

        assert!(matches!(result, Err(BusinessStoreError::ProofMismatch)));
        assert!(!backup_path.exists());
        assert_eq!(
            Container::snapshot_digest_path(&source_path).unwrap(),
            expected_digest
        );
        let leftover_temporary = fs::read_dir(&fixture.0)
            .unwrap()
            .filter_map(Result::ok)
            .any(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .contains("codex-token-bar-")
            });
        assert!(!leftover_temporary);
    }

    fn import_and_check_round_trip(
        fixture: &Fixture,
        container: &mut Container,
        source: &Path,
        store: &StoreSpec,
        label: &str,
        now: f64,
    ) -> StoreProof {
        let proof = container
            .import_snapshot(
                source,
                store,
                fixture.path(&format!("{label}-backup.sqlite")),
                now,
                false,
            )
            .unwrap();
        assert_eq!(
            container.proof(store).unwrap(),
            proof,
            "target proof for {label}"
        );
        let mut exported =
            Connection::open(fixture.path(&format!("{label}-export.sqlite"))).unwrap();
        assert_eq!(container.export_to(store, &mut exported).unwrap(), proof);
        assert_eq!(
            proof_for(&exported, "main", "", false, None).unwrap(),
            proof
        );
        proof
    }

    #[test]
    fn snapshots_prove_independently_of_other_stores_autoincrement_metadata() {
        let fixture = Fixture::new();
        let mut container = Container::open(fixture.path("container.sqlite")).unwrap();

        // Establish sqlite_sequence in the destination before importing the
        // non-AUTOINCREMENT ModelTrace schema used by the production fixture.
        let auto_path = fixture.path("auto-source.sqlite");
        let auto = Connection::open(&auto_path).unwrap();
        auto.execute_batch(
            "CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL);\
             INSERT INTO events(id,payload) VALUES(7,'kept');\
             PRAGMA user_version=1;",
        )
        .unwrap();
        drop(auto);
        let auto_store = StoreSpec::new("fixture_auto", "auto", "fixture/auto").unwrap();
        let auto_proof = import_and_check_round_trip(
            &fixture,
            &mut container,
            &auto_path,
            &auto_store,
            "auto",
            1.0,
        );
        assert_eq!(auto_proof.table_counts["events"], 1);
        assert_eq!(
            container
                .connection()
                .query_row(
                    "SELECT seq FROM sqlite_sequence WHERE name=?1",
                    [&format!("{}events", auto_store.prefix)],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            7
        );

        let modeltrace_path = fixture.path("modeltrace-source.sqlite");
        let modeltrace = Connection::open(&modeltrace_path).unwrap();
        modeltrace
            .execute_batch(
                "CREATE TABLE modeltrace_runs(scope TEXT NOT NULL,id TEXT PRIMARY KEY,started_at INTEGER NOT NULL,payload TEXT NOT NULL);\
                 CREATE INDEX modeltrace_scope_time ON modeltrace_runs(scope,started_at DESC);\
                 CREATE TABLE modeltrace_settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL);\
                 INSERT INTO modeltrace_runs VALUES('scope','run-1',10,'{}');\
                 PRAGMA user_version=0;",
            )
            .unwrap();
        drop(modeltrace);
        let modeltrace_store =
            StoreSpec::new("fixture_modeltrace", "modeltrace", "fixture/modeltrace").unwrap();
        let modeltrace_proof = import_and_check_round_trip(
            &fixture,
            &mut container,
            &modeltrace_path,
            &modeltrace_store,
            "modeltrace",
            2.0,
        );
        assert_eq!(modeltrace_proof.table_counts["modeltrace_runs"], 1);
        assert!(!modeltrace_proof
            .table_counts
            .contains_key("sqlite_sequence"));

        let empty_auto_path = fixture.path("empty-auto-source.sqlite");
        let empty_auto = Connection::open(&empty_auto_path).unwrap();
        empty_auto
            .execute_batch(
                "CREATE TABLE pending(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL);\
                 PRAGMA user_version=3;",
            )
            .unwrap();
        let source_sequence_table: bool = empty_auto
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='sqlite_sequence')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let source_sequence_rows: i64 = empty_auto
            .query_row("SELECT COUNT(*) FROM sqlite_sequence", [], |row| row.get(0))
            .unwrap();
        assert!(source_sequence_table);
        assert_eq!(source_sequence_rows, 0);
        drop(empty_auto);
        let empty_auto_store =
            StoreSpec::new("fixture_empty_auto", "empty", "fixture/empty-auto").unwrap();
        container.register(&empty_auto_store).unwrap();
        container
            .connection()
            .execute(
                "INSERT INTO sqlite_sequence(name,seq) VALUES(?1,0)",
                [&format!("{}pending", empty_auto_store.prefix)],
            )
            .unwrap();
        let empty_proof = import_and_check_round_trip(
            &fixture,
            &mut container,
            &empty_auto_path,
            &empty_auto_store,
            "empty-auto",
            3.0,
        );
        assert_eq!(empty_proof.table_counts["pending"], 0);
        assert!(!empty_proof.table_counts.contains_key("sqlite_sequence"));
        assert_eq!(
            container
                .connection()
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_sequence WHERE name=?1",
                    [&format!("{}pending", empty_auto_store.prefix)],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            0
        );
        assert_eq!(
            container
                .connection()
                .query_row(
                    "SELECT seq FROM sqlite_sequence WHERE name=?1",
                    [&format!("{}events", auto_store.prefix)],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            7
        );
    }

    #[test]
    fn retired_legacy_input_receipt_survives_namespace_removal_and_blocks_replay() {
        let fixture = Fixture::new();
        let container_path = fixture.path("codex-ledger.sqlite");
        let original_path = fixture.path("retained-stage.sqlite");
        let snapshot_path = fixture.path("snapshot.sqlite");
        drop(create_source(&original_path, 3, 17, "stage-one"));
        Container::backup_snapshot(&original_path, &snapshot_path).unwrap();

        let old_store = StoreSpec::new("exact", "job-1", "exact/staging/job-1").unwrap();
        let mut container = Container::open(&container_path).unwrap();
        let proof = container
            .import_legacy_snapshot(
                &snapshot_path,
                &old_store,
                &original_path,
                &snapshot_path,
                10.0,
                false,
            )
            .unwrap()
            .expect("first import should create the job store");
        assert_eq!(proof.row_count, 2);
        let active = container
            .legacy_input_receipt(&original_path)
            .unwrap()
            .unwrap();
        assert!(!active.retired);
        assert_eq!(active.store_id, old_store.id);

        container.remove_store_namespace(&old_store).unwrap();
        let retired = container
            .legacy_input_receipt(&original_path)
            .unwrap()
            .unwrap();
        assert!(retired.retired);
        assert_eq!(retired.source_digest, active.source_digest);

        let new_store = StoreSpec::new("exact", "job-2", "exact/staging/job-1").unwrap();
        assert!(container
            .import_legacy_snapshot(
                &snapshot_path,
                &new_store,
                &original_path,
                &snapshot_path,
                11.0,
                false,
            )
            .unwrap()
            .is_none());
        let logical = container.into_store_connection(&new_store).unwrap();
        assert!(!logical.has_logical_object("records").unwrap());
        assert!(original_path.is_file());
    }

    #[test]
    fn retired_legacy_input_can_be_reused_for_newer_stage_contents() {
        let fixture = Fixture::new();
        let container_path = fixture.path("codex-ledger.sqlite");
        let original_path = fixture.path("reused-stage.sqlite");
        let first_snapshot = fixture.path("first-snapshot.sqlite");
        let second_snapshot = fixture.path("second-snapshot.sqlite");
        drop(create_source(&original_path, 3, 17, "stage-one"));
        Container::backup_snapshot(&original_path, &first_snapshot).unwrap();

        let old_store = StoreSpec::new("exact", "job-old", "exact/staging/reused").unwrap();
        let mut container = Container::open(&container_path).unwrap();
        container
            .import_legacy_snapshot(
                &first_snapshot,
                &old_store,
                &original_path,
                &first_snapshot,
                20.0,
                false,
            )
            .unwrap();
        container.remove_store_namespace(&old_store).unwrap();

        let changed = Connection::open(&original_path).unwrap();
        changed
            .execute("UPDATE records SET value='stage-two' WHERE id=17", [])
            .unwrap();
        drop(changed);
        Container::backup_snapshot(&original_path, &second_snapshot).unwrap();
        let new_store = StoreSpec::new("exact", "job-new", "exact/staging/reused").unwrap();
        let proof = container
            .import_legacy_snapshot(
                &second_snapshot,
                &new_store,
                &original_path,
                &second_snapshot,
                21.0,
                false,
            )
            .unwrap()
            .expect("changed contents after retirement are a new job input");
        assert_eq!(proof.row_count, 2);
        let receipt = container
            .legacy_input_receipt(&original_path)
            .unwrap()
            .unwrap();
        assert_eq!(receipt.store_id, new_store.id);
        assert!(!receipt.retired);
        let logical = container.into_store_connection(&new_store).unwrap();
        let value: String = logical
            .query_row("SELECT value FROM records WHERE id=17", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(value, "stage-two");
    }

    #[test]
    fn proof_and_round_trip_preserve_schema_details_and_hidden_rowids() {
        let fixture = Fixture::new();
        let container_path = fixture.path("codex-ledger.sqlite");
        let source_path = fixture.path("schema-rich.sqlite");
        let snapshot_path = fixture.path("snapshot.sqlite");
        let source = Connection::open(&source_path).unwrap();
        source.execute_batch(
            "PRAGMA foreign_keys=ON;
             CREATE TABLE parent(
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                payload BLOB,
                note TEXT,
                generated TEXT GENERATED ALWAYS AS (key || '!') STORED
             );
             CREATE TABLE child(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                parent_key TEXT REFERENCES parent(key) ON DELETE CASCADE,
                note TEXT CHECK(note IS NULL OR length(note)>0)
             );
             CREATE INDEX child_note_ix ON child(note DESC) WHERE note IS NOT NULL;
             CREATE VIEW child_summary AS SELECT parent_key,count(*) AS child_count FROM child GROUP BY parent_key;
             CREATE TRIGGER child_note_update AFTER UPDATE OF note ON child BEGIN
                UPDATE parent SET note=NEW.note WHERE key=NEW.parent_key;
             END;
             CREATE TABLE rowid_holes(key TEXT,value TEXT);
             CREATE TABLE without_rowid(key TEXT PRIMARY KEY,value TEXT) WITHOUT ROWID;
             PRAGMA user_version=17;
             INSERT INTO parent(key,payload,note) VALUES('key-1',X'00FF000D',CAST(X'610062' AS TEXT));
             INSERT INTO child(parent_key,note) VALUES('key-1',CAST(X'780079' AS TEXT));
             INSERT INTO rowid_holes(rowid,key,value) VALUES(99,'deleted','x'),(150,'retained','y');
             DELETE FROM rowid_holes WHERE rowid=99;
             INSERT INTO without_rowid(key,value) VALUES('stable','value');",
        ).unwrap();
        drop(source);
        Container::backup_snapshot(&source_path, &snapshot_path).unwrap();

        let store = StoreSpec::new("exact", "schema-proof", "exact/schema-proof").unwrap();
        let mut container = Container::open(&container_path).unwrap();
        let source_proof = container
            .import_snapshot(&snapshot_path, &store, &snapshot_path, 30.0, false)
            .unwrap();
        let actual_proof = container.proof(&store).unwrap();
        assert_eq!(actual_proof, source_proof);

        let exported_path = fixture.path("round-trip.sqlite");
        let mut exported = Connection::open(&exported_path).unwrap();
        container.export_to(&store, &mut exported).unwrap();
        let exported_proof = proof_for(&exported, "main", "", false, None).unwrap();
        assert_eq!(exported_proof, source_proof);
        let retained_rowid: i64 = exported
            .query_row("SELECT rowid FROM rowid_holes", [], |row| row.get(0))
            .unwrap();
        assert_eq!(retained_rowid, 150);
    }

    #[test]
    fn store_ids_are_stable_and_separate_two_source_homes() {
        let first = StoreSpec::new("usage", "/home/a", "/home/a/usage.sqlite").unwrap();
        let same = StoreSpec::new("usage", "/home/a", "/home/a/usage.sqlite").unwrap();
        let second = StoreSpec::new("usage", "/home/b", "/home/b/usage.sqlite").unwrap();
        assert_eq!(first, same);
        assert_ne!(first.id, second.id);
        assert_ne!(first.prefix, second.prefix);
        assert_eq!(first.id.len(), 64);
    }

    #[test]
    fn imports_are_partitioned_idempotent_and_preserve_sqlite_sequence() {
        let fixture = Fixture::new();
        let source_path = fixture.path("source.sqlite");
        let source = create_source(&source_path, 23, 501, "with\0nul");
        let container_path = fixture.path("container.sqlite");
        let mut container = Container::open(&container_path).unwrap();
        let one = store(&fixture.path("logical-a"), "/home/a");
        let two = store(&fixture.path("logical-b"), "/home/b");
        container.register(&one).unwrap();
        container.register(&two).unwrap();
        let proof = container
            .import_snapshot(&source_path, &one, fixture.path("backup-a"), 10.0, false)
            .unwrap();
        assert_eq!(proof.table_counts["records"], 1);
        assert_eq!(container.user_version(&one).unwrap(), 23);
        let physical: i64 = container
            .connection()
            .query_row(
                &format!(
                    "SELECT id FROM {}",
                    SQLiteStoreNamespace::quote(&format!("{}records", one.prefix))
                ),
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(physical, 501);
        let receipt_count: i64 = container
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM tb_store_imports WHERE store_id=?1",
                [&one.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(receipt_count, 1);
        let receipt: (String, f64) = container
            .connection()
            .query_row(
                "SELECT backup_path,imported_at FROM tb_store_imports WHERE store_id=?1",
                [&one.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(receipt.0, fixture.path("backup-a").to_string_lossy());
        assert_eq!(receipt.1, 10.0);
        let again = container
            .import_snapshot(
                &source_path,
                &one,
                fixture.path("backup-again"),
                11.0,
                false,
            )
            .unwrap();
        assert_eq!(again, proof);
        assert_eq!(
            container
                .connection()
                .query_row::<i64, _, _>(
                    "SELECT COUNT(*) FROM tb_store_imports WHERE store_id=?1",
                    [&one.id],
                    |row| row.get(0)
                )
                .unwrap(),
            1
        );
        let second_source_path = fixture.path("source-home-b.sqlite");
        let second_source = create_source(&second_source_path, 31, 501, "home-b");
        let two_proof = container
            .import_snapshot(
                &second_source_path,
                &two,
                fixture.path("backup-b"),
                10.0,
                false,
            )
            .unwrap();
        assert_ne!(two_proof.rows_digest, proof.rows_digest);
        assert_ne!(one.id, two.id);
        let second_id: i64 = container
            .connection()
            .query_row(
                &format!(
                    "SELECT id FROM {}",
                    SQLiteStoreNamespace::quote(&format!("{}records", two.prefix))
                ),
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(second_id, 501);
        let second_uuid: String = container
            .connection()
            .query_row(
                &format!(
                    "SELECT session_uuid FROM {}",
                    SQLiteStoreNamespace::quote(&format!("{}records", two.prefix))
                ),
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(second_uuid, "same-uuid-in-each-home");
        assert_eq!(
            second_source
                .query_row::<String, _, _>("SELECT value FROM records", [], |row| row.get(0))
                .unwrap(),
            "home-b"
        );
        let second_sequence: i64 = container
            .connection()
            .query_row(
                "SELECT seq FROM sqlite_sequence WHERE name=?1",
                [&format!("{}records", two.prefix)],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(second_sequence, 987);
        assert_eq!(
            source
                .query_row::<i64, _, _>("PRAGMA user_version", [], |row| row.get(0))
                .unwrap(),
            23
        );
        assert_eq!(
            source
                .query_row::<i64, _, _>("SELECT COUNT(*) FROM records", [], |row| row.get(0))
                .unwrap(),
            1
        );
    }

    #[test]
    fn wal_snapshot_reads_committed_rows_without_touching_source() {
        let fixture = Fixture::new();
        let source_path = fixture.path("with wal #.sqlite");
        let source = Connection::open(&source_path).unwrap();
        source.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE t(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO t VALUES (1,'wal row');").unwrap();
        let mut container = Container::open(fixture.path("container.sqlite")).unwrap();
        let spec = store(&fixture.path("logical"), "home");
        let proof = container
            .import_snapshot(&source_path, &spec, fixture.path("backup"), 1.0, false)
            .unwrap();
        assert_eq!(proof.table_counts["t"], 1);
        assert_eq!(
            source
                .query_row::<String, _, _>("SELECT value FROM t", [], |row| row.get(0))
                .unwrap(),
            "wal row"
        );
    }

    #[test]
    fn failed_import_rolls_back_only_the_requested_namespace() {
        let fixture = Fixture::new();
        let good_path = fixture.path("good.sqlite");
        let good = create_source(&good_path, 1, 1, "good");
        let mut container = Container::open(fixture.path("container.sqlite")).unwrap();
        let one = store(&fixture.path("one"), "home-one");
        let two = store(&fixture.path("two"), "home-two");
        container
            .import_snapshot(&good_path, &one, fixture.path("backup-one"), 1.0, false)
            .unwrap();
        container
            .import_snapshot(&good_path, &two, fixture.path("backup-two"), 1.0, false)
            .unwrap();
        drop(good);

        let bad_path = fixture.path("constraint-failure.sqlite");
        let bad = Connection::open(&bad_path).unwrap();
        bad.execute_batch("CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT CHECK(value='ok')); PRAGMA ignore_check_constraints=ON; INSERT INTO records VALUES (1,'bad');").unwrap();
        let before_one = container.proof(&one).unwrap();
        let before_two = container.proof(&two).unwrap();
        let error = container
            .import_snapshot(&bad_path, &one, fixture.path("backup-bad"), 2.0, true)
            .unwrap_err();
        assert!(matches!(error, BusinessStoreError::Sql(_)));
        assert_eq!(container.proof(&one).unwrap(), before_one);
        assert_eq!(container.proof(&two).unwrap(), before_two);
        assert_eq!(
            container
                .connection()
                .query_row::<i64, _, _>("SELECT COUNT(*) FROM tb_store_imports", [], |row| row
                    .get(0))
                .unwrap(),
            2
        );
    }

    #[test]
    fn explicit_replace_changes_only_one_store_and_exports_round_trip() {
        let fixture = Fixture::new();
        let first_source_path = fixture.path("first.sqlite");
        let first_source = create_source(&first_source_path, 7, 10, "first");
        let second_source_path = fixture.path("second.sqlite");
        let second_source = create_source(&second_source_path, 9, 20, "second");
        let mut container = Container::open(fixture.path("container.sqlite")).unwrap();
        let one = store(&fixture.path("one"), "home-one");
        let two = store(&fixture.path("two"), "home-two");
        container
            .import_snapshot(
                &first_source_path,
                &one,
                fixture.path("backup-1"),
                1.0,
                false,
            )
            .unwrap();
        container
            .import_snapshot(
                &second_source_path,
                &two,
                fixture.path("backup-2"),
                1.0,
                false,
            )
            .unwrap();
        let two_before = container.proof(&two).unwrap();
        let next_source_path = fixture.path("next.sqlite");
        let next_source = create_source(&next_source_path, 8, 88, "replacement");
        container
            .import_snapshot(&next_source_path, &one, fixture.path("backup-3"), 3.0, true)
            .unwrap();
        let old_baseline = container
            .import_snapshot(
                &first_source_path,
                &one,
                fixture.path("backup-old-replay"),
                4.0,
                false,
            )
            .unwrap();
        assert_ne!(
            old_baseline.rows_digest,
            container.proof(&one).unwrap().rows_digest
        );
        assert_eq!(container.user_version(&one).unwrap(), 8);
        assert_eq!(container.proof(&two).unwrap(), two_before);

        let mut exported = Connection::open_in_memory().unwrap();
        let expected = container.proof(&one).unwrap();
        let actual = container.export_to(&one, &mut exported).unwrap();
        assert_eq!(actual.row_count, expected.row_count);
        assert_eq!(actual.rows_digest, expected.rows_digest);
        assert_eq!(
            exported
                .query_row::<i64, _, _>("PRAGMA user_version", [], |row| row.get(0))
                .unwrap(),
            8
        );
        assert_eq!(
            exported
                .query_row::<i64, _, _>("SELECT id FROM records", [], |row| row.get(0))
                .unwrap(),
            88
        );
        assert_eq!(
            exported
                .query_row::<i64, _, _>(
                    "SELECT seq FROM sqlite_sequence WHERE name='records'",
                    [],
                    |row| row.get(0)
                )
                .unwrap(),
            987
        );
        assert_eq!(
            exported
                .query_row::<String, _, _>("SELECT value FROM records", [], |row| row.get(0))
                .unwrap(),
            "replacement"
        );
        assert_eq!(exported.query_row::<String,_,_>("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_records_value'", [], |row| row.get(0)).unwrap(), "idx_records_value");
        assert_eq!(
            first_source
                .query_row::<i64, _, _>("SELECT id FROM records", [], |row| row.get(0))
                .unwrap(),
            10
        );
        assert_eq!(
            second_source
                .query_row::<i64, _, _>("SELECT id FROM records", [], |row| row.get(0))
                .unwrap(),
            20
        );
        assert_eq!(
            next_source
                .query_row::<i64, _, _>("SELECT id FROM records", [], |row| row.get(0))
                .unwrap(),
            88
        );
    }

    #[test]
    fn proof_distinguishes_blob_null_real_and_embedded_nul_text() {
        let fixture = Fixture::new();
        let source_path = fixture.path("source.sqlite");
        let source = Connection::open(&source_path).unwrap();
        source
            .execute_batch("CREATE TABLE typed(v BLOB, n TEXT, r REAL, t TEXT)")
            .unwrap();
        source
            .execute(
                "INSERT INTO typed VALUES (?1,NULL,?2,?3)",
                params![vec![0u8, 1, 255], 1.0f64 / 3.0, "a\0b"],
            )
            .unwrap();
        let mut container = Container::open(fixture.path("container.sqlite")).unwrap();
        let spec = store(&fixture.path("logical"), "home");
        let proof = container
            .import_snapshot(&source_path, &spec, fixture.path("backup"), 1.0, false)
            .unwrap();
        assert_eq!(proof.table_counts["typed"], 1);
        let again = container.proof(&spec).unwrap();
        assert_eq!(proof.rows_digest, again.rows_digest);
    }

    #[test]
    fn container_rejects_foreign_versions_before_ddl_and_versions_new_a() {
        let fixture = Fixture::new();
        let foreign_path = fixture.path("foreign.sqlite");
        let connection = Connection::open(&foreign_path).unwrap();
        connection.execute_batch("PRAGMA user_version=41").unwrap();
        drop(connection);
        assert!(matches!(
            Container::open(&foreign_path),
            Err(BusinessStoreError::InvalidContainerVersion)
        ));
        let preserved = Connection::open(&foreign_path).unwrap();
        let foreign_version: i64 = preserved
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        let foreign_tables: i64 = preserved
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(foreign_version, 41);
        assert_eq!(foreign_tables, 0);

        let foreign_v1 = fixture.path("foreign-v1.sqlite");
        let foreign = Connection::open(&foreign_v1).unwrap();
        foreign.execute_batch("CREATE TABLE foreign_records(id INTEGER); INSERT INTO foreign_records VALUES(7); PRAGMA user_version=1;").unwrap();
        drop(foreign);
        assert!(Container::open(&foreign_v1).is_err());
        let preserved_v1 = Connection::open(&foreign_v1).unwrap();
        assert_eq!(
            preserved_v1
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
                    [],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(
            preserved_v1
                .query_row("SELECT id FROM foreign_records", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            7
        );

        let path = fixture.path("container.sqlite");
        let container = Container::open(&path).unwrap();
        let journal: String = container
            .connection()
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        let version: i64 = container
            .connection()
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(journal.to_ascii_lowercase(), "wal");
        assert_eq!(version, 1);
        assert_eq!(
            container
                .connection()
                .query_row::<String, _, _>(
                    "SELECT value FROM tb_container_meta WHERE key='schema_version'",
                    [],
                    |row| row.get(0)
                )
                .unwrap(),
            "1"
        );
    }

    #[test]
    fn import_keeps_source_open_read_only() {
        let fixture = Fixture::new();
        let source_path = fixture.path("source.sqlite");
        let source = create_source(&source_path, 4, 6, "immutable");
        let mut container = Container::open(fixture.path("container.sqlite")).unwrap();
        let spec = store(&fixture.path("logical"), "home");
        container
            .import_snapshot(&source_path, &spec, fixture.path("backup"), 1.0, false)
            .unwrap();
        assert!(matches!(
            source.execute(
                "INSERT INTO records(value) VALUES ('still writable by owner')",
                []
            ),
            Ok(_)
        ));
        assert_eq!(
            source
                .query_row::<String, _, _>("SELECT value FROM records WHERE id=6", [], |row| row
                    .get(0))
                .unwrap(),
            "immutable"
        );
        drop(source);
        let read_only =
            Connection::open_with_flags(&source_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        assert_eq!(
            read_only
                .query_row::<i64, _, _>("SELECT COUNT(*) FROM records", [], |row| row.get(0))
                .unwrap(),
            2
        );
    }
}
