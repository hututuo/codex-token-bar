use crate::models::{ProviderRepairSnapshot, ProviderRepairStep};
use rusqlite::{Connection, OpenFlags, Result as SqlResult};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub fn scan_provider_repair(codex_home: &Path) -> ProviderRepairSnapshot {
    match scan_provider_repair_result(codex_home) {
        Ok(report) => snapshot_from_report(report),
        Err(error) => error_snapshot(codex_home, error.to_string()),
    }
}

fn scan_provider_repair_result(codex_home: &Path) -> Result<ProviderRepairReport, String> {
    let session_files = find_session_files(codex_home, true);
    let session_scan = scan_session_providers(&session_files);
    let sqlite_scan = scan_sqlite(codex_home).unwrap_or_else(|error| SQLiteScan {
        integrity: format!("读取失败：{error}"),
        ..SQLiteScan::default()
    });
    let session_index = scan_session_index(codex_home);
    let target = detect_target_provider(codex_home, &sqlite_scan, &session_scan);
    let session_mismatches = session_scan.count_provider_mismatches(&target.provider);
    let index_missing = latest_thread_index_missing(&sqlite_scan, &session_index);
    let inconsistent_count = session_mismatches
        + sqlite_scan.rows_to_repair(&target.provider)
        + session_scan.invalid_files
        + u32::from(index_missing);

    Ok(ProviderRepairReport {
        codex_home: codex_home.to_path_buf(),
        target,
        session_scan,
        sqlite_scan,
        session_index,
        session_mismatches,
        index_missing,
        inconsistent_count,
    })
}

fn detect_target_provider(
    codex_home: &Path,
    sqlite_scan: &SQLiteScan,
    session_scan: &SessionScan,
) -> TargetProvider {
    if let Some(provider) = config_provider(codex_home) {
        return TargetProvider {
            provider,
            source: "config.toml".into(),
        };
    }
    if let Some(provider) = sqlite_scan.latest_unarchived_provider.clone() {
        return TargetProvider {
            provider,
            source: "SQLite 最新会话".into(),
        };
    }
    if let Some(provider) = session_scan.newest_provider.clone() {
        return TargetProvider {
            provider,
            source: "最新 JSONL".into(),
        };
    }
    TargetProvider {
        provider: "openai".into(),
        source: "默认 openai".into(),
    }
}

fn config_provider(codex_home: &Path) -> Option<String> {
    let text = fs::read_to_string(codex_home.join("config.toml")).ok()?;
    for raw_line in text.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        let Some(value) = line.strip_prefix("model_provider") else {
            continue;
        };
        let Some((_, assigned)) = value.split_once('=') else {
            continue;
        };
        let trimmed = assigned.trim();
        let provider = trimmed
            .strip_prefix('"')
            .and_then(|value| value.split('"').next())
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if let Some(provider) = provider {
            return Some(provider.to_string());
        }
    }
    None
}

fn find_session_files(codex_home: &Path, include_archived: bool) -> Vec<PathBuf> {
    let mut roots = vec![codex_home.join("sessions")];
    if include_archived {
        roots.push(codex_home.join("archived_sessions"));
    }
    let mut files = Vec::new();
    for root in roots {
        collect_jsonl_files(&root, &mut files);
    }
    files.sort();
    files
}

fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>) {
    let Ok(metadata) = fs::metadata(root) else {
        return;
    };
    if metadata.is_file() {
        if root.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(root.to_path_buf());
        }
        return;
    }

    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        collect_jsonl_files(&entry.path(), files);
    }
}

fn scan_session_providers(files: &[PathBuf]) -> SessionScan {
    let mut provider_counts = HashMap::<String, u32>::new();
    let mut invalid_files = 0;
    let mut newest_provider = None;
    let mut newest_modified = None;

    for file in files {
        match read_session_provider(file) {
            Ok(Some(provider)) => {
                *provider_counts.entry(provider.clone()).or_insert(0) += 1;
                let modified = fs::metadata(file).and_then(|metadata| metadata.modified()).ok();
                if newest_modified.is_none_or(|current| modified.is_some_and(|next| next > current)) {
                    newest_modified = modified;
                    newest_provider = Some(provider);
                }
            }
            Ok(None) | Err(_) => invalid_files += 1,
        }
    }

    SessionScan {
        files_found: u32::try_from(files.len()).unwrap_or(u32::MAX),
        provider_counts,
        invalid_files,
        newest_provider,
    }
}

fn read_session_provider(file: &Path) -> Result<Option<String>, String> {
    let file = fs::File::open(file).map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    if read == 0 {
        return Ok(None);
    }

    let value: Value = serde_json::from_str(line.trim_end()).map_err(|error| error.to_string())?;
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return Ok(None);
    }
    let provider = value
        .get("payload")
        .and_then(|payload| payload.get("model_provider"))
        .and_then(Value::as_str)
        .unwrap_or("(missing)")
        .to_string();
    Ok(Some(provider))
}

fn scan_sqlite(codex_home: &Path) -> SqlResult<SQLiteScan> {
    let db_path = codex_home.join("state_5.sqlite");
    let connection = open_read_only(&db_path)?;
    connection.busy_timeout(Duration::from_millis(250))?;
    let columns = thread_columns(&connection)?;
    if !columns.contains("model_provider") {
        return Ok(SQLiteScan {
            integrity: sqlite_integrity(&connection).unwrap_or_else(|_| "unknown".into()),
            ..SQLiteScan::default()
        });
    }

    let provider_counts = sqlite_provider_counts(&connection, &columns)?;
    let latest_unarchived = latest_sqlite_provider(&connection, &columns)?;
    let (latest_unarchived_provider, latest_unarchived_thread_id) = match latest_unarchived {
        Some(row) => (Some(row.provider), Some(row.thread_id)),
        None => (None, None),
    };
    Ok(SQLiteScan {
        provider_counts,
        latest_unarchived_provider,
        latest_unarchived_thread_id,
        integrity: sqlite_integrity(&connection).unwrap_or_else(|_| "unknown".into()),
    })
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
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
}

