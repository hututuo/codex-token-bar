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
            five_hour_used_percent INTEGER,
            five_hour_resets_at REAL,
            seven_day_used_percent INTEGER,
            seven_day_resets_at REAL,
            status TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_created_at ON quota_snapshots(created_at);
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_account_created ON quota_snapshots(account_key, created_at);
        "#,
    )
}

pub(super) fn insert_row(connection: &Connection, row: &QuotaHistoryRow) -> SqlResult<()> {
    connection.execute(
        r#"
        INSERT INTO quota_snapshots (
            created_at, account_key, plan_type, limit_name, account_name,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
        "#,
        params![
            row.created_at,
            row.account_key,
            row.plan_type,
            row.limit_name,
            row.account_name,
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
    account_key: &str,
) -> SqlResult<Option<QuotaHistoryRow>> {
    let rows = query_rows(
        connection,
        r#"
        SELECT created_at, account_key, plan_type, limit_name, account_name,
               five_hour_used_percent, five_hour_resets_at,
               seven_day_used_percent, seven_day_resets_at, status
        FROM quota_snapshots
        WHERE account_key = ?1
        ORDER BY created_at DESC;
        "#,
        [account_key],
    )?;
    Ok(sanitized_rows(rows.into_iter().rev().collect()).pop())
}

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
    if let Some(account_name) = filter.account_name.as_ref().filter(|value| !value.trim().is_empty()) {
        query_rows(
            connection,
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE created_at >= ?1
              AND (
                account_key = ?2
                OR (
                  account_name = ?3
                  AND (?4 IS NULL OR lower(coalesce(plan_type, '')) = lower(?4))
                  AND (
                    ?5 IS NULL
                    OR limit_name = ?5
                    OR (?5 = 'codex' AND coalesce(limit_name, '') = '')
                  )
                )
              )
            ORDER BY created_at ASC;
            "#,
            params![
                cutoff,
                filter.account_key,
                account_name,
                filter.plan_type,
                filter.limit_name
            ],
        )
    } else {
        query_rows(
            connection,
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE account_key = ?1 AND created_at >= ?2
            ORDER BY created_at ASC;
            "#,
            params![filter.account_key, cutoff],
        )
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

fn latest_account_filter(connection: &Connection) -> SqlResult<Option<AccountHistoryFilter>> {
    connection
        .query_row(
            r#"
            SELECT account_key, plan_type, limit_name, account_name
            FROM quota_snapshots
            ORDER BY created_at DESC
            LIMIT 1;
            "#,
            [],
            |row| {
                Ok(AccountHistoryFilter {
                    account_key: row.get(0)?,
                    plan_type: row.get(1)?,
                    limit_name: row.get(2)?,
                    account_name: row.get(3)?,
                })
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
            five_hour_used_percent: row.get(5)?,
            five_hour_resets_at: row.get(6)?,
            seven_day_used_percent: row.get(7)?,
            seven_day_resets_at: row.get(8)?,
            status: row.get(9)?,
        })
    })?;
    rows.collect()
}
