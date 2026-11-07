//! Source discovery, boundary classification and physical/logical observation.
//!
//! This is an I/O domain, not a pure utility module. Candidate discovery is a
//! non-authoritative hint; read_only_source_probe owns its existing published
//! snapshot and drops it before filesystem discovery. The writer's traversal
//! and sources_changed use the caller's connection-local TEMP queues and protect
//! unavailable roots from becoming deletion tombstones. No new connection or
//! completeness state is introduced by this extraction.
//!
//! File signatures may open rollout readers and resolve logical lengths. Source
//! observations can write metadata on a supplied connection; they do not own
//! publication or change the root operation lease/connection lifetime.

use super::ExactUsageIndex;
use super::connection::{Connection, open_published_index_read_only, open_read_only_source};
use super::contracts::{ExactScanCompleteness, FileSignature, PhysicalFileStamp,
    checked_i64, nonnegative_u64, EVENT_ENRICHMENT_REVISION_KEY, EVENT_ENRICHMENT_REVISION,
    STAGED_FULL_REBUILD_PARSER_REVISION};
use super::store_metadata::{metadata_i64, metadata_text, column_exists_checked};
use super::ingest::prepare_scan_temp_tables;
use super::{database_path, representations, scan_warning};
use super::super::rollout_source::{self, RolloutReader, SourceHandle};
use crate::models::LocalDataWarning;
use rusqlite::{params, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, Instant, SystemTime};

/// Read-only metadata captured by the startup discovery pass.  The durable
/// scanner remains the only writer/authority; this plan is only a same-owner
/// hint that lets a normal scan consume the candidates without immediately
/// walking the same directory tree again.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(in super::super) struct PreciseScanCandidate {
    pub(super) canonical_path: PathBuf,
    pub(super) signature: Option<FileSignature>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DirectorySignature {
    path: PathBuf,
    exists: bool,
    is_directory: bool,
    size: u64,
    modified_ns: u128,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(in super::super) struct PreciseScanDiscovery {
    pub(in super::super) canonical_home: PathBuf,
    pub(in super::super) source_revision: u64,
    pub(in super::super) discovered_at: SystemTime,
    directory_signatures: Vec<DirectorySignature>,
    pub(in super::super) candidates: Vec<PreciseScanCandidate>,
    pub(in super::super) candidate_total: u64,
    pub(super) boundary_warnings: Vec<String>,
    pub(super) unresolved_boundary: bool,
}

impl PreciseScanDiscovery {
    /// The discovery pass is a candidate hint, not an authority.  It remains
    /// usable after a watcher event as long as the canonical Home path is the
    /// same; every candidate is reopened and re-signed by the durable scan.
    pub(in super::super) fn is_usable(&self, codex_home: &Path) -> bool {
        let Ok(canonical_home) = canonical_codex_home(codex_home) else {
            return false;
        };
        if canonical_home != self.canonical_home {
            return false;
        }
        true
    }
}

/// Read-only source-change result for the dashboard cadence. `changed = None`
/// means that discovery could not prove a complete source view; callers must
/// treat that state as unknown and schedule the authoritative precise owner.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(in super::super) struct ReadOnlySourceProbe {
    pub(in super::super) published_generation: u64,
    pub(in super::super) changed: Option<bool>,
}

/// Probes the published generation and file checkpoints without opening the
/// writable exact index. The filesystem side only reads directory entries and
/// file metadata through the existing discovery candidate seam; it never reads
/// JSONL bodies or creates temporary SQLite tables.
pub(in super::super) fn read_only_source_probe(
    codex_home: &Path,
    timeout: StdDuration,
) -> Result<ReadOnlySourceProbe, String> {
    let path = database_path(codex_home)?;
    let connection = open_published_index_read_only(&path, timeout).map_err(|error| {
        format!("无法只读打开精确 token 索引源探针 {}：{error}", path.display())
    })?;
    let Some(connection) = connection else {
        return Ok(ReadOnlySourceProbe {
            published_generation: 0,
            changed: Some(true),
        });
    };
    let connection = connection.unchecked_transaction()
        .map_err(|error| format!("无法开始精确 token 源探针只读快照：{error}"))?;
    let metadata_table_exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'metadata')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法只读检查精确 token 源探针元数据表：{error}"))?;
    if !metadata_table_exists {
        return Ok(ReadOnlySourceProbe {
            published_generation: 0,
            changed: Some(true),
        });
    }
    let published_generation = match metadata_text(&connection, "published_generation")? {
        Some(value) => value.parse::<u64>().map_err(|_| {
            format!("精确 token 源探针已发布代次无效：{value:?}，已拒绝按缺失值覆盖")
        })?,
        None => 0,
    };
    let building_generation = metadata_text(&connection, "building_generation")?;
    let enrichment_complete = metadata_text(&connection, EVENT_ENRICHMENT_REVISION_KEY)?.as_deref()
        == Some(EVENT_ENRICHMENT_REVISION);
    let published_view_exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'view' AND name = 'published_files')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法只读检查精确 token 已发布文件视图：{error}"))?;
    let observations_exist = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_observations')",
        [], |row| row.get::<_, bool>(0)).map_err(|error| error.to_string())?;
    if !published_view_exists || !observations_exist {
        return Ok(ReadOnlySourceProbe {
            published_generation,
            changed: Some(true),
        });
    }

    let mut statement = connection
        .prepare("SELECT f.path, f.size, f.modified_ns, o.physical_stamp FROM published_files f LEFT JOIN source_observations o ON o.path=f.path AND o.size=f.size AND o.modified_ns=f.modified_ns")
        .map_err(|error| format!("无法准备精确 token 源探针文件检查点：{error}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                (
                    nonnegative_u64(row.get::<_, i64>(1)?),
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ),
            ))
        })
        .map_err(|error| format!("无法读取精确 token 源探针文件检查点：{error}"))?;
    let mut published_files = HashMap::new();
    for row in rows {
        let (path, signature) =
            row.map_err(|error| format!("无法解码精确 token 源探针文件检查点：{error}"))?;
        published_files.insert(path, signature);
    }
    drop(statement);

    // Release the consistent DB snapshot before filesystem discovery. The
    // probe's watermark and checkpoints must come from the same publication.
    drop(connection);

    let discovery = match estimate_precise_scan_total_with_known_sources(codex_home, timeout, 0, &published_files) {
        Ok(discovery) => discovery,
        Err(_) => {
            return Ok(ReadOnlySourceProbe {
                published_generation,
                changed: None,
            })
        }
    };
    if discovery.unresolved_boundary {
        return Ok(ReadOnlySourceProbe {
            published_generation,
            changed: None,
        });
    }

    let mut seen = HashSet::with_capacity(discovery.candidates.len());
    let mut changed = building_generation.is_some() || !enrichment_complete;
    for candidate in discovery.candidates {
        let path = candidate.canonical_path.to_string_lossy().into_owned();
        if !seen.insert(path.clone()) {
            continue;
        }
        let unchanged = published_files
            .get(&path)
            .is_some_and(|(size, modified_ns, physical)| {
                candidate.signature.is_some_and(|signature| signature.matches_stored(*size, modified_ns)
                    && signature.matches_physical(physical.as_deref()))
            });
        changed |= !unchanged;
    }
    changed |= published_files.keys().any(|path| !seen.contains(path));
    Ok(ReadOnlySourceProbe {
        published_generation,
        changed: Some(changed),
    })
}

