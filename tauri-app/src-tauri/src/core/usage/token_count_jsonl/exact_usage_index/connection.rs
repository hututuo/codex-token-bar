//! Connection opening, integrity admission and close-time receipts.
//!
//! This is a stateful storage boundary, NOT a read-only utility module. Legacy
//! names such as open_read_only_index/existing_regular_index may initialize a
//! pool, restore an artifact or enter import/registration in production.
//! Published readers and external live sources have separate, restricted opens.
//! Keep ManagedIndexConnection, its Drop, per-path gates and active counts
//! together. The parent retains its Home lease and cross-process operation lock;
//! no connection, lock acquisition or transaction is added by this boundary.

#[cfg(not(test))]
pub(super) use crate::core::business_store_connection::{StoreConnection as Connection, StoreTransaction as Transaction};
#[cfg(test)]
pub(super) use rusqlite::{Connection, Transaction};
#[cfg(not(test))]
use crate::core::business_store_connection::StoreConnection as BoundStoreConnection;
use super::contracts::{
    FileSignature, EXACT_SESSION_PARSER_REVISION, PRE_COMPACTION_SESSION_PARSER_REVISION,
    LEGACY_SESSION_PARSER_REVISION, LEGACY_STAGED_PARSER_REVISION,
    PAGINATED_V4_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION,
    PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION,
    ORPHAN_REPAIR_REVISION_KEY, ORPHAN_REPAIR_REVISION, sqlite_sidecar_path,
};
use super::store_metadata::{metadata_i64, metadata_text, set_metadata};
use super::{file_signature, IndexPreparationTrace, Schema11ValidatedStorage,
    database_path, assess_index_migration, MigrationAssessment,
    schema11_receipt_matches_current, schema11_receipt_metadata_matches};
#[cfg(not(test))]
use super::stage_pool;
#[cfg(test)]
use super::{ExactUsageIndex, OPEN_DDL_COUNT};
use crate::core::{atomic_file, sqlite, startup_trace};
#[cfg(test)]
use rusqlite::OpenFlags;
use rusqlite::{OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
#[cfg(test)]
use std::collections::HashSet;
use std::fs;
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::{Barrier, atomic::{AtomicBool, AtomicU64, Ordering}};
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::time::Duration as StdDuration;

const INDEX_INTEGRITY_RECEIPT_VERSION: u32 = 2;
pub(super) const INDEX_INTEGRITY_RECEIPT_SUFFIX: &str = ".integrity-receipt.json";

pub(super) struct ManagedIndexConnection {
    connection: Option<Connection>,
    pub(super) path: PathBuf,
    receipt_eligible: bool,
    tracks_integrity: bool,
}

#[cfg(test)]
fn run_integrity_gate_enter_hook_for_testing(path: &Path) {
    let Some(slot) = INTEGRITY_GATE_ENTER_HOOK.get() else {
        return;
    };
    let hook = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(hook) = hook.as_ref() {
        hook(path);
    }
}

#[cfg(not(test))]
fn run_integrity_gate_enter_hook_for_testing(_path: &Path) {}

#[cfg(test)]
fn run_integrity_gate_release_hook_for_testing(path: &Path) {
    let Some(slot) = INTEGRITY_GATE_RELEASE_HOOK.get() else {
        return;
    };
    let hook = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(hook) = hook.as_ref() {
        hook(path);
    }
}

#[cfg(not(test))]
fn run_integrity_gate_release_hook_for_testing(_path: &Path) {}

#[cfg(test)]
fn run_before_finish_index_connection_hook_for_testing(path: &Path) {
    let Some(slot) = BEFORE_FINISH_INDEX_CONNECTION_HOOK.get() else {
        return;
    };
    let hook = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(hook) = hook.as_ref() {
        hook(path);
    }
}

#[cfg(not(test))]
fn run_before_finish_index_connection_hook_for_testing(_path: &Path) {}

impl ManagedIndexConnection {
    fn from_registered(connection: Connection, path: PathBuf) -> Self {
        Self {
            connection: Some(connection),
            path,
            receipt_eligible: false,
            tracks_integrity: true,
        }
    }

    pub(super) fn mark_receipt_eligible(&mut self) {
        self.receipt_eligible = true;
    }

    pub(super) fn mark_receipt_dirty(&mut self) {
        self.receipt_eligible = false;
    }
}

impl Deref for ManagedIndexConnection {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        self.connection
            .as_ref()
            .expect("managed exact index connection is available before drop")
    }
}

impl DerefMut for ManagedIndexConnection {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.connection
            .as_mut()
            .expect("managed exact index connection is available before drop")
    }
}

