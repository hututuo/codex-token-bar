use super::series::sanitized_rows;
use super::{now_unix, QuotaHistoryIdentity, QuotaHistoryRow, RETENTION_DAYS};
use rusqlite::{params, Connection, Result as SqlResult};
#[cfg(test)]
use rusqlite::OptionalExtension;

const LEGACY_BRIDGE_MAX_AGE_DAYS: i64 = 45;
const LEGACY_BRIDGE_MAX_ROWS: usize = 512;

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
            status TEXT NOT NULL,
            identity_version INTEGER,
            home_identity TEXT,
            stable_account_key TEXT,
            identity_plan_type TEXT,
            identity_limit_id TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_created_at ON quota_snapshots(created_at);
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_account_created ON quota_snapshots(account_key, created_at);
        "#,
    )?;
    ensure_column(connection, "source", "TEXT")?;
    ensure_column(connection, "identity_version", "INTEGER")?;
    ensure_column(connection, "home_identity", "TEXT")?;
    ensure_column(connection, "stable_account_key", "TEXT")?;
    ensure_column(connection, "identity_plan_type", "TEXT")?;
    ensure_column(connection, "identity_limit_id", "TEXT")?;
    connection.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_stable_identity_created
        ON quota_snapshots(
            identity_version,
            home_identity,
            stable_account_key,
            identity_plan_type,
            identity_limit_id,
            created_at
        );
        CREATE TABLE IF NOT EXISTS quota_history_legacy_claims (
            legacy_account_name TEXT NOT NULL,
            legacy_plan_type TEXT NOT NULL,
            legacy_limit_id TEXT NOT NULL,
            bridge_kind TEXT NOT NULL,
            owner_identity_version INTEGER NOT NULL,
            owner_home_identity TEXT NOT NULL,
            owner_stable_account_key TEXT NOT NULL,
            owner_plan_type TEXT NOT NULL,
            owner_limit_id TEXT NOT NULL,
            state TEXT NOT NULL,
            claimed_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            PRIMARY KEY (
                legacy_account_name,
                legacy_plan_type,
                legacy_limit_id
            )
        );
        "#,
    )?;
    Ok(())
}

pub(super) fn insert_row(connection: &Connection, row: &QuotaHistoryRow) -> SqlResult<()> {
    connection.execute(
        r#"
        INSERT INTO quota_snapshots (
            created_at, account_key, plan_type, limit_name, account_name, source,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status,
            identity_version, home_identity, stable_account_key,
            identity_plan_type, identity_limit_id
        ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
            ?12, ?13, ?14, ?15, ?16
        );
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
            row.status,
            row.identity_version,
            row.home_identity,
            row.stable_account_key,
            row.identity_plan_type,
            row.identity_limit_id
        ],
    )?;
    Ok(())
}

pub(super) fn latest_trusted_row(
    connection: &Connection,
    row: &QuotaHistoryRow,
) -> SqlResult<Option<QuotaHistoryRow>> {
    let filter = AccountHistoryFilter::from_row(row);
    let rows = if let Some(identity) = filter.identity.as_ref() {
        query_stable_identity_rows(connection, identity, None)?
    } else {
        matching_rows(connection, &filter, None, "DESC")?
            .into_iter()
            .rev()
            .collect()
    };
    Ok(sanitized_rows(rows).pop())
}

#[cfg(test)]
pub(super) fn recent_rows(connection: &Connection) -> SqlResult<Vec<QuotaHistoryRow>> {
    rows_since(connection, 31.0 * 24.0 * 60.0 * 60.0)
}

#[cfg(test)]
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

pub(super) fn rows_since_for_row(
    connection: &Connection,
    age_seconds: f64,
    row: &QuotaHistoryRow,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    let filter = AccountHistoryFilter::from_row(row);
    let cutoff = now_unix() - age_seconds;
    matching_rows(connection, &filter, Some(cutoff), "ASC")
}