impl ExactUsageIndex {
    pub(in super::super) fn discover_sources(
        &self, codex_home: &Path, timeout: StdDuration, source_revision: u64,
    ) -> Result<PreciseScanDiscovery, String> {
        let known = complete_source_observations(&self.connection)?;
        estimate_precise_scan_total_with_known_sources(codex_home, timeout, source_revision, &known)
    }

    /// Discovery work despite the predicate name: prepares TEMP observations
    /// and traverses sources with the existing writer. This remains in the scan
    /// coordinator, not in the published read-model module.
    pub(in super::super) fn sources_changed(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<bool, String> {
        if metadata_i64(&self.connection, "building_generation")?.is_some() {
            return Ok(true);
        }
        prepare_scan_temp_tables(&self.connection)?;
        self.prepare_source_change_snapshot()?;
        let published_files = self.source_change_snapshot_signatures()?;
        let mut seen_files = HashSet::with_capacity(published_files.len());
        let mut changed = false;
        let mut ignored_scan_completeness = ExactScanCompleteness::default();
        visit_session_files(
            &mut self.connection,
            codex_home,
            warnings,
            &mut ignored_scan_completeness,
            |_connection, file, scan_warnings, scan_completeness| {
                let path = file.to_string_lossy().into_owned();
                if !seen_files.insert(path.clone()) {
                    return Ok(());
                }
                let signature = match lightweight_file_signature(file, published_files.get(&path)) {
                    Ok(Some(signature)) => signature,
                    Ok(None) => { changed = true; return Ok(()); },
                    Err(error) => {
                        // A metadata/permission race is a source change, not
                        // proof that the file disappeared.  Let the durable
                        // scan classify it as incomplete and preserve the
                        // published rows instead of aborting the probe.
                        changed = true;
                        scan_completeness.mark_incomplete();
                        scan_warnings.push(scan_warning(format!(
                            "无法读取会话文件签名，本轮保留已有统计：{}（{}）",
                            file.display(),
                            error
                        )));
                        return Ok(());
                    }
                };
                let unchanged = published_files
                    .get(&path)
                    .is_some_and(|(size, modified_ns, physical)| {
                        signature.matches_stored(*size, modified_ns)
                            && signature.matches_physical(physical.as_deref())
                    });
                changed |= !unchanged;
                Ok(())
            },
        )?;
        let deleted = published_files
            .keys()
            .any(|path| !seen_files.contains(path));
        Ok(changed || deleted || ignored_scan_completeness.incomplete_source_scan)
    }

    pub(super) fn sources_changed_from_discovery(
        &mut self,
        discovery: &PreciseScanDiscovery,
    ) -> Result<bool, String> {
        if metadata_i64(&self.connection, "building_generation")?.is_some() {
            return Ok(true);
        }
        if discovery.unresolved_boundary {
            return Ok(true);
        }
        prepare_scan_temp_tables(&self.connection)?;
        self.prepare_source_change_snapshot()?;
        let published_files = self.source_change_snapshot_signatures()?;
        let mut seen = HashSet::with_capacity(discovery.candidates.len());
        let mut changed = false;
        for candidate in &discovery.candidates {
            let path = candidate.canonical_path.to_string_lossy().into_owned();
            if !seen.insert(path.clone()) {
                continue;
            }
            let unchanged = published_files
                .get(&path)
                .is_some_and(|(size, modified_ns, physical)| {
                    candidate.signature.is_some_and(|signature| signature.matches_stored(*size, modified_ns)
                        && signature.matches_physical(physical.as_deref()))
                });
            changed |= !unchanged;
        }
        let deleted = published_files.keys().any(|path| !seen.contains(path));
        Ok(changed || deleted)
    }

    fn prepare_source_change_snapshot(&self) -> Result<(), String> {
        self.connection
            .execute_batch(
                r#"
                DROP TABLE IF EXISTS temp.source_change_files_snapshot;
                CREATE TEMP TABLE source_change_files_snapshot AS
                SELECT * FROM main.published_files;
                CREATE UNIQUE INDEX source_change_files_snapshot_path_idx
                    ON source_change_files_snapshot(path);
                "#,
            )
            .map_err(|error| format!("无法建立精确 token 源文件快照：{error}"))
    }

    fn source_change_snapshot_signatures(&self) -> Result<HashMap<String, (u64, String, Option<String>)>, String> {
        let mut statement = self
            .connection
            .prepare("SELECT f.path,f.size,f.modified_ns,o.physical_stamp FROM temp.source_change_files_snapshot f LEFT JOIN source_observations o ON o.path=f.path AND o.size=f.size AND o.modified_ns=f.modified_ns WHERE NOT EXISTS(SELECT 1 FROM usage_ledger_sources l WHERE l.source_id=f.source_id AND l.missing=1)")
            .map_err(|error| format!("无法读取精确 token 源文件快照：{error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    (
                        nonnegative_u64(row.get::<_, i64>(1)?),
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ),
                ))
            })
            .map_err(|error| format!("无法遍历精确 token 源文件快照：{error}"))?;
        let mut signatures = HashMap::new();
        for row in rows {
            let (path, signature) =
                row.map_err(|error| format!("无法解析精确 token 源文件快照：{error}"))?;
            signatures.insert(path, signature);
        }
        Ok(signatures)
    }

}

