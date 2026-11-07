//! Incremental session directory snapshots and catalog schema compatibility.
//!
//! Refresh and snapshot borrow the existing managed connection. The outer
//! caller retains its Home/build locks and fallback-to-published policy; this
//! module retains the original read-before-write and atomic publication order.

use super::{file_signature_from_handle, is_history_repair_workspace,
    reject_session_catalog_reparse_point, rollout_source, IndexedSessionCatalogEntry,
    IndexedSessionCatalogSnapshot, IndexedSessionMetadata};
use super::connection::{Connection, ManagedIndexConnection};
use super::contracts::{checked_i64, SESSION_CATALOG_SCHEMA_COLUMNS, SESSION_CATALOG_SCHEMA_VERSION};
use super::store_metadata::{column_exists_checked, metadata_i64, metadata_text, set_metadata, table_row_count};
use rusqlite::{params, TransactionBehavior};
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::cell::Cell;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Clone, Debug)]
struct StoredSessionCatalogEntry {
    entry: IndexedSessionCatalogEntry,
    modified_ns: String,
    created_ns: String,
    first_line_bytes: u64,
    first_line_sha256: [u8; 32],
    last_seen_generation: i64,
}

#[derive(Clone, Debug)]
struct SessionCatalogObservation {
    path: PathBuf,
    archived: bool,
    size: u64,
    modified_ns: String,
    created_ns: String,
    modified_at: Option<i64>,
    created_at: Option<i64>,
}

#[cfg(test)]
thread_local! {
    static FAIL_NEXT_SESSION_CATALOG_PUBLISH: Cell<bool> = const { Cell::new(false) };
}

pub(super) fn refresh<F>(
    connection: &mut ManagedIndexConnection,
    codex_home: &Path,
    mut parser: F,
) -> Result<(), String>
where
    F: FnMut(&[u8]) -> Result<IndexedSessionMetadata, String>,
{
    connection.mark_receipt_dirty();
    let existing = load_stored_session_catalog(connection)?;
    let observations = collect_session_catalog_observations(codex_home)?;
    let published_generation =
        metadata_i64(connection, "session_catalog_published_generation")?.unwrap_or(0);
    let generation = published_generation
        .checked_add(1)
        .ok_or_else(|| "会话目录索引代次溢出".to_string())?;
    let mut entries = Vec::with_capacity(observations.len());
    let mut catalog_changed = observations.len() != existing.len();
    for observation in observations {
        let previous = existing.get(&observation.path);
        let entry = if previous
            .is_some_and(|entry| session_catalog_observation_matches(entry, &observation))
        {
            let mut entry = previous
                .cloned()
                .expect("checked existing session catalog entry");
            entry.entry.archived = observation.archived;
            entry.last_seen_generation = generation;
            entry
        } else {
            catalog_changed = true;
            refresh_session_catalog_entry(observation, previous, generation, &mut parser)?
        };
        entries.push(entry);
    }
    if !catalog_changed {
        connection.mark_receipt_eligible();
        return Ok(());
    }

    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始会话目录索引发布事务：{error}"))?;
    for entry in &entries {
        transaction
            .execute(
                r#"
                    INSERT INTO session_catalog_files (
                        path, archived, thread_id, cwd, source, session_id,
                        forked_from_id, parent_thread_id, size, modified_ns,
                        created_ns, modified_at, created_at,
                        first_line_bytes, first_line_sha256,
                        last_seen_generation
                    ) VALUES (
                        ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                        ?12, ?13, ?14, ?15, ?16
                    )
                    ON CONFLICT(path) DO UPDATE SET
                        archived = excluded.archived,
                        thread_id = excluded.thread_id,
                        cwd = excluded.cwd,
                        source = excluded.source,
                        session_id = excluded.session_id,
                        forked_from_id = excluded.forked_from_id,
                        parent_thread_id = excluded.parent_thread_id,
                        size = excluded.size,
                        modified_ns = excluded.modified_ns,
                        created_ns = excluded.created_ns,
                        modified_at = excluded.modified_at,
                        created_at = excluded.created_at,
                        first_line_bytes = excluded.first_line_bytes,
                        first_line_sha256 = excluded.first_line_sha256,
                        last_seen_generation = excluded.last_seen_generation
                    "#,
                params![
                    entry.entry.path.to_string_lossy(),
                    i64::from(entry.entry.archived),
                    entry.entry.metadata.thread_id,
                    entry.entry.metadata.cwd,
                    entry.entry.metadata.source,
                    entry.entry.metadata.session_id,
                    entry.entry.metadata.forked_from_id,
                    entry.entry.metadata.parent_thread_id,
                    checked_i64(entry.entry.size, "会话目录文件大小")?,
                    entry.modified_ns,
                    entry.created_ns,
                    entry.entry.modified_at,
                    entry.entry.created_at,
                    checked_i64(entry.first_line_bytes, "会话目录首行长度")?,
                    entry.first_line_sha256.as_slice(),
                    entry.last_seen_generation,
                ],
            )
            .map_err(|error| {
                format!(
                    "无法写入会话目录索引 {}：{error}",
                    entry.entry.path.display()
                )
            })?;
    }
    transaction
        .execute(
            "DELETE FROM session_catalog_files WHERE last_seen_generation <> ?1",
            [generation],
        )
        .map_err(|error| format!("无法清理会话目录索引中的已删除文件：{error}"))?;
    run_before_session_catalog_publish_hook_for_testing()?;
    set_metadata(
        &transaction,
        "session_catalog_published_generation",
        &generation.to_string(),
    )?;
    transaction
        .commit()
        .map_err(|error| format!("无法原子发布会话目录索引：{error}"))?;
    connection.mark_receipt_eligible();
    Ok(())
}

