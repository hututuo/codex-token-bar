//! Exact namespace ownership, candidates, receipts and A storage bridges.
//!
//! Existing-owner resolution reuses its caller's admitted handle/snapshot;
//! public open/import/clone/replace/seal calls retain their original admission
//! and I/O. Ownership resolution is not permission to bypass runtime fences.
//! Journal recovery belongs to import_coordinator; physical identity admission
//! remains owned by admission and is never cached anew in this module.

use super::admission::{ensure_runtime_business_store_readable, verify_ready_container,
    initialized_marker_path, open_ready_container};
#[cfg(not(test))]
use super::admission::verify_active_container_identity;
use super::import_coordinator::{PendingLegacyImport, legacy_source_exists,
    open_store_at_address_with_hook};
use super::{container_path, path_identity, open_store, now_unix};
use crate::core::business_store_connection::StoreConnection;
use crate::core::business_store_container::{Container, StoreProof, StoreSpec};
use rusqlite::{Connection, OptionalExtension};
use std::path::{Path, PathBuf};

/// Exact resolves historical spellings on the same A connection used for
/// registration/import. It never re-hashes an existing owner's durable ID.
pub(crate) fn open_exact_store(path: &Path, legacy_sources: &[PathBuf]) -> Result<StoreConnection, String> {
    open_exact_store_at(&container_path()?, path, legacy_sources, true)
}

pub(crate) fn open_exact_store_during_bootstrap(path: &Path, legacy_sources: &[PathBuf]) -> Result<StoreConnection, String> {
    open_exact_store_at(&container_path()?, path, legacy_sources, false)
}

pub(super) fn open_exact_store_at(container: &Path, path: &Path, legacy_sources: &[PathBuf], ready: bool) -> Result<StoreConnection, String> {
    let address = path_identity::ExactAddress::new(path)?;
    open_store_at_address_with_hook(container, "exact", &address.preferred.source_identity,
        &address.preferred.logical_path, legacy_sources, ready, Some(&address), &|| Ok(()))
}

pub(crate) fn open_exact_registered_read_only(path: &Path, timeout: std::time::Duration) -> Result<Option<StoreConnection>, String> {
    ensure_runtime_business_store_readable()?;
    open_exact_registered_read_only_at(&container_path()?, path, timeout)
}

pub(super) fn open_exact_registered_read_only_at(container_path: &Path, path: &Path, timeout: std::time::Duration) -> Result<Option<StoreConnection>, String> {
    verify_ready_container(container_path)?;
    let container = Container::open_read_only_existing(container_path, timeout).map_err(|error| error.to_string())?;
    #[cfg(not(test))]
    verify_active_container_identity(container_path)?;
    let Some(store) = path_identity::ExactAddress::new(path)?.resolve(container.connection(), false)? else {
        return Ok(None);
    };
    let pending: Option<String> = container.connection().query_row(
        "SELECT value FROM tb_container_meta WHERE key=?1",
        [format!("migration_pending_store_v1:{}", store.id)], |row| row.get(0),
    ).optional().map_err(|error| error.to_string())?;
    if let Some(json) = pending {
        let batch: PendingLegacyImport = serde_json::from_str(&json).map_err(|error| format!("未完成导入记录无效：{error}"))?;
        // The initialized marker is the commit point for retained bootstrap
        // journals. A later, uncommitted owner must not look like empty history
        // or leak its partially imported replacement through a reader.
        if ![1, 2].contains(&batch.version) || !batch.bootstrap {
            return Err("该来源的旧账恢复尚未完成，已保留其他已发布统计".into());
        }
    }
    container.into_store_connection(&store).map(Some).map_err(|error| error.to_string())
}

fn resolve_exact_store_spec_on(connection: &Connection, path: &Path, writing: bool) -> Result<StoreSpec, String> {
    let address = path_identity::ExactAddress::new(path)?;
    Ok(address.resolve(connection, writing)?.unwrap_or(address.preferred))
}


pub(crate) fn exact_store_spec(path: &Path) -> Result<StoreSpec, String> {
    Ok(path_identity::ExactAddress::new(path)?.preferred)
}

/// "Pure owner lookup" means no registration or writer admission; this still
/// probes filesystem metadata, opens a read-only A connection and queries it.
/// The writing flag controls ownership resolution, not runtime readiness.
pub(crate) fn existing_exact_store_spec(path: &Path, writing: bool) -> Result<StoreSpec, String> {
    let container_path = container_path()?;
    match std::fs::symlink_metadata(&container_path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return exact_store_spec(path),
        Err(error) => return Err(format!("无法核对 Exact 所有者，未创建任何分区：{error}")),
        Ok(metadata) if !metadata.file_type().is_file() => return Err("业务库 A 不是普通文件".into()),
        Ok(_) => {}
    }
    // This is a pure owner lookup, also used before bootstrap activation. Its
    // caller still owns admission; this helper cannot register or open a writer.
    let container = Container::open_read_only_existing(&container_path, std::time::Duration::from_secs(30))
        .map_err(|error| error.to_string())?;
    resolve_exact_store_spec_on(container.connection(), path, writing)
}

/// Pure owner resolution on an already admitted A handle. Revalidate root
/// versions and all historical aliases in one short read snapshot; a warm
/// SQLite schema is reusable, but an earlier owner decision is not.
pub(crate) fn existing_exact_store_spec_on(
    connection: &Connection, path: &Path, writing: bool,
) -> Result<StoreSpec, String> {
    let resolve = |connection: &Connection| {
        Container::validate_version_on(connection).map_err(|error| error.to_string())?;
        resolve_exact_store_spec_on(connection, path, writing)
    };
    if connection.is_autocommit() {
        let snapshot = connection.unchecked_transaction().map_err(|error| error.to_string())?;
        let result = resolve(&snapshot)?;
        snapshot.commit().map_err(|error| error.to_string())?;
        Ok(result)
    } else {
        resolve(connection)
    }
}

