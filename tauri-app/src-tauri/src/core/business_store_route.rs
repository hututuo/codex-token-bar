//! Bootstrap and legacy import routing for business container A.
//!
//! All paths used by the app are resolved from its support directory. Old
//! stores are copied through SQLite's online backup API into immutable
//! snapshots, then imported into one private namespace. Source files remain
//! untouched.

use crate::core::app_paths;
use crate::core::business_store_connection::StoreConnection;
use crate::core::business_store_container::{Container, StoreProof, StoreSpec};
use fs2::available_space;
use rusqlite::{Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ContainerFileIdentity {
    volume: u64,
    file_id: u128,
}

#[cfg(not(test))]
static ACTIVE_CONTAINER_IDENTITY: OnceLock<Mutex<Option<ContainerFileIdentity>>> = OnceLock::new();

pub(crate) struct ContainerMaintenancePolicy {
    pub(crate) minimum_check_interval_seconds: i64,
    pub(crate) minimum_free_bytes: u64,
    pub(crate) absolute_free_bytes: u64,
    pub(crate) minimum_free_percent: u64,
    pub(crate) disk_reserve_bytes: u64,
}

pub(crate) enum ContainerMaintenanceOutcome {
    NotDue,
    Busy,
    BelowThreshold {
        database_bytes: u64,
        free_bytes: u64,
    },
    InsufficientSpace {
        database_bytes: u64,
        free_bytes: u64,
        available_bytes: u64,
        required_bytes: u64,
    },
    Compacted {
        before_bytes: u64,
        after_bytes: u64,
        reclaimed_bytes: u64,
    },
}

pub(crate) fn container_path() -> Result<PathBuf, String> {
    let quota_path = app_paths::quota_history_database_path()
        .ok_or_else(|| "无法定位应用支持目录，不能初始化业务数据库".to_string())?;
    Ok(quota_path.with_file_name("codex-ledger.sqlite"))
}

pub(crate) fn bootstrap() -> Result<(), String> {
    let path = container_path()?;
    let marker = initialized_marker_path(&path);
    match std::fs::symlink_metadata(&marker) {
        Ok(_) => {
            verify_initialized(&path)?;
            run_container_maintenance_if_due();
            return Ok(());
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("无法检查业务数据库初始化标记：{error}")),
    }
    Container::open(&path).map_err(|error| error.to_string())?;
    bootstrap_legacy_stores()?;
    crate::core::usage::token_count_jsonl::bootstrap_legacy_exact_indexes()?;
    resume_pending_bootstrap_imports(&path)?;
    verify_bootstrap_pending_inputs(
        &Container::open_existing(&path).map_err(|error| error.to_string())?,
    )?;
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&path)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("无法同步业务数据库容器：{error}"))?;
    crate::core::atomic_file::sync_parent(path.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|error| format!("无法同步业务数据库目录：{error}"))?;
    crate::core::atomic_file::write_atomically(&marker, b"tokenbar-codex-ledger-v1\n")
        .map_err(|error| format!("无法写入业务数据库初始化标记：{error}"))?;
    verify_initialized(&path)?;
    run_container_maintenance_if_due();
    Ok(())
}

fn run_container_maintenance_if_due() {
    let result = maintain_container_storage_during_bootstrap(
        now_unix() as i64,
        ContainerMaintenancePolicy {
            minimum_check_interval_seconds: 24 * 60 * 60,
            minimum_free_bytes: 64 * 1024 * 1024,
            absolute_free_bytes: 256 * 1024 * 1024,
            minimum_free_percent: 20,
            disk_reserve_bytes: 512 * 1024 * 1024,
        },
        None,
    );
    if let Err(error) = result {
        crate::core::startup_trace::mark_performance(format!(
            "business_store maintenance_error={error}"
        ));
    }
}

pub(crate) fn source_identity(module: &str, source_home: &Path) -> Result<String, String> {
    let canonical = std::fs::canonicalize(source_home).unwrap_or_else(|_| {
        match (source_home.parent(), source_home.file_name()) {
            (Some(parent), Some(name)) => std::fs::canonicalize(parent)
                .unwrap_or_else(|_| parent.to_path_buf())
                .join(name),
            _ => source_home.to_path_buf(),
        }
    });
    let text = canonical
        .to_str()
        .ok_or_else(|| "数据源路径无法编码，拒绝初始化隔离业务分区".to_string())?;
    let mut digest = Sha256::new();
    digest.update(b"tokenbar-business-source-v1\0");
    digest.update(module.as_bytes());
    digest.update(b"\0");
    digest.update(text.as_bytes());
    Ok(hex_digest(&digest.finalize()))
}

pub(crate) fn open_store(
    module: &str,
    source_identity: &str,
    logical_path: &str,
    legacy_sources: &[PathBuf],
) -> Result<StoreConnection, String> {
    open_store_inner(module, source_identity, logical_path, legacy_sources, true)
}

/// Open an already-imported namespace without consulting its original file.
/// Legacy readers use this after an old physical source has been archived or
/// removed; absence must not hide rows already preserved in A.
pub(crate) fn open_registered_store(
    module: &str,
    source_identity: &str,
    logical_path: &str,
) -> Result<Option<StoreConnection>, String> {
    let path = container_path()?;
    open_registered_store_at(&path, module, source_identity, logical_path)
}

fn open_registered_store_at(
    path: &Path,
    module: &str,
    source_identity: &str,
    logical_path: &str,
) -> Result<Option<StoreConnection>, String> {
    let container = open_ready_container(path)?;
    let store =
        StoreSpec::new(module, source_identity, logical_path).map_err(|error| error.to_string())?;
    if !container
        .is_registered(&store)
        .map_err(|error| error.to_string())?
    {
        return Ok(None);
    }
    container
        .into_store_connection(&store)
        .map(Some)
        .map_err(|error| error.to_string())
}

/// Read an existing namespace without registration, import, or a write lock.
pub(crate) fn open_registered_store_read_only(
    module: &str,
    source_identity: &str,
    logical_path: &str,
    timeout: std::time::Duration,
) -> Result<Option<StoreConnection>, String> {
    ensure_runtime_business_store_ready()?;
    open_registered_store_read_only_at(
        &container_path()?, module, source_identity, logical_path, timeout,
    )
}

fn open_registered_store_read_only_at(
    path: &Path,
    module: &str,
    source_identity: &str,
    logical_path: &str,
    timeout: std::time::Duration,
) -> Result<Option<StoreConnection>, String> {
    verify_ready_container(path)?;
    let container = Container::open_read_only_existing(path, timeout)
        .map_err(|error| error.to_string())?;
    #[cfg(not(test))]
    verify_active_container_identity(path)?;
    let store = StoreSpec::new(module, source_identity, logical_path)
        .map_err(|error| error.to_string())?;
    if !container.is_registered(&store).map_err(|error| error.to_string())? {
        return Ok(None);
    }
    container.into_store_connection(&store).map(Some).map_err(|error| error.to_string())
}

/// Run the shared A container compaction policy. Module-local VACUUM SQL is
/// deliberately a no-op; this daily gate is the only path that checkpoints
/// and incrementally reclaims container pages.
pub(crate) fn maintain_container_storage_if_due(
    now_unix: i64,
    policy: ContainerMaintenancePolicy,
    available_bytes_override: Option<u64>,
) -> Result<ContainerMaintenanceOutcome, String> {
    ensure_runtime_business_store_ready()?;
    maintain_container_storage_during_bootstrap(now_unix, policy, available_bytes_override)
}

fn maintain_container_storage_during_bootstrap(
    now_unix: i64,
    policy: ContainerMaintenancePolicy,
    available_bytes_override: Option<u64>,
) -> Result<ContainerMaintenanceOutcome, String> {
    let path = container_path()?;
    // Startup maintenance is part of bootstrap readiness. It must use the
    // internal open path because normal business-store access stays gated
    // until this function and the rest of bootstrap have completed.
    let container = open_ready_container_during_bootstrap(&path)?;
    let connection = container.connection();
    let last_checked = connection
        .query_row(
            "SELECT value FROM tb_container_meta WHERE key='maintenance_checked_at'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| format!("无法读取 A 容器维护时间：{error}"))?
        .and_then(|value| value.parse::<i64>().ok());
    if last_checked
        .is_some_and(|last| now_unix.saturating_sub(last) < policy.minimum_check_interval_seconds)
    {
        return Ok(ContainerMaintenanceOutcome::NotDue);
    }

    let record_check = || -> Result<(), String> {
        connection
            .execute(
                "INSERT OR REPLACE INTO tb_container_meta(key,value) VALUES('maintenance_checked_at',?1)",
                [now_unix.to_string()],
            )
            .map(|_| ())
            .map_err(|error| format!("无法记录 A 容器维护时间：{error}"))
    };
    let metric = |name: &str| -> Result<u64, String> {
        let value = connection
            .query_row(&format!("PRAGMA {name}"), [], |row| row.get::<_, i64>(0))
            .map_err(|error| format!("无法读取 A 容器 {name}：{error}"))?;
        u64::try_from(value).map_err(|_| format!("A 容器 {name} 值无效"))
    };
    if metric("auto_vacuum")? != 2 {
        // Existing v1 containers keep their original auto_vacuum setting.
        // Never run a full VACUUM to enable pointer maps: it can renumber
        // hidden rowids in preserved legacy tables.
        record_check()?;
        return Ok(ContainerMaintenanceOutcome::NotDue);
    }

    let page_size = metric("page_size")?;
    let page_count = metric("page_count")?;
    let free_pages = metric("freelist_count")?;
    let database_bytes = page_size
        .checked_mul(page_count)
        .ok_or_else(|| "A 容器字节数溢出".to_string())?;
    let free_bytes = page_size
        .checked_mul(free_pages)
        .ok_or_else(|| "A 容器空闲空间字节数溢出".to_string())?;
    let free_percent = if page_count == 0 {
        0.0
    } else {
        (free_pages as f64 / page_count as f64) * 100.0
    };
    if free_bytes < policy.minimum_free_bytes
        || !(free_percent >= policy.minimum_free_percent as f64
            || free_bytes >= policy.absolute_free_bytes)
    {
        record_check()?;
        return Ok(ContainerMaintenanceOutcome::BelowThreshold {
            database_bytes,
            free_bytes,
        });
    }

    let required_bytes = database_bytes
        .checked_mul(2)
        .and_then(|value| value.checked_add(policy.disk_reserve_bytes))
        .ok_or_else(|| "A 容器维护容量需求溢出".to_string())?;
    let available_bytes = if let Some(value) = available_bytes_override {
        value
    } else {
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        available_space(parent)
            .map_err(|error| format!("无法检查 A 容器可用空间 {}：{error}", parent.display()))?
    };
    if available_bytes < required_bytes {
        record_check()?;
        return Ok(ContainerMaintenanceOutcome::InsufficientSpace {
            database_bytes,
            free_bytes,
            available_bytes,
            required_bytes,
        });
    }

    let checkpoint_busy: i64 = connection
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0))
        .map_err(|error| format!("无法 checkpoint A 容器 WAL：{error}"))?;
    if checkpoint_busy != 0 {
        return Ok(ContainerMaintenanceOutcome::Busy);
    }
    connection
        .execute_batch("PRAGMA incremental_vacuum")
        .map_err(|error| format!("无法增量回收 A 容器空闲页：{error}"))?;
    let checkpoint_busy: i64 = connection
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0))
        .map_err(|error| format!("无法完成 A 容器 WAL checkpoint：{error}"))?;
    if checkpoint_busy != 0 {
        return Ok(ContainerMaintenanceOutcome::Busy);
    }
    record_check()?;
    let after_bytes = metric("page_count")?
        .checked_mul(page_size)
        .ok_or_else(|| "A 容器压缩后字节数溢出".to_string())?;
    Ok(ContainerMaintenanceOutcome::Compacted {
        before_bytes: database_bytes,
        after_bytes,
        reclaimed_bytes: database_bytes.saturating_sub(after_bytes),
    })
}