impl Drop for ManagedIndexConnection {
    fn drop(&mut self) {
        if !self.tracks_integrity {
            drop(self.connection.take());
            return;
        }
        let receipt = if self.receipt_eligible {
            self.connection
                .as_ref()
                .and_then(|connection| receipt_metadata(connection, &self.path).ok())
        } else {
            None
        };
        drop(self.connection.take());

        // Receipt I/O and the post-close storage signature must stay outside
        // INDEX_INTEGRITY_STATES. The per-path gate serializes concurrent
        // close-time receipts without coupling different index paths.
        let gate = index_integrity_gate(&self.path);
        let _gate_guard = gate.enter(&self.path);
        let signature_after_close = index_storage_signature(&self.path).ok();
        if let (Some(receipt), Some(signature)) = (receipt, signature_after_close) {
            write_integrity_receipt_best_effort(&self.path, receipt, signature);
        }
        run_before_finish_index_connection_hook_for_testing(&self.path);
        let states = index_integrity_states();
        let mut states = states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        finish_index_connection(&mut states, &self.path);
        drop(states);
        drop(_gate_guard);
    }
}

/// Runtime readers only consult the registered A namespace. Never enter the
/// legacy import/registration route, even while another owner is publishing.
/// Migration and staging callers continue to use their separate open path.
pub(super) fn open_published_index_read_only(path: &Path, timeout: StdDuration) -> Result<Option<Connection>, String> {
    #[cfg(test)]
    {
        if !existing_regular_index(path)? { return Ok(None); }
        sqlite::open_read_only(path, timeout).map(Some).map_err(|error| error.to_string())
    }
    #[cfg(not(test))]
    {
        let connection = crate::core::business_store_route::open_exact_registered_read_only(path, timeout)?;
        let Some(connection) = connection else { return Ok(None); };
        let has_objects = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM main.sqlite_master WHERE type IN ('table','index','view','trigger'))",
            [], |row| row.get::<_, bool>(0),
        ).map_err(|error| format!("无法只读检查精确 token 分区对象：{error}"))?;
        Ok(has_objects.then_some(connection))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct IndexStorageSignature {
    database: FileSignature,
    wal: Option<FileSignature>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct IndexIntegrityReceipt {
    version: u32,
    canonical_index_path: String,
    database: ReceiptFileSignature,
    wal: Option<ReceiptFileSignature>,
    schema_version: i64,
    parser_revision: String,
    revision: i64,
    published_generation: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptFileSignature {
    size: u64,
    modified_ns: String,
}

#[derive(Clone, Debug)]
struct ReceiptMetadata {
    canonical_index_path: String,
    schema_version: i64,
    parser_revision: String,
    revision: i64,
    published_generation: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct IndexIntegrityState {
    active_connections: usize,
}

pub(super) struct IntegrityGate {
    in_flight: Mutex<bool>,
    released: Condvar,
}

pub(super) struct IntegrityGateGuard {
    gate: Arc<IntegrityGate>,
    path: PathBuf,
    notify_release: bool,
}

static INDEX_INTEGRITY_GATES: OnceLock<Mutex<HashMap<PathBuf, Weak<IntegrityGate>>>> =
    OnceLock::new();

#[cfg(test)]
pub(in super::super) type IntegrityGateEnterHook = Box<dyn Fn(&Path) + Send + Sync>;
#[cfg(test)]
pub(in super::super) type IntegrityGateReleaseHook = Box<dyn Fn(&Path) + Send + Sync>;
#[cfg(test)]
pub(in super::super) type BeforeFinishIndexConnectionHook = Box<dyn Fn(&Path) + Send + Sync>;
#[cfg(test)]
static INTEGRITY_GATE_ENTER_HOOK: OnceLock<Mutex<Option<IntegrityGateEnterHook>>> = OnceLock::new();
#[cfg(test)]
static INTEGRITY_GATE_RELEASE_HOOK: OnceLock<Mutex<Option<IntegrityGateReleaseHook>>> =
    OnceLock::new();
#[cfg(test)]
static BEFORE_FINISH_INDEX_CONNECTION_HOOK: OnceLock<
    Mutex<Option<BeforeFinishIndexConnectionHook>>,
> = OnceLock::new();

#[cfg(test)]
static QUICK_CHECK_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static FAIL_NEXT_QUICK_CHECK_QUERY: AtomicBool = AtomicBool::new(false);
#[cfg(test)]
static RECEIPT_WRITE_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static QUICK_CHECK_BARRIER: OnceLock<Mutex<Option<(Arc<Barrier>, HashSet<PathBuf>)>>> =
    OnceLock::new();
static INDEX_INTEGRITY_STATES: OnceLock<Mutex<HashMap<PathBuf, IndexIntegrityState>>> =
    OnceLock::new();

/// Historical name: this is a storage-availability operation, not a stat probe.
/// Production may acquire the pool registry/handle locks, initialize or upgrade
/// pool schema, inspect retained seals/legacy ownership, and open a registered
/// Exact store through its import route to distinguish empty registration.
/// It must not be used as a side-effect-free published-reader existence check.
pub(super) fn existing_regular_index(path: &Path) -> Result<bool, String> {
    #[cfg(not(test))]
    if stage_pool::is_path(path) {
        let pool=stage_pool::Pool::current()?;
        return match pool.lookup(path)? {Some(job)=>Ok(pool.seal(&job)?.is_some()),None=>Ok(false)};
    }
    #[cfg(not(test))]
    {
        let physical_exists=existing_regular_legacy_file(path)?;
        if !physical_exists && stage_pool::is_legacy_path(path) {
            if let Some(present)=stage_pool::Pool::current()?.legacy_presence(path)? {return Ok(present)}
        }
        if physical_exists {
            if crate::core::business_store_route::exact_store_exists(path)? {
                return Ok(true);
            }
            if crate::core::business_store_route::exact_legacy_input_is_retired_unchanged(path)? {
                return Ok(false);
            }
            return Ok(true);
        }
        if !crate::core::business_store_route::exact_store_exists(path)? {
            return Ok(false);
        }
        // A job namespace can be registered before its first A-table write.
        // If the process stopped while its TEMP producer was parsing, retry
        // that known empty namespace instead of treating registration alone
        // as a corrupt, permanently blocking stage.
        let connection = open_exact_business_store(path)?;
        return connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM main.sqlite_master WHERE type IN ('table','index','view','trigger'))",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("无法检查精确 token 暂存分区对象：{error}"));
    }
    #[cfg(test)]
    {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝打开符号链接形式的精确 token 索引：{}",
            path.display()
        )),
        Ok(metadata) if !metadata.is_file() => Err(format!(
            "精确 token 索引路径不是普通文件：{}",
            path.display()
        )),
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!(
            "无法检查精确 token 索引路径 {}：{}",
            path.display(),
            error
        )),
    }
    }
}