pub(super) fn visit_session_files(
    connection: &mut Connection,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    mut visit: impl FnMut(
        &mut Connection,
        &Path,
        &mut Vec<LocalDataWarning>,
        &mut ExactScanCompleteness,
    ) -> Result<(), String>,
) -> Result<(), String> {
    super::record_dashboard_source_scan_for_testing();
    let canonical_home = canonical_codex_home(codex_home)?;
    let canonical_sessions_root = canonical_home.join("sessions");
    let sessions_root = codex_home.join("sessions");
    let archived_sessions_root = codex_home.join("archived_sessions");
    if sessions_root.exists() || archived_sessions_root.exists() {
        if sessions_root.is_dir() {
            enqueue_directory(
                connection,
                &canonical_home,
                &sessions_root,
                warnings,
                scan_completeness,
            )?;
        } else {
            scan_completeness.block_publish();
            warnings.push(scan_warning(format!(
                "会话目录不存在：{}",
                sessions_root.display()
            )));
            suppress_missing_tombstones_under(connection, &sessions_root)?;
        }
        if archived_sessions_root.exists() {
            enqueue_directory(
                connection,
                &canonical_home,
                &archived_sessions_root,
                warnings,
                scan_completeness,
            )?;
        }
        loop {
            let directory = connection
                .query_row(
                    "SELECT path FROM exact_seen_directories WHERE processed = 0 ORDER BY path LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| format!("无法读取会话目录外存队列：{error}"))?;
            let Some(directory) = directory else {
                break;
            };
            connection
                .execute(
                    "UPDATE exact_seen_directories SET processed = 1 WHERE path = ?1",
                    params![&directory],
                )
                .map_err(|error| format!("无法推进会话目录外存队列：{error}"))?;
            let directory = PathBuf::from(directory);
            // 单个目录/条目不可读属持久性错误，整轮报错会让 building 滞留且每轮
            // 复现。降级为警告并跳过；跳过前把未真正扫描到的已索引路径补进
            // exact_seen_files，抑制 finalize 的删除墓碑（宁可沿用旧统计，不可误删）。
            let entries = match fs::read_dir(&directory) {
                Ok(entries) => entries,
                Err(error) => {
                    if directory == canonical_sessions_root {
                        scan_completeness.block_publish();
                    } else {
                        scan_completeness.mark_incomplete();
                    }
                    warnings.push(scan_warning(format!(
                        "读取会话目录失败，本轮跳过该目录：{}（{}）",
                        directory.display(),
                        error
                    )));
                    suppress_missing_tombstones_under(connection, &directory)?;
                    continue;
                }
            };
            for entry in entries {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(error) => {
                        scan_completeness.mark_incomplete();
                        warnings.push(scan_warning(format!(
                            "读取会话目录项失败，本轮跳过该目录剩余条目：{}（{}）",
                            directory.display(),
                            error
                        )));
                        suppress_missing_tombstones_under(connection, &directory)?;
                        break;
                    }
                };
                let path = entry.path();
                if is_history_repair_workspace(&path) { continue; }
                let metadata = match fs::symlink_metadata(&path) {
                    Ok(metadata) => metadata,
                    Err(error) => {
                        if error.kind() == std::io::ErrorKind::NotFound
                            && rollout_source::confirmed_missing_reference(&path, &canonical_home)
                        { continue; }
                        scan_completeness.mark_incomplete();
                        warnings.push(scan_warning(format!(
                            "读取会话目录项元数据失败，本轮跳过该条目：{}（{}）",
                            path.display(),
                            error
                        )));
                        suppress_missing_tombstones_under(connection, &path)?;
                        continue;
                    }
                };
                if metadata.file_type().is_dir() {
                    enqueue_directory(
                        connection,
                        &canonical_home,
                        &path,
                        warnings,
                        scan_completeness,
                    )?;
                } else if rollout_source::is_rollout(&path)
                {
                    match resolve_file_within_codex_home(
                        &canonical_home,
                        &path,
                        "会话目录",
                        warnings,
                    ) {
                        ResolvedSessionFile::Accepted(file) => {
                            visit(connection, &file, warnings, scan_completeness)?;
                        }
                        ResolvedSessionFile::Rejected | ResolvedSessionFile::Absent => {}
                        ResolvedSessionFile::Unresolved => scan_completeness.mark_incomplete(),
                    }
                }
            }
        }
    } else {
        scan_completeness.block_publish();
        warnings.push(scan_warning(format!(
            "会话目录不存在：{}",
            sessions_root.display()
        )));
        suppress_missing_tombstones_under(connection, &sessions_root)?;
        suppress_missing_tombstones_under(connection, &archived_sessions_root)?;
    }

    visit_active_rollouts(
        connection,
        codex_home,
        &canonical_home,
        warnings,
        scan_completeness,
        visit,
    )
}

