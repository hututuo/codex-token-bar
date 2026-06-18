use crate::models::{AccountQuotaBundle, QuotaHistoryPoint, QuotaSnapshot, RecentUsagePoint};
use rusqlite::{params, Connection, OptionalExtension, Result as SqlResult};
use std::collections::HashMap;
use std::path::PathBuf;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

const HEARTBEAT_SECONDS: f64 = 60.0 * 60.0;
const RETENTION_DAYS: i64 = 45;
const RECENT_INTERVAL_SECONDS: i64 = 5 * 60;
const RECENT_BIN_COUNT: usize = 288;
const MAX_CARRY_GAP_SECONDS: f64 = 90.0 * 60.0;

pub fn record_bundle(bundle: &AccountQuotaBundle) {
    if !quota_available(&bundle.quota) {
        return;
    }
    let Ok(database) = QuotaHistoryDatabase::default() else {
        return;
    };
    let _ = database.record(bundle);
}

pub fn recent_history_24h() -> Vec<QuotaHistoryPoint> {
    let Ok(database) = QuotaHistoryDatabase::default() else {
        return Vec::new();
    };
    database
        .recent_history_24h(RECENT_BIN_COUNT)
        .unwrap_or_default()
}

pub fn apply_recent_history(points: &mut [RecentUsagePoint]) {
    if points.is_empty() {
        return;
    }
    let Ok(database) = QuotaHistoryDatabase::default() else {
        return;
    };
    let history = database
        .recent_history_24h(points.len())
        .unwrap_or_default();
    overlay_history(points, &history);
}

pub fn overlay_history(points: &mut [RecentUsagePoint], history: &[QuotaHistoryPoint]) {
    for (point, quota) in points.iter_mut().zip(history.iter()) {
        point.five_hour_remaining_percent = quota.five_hour_remaining_percent;
        point.seven_day_remaining_percent = quota.seven_day_remaining_percent;
    }
}

fn quota_available(quota: &QuotaSnapshot) -> bool {
    quota.five_hour.resets_at_unix.is_some() || quota.seven_day.resets_at_unix.is_some()
}

struct QuotaHistoryDatabase {
    path: PathBuf,
}

impl QuotaHistoryDatabase {
    fn default() -> Result<Self, String> {
        database_path()
            .map(|path| Self { path })
            .ok_or_else(|| "Unable to locate application support directory".into())
    }

    fn record(&self, bundle: &AccountQuotaBundle) -> SqlResult<()> {
        let connection = self.open()?;
        let now = now_unix();
        ensure_schema(&connection)?;
        let row = QuotaHistoryRow::from_bundle(bundle, now);
        let latest = latest_trusted_row(&connection, &row.account_key)?;
        let normalized = row.normalized_after(latest.as_ref());
        if latest
            .as_ref()
            .is_some_and(|latest| !should_insert(&normalized, latest, now))
        {
            return Ok(());
        }
        insert_row(&connection, &normalized)?;
        prune(&connection, now)?;
        Ok(())
    }

    fn recent_history_24h(&self, count: usize) -> SqlResult<Vec<QuotaHistoryPoint>> {
        let connection = self.open()?;
        ensure_schema(&connection)?;
        let rows = recent_rows(&connection)?;
        Ok(make_recent_history(rows, count.max(1)))
    }

    fn open(&self) -> SqlResult<Connection> {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let connection = Connection::open(&self.path)?;
        connection.busy_timeout(std::time::Duration::from_secs(3))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        Ok(connection)
    }
}

#[derive(Clone, Debug)]
struct QuotaHistoryRow {
    created_at: f64,
    account_key: String,
    plan_type: Option<String>,
    limit_name: Option<String>,
    account_name: Option<String>,
    five_hour_used_percent: Option<i32>,
    five_hour_resets_at: Option<f64>,
    seven_day_used_percent: Option<i32>,
    seven_day_resets_at: Option<f64>,
    status: String,
}