pub(crate) fn open_store_during_bootstrap(
    module: &str,
    source_identity: &str,
    logical_path: &str,
    legacy_sources: &[PathBuf],
) -> Result<StoreConnection, String> {
    open_store_inner(module, source_identity, logical_path, legacy_sources, false)
}

fn open_store_inner(
    module: &str,
    source_identity: &str,
    logical_path: &str,
    legacy_sources: &[PathBuf],
    require_initialized: bool,
) -> Result<StoreConnection, String> {
    let container_path = container_path()?;
    open_store_at(
        &container_path,
        module,
        source_identity,
        logical_path,
        legacy_sources,
        require_initialized,
    )
}

fn open_store_at(
    container_path: &Path,
    module: &str,
    source_identity: &str,
    logical_path: &str,
    legacy_sources: &[PathBuf],
    require_initialized: bool,
) -> Result<StoreConnection, String> {
    open_store_at_with_hook(
        container_path,
        module,
        source_identity,
        logical_path,
        legacy_sources,
        require_initialized,
        &|| Ok(()),
    )
}

#[derive(serde::Serialize, serde::Deserialize)]
struct PendingLegacyImport {
    #[serde(default = "legacy_journal_version")]
    version: u32,
    sources: Vec<PathBuf>,
    #[serde(default)]
    snapshots: Vec<PendingSnapshot>,
    bootstrap: bool,
    #[serde(default)]
    replace_uncommitted: bool,
}

fn legacy_journal_version() -> u32 { 1 }

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct PendingSnapshot {
    source: PathBuf,
    backup: PathBuf,
    digest: String,
}

fn validate_pending_snapshot(container_path: &Path, store: &StoreSpec, snapshot: &PendingSnapshot) -> Result<(), String> {
    if snapshot.backup != backup_path(container_path, store, &snapshot.source, &snapshot.digest) {
        return Err(format!("未完成导入的绑定路径无效，保留全部旧账：{}", snapshot.backup.display()));
    }
    // Reject aliases/nonregular targets before the backup helper may move any
    // corrupt app-owned file aside. It must never touch an external export.
    let exists = legacy_source_exists(&snapshot.backup)?;
    if exists && Container::snapshot_digest_path(&snapshot.backup).ok().as_deref() == Some(&snapshot.digest) { return Ok(()); }
    // A missing/corrupt backup is recoverable only from the *same* frozen
    // source proof. A newer or truncated original is not its replacement.
    if legacy_source_exists(&snapshot.source)?
        && Container::snapshot_digest_path(&snapshot.source).ok().as_deref() == Some(&snapshot.digest) {
        Container::ensure_verified_backup(&snapshot.source, &snapshot.backup, &snapshot.digest).map_err(|e| e.to_string())?;
        return Ok(());
    }
    Err(format!("未完成导入的绑定快照无效，保留全部旧账：{}", snapshot.backup.display()))
}

fn validate_pending_batch(batch: &PendingLegacyImport, path: &Path, store: &StoreSpec) -> Result<(), String> {
    if ![1, 2].contains(&batch.version) { return Err("未知的未完成导入版本，已保留旧账".into()); }
    if batch.version == 2 && batch.sources.len() != batch.snapshots.len() {
        return Err("未完成导入快照数量不匹配".into());
    }
    let mut seen = std::collections::HashSet::new();
    for snapshot in &batch.snapshots {
        if !batch.sources.contains(&snapshot.source) || !seen.insert(&snapshot.source) {
            return Err("未完成导入快照来源不匹配".into());
        }
        validate_pending_snapshot(path, store, snapshot)?;
    }
    Ok(())
}

// Public 0.9.8/0.9.9 journals list only paths. A committed per-source receipt
// can bind its missing frozen proof without guessing a backup from filenames.
// This also prevents a v1 retry from replacing an imported row with a later
// truncation. An unreceipted missing v1 input still cannot be reconstructed.
fn bind_legacy_pending_receipts(batch: &mut PendingLegacyImport, container: &Container, store: &StoreSpec) -> Result<(), String> {
    if batch.version != 1 { return Ok(()); }
    if !batch.snapshots.is_empty() { return Err("旧版本批次包含未知快照字段，已保留旧账".into()); }
    for source in &batch.sources {
        if let Some(receipt) = container.legacy_input_receipt(source).map_err(|e| e.to_string())? {
            if receipt.retired || receipt.store_id != store.id || receipt.module != store.module || receipt.logical_path != store.logical_path {
                return Err("旧版本未完成批次与来源归属不一致".into());
            }
            batch.snapshots.push(PendingSnapshot { source: source.clone(), backup: PathBuf::from(receipt.backup_path), digest: receipt.source_digest });
        }
    }
    Ok(())
}

/// Discovery can no longer see deleted/moved originals. A versioned journal
/// binds their immutable SQLite backups, so restart visits every unfinished
/// store even if no physical source was rediscovered. No unjournaled file or
/// backup is guessed from a directory scan.
fn resume_pending_bootstrap_imports(path: &Path) -> Result<(), String> {
    let container = Container::open_existing(path).map_err(|e| e.to_string())?;
    let mut statement = container.connection().prepare(
        "SELECT s.module,s.source_identity,s.logical_path,m.value FROM tb_stores s JOIN tb_container_meta m ON m.key='migration_pending_store_v1:'||s.store_id"
    ).map_err(|e| e.to_string())?;
    let batches = statement.query_map([], |r| Ok((r.get::<_, String>(0)?,r.get::<_, String>(1)?,r.get::<_, String>(2)?,r.get::<_, String>(3)?)))
        .map_err(|e| e.to_string())?.collect::<Result<Vec<_>,_>>().map_err(|e| e.to_string())?;
    drop(statement);
    drop(container);
    for (module, identity, logical, json) in batches {
        let batch: PendingLegacyImport = serde_json::from_str(&json).map_err(|e| format!("未完成导入记录无效：{e}"))?;
        let container = Container::open_existing(path).map_err(|e| e.to_string())?;
        let store = StoreSpec::new(&module, &identity, &logical).map_err(|e| e.to_string())?;
        validate_pending_batch(&batch, path, &store)?;
        let mut complete = container.has_imported_objects(&store).map_err(|e| e.to_string())?;
        for source in &batch.sources {
            complete &= container.legacy_input_receipt(source).map_err(|e| e.to_string())?
                .is_some_and(|r| !r.retired && r.store_id == store.id && r.module == store.module && r.logical_path == store.logical_path
                    && batch.snapshots.iter().any(|s| &s.source == source && s.digest == r.source_digest));
        }
        drop(container);
        if complete { continue; }
        drop(open_store_at_with_hook(path, &module, &identity, &logical, &batch.sources, false, &|| Ok(()))?);
    }
    Ok(())
}

// Discovery can omit a source that disappeared after an earlier attempt.
// Check the complete journal, including stores not visited on this retry.
fn verify_bootstrap_pending_inputs(container: &Container) -> Result<(), String> {
    let mut statement = container
        .connection()
        .prepare(
            "SELECT key,value FROM tb_container_meta WHERE key LIKE 'migration_pending_store_v1:%'",
        )
        .map_err(|error| error.to_string())?;
    let batches = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|error| error.to_string())?;
    for batch in batches {
        let (key, json) = batch.map_err(|error| error.to_string())?;
        let pending: PendingLegacyImport =
            serde_json::from_str(&json).map_err(|error| error.to_string())?;
        if ![1, 2].contains(&pending.version) { return Err("未知的未完成导入版本，已保留旧账".into()); }
        for source in &pending.sources {
            let receipt = container
                .legacy_input_receipt(source)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("未完成导入缺少来源收据：{}", source.display()))?;
            let store = StoreSpec::new(&receipt.module,
                container.connection().query_row("SELECT source_identity FROM tb_stores WHERE store_id=?1", [&receipt.store_id], |r| r.get::<_, String>(0)).map_err(|e| e.to_string())?,
                &receipt.logical_path).map_err(|e| e.to_string())?;
            validate_pending_batch(&pending, container.path(), &store)?;
            let actual = if legacy_source_exists(source)? {
                Container::snapshot_digest_path(source).map_err(|e| e.to_string())?
            } else {
                let snapshot = pending.snapshots.iter().find(|s| &s.source == source)
                    .ok_or_else(|| format!("旧版本未完成导入缺少绑定快照：{}", source.display()))?;
                snapshot.digest.clone()
            };
            if receipt.retired
                || key != format!("migration_pending_store_v1:{}", receipt.store_id)
                || actual != receipt.source_digest
            {
                return Err(format!(
                    "未完成导入的来源发生变化，已保留旧账：{}",
                    source.display()
                ));
            }
        }
    }
    Ok(())
}

