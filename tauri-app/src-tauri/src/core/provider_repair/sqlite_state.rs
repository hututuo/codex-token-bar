use super::safe_fs::PinnedHome;
use super::{provider_for_mutation, validated_provider_candidate};
use crate::core::sqlite;
use rusqlite::{Connection, Result as SqlResult};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const SQLITE_STAGE_ATTEMPTS: usize = 64;
static SQLITE_STAGE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
pub(super) struct SQLiteScan {
    pub(super) database_present: bool,
    pub(super) provider_counts: Vec<SQLiteProviderCount>,
    pub(super) thread_providers: HashMap<String, String>,
    pub(super) latest_unarchived_provider: Option<String>,
    pub(super) latest_unarchived_thread_id: Option<String>,
    pub(super) integrity: String,
}

impl SQLiteScan {
    pub(super) fn rows_to_repair(&self, target_provider: &str) -> u32 {
        self.provider_counts
            .iter()
            .filter(|row| row.provider != target_provider)
            .map(|row| row.count)
            .sum()
    }

    pub(super) fn rows_to_repair_from_sessions(
        &self,
        session_providers: &HashMap<String, String>,
    ) -> u32 {
        session_providers
            .iter()
            .filter(|(thread_id, provider)| {
                self.thread_providers
                    .get(*thread_id)
                    .is_some_and(|current| current != *provider)
            })
            .count()
            .try_into()
            .unwrap_or(u32::MAX)
    }
}

pub(super) struct SQLiteProviderCount {
    pub(super) provider: String,
    #[allow(dead_code)]
    archived: i64,
    count: u32,
}

struct LatestSQLiteProvider {
    provider: String,
    thread_id: String,
}

pub(super) fn scan_sqlite(codex_home: &Path) -> SqlResult<SQLiteScan> {
    let db_path = codex_home.join("state_5.sqlite");
    let connection = open_read_only(&db_path)?;
    let columns = thread_columns(&connection)?;
    if !columns.contains("model_provider") {
        return Ok(SQLiteScan {
            database_present: true,
            integrity: sqlite_integrity(&connection).unwrap_or_else(|_| "unknown".into()),
            ..SQLiteScan::default()
        });
    }

    let provider_counts = sqlite_provider_counts(&connection, &columns)?;
    let thread_providers = sqlite_thread_providers(&connection)?;
    let latest_unarchived = latest_sqlite_provider(&connection, &columns)?;
    let (latest_unarchived_provider, latest_unarchived_thread_id) = match latest_unarchived {
        Some(row) => (
            validated_provider_candidate(&row.provider),
            Some(row.thread_id),
        ),
        None => (None, None),
    };
    Ok(SQLiteScan {
        database_present: true,
        provider_counts,
        thread_providers,
        latest_unarchived_provider,
        latest_unarchived_thread_id,
        integrity: sqlite_integrity(&connection).unwrap_or_else(|_| "unknown".into()),
    })
}

pub(super) fn scan_sqlite_in(pinned_home: &PinnedHome) -> Result<SQLiteScan, String> {
    if pinned_home
        .open_file(Path::new("state_5.sqlite"))?
        .is_none()
    {
        return Ok(SQLiteScan::default());
    }
    with_pinned_sqlite_snapshot(pinned_home, |snapshot_root| {
        scan_sqlite(snapshot_root).map_err(|error| error.to_string())
    })
}

#[cfg(test)]
pub(super) fn sync_sqlite_provider(
    codex_home: &Path,
    target_provider: &str,
) -> Result<u32, String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    sync_sqlite_provider_in(&pinned_home, target_provider)
}

pub(super) fn sync_sqlite_provider_in(
    pinned_home: &PinnedHome,
    target_provider: &str,
) -> Result<u32, String> {
    sync_sqlite_provider_from_source(
        pinned_home,
        SQLiteProviderMutation::Migrate(target_provider.to_string()),
        None,
    )
}

pub(super) fn sync_sqlite_provider_from_snapshot_in(
    pinned_home: &PinnedHome,
    target_provider: &str,
    snapshot: &Path,
    expected_size: u64,
    expected_checksum: &str,
) -> Result<u32, String> {
    sync_sqlite_provider_from_source(
        pinned_home,
        SQLiteProviderMutation::Migrate(target_provider.to_string()),
        Some((snapshot, expected_size, expected_checksum)),
    )
}