pub(super) fn snapshot(connection: &ManagedIndexConnection) -> Result<IndexedSessionCatalogSnapshot, String> {
    let transaction = connection.unchecked_transaction().map_err(|error| error.to_string())?;
    let mut entries: Vec<_> = load_stored_session_catalog(connection)?
        .into_values()
        .map(|entry| entry.entry)
        .collect();
    entries.sort_by(|left, right| left.path.cmp(&right.path));
    transaction.commit().map_err(|error| error.to_string())?;
    Ok(IndexedSessionCatalogSnapshot {
        entries,
        warnings: Vec::new(),
    })
}

const SESSION_CATALOG_SCHEMA_V1_IDENTITY_COLUMNS: &[&str] = &[
    "stat_device_id",
    "stat_file_id",
    "stat_changed_ns",
    "device_id",
    "file_id",
    "changed_ns",
];

fn session_catalog_columns(connection: &Connection) -> Result<Option<Vec<String>>, String> {
    let exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_catalog_files')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查会话目录增量索引表：{error}"))?;
    if !exists {
        return Ok(None);
    }
    let mut statement = connection
        .prepare("SELECT name FROM pragma_table_info('session_catalog_files') ORDER BY cid")
        .map_err(|error| format!("无法检查会话目录增量索引字段：{error}"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法读取会话目录增量索引字段：{error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码会话目录增量索引字段：{error}"))?;
    Ok(Some(columns))
}

pub(super) fn validate_session_catalog_schema_version(connection: &Connection) -> Result<(), String> {
    let Some(raw_version) = metadata_text(connection, "session_catalog_schema_version")? else {
        if let Some(columns) = session_catalog_columns(connection)? {
            let expected = SESSION_CATALOG_SCHEMA_COLUMNS
                .iter()
                .map(|column| (*column).to_string())
                .collect::<Vec<_>>();
            let without_v1_identity = columns
                .iter()
                .filter(|column| {
                    !SESSION_CATALOG_SCHEMA_V1_IDENTITY_COLUMNS.contains(&column.as_str())
                })
                .cloned()
                .collect::<Vec<_>>();
            if columns != expected && without_v1_identity != expected {
                return Err(
                    "精确 token 会话目录缺少 schema 标记且表结构不是当前已知形状，已拒绝删除或覆盖"
                        .into(),
                );
            }
        }
        return Ok(());
    };
    let version = raw_version.parse::<i64>().map_err(|_| {
        format!("精确 token 会话目录 schema 版本未知或损坏（{raw_version}），已拒绝覆盖")
    })?;
    if version > SESSION_CATALOG_SCHEMA_VERSION {
        return Err(format!(
            "精确 token 会话目录 schema 版本 {version} 高于当前支持版本 {SESSION_CATALOG_SCHEMA_VERSION}，已拒绝覆盖"
        ));
    }
    if version < 0 {
        return Err(format!(
            "精确 token 会话目录 schema 版本 {version} 无效，已拒绝覆盖"
        ));
    }
    Ok(())
}

pub(super) fn initialize_session_catalog_schema(connection: &Connection) -> Result<(), String> {
    // Keep this guard here as well as in `open`: callers/tests that initialize
    // the catalog directly must receive the same fail-closed behavior before
    // the legacy DROP/CREATE path can run.
    validate_session_catalog_schema_version(connection)?;
    let mut stored_version = metadata_i64(connection, "session_catalog_schema_version")?;
    if stored_version.is_none() {
        if let Some(columns) = session_catalog_columns(connection)? {
            let has_v1_identity = SESSION_CATALOG_SCHEMA_V1_IDENTITY_COLUMNS
                .iter()
                .all(|column| columns.iter().any(|value| value == column));
            stored_version = Some(if has_v1_identity { 1 } else { 2 });
            set_metadata(
                connection,
                "session_catalog_schema_version",
                &stored_version.unwrap_or(2).to_string(),
            )?;
        }
    }
    if stored_version == Some(1) {
        let transaction = connection
            .unchecked_transaction()
            .map_err(|error| format!("无法开始会话目录 schema 1→2 迁移：{error}"))?;
        let rows_before = table_row_count(&transaction, "session_catalog_files")?;
        for column in SESSION_CATALOG_SCHEMA_V1_IDENTITY_COLUMNS {
            if column_exists_checked(&transaction, "session_catalog_files", column)? {
                transaction
                    .execute(
                        &format!("ALTER TABLE session_catalog_files DROP COLUMN {column}"),
                        [],
                    )
                    .map_err(|error| format!("无法移除会话目录身份字段 {column}：{error}"))?;
            }
        }
        let rows_after = table_row_count(&transaction, "session_catalog_files")?;
        if rows_before != rows_after {
            return Err("会话目录 schema 1→2 行数对账失败".into());
        }
        set_metadata(
            &transaction,
            "session_catalog_schema_version",
            &SESSION_CATALOG_SCHEMA_VERSION.to_string(),
        )?;
        if metadata_i64(&transaction, "session_catalog_published_generation")?.is_none() {
            let generation = transaction
                .query_row(
                    "SELECT COALESCE(MAX(last_seen_generation), 0) FROM session_catalog_files",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .map_err(|error| format!("无法恢复会话目录发布代次：{error}"))?;
            set_metadata(
                &transaction,
                "session_catalog_published_generation",
                &generation.to_string(),
            )?;
        }
        transaction
            .commit()
            .map_err(|error| format!("无法提交会话目录 schema 1→2 迁移：{error}"))?;
        stored_version = Some(SESSION_CATALOG_SCHEMA_VERSION);
    }
    if let Some(version) = stored_version {
        if version != SESSION_CATALOG_SCHEMA_VERSION {
            return Err(format!(
                "会话目录 schema {version} 无法由当前版本无损升级；已保留原表"
            ));
        }
    }

    connection
        .execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS session_catalog_files (
                path TEXT PRIMARY KEY,
                archived INTEGER NOT NULL,
                thread_id TEXT NOT NULL,
                cwd TEXT NOT NULL,
                source TEXT NOT NULL,
                session_id TEXT,
                forked_from_id TEXT,
                parent_thread_id TEXT,
                size INTEGER NOT NULL,
                modified_ns TEXT NOT NULL,
                created_ns TEXT NOT NULL,
                modified_at INTEGER,
                created_at INTEGER,
                first_line_bytes INTEGER NOT NULL,
                first_line_sha256 BLOB NOT NULL,
                last_seen_generation INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS session_catalog_thread_id_idx
                ON session_catalog_files(thread_id, path);
            INSERT INTO metadata(key, value)
            VALUES ('session_catalog_schema_version', '2')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            "#,
        )
        .map_err(|error| format!("无法确认会话目录增量索引结构：{error}"))?;
    if metadata_i64(connection, "session_catalog_published_generation")?.is_none() {
        set_metadata(connection, "session_catalog_published_generation", "0")?;
    }
    Ok(())
}

fn load_stored_session_catalog(
    connection: &Connection,
) -> Result<HashMap<PathBuf, StoredSessionCatalogEntry>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT path, archived, thread_id, cwd, source, session_id,
                   forked_from_id, parent_thread_id, size, modified_ns,
                   created_ns, modified_at, created_at,
                   first_line_bytes, first_line_sha256,
                   last_seen_generation
            FROM session_catalog_files
            "#,
        )
        .map_err(|error| format!("无法准备会话目录索引读取：{error}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, i64>(8)?,
                row.get::<_, String>(9)?,
                row.get::<_, String>(10)?,
                row.get::<_, Option<i64>>(11)?,
                row.get::<_, Option<i64>>(12)?,
                row.get::<_, i64>(13)?,
                row.get::<_, Vec<u8>>(14)?,
                row.get::<_, i64>(15)?,
            ))
        })
        .map_err(|error| format!("无法查询会话目录索引：{error}"))?;

    let mut result = HashMap::new();
    for row in rows {
        let (
            path,
            archived,
            thread_id,
            cwd,
            source,
            session_id,
            forked_from_id,
            parent_thread_id,
            size,
            modified_ns,
            created_ns,
            modified_at,
            created_at,
            first_line_bytes,
            first_line_sha256,
            last_seen_generation,
        ) = row.map_err(|error| format!("无法读取会话目录索引行：{error}"))?;
        let path = PathBuf::from(path);
        let size = u64::try_from(size)
            .map_err(|_| format!("会话目录索引文件大小无效：{}", path.display()))?;
        let first_line_bytes = u64::try_from(first_line_bytes)
            .map_err(|_| format!("会话目录索引首行长度无效：{}", path.display()))?;
        let first_line_sha256: [u8; 32] =
            first_line_sha256.try_into().map_err(|bytes: Vec<u8>| {
                format!(
                    "会话目录索引首行摘要长度无效：{}（{} 字节）",
                    path.display(),
                    bytes.len()
                )
            })?;
        result.insert(
            path.clone(),
            StoredSessionCatalogEntry {
                entry: IndexedSessionCatalogEntry {
                    path,
                    archived: archived != 0,
                    metadata: IndexedSessionMetadata {
                        thread_id,
                        cwd,
                        source,
                        session_id,
                        forked_from_id,
                        parent_thread_id,
                    },
                    size,
                    modified_at,
                    created_at,
                },
                modified_ns,
                created_ns,
                first_line_bytes,
                first_line_sha256,
                last_seen_generation,
            },
        );
    }
    Ok(result)
}

