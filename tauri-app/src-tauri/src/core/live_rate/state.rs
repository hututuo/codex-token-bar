use crate::core::sqlite;
use crate::models::LiveThreadOption;
use rusqlite::{params, Connection, Result};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(test)]
#[path = "state_tests.rs"]
mod tests;

#[derive(Clone, Default)]
pub(super) struct UsageSummary {
    pub(super) total_tokens: u64,
    pub(super) today_tokens: u64,
    pub(super) today_requests: u32,
}

#[derive(Clone, Debug)]
pub(super) struct RolloutThread {
    pub(super) id: String,
    pub(super) rollout_path: PathBuf,
    pub(super) thread_source: String,
}

pub(super) fn read_thread_options_result(
    codex_home: &Path,
    limit: usize,
) -> Result<Vec<LiveThreadOption>> {
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;
    let columns = ThreadColumns::read(&connection)?;

    let archived_filter = if columns.contains("archived") {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let source_filter = if columns.contains("thread_source") {
        "COALESCE(thread_source, 'user') != 'subagent'"
    } else {
        "1 = 1"
    };
    let title_expression = if columns.contains("name") {
        "COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(title), ''), '')"
    } else {
        "title"
    };
    let first_message = columns.optional("first_user_message");
    let preview = columns.optional("preview");
    let updated_ms = columns.updated_ms()?;
    let sql = format!(
        r#"
        SELECT id, {title_expression}, {first_message}, {preview},
               strftime(
                 '%m/%d %H:%M',
                 ({updated_ms}) / 1000,
                 'unixepoch',
                 'localtime'
               ) AS updated_label,
               tokens_used
        FROM threads
        WHERE {archived_filter}
          AND {source_filter}
        ORDER BY {updated_ms} DESC, id ASC
        LIMIT ?1;
        "#,
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![limit as i64], |row| {
        let id: String = row.get(0)?;
        let title = row.get::<_, Option<String>>(1)?.unwrap_or_default();
        let first_message = row.get::<_, Option<String>>(2)?.unwrap_or_default();
        let preview = row.get::<_, Option<String>>(3)?.unwrap_or_default();
        let updated_at = row.get::<_, Option<String>>(4)?.unwrap_or_default();
        let tokens_used = row.get::<_, Option<i64>>(5)?.unwrap_or_default();
        Ok(LiveThreadOption {
            id,
            title: best_thread_label(&[&title, &first_message, &preview]),
            subtitle: best_thread_subtitle(&title, &first_message, &preview),
            updated_at,
            tokens_used: u64::try_from(tokens_used).unwrap_or(0),
        })
    })?;

    rows.collect()
}

pub(super) fn read_recent_rollout_threads(
    codex_home: &Path,
    limit: usize,
) -> Result<Vec<RolloutThread>> {
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;
    let columns = ThreadColumns::read(&connection)?;
    if !columns.contains("rollout_path") {
        return Ok(Vec::new());
    }

    let archived_filter = if columns.contains("archived") {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let source_expression = if columns.contains("thread_source") {
        "COALESCE(thread_source, 'user')"
    } else {
        "'user'"
    };
    let updated_ms = columns.updated_ms()?;
    let sql = format!(
        r#"
        SELECT id, rollout_path, {source_expression}
        FROM threads
        WHERE {archived_filter}
          AND rollout_path IS NOT NULL
          AND rollout_path <> ''
        ORDER BY {updated_ms} DESC, id ASC
        LIMIT ?1;
        "#,
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![limit as i64], |row| {
        let id: String = row.get(0)?;
        let rollout_path: String = row.get(1)?;
        let thread_source: String = row.get(2)?;
        Ok(RolloutThread {
            id,
            rollout_path: normalize_rollout_path(codex_home, rollout_path),
            thread_source,
        })
    })?;

    rows.collect()
}

pub(super) fn read_thread_title(codex_home: &Path, thread_id: &str) -> Result<Option<String>> {
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;
    let columns = ThreadColumns::read(&connection)?;
    let name_expression = columns.optional("name");
    let first_message = columns.optional("first_user_message");
    let sql = format!(
        "SELECT {name_expression}, title, {first_message} FROM threads WHERE id = ?1 LIMIT 1;"
    );
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(params![thread_id])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };

    let name = compact_title(&row.get::<_, Option<String>>(0)?.unwrap_or_default());
    if !name.is_empty() {
        return Ok(Some(name));
    }
    let title = row.get::<_, Option<String>>(1)?.unwrap_or_default();
    let first_message = row.get::<_, Option<String>>(2)?.unwrap_or_default();
    // Codex often fills title with the first prompt before it has a real name.
    if !title.trim().is_empty() && title.trim() != first_message.trim() {
        return Ok(Some(compact_title(&title)));
    }
    Ok(None)
}

pub(super) fn read_thread_titles(
    codex_home: &Path,
    thread_ids: &[String],
) -> Result<HashMap<String, String>> {
    let mut titles = HashMap::new();
    if thread_ids.is_empty() {
        return Ok(titles);
    }
    let connection = open_read_only(&codex_home.join("state_5.sqlite"))?;
    let columns = ThreadColumns::read(&connection)?;
    let name_expression = columns.optional("name");
    let first_message = columns.optional("first_user_message");
    for chunk in thread_ids.chunks(400) {
        let placeholders = std::iter::repeat("?")
            .take(chunk.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT id, {name_expression}, title, {first_message} FROM threads WHERE id IN ({placeholders});"
        );
        let mut statement = connection.prepare(&sql)?;
        let mut rows =
            statement.query(rusqlite::params_from_iter(chunk.iter().map(String::as_str)))?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let name = compact_title(&row.get::<_, Option<String>>(1)?.unwrap_or_default());
            if !name.is_empty() {
                titles.insert(id, name);
                continue;
            }
            let title = row.get::<_, Option<String>>(2)?.unwrap_or_default();
            let first_message = row.get::<_, Option<String>>(3)?.unwrap_or_default();
            if !title.trim().is_empty() && title.trim() != first_message.trim() {
                titles.insert(id, compact_title(&title));
            }
        }
    }
    Ok(titles)
}