pub(crate) fn exact_stage_candidates(index: &Path, source_digest: &str) -> Result<Vec<PathBuf>, String> {
    let container = open_ready_container(&container_path()?)?;
    exact_stage_candidates_on(container.connection(), index, source_digest)
}

/// Use the already fenced A owner connection during one backfill. Opening and
/// validating the whole large SQLite catalog for every source is unnecessary.
pub(crate) fn exact_stage_candidates_on(connection: &Connection, index: &Path, source_digest: &str) -> Result<Vec<PathBuf>, String> {
    if source_digest.len()!=64 || !source_digest.bytes().all(|byte|byte.is_ascii_hexdigit()) {
        return Err("暂存来源摘要无效".into());
    }
    let families = path_identity::candidate_families(index)?;
    let mut paths = Vec::new();
    for family in families {
    let prefix = format!("exact/staging/{family}/{source_digest}.candidate-v2-");
    let upper = format!("exact/staging/{family}/{source_digest}.candidate-v2.");
    let mut statement = connection.prepare(
        "SELECT logical_path,source_identity FROM tb_stores \
         WHERE module='exact' AND state IN ('ready','sealed') AND logical_path>=?1 AND logical_path<?2"
    ).map_err(|error| error.to_string())?;
    let entries = statement.query_map(rusqlite::params![prefix, upper], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }).map_err(|error| error.to_string())?;
    let mut directory = index.as_os_str().to_os_string();
    directory.push(".staging");
    let directory = PathBuf::from(directory);
    for entry in entries {
        let (logical, identity) = entry.map_err(|error| error.to_string())?;
        let name = logical.rsplit('/').next().ok_or("暂存候选缺少目录项")?;
        let path = directory.join(name);
        if !path_identity::ExactAddress::new(&path)?.registered(connection)?.iter()
            .any(|store| store.logical_path == logical && store.source_identity == identity) {
            return Err("暂存候选目录与业务分区身份不一致；已保留候选".into());
        }
        paths.push(path);
    }
    }
    paths.sort(); paths.dedup();
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
    let store = resolve_exact_store_spec_on(container.connection(), target, false)?;
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

pub(super) const LEGACY_EXACT_MIGRATION_KEY: &str = "legacy_exact_migration_v1:";

/// Bootstrap alone owns this receipt. It distinguishes immutable physical
/// legacy artifacts from the A-owned schema migration of the imported rows.
pub(crate) fn preserve_legacy_exact_migration(
    path: &Path,
    manifests: &[(PathBuf, String)],
) -> Result<(), String> {
    let store = existing_exact_store_spec(path, true)?;
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
    let container = open_ready_container(&container_path()?)?;
    let store = resolve_exact_store_spec_on(container.connection(), path, false)?;
    validate_legacy_exact_migration_receipt(&container, &store)
}

/// The caller owns an admitted connection and a read snapshot covering both
/// the owner and receipt. Reuse SQLite's schema, never a prior owner decision.
pub(crate) fn preserves_legacy_exact_migration_on(
    connection: &Connection, path: &Path, expected_owner: &StoreSpec,
) -> Result<bool, String> {
    Container::validate_version_on(connection).map_err(|error| error.to_string())?;
    let store = resolve_exact_store_spec_on(connection, path, false)?;
    if &store != expected_owner {
        return Err("迁移保留凭据与当前 Exact 连接所有者不匹配".into());
    }
    validate_legacy_exact_migration_receipt_on(connection, &store)
}

/// Registration alone is insufficient: a physical legacy candidate must not
/// become a resumable A candidate simply because somebody opened its path.
pub(crate) fn owns_exact_migration_artifact(path: &Path) -> Result<bool, String> {
    let container = open_ready_container(&container_path()?)?;
    let store = resolve_exact_store_spec_on(container.connection(), path, false)?;
    Ok(container.is_registered(&store).map_err(|e| e.to_string())?
        && container.has_imported_objects(&store).map_err(|e| e.to_string())?
        && container.legacy_input_receipt(path).map_err(|e| e.to_string())?.is_none())
}

pub(crate) fn exact_store_has_objects(path: &Path) -> Result<bool, String> {
    let container = open_ready_container(&container_path()?)?;
    let store = resolve_exact_store_spec_on(container.connection(), path, false)?;
    Ok(container.is_registered(&store).map_err(|e| e.to_string())?
        && container.has_imported_objects(&store).map_err(|e| e.to_string())?)
}

pub(super) fn validate_legacy_exact_migration_receipt(container: &Container, store: &StoreSpec) -> Result<bool, String> {
    validate_legacy_exact_migration_receipt_on(container.connection(), store)
}

fn validate_legacy_exact_migration_receipt_on(connection: &Connection, store: &StoreSpec) -> Result<bool, String> {
    let raw: Option<String> = connection.query_row(
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
    let store = existing_exact_store_spec(path, true)?;
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
    let source = existing_exact_store_spec(source_path, true)?;
    let target = existing_exact_store_spec(target_path, true)?;
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
    let mut container = open_ready_container(&container_path)?;
    let store = resolve_exact_store_spec_on(container.connection(), path, true)?;
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
    let store = existing_exact_store_spec(path, true)?;
    open_ready_container(&container_path()?)?
        .seal_store(&store, now_unix())
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub(crate) fn exact_store_observation(
    path: &Path,
) -> Result<Option<(u64, i64, String, f64)>, String> {
    let store = existing_exact_store_spec(path, true)?;
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
    let store = existing_exact_store_spec(path, true)?;
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
