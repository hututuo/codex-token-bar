//! External state is live, read-only input, never a legacy ledger to import.
//! data_version is compared only on the same retained SQLite connection.
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

pub(super) enum SourceRead<T> {
    Unchanged,
    Updated { token: String, value: T },
}

struct Reader {
    connection: rusqlite::Connection,
    identity: Option<(u64, u64)>,
    instance: uuid::Uuid,
    last_used: Instant,
}

// A bounded metadata owner. The lock covers short source reads only, never
// an Exact scan, a ledger transaction, or a callback that re-enters this cache.
static READERS: OnceLock<Mutex<HashMap<PathBuf, Reader>>> = OnceLock::new();
const MAX_READERS: usize = 16;

fn identity(path: &Path) -> Result<Option<(u64, u64)>, String> {
    let handle = fs::File::open(path).map_err(|e| format!("打开本地状态来源失败：{e}"))?;
    let metadata = handle
        .metadata()
        .map_err(|e| format!("读取本地状态来源身份失败：{e}"))?;
    if !metadata.is_file() {
        return Err("本地状态来源不是普通文件".into());
    }
    // Change-time/mtime may advance for normal writes. Only device/file identity
    // distinguishes replacement; committed row changes use SQLite data_version.
    Ok(super::physical_file_stamp(&handle, &metadata)?.map(|s| (s.volume, s.file_id)))
}

pub(super) fn read_snapshot<T>(
    database: &Path,
    previous: Option<&str>,
    read: impl FnOnce(&rusqlite::Connection) -> Result<T, String>,
) -> Result<SourceRead<T>, String> {
    let before = identity(database)?;
    // SQLite's Windows VFS opens with SHARE_READ|SHARE_WRITE, without
    // SHARE_DELETE. Retaining that handle would prevent the external owner
    // from replacing its database. A fresh short read is safer there; never
    // compare data_version values obtained from different connections.
    if cfg!(windows) {
        let mut reader = open_reader(database, before)?;
        return read_from(&mut reader, database, None, read);
    }
    let mut cache = READERS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| "本地状态来源读取器不可用".to_string())?;
    // Unknown file identity cannot justify retaining an old physical handle.
    let reopen = cache
        .get(database)
        .is_none_or(|r| before.is_none() || r.identity != before);
    if reopen {
        cache.remove(database);
        if cache.len() >= MAX_READERS {
            if let Some(oldest) = cache
                .iter()
                .min_by_key(|(_, r)| r.last_used)
                .map(|(p, _)| p.clone())
            {
                cache.remove(&oldest);
            }
        }
        cache.insert(database.to_path_buf(), open_reader(database, before)?);
    }
    let reader = cache.get_mut(database).ok_or("本地状态来源读取器不存在")?;
    read_from(reader, database, previous, read)
}

fn open_reader(database: &Path, before: Option<(u64, u64)>) -> Result<Reader, String> {
    let connection = crate::core::sqlite::open_read_only(database, Duration::from_secs(3))
        .map_err(|e| e.to_string())?;
    connection
        .pragma_update(None, "query_only", true)
        .map_err(|e| e.to_string())?;
    if identity(database)? != before {
        return Err("本地状态来源在打开期间被替换".into());
    }
    Ok(Reader {
        connection,
        identity: before,
        instance: uuid::Uuid::new_v4(),
        last_used: Instant::now(),
    })
}

fn read_from<T>(
    reader: &mut Reader,
    database: &Path,
    previous: Option<&str>,
    read: impl FnOnce(&rusqlite::Connection) -> Result<T, String>,
) -> Result<SourceRead<T>, String> {
    reader.last_used = Instant::now();
    let version: i64 = reader
        .connection
        .pragma_query_value(None, "data_version", |row| row.get(0))
        .map_err(|e| e.to_string())?;
    let token = format!("sqlite-live-reader-v2:{}:{version}", reader.instance);
    if previous == Some(token.as_str()) {
        return Ok(SourceRead::Unchanged);
    }

    // A short transaction pins one committed snapshot. A concurrent commit is
    // valid: retain this snapshot's token and notice the next version on refresh.
    // Never attach a newer post-read version to older rows (which loses updates).
    let transaction = reader
        .connection
        .unchecked_transaction()
        .map_err(|e| e.to_string())?;
    let value = read(&transaction)?;
    transaction.commit().map_err(|e| e.to_string())?;
    if identity(database)? != reader.identity {
        return Err("本地状态来源在读取期间被替换，已保留上一份结果".into());
    }
    Ok(SourceRead::Updated { token, value })
}

#[cfg(test)]
mod tests;