impl QuotaHistoryRow {
    fn from_bundle(bundle: &AccountQuotaBundle, created_at: f64) -> Self {
        Self {
            created_at,
            account_key: account_key(bundle),
            plan_type: Some(bundle.account.plan_label.clone()).filter(|value| !value.trim().is_empty()),
            limit_name: Some("codex".into()),
            account_name: Some(bundle.account.display_name.clone())
                .filter(|value| !value.trim().is_empty()),
            five_hour_used_percent: percent_to_int(bundle.quota.five_hour.used_percent),
            five_hour_resets_at: bundle.quota.five_hour.resets_at_unix.map(|value| value as f64),
            seven_day_used_percent: percent_to_int(bundle.quota.seven_day.used_percent),
            seven_day_resets_at: bundle.quota.seven_day.resets_at_unix.map(|value| value as f64),
            status: bundle.quota.pace_label.clone(),
        }
    }

    fn normalized_after(&self, previous: Option<&Self>) -> Self {
        let Some(previous) = previous else {
            return self.clone();
        };
        let mut normalized = self.clone();
        normalized.five_hour_used_percent = normalized_used_percent(
            self.five_hour_used_percent,
            self.five_hour_resets_at,
            previous.five_hour_used_percent,
            previous.five_hour_resets_at,
        );
        normalized.seven_day_used_percent = normalized_used_percent(
            self.seven_day_used_percent,
            self.seven_day_resets_at,
            previous.seven_day_used_percent,
            previous.seven_day_resets_at,
        );
        normalized
    }

    fn five_hour_remaining(&self) -> Option<f64> {
        remaining_from_used(self.five_hour_used_percent)
    }

    fn seven_day_remaining(&self) -> Option<f64> {
        remaining_from_used(self.seven_day_used_percent)
    }
}

fn normalized_used_percent(
    current_used: Option<i32>,
    current_reset: Option<f64>,
    previous_used: Option<i32>,
    previous_reset: Option<f64>,
) -> Option<i32> {
    let Some(current_used) = current_used else {
        return previous_used;
    };
    match (current_reset, previous_reset, previous_used) {
        (Some(current_reset), Some(previous_reset), Some(previous_used))
            if same_reset_window(current_reset, previous_reset) =>
        {
            Some(current_used.max(previous_used))
        }
        (None, None, Some(previous_used)) => Some(current_used.max(previous_used)),
        _ => Some(current_used),
    }
}

fn same_reset_window(left: f64, right: f64) -> bool {
    (left - right).abs() < 1.0
}

fn should_insert(row: &QuotaHistoryRow, latest: &QuotaHistoryRow, now: f64) -> bool {
    if row.account_key != latest.account_key {
        return true;
    }
    if row.five_hour_used_percent != latest.five_hour_used_percent {
        return true;
    }
    if row.seven_day_used_percent != latest.seven_day_used_percent {
        return true;
    }
    if row.five_hour_resets_at != latest.five_hour_resets_at {
        return true;
    }
    if row.seven_day_resets_at != latest.seven_day_resets_at {
        return true;
    }
    if row.plan_type != latest.plan_type
        || row.limit_name != latest.limit_name
        || row.account_name != latest.account_name
    {
        return true;
    }
    now - latest.created_at >= HEARTBEAT_SECONDS
}

fn make_recent_history(rows: Vec<QuotaHistoryRow>, count: usize) -> Vec<QuotaHistoryPoint> {
    let now = now_unix();
    let start = now - (count as f64) * RECENT_INTERVAL_SECONDS as f64;
    let sorted = sanitized_rows(rows);
    let mut row_index = 0;
    let mut latest: Option<QuotaHistoryRow> = None;

    (0..count)
        .map(|index| {
            let bin_start = start + index as f64 * RECENT_INTERVAL_SECONDS as f64;
            let end = bin_start + RECENT_INTERVAL_SECONDS as f64;
            while row_index < sorted.len() && sorted[row_index].created_at <= end {
                latest = Some(sorted[row_index].clone());
                row_index += 1;
            }
            QuotaHistoryPoint {
                label: format_unix_time(bin_start),
                five_hour_remaining_percent: quota_remaining(
                    latest.as_ref(),
                    end,
                    |row| row.five_hour_remaining(),
                    |row| row.five_hour_resets_at,
                ),
                seven_day_remaining_percent: quota_remaining(
                    latest.as_ref(),
                    end,
                    |row| row.seven_day_remaining(),
                    |row| row.seven_day_resets_at,
                ),
            }
        })
        .collect()
}