struct ThreadColumns(HashSet<String>);

impl ThreadColumns {
    fn read(connection: &Connection) -> Result<Self> {
        let mut statement = connection.prepare("PRAGMA table_info(threads)")?;
        let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
        Ok(Self(columns.collect::<Result<_>>()?))
    }

    fn contains(&self, column: &str) -> bool {
        self.0.contains(column)
    }

    fn optional(&self, column: &'static str) -> &'static str {
        if self.contains(column) {
            column
        } else {
            "NULL"
        }
    }

    fn updated_ms(&self) -> Result<String> {
        // The upstream millisecond migration accepts legacy timestamps in either
        // unit. A NULL new field still falls back to the original timestamp.
        let seconds =
            "CASE WHEN updated_at > 9999999999 THEN updated_at ELSE updated_at * 1000 END";
        match (self.contains("updated_at_ms"), self.contains("updated_at")) {
            (true, true) => Ok(format!("COALESCE(updated_at_ms, {seconds})")),
            (true, false) => Ok("updated_at_ms".into()),
            (false, true) => Ok(seconds.into()),
            (false, false) => Err(rusqlite::Error::InvalidColumnName(
                "updated_at / updated_at_ms".into(),
            )),
        }
    }
}

fn best_thread_label(values: &[&str]) -> String {
    values
        .iter()
        .map(|value| compact_title(value))
        .find(|value| !value.is_empty())
        .unwrap_or_else(|| "无标题会话".into())
}

fn best_thread_subtitle(title: &str, first_message: &str, preview: &str) -> String {
    let title = compact_title(title);
    for value in [first_message, preview] {
        let cleaned = compact_title(value);
        if !cleaned.is_empty() && cleaned != title {
            return cleaned;
        }
    }
    "最近会话".into()
}

fn compact_title(value: &str) -> String {
    let mut title = value.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_CHARS: usize = 88;
    if title.chars().count() > MAX_CHARS {
        title = title.chars().take(MAX_CHARS).collect::<String>();
        title.push('…');
    }
    title
}

fn normalize_rollout_path(codex_home: &Path, rollout_path: String) -> PathBuf {
    let path = PathBuf::from(rollout_path);
    if path.is_absolute() {
        path
    } else {
        codex_home.join(path)
    }
}

fn open_read_only(path: &Path) -> Result<Connection> {
    sqlite::open_read_only(path, Duration::from_millis(100))
}