// The hook permits deterministic interruption/source-change tests without
// global flags or touching real user databases.
fn open_store_at_with_hook(
    container_path: &Path,
    module: &str,
    source_identity: &str,
    logical_path: &str,
    legacy_sources: &[PathBuf],
    require_initialized: bool,
    after_import: &dyn Fn() -> Result<(), String>,
) -> Result<StoreConnection, String> {
    if require_initialized {
        ensure_runtime_business_store_ready()?;
        verify_ready_container(container_path)?;
    }
    let store =
        StoreSpec::new(module, source_identity, logical_path).map_err(|error| error.to_string())?;
    let mut container = if require_initialized {
        Container::open_existing(&container_path).map_err(|error| error.to_string())?
    } else {
        Container::open(&container_path).map_err(|error| error.to_string())?
    };
    if require_initialized {
        #[cfg(not(test))]
        verify_active_container_identity(container_path)?;
    }
    container
        .register(&store)
        .map_err(|error| error.to_string())?;

    let has_objects = container
        .has_imported_objects(&store)
        .map_err(|error| error.to_string())?;
    let journal_key = format!("migration_pending_store_v1:{}", store.id);
    let journal_raw: Option<String> = container
        .connection()
        .query_row(
            "SELECT value FROM tb_container_meta WHERE key=?1",
            [&journal_key],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| error.to_string())?;
    let mut pending: Option<PendingLegacyImport> = journal_raw
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .map_err(|error| format!("未完成导入记录无效：{error}"))?;
    if pending.as_ref().is_some_and(|p| ![1, 2].contains(&p.version)) {
        return Err("未知的未完成导入版本，已保留旧账".into());
    }
    let globally_initialized = initialized_marker_path(container_path).is_file();
    if pending
        .as_ref()
        .is_some_and(|value| value.bootstrap && globally_initialized)
    {
        // Marker publication commits the bootstrap batch. Never replay its
        // frozen original files over rows subsequently written by the app.
        container
            .connection()
            .execute("DELETE FROM tb_container_meta WHERE key=?1", [&journal_key])
            .map_err(|error| error.to_string())?;
        pending = None;
    }
    if let Some(batch) = &mut pending { bind_legacy_pending_receipts(batch, &container, &store)?; }
    let mut all_sources = legacy_sources.to_vec();
    if let Some(batch) = &pending {
        validate_pending_batch(batch, container_path, &store)?;
        for source in &batch.sources {
            if !all_sources.contains(source) { all_sources.push(source.clone()); }
        }
    }
    let mut snapshots = Vec::new();
    let mut saw_retired_input = false;
    for legacy_path in &all_sources {
        if !legacy_source_exists(legacy_path)? {
            if let Some(batch) = &pending {
                if batch.sources.contains(legacy_path) {
                    let frozen = batch.snapshots.iter().find(|s| &s.source == legacy_path)
                        .ok_or_else(|| format!("旧版本未完成导入缺少绑定快照：{}", legacy_path.display()))?;
                    snapshots.push((frozen.source.clone(), frozen.backup.clone(), frozen.digest.clone()));
                }
            }
            continue;
        }
        if let Some(receipt) = container
            .legacy_input_receipt(legacy_path)
            .map_err(|error| error.to_string())?
        {
            if receipt.retired {
                if pending.is_some() {
                    return Err("未完成导入引用了已退役分区，拒绝重新激活".into());
                }
                // A retired physical stage/archive is evidence only. Reusing
                // its path must use a fresh store identity; never hash or
                // replay it on the ordinary open path.
                saw_retired_input = true;
                continue;
            }
            if receipt.store_id == store.id
                && receipt.module == store.module
                && receipt.logical_path == store.logical_path
            {
                if pending.is_none() {
                    // Old builds did not journal an unfinished batch. Before
                    // global activation, validate their receipts but never
                    // guess which namespace is safe to replace.
                    if !globally_initialized
                        && Container::snapshot_digest_path(legacy_path)
                            .map_err(|error| error.to_string())?
                            != receipt.source_digest
                    {
                        return Err(
                            "旧版本未完成导入的来源已变化；保留旧账，需核对或恢复该批次".into()
                        );
                    }
                    continue;
                }
            } else {
                return Err(format!(
                    "旧业务数据库来源已属于另一隔离分区：{}",
                    legacy_path.display()
                ));
            }
        }
        let source_digest =
            Container::snapshot_digest_path(legacy_path).map_err(|error| error.to_string())?;
        let backup_path = backup_path(&container_path, &store, legacy_path, &source_digest);
        Container::ensure_verified_backup(legacy_path, &backup_path, &source_digest)
            .map_err(|error| error.to_string())?;
        if Container::snapshot_digest_path(legacy_path).map_err(|error| error.to_string())?
            != source_digest
        {
            return Err(format!(
                "旧业务数据库在生成快照期间发生变化，拒绝导入：{}",
                legacy_path.display()
            ));
        }
        if let Some(frozen) = pending.as_ref().and_then(|batch| batch.snapshots.iter().find(|s| &s.source == legacy_path)) {
            if source_digest != frozen.digest && !Container::retry_snapshot_covers(&backup_path, &frozen.backup, module).map_err(|e| e.to_string())? {
                return Err(format!("重试来源不再覆盖已冻结的旧账，保留两个快照并停止替换：{}", legacy_path.display()));
            }
        }
        snapshots.push((legacy_path.clone(), backup_path, source_digest));
    }
    if has_objects && snapshots.is_empty() {
        return container
            .into_store_connection(&store)
            .map_err(|error| error.to_string());
    }
    let mut relocation_aliases = false;
    if snapshots.len() > 1 && snapshots.iter().any(|(_, _, digest)| *digest != snapshots[0].2) {
        let mut covering = None;
        if module == "exact" {
            for candidate in 0..snapshots.len() {
                let mut covers = true;
                for other in 0..snapshots.len() {
                    if candidate == other { continue; }
                    if !Container::exact_snapshot_covers(&snapshots[candidate].1, &snapshots[other].1)
                        .map_err(|e| e.to_string())? { covers = false; break; }
                }
                if covers { covering = Some(candidate); break; }
            }
        }
        let Some(covering) = covering else {
            return Err(format!(
                "同一业务分区存在内容不同的旧库候选；保留所有来源并拒绝切换：{logical_path}；来源：{}",
                snapshots.iter().map(|(p, _, _)| p.display().to_string()).collect::<Vec<_>>().join(" | ")
            ));
        };
        snapshots.swap(0, covering);
        relocation_aliases = true;
    }
    let record_input = |container: &mut Container, source: &Path, backup: &Path, digest: &str| -> Result<(), String> {
        if module == "exact" && (relocation_aliases || has_objects) {
            let proof = container.proof(&store).map_err(|e| e.to_string())?;
            if format!("{}:{}", proof.schema_digest, proof.rows_digest) != digest {
                return container.record_exact_relocation_input(backup, &store, source, backup).map_err(|e| e.to_string());
            }
        }
        container.record_identical_legacy_input(backup, &store, source, backup, now_unix()).map_err(|e| e.to_string())
    };
    // A journal authorizes retrying an import, not discarding any rows that
    // another writer added to its destination. Only a complete receipt-bound
    // frozen image may be replaced; compare again under the SQLite write lock.
    let expected_destination = if pending.as_ref().is_some_and(|p| p.replace_uncommitted) && !snapshots.is_empty() {
        let actual = container.proof(&store).map_err(|e|e.to_string())?;
        if has_objects {
            let mut frozen = pending.as_ref().unwrap().snapshots.clone();
            for source in &pending.as_ref().unwrap().sources {
                if let Some(r)=container.legacy_input_receipt(source).map_err(|e|e.to_string())? {
                    if r.retired || r.store_id!=store.id || r.module!=store.module || r.logical_path!=store.logical_path { return Err("未完成批次的目标归属不一致，已保留旧账".into()); }
                    frozen.push(PendingSnapshot { source: source.clone(), backup: PathBuf::from(r.backup_path), digest: r.source_digest });
                }
            }
            let mut matches = false;
            for snapshot in &frozen {
                validate_pending_snapshot(container_path,&store,snapshot)?;
                if Container::snapshot_proof_path(&snapshot.backup).map_err(|e|e.to_string())? == actual { matches=true; break; }
            }
            if !matches { return Err("未完成导入的目标已有独立账目变化，保留现有账目与全部快照，拒绝覆盖".into()); }
        }
        Some(actual)
    } else { None };
    // A journal is written BEFORE the first namespace replacement. Only a
    // journaled, never-activated import may be replaced during recovery.
    if !snapshots.is_empty() {
        let batch = PendingLegacyImport {
            version: 2,
            snapshots: snapshots.iter().map(|(source, backup, digest)| PendingSnapshot { source: source.clone(), backup: backup.clone(), digest: digest.clone() }).collect(),
            sources: snapshots
                .iter()
                .map(|(source, _, _)| source.clone())
                .collect(),
            bootstrap: !globally_initialized,
            replace_uncommitted: pending
                .as_ref()
                .map_or(!has_objects, |batch| batch.replace_uncommitted),
        };
        // Keep every superseded attempt's proof and ownership outside the
        // mutable retry journal. Activation must not orphan the prior backup.
        let history = pending.as_ref().map(|p| p.snapshots.as_slice()).unwrap_or(&[])
            .iter().chain(batch.snapshots.iter());
        for snapshot in history {
            let key = format!("migration_snapshot_history_v1:{}:{}", store.id,
                hex_digest(&Sha256::digest(serde_json::to_vec(snapshot).map_err(|e| e.to_string())?)));
            let json = serde_json::to_string(snapshot).map_err(|e| e.to_string())?;
            container.connection().execute("INSERT OR IGNORE INTO tb_container_meta(key,value) VALUES(?1,?2)", rusqlite::params![key,json]).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_string(&batch).map_err(|error| error.to_string())?;
        container
            .connection()
            .execute(
                "INSERT OR REPLACE INTO tb_container_meta(key,value) VALUES (?1,?2)",
                rusqlite::params![journal_key, json],
            )
            .map_err(|error| error.to_string())?;
    }
    if pending
        .as_ref()
        .is_some_and(|batch| batch.replace_uncommitted)
        && !snapshots.is_empty()
    {
        let (_, backup, digest) = &snapshots[0];
        let expected_source=Container::snapshot_proof_path(backup).map_err(|e|e.to_string())?;
        if format!("{}:{}",expected_source.schema_digest,expected_source.rows_digest)!=*digest { return Err("未完成导入快照在替换前发生变化，已保留旧账".into()); }
        container
            .replace_frozen_snapshot(backup, &store, backup, now_unix(), expected_destination.as_ref().ok_or("未完成导入缺少目标证明")?, &expected_source)
            .map_err(|error| error.to_string())?;
        // The journal remains durable across every step, including a crash
        // between replacing rows and updating source receipts.
        container
            .connection()
            .execute(
                "DELETE FROM tb_legacy_inputs WHERE store_id=?1 AND retired=0",
                [&store.id],
            )
            .map_err(|error| error.to_string())?;
        for (source_path, backup_path, digest) in &snapshots {
            record_input(&mut container, source_path, backup_path, digest)?;
        }
    } else if has_objects {
        for (source_path, backup_path, digest) in &snapshots {
            record_input(&mut container, source_path, backup_path, digest)?;
        }
    } else {
        let mut imported = false;
        for (source_path, backup_path, _) in &snapshots {
            if container
                .import_legacy_snapshot(
                    backup_path,
                    &store,
                    source_path,
                    backup_path,
                    now_unix(),
                    false,
                )
                .map_err(|error| error.to_string())?
                .is_some()
            {
                imported = true;
                break;
            }
        }
        if imported {
            for (source_path, backup_path, digest) in &snapshots {
                record_input(&mut container, source_path, backup_path, digest)?;
            }
        } else if !snapshots.is_empty() || saw_retired_input {
            return Err(format!(
                "旧业务库候选已退役且未变化；拒绝以空分区继续：{logical_path}"
            ));
        }
    }

    after_import()?;
    for (source_path, backup, digest) in &snapshots {
        let validation_path = if legacy_source_exists(source_path)? { source_path } else { backup };
        if Container::snapshot_digest_path(validation_path).map_err(|error| error.to_string())?
            != *digest
        {
            return Err(format!(
                "旧业务数据库在导入期间发生变化；容器保留快照且初始化不会完成：{}",
                source_path.display()
            ));
        }
    }

    if globally_initialized {
        container
            .connection()
            .execute("DELETE FROM tb_container_meta WHERE key=?1", [&journal_key])
            .map_err(|error| error.to_string())?;
    }
    // First-bootstrap journals remain pending until the global initialized
    // marker exists, so failure in a later module cannot freeze this source.
    container
        .into_store_connection(&store)
        .map_err(|error| error.to_string())
}

pub(crate) fn exact_store_spec(path: &Path) -> Result<StoreSpec, String> {
    if let Some((family, name)) = exact_stage_candidate_address(path)? {
        // A virtual stage must keep its identity when a physical staging
        // directory appears later. Its catalog address also permits recovery
        // without relying on fs::read_dir for namespace-only artifacts.
        let mut digest = Sha256::new();
        digest.update(b"tokenbar-exact-stage-candidate-v2\0");
        digest.update(family.as_bytes());
        digest.update(b"\0");
        digest.update(name.as_bytes());
        return StoreSpec::new("exact", format!("{:x}", digest.finalize()),
            format!("exact/staging/{family}/{name}"))
            .map_err(|error| error.to_string());
    }
    let identity = source_identity("exact", path)?;
    StoreSpec::new("exact", identity.clone(), format!("exact/index/{identity}"))
        .map_err(|error| error.to_string())
}

fn exact_stage_candidate_address(path: &Path) -> Result<Option<(String, String)>, String> {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else { return Ok(None) };
    let Some((source, contract)) = name.strip_suffix(".sqlite3")
        .and_then(|name| name.split_once(".candidate-v2-")) else { return Ok(None) };
    let hash = |text: &str| text.len() == 64 && text.bytes().all(|byte| byte.is_ascii_hexdigit());
    if !hash(source) || !hash(contract) { return Ok(None); }
    let Some(directory) = path.parent() else { return Ok(None) };
    let Some(index_name) = directory.file_name().and_then(|name| name.to_str())
        .and_then(|name| name.strip_suffix(".staging")) else { return Ok(None) };
    let index = directory.with_file_name(index_name);
    Ok(Some((source_identity("exact", &index)?, name.to_owned())))
}

pub(crate) fn exact_stage_candidates(index: &Path, source_digest: &str) -> Result<Vec<PathBuf>, String> {
    let family = source_identity("exact", index)?;
    let prefix = format!("exact/staging/{family}/{source_digest}.candidate-v2-");
    let container = open_ready_container(&container_path()?)?;
    let mut statement = container.connection().prepare(
        "SELECT logical_path,source_identity FROM tb_stores \
         WHERE module='exact' AND state IN ('ready','sealed') AND substr(logical_path,1,?1)=?2"
    ).map_err(|error| error.to_string())?;
    let entries = statement.query_map(rusqlite::params![prefix.len(), prefix], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }).map_err(|error| error.to_string())?;
    let mut directory = index.as_os_str().to_os_string();
    directory.push(".staging");
    let directory = PathBuf::from(directory);
    let mut paths = Vec::new();
    for entry in entries {
        let (logical, identity) = entry.map_err(|error| error.to_string())?;
        let name = logical.rsplit('/').next().ok_or("暂存候选缺少目录项")?;
        let path = directory.join(name);
        let expected = exact_store_spec(&path)?;
        if expected.logical_path != logical || expected.source_identity != identity {
            return Err("暂存候选目录与业务分区身份不一致；已保留候选".into());
        }
        paths.push(path);
    }
    Ok(paths)
}