pub(super) fn repair_sqlite_providers_from_snapshot_in(
    pinned_home: &PinnedHome,
    session_providers: &HashMap<String, String>,
    snapshot: &Path,
    expected_size: u64,
    expected_checksum: &str,
) -> Result<u32, String> {
    sync_sqlite_provider_from_source(
        pinned_home,
        SQLiteProviderMutation::Repair(session_providers),
        Some((snapshot, expected_size, expected_checksum)),
    )
}

enum SQLiteProviderMutation<'a> {
    Migrate(String),
    Repair(&'a HashMap<String, String>),
}

fn sync_sqlite_provider_from_source(
    pinned_home: &PinnedHome,
    mutation: SQLiteProviderMutation<'_>,
    snapshot: Option<(&Path, u64, &str)>,
) -> Result<u32, String> {
    let mutation = match mutation {
        SQLiteProviderMutation::Migrate(provider) => {
            SQLiteProviderMutation::Migrate(provider_for_mutation(&provider)?)
        }
        SQLiteProviderMutation::Repair(providers) => {
            for provider in providers.values() {
                provider_for_mutation(provider)?;
            }
            SQLiteProviderMutation::Repair(providers)
        }
    };
    let relative = Path::new("state_5.sqlite");
    if pinned_home.open_file(relative)?.is_none() {
        return Ok(0);
    }
    let stage = create_sqlite_stage_directory()?;
    let result = (|| {
        if let Some((snapshot, expected_size, expected_checksum)) = snapshot {
            copy_snapshot_file(
                snapshot,
                &stage.join("state_5.sqlite"),
                expected_size,
                expected_checksum,
            )?;
        } else {
            copy_pinned_member(pinned_home, relative, &stage.join("state_5.sqlite"))?;
            if pinned_home
                .open_file(Path::new("state_5.sqlite-wal"))?
                .is_some()
            {
                copy_pinned_member(
                    pinned_home,
                    Path::new("state_5.sqlite-wal"),
                    &stage.join("state_5.sqlite-wal"),
                )?;
            }
        }

        let staged_database = stage.join("state_5.sqlite");
        let connection = sqlite::open_read_write(&staged_database, Duration::from_secs(2))
            .map_err(|error| error.to_string())?;
        let columns = thread_columns(&connection).map_err(|error| error.to_string())?;
        if !columns.contains("model_provider") {
            return Ok(0);
        }
        let changed = match mutation {
            SQLiteProviderMutation::Migrate(target_provider) => connection
                .execute(
                    "UPDATE threads SET model_provider = ?1 WHERE COALESCE(model_provider, '') <> ?1;",
                    [target_provider.as_str()],
                )
                .map_err(|error| error.to_string())?,
            SQLiteProviderMutation::Repair(session_providers) => {
                let transaction = connection
                    .unchecked_transaction()
                    .map_err(|error| error.to_string())?;
                let mut changed = 0_usize;
                {
                    let mut statement = transaction
                        .prepare(
                            "UPDATE threads SET model_provider = ?1 \
                             WHERE id = ?2 AND COALESCE(model_provider, '') <> ?1;",
                        )
                        .map_err(|error| error.to_string())?;
                    for (thread_id, provider) in session_providers {
                        changed = changed.saturating_add(
                            statement
                                .execute([provider.as_str(), thread_id.as_str()])
                                .map_err(|error| error.to_string())?,
                        );
                    }
                }
                transaction.commit().map_err(|error| error.to_string())?;
                changed
            }
        };
        sqlite::checkpoint_wal_full(&connection);
        connection
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|error| format!("固化 Provider SQLite WAL 失败：{error}"))?;
        let journal_mode: String = connection
            .query_row("PRAGMA journal_mode = DELETE", [], |row| row.get(0))
            .map_err(|error| format!("固化 Provider SQLite journal_mode 失败：{error}"))?;
        if !journal_mode.eq_ignore_ascii_case("delete") {
            return Err(format!(
                "Provider SQLite journal_mode 未固化为 delete：{journal_mode}"
            ));
        }
        let integrity = sqlite_integrity(&connection).map_err(|error| error.to_string())?;
        if integrity != "ok" {
            return Err(format!("SQLite integrity_check: {integrity}"));
        }
        drop(connection);
        if changed == 0 {
            return Ok(0);
        }

        for sidecar in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
            pinned_home.remove_file(Path::new(sidecar), || Ok(()))?;
        }
        let mut source = OpenOptions::new()
            .read(true)
            .open(&staged_database)
            .map_err(|error| error.to_string())?;
        pinned_home.install_atomically(
            relative,
            None,
            None,
            |target| {
                source
                    .rewind()
                    .and_then(|_| std::io::copy(&mut source, target).map(|_| ()))
                    .map_err(|error| error.to_string())
            },
            |_, _| Ok(()),
        )?;
        Ok(u32::try_from(changed).unwrap_or(u32::MAX))
    })();
    cleanup_sqlite_stage(&stage, result)
}