/// 把 root（文件或目录）下所有已索引路径补进 exact_seen_files：不可读条目本轮
/// 未真正扫描，finalize_generation 不得把它们当作已删除的会话打墓碑。
fn suppress_missing_tombstones_under(connection: &Connection, root: &Path) -> Result<(), String> {
    let exact = root.to_string_lossy().into_owned();
    // 前缀比较用 substr 而非 LIKE：路径里的 % 与 _ 不能被当作通配符。
    let prefix = format!("{exact}/");
    connection
        .execute(
            r#"
            INSERT OR IGNORE INTO exact_seen_files(path)
            SELECT DISTINCT path FROM files
            WHERE path = ?1 OR substr(path, 1, length(?2)) = ?2
            "#,
            params![exact, prefix],
        )
        .map(|_| ())
        .map_err(|error| format!("无法抑制不可读会话条目的删除墓碑：{error}"))
}

/// Performs a read-only candidate discovery for the progress UI and the
/// immediately following durable scan.
///
/// This deliberately does not open the exact index, touch any temporary scan
/// tables, or participate in generation/fingerprint/tombstone decisions. The
/// durable scanner remains the sole source of truth; this plan may become
/// stale while files are being created, removed, or rewritten. Directory
/// metadata is retained for diagnostics, but never decides whether the
/// durable scanner may consume the candidate list.
pub(in super::super) fn estimate_precise_scan_total(
    codex_home: &Path,
    timeout: StdDuration,
) -> Result<PreciseScanDiscovery, String> {
    estimate_precise_scan_total_with_source_revision(codex_home, timeout, 0)
}

pub(in super::super) fn estimate_precise_scan_total_with_source_revision(
    codex_home: &Path,
    timeout: StdDuration,
    source_revision: u64,
) -> Result<PreciseScanDiscovery, String> {
    estimate_precise_scan_total_with_known_sources(codex_home, timeout, source_revision, &HashMap::new())
}

