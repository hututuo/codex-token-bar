use super::series::sanitized_rows;
use super::{now_unix, QuotaHistoryRow, RETENTION_DAYS};
use rusqlite::{params, Connection, OptionalExtension, Result as SqlResult};

pub(super) fn ensure_schema(connection: &Connection) -> SqlResult<()> {
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS quota_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            account_key TEXT NOT NULL,
            plan_type TEXT,
            limit_name TEXT,
            account_name TEXT,
            source TEXT,
            five_hour_used_percent INTEGER,
            five_hour_resets_at REAL,
            seven_day_used_percent INTEGER,
            seven_day_resets_at REAL,
            status TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_created_at ON quota_snapshots(created_at);
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_account_created ON quota_snapshots(account_key, created_at);
        "#,
    )?;
    ensure_column(connection, "source", "TEXT")?;
    Ok(())
}

pub(super) fn insert_row(connection: &Connection, row: &QuotaHistoryRow) -> SqlResult<()> {
    connection.execute(
        r#"
        INSERT INTO quota_snapshots (
            created_at, account_key, plan_type, limit_name, account_name, source,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
        "#,
        params![
            row.created_at,
            row.account_key,
            row.plan_type,
            row.limit_name,
            row.account_name,
            row.source,
            row.five_hour_used_percent,
            row.five_hour_resets_at,
            row.seven_day_used_percent,
            row.seven_day_resets_at,
            row.status
        ],
    )?;
    Ok(())
}

pub(super) fn latest_trusted_row(
    connection: &Connection,
    row: &QuotaHistoryRow,
) -> SqlResult<Option<QuotaHistoryRow>> {
    let filter = AccountHistoryFilter::from_row(row);
    let rows = matching_rows(connection, &filter, None, "DESC")?;
    Ok(sanitized_rows(rows.into_iter().rev().collect()).pop())
}

#[cfg(test)]
pub(super) fn recent_rows(connection: &Connection) -> SqlResult<Vec<QuotaHistoryRow>> {
    rows_since(connection, 31.0 * 24.0 * 60.0 * 60.0)
}

pub(super) fn rows_since(
    connection: &Connection,
    age_seconds: f64,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    let Some(filter) = latest_account_filter(connection)? else {
        return Ok(Vec::new());
    };
    let cutoff = now_unix() - age_seconds;
    matching_rows(connection, &filter, Some(cutoff), "ASC")
}

fn matching_rows(
    connection: &Connection,
    filter: &AccountHistoryFilter,
    cutoff: Option<f64>,
    order: &str,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    if let Some(account_name) = filter.account_name.as_ref().filter(|value| !value.trim().is_empty()) {
        if let Some(cutoff) = cutoff {
            query_rows(
                connection,
                &format!(
                    r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE (
              account_key = ?1
              OR (
                account_name = ?2
                AND (
                  ?3 IS NULL
                  OR lower(coalesce(plan_type, '')) = lower(?3)
                  OR (
                    lower(?3) <> 'pro'
                    AND lower(coalesce(plan_type, '')) = 'pro'
                    AND lower(coalesce(limit_name, '')) = 'codex'
                    AND lower(coalesce(source, 'tauri')) = 'tauri'
                  )
                )
                AND (
                  ?4 IS NULL
                  OR lower(coalesce(limit_name, '')) = lower(?4)
                  OR (?4 = 'codex' AND coalesce(limit_name, '') = '')
                )
              )
            )
            AND created_at >= ?5
            ORDER BY created_at {order};
            "#
                ),
                params![
                    filter.account_key,
                    account_name,
                    filter.plan_type,
                    filter.limit_name,
                    cutoff
                ],
            )
        } else {
            query_rows(
                connection,
                &format!(
                    r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE (
              account_key = ?1
              OR (
                account_name = ?2
                AND (
                  ?3 IS NULL
                  OR lower(coalesce(plan_type, '')) = lower(?3)
                  OR (
                    lower(?3) <> 'pro'
                    AND lower(coalesce(plan_type, '')) = 'pro'
                    AND lower(coalesce(limit_name, '')) = 'codex'
                    AND lower(coalesce(source, 'tauri')) = 'tauri'
                  )
                )
                AND (
                  ?4 IS NULL
                  OR lower(coalesce(limit_name, '')) = lower(?4)
                  OR (?4 = 'codex' AND coalesce(limit_name, '') = '')
                )
              )
            )
            ORDER BY created_at {order};
            "#
                ),
                params![
                    filter.account_key,
                    account_name,
                    filter.plan_type,
                    filter.limit_name
                ],
            )
        }
    } else {
        if let Some(cutoff) = cutoff {
            query_rows(
                connection,
                &format!(
                    r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE account_key = ?1
            AND created_at >= ?2
            ORDER BY created_at {order};
            "#
                ),
                params![filter.account_key, cutoff],
            )
        } else {
            query_rows(
                connection,
                &format!(
                    r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE account_key = ?1
            ORDER BY created_at {order};
            "#
                ),
                params![filter.account_key],
            )
        }
    }
}

pub(super) fn prune(connection: &Connection, now: f64) -> SqlResult<()> {
    let cutoff = now - RETENTION_DAYS as f64 * 24.0 * 60.0 * 60.0;
    connection.execute(
        "DELETE FROM quota_snapshots WHERE created_at < ?1;",
        params![cutoff],
    )?;
    Ok(())
}

struct AccountHistoryFilter {
    account_key: String,
    plan_type: Option<String>,
    limit_name: Option<String>,
    account_name: Option<String>,
}

impl AccountHistoryFilter {
    fn from_row(row: &QuotaHistoryRow) -> Self {
        Self {
            account_key: row.history_match_key(),
            plan_type: row.match_plan_type(),
            limit_name: row.match_limit_name(),
            account_name: row.match_account_name(),
        }
    }
}

fn latest_account_filter(connection: &Connection) -> SqlResult<Option<AccountHistoryFilter>> {
    connection
        .query_row(
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            ORDER BY created_at DESC
            LIMIT 1;
            "#,
            [],
            |row| {
                let row = QuotaHistoryRow {
                    created_at: row.get(0)?,
                    account_key: row.get(1)?,
                    plan_type: row.get(2)?,
                    limit_name: row.get(3)?,
                    account_name: row.get(4)?,
                    source: row.get(5)?,
                    five_hour_used_percent: row.get(6)?,
                    five_hour_resets_at: row.get(7)?,
                    seven_day_used_percent: row.get(8)?,
                    seven_day_resets_at: row.get(9)?,
                    status: row.get(10)?,
                };
                Ok(AccountHistoryFilter::from_row(&row))
            },
        )
        .optional()
}

fn query_rows<P>(connection: &Connection, sql: &str, params: P) -> SqlResult<Vec<QuotaHistoryRow>>
where
    P: rusqlite::Params,
{
    let mut statement = connection.prepare(sql)?;
    let rows = statement.query_map(params, |row| {
        Ok(QuotaHistoryRow {
            created_at: row.get(0)?,
            account_key: row.get(1)?,
            plan_type: row.get(2)?,
            limit_name: row.get(3)?,
            account_name: row.get(4)?,
            source: row.get(5)?,
            five_hour_used_percent: row.get(6)?,
            five_hour_resets_at: row.get(7)?,
            seven_day_used_percent: row.get(8)?,
            seven_day_resets_at: row.get(9)?,
            status: row.get(10)?,
        })
    })?;
    rows.collect()
}

fn ensure_column(connection: &Connection, name: &str, definition: &str) -> SqlResult<()> {
    let mut statement = connection.prepare("PRAGMA table_info(quota_snapshots);")?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<SqlResult<Vec<_>>>()?;
    if !columns.iter().any(|column| column == name) {
        connection.execute(&format!("ALTER TABLE quota_snapshots ADD COLUMN {name} {definition};"), [])?;
    }
    Ok(())
}