fn quota_remaining(
    row: Option<&QuotaHistoryRow>,
    at: f64,
    remaining: impl Fn(&QuotaHistoryRow) -> Option<f64>,
    resets_at: impl Fn(&QuotaHistoryRow) -> Option<f64>,
) -> Option<f64> {
    let row = row?;
    let value = remaining(row)?;
    if let Some(reset) = resets_at(row) {
        if at >= reset {
            return Some(1.0);
        }
        return Some(value);
    }
    if at - row.created_at <= MAX_CARRY_GAP_SECONDS {
        Some(value)
    } else {
        None
    }
}

fn sanitized_rows(rows: Vec<QuotaHistoryRow>) -> Vec<QuotaHistoryRow> {
    let mut last_by_account: HashMap<String, QuotaHistoryRow> = HashMap::new();
    rows.into_iter()
        .map(|row| {
            let normalized = row.normalized_after(last_by_account.get(&row.account_key));
            last_by_account.insert(row.account_key.clone(), normalized.clone());
            normalized
        })
        .collect()
}

fn ensure_schema(connection: &Connection) -> SqlResult<()> {
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

fn insert_row(connection: &Connection, row: &QuotaHistoryRow) -> SqlResult<()> {
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

fn latest_trusted_row(connection: &Connection, account_key: &str) -> SqlResult<Option<QuotaHistoryRow>> {
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

fn recent_rows(connection: &Connection) -> SqlResult<Vec<QuotaHistoryRow>> {
    let Some(account_key) = latest_account_key(connection)? else {
        return Ok(Vec::new());
    };
    let cutoff = now_unix() - 31.0 * 24.0 * 60.0 * 60.0;
    let rows = query_rows(
        connection,
        r#"
        SELECT created_at, account_key, plan_type, limit_name, account_name,
               five_hour_used_percent, five_hour_resets_at,
               seven_day_used_percent, seven_day_resets_at, status
        FROM quota_snapshots
        WHERE account_key = ?1 AND created_at >= ?2
        ORDER BY created_at ASC;
        "#,
        params![account_key, cutoff],
    )?;
    Ok(rows)
}

fn latest_account_key(connection: &Connection) -> SqlResult<Option<String>> {
    connection
        .query_row(
            "SELECT account_key FROM quota_snapshots ORDER BY created_at DESC LIMIT 1;",
            [],
            |row| row.get(0),
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

fn prune(connection: &Connection, now: f64) -> SqlResult<()> {
    let cutoff = now - RETENTION_DAYS as f64 * 24.0 * 60.0 * 60.0;
    connection.execute(
        "DELETE FROM quota_snapshots WHERE created_at < ?1;",
        params![cutoff],
    )?;
    Ok(())
}

fn account_key(bundle: &AccountQuotaBundle) -> String {
    let mut parts = vec![
        bundle.account.display_name.trim().to_string(),
        bundle.account.plan_label.trim().to_string(),
        "codex".into(),
    ];
    parts.retain(|value| !value.is_empty());
    if parts.is_empty() {
        "default".into()
    } else {
        parts.join("|")
    }
}

fn percent_to_int(value: f64) -> Option<i32> {
    if !value.is_finite() {
        return None;
    }
    Some((value * 100.0).round().clamp(0.0, 100.0) as i32)
}

fn remaining_from_used(value: Option<i32>) -> Option<f64> {
    value.map(|used| (100 - used).clamp(0, 100) as f64 / 100.0)
}

fn now_unix() -> f64 {
    OffsetDateTime::now_utc().unix_timestamp() as f64
}

fn format_unix_time(value: f64) -> String {
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let seconds = value.round() as i64;
    OffsetDateTime::from_unix_timestamp(seconds)
        .unwrap_or_else(|_| OffsetDateTime::UNIX_EPOCH)
        .to_offset(offset)
        .format(format_description!("[hour]:[minute]"))
        .unwrap_or_else(|_| "00:00".into())
}

fn database_path() -> Option<PathBuf> {
    if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .map(|path| path.join("CodexTokenBar").join("quota-history.sqlite"))
    } else {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| {
                home.join("Library")
                    .join("Application Support")
                    .join("CodexTokenBar")
                    .join("quota-history.sqlite")
            })
    }
}

#[cfg(test)]
#[path = "quota_history_tests.rs"]
mod quota_history_tests;