/// Once A has been activated, its imported source receipts are historical
/// ownership records, not invitations to reopen old physical writers. Unknown
/// inputs still need reconciliation; mere registration never commits a store.
pub(crate) fn exact_sources_already_consumed(
    target: &Path,
    sources: &[PathBuf],
) -> Result<bool, String> {
    let path = container_path()?;
    if !initialized_marker_path(&path).is_file() {
        return Ok(false);
    }
    let container = open_ready_container(&path)?;
    let store = exact_store_spec(target)?;
    if !container.is_registered(&store).map_err(|e| e.to_string())?
        || !container.has_imported_objects(&store).map_err(|e| e.to_string())? {
        return Ok(false);
    }
    let pending: Option<String> = container.connection().query_row(
        "SELECT value FROM tb_container_meta WHERE key=?1",
        [format!("migration_pending_store_v1:{}",store.id)], |r| r.get(0),
    ).optional().map_err(|e| e.to_string())?;
    if let Some(pending) = pending {
        let batch: PendingLegacyImport = serde_json::from_str(&pending).map_err(|e| format!("未完成导入记录无效：{e}"))?;
        if ![1,2].contains(&batch.version) { return Err("未知的未完成导入版本，已保留旧账".into()); }
        // Only the initialized marker commits a first-bootstrap batch. A
        // failed late import remains pending even if it already wrote a path
        // receipt; it must be revalidated before that path can be frozen.
        if !batch.bootstrap { return Ok(false); }
    }
    for source in sources {
        if let Some(receipt) = container.legacy_input_receipt(source).map_err(|e| e.to_string())? {
            if receipt.store_id != store.id || receipt.module != store.module
                || receipt.logical_path != store.logical_path {
                return Ok(false);
            }
        } else if legacy_source_exists(source)? {
            return Ok(false);
        }
    }
    Ok(true)
}

const LEGACY_EXACT_MIGRATION_KEY: &str = "legacy_exact_migration_v1:";