fn estimate_precise_scan_total_with_known_sources(
    codex_home: &Path,
    timeout: StdDuration,
    source_revision: u64,
    known: &HashMap<String, (u64, String, Option<String>)>,
) -> Result<PreciseScanDiscovery, String> {
    let deadline = Instant::now()
        .checked_add(timeout)
        .unwrap_or_else(Instant::now);
    let canonical_home = canonical_codex_home(codex_home)?;
    let discovered_at = SystemTime::now();
    let mut candidates = HashMap::new();
    let mut directories = HashMap::new();
    let mut boundary_warnings = Vec::new();
    let mut unresolved_boundary = false;
    let state_database = codex_home.join("state_5.sqlite");
    directories.insert(state_database.clone(), directory_signature(&state_database));

    for root_name in ["sessions", "archived_sessions"] {
        let root = codex_home.join(root_name);
        directories.insert(root.clone(), directory_signature(&root));
        if root.is_dir() {
            estimate_session_directory(
                &root,
                &canonical_home,
                &deadline,
                &mut candidates,
                &mut directories,
                &mut boundary_warnings,
                &mut unresolved_boundary,
                known,
            )?;
        }
    }
    estimate_active_rollouts(
        codex_home,
        &canonical_home,
        &deadline,
        &mut candidates,
        &mut directories,
        &mut boundary_warnings,
        &mut unresolved_boundary,
        known,
    )?;

    ensure_estimate_deadline(&deadline)?;
    let mut candidates = candidates
        .into_iter()
        .map(|(canonical_path, signature)| PreciseScanCandidate {
            canonical_path,
            signature,
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| left.canonical_path.cmp(&right.canonical_path));
    let candidate_total = candidates.len() as u64;
    let mut directory_signatures = directories.into_values().collect::<Vec<_>>();
    directory_signatures.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(PreciseScanDiscovery {
        canonical_home,
        source_revision,
        discovered_at,
        directory_signatures,
        candidates,
        candidate_total,
        boundary_warnings,
        unresolved_boundary,
    })
}

fn estimate_session_directory(
    root: &Path,
    canonical_home: &Path,
    deadline: &Instant,
    candidates: &mut HashMap<PathBuf, Option<FileSignature>>,
    directories: &mut HashMap<PathBuf, DirectorySignature>,
    boundary_warnings: &mut Vec<String>,
    unresolved_boundary: &mut bool,
    known: &HashMap<String, (u64, String, Option<String>)>,
) -> Result<(), String> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        ensure_estimate_deadline(deadline)?;
        directories.insert(directory.clone(), directory_signature(&directory));
        let entries = fs::read_dir(&directory).map_err(|error| {
            format!(
                "无法预扫描精确 token 会话目录 {}：{error}",
                directory.display()
            )
        })?;
        for entry in entries {
            ensure_estimate_deadline(deadline)?;
            let entry = entry.map_err(|error| {
                format!(
                    "无法预扫描精确 token 会话目录项 {}：{error}",
                    directory.display()
                )
            })?;
            let path = entry.path();
                if is_history_repair_workspace(&path) { continue; }
            let metadata = match fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(error) => {
                    if error.kind() == std::io::ErrorKind::NotFound
                        && rollout_source::confirmed_missing_reference(&path, canonical_home)
                    { continue; }
                    *unresolved_boundary = true;
                    boundary_warnings.push(format!(
                        "无法读取会话目录项元数据：{}（{}）",
                        path.display(),
                        error
                    ));
                    continue;
                }
            };
            if metadata.file_type().is_dir() {
                pending.push(path);
                continue;
            }
            if !rollout_source::is_rollout(&path)
            {
                continue;
            }
            let canonical = match rollout_source::canonical_logical_path(&path) {
                Ok(canonical) => canonical,
                Err(error) => {
                    if error.kind() == std::io::ErrorKind::NotFound
                        && rollout_source::confirmed_missing_reference(&path, canonical_home)
                    { continue; }
                    *unresolved_boundary = true;
                    boundary_warnings.push(format!(
                        "无法确认会话文件边界：{}（{}）",
                        path.display(),
                        error
                    ));
                    continue;
                }
            };
            if !canonical.starts_with(canonical_home) {
                boundary_warnings.push(format!(
                    "拒绝读取 Codex Home 外的会话文件：{} -> {}",
                    path.display(),
                    canonical.display()
                ));
                continue;
            }
            let metadata = match rollout_source::metadata(&canonical) {
                Ok(metadata) => metadata,
                Err(error) => {
                    if error.kind() == std::io::ErrorKind::NotFound
                        && rollout_source::confirmed_missing_reference(&canonical, canonical_home)
                    { continue; }
                    *unresolved_boundary = true;
                    boundary_warnings.push(format!(
                        "无法读取会话文件元数据：{}（{}）",
                        canonical.display(),
                        error
                    ));
                    continue;
                }
            };
            if !metadata.is_file() {
                boundary_warnings.push(format!("拒绝读取非普通会话文件：{}", canonical.display()));
                continue;
            }
            match lightweight_file_signature(&canonical, known.get(canonical.to_string_lossy().as_ref())) {
                Ok(signature) => {
                    candidates.entry(canonical).or_insert(signature);
                }
                Err(error) => {
                    *unresolved_boundary = true;
                    boundary_warnings.push(error);
                }
            }
        }
    }
    Ok(())
}

