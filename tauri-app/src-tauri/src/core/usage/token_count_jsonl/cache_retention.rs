//! One diagnostic pipeline: rollout ownership -> numeric first-usage facts ->
//! retained sidecar -> chart. This module never writes Codex or the billing DB.
mod database;
use super::{rollout_source, session_parser};
use crate::core::{app_paths, cross_process_lock::CrossProcessFileLock, sqlite};
use serde::{Deserialize, Serialize};
use session_parser::cache_retention_parser::{Parser, Point, REVISION};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Checkpoint {
    pub generation: String,
    pub offset: u64,
    pub prefix_digest: String,
    pub parser: Parser,
    pub parser_revision: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub points: Vec<Point>,
    pub models: Vec<String>,
    pub source_count: usize,
    pub own_round_count: i64,
    pub revision: i64,
    pub failures: usize,
    pub updated_at_microseconds: i64,
}

fn hash(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes.as_ref()))
}

fn database_path(home: &Path) -> Result<PathBuf, String> {
    let canonical = fs::canonicalize(home).map_err(|e| format!("Codex 目录暂不可用：{e}"))?;
    let root = app_paths::usage_history_dir()
        .ok_or("无法定位续问建议保存目录")?
        .parent()
        .ok_or("续问建议目录无父路径")?
        .join("cache-retention-v1");
    Ok(root.join(format!(
        "{}.sqlite",
        hash(canonical.to_string_lossy().as_bytes())
    )))
}

pub(crate) fn read(
    home: &Path,
    days: Option<u32>,
    model: Option<&str>,
    refresh: bool,
) -> Result<Snapshot, String> {
    if days.is_some_and(|d| d != 7 && d != 30) {
        return Err("不支持的续问建议时间范围".into());
    }
    let home = fs::canonicalize(home).map_err(|e| e.to_string())?;
    let path = database_path(&home)?;
    let now = time::OffsetDateTime::now_utc().unix_timestamp_nanos() / 1000;
    let now = i64::try_from(now).map_err(|e| e.to_string())?;
    if !refresh {
        match fs::metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Snapshot {
                    points: Vec::new(),
                    models: Vec::new(),
                    source_count: 0,
                    own_round_count: 0,
                    revision: 0,
                    failures: 0,
                    updated_at_microseconds: now,
                })
            }
            Err(e) => return Err(e.to_string()),
            Ok(_) => {}
        }
        return database::Database::open_read_only(&path)?.snapshot(days, model, now);
    }
    // Only the background writer owns a lock. WAL readers keep the previous
    // verified snapshot available during a long first import or append scan.
    let _lock = CrossProcessFileLock::acquire(&path.with_extension("lock"), "续问建议更新")?;
    let db = database::Database::open(&path)?;
    let failures = synchronize(&home, &path, &db)?;
    let mut result = db.snapshot(days, model, now)?;
    result.failures = failures;
    Ok(result)
}

fn discover(root: &Path, output: &mut std::collections::BTreeSet<PathBuf>) -> Result<(), String> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("会话目录不可读，保留上次建议：{e}")),
    };
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            discover(&entry.path(), output)?;
        } else if kind.is_file() && rollout_source::is_rollout(&entry.path()) {
            output.insert(rollout_source::logical_path(&entry.path()));
        }
    }
    Ok(())
}

fn known_subagents(home: &Path) -> Result<HashSet<String>, String> {
    let path = home.join("state_5.sqlite");
    match fs::metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(HashSet::new()),
        Err(e) => return Err(e.to_string()),
        Ok(_) => {}
    }
    let db =
        sqlite::open_read_only(&path, Duration::from_millis(150)).map_err(|e| e.to_string())?;
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='threads')",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    if !exists {
        return Ok(HashSet::new());
    }
    let mut statement = db
        .prepare("SELECT id FROM threads WHERE source LIKE '%subagent%'")
        .map_err(|e| e.to_string())?;
    let result = statement
        .query_map([], |r| r.get(0))
        .map_err(|e| e.to_string())?
        .collect::<Result<_, _>>()
        .map_err(|e| e.to_string());
    result
}

fn fingerprint(path: &Path) -> Result<String, String> {
    let physical = rollout_source::physical_path(path).map_err(|e| e.to_string())?;
    let metadata = fs::metadata(&physical).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    let identity = {
        use std::os::unix::fs::MetadataExt;
        format!(
            "{}:{}:{}:{}",
            metadata.dev(),
            metadata.ino(),
            metadata.ctime(),
            metadata.ctime_nsec()
        )
    };
    #[cfg(windows)]
    let identity = {
        use std::os::windows::fs::MetadataExt;
        format!(
            "{}:{}:{}",
            metadata.creation_time(),
            metadata.last_write_time(),
            metadata.file_attributes()
        )
    };
    #[cfg(not(any(unix, windows)))]
    let identity = format!("{:?}", metadata.created().ok());
    Ok(format!(
        "{REVISION}:{}:{:?}:{}:{identity}",
        metadata.len(),
        metadata.modified().map_err(|e| e.to_string())?,
        physical.display()
    ))
}

