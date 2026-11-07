//! Whole legacy import coordinator for business container A.
//!
//! Journal persistence precedes replacement. Snapshot recovery, final source/
//! destination rechecks under the container's transaction, receipt updates and
//! post-import source checks remain one ordered coordinator. First bootstrap is
//! activated by the root's initialized marker only after every batch succeeds.
//! A late import keeps its original per-store journal completion rule.
//!
//! Validation is effectful here: a bound frozen snapshot can be rebuilt from
//! exactly the same source proof. Do not extract it into a pure predicate or
//! split open_store_at_address_with_hook into independent strategy services.

use super::admission::{ensure_runtime_business_store_ready, initialized_marker_path,
    verify_ready_container};
#[cfg(not(test))]
use super::admission::verify_active_container_identity;
use super::{container_path, path_identity, source_identity, open_store_during_bootstrap,
    now_unix, hex_digest};
use crate::core::app_paths;
use crate::core::business_store_connection::StoreConnection;
use crate::core::business_store_container::{Container, StoreSpec};
use rusqlite::OptionalExtension;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

pub(super) fn open_store_inner(
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

pub(super) fn open_store_at(
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
pub(super) struct PendingLegacyImport {
    #[serde(default = "legacy_journal_version")]
    pub(super) version: u32,
    pub(super) sources: Vec<PathBuf>,
    #[serde(default)]
    pub(super) snapshots: Vec<PendingSnapshot>,
    pub(super) bootstrap: bool,
    #[serde(default)]
    pub(super) replace_uncommitted: bool,
}

fn legacy_journal_version() -> u32 { 1 }

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct PendingSnapshot {
    pub(super) source: PathBuf,
    pub(super) backup: PathBuf,
    pub(super) digest: String,
}

/// Historical name: this may REBUILD the app-owned frozen backup from a source
/// with exactly the journal's recorded proof. The backup helper may preserve an
/// invalid prior image and write a replacement. Keep this under import recovery,
/// before journal/activation decisions; it is not a pure validation predicate.
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

/// Also performs each snapshot's allowed recovery via validate_pending_snapshot;
/// callers must not treat batch validation as read-only or move it past activation.
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
pub(super) fn resume_pending_bootstrap_imports(path: &Path) -> Result<(), String> {
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
/// Despite "verify", batch validation can rebuild a bound frozen backup.
/// The root calls this before fsync and initialized-marker publication.
pub(super) fn verify_bootstrap_pending_inputs(container: &Container) -> Result<(), String> {
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
pub(super) fn open_store_at_with_hook(
    container_path: &Path,
    module: &str,
    source_identity: &str,
    logical_path: &str,
    legacy_sources: &[PathBuf],
    require_initialized: bool,
    after_import: &dyn Fn() -> Result<(), String>,
) -> Result<StoreConnection, String> {
    open_store_at_address_with_hook(container_path, module, source_identity, logical_path,
        legacy_sources, require_initialized, None, after_import)
}

/// Whole coordinator: retain journal-before-replacement, the container API's
/// transaction-time source/destination proof rechecks, after_import callback,
/// final source checks and marker-versus-late-journal activation semantics.
pub(super) fn open_store_at_address_with_hook(
    container_path: &Path,
    module: &str,
    source_identity: &str,
    logical_path: &str,
    legacy_sources: &[PathBuf],
    require_initialized: bool,
    exact_address: Option<&path_identity::ExactAddress>,
    after_import: &dyn Fn() -> Result<(), String>,
) -> Result<StoreConnection, String> {
    if require_initialized {
        ensure_runtime_business_store_ready()?;
        verify_ready_container(container_path)?;
    }
    let mut container = if require_initialized {
        Container::open_existing(&container_path).map_err(|error| error.to_string())?
    } else {
        Container::open(&container_path).map_err(|error| error.to_string())?
    };
    if require_initialized {
        #[cfg(not(test))]
        verify_active_container_identity(container_path)?;
    }
    let store = match exact_address {
        Some(address) => address.resolve(container.connection(), true)?.unwrap_or_else(|| address.preferred.clone()),
        None => StoreSpec::new(module, source_identity, logical_path).map_err(|error| error.to_string())?,
    };
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

/// Metadata failure is not evidence of absence. File symlinks are unsupported
/// legacy inputs; configured support-directory symlinks retain normal OS traversal.
pub(super) fn legacy_source_exists(path: &Path) -> Result<bool, String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => Ok(true),
        Ok(_) => Err(format!("旧业务数据库不是普通文件；拒绝切换：{}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("无法检查旧业务数据库 {}：{error}", path.display())),
    }
}

pub(super) fn bootstrap_legacy_stores() -> Result<(), String> {
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

pub(super) fn backup_path(
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