fn estimate_active_rollouts(
    codex_home: &Path,
    canonical_home: &Path,
    deadline: &Instant,
    candidates: &mut HashMap<PathBuf, Option<FileSignature>>,
    directories: &mut HashMap<PathBuf, DirectorySignature>,
    boundary_warnings: &mut Vec<String>,
    unresolved_boundary: &mut bool,
    known: &HashMap<String, (u64, String, Option<String>)>,
) -> Result<(), String> {
    ensure_estimate_deadline(deadline)?;
    let database = codex_home.join("state_5.sqlite");
    if !database.is_file() {
        return Ok(());
    }
    let state_connection = open_read_only_source(&database, StdDuration::from_millis(100))
        .map_err(|error| format!("无法预扫描 active rollout：{error}"))?;
    if !column_exists_checked(&state_connection, "threads", "rollout_path")? {
        return Ok(());
    }
    let archived_filter = if column_exists_checked(&state_connection, "threads", "archived")? {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let sql = format!(
        "SELECT rollout_path FROM threads WHERE {archived_filter} AND rollout_path IS NOT NULL AND rollout_path <> ''"
    );
    let mut statement = state_connection
        .prepare(&sql)
        .map_err(|error| format!("无法准备 active rollout 预扫描：{error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法读取 active rollout 预扫描结果：{error}"))?;
    for row in rows {
        ensure_estimate_deadline(deadline)?;
        let raw = row.map_err(|error| format!("无法读取 active rollout 路径：{error}"))?;
        let path = {
            let path = PathBuf::from(raw);
            if path.is_absolute() {
                path
            } else {
                codex_home.join(path)
            }
        };
        if !rollout_source::is_rollout(&path)
        {
            *unresolved_boundary = true;
            boundary_warnings.push(format!(
                "active rollout 路径不是 JSONL，本轮跳过该项：{}（支持 JSONL 或 JSONL.zst）",
                path.display()
            ));
            continue;
        }
        let canonical = match rollout_source::canonical_logical_path(&path) {
            Ok(canonical) => canonical,
            Err(error) => {
                if error.kind() == std::io::ErrorKind::NotFound
                    && rollout_source::confirmed_missing_reference(&path, canonical_home)
                { continue; }
                *unresolved_boundary = true;
                boundary_warnings.push(format!(
                    "无法确认 active rollout 会话文件边界：{}（{}）{}",
                    path.display(), error,
                    super::scan_failure::compressed_twin_hint(&path, canonical_home)
                ));
                continue;
            }
        };
        if !canonical.starts_with(canonical_home) {
            boundary_warnings.push(format!(
                "拒绝读取 Codex Home 外的 active rollout 会话文件：{} -> {}",
                path.display(),
                canonical.display()
            ));
            continue;
        }
        let metadata = match rollout_source::metadata(&canonical) {
            Ok(metadata) => metadata,
            Err(error) => {
                if error.kind() == std::io::ErrorKind::NotFound
                    && rollout_source::confirmed_missing_reference(&canonical, canonical_home)
                { continue; }
                *unresolved_boundary = true;
                boundary_warnings.push(format!(
                    "无法读取 active rollout 会话文件元数据：{}（{}）",
                    canonical.display(),
                    error
                ));
                continue;
            }
        };
        if !metadata.is_file() {
            boundary_warnings.push(format!(
                "拒绝读取非普通 active rollout 会话文件：{}",
                canonical.display()
            ));
            continue;
        }
        if let Some(parent) = canonical.parent() {
            directories.insert(parent.to_path_buf(), directory_signature(parent));
        }
        match lightweight_file_signature(&canonical, known.get(canonical.to_string_lossy().as_ref())) {
            Ok(signature) => {
                candidates.entry(canonical).or_insert(signature);
            }
            Err(error) => {
                *unresolved_boundary = true;
                boundary_warnings.push(error);
            }
        }
    }
    Ok(())
}

fn ensure_estimate_deadline(deadline: &Instant) -> Result<(), String> {
    if Instant::now() >= *deadline {
        Err("精确 token 预扫描超过时间上限".into())
    } else {
        Ok(())
    }

}

fn enqueue_directory(
    connection: &Connection,
    canonical_home: &Path,
    directory: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
) -> Result<(), String> {
    if is_history_repair_workspace(directory) { return Ok(()); }
    let canonical = match fs::canonicalize(directory) {
        Ok(canonical) if canonical.starts_with(canonical_home) => canonical,
        Ok(canonical) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "拒绝读取 Codex Home 外的会话目录：{} -> {}",
                directory.display(),
                canonical.display()
            )));
            return Ok(());
        }
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "无法确认会话目录边界：{}（{}）",
                directory.display(),
                error
            )));
            // 解析失败多为权限类持久错误：真正被删除的目录下一轮不会再被父目录
            // 列出，墓碑只是顺延一轮。先抑制，避免把已发布统计误判为已删除。
            suppress_missing_tombstones_under(connection, directory)?;
            return Ok(());
        }
    };
    connection
        .execute(
            "INSERT OR IGNORE INTO exact_seen_directories(path, processed) VALUES (?1, 0)",
            params![canonical.to_string_lossy().as_ref()],
        )
        .map(|_| ())
        .map_err(|error| format!("无法写入会话目录外存队列：{error}"))
}

fn visit_active_rollouts(
    index_connection: &mut Connection,
    codex_home: &Path,
    canonical_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    mut visit: impl FnMut(
        &mut Connection,
        &Path,
        &mut Vec<LocalDataWarning>,
        &mut ExactScanCompleteness,
    ) -> Result<(), String>,
) -> Result<(), String> {
    let database = codex_home.join("state_5.sqlite");
    if !database.exists() {
        return Ok(());
    }
    let state_connection = match open_read_only_source(&database, StdDuration::from_millis(100)) {
        Ok(connection) => connection,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取 active rollout 索引失败，本轮保留已有统计：{}（{}）",
                database.display(),
                error
            )));
            return Ok(());
        }
    };
    let has_rollout_path = match column_exists_checked(&state_connection, "threads", "rollout_path")
    {
        Ok(value) => value,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取 active rollout 索引结构失败，本轮保留已有统计：{}（{}）",
                database.display(),
                error
            )));
            return Ok(());
        }
    };
    if !has_rollout_path {
        return Ok(());
    }
    let archived_filter = match column_exists_checked(&state_connection, "threads", "archived") {
        Ok(true) => "COALESCE(archived, 0) = 0",
        Ok(false) => "1 = 1",
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取 active rollout 归档字段失败，将保守扫描全部路径：{}（{}）",
                database.display(),
                error
            )));
            "1 = 1"
        }
    };
    let sql = format!(
        "SELECT rollout_path FROM threads WHERE {archived_filter} AND rollout_path IS NOT NULL AND rollout_path <> ''"
    );
    let mut statement = match state_connection.prepare(&sql) {
        Ok(statement) => statement,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "准备 active rollout 路径枚举失败，本轮保留已有统计：{error}"
            )));
            return Ok(());
        }
    };
    let rows = match statement.query_map([], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "开始 active rollout 路径枚举失败，本轮保留已有统计：{error}"
            )));
            return Ok(());
        }
    };
    for row in rows {
        let raw = match row {
            Ok(raw) => raw,
            Err(error) => {
                scan_completeness.mark_incomplete();
                warnings.push(scan_warning(format!(
                    "读取 active rollout 路径项失败，本轮跳过该项：{error}"
                )));
                continue;
            }
        };
        let path = {
            let path = PathBuf::from(raw);
            if path.is_absolute() {
                path
            } else {
                codex_home.join(path)
            }
        };
        if !rollout_source::is_rollout(&path)
        {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "active rollout 路径不是 JSONL，本轮跳过该项：{}（支持 JSONL 或 JSONL.zst）",
                path.display()
            )));
            continue;
        }
        match resolve_file_within_codex_home(canonical_home, &path, "active rollout", warnings) {
            ResolvedSessionFile::Accepted(file) => {
                visit(index_connection, &file, warnings, scan_completeness)?;
            }
            ResolvedSessionFile::Rejected | ResolvedSessionFile::Absent => {}
            ResolvedSessionFile::Unresolved => scan_completeness.mark_incomplete(),
        }
    }
    Ok(())
}

