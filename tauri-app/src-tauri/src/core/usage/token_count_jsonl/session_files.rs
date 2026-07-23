use super::UsageScanLimitError;
use crate::core::sqlite;
use crate::models::LocalDataWarning;
use rusqlite::Connection;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub(super) const MAX_SESSION_FILE_COUNT: usize = 20_000;

pub(super) fn jsonl_files_for_codex_home(
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<Vec<PathBuf>, UsageScanLimitError> {
    let mut files = Vec::new();
    let mut visited_directories = HashSet::new();
    let sessions_root = codex_home.join("sessions");
    if sessions_root.exists() {
        collect_jsonl_files(
            &sessions_root,
            &mut files,
            &mut visited_directories,
            warnings,
        )?;
    } else {
        warnings.push(jsonl_scan_warning(format!(
            "会话目录不存在：{}",
            sessions_root.display()
        )));
    }
    collect_state_rollout_files(codex_home, &mut files, warnings)?;
    Ok(deduplicate_files(files))
}

fn deduplicate_files(files: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut deduped = Vec::new();
    for file in files {
        let key = fs::canonicalize(&file).unwrap_or_else(|_| file.clone());
        if seen.insert(key) {
            deduped.push(file);
        }
    }
    deduped.sort();
    deduped
}

fn collect_state_rollout_files(
    codex_home: &Path,
    files: &mut Vec<PathBuf>,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<(), UsageScanLimitError> {
    let database = codex_home.join("state_5.sqlite");
    if !database.exists() {
        return Ok(());
    }
    let connection = match sqlite::open_read_only(&database, Duration::from_millis(100)) {
        Ok(connection) => connection,
        Err(error) => {
            let message = format!(
                "读取 active rollout 索引失败：{}（{}）",
                database.display(),
                error
            );
            warnings.push(jsonl_scan_warning(message.clone()));
            return Err(UsageScanLimitError::new(message));
        }
    };
    if !column_exists(&connection, "threads", "rollout_path") {
        return Ok(());
    }

    let archived_filter = if column_exists(&connection, "threads", "archived") {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let sql = format!(
        r#"
        SELECT rollout_path
        FROM threads
        WHERE {archived_filter}
          AND rollout_path IS NOT NULL
          AND rollout_path <> '';
        "#
    );
    let mut statement = match connection.prepare(&sql) {
        Ok(statement) => statement,
        Err(error) => {
            let message = format!(
                "读取 active rollout 路径失败：{}（{}）",
                database.display(),
                error
            );
            warnings.push(jsonl_scan_warning(message.clone()));
            return Err(UsageScanLimitError::new(message));
        }
    };
    let rows = match statement.query_map([], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(error) => {
            let message = format!(
                "读取 active rollout 路径失败：{}（{}）",
                database.display(),
                error
            );
            warnings.push(jsonl_scan_warning(message.clone()));
            return Err(UsageScanLimitError::new(message));
        }
    };
    for row in rows {
        let row = row.map_err(|error| {
            let message = format!(
                "读取 active rollout 路径失败：{}（{}）",
                database.display(),
                error
            );
            warnings.push(jsonl_scan_warning(message.clone()));
            UsageScanLimitError::new(message)
        })?;
        let path = normalize_rollout_path(codex_home, row);
        if path.is_file()
            && path
                .extension()
                .is_some_and(|extension| extension == "jsonl")
        {
            push_session_file(files, path)?;
        }
    }
    Ok(())
}

fn normalize_rollout_path(codex_home: &Path, rollout_path: String) -> PathBuf {
    let path = PathBuf::from(rollout_path);
    if path.is_absolute() {
        path
    } else {
        codex_home.join(path)
    }
}

fn column_exists(connection: &Connection, table: &str, column: &str) -> bool {
    let Ok(mut statement) = connection.prepare(&format!("PRAGMA table_info({table})")) else {
        return false;
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(1)) else {
        return false;
    };

    let exists = rows.filter_map(Result::ok).any(|name| name == column);
    exists
}

fn collect_jsonl_files(
    root: &Path,
    files: &mut Vec<PathBuf>,
    visited_directories: &mut HashSet<PathBuf>,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<(), UsageScanLimitError> {
    let directory_key = fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    if !visited_directories.insert(directory_key) {
        return Ok(());
    }
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) => {
            let message = format!(
                "读取会话目录失败：{}（{}）",
                root.display(),
                error
            );
            warnings.push(jsonl_scan_warning(message.clone()));
            return Err(UsageScanLimitError::new(message));
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                let message = format!(
                    "读取会话目录项失败：{}（{}）",
                    root.display(),
                    error
                );
                warnings.push(jsonl_scan_warning(message.clone()));
                return Err(UsageScanLimitError::new(message));
            }
        };
        let path = entry.path();
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                let message = format!(
                    "读取会话目录项元数据失败：{}（{}）",
                    path.display(),
                    error
                );
                warnings.push(jsonl_scan_warning(message.clone()));
                return Err(UsageScanLimitError::new(message));
            }
        };
        if metadata.file_type().is_dir() {
            collect_jsonl_files(&path, files, visited_directories, warnings)?;
        } else if path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
        {
            push_session_file(files, path)?;
        }
    }
    Ok(())
}

fn push_session_file(files: &mut Vec<PathBuf>, path: PathBuf) -> Result<(), UsageScanLimitError> {
    if files.len() >= MAX_SESSION_FILE_COUNT {
        return Err(UsageScanLimitError::new(format!(
            "会话文件数量超过安全上限（{} 个）",
            MAX_SESSION_FILE_COUNT
        )));
    }
    files.push(path);
    Ok(())
}

pub(super) fn session_id_from_file(file: &Path) -> String {
    let stem = file
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    let parts: Vec<&str> = stem.split('-').collect();
    let start = parts.len().saturating_sub(5);
    parts[start..].join("-")
}

fn jsonl_scan_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "jsonl_scan".into(),
        message,
    }
}