/// Acquires the per-path gate, rechecks storage availability, opens/configures
/// the bound handle and registers its active lifetime. Candidate receipt checks
/// can observe or seal a namespace through the migration coordinator. Recovery
/// here preserves corrupt/transiently unavailable storage; it never recreates it.
pub(super) fn open_index_connection_with_recovery(
    path: &Path,
    existed_before_hint: bool,
    initialize_metadata: bool,
    verified_candidate: Option<&Schema11ValidatedStorage>,
) -> Result<(ManagedIndexConnection, bool), String> {
    let gate = index_integrity_gate(path);
    let _gate_guard = gate.enter(path);
    // The caller's existence probe can become stale while another open is
    // waiting on this path gate. Recheck under the per-path gate, never under
    // INDEX_INTEGRITY_STATES, so a newly created database is treated as such.
    let existed_before = existing_regular_index(path)?;
    let _ = existed_before_hint;
    if !existed_before {
        let connection = open_index_connection(path, true, true)?;
        return managed_index_connection(path, connection).map(|connection| (connection, false));
    }

    let state_has_active_connection = {
        let states = index_integrity_states();
        let states = states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        states
            .get(path)
            .is_some_and(|state| state.active_connections > 0)
    };
    let signature_before_open = index_storage_signature(path).ok();
    let receipt = signature_before_open.and_then(|signature| {
        read_integrity_receipt(path)
            .filter(|receipt| receipt_storage_matches(receipt, path, signature))
    });

    let candidate_proof_matches = verified_candidate.is_some_and(|verified| {
        schema11_receipt_matches_current(path, &verified.receipt).unwrap_or(false)
    });
    match open_index_connection(path, false, initialize_metadata) {
        Ok(connection) if state_has_active_connection => {
            return managed_index_connection(path, connection)
                .map(|connection| (connection, false));
        }
        Ok(connection) => {
            let receipt_is_verified = receipt
                .as_ref()
                .is_some_and(|receipt| receipt_connection_metadata_matches(receipt, &connection));
            // Connection-local pragmas (and our own journal-mode transition)
            // cannot change logical facts. Reuse only the proof checked before
            // that transition, with the same metadata after opening.
            let candidate_metadata_matches = candidate_proof_matches
                && verified_candidate.is_some_and(|verified| {
                    schema11_receipt_metadata_matches(&connection, &verified.receipt).unwrap_or(false)
                });
            if receipt_is_verified || candidate_metadata_matches {
                if candidate_metadata_matches {
                    startup_trace::mark_performance("exact_prepare reuse=candidate_integrity_on_open");
                }
                return managed_index_connection(path, connection)
                    .map(|connection| (connection, false));
            }
            match quick_check_index_result(&connection, Some(path)) {
                Ok(None) => {
                    return managed_index_connection(path, connection)
                        .map(|connection| (connection, false));
                }
                Ok(Some(report)) => {
                    drop(connection);
                    return Err(format!(
                        "精确 token 索引完整性检查报告损坏，已保留原索引并拒绝自动重建：{report}"
                    ));
                }
                Err(error) => {
                    drop(connection);
                    return Err(format!(
                        "精确 token 索引完整性检查暂时失败，已保留原索引并拒绝自动重建：{error}"
                    ));
                }
            }
        }
        Err(error) => Err(format!(
            "精确 token 索引打开失败，已保留原索引并拒绝自动重建：{error}"
        )),
    }
}