/// Bootstrap alone owns this receipt. It distinguishes immutable physical
/// legacy artifacts from the A-owned schema migration of the imported rows.
pub(crate) fn preserve_legacy_exact_migration(
    path: &Path,
    manifests: &[(PathBuf, String)],
) -> Result<(), String> {
    let store = exact_store_spec(path)?;
    let container = Container::open_existing(container_path()?).map_err(|e| e.to_string())?;
    if !container.is_registered(&store).map_err(|e| e.to_string())? {
        return Err("尚未导入旧 Exact 账本，拒绝登记迁移凭据".into());
    }
    validate_legacy_exact_migration_receipt(&container, &store)?;
    let value = serde_json::json!({"version":1,"logicalPath":store.logical_path,"manifests":manifests});
    container.connection().execute(
        "INSERT OR REPLACE INTO tb_container_meta(key,value) VALUES (?1,?2)",
        rusqlite::params![format!("{LEGACY_EXACT_MIGRATION_KEY}{}", store.id), value.to_string()],
    ).map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn preserves_legacy_exact_migration(path: &Path) -> Result<bool, String> {
    let store = exact_store_spec(path)?;
    let container = open_ready_container(&container_path()?)?;
    validate_legacy_exact_migration_receipt(&container, &store)
}

/// Registration alone is insufficient: a physical legacy candidate must not
/// become a resumable A candidate simply because somebody opened its path.
pub(crate) fn owns_exact_migration_artifact(path: &Path) -> Result<bool, String> {
    let store = exact_store_spec(path)?;
    let container = open_ready_container(&container_path()?)?;
    Ok(container.is_registered(&store).map_err(|e| e.to_string())?
        && container.has_imported_objects(&store).map_err(|e| e.to_string())?
        && container.legacy_input_receipt(path).map_err(|e| e.to_string())?.is_none())
}

pub(crate) fn exact_store_has_objects(path: &Path) -> Result<bool, String> {
    let store = exact_store_spec(path)?;
    let container = open_ready_container(&container_path()?)?;
    Ok(container.is_registered(&store).map_err(|e| e.to_string())?
        && container.has_imported_objects(&store).map_err(|e| e.to_string())?)
}

fn validate_legacy_exact_migration_receipt(container: &Container, store: &StoreSpec) -> Result<bool, String> {
    let raw: Option<String> = container.connection().query_row(
        "SELECT value FROM tb_container_meta WHERE key=?1",
        [format!("{LEGACY_EXACT_MIGRATION_KEY}{}", store.id)], |r| r.get(0),
    ).optional().map_err(|e| e.to_string())?;
    let Some(raw) = raw else { return Ok(false); };
    let value: serde_json::Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
    if value["version"] != 1 || value["logicalPath"] != store.logical_path {
        return Err("旧 Exact 迁移保留凭据无效，已停止写入".into());
    }
    Ok(true)
}

pub(crate) fn exact_store_exists(path: &Path) -> Result<bool, String> {
    let container_path = container_path()?;
    if !container_path.is_file() {
        return Ok(false);
    }
    let store = exact_store_spec(path)?;
    open_ready_container(&container_path)?
        .is_registered(&store)
        .map_err(|error| error.to_string())
}

pub(crate) fn exact_legacy_input_is_retired_unchanged(path: &Path) -> Result<bool, String> {
    let container_path = container_path()?;
    if !container_path.is_file() || !path.is_file() {
        return Ok(false);
    }
    open_ready_container(&container_path)?
        .legacy_input_is_retired_unchanged(path)
        .map_err(|error| error.to_string())
}

pub(crate) fn clone_exact_store(
    source_path: &Path,
    target_path: &Path,
) -> Result<StoreProof, String> {
    let source = exact_store_spec(source_path)?;
    let target = exact_store_spec(target_path)?;
    let source_connection = open_store(
        "exact",
        &source.source_identity,
        &source.logical_path,
        &[source_path.to_path_buf()],
    )?;
    drop(source_connection);
    open_ready_container(&container_path()?)?
        .clone_store_namespace(&source, &target)
        .map_err(|error| error.to_string())
}

pub(crate) fn replace_exact_store(
    candidate_path: &Path,
    active_path: &Path,
) -> Result<StoreProof, String> {
    clone_exact_store(candidate_path, active_path)
}

pub(crate) fn remove_exact_store(path: &Path) -> Result<bool, String> {
    let container_path = container_path()?;
    if !container_path.is_file() {
        return Ok(false);
    }
    let store = exact_store_spec(path)?;
    let mut container = open_ready_container(&container_path)?;
    if !container
        .is_registered(&store)
        .map_err(|error| error.to_string())?
    {
        return Ok(false);
    }
    container
        .remove_store_namespace(&store)
        .map_err(|error| error.to_string())?;
    Ok(true)
}

pub(crate) fn seal_exact_store(path: &Path) -> Result<(), String> {
    let store = exact_store_spec(path)?;
    open_ready_container(&container_path()?)?
        .seal_store(&store, now_unix())
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub(crate) fn exact_store_observation(
    path: &Path,
) -> Result<Option<(u64, i64, String, f64)>, String> {
    let store = exact_store_spec(path)?;
    open_ready_container(&container_path()?)?
        .seal_observation(&store)
        .map_err(|error| error.to_string())
}

pub(crate) fn attach_exact_store_alias(
    connection: &StoreConnection,
    alias: &str,
    path: &Path,
) -> Result<(), String> {
    let container_path = container_path()?;
    if !container_path.is_file() {
        return Err("业务数据库 A 不存在，不能附加精确 token 暂存分区".into());
    }
    let store = exact_store_spec(path)?;
    let container = open_ready_container(&container_path)?;
    if !container
        .is_registered(&store)
        .map_err(|error| error.to_string())?
    {
        return Err("精确 token 暂存分区未注册".into());
    }
    if container
        .seal_observation(&store)
        .map_err(|error| error.to_string())?
        .is_none()
    {
        return Err("精确 token 暂存分区尚未封存".into());
    }
    let object_names = container
        .logical_object_names(&store)
        .map_err(|error| error.to_string())?;
    connection
        .register_readonly_namespace_alias(alias, store.prefix.clone(), object_names)
        .map_err(|error| format!("无法注册精确 token 只读暂存别名：{error}"))
}

pub(crate) fn detach_exact_store_alias(
    connection: &StoreConnection,
    alias: &str,
) -> Result<(), String> {
    connection
        .unregister_namespace_alias(alias)
        .map_err(|error| format!("无法移除精确 token 暂存别名：{error}"))
}

pub(crate) fn export_store_to_path(
    source_identity: &str,
    module: &str,
    logical_path: &str,
    target_path: &Path,
) -> Result<(), String> {
    if let Some(parent) = target_path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let store =
        StoreSpec::new(module, source_identity, logical_path).map_err(|error| error.to_string())?;
    let container = open_ready_container(&container_path()?)?;
    let mut target = Connection::open(target_path).map_err(|error| error.to_string())?;
    container
        .export_to(&store, &mut target)
        .map_err(|error| error.to_string())?;
    Ok(())
}

/// Metadata failure is not evidence of absence. File symlinks are unsupported
/// legacy inputs; configured support-directory symlinks retain normal OS traversal.
fn legacy_source_exists(path: &Path) -> Result<bool, String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => Ok(true),
        Ok(_) => Err(format!("旧业务数据库不是普通文件；拒绝切换：{}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("无法检查旧业务数据库 {}：{error}", path.display())),
    }
}

fn bootstrap_legacy_stores() -> Result<(), String> {
    for path in [
        app_paths::quota_history_database_path(),
        app_paths::legacy_shared_quota_history_database_path(),
    ]
    .into_iter()
    .flatten()
    {
        if !legacy_source_exists(&path)? { continue; }
        let identity = source_identity("quota_history_legacy", &path)?;
        let logical_path = format!("legacy/quota-history/{identity}");
        let _ =
            open_store_during_bootstrap("quota_history_legacy", &identity, &logical_path, &[path])?;
    }
    if let Some(path) = app_paths::modeltrace_database_path() {
        if legacy_source_exists(&path)? {
            let identity = source_identity("modeltrace_legacy", &path)?;
            let logical_path = format!("legacy/modeltrace/{identity}");
            let _ =
                open_store_during_bootstrap("modeltrace_legacy", &identity, &logical_path, &[path])?;
        }
    }
    if let Some(directory) = app_paths::performance_trace_log_path()
        .and_then(|path| path.parent().map(Path::to_path_buf))
    {
        let entries = match std::fs::read_dir(&directory) {
            Ok(entries) => Some(entries),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => {
                return Err(format!(
                    "无法枚举旧 Body Speed 数据库目录 {}：{error}",
                    directory.display()
                ));
            }
        };
        if let Some(entries) = entries {
            for entry in entries {
                let entry = entry.map_err(|error| error.to_string())?;
                let path = entry.path();
                let Some(filename) = path.file_name().and_then(|name| name.to_str()) else {
                    continue;
                };
                let Some(identity_part) = filename
                    .strip_prefix("body-speed-")
                    .and_then(|name| name.strip_suffix(".sqlite"))
                else {
                    continue;
                };
                if identity_part.is_empty() {
                    continue;
                }
                let metadata = std::fs::symlink_metadata(&path).map_err(|error| {
                    format!("无法检查旧 Body Speed 数据库 {}：{error}", path.display())
                })?;
                if metadata.file_type().is_symlink() || !metadata.is_file() {
                    return Err(format!(
                        "旧 Body Speed 数据库不是普通文件；拒绝切换：{}",
                        path.display()
                    ));
                }
                // The physical Home fingerprint is already embedded in the
                // legacy filename. Keep this identity stable when the source
                // file is later archived or removed.
                let identity = filename.to_owned();
                let logical_path = format!("body-speed/{filename}");
                let _ =
                    open_store_during_bootstrap("body-speed", &identity, &logical_path, &[path])?;
            }
        }
    }
    Ok(())
}

fn initialized_marker_path(container_path: &Path) -> PathBuf {
    let mut value = container_path.as_os_str().to_os_string();
    value.push(".initialized");
    PathBuf::from(value)
}

fn verify_marker(container_path: &Path) -> Result<(), String> {
    let marker = initialized_marker_path(container_path);
    let container_metadata = std::fs::symlink_metadata(container_path)
        .map_err(|error| format!("业务数据库 A 缺少有效容器文件：{error}"))?;
    if container_metadata.file_type().is_symlink() || !container_metadata.is_file() {
        return Err("业务数据库 A 不是普通文件；拒绝打开".into());
    }
    let marker_metadata = std::fs::symlink_metadata(&marker)
        .map_err(|error| format!("业务数据库 A 缺少有效初始化标记：{error}"))?;
    if marker_metadata.file_type().is_symlink() || !marker_metadata.is_file() {
        return Err("业务数据库 A 初始化标记不是普通文件；拒绝写入".into());
    }
    let contents = std::fs::read(&marker)
        .map_err(|error| format!("业务数据库 A 缺少有效初始化标记：{error}"))?;
    if contents != b"tokenbar-codex-ledger-v1\n" {
        return Err("业务数据库 A 初始化标记损坏；拒绝写入".into());
    }
    Ok(())
}

fn verify_initialized(container_path: &Path) -> Result<(), String> {
    verify_marker(container_path)?;
    Container::open(container_path).map_err(|error| format!("业务数据库 A 校验失败：{error}"))?;
    #[cfg(not(test))]
    remember_active_container_identity(container_path)?;
    Ok(())
}

/// Retained Exact staging uses the runtime readiness and physical identity
/// fences without reopening A and reparsing its large MAIN catalog.
pub(crate) fn validate_exact_stage_container(path: &Path) -> Result<(), String> {
    ensure_runtime_business_store_ready()?;
    verify_marker(path)?;
    #[cfg(not(test))]
    verify_active_container_identity(path)?;
    Ok(())
}

fn open_ready_container(container_path: &Path) -> Result<Container, String> {
    ensure_runtime_business_store_ready()?;
    open_ready_container_during_bootstrap(container_path)
}

fn open_ready_container_during_bootstrap(container_path: &Path) -> Result<Container, String> {
    verify_ready_container(container_path)?;
    let container = Container::open_existing(container_path).map_err(|error| error.to_string())?;
    #[cfg(not(test))]
    verify_active_container_identity(container_path)?;
    Ok(container)
}

fn ensure_runtime_business_store_ready() -> Result<(), String> {
    #[cfg(test)]
    {
        // Unit tests exercise the route against isolated temporary containers;
        // coordinator transitions are tested independently without process
        // global state or races between test cases.
        Ok(())
    }
    #[cfg(not(test))]
    {
        crate::core::business_startup::process_coordinator().ensure_ready()
    }
}

fn verify_ready_container(container_path: &Path) -> Result<(), String> {
    verify_marker(container_path)?;
    #[cfg(not(test))]
    verify_active_container_identity(container_path)?;
    Ok(())
}

#[cfg(not(test))]
fn remember_active_container_identity(path: &Path) -> Result<(), String> {
    let observed = container_file_identity(path)?;
    let slot = ACTIVE_CONTAINER_IDENTITY.get_or_init(|| Mutex::new(None));
    let mut cached = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    match *cached {
        Some(expected) if expected != observed => {
            Err("codex-ledger A 容器文件身份在本次运行中发生变化；拒绝继续写入".into())
        }
        Some(_) => Ok(()),
        None => {
            *cached = Some(observed);
            Ok(())
        }
    }
}

#[cfg(not(test))]
fn verify_active_container_identity(path: &Path) -> Result<(), String> {
    let slot = ACTIVE_CONTAINER_IDENTITY.get_or_init(|| Mutex::new(None));
    let expected = slot
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .ok_or_else(|| "业务数据库 A 尚未在本次运行中完成身份缓存".to_string())?;
    let observed = container_file_identity(path)?;
    if observed != expected {
        return Err("codex-ledger A 容器文件已被替换；拒绝继续读写".into());
    }
    Ok(())
}

fn container_file_identity(path: &Path) -> Result<ContainerFileIdentity, String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| format!("无法读取业务数据库 A 文件身份：{error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("业务数据库 A 不是普通文件；拒绝打开".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        return Ok(ContainerFileIdentity {
            volume: metadata.dev(),
            file_id: u128::from(metadata.ino()),
        });
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{
            FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
        };
        let file = std::fs::File::open(path)
            .map_err(|error| format!("无法打开业务数据库 A 读取文件身份：{error}"))?;
        let mut information = FILE_ID_INFO::default();
        if unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle() as _,
                FileIdInfo,
                (&mut information as *mut FILE_ID_INFO).cast(),
                std::mem::size_of::<FILE_ID_INFO>() as u32,
            )
        } == 0
        {
            return Err(format!(
                "无法读取业务数据库 A 文件身份：{}",
                std::io::Error::last_os_error()
            ));
        }
        let file_id = information
            .FileId
            .Identifier
            .iter()
            .enumerate()
            .fold(0_u128, |value, (index, byte)| {
                value | (u128::from(*byte) << (index * 8))
            });
        return Ok(ContainerFileIdentity {
            volume: information.VolumeSerialNumber,
            file_id,
        });
    }
    #[cfg(not(any(unix, windows)))]
    {
        let canonical = std::fs::canonicalize(path).map_err(|error| error.to_string())?;
        let mut digest = Sha256::new();
        digest.update(canonical.to_string_lossy().as_bytes());
        digest.update(metadata.len().to_be_bytes());
        let bytes = digest.finalize();
        let mut file_id = [0_u8; 16];
        file_id.copy_from_slice(&bytes[..16]);
        Ok(ContainerFileIdentity {
            volume: 0,
            file_id: u128::from_be_bytes(file_id),
        })
    }
}

fn backup_path(
    container_path: &Path,
    store: &StoreSpec,
    source: &Path,
    source_digest: &str,
) -> PathBuf {
    let source_hash = source
        .to_str()
        .map(|value| hex_digest(&Sha256::digest(value.as_bytes())))
        .unwrap_or_else(|| "nonutf8-source".into());
    let digest_hash = hex_digest(&Sha256::digest(source_digest.as_bytes()));
    let mut backup_key = Sha256::new();
    backup_key.update(b"tokenbar-business-snapshot-path-v1\0");
    backup_key.update(store.id.as_bytes());
    backup_key.update(b"\0");
    backup_key.update(source_hash.as_bytes());
    backup_key.update(b"\0");
    backup_key.update(digest_hash.as_bytes());
    let backup_name = hex_digest(&backup_key.finalize());
    container_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("codex-ledger-snapshots")
        // Keep the filename bounded: the previous concatenated hashes could
        // exceed Windows MAX_PATH below runner temp directories and user paths.
        .join(format!("{backup_name}.sqlite"))
}

fn now_unix() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

