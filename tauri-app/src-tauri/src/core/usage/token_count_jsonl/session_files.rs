use crate::models::LocalDataWarning;
use crate::core::sqlite;
use rusqlite::Connection;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub(super) fn jsonl_files_for_codex_home(
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let sessions_root = codex_home.join("sessions");
    if sessions_root.exists() {
        collect_jsonl_files(&sessions_root, &mut files, warnings);
    } else {
        warnings.push(jsonl_scan_warning(format!(
            "会话目录不存在：{}",
            sessions_root.display()
        )));
    }
    collect_state_rollout_files(codex_home, &mut files, warnings);
    deduplicate_files(files)
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
) {
    let database = codex_home.join("state_5.sqlite");
    if !database.exists() {
        return;
    }
    let connection = match sqlite::open_read_only(&database, Duration::from_millis(100)) {
        Ok(connection) => connection,
        Err(error) => {
            warnings.push(jsonl_scan_warning(format!(
                "读取 active rollout 索引失败：{}（{}）",
                database.display(),
                error
            )));
            return;
        }
    };
    if !column_exists(&connection, "threads", "rollout_path") {
        return;
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
            warnings.push(jsonl_scan_warning(format!(
                "读取 active rollout 路径失败：{}（{}）",
                database.display(),
                error
            )));
            return;
        }
    };
    let rows = match statement.query_map([], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(error) => {
            warnings.push(jsonl_scan_warning(format!(
                "读取 active rollout 路径失败：{}（{}）",
                database.display(),
                error
            )));
            return;
        }
    };
    for row in rows.flatten() {
        let path = normalize_rollout_path(codex_home, row);
        if path.is_file() && path.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(path);
        }
    }
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

fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>, warnings: &mut Vec<LocalDataWarning>) {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) => {
            warnings.push(jsonl_scan_warning(format!(
                "读取会话目录失败：{}（{}）",
                root.display(),
                error
            )));
            return;
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                warnings.push(jsonl_scan_warning(format!(
                    "读取会话目录项失败：{}（{}）",
                    root.display(),
                    error
                )));
                continue;
            }
        };
        let path = entry.path();
        if path.is_dir() {
            collect_jsonl_files(&path, files, warnings);
        } else if path.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(path);
        }
    }
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
