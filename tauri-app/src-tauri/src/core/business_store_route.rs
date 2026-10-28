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
    let mut snapshots = Vec::new();
    let mut saw_retired_input = false;
    for legacy_path in legacy_sources {
        if !legacy_path.is_file() {
            continue;
        }
        if let Some(receipt) = container
            .legacy_input_receipt(legacy_path)
            .map_err(|error| error.to_string())?
        {
            if receipt.retired {
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
                // The source was already snapshotted and imported. Its bytes
                // are no longer part of normal connection establishment.
                continue;
            }
            return Err(format!(
                "旧业务数据库来源已属于另一隔离分区：{}",
                legacy_path.display()
            ));
        }
        let source_digest =
            Container::snapshot_digest_path(legacy_path).map_err(|error| error.to_string())?;
        let backup_path = backup_path(&container_path, &store, legacy_path, &source_digest);
        if !backup_path.is_file() {
            Container::backup_snapshot(legacy_path, &backup_path)
                .map_err(|error| error.to_string())?;
        }
        let backup_digest =
            Container::snapshot_digest_path(&backup_path).map_err(|error| error.to_string())?;
        if backup_digest != source_digest {
            return Err(format!(
                "旧业务数据库在生成快照期间变化，拒绝导入：{}",
                legacy_path.display()
            ));
        }
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
    if has_objects {
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

fn bootstrap_legacy_stores() -> Result<(), String> {
    for path in [
        app_paths::quota_history_database_path(),
        app_paths::legacy_shared_quota_history_database_path(),
    ]
    .into_iter()
    .flatten()
    .filter(|path| path.is_file())
    {
        let identity = source_identity("quota_history_legacy", &path)?;
        let logical_path = format!("legacy/quota-history/{identity}");
        let _ =
            open_store_during_bootstrap("quota_history_legacy", &identity, &logical_path, &[path])?;
    }
    if let Some(path) = app_paths::modeltrace_database_path().filter(|path| path.is_file()) {
        let identity = source_identity("modeltrace_legacy", &path)?;
        let logical_path = format!("legacy/modeltrace/{identity}");
        let _ =
            open_store_during_bootstrap("modeltrace_legacy", &identity, &logical_path, &[path])?;
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
    container_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("codex-ledger-snapshots")
        .join(format!("{}-{source_hash}-{digest_hash}.sqlite", store.id))
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
