use super::{provider_for_mutation, validated_provider_candidate};
use crate::core::sqlite;
use rusqlite::{Connection, Result as SqlResult};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Default)]
pub(super) struct SQLiteScan {
    pub(super) provider_counts: Vec<SQLiteProviderCount>,
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
            integrity: sqlite_integrity(&connection).unwrap_or_else(|_| "unknown".into()),
            ..SQLiteScan::default()
        });
    }

    let provider_counts = sqlite_provider_counts(&connection, &columns)?;
    let latest_unarchived = latest_sqlite_provider(&connection, &columns)?;
    let (latest_unarchived_provider, latest_unarchived_thread_id) = match latest_unarchived {
        Some(row) => (
            validated_provider_candidate(&row.provider),
            Some(row.thread_id),
        ),
        None => (None, None),
    };
    Ok(SQLiteScan {
        provider_counts,
        latest_unarchived_provider,
        latest_unarchived_thread_id,
        integrity: sqlite_integrity(&connection).unwrap_or_else(|_| "unknown".into()),
    })
}

pub(super) fn sync_sqlite_provider(
    codex_home: &Path,
    target_provider: &str,
) -> Result<u32, String> {
    let target_provider = provider_for_mutation(target_provider)?;
    let db_path = codex_home.join("state_5.sqlite");
    if !db_path.exists() {
        return Ok(0);
    }
    let connection = sqlite::open_read_write(&db_path, Duration::from_secs(2))
        .map_err(|error| error.to_string())?;
    let columns = thread_columns(&connection).map_err(|error| error.to_string())?;
    if !columns.contains("model_provider") {
        return Ok(0);
    }
    let changed = connection
        .execute(
            "UPDATE threads SET model_provider = ?1 WHERE COALESCE(model_provider, '') <> ?1;",
            [target_provider.as_str()],
        )
        .map_err(|error| error.to_string())?;
    sqlite::checkpoint_wal_full(&connection);
    let integrity = sqlite_integrity(&connection).map_err(|error| error.to_string())?;
    if integrity != "ok" {
        return Err(format!("SQLite integrity_check: {integrity}"));
    }
    Ok(u32::try_from(changed).unwrap_or(u32::MAX))
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
        .query_row(&sql, [thread_id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .map_err(|error| error.to_string())?;
    Ok(json!({
        "id": id,
        "thread_name": title,
        "updated_at": format_unix_millis_rfc3339(updated_ms)
    }))
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
    sqlite::open_read_only(path, Duration::from_millis(250))
}

fn format_unix_millis_rfc3339(millis: i64) -> String {
    let seconds = if millis > 10_000_000_000 { millis / 1000 } else { millis };
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