fn synchronize(home: &Path, path: &Path, db: &database::Database) -> Result<usize, String> {
    let mut files = std::collections::BTreeSet::new();
    discover(&home.join("sessions"), &mut files)?;
    discover(&home.join("archived_sessions"), &mut files)?;
    let known = known_subagents(home)?;
    let kind_keys: HashSet<_> = known.iter().map(hash).collect();
    let summaries = db.summaries()?;
    let mut visited = HashSet::new();
    let mut failures = 0;
    for file in files {
        let key = hash(file.to_string_lossy().as_bytes());
        visited.insert(key.clone());
        // A source error retains its last verified generation. Database errors
        // propagate rather than being converted to a successful partial scan.
        let old = summaries.get(&key);
        let same_kind =
            old.is_some_and(|s| s.is_child == (s.explicit_child || kind_keys.contains(&s.session)));
        let signature = match fingerprint(&file) {
            Ok(value) => value,
            Err(_) => {
                failures += 1;
                continue;
            }
        };
        if old.is_some_and(|s| s.fingerprint == signature) && same_kind {
            continue;
        }
        let cached = if same_kind {
            db.checkpoint(&key)?
        } else {
            None
        };
        let result = (|| {
            let checkpoint = parse(&file, cached, &known)?;
            if fingerprint(&file)? != signature {
                return Err("会话正在改写，稍后重试".into());
            }
            Ok::<_, String>(Some((signature, checkpoint)))
        })();
        match result {
            Ok(Some((signature, checkpoint))) => {
                let size = fs::metadata(path).map(|m| m.len()).unwrap_or(0)
                    + fs::metadata(format!("{}-wal", path.display()))
                        .map(|m| m.len())
                        .unwrap_or(0);
                if size > 500 * 1024 * 1024 {
                    return Err("续问建议缓存达到 500 MiB 预算，已保留历史并暂停更新".into());
                }
                db.publish(&key, &signature, &checkpoint)?;
            }
            Ok(None) => {}
            Err(_) => failures += 1,
        }
    }
    db.remove_missing(&visited)?;
    Ok(failures)
}

fn parse(
    path: &Path,
    cached: Option<Checkpoint>,
    known: &HashSet<String>,
) -> Result<Checkpoint, String> {
    let mut reader = rollout_source::RolloutReader::open(path).map_err(|e| e.to_string())?;
    let before = reader.metadata().map_err(|e| e.to_string())?;
    let metadata = session_parser::paginated_subagent_metadata(&mut reader)?;
    let mut state = Checkpoint {
        generation: uuid::Uuid::new_v4().to_string(),
        offset: 0,
        prefix_digest: String::new(),
        parser: Parser::new(metadata.as_ref()),
        parser_revision: REVISION.into(),
    };
    let mut digest = Sha256::new();
    if let Some(mut cached) = cached.filter(|s| s.parser_revision == REVISION) {
        let mut remaining = cached.offset;
        let mut chunk = [0u8; 262144];
        while remaining > 0 {
            let count = reader
                .read(&mut chunk[..usize::try_from(remaining.min(262144)).unwrap()])
                .map_err(|e| e.to_string())?;
            if count == 0 {
                break;
            }
            digest.update(&chunk[..count]);
            remaining -= count as u64;
        }
        if remaining == 0 && format!("{:x}", digest.clone().finalize()) == cached.prefix_digest {
            cached.parser.excluded_subagent = cached.parser.explicit_subagent
                || known.iter().any(|s| hash(s) == cached.parser.session_key);
            state = cached;
        } else {
            reader.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
            digest = Sha256::new();
        }
    }
    let mut buffered = BufReader::with_capacity(65536, reader);
    loop {
        // read_until is bounded with Take: a corrupt single line cannot grow
        // memory unboundedly. Partial tails are retried on the next append.
        let mut line = Vec::new();
        (&mut buffered)
            .take(32 * 1024 * 1024 + 1)
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if line.len() > 32 * 1024 * 1024 {
            return Err("会话日志单行超过 32 MiB".into());
        }
        if line.last() != Some(&b'\n') {
            break;
        }
        state.parser.consume(&line[..line.len() - 1], known);
        digest.update(&line);
        state.offset += line.len() as u64;
        if state.parser.excluded_subagent {
            break;
        }
    }
    let after = buffered.get_ref().metadata().map_err(|e| e.to_string())?;
    if before.len() != after.len() || before.modified().ok() != after.modified().ok() {
        return Err("会话仍在写入，稍后继续".into());
    }
    state.prefix_digest = format!("{:x}", digest.finalize());
    Ok(state)
}