fn collect_session_catalog_observations(
    codex_home: &Path,
) -> Result<Vec<SessionCatalogObservation>, String> {
    let mut observations = Vec::new();
    for (relative_root, archived) in [("sessions", false), ("archived_sessions", true)] {
        let root = codex_home.join(relative_root);
        let root_metadata = match fs::symlink_metadata(&root) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(format!(
                    "无法读取会话目录 {} 的属性：{error}",
                    root.display()
                ));
            }
        };
        reject_session_catalog_reparse_point(&root, &root_metadata)?;
        if !root_metadata.is_dir() {
            return Err(format!("会话目录不是普通目录：{}", root.display()));
        }
        let canonical_root = fs::canonicalize(&root)
            .map_err(|error| format!("无法固定会话目录 {}：{error}", root.display()))?;
        let mut pending = vec![canonical_root];
        while let Some(directory) = pending.pop() {
            let entries = fs::read_dir(&directory).map_err(|error| {
                format!("会话目录增量扫描无法读取 {}：{error}", directory.display())
            })?;
            for entry in entries {
                let entry = entry.map_err(|error| {
                    format!(
                        "会话目录增量扫描无法读取 {} 中的目录项：{error}",
                        directory.display()
                    )
                })?;
                let path = entry.path();
                if is_history_repair_workspace(&path) { continue; }
                let metadata = fs::symlink_metadata(&path).map_err(|error| {
                    format!(
                        "会话目录增量扫描无法读取 {} 的属性：{error}",
                        path.display()
                    )
                })?;
                reject_session_catalog_reparse_point(&path, &metadata)?;
                if metadata.is_dir() {
                    pending.push(path);
                    continue;
                }
                if !metadata.is_file()
                    || !rollout_source::is_rollout(&path)
                {
                    continue;
                }
                let logical = rollout_source::canonical_logical_path(&path).map_err(|e|e.to_string())?;
                let selected = rollout_source::physical_path(&logical).map_err(|e|format!("无法解析目录来源 {}：{e}",logical.display()))?;
                let selected_metadata = fs::symlink_metadata(&selected).map_err(|e|e.to_string())?;
                reject_session_catalog_reparse_point(&selected, &selected_metadata)?;
                observations.push(session_catalog_observation(logical, archived, &selected_metadata)?);
            }
        }
    }
    observations.sort_by(|left, right| left.path.cmp(&right.path));
    observations.dedup_by(|left,right| left.path==right.path);
    Ok(observations)
}