fn scan_session_index(codex_home: &Path) -> SessionIndexScan {
    let path = codex_home.join("session_index.jsonl");
    let Ok(text) = fs::read_to_string(path) else {
        return SessionIndexScan::default();
    };

    let mut ids = HashSet::new();
    let mut rows = 0;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        rows += 1;
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            if let Some(id) = value.get("id").and_then(Value::as_str) {
                ids.insert(id.to_string());
            }
        }
    }
    SessionIndexScan { ids, rows }
}

fn latest_thread_index_missing(sqlite_scan: &SQLiteScan, session_index: &SessionIndexScan) -> bool {
    sqlite_scan
        .latest_unarchived_thread_id
        .as_ref()
        .is_some_and(|thread_id| !session_index.ids.contains(thread_id))
}

fn snapshot_from_report(report: ProviderRepairReport) -> ProviderRepairSnapshot {
    let sqlite_mismatches = report.sqlite_scan.rows_to_repair(&report.target.provider);
    let index_issue = u32::from(report.index_missing);
    let status = if report.inconsistent_count == 0 {
        format!(
            "扫描完成：未发现不一致。SQLite {}，session_index {} 行。",
            report.sqlite_scan.integrity, report.session_index.rows
        )
    } else {
        format!(
            "扫描完成：发现 {} 条不一致（JSONL {}，SQLite {}，异常文件 {}，索引 {}）。",
            report.inconsistent_count,
            report.session_mismatches,
            sqlite_mismatches,
            report.session_scan.invalid_files,
            index_issue
        )
    };

    ProviderRepairSnapshot {
        detected_provider: report.target.provider.clone(),
        provider_source: report.target.source.clone(),
        session_files_found: report.session_scan.files_found,
        inconsistent_count: report.inconsistent_count,
        status,
        steps: vec![
            ProviderRepairStep {
                label: "扫描".into(),
                status: if report.inconsistent_count == 0 {
                    "未发现不一致".into()
                } else {
                    format!("发现 {} 条不一致", report.inconsistent_count)
                },
                done: true,
                healthy: report.inconsistent_count == 0,
            },
            ProviderRepairStep {
                label: "备份".into(),
                status: "未备份".into(),
                done: false,
                healthy: true,
            },
            ProviderRepairStep {
                label: "修复".into(),
                status: if report.inconsistent_count == 0 {
                    "暂无需修复".into()
                } else {
                    "未进行修复".into()
                },
                done: false,
                healthy: report.inconsistent_count == 0,
            },
            ProviderRepairStep {
                label: "验证".into(),
                status: "未验证".into(),
                done: false,
                healthy: report.inconsistent_count == 0,
            },
        ],
    }
}

fn error_snapshot(codex_home: &Path, message: String) -> ProviderRepairSnapshot {
    ProviderRepairSnapshot {
        detected_provider: "openai".into(),
        provider_source: "读取失败".into(),
        session_files_found: 0,
        inconsistent_count: 1,
        status: format!("扫描失败：{message}"),
        steps: vec![
            ProviderRepairStep {
                label: "扫描".into(),
                status: format!("读取失败：{}", codex_home.display()),
                done: true,
                healthy: false,
            },
            ProviderRepairStep {
                label: "备份".into(),
                status: "未备份".into(),
                done: false,
                healthy: true,
            },
            ProviderRepairStep {
                label: "修复".into(),
                status: "未进行修复".into(),
                done: false,
                healthy: false,
            },
            ProviderRepairStep {
                label: "验证".into(),
                status: "未验证".into(),
                done: false,
                healthy: false,
            },
        ],
    }
}

fn provider_or_missing(value: String) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        "(missing)".into()
    } else {
        trimmed.into()
    }
}

struct ProviderRepairReport {
    #[allow(dead_code)]
    codex_home: PathBuf,
    target: TargetProvider,
    session_scan: SessionScan,
    sqlite_scan: SQLiteScan,
    session_index: SessionIndexScan,
    session_mismatches: u32,
    index_missing: bool,
    inconsistent_count: u32,
}

struct TargetProvider {
    provider: String,
    source: String,
}

struct SessionScan {
    files_found: u32,
    provider_counts: HashMap<String, u32>,
    invalid_files: u32,
    newest_provider: Option<String>,
}

impl SessionScan {
    fn count_provider_mismatches(&self, target_provider: &str) -> u32 {
        self.provider_counts
            .iter()
            .filter(|(provider, _)| provider.as_str() != target_provider)
            .map(|(_, count)| *count)
            .sum()
    }
}

#[derive(Default)]
struct SQLiteScan {
    provider_counts: Vec<SQLiteProviderCount>,
    latest_unarchived_provider: Option<String>,
    latest_unarchived_thread_id: Option<String>,
    integrity: String,
}

impl SQLiteScan {
    fn rows_to_repair(&self, target_provider: &str) -> u32 {
        self.provider_counts
            .iter()
            .filter(|row| row.provider != target_provider)
            .map(|row| row.count)
            .sum()
    }
}

struct SQLiteProviderCount {
    provider: String,
    #[allow(dead_code)]
    archived: i64,
    count: u32,
}

struct LatestSQLiteProvider {
    provider: String,
    thread_id: String,
}

#[derive(Default)]
struct SessionIndexScan {
    ids: HashSet<String>,
    rows: u32,
}

#[cfg(test)]
#[path = "provider_repair_tests.rs"]
mod provider_repair_tests;