#[cfg(not(test))]
fn quick_check_bound_staging_store(connection: &BoundStoreConnection) -> Result<(), String> {
    const STAGING_TABLES: [&str; 4] = ["chunks", "events", "fingerprints", "manifest"];

    let existing_tables = {
        let mut statement = connection
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='table' AND lower(substr(name,1,7)) <> 'sqlite_' ORDER BY name",
            )
            .map_err(|error| format!("无法读取精确 token 暂存表清单：{error}"))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| format!("无法读取精确 token 暂存表清单：{error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("无法解码精确 token 暂存表清单：{error}"))?;
        rows
    };
    let expected_tables = STAGING_TABLES
        .iter()
        .map(|table| (*table).to_owned())
        .collect::<Vec<_>>();
    if existing_tables != expected_tables {
        return Err(format!(
            "精确 token 暂存表清单不匹配：预期 {:?}，实际 {:?}",
            expected_tables, existing_tables
        ));
    }

    for table in STAGING_TABLES {
        let sql = format!("PRAGMA quick_check('{table}')");
        let mut statement = connection
            .prepare(&sql)
            .map_err(|error| format!("无法准备精确 token 暂存表 {table} quick_check：{error}"))?;
        let reports = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| format!("无法读取精确 token 暂存表 {table} quick_check：{error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("无法解码精确 token 暂存表 {table} quick_check：{error}"))?;
        if reports.len() != 1 || reports[0] != "ok" {
            return Err(format!(
                "SQLite quick_check({table}) 报告损坏：{}",
                reports.join("; ")
            ));
        }
    }
    Ok(())
}

#[cfg(not(test))]
pub(super) fn quick_check_staged(connection: &Connection) -> Result<(), String> {
    if connection.is_bound() {
        quick_check_bound_staging_store(connection)
    } else {
        quick_check_index(connection, None)
    }
}

#[cfg(test)]
pub(super) fn quick_check_staged(connection: &Connection) -> Result<(), String> {
    // Test builds intentionally use raw rusqlite connections for legacy stage
    // fixtures. Preserve their whole-file check path and its failure hooks.
    quick_check_index(connection, None)
}

pub(super) fn quick_check_index(connection: &Connection, path: Option<&Path>) -> Result<(), String> {
    match quick_check_index_result(connection, path)? {
        None => Ok(()),
        Some(report) => Err(format!("SQLite quick_check 报告损坏：{report}")),
    }
}

/// Returns `Ok(None)` for a clean database, `Ok(Some(report))` only when
/// SQLite completed the check and explicitly reported structural corruption,
/// and `Err` for a transient/query failure. Callers must never turn the latter
/// into destructive recovery: an interrupted WAL/checkpoint, lock, or disk I/O
/// failure is not proof that the published index is corrupt.
fn quick_check_index_result(
    connection: &Connection,
    path: Option<&Path>,
) -> Result<Option<String>, String> {
    #[cfg(test)]
    QUICK_CHECK_COUNT.fetch_add(1, Ordering::SeqCst);
    #[cfg(not(test))]
    let _ = path;
    #[cfg(test)]
    if let Some(path) = path {
        let barrier = QUICK_CHECK_BARRIER
            .get_or_init(|| Mutex::new(None))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_ref()
            .filter(|(_, paths)| paths.contains(path))
            .map(|(barrier, _)| Arc::clone(barrier));
        if let Some(barrier) = barrier {
            barrier.wait();
        }
    }
    #[cfg(test)]
    if FAIL_NEXT_QUICK_CHECK_QUERY.swap(false, Ordering::SeqCst) {
        return Err("injected transient quick_check query failure".into());
    }
    let preparation = IndexPreparationTrace::new("quick_check");
    let result = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法完成 SQLite quick_check：{error}"))?;
    if result.eq_ignore_ascii_case("ok") {
        preparation.finish();
        Ok(None)
    } else {
        Ok(Some(result))
    }
}

fn index_integrity_states() -> &'static Mutex<HashMap<PathBuf, IndexIntegrityState>> {
    INDEX_INTEGRITY_STATES.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(super) fn index_integrity_gate(path: &Path) -> Arc<IntegrityGate> {
    let gates = INDEX_INTEGRITY_GATES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut gates = gates
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    gates.retain(|_, gate| gate.strong_count() > 0);
    if let Some(gate) = gates.get(path).and_then(Weak::upgrade) {
        return gate;
    }
    let gate = Arc::new(IntegrityGate {
        in_flight: Mutex::new(false),
        released: Condvar::new(),
    });
    gates.insert(path.to_path_buf(), Arc::downgrade(&gate));
    gate
}

impl IntegrityGate {
    fn enter(self: &Arc<Self>, path: &Path) -> IntegrityGateGuard {
        self.enter_with_release_hook(path, true)
    }

    // A sync guard is released before the managed connection closes. It must
    // not look like the close-time guard to diagnostics or tests; only the
    // close-time guard publishes that probe.
    pub(super) fn enter_silent(self: &Arc<Self>, path: &Path) -> IntegrityGateGuard {
        self.enter_with_release_hook(path, false)
    }

    fn enter_with_release_hook(
        self: &Arc<Self>,
        path: &Path,
        notify_release: bool,
    ) -> IntegrityGateGuard {
        let mut in_flight = self
            .in_flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        while *in_flight {
            in_flight = self
                .released
                .wait(in_flight)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        *in_flight = true;
        drop(in_flight);
        run_integrity_gate_enter_hook_for_testing(path);
        IntegrityGateGuard {
            gate: Arc::clone(self),
            path: path.to_path_buf(),
            notify_release,
        }
    }
}

impl Drop for IntegrityGateGuard {
    fn drop(&mut self) {
        // The release probe runs before the gate becomes available to a
        // waiter. This keeps the test-only observation deterministic: the
        // close path must have already published its state decrement before
        // any new open can acquire this path gate.
        if self.notify_release {
            run_integrity_gate_release_hook_for_testing(&self.path);
        }
        let mut in_flight = self
            .gate
            .in_flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *in_flight = false;
        self.gate.released.notify_one();
    }
}

fn index_storage_signature(path: &Path) -> Result<IndexStorageSignature, String> {
    Ok(IndexStorageSignature {
        database: file_signature(path)?,
        wal: optional_index_sidecar_signature(&sqlite_sidecar_path(path, "-wal"))?,
    })
}

fn integrity_receipt_path(path: &Path) -> PathBuf {
    let mut receipt = path.as_os_str().to_os_string();
    receipt.push(INDEX_INTEGRITY_RECEIPT_SUFFIX);
    PathBuf::from(receipt)
}

#[cfg(test)]
pub(in super::super) fn integrity_receipt_path_for_testing(codex_home: &Path) -> Result<PathBuf, String> {
    Ok(integrity_receipt_path(&database_path(codex_home)?))
}

fn receipt_file_signature(signature: FileSignature) -> ReceiptFileSignature {
    ReceiptFileSignature {
        size: signature.size,
        modified_ns: signature.modified_ns.to_string(),
    }
}

fn receipt_file_signature_matches(stored: &ReceiptFileSignature, current: FileSignature) -> bool {
    stored.size == current.size
        && stored.modified_ns.parse::<u128>().ok() == Some(current.modified_ns)
}

fn receipt_storage_matches(
    receipt: &IndexIntegrityReceipt,
    path: &Path,
    signature: IndexStorageSignature,
) -> bool {
    receipt.version == INDEX_INTEGRITY_RECEIPT_VERSION
        && canonical_index_path(path)
            .ok()
            .is_some_and(|canonical| receipt.canonical_index_path == canonical.to_string_lossy())
        && receipt_file_signature_matches(&receipt.database, signature.database)
        && match (&receipt.wal, signature.wal) {
            (None, None) => true,
            (Some(stored), Some(current)) => receipt_file_signature_matches(stored, current),
            // SQLite may leave a zero-byte WAL sidecar behind, or recreate an
            // empty sidecar with a new inode on the next read-only open.  An
            // empty WAL has no database state to validate; treating it as
            // absent keeps the integrity receipt reusable without running
            // quick_check on every startup.
            (Some(stored), None) => stored.size == 0,
            (None, Some(current)) => current.size == 0,
        }
}

fn receipt_connection_metadata_matches(
    receipt: &IndexIntegrityReceipt,
    connection: &Connection,
) -> bool {
    // The receipt was already matched against the pre-open signature. A
    // connection open can create a WAL sidecar, so storage is deliberately
    // checked before the open and metadata after it.
    metadata_i64(connection, "schema_version")
        .ok()
        .flatten()
        .is_some_and(|schema_version| schema_version == receipt.schema_version)
        && metadata_i64(connection, "revision")
            .ok()
            .flatten()
            .is_some_and(|revision| revision == receipt.revision)
        && metadata_text(connection, "published_generation")
            .ok()
            .flatten()
            .and_then(|generation| generation.parse::<i64>().ok())
            .is_some_and(|generation| generation == receipt.published_generation)
        && [EXACT_SESSION_PARSER_REVISION, PRE_COMPACTION_SESSION_PARSER_REVISION,
            LEGACY_SESSION_PARSER_REVISION, LEGACY_STAGED_PARSER_REVISION,
            PAGINATED_V4_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION,
            PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION]
            .contains(&receipt.parser_revision.as_str())
}

fn receipt_metadata(connection: &Connection, path: &Path) -> Result<ReceiptMetadata, String> {
    let schema_version = metadata_i64(connection, "schema_version")?
        .ok_or_else(|| "精确 token 完整性收据缺少 schema 版本".to_string())?;
    let revision = metadata_i64(connection, "revision")?
        .ok_or_else(|| "精确 token 完整性收据缺少索引 revision".to_string())?;
    let published_generation = metadata_i64(connection, "published_generation")?
        .ok_or_else(|| "精确 token 完整性收据缺少已发布代次".to_string())?;
    let canonical_index_path = canonical_index_path(path)?.to_string_lossy().into_owned();
    Ok(ReceiptMetadata {
        canonical_index_path,
        schema_version,
        parser_revision: EXACT_SESSION_PARSER_REVISION.into(),
        revision,
        published_generation,
    })
}

fn read_integrity_receipt(path: &Path) -> Option<IndexIntegrityReceipt> {
    let receipt_path = integrity_receipt_path(path);
    let metadata = fs::symlink_metadata(&receipt_path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let bytes = fs::read(receipt_path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn receipt_destination_is_safe(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝覆盖符号链接形式的精确 token 完整性收据：{}",
            path.display()
        )),
        Ok(metadata) if !metadata.is_file() => Err(format!(
            "精确 token 完整性收据路径不是普通文件：{}",
            path.display()
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "无法检查精确 token 完整性收据路径 {}：{}",
            path.display(),
            error
        )),
    }
}

fn write_integrity_receipt_best_effort(
    path: &Path,
    metadata: ReceiptMetadata,
    signature: IndexStorageSignature,
) {
    let receipt_path = integrity_receipt_path(path);
    if receipt_destination_is_safe(&receipt_path).is_err() {
        return;
    }
    let receipt = IndexIntegrityReceipt {
        version: INDEX_INTEGRITY_RECEIPT_VERSION,
        canonical_index_path: metadata.canonical_index_path,
        database: receipt_file_signature(signature.database),
        wal: signature.wal.map(receipt_file_signature),
        schema_version: metadata.schema_version,
        parser_revision: metadata.parser_revision,
        revision: metadata.revision,
        published_generation: metadata.published_generation,
    };
    let Ok(bytes) = serde_json::to_vec(&receipt) else {
        return;
    };
    if fs::read(&receipt_path).is_ok_and(|existing| existing == bytes) {
        return;
    }
    #[cfg(test)]
    RECEIPT_WRITE_COUNT.fetch_add(1, Ordering::SeqCst);
    let _ = atomic_file::write_atomically(&receipt_path, &bytes);
}

fn canonical_index_path(path: &Path) -> Result<PathBuf, String> {
    fs::canonicalize(path).map_err(|error| {
        format!(
            "无法确认精确 token 索引规范路径 {}：{}",
            path.display(),
            error
        )
    })
}

pub(super) fn optional_index_sidecar_signature(path: &Path) -> Result<Option<FileSignature>, String> {
    #[cfg(not(test))]
    {
        let _ = path;
        return Ok(None);
    }
    #[cfg(test)]
    {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝读取符号链接形式的精确 token 索引侧写文件：{}",
            path.display()
        )),
        Ok(metadata) if !metadata.is_file() => Err(format!(
            "精确 token 索引侧写路径不是普通文件：{}",
            path.display()
        )),
        Ok(_) => {
            let signature = file_signature(path)?;
            Ok((signature.size > 0).then_some(signature))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!(
            "无法检查精确 token 索引侧写路径 {}：{}",
            path.display(),
            error
        )),
    }
    }
}