fn session_catalog_observation(
    path: PathBuf,
    archived: bool,
    metadata: &fs::Metadata,
) -> Result<SessionCatalogObservation, String> {
    let modified = metadata.modified().ok();
    let created = metadata.created().ok();
    // Invalidation and displayed disk usage track the physical source. A
    // catalog header does not require the accounting index or logical length.
    let size = metadata.len();
    Ok(SessionCatalogObservation {
        path,
        archived,
        size,
        modified_ns: system_time_ns_text(modified),
        created_ns: system_time_ns_text(created),
        modified_at: system_time_unix_seconds(modified),
        created_at: system_time_unix_seconds(created),
    })
}

fn session_catalog_observation_matches(
    stored: &StoredSessionCatalogEntry,
    observed: &SessionCatalogObservation,
) -> bool {
    stored.entry.archived == observed.archived
        && stored.entry.size == observed.size
        && stored.modified_ns == observed.modified_ns
}

fn refresh_session_catalog_entry<F>(
    observation: SessionCatalogObservation,
    previous: Option<&StoredSessionCatalogEntry>,
    generation: i64,
    parser: &mut F,
) -> Result<StoredSessionCatalogEntry, String>
where
    F: FnMut(&[u8]) -> Result<IndexedSessionMetadata, String>,
{
    let physical = rollout_source::physical_path(&observation.path).map_err(|e|e.to_string())?;
    // Pin and validate the physical source while reading only session_meta.
    let mut file = open_session_catalog_rollout(&physical)?;
    let before = file_signature_from_handle(&file, &observation.path)?;
    if before.size != observation.size || before.modified_ns.to_string() != observation.modified_ns
    {
        return Err(format!(
            "会话文件在索引读取前发生变化，请重试：{}",
            observation.path.display()
        ));
    }
    let mut first_line = Vec::new();
    {
        let source = rollout_source::metadata_reader(&mut file).map_err(|error| error.to_string())?;
        let mut reader = BufReader::new(source);
        reader.read_until(b'\n', &mut first_line).map_err(|error| {
            format!(
                "读取会话文件首行失败：{}（{error}）",
                observation.path.display()
            )
        })?;
    }
    if first_line.last().copied() != Some(b'\n') {
        return Err(format!(
            "会话文件首条 session_meta 尚未形成完整行：{}",
            observation.path.display()
        ));
    }
    let after = file_signature_from_handle(&file, &observation.path)?;
    if before != after {
        return Err(format!(
            "会话文件在首行校验期间发生变化，请重试：{}",
            observation.path.display()
        ));
    }
    let physical_path = rollout_source::physical_path(&observation.path).map_err(|error| error.to_string())?;
    if physical_path != physical {
        return Err(format!("会话物理表示在首行校验期间变化，请重试：{}", observation.path.display()));
    }
    let current_file = open_session_catalog_rollout(&physical_path)?;
    if file_signature_from_handle(&current_file, &observation.path)? != before {
        return Err(format!("会话文件路径在首行校验期间被替换，请重试：{}", observation.path.display()));
    }
    let path_metadata = fs::symlink_metadata(&physical_path).map_err(|error| {
        format!(
            "会话文件首行校验后无法复核路径 {}：{error}",
            observation.path.display()
        )
    })?;
    reject_session_catalog_reparse_point(&observation.path, &path_metadata)?;
    let path_observation = session_catalog_observation(
        observation.path.clone(),
        observation.archived,
        &path_metadata,
    )?;
    if !session_catalog_observation_values_match(&observation, &path_observation) {
        return Err(format!(
            "会话文件路径在首行校验期间被替换，请重试：{}",
            observation.path.display()
        ));
    }

    let first_line_sha256: [u8; 32] = Sha256::digest(&first_line).into();
    let metadata = if previous.is_some_and(|entry| {
        observation.size >= entry.entry.size
            && entry.first_line_bytes == first_line.len() as u64
            && entry.first_line_sha256 == first_line_sha256
    }) {
        previous
            .expect("checked previous session catalog entry")
            .entry
            .metadata
            .clone()
    } else {
        let metadata = parser(&first_line).map_err(|error| {
            format!(
                "无法解析会话文件 {} 的 session_meta：{error}",
                observation.path.display()
            )
        })?;
        if metadata.thread_id.trim().is_empty() {
            return Err(format!(
                "会话文件首行缺少会话 ID：{}",
                observation.path.display()
            ));
        }
        metadata
    };

    Ok(StoredSessionCatalogEntry {
        entry: IndexedSessionCatalogEntry {
            path: observation.path,
            archived: observation.archived,
            metadata,
            size: observation.size,
            modified_at: observation.modified_at,
            created_at: observation.created_at,
        },
        modified_ns: observation.modified_ns,
        created_ns: observation.created_ns,
        first_line_bytes: first_line.len() as u64,
        first_line_sha256,
        last_seen_generation: generation,
    })
}