/// Read a peer (Swift) database without touching its schema or its legacy
/// bridge claims. A peer database is optional and may be from an older
/// version, so the caller deliberately treats any error as an empty result.
pub(super) fn rows_since_for_read_only_peer(
    connection: &Connection,
    age_seconds: f64,
    identity: &QuotaHistoryIdentity,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    let cutoff = now_unix() - age_seconds;
    let rows = query_stable_identity_rows(connection, identity, Some(cutoff))?;
    Ok(rows
        .into_iter()
        .filter(|row| {
            // Reset timestamps stay attached to each historical sample: using
            // the current bundle's reset as a filter would erase prior cycles.
            // The stable identity already includes the account, plan, and
            // limit; display names and derived account keys are not scope.
            row.stable_identity().as_ref() == Some(identity)
                && is_swift_source(row.source.as_deref())
        })
        .collect())
}

fn is_swift_source(source: Option<&str>) -> bool {
    source
        .map(str::trim)
        .is_some_and(|value| value.eq_ignore_ascii_case("swift"))
}

fn matching_rows(
    connection: &Connection,
    filter: &AccountHistoryFilter,
    cutoff: Option<f64>,
    order: &str,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    if let Some(identity) = filter.identity.as_ref() {
        return matching_stable_identity_rows(connection, filter, identity, cutoff, order);
    }
    matching_legacy_filter_rows(connection, filter, cutoff, order)
}