fn managed_index_connection(
    path: &Path,
    connection: Connection,
) -> Result<ManagedIndexConnection, String> {
    let states = index_integrity_states();
    let mut states = states
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Ok(register_index_connection(&mut states, path, connection))
}

fn register_index_connection(
    states: &mut HashMap<PathBuf, IndexIntegrityState>,
    path: &Path,
    connection: Connection,
) -> ManagedIndexConnection {
    let active_connections = states
        .get(path)
        .map(|state| state.active_connections)
        .unwrap_or(0)
        .saturating_add(1);
    states.insert(
        path.to_path_buf(),
        IndexIntegrityState { active_connections },
    );
    ManagedIndexConnection::from_registered(connection, path.to_path_buf())
}

fn finish_index_connection(states: &mut HashMap<PathBuf, IndexIntegrityState>, path: &Path) {
    let remaining_connections = states
        .get(path)
        .map(|state| state.active_connections.saturating_sub(1))
        .unwrap_or(0);
    if remaining_connections > 0 {
        states.insert(
            path.to_path_buf(),
            IndexIntegrityState {
                active_connections: remaining_connections,
            },
        );
    } else {
        states.remove(path);
    }
}

pub(super) fn invalidate_index_integrity_signature(path: &Path) {
    let states = index_integrity_states();
    let mut states = states
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    states.remove(path);
}