fn hex_digest(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::{params, OpenFlags};
    use std::fs;
    use uuid::Uuid;

    #[test]
    fn registered_read_only_store_does_not_wait_for_or_modify_a_publisher() {
        let fixture = Fixture::new();
        let support = fixture.path("support");
        fs::create_dir_all(&support).unwrap();
        let _environment = app_paths::app_path_test_env_guard(&[
            ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support.clone()),
        ]);
        let path = container_path().unwrap();
        assert_eq!(path, support.join("codex-ledger.sqlite"));
        let spec = StoreSpec::new("exact", "test-home", "test-index").unwrap();
        let container = Container::open(&path).unwrap();
        container.register(&spec).unwrap();
        let store = container.into_store_connection(&spec).unwrap();
        store.execute_batch("CREATE TABLE records(value INTEGER); INSERT INTO records VALUES(41)").unwrap();
        drop(store);
        fs::write(initialized_marker_path(&path), b"tokenbar-codex-ledger-v1\n").unwrap();
        let writer = Container::open_existing(&path).unwrap();
        let physical_table = format!("{}records", spec.prefix);
        writer.connection().execute_batch(&format!(
            "BEGIN IMMEDIATE; UPDATE \"{physical_table}\" SET value=42"
        )).unwrap();

        // Registration would need the writer lock and fail at this timeout.
        let reader = open_registered_store_read_only(
            "exact", "test-home", "test-index", std::time::Duration::from_millis(25),
        ).unwrap().unwrap();
        assert_eq!(reader.query_row("SELECT value FROM records", [], |row| row.get::<_, i64>(0)).unwrap(), 41);
        let error = reader.execute("INSERT INTO records VALUES(99)", []).unwrap_err();
        assert_eq!(error.sqlite_error_code(), Some(rusqlite::ErrorCode::ReadOnly));
        drop(reader);
        writer.connection().execute_batch("ROLLBACK").unwrap();
        assert_eq!(writer.connection().query_row(
            &format!("SELECT value FROM \"{physical_table}\""), [], |row| row.get::<_, i64>(0),
        ).unwrap(), 41);
    }

    #[test]
    fn registered_read_only_store_never_creates_or_registers_missing_inputs() {
        let fixture = Fixture::new();
        let support = fixture.path("support");
        fs::create_dir_all(&support).unwrap();
        let _environment = app_paths::app_path_test_env_guard(&[
            ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support.clone()),
        ]);
        let path = container_path().unwrap();
        assert_eq!(path, support.join("codex-ledger.sqlite"));
        assert!(open_registered_store_read_only(
            "exact", "home", "index", std::time::Duration::from_millis(25),
        ).is_err());
        assert!(!path.exists());
        let container = Container::open(&path).unwrap();
        drop(container);
        // A valid physical database without the activation marker stays gated.
        assert!(open_registered_store_read_only(
            "exact", "home", "index", std::time::Duration::from_millis(25),
        ).is_err());
        fs::write(initialized_marker_path(&path), b"tokenbar-codex-ledger-v1\n").unwrap();
        assert!(open_registered_store_read_only(
            "exact", "home", "index", std::time::Duration::from_millis(25),
        ).unwrap().is_none());
        let container = Container::open_existing(&path).unwrap();
        assert!(!container.is_registered(&StoreSpec::new("exact", "home", "index").unwrap()).unwrap());
        container.connection().execute(
            "UPDATE tb_container_meta SET value='999' WHERE key='schema_version'", [],
        ).unwrap();
        assert!(open_registered_store_read_only(
            "exact", "home", "index", std::time::Duration::from_millis(25),
        ).is_err(), "unknown container versions must never be repaired by a reader");
        assert_eq!(container.connection().query_row(
            "SELECT value FROM tb_container_meta WHERE key='schema_version'", [], |row| row.get::<_, String>(0),
        ).unwrap(), "999");
    }

    #[test]
    fn consumed_sources_require_activation_rows_and_complete_path_ownership() {
        let fixture = Fixture::new();
        let support = fixture.path("support");
        fs::create_dir_all(&support).unwrap();
        let _guard = app_paths::app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support)]);
        let target = fixture.path("active.sqlite3");
        let old = fixture.path("old.sqlite3");
        seed_legacy(&old);
        let store = exact_store_spec(&target).unwrap();
        drop(open_store_during_bootstrap("exact", &store.source_identity, &store.logical_path, &[old.clone()]).unwrap());
        assert!(!exact_sources_already_consumed(&target, &[old.clone()]).unwrap());
        fs::write(initialized_marker_path(&container_path().unwrap()), b"tokenbar-codex-ledger-v1\n").unwrap();
        assert!(exact_sources_already_consumed(&target, &[target.clone(), old.clone()]).unwrap());
        // A owns the committed rows; retired files can disappear or become
        // unreadable without making an ordinary open replay them over A.
        fs::write(&old, b"must never be opened as SQLite again").unwrap();
        assert!(exact_sources_already_consumed(&target, &[old.clone()]).unwrap());
        fs::remove_file(&old).unwrap();
        assert!(exact_sources_already_consumed(&target, &[old]).unwrap());
        let unknown = fixture.path("unknown.sqlite3");
        seed_legacy(&unknown);
        assert!(!exact_sources_already_consumed(&target, &[unknown]).unwrap());
        let empty = fixture.path("empty.sqlite3");
        Container::open_existing(container_path().unwrap()).unwrap().register(&exact_store_spec(&empty).unwrap()).unwrap();
        assert!(!exact_sources_already_consumed(&empty, &[]).unwrap());
    }

    #[test]
    fn physical_candidates_and_empty_registration_are_not_owned_a_migration_artifacts() {
        let fixture = Fixture::new();
        let support = fixture.path("support");
        fs::create_dir_all(&support).unwrap();
        let _guard = app_paths::app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support)]);
        let raw = fixture.path("old.schema11-candidate");
        seed_legacy(&raw);
        let spec = exact_store_spec(&raw).unwrap();
        drop(open_store_during_bootstrap("exact", &spec.source_identity, &spec.logical_path, &[raw.clone()]).unwrap());
        fs::write(initialized_marker_path(&container_path().unwrap()), b"tokenbar-codex-ledger-v1\n").unwrap();
        assert!(exact_store_has_objects(&raw).unwrap());
        assert!(!owns_exact_migration_artifact(&raw).unwrap());
        let empty = fixture.path("registered-only");
        let container = Container::open_existing(container_path().unwrap()).unwrap();
        container.register(&exact_store_spec(&empty).unwrap()).unwrap();
        drop(container);
        assert!(!exact_store_has_objects(&empty).unwrap());
        assert!(!owns_exact_migration_artifact(&empty).unwrap());
        let native = fixture.path("native-a-candidate");
        clone_exact_store(&raw, &native).unwrap();
        assert!(owns_exact_migration_artifact(&native).unwrap());
    }

    #[test]
    fn legacy_migration_ownership_is_explicit_and_unknown_receipts_are_not_overwritten() {
        let fixture = Fixture::new();
        let support = fixture.path("support");
        fs::create_dir_all(&support).unwrap();
        let _guard = app_paths::app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support)]);
        let path = fixture.path("logical.sqlite3");
        let spec = exact_store_spec(&path).unwrap();
        let container = Container::open(container_path().unwrap()).unwrap();
        container.register(&spec).unwrap();
        assert!(!validate_legacy_exact_migration_receipt(&container, &spec).unwrap());
        drop(container);
        preserve_legacy_exact_migration(&path, &[(fixture.path("old-manifest.json"), "proof".into())]).unwrap();
        let container = Container::open_existing(container_path().unwrap()).unwrap();
        assert!(validate_legacy_exact_migration_receipt(&container, &spec).unwrap());
        let key = format!("{LEGACY_EXACT_MIGRATION_KEY}{}", spec.id);
        let unknown = serde_json::json!({"version":999,"logicalPath":spec.logical_path}).to_string();
        container.connection().execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2", rusqlite::params![unknown,key]).unwrap();
        assert!(validate_legacy_exact_migration_receipt(&container, &spec).is_err());
        drop(container);
        assert!(preserve_legacy_exact_migration(&path, &[]).is_err());
        let container = Container::open_existing(container_path().unwrap()).unwrap();
        let unchanged: String = container.connection().query_row("SELECT value FROM tb_container_meta WHERE key=?1", [key], |r| r.get(0)).unwrap();
        assert_eq!(unchanged, unknown);
    }

    #[test]
    fn legacy_file_discovery_distinguishes_missing_and_nonregular_inputs() {
        let root = tempfile::tempdir().unwrap();
        assert!(!legacy_source_exists(&root.path().join("absent.sqlite")).unwrap());
        assert!(legacy_source_exists(root.path()).is_err());
        let source = root.path().join("legacy.sqlite");
        fs::write(&source, b"retained evidence").unwrap();
        assert!(legacy_source_exists(&source).unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn legacy_file_discovery_rejects_permission_errors_and_file_symlinks() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("modeltrace");
        fs::create_dir(&directory).unwrap();
        let source = directory.join("modeltrace.sqlite");
        fs::write(&source, b"retained evidence").unwrap();
        if unsafe { libc::geteuid() } != 0 {
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o000)).unwrap();
            let result = legacy_source_exists(&source);
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
            assert!(result.is_err(), "Inaccessible metadata must not skip a legacy module");
        }
        let alias = root.path().join("legacy-symlink.sqlite");
        symlink(&source, &alias).unwrap();
        assert!(legacy_source_exists(&alias).is_err());
        let root_alias = root.path().join("configured-support-root");
        symlink(&directory, &root_alias).unwrap();
        assert!(legacy_source_exists(&root_alias.join("modeltrace.sqlite")).unwrap(),
                "Configured directory aliases retain normal OS traversal");
        assert_eq!(fs::read(source).unwrap(), b"retained evidence");
    }

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("store-route-{}", Uuid::new_v4()));
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

    #[test]
    fn online_backup_is_consistent_and_preserves_legacy_source() {
        let fixture = Fixture::new();
        let source_path = fixture.path("legacy.sqlite");
        let backup_path = fixture.path("snapshot.sqlite");
        let source = Connection::open(&source_path).unwrap();
        source
            .execute_batch("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT);")
            .unwrap();
        source
            .execute("INSERT INTO sample VALUES (?1, ?2)", params![41, "legacy"])
            .unwrap();
        drop(source);
        Container::backup_snapshot(&source_path, &backup_path).unwrap();
        let source =
            Connection::open_with_flags(&source_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let snapshot =
            Connection::open_with_flags(&backup_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let original: i64 = source
            .query_row("SELECT id FROM sample", [], |row| row.get(0))
            .unwrap();
        let copied: String = snapshot
            .query_row("SELECT value FROM sample WHERE id=41", [], |row| row.get(0))
            .unwrap();
        assert_eq!(original, 41);
        assert_eq!(copied, "legacy");
    }

    #[test]
    fn source_identity_is_hashed_and_stable_for_canonical_home() {
        let fixture = Fixture::new();
        let first = source_identity("exact", &fixture.0).unwrap();
        let second = source_identity("exact", &fixture.0).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
        assert_ne!(first, source_identity("quota", &fixture.0).unwrap());
    }

    #[test]
    fn source_identity_stays_stable_after_database_file_removal() {
        let fixture = Fixture::new();
        let path = fixture.path("legacy.sqlite");
        drop(Connection::open(&path).unwrap());
        let while_present = source_identity("modeltrace_legacy", &path).unwrap();
        fs::remove_file(&path).unwrap();
        let after_removal = source_identity("modeltrace_legacy", &path).unwrap();
        assert_eq!(while_present, after_removal);
    }

    #[test]
    fn snapshot_backup_filename_stays_bounded_and_tracks_source_version() {
        let fixture = Fixture::new();
        let container = fixture.path("codex-ledger.sqlite");
        let store = StoreSpec::new("quota_history", "home", "quota").unwrap();
        let source = fixture.path("legacy.sqlite");
        let first = backup_path(&container, &store, &source, &"a".repeat(64));
        let same = backup_path(&container, &store, &source, &"a".repeat(64));
        let changed = backup_path(&container, &store, &source, &"b".repeat(64));

        assert_eq!(first, same);
        assert_ne!(first, changed);
        assert!(first.file_name().unwrap().to_str().unwrap().len() <= 72);
    }

    fn seed_legacy(path: &Path) {
        Connection::open(path).unwrap().execute_batch(
            "CREATE TABLE events(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO events VALUES(1,'old');"
        ).unwrap();
    }

    #[test]
    fn late_exact_alias_of_consumed_baseline_preserves_current_corrections() {
        let fixture = Fixture::new();
        let db = fixture.path("codex-ledger.sqlite");
        let original = fixture.path("old.sqlite");
        seed_legacy(&original);
        drop(open_store_at(&db,"exact","home","exact",std::slice::from_ref(&original),false).unwrap());
        fs::write(initialized_marker_path(&db),b"tokenbar-codex-ledger-v1\n").unwrap();
        let active = open_store_at(&db,"exact","home","exact",std::slice::from_ref(&original),true).unwrap();
        active.execute("UPDATE events SET value='audited compaction correction' WHERE id=1",[]).unwrap();
        active.execute("INSERT INTO events VALUES(2,'new active usage')",[]).unwrap();
        drop(active);
        let spec = StoreSpec::new("exact","home","exact").unwrap();
        let before = Container::open_existing(&db).unwrap().proof(&spec).unwrap();
        let alias = fixture.path("moved-old-copy.sqlite");
        fs::copy(&original,&alias).unwrap();
        let frozen = fs::read(&alias).unwrap();
        drop(open_store_at(&db,"exact","home","exact",std::slice::from_ref(&alias),true).unwrap());
        let container = Container::open_existing(&db).unwrap();
        assert_eq!(container.proof(&spec).unwrap(),before,"An old alias must never roll back corrected or newly recorded usage");
        assert!(container.legacy_input_receipt(&alias).unwrap().is_some());
        assert_eq!(fs::read(&alias).unwrap(),frozen);
        drop(container);
        let changed = fixture.path("unknown-new-history.sqlite");
        fs::copy(&original,&changed).unwrap();
        Connection::open(&changed).unwrap().execute("INSERT INTO events VALUES(3,'unproven history')",[]).unwrap();
        assert!(open_store_at(&db,"exact","home","exact",std::slice::from_ref(&changed),true).is_err());
        assert_eq!(Container::open_existing(&db).unwrap().proof(&spec).unwrap(),before);
        // An accepted path belonging to another partition is never stolen,
        // even when both baseline proofs are identical.
        let foreign = fixture.path("foreign.sqlite");
        fs::copy(&original,&foreign).unwrap();
        drop(open_store_at(&db,"exact","other-home","other-exact",std::slice::from_ref(&foreign),true).unwrap());
        assert!(open_store_at(&db,"exact","home","exact",std::slice::from_ref(&foreign),true).is_err());
        assert_eq!(Container::open_existing(&db).unwrap().proof(&spec).unwrap(),before);
    }

    #[test]
    fn failed_late_alias_cannot_be_frozen_by_its_partial_path_receipt() {
        let fixture = Fixture::new();
        let support = fixture.path("support");
        fs::create_dir_all(&support).unwrap();
        let _guard = app_paths::app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",support.clone())]);
        let db = container_path().unwrap();
        let target = support.join("logical-exact.sqlite");
        let spec = exact_store_spec(&target).unwrap();
        let original = fixture.path("original.sqlite");
        seed_legacy(&original);
        drop(open_store_at(&db,"exact",&spec.source_identity,&spec.logical_path,std::slice::from_ref(&original),false).unwrap());
        fs::write(initialized_marker_path(&db),b"tokenbar-codex-ledger-v1\n").unwrap();
        let active = open_store_at(&db,"exact",&spec.source_identity,&spec.logical_path,std::slice::from_ref(&original),true).unwrap();
        active.execute("UPDATE events SET value='corrected active ledger'",[]).unwrap();
        drop(active);
        let alias = fixture.path("late-copy.sqlite");
        fs::copy(&original,&alias).unwrap();
        let before = Container::open_existing(&db).unwrap().proof(&spec).unwrap();
        let result = open_store_at_with_hook(&db,"exact",&spec.source_identity,&spec.logical_path,std::slice::from_ref(&alias),true,&|| {
            Connection::open(&alias).unwrap().execute("UPDATE events SET value='source changed after import'",[]).unwrap();
            Ok(())
        });
        assert!(result.is_err());
        assert_eq!(Container::open_existing(&db).unwrap().proof(&spec).unwrap(),before);
        assert!(!exact_sources_already_consumed(&target,&[original,alias]).unwrap(),"An unfinished late batch must not take the consumed-source shortcut");
    }

    #[test]
    fn exact_alias_witness_must_belong_to_the_target_partition() {
        let fixture = Fixture::new();
        let db = fixture.path("codex-ledger.sqlite");
        let original = fixture.path("foreign-original.sqlite");
        seed_legacy(&original);
        drop(open_store_at(&db,"exact","foreign","foreign",std::slice::from_ref(&original),false).unwrap());
        fs::write(initialized_marker_path(&db),b"tokenbar-codex-ledger-v1\n").unwrap();
        let target = open_store_at(&db,"exact","target","target",&[],true).unwrap();
        target.execute_batch("CREATE TABLE events(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO events VALUES(1,'target current value')").unwrap();
        drop(target);
        let spec = StoreSpec::new("exact","target","target").unwrap();
        let before = Container::open_existing(&db).unwrap().proof(&spec).unwrap();
        let alias = fixture.path("unknown-alias.sqlite");
        fs::copy(&original,&alias).unwrap();
        assert!(open_store_at(&db,"exact","target","target",std::slice::from_ref(&alias),true).is_err());
        let container = Container::open_existing(&db).unwrap();
        assert_eq!(container.proof(&spec).unwrap(),before);
        assert!(container.legacy_input_receipt(&alias).unwrap().is_none());
    }

    #[test]
    fn interrupted_bootstrap_reimports_changed_source_and_freezes_only_after_activation() {
        let fixture = Fixture::new();
        let db = fixture.path("codex-ledger.sqlite");
        let raw = fixture.path("legacy.sqlite");
        seed_legacy(&raw);
        let sources = std::slice::from_ref(&raw);
        let failed = open_store_at_with_hook(
            &db,
            "quota_history",
            "home",
            "quota",
            sources,
            false,
            &|| {
                Connection::open(&raw)
                    .unwrap()
                    .execute("INSERT INTO events VALUES(2,'new')", [])
                    .unwrap();
                Ok(())
            },
        );
        assert!(failed.is_err());
        let recovered =
            open_store_at(&db, "quota_history", "home", "quota", sources, false).unwrap();
        assert_eq!(
            recovered
                .query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            2
        );
        drop(recovered);
        verify_bootstrap_pending_inputs(&Container::open_existing(&db).unwrap()).unwrap();
        fs::write(initialized_marker_path(&db), b"tokenbar-codex-ledger-v1\n").unwrap();
        let active = open_store_at(&db, "quota_history", "home", "quota", sources, true).unwrap();
        active
            .execute("INSERT INTO events VALUES(99,'active-new-row')", [])
            .unwrap();
        drop(active);
        Connection::open(&raw)
            .unwrap()
            .execute("INSERT INTO events VALUES(3,'frozen')", [])
            .unwrap();
        let active = open_store_at(&db, "quota_history", "home", "quota", sources, true).unwrap();
        assert_eq!(
            active
                .query_row("SELECT COUNT(*) FROM events WHERE id=99", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            active
                .query_row("SELECT COUNT(*) FROM events WHERE id=3", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn interrupted_retry_never_replaces_frozen_unique_history_with_a_truncated_source() {
        let fixture = Fixture::new();
        let db = fixture.path("codex-ledger.sqlite");
        let raw = fixture.path("legacy.sqlite");
        seed_legacy(&raw);
        Connection::open(&raw).unwrap().execute("INSERT INTO events VALUES(2,'unique old history')", []).unwrap();
        let sources = std::slice::from_ref(&raw);
        assert!(open_store_at_with_hook(&db, "quota_history", "home", "quota", sources, false, &|| Err("interrupted".into())).is_err());
        let container = Container::open_existing(&db).unwrap();
        let receipt = container.legacy_input_receipt(&raw).unwrap().unwrap();
        let original_snapshot = fs::read(&receipt.backup_path).unwrap();
        let store = StoreSpec::new("quota_history", "home", "quota").unwrap();
        let before = container.proof(&store).unwrap();
        drop(container);
        Connection::open(&raw).unwrap().execute("DELETE FROM events WHERE id=2", []).unwrap();
        assert!(open_store_at(&db, "quota_history", "home", "quota", sources, false).is_err());
        let container = Container::open_existing(&db).unwrap();
        assert_eq!(container.proof(&store).unwrap(), before);
        assert_eq!(fs::read(&receipt.backup_path).unwrap(), original_snapshot);
        assert_eq!(container.legacy_input_receipt(&raw).unwrap().unwrap().source_digest, receipt.source_digest);
        assert!(!initialized_marker_path(&db).exists());
    }

    #[test]
    fn interrupted_late_import_preserves_other_activated_partition() {
        let fixture = Fixture::new();
        let db = fixture.path("codex-ledger.sqlite");
        Container::open(&db).unwrap();
        fs::write(initialized_marker_path(&db), b"tokenbar-codex-ledger-v1\n").unwrap();
        let active = open_store_at(&db, "quota_history", "active", "active", &[], true).unwrap();
        active
            .execute_batch("CREATE TABLE live(id INTEGER); INSERT INTO live VALUES(88)")
            .unwrap();
        drop(active);
        let raw = fixture.path("late.sqlite");
        seed_legacy(&raw);
        let sources = std::slice::from_ref(&raw);
        assert!(
            open_store_at_with_hook(&db, "body", "late", "late", sources, true, &|| Err(
                "interrupted".into()
            ))
            .is_err()
        );
        Connection::open(&raw)
            .unwrap()
            .execute("INSERT INTO events VALUES(2,'new')", [])
            .unwrap();
        let recovered = open_store_at(&db, "body", "late", "late", sources, true).unwrap();
        assert_eq!(
            recovered
                .query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            2
        );
        let active = open_store_at(&db, "quota_history", "active", "active", &[], true).unwrap();
        assert_eq!(
            active
                .query_row("SELECT id FROM live", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            88
        );
    }

    #[test]
    fn pending_disappeared_source_recovers_only_from_bound_verified_snapshot() {
        for corrupt in [false, true] {
            let fixture = Fixture::new();
            let db = fixture.path("codex-ledger.sqlite");
            let raw = fixture.path("legacy.sqlite");
            seed_legacy(&raw);
            drop(open_store_at(&db, "quota_history", "home", "quota", std::slice::from_ref(&raw), false).unwrap());
            let container = Container::open_existing(&db).unwrap();
            let receipt = container.legacy_input_receipt(&raw).unwrap().unwrap();
            drop(container);
            fs::remove_file(&raw).unwrap();
            if corrupt { fs::write(&receipt.backup_path, b"invalid frozen copy").unwrap(); }
            let result = resume_pending_bootstrap_imports(&db);
            if corrupt {
                assert!(result.is_err());
                assert!(!initialized_marker_path(&db).exists());
                continue;
            }
            result.unwrap();
            verify_bootstrap_pending_inputs(&Container::open_existing(&db).unwrap()).unwrap();
            let active = open_store_at(&db, "quota_history", "home", "quota", &[], false).unwrap();
            assert_eq!(active.query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
            assert!(!raw.exists(), "Recovery must not recreate the old writer");
        }
    }

    #[test]
    fn public_v1_pending_receipts_bind_missing_sources_without_losing_frozen_rows() {
        for truncate in [false, true] {
            let fixture = Fixture::new();
            let db = fixture.path("codex-ledger.sqlite");
            let raw = fixture.path("old-cache/legacy.sqlite");
            fs::create_dir_all(raw.parent().unwrap()).unwrap();
            seed_legacy(&raw);
            drop(open_store_at(&db, "quota_history", "home", "quota", std::slice::from_ref(&raw), false).unwrap());
            let container = Container::open_existing(&db).unwrap();
            let store = StoreSpec::new("quota_history", "home", "quota").unwrap();
            let key = format!("migration_pending_store_v1:{}", store.id);
            let v1 = serde_json::json!({"sources":[raw],"bootstrap":true,"replace_uncommitted":true}).to_string();
            container.connection().execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2", rusqlite::params![v1,key]).unwrap();
            let before = container.proof(&store).unwrap();
            drop(container);
            if truncate { Connection::open(&raw).unwrap().execute("DELETE FROM events", []).unwrap(); }
            else { fs::remove_file(&raw).unwrap(); fs::remove_dir(raw.parent().unwrap()).unwrap(); }
            let result = resume_pending_bootstrap_imports(&db);
            if truncate {
                assert!(result.is_err());
                assert_eq!(Container::open_existing(&db).unwrap().proof(&store).unwrap(), before);
            } else {
                result.unwrap();
                verify_bootstrap_pending_inputs(&Container::open_existing(&db).unwrap()).unwrap();
                assert_eq!(Container::open_existing(&db).unwrap().proof(&store).unwrap(), before);
                assert!(!raw.exists());
            }
        }
    }

    #[test]
    fn pending_backup_can_be_recovered_from_the_identical_live_source_only() {
        let fixture = Fixture::new();
        let db = fixture.path("codex-ledger.sqlite");
        let raw = fixture.path("legacy.sqlite");
        seed_legacy(&raw);
        drop(open_store_at(&db, "quota_history", "home", "quota", std::slice::from_ref(&raw), false).unwrap());
        let container = Container::open_existing(&db).unwrap();
        let receipt = container.legacy_input_receipt(&raw).unwrap().unwrap();
        drop(container);
        let corrupt = b"partial app-owned backup";
        fs::write(&receipt.backup_path, corrupt).unwrap();
        resume_pending_bootstrap_imports(&db).unwrap();
        assert_eq!(Container::snapshot_digest_path(&receipt.backup_path).unwrap(), receipt.source_digest);
        let parent = Path::new(&receipt.backup_path).parent().unwrap();
        assert!(fs::read_dir(parent).unwrap().filter_map(Result::ok)
            .any(|entry| entry.file_name().to_string_lossy().starts_with(".tokenbar-backup-quarantine-") && fs::read(entry.path()).ok().as_deref() == Some(corrupt)));
    }

    #[test]
    fn pending_journal_never_reads_a_forged_backup_or_future_version() {
        for future in [false, true] {
            let fixture = Fixture::new();
            let db = fixture.path("codex-ledger.sqlite");
            let raw = fixture.path("legacy.sqlite");
            seed_legacy(&raw);
            drop(open_store_at(&db, "quota_history", "home", "quota", std::slice::from_ref(&raw), false).unwrap());
            let store = StoreSpec::new("quota_history", "home", "quota").unwrap();
            let container = Container::open_existing(&db).unwrap();
            let key = format!("migration_pending_store_v1:{}", store.id);
            let original: String = container.connection().query_row("SELECT value FROM tb_container_meta WHERE key=?1", [&key], |r| r.get(0)).unwrap();
            let mut forged: serde_json::Value = serde_json::from_str(&original).unwrap();
            let outside = fixture.path("user-export.sqlite");
            seed_legacy(&outside);
            let bytes = fs::read(&outside).unwrap();
            if future { forged["version"] = 999.into(); }
            else { forged["snapshots"][0]["backup"] = outside.to_string_lossy().to_string().into(); }
            let forged = forged.to_string();
            container.connection().execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2", rusqlite::params![forged, key]).unwrap();
            drop(container);
            fs::remove_file(&raw).unwrap();
            assert!(resume_pending_bootstrap_imports(&db).is_err());
            assert_eq!(fs::read(&outside).unwrap(), bytes);
            let container = Container::open_existing(&db).unwrap();
            let retained: String = container.connection().query_row("SELECT value FROM tb_container_meta WHERE key=?1", [&key], |r| r.get(0)).unwrap();
            assert_eq!(retained, forged);
        }
    }

    #[test]
    fn legacy_unjournaled_failed_import_rejects_changed_source_instead_of_publishing_stale_rows() {
        let fixture = Fixture::new();
        let db = fixture.path("codex-ledger.sqlite");
        let raw = fixture.path("legacy.sqlite");
        seed_legacy(&raw);
        drop(
            open_store_at(
                &db,
                "quota_history",
                "home",
                "quota",
                std::slice::from_ref(&raw),
                false,
            )
            .unwrap(),
        );
        Container::open_existing(&db)
            .unwrap()
            .connection()
            .execute(
                "DELETE FROM tb_container_meta WHERE key LIKE 'migration_pending_store_v1:%'",
                [],
            )
            .unwrap();
        Connection::open(&raw)
            .unwrap()
            .execute("INSERT INTO events VALUES(2,'new')", [])
            .unwrap();
        assert!(open_store_at(
            &db,
            "quota_history",
            "home",
            "quota",
            std::slice::from_ref(&raw),
            false
        )
        .is_err());
        assert!(!initialized_marker_path(&db).exists());
    }

    #[test]
    fn initialized_route_imports_legacy_into_private_store_and_preserves_source() {
        let fixture = Fixture::new();
        let container_path = fixture.path("codex-ledger.sqlite");
        let legacy_path = fixture.path("legacy.sqlite");

        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute_batch("CREATE TABLE events(id INTEGER PRIMARY KEY, value TEXT NOT NULL);")
            .unwrap();
        legacy
            .execute("INSERT INTO events VALUES (17, 'preserved')", [])
            .unwrap();
        drop(legacy);

        // This follows the controlled first-install path. The assertion below
        // exercises the same initialized-only route used by ordinary writers.
        Container::open(&container_path).unwrap();
        fs::write(
            initialized_marker_path(&container_path),
            b"tokenbar-codex-ledger-v1\n",
        )
        .unwrap();

        let connection = open_store_at(
            &container_path,
            "quota_history",
            "fixture-home",
            "quota/history.sqlite",
            std::slice::from_ref(&legacy_path),
            true,
        )
        .unwrap();
        let imported: String = connection
            .query_row("SELECT value FROM events WHERE id=17", [], |row| row.get(0))
            .unwrap();
        assert_eq!(imported, "preserved");
        drop(connection);

        let legacy =
            Connection::open_with_flags(&legacy_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let retained: String = legacy
            .query_row("SELECT value FROM events WHERE id=17", [], |row| row.get(0))
            .unwrap();
        assert_eq!(retained, "preserved");
        drop(legacy);

        // A hot open follows its durable receipt and does not rescan or
        // re-import the retired source bytes.
        let legacy = Connection::open(&legacy_path).unwrap();
        legacy
            .execute(
                "UPDATE events SET value='changed after import' WHERE id=17",
                [],
            )
            .unwrap();
        drop(legacy);
        let connection = open_store_at(
            &container_path,
            "quota_history",
            "fixture-home",
            "quota/history.sqlite",
            std::slice::from_ref(&legacy_path),
            true,
        )
        .unwrap();
        let imported_again: String = connection
            .query_row("SELECT value FROM events WHERE id=17", [], |row| row.get(0))
            .unwrap();
        assert_eq!(imported_again, "preserved");
        drop(connection);

        fs::remove_file(&legacy_path).unwrap();
        let connection = open_registered_store_at(
            &container_path,
            "quota_history",
            "fixture-home",
            "quota/history.sqlite",
        )
        .unwrap()
        .unwrap();
        let after_source_removal: String = connection
            .query_row("SELECT value FROM events WHERE id=17", [], |row| row.get(0))
            .unwrap();
        assert_eq!(after_source_removal, "preserved");
        drop(connection);

        fs::remove_file(initialized_marker_path(&container_path)).unwrap();
        assert!(open_store_at(
            &container_path,
            "quota_history",
            "fixture-home",
            "quota/history.sqlite",
            &[],
            true,
        )
        .is_err());
    }
    fn seed_incident_quota_source(path:&Path) {
        Connection::open(path).unwrap().execute_batch("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,account_key TEXT NOT NULL,used REAL NOT NULL);INSERT INTO quota_snapshots VALUES(1,'account',10),(2,'account',11);CREATE TABLE quota_history_legacy_claims(name TEXT PRIMARY KEY,owner TEXT NOT NULL);INSERT INTO quota_history_legacy_claims VALUES('display','account');CREATE TABLE quota_history_maintenance(key TEXT PRIMARY KEY,value TEXT NOT NULL);INSERT INTO quota_history_maintenance VALUES('policy_version','3'),('last_compacted_at','100')").unwrap();
    }
    #[test]
    fn incident_v1_quota_daily_maintenance_append_interrupt_and_repeated_retry_preserve_history() {
        let fixture=Fixture::new();let db=fixture.path("codex-ledger.sqlite");let source=fixture.path("quota-history.sqlite");seed_incident_quota_source(&source);
        let inputs=std::slice::from_ref(&source);
        assert!(open_store_at_with_hook(&db,"quota_history_legacy","home","quota",inputs,false,&||Err("interrupted".into())).is_err());
        let store=StoreSpec::new("quota_history_legacy","home","quota").unwrap();
        let a=Container::open_existing(&db).unwrap();let receipt=a.legacy_input_receipt(&source).unwrap().unwrap();let frozen=fs::read(&receipt.backup_path).unwrap();
        let journal=serde_json::json!({"sources":inputs,"bootstrap":true,"replace_uncommitted":true});
        a.connection().execute("UPDATE tb_container_meta SET value=?1 WHERE key=?2",params![journal.to_string(),format!("migration_pending_store_v1:{}",store.id)]).unwrap();drop(a);
        Connection::open(&source).unwrap().execute_batch("INSERT INTO quota_snapshots VALUES(3,'account',12);UPDATE quota_history_maintenance SET value='200' WHERE key='last_compacted_at'").unwrap();let original=fs::read(&source).unwrap();
        assert!(open_store_at_with_hook(&db,"quota_history_legacy","home","quota",inputs,false,&||Err("interrupted again".into())).is_err());
        for _ in 0..3 {
            let ready=open_store_at(&db,"quota_history_legacy","home","quota",inputs,false).unwrap();
            assert_eq!(ready.query_row("SELECT count(*),sum(used) FROM quota_snapshots",[],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,f64>(1)?))).unwrap(),(3,33.0));
        }
        assert_eq!(fs::read(&source).unwrap(),original);assert_eq!(fs::read(&receipt.backup_path).unwrap(),frozen);
        assert!(!initialized_marker_path(&db).exists(),"Module recovery must not prematurely publish global readiness");
    }
    #[test]
    fn incident_quota_recovery_never_overwrites_independent_partial_destination_rows() {
        let fixture=Fixture::new();let db=fixture.path("codex-ledger.sqlite");let source=fixture.path("quota-history.sqlite");seed_incident_quota_source(&source);let inputs=std::slice::from_ref(&source);
        assert!(open_store_at_with_hook(&db,"quota_history_legacy","home","quota",inputs,false,&||Err("interrupted".into())).is_err());
        let active=open_store_at(&db,"quota_history_legacy","home","quota",inputs,false).unwrap();active.execute("INSERT INTO quota_snapshots VALUES(999,'independent',334108)",[]).unwrap();drop(active);
        let store=StoreSpec::new("quota_history_legacy","home","quota").unwrap();let before=Container::open_existing(&db).unwrap().proof(&store).unwrap();
        Connection::open(&source).unwrap().execute_batch("INSERT INTO quota_snapshots VALUES(3,'account',12);UPDATE quota_history_maintenance SET value='200' WHERE key='last_compacted_at'").unwrap();
        let error=match open_store_at(&db,"quota_history_legacy","home","quota",inputs,false){Ok(_)=>panic!("Independent destination was overwritten"),Err(e)=>e};assert!(error.contains("目标已有独立账目变化"),"{error}");
        assert_eq!(Container::open_existing(&db).unwrap().proof(&store).unwrap(),before);assert!(!initialized_marker_path(&db).exists());
    }

}