fn copy_snapshot_file(
    source: &Path,
    target: &Path,
    expected_size: u64,
    expected_checksum: &str,
) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source).map_err(|error| error.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "Provider SQLite 恢复点成员不是普通文件：{}",
            source.display()
        ));
    }
    let mut source_file = OpenOptions::new()
        .read(true)
        .open(source)
        .map_err(|error| error.to_string())?;
    let mut target_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)
        .map_err(|error| error.to_string())?;
    let mut size = 0_u64;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = source_file
            .read(&mut buffer)
            .map_err(|error| error.to_string())?;
        if read == 0 {
            break;
        }
        target_file
            .write_all(&buffer[..read])
            .map_err(|error| error.to_string())?;
        hasher.update(&buffer[..read]);
        size = size.saturating_add(u64::try_from(read).unwrap_or(u64::MAX));
    }
    target_file.sync_all().map_err(|error| error.to_string())?;
    let checksum = format!("{:x}", hasher.finalize());
    if size != expected_size || checksum != expected_checksum {
        return Err(format!(
            "Provider SQLite 恢复点成员在安装前 SHA-256 或大小校验失败：{}",
            source.display()
        ));
    }
    Ok(())
}

fn create_sqlite_stage_directory() -> Result<std::path::PathBuf, String> {
    let root = std::env::temp_dir();
    for _ in 0..SQLITE_STAGE_ATTEMPTS {
        let sequence = SQLITE_STAGE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = root.join(format!(
            "codex-token-bar-provider-sqlite-{}-{sequence:020}",
            std::process::id()
        ));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("创建 Provider SQLite 暂存目录失败：{error}")),
        }
    }
    Err("无法创建唯一 Provider SQLite 暂存目录".into())
}

fn copy_pinned_member(
    pinned_home: &PinnedHome,
    relative: &Path,
    target: &Path,
) -> Result<(), String> {
    let mut source = pinned_home
        .open_file(relative)?
        .ok_or_else(|| format!("Provider SQLite 成员不存在：{}", relative.display()))?;
    let mut target = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)
        .map_err(|error| error.to_string())?;
    std::io::copy(&mut source, &mut target).map_err(|error| error.to_string())?;
    target.sync_all().map_err(|error| error.to_string())
}

fn cleanup_sqlite_stage<T>(stage: &Path, result: Result<T, String>) -> Result<T, String> {
    match fs::remove_dir_all(stage) {
        Ok(()) => result,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => result,
        Err(error) => match result {
            Ok(_) => Err(format!(
                "Provider SQLite 已处理，但敏感暂存目录清理失败，残留于 {}：{error}",
                stage.display()
            )),
            Err(operation_error) => Err(format!(
                "{operation_error}；敏感暂存目录清理失败，残留于 {}：{error}",
                stage.display()
            )),
        },
    }
}

pub(super) fn latest_thread_index_entry(
    codex_home: &Path,
    thread_id: &str,
) -> Result<Value, String> {
    let connection =
        open_read_only(&codex_home.join("state_5.sqlite")).map_err(|error| error.to_string())?;
    let columns = thread_columns(&connection).map_err(|error| error.to_string())?;
    let title_expression = if columns.contains("thread_name") {
        "COALESCE(thread_name, id)"
    } else if columns.contains("title") {
        "COALESCE(title, id)"
    } else {
        "id"
    };
    let updated_expression = updated_at_expression(&columns);
    let sql = format!(
        "SELECT id, {title_expression}, {updated_expression} FROM threads WHERE id = ?1 LIMIT 1;"
    );
    let (id, title, updated_ms): (String, String, i64) = connection
        .query_row(&sql, [thread_id], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .map_err(|error| error.to_string())?;
    Ok(json!({
        "id": id,
        "thread_name": title,
        "updated_at": format_unix_millis_rfc3339(updated_ms)
    }))
}

pub(super) fn latest_thread_index_entry_in(
    pinned_home: &PinnedHome,
    thread_id: &str,
) -> Result<Value, String> {
    with_pinned_sqlite_snapshot(pinned_home, |snapshot_root| {
        latest_thread_index_entry(snapshot_root, thread_id)
    })
}

fn with_pinned_sqlite_snapshot<T>(
    pinned_home: &PinnedHome,
    operation: impl FnOnce(&Path) -> Result<T, String>,
) -> Result<T, String> {
    let stage = create_sqlite_stage_directory()?;
    let result = (|| {
        copy_pinned_member(
            pinned_home,
            Path::new("state_5.sqlite"),
            &stage.join("state_5.sqlite"),
        )?;
        for sidecar in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
            let relative = Path::new(sidecar);
            if pinned_home.open_file(relative)?.is_some() {
                copy_pinned_member(pinned_home, relative, &stage.join(sidecar))?;
            }
        }
        operation(&stage)
    })();
    cleanup_sqlite_stage(&stage, result)
}