pub(super) fn canonical_codex_home(codex_home: &Path) -> Result<PathBuf, String> {
    fs::canonicalize(codex_home).map_err(|error| {
        format!(
            "无法确认所选 Codex Home 的物理边界：{}（{}）",
            codex_home.display(),
            error
        )
    })
}

pub(super) enum ResolvedSessionFile {
    Accepted(PathBuf),
    /// The target was resolved completely and is intentionally outside the
    /// accepted statistics boundary (for example, an escaping symlink).
    Rejected,
    /// Both plain and compressed entries of this reference are confirmed absent.
    /// The durable ledger remains authoritative; missing text is not zero use.
    Absent,
    /// The target could not be resolved completely, so the source enumeration
    /// is not authoritative and the current generation must not publish.
    Unresolved,
}

pub(super) fn resolve_file_within_codex_home(
    canonical_home: &Path,
    candidate: &Path,
    source: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> ResolvedSessionFile {
    if is_history_repair_workspace(candidate) { return ResolvedSessionFile::Rejected; }

    let canonical = match rollout_source::canonical_logical_path(candidate) {
        Ok(canonical) => canonical,
        Err(error) => {
            if error.kind() == std::io::ErrorKind::NotFound
                && rollout_source::confirmed_missing_reference(candidate, canonical_home)
            { return ResolvedSessionFile::Absent; }
            warnings.push(scan_warning(format!(
                "无法确认 {source} 会话文件边界：{}（{}）{}",
                candidate.display(),
                error,
                super::scan_failure::compressed_twin_hint(candidate, canonical_home)
            )));
            return ResolvedSessionFile::Unresolved;
        }
    };
    if !canonical.starts_with(canonical_home) {
        warnings.push(scan_warning(format!(
            "拒绝读取 Codex Home 外的 {source} 会话文件：{} -> {}",
            candidate.display(),
            canonical.display()
        )));
        return ResolvedSessionFile::Rejected;
    }
    let metadata = match rollout_source::metadata(&canonical) {
        Ok(metadata) => metadata,
        Err(error) => {
            if error.kind() == std::io::ErrorKind::NotFound
                && rollout_source::confirmed_missing_reference(candidate, canonical_home)
            { return ResolvedSessionFile::Absent; }
            warnings.push(scan_warning(format!(
                "无法读取 {source} 会话文件元数据：{}（{}）",
                canonical.display(),
                error
            )));
            return ResolvedSessionFile::Unresolved;
        }
    };
    if !metadata.is_file()
        || !canonical
            .extension()
            .is_some_and(|extension| extension == "jsonl")
    {
        warnings.push(scan_warning(format!(
            "拒绝读取非 JSONL 普通文件：{}",
            canonical.display()
        )));
        return ResolvedSessionFile::Rejected;
    }
    ResolvedSessionFile::Accepted(canonical)
}

pub(super) fn ensure_source_observations(connection: &Connection) -> Result<(), String> {
    let exists = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_observations')",
        [], |row| row.get::<_, bool>(0)).map_err(|error| error.to_string())?;
    if !exists {
        connection.execute_batch("CREATE TABLE source_observations (
            path TEXT PRIMARY KEY, size INTEGER NOT NULL, modified_ns TEXT NOT NULL,
            physical_stamp TEXT NOT NULL) WITHOUT ROWID;")
            .map_err(|error| format!("无法建立源文件元数据观察表：{error}"))?;
    }
    Ok(())
}

pub(super) fn record_source_observation(connection: &Connection, path: &str, signature: FileSignature) -> Result<(), String> {
    if let Some(stamp) = signature.physical {
        connection.execute("INSERT INTO source_observations(path,size,modified_ns,physical_stamp)
            VALUES (?1,?2,?3,?4) ON CONFLICT(path) DO UPDATE SET size=excluded.size,
            modified_ns=excluded.modified_ns,physical_stamp=excluded.physical_stamp
            WHERE size<>excluded.size OR modified_ns<>excluded.modified_ns OR physical_stamp<>excluded.physical_stamp",
            params![path, checked_i64(signature.size, "源文件观察大小")?,
                signature.modified_ns.to_string(), stamp.encode()])
            .map_err(|error| format!("无法保存源文件元数据观察：{error}"))?;
    }
    Ok(())
}

#[cfg(unix)]
pub(super) fn physical_file_stamp(_handle: &fs::File, metadata: &fs::Metadata) -> Result<Option<PhysicalFileStamp>, String> {
    use std::os::unix::fs::MetadataExt;
    Ok(Some(PhysicalFileStamp { volume: metadata.dev(), file_id: metadata.ino(),
        changed_ns: i128::from(metadata.ctime()) * 1_000_000_000 + i128::from(metadata.ctime_nsec()) }))
}