/// Configures the existing connection and may create metadata/WAL state when
/// requested. Production admission can register/import an Exact namespace;
/// create_if_missing only controls raw SQLite open flags in test builds.
pub(super) fn open_index_connection(
    path: &Path,
    create_if_missing: bool,
    initialize_metadata: bool,
) -> Result<Connection, String> {
    #[cfg(not(test))]
    let connection = open_exact_business_store(path)?;
    #[cfg(test)]
    let mut flags = OpenFlags::default();
    #[cfg(test)]
    if !create_if_missing {
        flags.remove(OpenFlags::SQLITE_OPEN_CREATE);
    }
    #[cfg(test)]
    let connection = Connection::open_with_flags(path, flags)
        .map_err(|error| format!("无法打开精确 token 索引 {}：{}", path.display(), error))?;
    connection
        .busy_timeout(StdDuration::from_secs(30))
        .map_err(|error| format!("无法设置精确 token 索引等待时间：{error}"))?;
    let pragmas = if create_if_missing || initialize_metadata {
        "PRAGMA journal_mode = WAL;\nPRAGMA synchronous = NORMAL;\nPRAGMA temp_store = FILE;\nPRAGMA cache_size = -16384;\nPRAGMA foreign_keys = ON;"
    } else {
        // A compatible reopen must not ask SQLite to change persistent
        // journal state. The database was configured for WAL when it was
        // created; these remaining pragmas are connection-local.
        "PRAGMA synchronous = NORMAL;\nPRAGMA temp_store = FILE;\nPRAGMA cache_size = -16384;\nPRAGMA foreign_keys = ON;"
    };
    connection
        .execute_batch(pragmas)
        .map_err(|error| format!("无法初始化精确 token 索引连接：{error}"))?;
    if create_if_missing || initialize_metadata {
        #[cfg(test)]
        OPEN_DDL_COUNT.fetch_add(1, Ordering::SeqCst);
        connection
            .execute_batch(
                r#"
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                "#,
            )
            .map_err(|error| format!("无法初始化精确 token 索引元数据表：{error}"))?;
    }
    let foreign_keys_enabled = connection
        .query_row("PRAGMA foreign_keys", [], |row| row.get::<_, i64>(0))
        .map_err(|error| format!("无法确认精确 token 索引外键约束：{error}"))?;
    if foreign_keys_enabled != 1 {
        return Err("精确 token 索引外键约束未启用".into());
    }
    Ok(connection)
}

