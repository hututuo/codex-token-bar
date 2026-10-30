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
    sources: Vec<PathBuf>,
    bootstrap: bool,
    #[serde(default)]
    replace_uncommitted: bool,
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
        for source in &pending.sources {
            let receipt = container
                .legacy_input_receipt(source)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("未完成导入缺少来源收据：{}", source.display()))?;
            if receipt.retired
                || key != format!("migration_pending_store_v1:{}", receipt.store_id)
                || Container::snapshot_digest_path(source).map_err(|error| error.to_string())?
                    != receipt.source_digest
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
    if let Some(batch) = &pending {
        for source in &batch.sources {
            if !legacy_sources.contains(source) || !legacy_source_exists(source)? {
                return Err(format!(
                    "未完成导入的来源已移走或不可用，保留候选账本：{}",
                    source.display()
                ));
            }
        }
    }
    let mut snapshots = Vec::new();
    let mut saw_retired_input = false;
    for legacy_path in legacy_sources {
        if !legacy_source_exists(legacy_path)? {
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
        snapshots.push((legacy_path.clone(), backup_path, source_digest));
    }
    if has_objects && snapshots.is_empty() {
        return container
            .into_store_connection(&store)
            .map_err(|error| error.to_string());
    }
    if let Some((_, _, first_digest)) = snapshots.first() {
        if snapshots
            .iter()
            .any(|(_, _, digest)| digest != first_digest)
        {
            return Err(format!(
                "同一业务分区存在内容不同的旧库候选；保留所有来源并拒绝切换：{logical_path}"
            ));
        }
    }
    // A journal is written BEFORE the first namespace replacement. Only a
    // journaled, never-activated import may be replaced during recovery.
    if !snapshots.is_empty() {
        let batch = PendingLegacyImport {
            sources: snapshots
                .iter()
                .map(|(source, _, _)| source.clone())
                .collect(),
            bootstrap: !globally_initialized,
            replace_uncommitted: pending
                .as_ref()
                .map_or(!has_objects, |batch| batch.replace_uncommitted),
        };
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
        let (_, backup, _) = &snapshots[0];
        container
            .import_snapshot(backup, &store, backup, now_unix(), true)
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
        for (source_path, backup_path, _) in &snapshots {
            container
                .record_identical_legacy_input(
                    backup_path,
                    &store,
                    source_path,
                    backup_path,
                    now_unix(),
                )
                .map_err(|error| error.to_string())?;
        }
    } else if has_objects {
        for (source_path, backup_path, _) in &snapshots {
            container
                .record_identical_legacy_input(
                    backup_path,
                    &store,
                    source_path,
                    backup_path,
                    now_unix(),
                )
                .map_err(|error| error.to_string())?;
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
            for (source_path, backup_path, _) in &snapshots {
                container
                    .record_identical_legacy_input(
                        backup_path,
                        &store,
                        source_path,
                        backup_path,
                        now_unix(),
                    )
                    .map_err(|error| error.to_string())?;
            }
        } else if !snapshots.is_empty() || saw_retired_input {
            return Err(format!(
                "旧业务库候选已退役且未变化；拒绝以空分区继续：{logical_path}"
            ));
        }
    }

    after_import()?;
    for (source_path, _, digest) in &snapshots {
        if Container::snapshot_digest_path(source_path).map_err(|error| error.to_string())?
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
    let identity = source_identity("exact", path)?;
    StoreSpec::new("exact", identity.clone(), format!("exact/index/{identity}"))
        .map_err(|error| error.to_string())
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
    fn pending_disappeared_source_cannot_be_omitted_by_next_discovery() {
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
        let saved = fixture.path("saved.sqlite");
        fs::rename(&raw, &saved).unwrap();
        assert!(verify_bootstrap_pending_inputs(&Container::open_existing(&db).unwrap()).is_err());
        assert!(open_store_at(&db, "quota_history", "home", "quota", &[], false).is_err());
        fs::rename(&saved, &raw).unwrap();
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
        verify_bootstrap_pending_inputs(&Container::open_existing(&db).unwrap()).unwrap();
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
}