fn sqlite_provider_counts(
    connection: &Connection,
    columns: &HashSet<String>,
) -> SqlResult<Vec<SQLiteProviderCount>> {
    let archived_expression = if columns.contains("archived") {
        "COALESCE(archived, 0)"
    } else {
        "0"
    };
    let mut statement = connection.prepare(&format!(
        r#"
        SELECT COALESCE(model_provider, ''), {archived_expression}, COUNT(*)
        FROM threads
        GROUP BY COALESCE(model_provider, ''), {archived_expression}
        ORDER BY {archived_expression} ASC, COUNT(*) DESC;
        "#
    ))?;
    let rows = statement.query_map([], |row| {
        Ok(SQLiteProviderCount {
            provider: provider_or_missing(row.get::<_, String>(0)?),
            archived: row.get::<_, i64>(1).unwrap_or(0),
            count: u32::try_from(row.get::<_, i64>(2).unwrap_or(0)).unwrap_or(0),
        })
    })?;
    rows.collect()
}

fn sqlite_thread_providers(connection: &Connection) -> SqlResult<HashMap<String, String>> {
    let mut statement =
        connection.prepare("SELECT id, COALESCE(model_provider, '') FROM threads;")?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            provider_or_missing(row.get::<_, String>(1)?),
        ))
    })?;
    rows.collect()
}

fn latest_sqlite_provider(
    connection: &Connection,
    columns: &HashSet<String>,
) -> SqlResult<Option<LatestSQLiteProvider>> {
    let archived_filter = if columns.contains("archived") {
        "WHERE COALESCE(archived, 0) = 0"
    } else {
        ""
    };
    let updated_expression = updated_at_expression(columns);
    let mut statement = connection.prepare(&format!(
        r#"
        SELECT COALESCE(model_provider, ''), id
        FROM threads
        {archived_filter}
        ORDER BY {updated_expression} DESC, id DESC
        LIMIT 1;
        "#
    ))?;
    let mut rows = statement.query([])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    Ok(Some(LatestSQLiteProvider {
        provider: provider_or_missing(row.get(0)?),
        thread_id: row.get(1)?,
    }))
}

fn updated_at_expression(columns: &HashSet<String>) -> &'static str {
    if columns.contains("updated_at_ms") && columns.contains("updated_at") {
        "COALESCE(updated_at_ms, updated_at * 1000)"
    } else if columns.contains("updated_at_ms") {
        "updated_at_ms"
    } else if columns.contains("updated_at") {
        "updated_at * 1000"
    } else {
        "0"
    }
}

fn thread_columns(connection: &Connection) -> SqlResult<HashSet<String>> {
    let mut statement = connection.prepare("PRAGMA table_info(threads);")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(1))?;
    rows.collect()
}

fn sqlite_integrity(connection: &Connection) -> SqlResult<String> {
    connection.query_row("PRAGMA integrity_check;", [], |row| row.get(0))
}

fn open_read_only(path: &Path) -> SqlResult<Connection> {
    sqlite::open_read_only(path, Duration::from_millis(250))
}

fn format_unix_millis_rfc3339(millis: i64) -> String {
    let seconds = if millis > 10_000_000_000 {
        millis / 1000
    } else {
        millis
    };
    OffsetDateTime::from_unix_timestamp(seconds)
        .unwrap_or_else(|_| OffsetDateTime::UNIX_EPOCH)
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
}

fn provider_or_missing(value: String) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        "(missing)".into()
    } else {
        trimmed.into()
    }
}