fn session_catalog_observation_values_match(
    left: &SessionCatalogObservation,
    right: &SessionCatalogObservation,
) -> bool {
    left.archived == right.archived
        && left.size == right.size
        && left.modified_ns == right.modified_ns
}

fn system_time_ns_text(value: Option<SystemTime>) -> String {
    value
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos().to_string())
        .unwrap_or_else(|| "0".into())
}

fn system_time_unix_seconds(value: Option<SystemTime>) -> Option<i64> {
    value
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
}

#[cfg(unix)]
fn open_session_catalog_rollout(path: &Path) -> Result<fs::File, String> {
    use std::os::unix::fs::OpenOptionsExt;

    fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("无法打开会话目录索引源 {}：{error}", path.display()))
}

#[cfg(windows)]
fn open_session_catalog_rollout(path: &Path) -> Result<fs::File, String> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;

    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("无法打开会话目录索引源 {}：{error}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("无法读取会话目录索引源属性：{error}"))?;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!(
            "会话目录索引拒绝 Windows 重解析点：{}",
            path.display()
        ));
    }
    if !metadata.is_file() {
        return Err(format!("会话目录索引源不是普通文件：{}", path.display()));
    }
    Ok(file)
}

#[cfg(not(any(unix, windows)))]
fn open_session_catalog_rollout(path: &Path) -> Result<fs::File, String> {
    fs::File::open(path)
        .map_err(|error| format!("无法打开会话目录索引源 {}：{error}", path.display()))
}

#[cfg(test)]
fn run_before_session_catalog_publish_hook_for_testing() -> Result<(), String> {
    FAIL_NEXT_SESSION_CATALOG_PUBLISH.with(|flag| {
        if flag.replace(false) {
            Err("injected interruption before session catalog publish".into())
        } else {
            Ok(())
        }
    })
}

#[cfg(not(test))]
fn run_before_session_catalog_publish_hook_for_testing() -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
pub(super) fn fail_next_session_catalog_publish_for_testing() {
    FAIL_NEXT_SESSION_CATALOG_PUBLISH.with(|flag| flag.set(true));
}