fn matching_legacy_filter_rows(
    connection: &Connection,
    filter: &AccountHistoryFilter,
    cutoff: Option<f64>,
    order: &str,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    if let Some(account_name) = filter
        .account_name
        .as_ref()
        .filter(|value| !value.trim().is_empty())
    {
        if let Some(cutoff) = cutoff {
            query_rows(
                connection,
                &format!(
                    r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
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
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
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
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
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
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
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

fn matching_stable_identity_rows(
    connection: &Connection,
    filter: &AccountHistoryFilter,
    identity: &QuotaHistoryIdentity,
    cutoff: Option<f64>,
    order: &str,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    let mut rows = query_stable_identity_rows(connection, identity, cutoff)?;
    if rows.is_empty() {
        return Ok(rows);
    }
    let legacy_cutoff = cutoff
        .unwrap_or(f64::NEG_INFINITY)
        .max(now_unix() - LEGACY_BRIDGE_MAX_AGE_DAYS as f64 * 24.0 * 60.0 * 60.0);

    for bridge in legacy_bridges(filter, identity) {
        let legacy_rows = query_legacy_bridge_rows(connection, &bridge, legacy_cutoff)?;
        if legacy_rows.is_empty() {
            continue;
        }
        let known_ambiguous = legacy_bridge_has_other_stable_identity(
            connection,
            &bridge,
            identity,
        )?;
        if claim_legacy_bridge(connection, &bridge, identity, known_ambiguous)? {
            rows.extend(legacy_rows);
        }
    }

    rows.sort_by(|left, right| {
        left.created_at
            .partial_cmp(&right.created_at)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if order.eq_ignore_ascii_case("DESC") {
        rows.reverse();
    }
    Ok(rows)
}

fn query_stable_identity_rows(
    connection: &Connection,
    identity: &QuotaHistoryIdentity,
    cutoff: Option<f64>,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    if let Some(cutoff) = cutoff {
        query_rows(
            connection,
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
            FROM quota_snapshots
            WHERE identity_version = ?1
              AND home_identity = ?2
              AND stable_account_key = ?3
              AND identity_plan_type = ?4
              AND identity_limit_id = ?5
              AND created_at >= ?6
            ORDER BY created_at ASC;
            "#,
            params![
                identity.version,
                identity.home_identity,
                identity.stable_account_key,
                identity.plan_type,
                identity.limit_id,
                cutoff
            ],
        )
    } else {
        query_rows(
            connection,
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
            FROM quota_snapshots
            WHERE identity_version = ?1
              AND home_identity = ?2
              AND stable_account_key = ?3
              AND identity_plan_type = ?4
              AND identity_limit_id = ?5
            ORDER BY created_at ASC;
            "#,
            params![
                identity.version,
                identity.home_identity,
                identity.stable_account_key,
                identity.plan_type,
                identity.limit_id
            ],
        )
    }
}

#[derive(Clone)]
struct LegacyBridge {
    account_name: String,
    plan_type: String,
    limit_id: String,
    kind: &'static str,
    fake_pro: bool,
}

fn legacy_bridges(
    filter: &AccountHistoryFilter,
    identity: &QuotaHistoryIdentity,
) -> Vec<LegacyBridge> {
    let Some(account_name) = filter
        .account_name
        .as_ref()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
    else {
        return Vec::new();
    };
    let mut bridges = vec![LegacyBridge {
        account_name: account_name.to_string(),
        plan_type: identity.plan_type.clone(),
        limit_id: identity.limit_id.clone(),
        kind: "exact-plan",
        fake_pro: false,
    }];
    if !identity.plan_type.eq_ignore_ascii_case("Pro")
        && identity.limit_id.eq_ignore_ascii_case("codex")
    {
        bridges.push(LegacyBridge {
            account_name: account_name.to_string(),
            plan_type: "Pro".into(),
            limit_id: identity.limit_id.clone(),
            kind: "swift-fake-pro",
            fake_pro: true,
        });
    }
    bridges
}

fn query_legacy_bridge_rows(
    connection: &Connection,
    bridge: &LegacyBridge,
    cutoff: f64,
) -> SqlResult<Vec<QuotaHistoryRow>> {
    query_rows(
        connection,
        &format!(
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
            FROM quota_snapshots
            WHERE identity_version IS NULL
              AND account_name = ?1
              AND lower(coalesce(plan_type, '')) = lower(?2)
              AND (
                lower(coalesce(limit_name, '')) = lower(?3)
                OR (?3 = 'codex' AND coalesce(limit_name, '') = '')
              )
              AND created_at >= ?4
              AND (
                source IS NULL
                OR trim(source) = ''
                OR lower(trim(source)) IN ('swift', 'tauri')
              )
              AND (
                ?5 = 0
                OR source IS NULL
                OR trim(source) = ''
                OR lower(trim(source)) = 'swift'
              )
            ORDER BY created_at DESC
            LIMIT {LEGACY_BRIDGE_MAX_ROWS};
            "#
        ),
        params![
            bridge.account_name,
            bridge.plan_type,
            bridge.limit_id,
            cutoff,
            i64::from(bridge.fake_pro)
        ],
    )
}

fn legacy_bridge_has_other_stable_identity(
    connection: &Connection,
    bridge: &LegacyBridge,
    identity: &QuotaHistoryIdentity,
) -> SqlResult<bool> {
    let shared_pro_alias = bridge.plan_type.eq_ignore_ascii_case("Pro")
        && bridge.limit_id.eq_ignore_ascii_case("codex");
    let other_count: i64 = connection.query_row(
        r#"
        SELECT count(*)
        FROM (
            SELECT DISTINCT identity_version, home_identity, stable_account_key,
                            identity_plan_type, identity_limit_id
            FROM quota_snapshots
            WHERE identity_version = ?1
              AND account_name = ?2
              AND identity_limit_id = ?3
              AND (
                ?4 = 1
                OR identity_plan_type = ?5
              )
              AND NOT (
                home_identity = ?6
                AND stable_account_key = ?7
                AND identity_plan_type = ?8
                AND identity_limit_id = ?9
              )
        );
        "#,
        params![
            identity.version,
            bridge.account_name,
            bridge.limit_id,
            i64::from(shared_pro_alias),
            bridge.plan_type,
            identity.home_identity,
            identity.stable_account_key,
            identity.plan_type,
            identity.limit_id
        ],
        |row| row.get(0),
    )?;
    Ok(other_count > 0)
}

fn claim_legacy_bridge(
    connection: &Connection,
    bridge: &LegacyBridge,
    identity: &QuotaHistoryIdentity,
    known_ambiguous: bool,
) -> SqlResult<bool> {
    let now = now_unix();
    connection.execute(
        r#"
        INSERT INTO quota_history_legacy_claims (
            legacy_account_name, legacy_plan_type, legacy_limit_id, bridge_kind,
            owner_identity_version, owner_home_identity, owner_stable_account_key,
            owner_plan_type, owner_limit_id, state, claimed_at, last_seen_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?11, ?10, ?10)
        ON CONFLICT(legacy_account_name, legacy_plan_type, legacy_limit_id)
        DO UPDATE SET
            state = CASE
                WHEN excluded.state = 'claimed'
                 AND quota_history_legacy_claims.state = 'claimed'
                 AND quota_history_legacy_claims.owner_identity_version = excluded.owner_identity_version
                 AND quota_history_legacy_claims.owner_home_identity = excluded.owner_home_identity
                 AND quota_history_legacy_claims.owner_stable_account_key = excluded.owner_stable_account_key
                 AND quota_history_legacy_claims.owner_plan_type = excluded.owner_plan_type
                 AND quota_history_legacy_claims.owner_limit_id = excluded.owner_limit_id
                THEN 'claimed'
                ELSE 'ambiguous'
            END,
            last_seen_at = excluded.last_seen_at;
        "#,
        params![
            bridge.account_name,
            bridge.plan_type,
            bridge.limit_id,
            bridge.kind,
            identity.version,
            identity.home_identity,
            identity.stable_account_key,
            identity.plan_type,
            identity.limit_id,
            now,
            if known_ambiguous {
                "ambiguous"
            } else {
                "claimed"
            }
        ],
    )?;

    let claim = connection.query_row(
        r#"
        SELECT state, owner_identity_version, owner_home_identity,
               owner_stable_account_key, owner_plan_type, owner_limit_id
        FROM quota_history_legacy_claims
        WHERE legacy_account_name = ?1
          AND legacy_plan_type = ?2
          AND legacy_limit_id = ?3;
        "#,
        params![
            bridge.account_name,
            bridge.plan_type,
            bridge.limit_id
        ],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
            ))
        },
    )?;
    Ok(claim.0 == "claimed"
        && claim.1 == identity.version
        && claim.2 == identity.home_identity
        && claim.3 == identity.stable_account_key
        && claim.4 == identity.plan_type
        && claim.5 == identity.limit_id)
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
    identity: Option<QuotaHistoryIdentity>,
    account_key: String,
    plan_type: Option<String>,
    limit_name: Option<String>,
    account_name: Option<String>,
}

impl AccountHistoryFilter {
    fn from_row(row: &QuotaHistoryRow) -> Self {
        Self {
            identity: row.stable_identity(),
            account_key: row.history_match_key(),
            plan_type: row.match_plan_type(),
            limit_name: row.match_limit_name(),
            account_name: row.match_account_name(),
        }
    }
}

#[cfg(test)]
fn latest_account_filter(connection: &Connection) -> SqlResult<Option<AccountHistoryFilter>> {
    connection
        .query_row(
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
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
                    identity_version: row.get(11)?,
                    home_identity: row.get(12)?,
                    stable_account_key: row.get(13)?,
                    identity_plan_type: row.get(14)?,
                    identity_limit_id: row.get(15)?,
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
            identity_version: row.get(11)?,
            home_identity: row.get(12)?,
            stable_account_key: row.get(13)?,
            identity_plan_type: row.get(14)?,
            identity_limit_id: row.get(15)?,
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
        connection.execute(
            &format!("ALTER TABLE quota_snapshots ADD COLUMN {name} {definition};"),
            [],
        )?;
    }
    Ok(())
}