#[cfg(windows)]
pub(super) fn physical_file_stamp(handle: &fs::File, _metadata: &fs::Metadata) -> Result<Option<PhysicalFileStamp>, String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{FileBasicInfo, GetFileInformationByHandle,
        GetFileInformationByHandleEx, BY_HANDLE_FILE_INFORMATION, FILE_BASIC_INFO};
    let mut identity = BY_HANDLE_FILE_INFORMATION::default();
    let mut basic = FILE_BASIC_INFO::default();
    if unsafe { GetFileInformationByHandle(handle.as_raw_handle(), &mut identity) } == 0
        || unsafe { GetFileInformationByHandleEx(handle.as_raw_handle(), FileBasicInfo,
            (&mut basic as *mut FILE_BASIC_INFO).cast(), std::mem::size_of::<FILE_BASIC_INFO>() as u32) } == 0 {
        return Err(format!("读取源文件变化元数据失败：{}", std::io::Error::last_os_error()));
    }
    Ok(Some(PhysicalFileStamp { volume: u64::from(identity.dwVolumeSerialNumber),
        file_id: (u64::from(identity.nFileIndexHigh) << 32) | u64::from(identity.nFileIndexLow),
        changed_ns: i128::from(basic.ChangeTime) * 100 }))
}

#[cfg(not(any(unix, windows)))]
pub(super) fn physical_file_stamp(_handle: &fs::File, _metadata: &fs::Metadata) -> Result<Option<PhysicalFileStamp>, String> { Ok(None) }

/// Opens physical handles before/after observation and may consult cached
/// logical length for compressed input. Unknown length stays unknown; this is
/// not a replacement for the authoritative rollout reader or a pure stat.
pub(super) fn lightweight_file_signature(
    path: &Path, known: Option<&(u64, String, Option<String>)>,
) -> Result<Option<FileSignature>, String> {
    let physical = rollout_source::physical_path(path).map_err(|error| error.to_string())?;
    let handle = fs::File::open(&physical).map_err(|error| error.to_string())?;
    let before = file_signature_from_handle(&handle, path)?;
    let compressed = rollout_source::is_compressed(&physical);
    let logical = if !compressed {
        Some(before.size)
    } else if let Some((size, modified, stamp)) = known.filter(|(_, modified, stamp)| {
        before.physical.is_some() && before.modified_ns.to_string() == *modified && before.matches_physical(stamp.as_deref())
    }) {
        let _ = (modified, stamp);
        Some(*size)
    } else {
        RolloutReader::cached_logical_length(path).map_err(|error| error.to_string())?
    };
    let selected_after = rollout_source::physical_path(path).map_err(|error| error.to_string())?;
    let after_handle = fs::File::open(&selected_after).map_err(|error| error.to_string())?;
    if selected_after != physical || file_signature_from_handle(&handle, path)? != before
        || file_signature_from_handle(&after_handle, path)? != before {
        return Err(format!("会话物理来源在观察期间变化：{}", path.display()));
    }
    Ok(logical.map(|size| FileSignature { size, ..before }))
}

fn complete_source_observations(db: &Connection) -> Result<HashMap<String, (u64, String, Option<String>)>, String> {
    let mut statement = db.prepare(representations::COMPLETE_OBSERVATIONS_SQL).map_err(|error| error.to_string())?;
    let rows = statement.query_map(params![EVENT_ENRICHMENT_REVISION, STAGED_FULL_REBUILD_PARSER_REVISION], |row| {
        Ok((row.get::<_, String>(0)?, (nonnegative_u64(row.get::<_, i64>(1)?), row.get(2)?, row.get(3)?)))
    }).map_err(|error| error.to_string())?;
    rows.collect::<Result<HashMap<_, _>, _>>().map_err(|error| error.to_string())
}

/// Opens the rollout abstraction and requests logical length; compressed input
/// can require reader/length work. This is not the physical-only stat contract.
pub(super) fn file_signature(path: &Path) -> Result<FileSignature, String> {
    let handle = RolloutReader::open(path)
        .map_err(|error| format!("打开会话文件失败：{}（{}）", path.display(), error))?;
    file_signature_from_handle(&handle, path)
}

fn directory_signature(path: &Path) -> DirectorySignature {
    let metadata = fs::symlink_metadata(path).ok();
    let modified_ns = metadata
        .as_ref()
        .and_then(|value| value.modified().ok())
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map_or(0, |value| value.as_nanos());
    DirectorySignature {
        path: path.to_path_buf(),
        exists: metadata.is_some(),
        is_directory: metadata.as_ref().is_some_and(fs::Metadata::is_dir),
        size: metadata.as_ref().map_or(0, fs::Metadata::len),
        modified_ns,
    }
}

/// Reads physical identity and asks SourceHandle for logical length; compressed
/// readers may perform length work. The caller keeps ownership of this handle.
pub(super) fn file_signature_from_handle(handle: &impl SourceHandle, path: &Path) -> Result<FileSignature, String> {
    let metadata = handle.raw_file()
        .metadata()
        .map_err(|error| format!("读取会话文件元数据失败：{}（{}）", path.display(), error))?;
    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let modified_ns = modified
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    Ok(FileSignature {
        size: handle.logical_length().map_err(|error| format!("读取会话逻辑长度失败：{}（{error}）",path.display()))?,
        modified_ns,
        physical: physical_file_stamp(handle.raw_file(), &metadata)?,
    })
}

pub(super) fn is_history_repair_workspace(path: &Path) -> bool {
    path.components().any(|part| part.as_os_str().to_str().is_some_and(|name| name.starts_with(".codex-history-repair-stage.")))
}