#[cfg(not(test))]
/// Admitted writer/import route: may preserve backups, resume journals and
/// register/import legacy inputs. This is never the published-read-only route.
pub(super) fn open_exact_business_store(path: &Path) -> Result<Connection, String> {
    let legacy_sources = if existing_regular_legacy_file(path)? {
        vec![path.to_path_buf()]
    } else {
        Vec::new()
    };
    crate::core::business_store_route::open_exact_store(path, &legacy_sources)
}

/// An externally owned live database must never enter the one-time legacy
/// import route. Keep the same unbound, read-only source in every build mode.
pub(super) fn open_read_only_source(path: &Path, timeout: StdDuration) -> Result<Connection, String> {
    let raw = sqlite::open_read_only(path, timeout).map_err(|error| error.to_string())?;
    raw.pragma_update(None, "query_only", true).map_err(|error| error.to_string())?;
    #[cfg(test)]
    { Ok(raw) }
    #[cfg(not(test))]
    { Ok(Connection::unbound(raw)) }
}

/// Historical name: production is NOT a read-only open contract.
/// Pool paths may prepare the retained pool and restore a private SQLite image;
/// ordinary paths enter open_exact_business_store, which can register/import
/// legacy data and returns the original bound connection. Call only from the
/// existing migration/staging orchestration. Published readers must instead use
/// open_published_index_read_only; external live sources use open_read_only_source.
pub(super) fn open_read_only_index(path: &Path, timeout: StdDuration) -> Result<Connection, String> {
    #[cfg(not(test))]
    if stage_pool::is_path(path) {
        let pool=stage_pool::Pool::current()?;
        let job=pool.lookup(path)?.ok_or("读取的暂存job缺失")?;
        return pool.restore(&job).map(Connection::unbound);
    }
    #[cfg(test)]
    {
        return sqlite::open_read_only(path, timeout).map_err(|error| error.to_string());
    }
    #[cfg(not(test))]
    {
        let connection = open_exact_business_store(path)?;
        connection
            .busy_timeout(timeout)
            .map_err(|error| format!("无法设置精确 token 索引读取等待时间：{error}"))?;
        Ok(connection)
    }
}

pub(super) fn existing_regular_legacy_file(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝导入符号链接形式的精确 token 索引：{}",
            path.display()
        )),
        Ok(metadata) if !metadata.is_file() => Err(format!(
            "精确 token 索引路径不是普通文件：{}",
            path.display()
        )),
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("无法检查旧精确 token 索引 {}：{error}", path.display())),
    }
}

pub(super) fn reject_orphaned_index_rows(connection: &Connection) -> Result<(), String> {
    if orphaned_index_rows_exist(connection)? {
        return Err(
            "精确 token 索引发现孤儿行；已保留活动库、上一代统计和全部异常行，repair required"
                .into(),
        );
    }
    Ok(())
}

/// Verification with a durable completion marker, NOT a read-only predicate.
/// A missing marker starts the existing deferred transaction, rejects orphans
/// without deleting them, writes the marker only when clean, then commits.
/// Read-only admission must use reject_orphaned_index_rows instead.
pub(super) fn verify_no_orphaned_index_rows(connection: &mut Connection) -> Result<(), String> {
    if metadata_text(connection, ORPHAN_REPAIR_REVISION_KEY)?.as_deref()
        == Some(ORPHAN_REPAIR_REVISION)
    {
        return Ok(());
    }

    // Start read-first. A legacy database can be checked without reserving a
    // writer slot. Orphaned rows are preserved as repair evidence: v0.9.2 no
    // longer treats an inconsistent derived index as authority to delete any
    // published or staged data. Only the clean verification marker is written.
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Deferred)
        .map_err(|error| format!("无法开始精确 token 孤儿行读取事务：{error}"))?;
    reject_orphaned_index_rows(&transaction)?;
    set_metadata(
        &transaction,
        ORPHAN_REPAIR_REVISION_KEY,
        ORPHAN_REPAIR_REVISION,
    )?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交精确 token 孤儿行修复标记：{error}"))
}

fn orphaned_index_rows_exist(connection: &Connection) -> Result<bool, String> {
    // Schema 11 compatibility views intentionally hide child rows whose
    // stable source is missing, so view-level anti-joins alone cannot detect
    // physical orphans left by an older foreign_keys=OFF writer. Check the
    // complete declared graph first; this is read-only and preserves every
    // offending row for an explicit candidate repair.
    let foreign_key_failure = connection
        .query_row("PRAGMA foreign_key_check", [], |_| Ok(true))
        .optional()
        .map_err(|error| format!("无法检查精确 token 物理外键孤儿：{error}"))?
        .unwrap_or(false);
    if foreign_key_failure {
        return Ok(true);
    }
    for (label, query) in [
        (
            "事件",
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM events
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = events.file_generation
                      AND files.path = events.file_path
                )
            )
            "#,
        ),
        (
            "去重状态",
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM file_fingerprints
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = file_fingerprints.file_generation
                      AND files.path = file_fingerprints.file_path
                )
            )
            "#,
        ),
        (
            "分块状态",
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM file_chunks
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = file_chunks.file_generation
                      AND files.path = file_chunks.file_path
                )
            )
            "#,
        ),
    ] {
        let exists = connection
            .query_row(query, [], |row| row.get::<_, i64>(0))
            .map_err(|error| format!("无法检查精确 token 孤儿{label}：{error}"))?
            != 0;
        if exists {
            return Ok(true);
        }
    }
    Ok(false)
}

impl super::ExactUsageIndex {
    pub(in super::super) fn open_published(codex_home: &Path) -> Result<Self, String> {
        let path = database_path(codex_home)?;
        let connection = open_published_index_read_only(&path, StdDuration::from_secs(3))?
            .ok_or("该来源没有已核实的已发布精确索引")?;
        let assessment = assess_index_migration(&connection, true)?;
        if !matches!(assessment, MigrationAssessment::Compatible) {
            return Err(assessment.blocking_error().unwrap_or_else(|| "旧索引等待兼容补全，已保留原账".into()));
        }
        Ok(Self { connection: ManagedIndexConnection { connection: Some(connection), path,
            receipt_eligible: false, tracks_integrity: false }, _operation_lock: None,
            migration_pending: false, published_read_only: true })
    }

}

#[cfg(test)]
impl ExactUsageIndex {
    #[cfg(test)]
    pub(in super::super) fn set_integrity_gate_enter_hook_for_testing(hook: Option<IntegrityGateEnterHook>) {
        let slot = INTEGRITY_GATE_ENTER_HOOK.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
    }

    #[cfg(test)]
    pub(in super::super) fn set_integrity_gate_release_hook_for_testing(
        hook: Option<IntegrityGateReleaseHook>,
    ) {
        let slot = INTEGRITY_GATE_RELEASE_HOOK.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
    }

    #[cfg(test)]
    pub(in super::super) fn set_before_finish_index_connection_hook_for_testing(
        hook: Option<BeforeFinishIndexConnectionHook>,
    ) {
        let slot = BEFORE_FINISH_INDEX_CONNECTION_HOOK.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
    }

    #[cfg(test)]
    pub(in super::super) fn clear_integrity_signature_for_testing(codex_home: &Path) {
        if let Ok(path) = database_path(codex_home) {
            invalidate_index_integrity_signature(&path);
        }
    }

    #[cfg(test)]
    pub(in super::super) fn active_integrity_connections_for_testing(path: &Path) -> usize {
        index_integrity_states()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(path)
            .map(|state| state.active_connections)
            .unwrap_or(0)
    }

    #[cfg(test)]
    pub(in super::super) fn reset_quick_check_count_for_testing() {
        QUICK_CHECK_COUNT.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(in super::super) fn quick_check_count_for_testing() -> u64 {
        QUICK_CHECK_COUNT.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(in super::super) fn fail_next_quick_check_query_for_testing() {
        FAIL_NEXT_QUICK_CHECK_QUERY.store(true, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(in super::super) fn reset_receipt_write_count_for_testing() {
        RECEIPT_WRITE_COUNT.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(in super::super) fn receipt_write_count_for_testing() -> u64 {
        RECEIPT_WRITE_COUNT.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(in super::super) fn set_quick_check_barrier_for_testing(
        barrier: Option<(Arc<Barrier>, HashSet<PathBuf>)>,
    ) {
        let slot = QUICK_CHECK_BARRIER.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = barrier;
    }

}
