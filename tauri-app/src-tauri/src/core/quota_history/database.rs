use super::{
    now_unix, QuotaHistoryIdentity, QuotaHistoryRow, QuotaWindow,
    NEW_CYCLE_RESET_THRESHOLD_SECONDS, QUOTA_HISTORY_MAINTENANCE_INTERVAL_SECONDS,
    QUOTA_HISTORY_POLICY_VERSION,
};
use rusqlite::{params, Connection, OptionalExtension, Result as SqlResult, Transaction};
use std::collections::HashSet;

const FREELIST_RECLAIM_MIN_FREE_BYTES: i64 = 1_048_576;
const FREELIST_RECLAIM_MIN_RATIO: f64 = 0.20;

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
            five_hour_cycle_generation INTEGER,
            five_hour_reset_anchor INTEGER NOT NULL DEFAULT 0,
            seven_day_used_percent INTEGER,
            seven_day_resets_at REAL,
            seven_day_cycle_generation INTEGER,
            seven_day_reset_anchor INTEGER NOT NULL DEFAULT 0,
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
    ensure_column(connection, "five_hour_cycle_generation", "INTEGER")?;
    ensure_column(connection, "five_hour_reset_anchor", "INTEGER NOT NULL DEFAULT 0")?;
    ensure_column(connection, "seven_day_cycle_generation", "INTEGER")?;
    ensure_column(connection, "seven_day_reset_anchor", "INTEGER NOT NULL DEFAULT 0")?;
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
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_stable_cycle_created
        ON quota_snapshots(
            identity_version,
            home_identity,
            stable_account_key,
            identity_plan_type,
            identity_limit_id,
            created_at,
            id
        );
        CREATE TABLE IF NOT EXISTS quota_history_maintenance (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        INSERT OR IGNORE INTO quota_history_maintenance (key, value)
        VALUES ('policy_version', '0'), ('last_compacted_at', '0');
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
            five_hour_cycle_generation, five_hour_reset_anchor,
            seven_day_used_percent, seven_day_resets_at,
            seven_day_cycle_generation, seven_day_reset_anchor, status,
            identity_version, home_identity, stable_account_key,
            identity_plan_type, identity_limit_id
        ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
            ?14, ?15, ?16, ?17, ?18, ?19, ?20
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
            row.five_hour_cycle_generation,
            row.five_hour_reset_anchor.unwrap_or(0),
            row.seven_day_used_percent,
            row.seven_day_resets_at,
            row.seven_day_cycle_generation,
            row.seven_day_reset_anchor.unwrap_or(0),
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
    if let Some(identity) = filter.identity.as_ref() {
        return query_rows(
            connection,
            r#"
            SELECT created_at, account_key, plan_type, limit_name, account_name, source,
                   five_hour_used_percent, five_hour_resets_at,
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
            FROM quota_snapshots
            WHERE identity_version = ?1
              AND home_identity = ?2
              AND stable_account_key = ?3
              AND identity_plan_type = ?4
              AND identity_limit_id = ?5
            ORDER BY created_at DESC, id DESC
            LIMIT 1;
            "#,
            params![
                identity.version,
                identity.home_identity,
                identity.stable_account_key,
                identity.plan_type,
                identity.limit_id,
            ],
        )
        .map(|mut rows| rows.pop());
    }

    let rows = matching_rows(connection, &filter, None, "DESC")?;
    Ok(rows.into_iter().next())
}

pub(super) fn latest_anchor(
    connection: &Connection,
    row: &QuotaHistoryRow,
    window: QuotaWindow,
) -> SqlResult<Option<super::AcceptedAnchor>> {
    let Some(identity) = row.stable_identity() else {
        return Ok(None);
    };
    let (generation_column, anchor_column, reset_column) = match window {
        QuotaWindow::FiveHour => (
            "five_hour_cycle_generation",
            "five_hour_reset_anchor",
            "five_hour_resets_at",
        ),
        QuotaWindow::SevenDay => (
            "seven_day_cycle_generation",
            "seven_day_reset_anchor",
            "seven_day_resets_at",
        ),
    };
    let sql = format!(
        r#"
        SELECT {generation_column}, {reset_column}
        FROM quota_snapshots
        WHERE identity_version = ?1
          AND home_identity = ?2
          AND stable_account_key = ?3
          AND identity_plan_type = ?4
          AND identity_limit_id = ?5
          AND {anchor_column} = 1
          AND {reset_column} IS NOT NULL
        ORDER BY created_at DESC, id DESC
        LIMIT 1;
        "#
    );
    connection
        .query_row(
            &sql,
            params![
                identity.version,
                identity.home_identity,
                identity.stable_account_key,
                identity.plan_type,
                identity.limit_id,
            ],
            |row| {
                Ok(super::AcceptedAnchor {
                    generation: row.get(0)?,
                    reset: row.get(1)?,
                })
            },
        )
        .optional()
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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
    // A safe legacy claim is a read-only compatibility bridge.  It follows
    // the caller's requested history window, but never applies the former
    // 45-day or 512-row truncation to an otherwise unambiguous legacy scope.
    let legacy_cutoff = cutoff.unwrap_or(f64::NEG_INFINITY);

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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
            ORDER BY created_at ASC;
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
                   five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_used_percent, seven_day_resets_at,
                   seven_day_cycle_generation, seven_day_reset_anchor, status,
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
                    five_hour_cycle_generation: row.get(8)?,
                    five_hour_reset_anchor: row.get(9)?,
                    seven_day_used_percent: row.get(10)?,
                    seven_day_resets_at: row.get(11)?,
                    seven_day_cycle_generation: row.get(12)?,
                    seven_day_reset_anchor: row.get(13)?,
                    status: row.get(14)?,
                    identity_version: row.get(15)?,
                    home_identity: row.get(16)?,
                    stable_account_key: row.get(17)?,
                    identity_plan_type: row.get(18)?,
                    identity_limit_id: row.get(19)?,
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
            five_hour_cycle_generation: row.get(8)?,
            five_hour_reset_anchor: row.get(9)?,
            seven_day_used_percent: row.get(10)?,
            seven_day_resets_at: row.get(11)?,
            seven_day_cycle_generation: row.get(12)?,
            seven_day_reset_anchor: row.get(13)?,
            status: row.get(14)?,
            identity_version: row.get(15)?,
            home_identity: row.get(16)?,
            stable_account_key: row.get(17)?,
            identity_plan_type: row.get(18)?,
            identity_limit_id: row.get(19)?,
        })
    })?;
    rows.collect()
}

#[derive(Clone)]
struct StoredQuotaHistoryRow {
    id: i64,
    row: QuotaHistoryRow,
}

pub(super) fn maintain_if_due(connection: &mut Connection, now: f64) -> SqlResult<()> {
    let metadata = connection
        .prepare(
            "SELECT key, value FROM quota_history_maintenance WHERE key IN ('policy_version', 'last_compacted_at');",
        )?
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<SqlResult<Vec<_>>>()?;
    let policy_version = metadata
        .iter()
        .find(|(key, _)| key == "policy_version")
        .and_then(|(_, value)| value.parse::<i64>().ok())
        .unwrap_or_default();
    let last_compacted_at = metadata
        .iter()
        .find(|(key, _)| key == "last_compacted_at")
        .and_then(|(_, value)| value.parse::<f64>().ok())
        .unwrap_or_default();
    let due = policy_version != QUOTA_HISTORY_POLICY_VERSION
        || now - last_compacted_at >= QUOTA_HISTORY_MAINTENANCE_INTERVAL_SECONDS;
    if !due {
        return Ok(());
    }

    let transaction = connection.transaction()?;
    let identities = stable_identities(&transaction)?;
    for identity in identities {
        compact_stable_identity(&transaction, &identity)?;
    }
    // Keep this update in the same transaction as all row work.  If any
    // migration or compaction operation fails, the timestamp remains stale
    // and the next record/read retries the work.
    transaction.execute_batch(
        "INSERT INTO quota_history_maintenance (key, value) VALUES ('policy_version', '0'), ('last_compacted_at', '0') ON CONFLICT(key) DO NOTHING;",
    )?;
    transaction.execute(
        "UPDATE quota_history_maintenance SET value = ?1 WHERE key = 'policy_version';",
        params![QUOTA_HISTORY_POLICY_VERSION.to_string()],
    )?;
    transaction.execute(
        "UPDATE quota_history_maintenance SET value = ?1 WHERE key = 'last_compacted_at';",
        params![now],
    )?;
    transaction.commit()?;
    // This is deliberately after commit: VACUUM cannot run inside the
    // compaction transaction.  Reclamation is best effort and threshold
    // gated, so a small database never pays the cost on every record.
    maybe_reclaim_freelist(connection);
    Ok(())
}

fn freelist_reclaim_due(connection: &Connection) -> SqlResult<bool> {
    let page_count: i64 = connection.query_row("PRAGMA page_count;", [], |row| row.get(0))?;
    let free_pages: i64 = connection.query_row("PRAGMA freelist_count;", [], |row| row.get(0))?;
    let page_size: i64 = connection.query_row("PRAGMA page_size;", [], |row| row.get(0))?;
    if page_count <= 0 || free_pages <= 0 || page_size <= 0 {
        return Ok(false);
    }
    let free_bytes = free_pages.saturating_mul(page_size);
    let free_ratio = free_pages as f64 / page_count as f64;
    Ok(free_bytes >= FREELIST_RECLAIM_MIN_FREE_BYTES || free_ratio >= FREELIST_RECLAIM_MIN_RATIO)
}

fn maybe_reclaim_freelist(connection: &Connection) {
    let Ok(true) = freelist_reclaim_due(connection) else {
        return;
    };
    // Both operations occur after the SQLite transaction has committed.  A
    // concurrent/locked database simply defers reclamation to a later daily
    // maintenance pass; row history and metadata are already durable.
    let _ = connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    let _ = connection.execute_batch("VACUUM;");
}

#[cfg(test)]
pub(super) fn freelist_reclaim_due_for_test(connection: &Connection) -> SqlResult<bool> {
    freelist_reclaim_due(connection)
}

#[cfg(test)]
pub(super) fn maintenance_metadata(connection: &Connection) -> SqlResult<(i64, i64)> {
    let mut statement = connection.prepare(
        "SELECT key, value FROM quota_history_maintenance WHERE key IN ('policy_version', 'last_compacted_at');",
    )?;
    let metadata = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<SqlResult<Vec<_>>>()?;
    Ok((
        metadata
            .iter()
            .find(|(key, _)| key == "policy_version")
            .and_then(|(_, value)| value.parse().ok())
            .unwrap_or_default(),
        metadata
            .iter()
            .find(|(key, _)| key == "last_compacted_at")
            .and_then(|(_, value)| value.parse::<f64>().ok())
            .unwrap_or_default() as i64,
    ))
}

fn stable_identities(connection: &Connection) -> SqlResult<Vec<QuotaHistoryIdentity>> {
    let mut statement = connection.prepare(
        r#"
        SELECT DISTINCT identity_version, home_identity, stable_account_key,
                        identity_plan_type, identity_limit_id
        FROM quota_snapshots
        WHERE identity_version = ?1
          AND home_identity IS NOT NULL
          AND stable_account_key IS NOT NULL
          AND identity_plan_type IS NOT NULL
          AND identity_limit_id IS NOT NULL
        ORDER BY home_identity, stable_account_key, identity_plan_type, identity_limit_id;
        "#,
    )?;
    let rows = statement.query_map(params![super::QUOTA_HISTORY_IDENTITY_VERSION], |row| {
        Ok(QuotaHistoryIdentity {
            version: row.get(0)?,
            home_identity: row.get(1)?,
            stable_account_key: row.get(2)?,
            plan_type: row.get(3)?,
            limit_id: row.get(4)?,
        })
    })?;
    rows.collect()
}

fn stable_rows_for_identity(
    connection: &Connection,
    identity: &QuotaHistoryIdentity,
) -> SqlResult<Vec<StoredQuotaHistoryRow>> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, created_at, account_key, plan_type, limit_name, account_name, source,
               five_hour_used_percent, five_hour_resets_at,
               five_hour_cycle_generation, five_hour_reset_anchor,
               seven_day_used_percent, seven_day_resets_at,
               seven_day_cycle_generation, seven_day_reset_anchor, status,
               identity_version, home_identity, stable_account_key,
               identity_plan_type, identity_limit_id
        FROM quota_snapshots
        WHERE identity_version = ?1
          AND home_identity = ?2
          AND stable_account_key = ?3
          AND identity_plan_type = ?4
          AND identity_limit_id = ?5
        ORDER BY created_at ASC, id ASC;
        "#,
    )?;
    let rows = statement.query_map(
        params![
            identity.version,
            identity.home_identity,
            identity.stable_account_key,
            identity.plan_type,
            identity.limit_id,
        ],
        |row| {
            Ok(StoredQuotaHistoryRow {
                id: row.get(0)?,
                row: QuotaHistoryRow {
                    created_at: row.get(1)?,
                    account_key: row.get(2)?,
                    plan_type: row.get(3)?,
                    limit_name: row.get(4)?,
                    account_name: row.get(5)?,
                    source: row.get(6)?,
                    five_hour_used_percent: row.get(7)?,
                    five_hour_resets_at: row.get(8)?,
                    five_hour_cycle_generation: row.get(9)?,
                    five_hour_reset_anchor: row.get(10)?,
                    seven_day_used_percent: row.get(11)?,
                    seven_day_resets_at: row.get(12)?,
                    seven_day_cycle_generation: row.get(13)?,
                    seven_day_reset_anchor: row.get(14)?,
                    status: row.get(15)?,
                    identity_version: row.get(16)?,
                    home_identity: row.get(17)?,
                    stable_account_key: row.get(18)?,
                    identity_plan_type: row.get(19)?,
                    identity_limit_id: row.get(20)?,
                },
            })
        },
    )?;
    rows.collect()
}

#[derive(Clone, Copy)]
struct MaintenanceWindowState {
    generation: i64,
    anchor_reset: Option<i64>,
    seen: bool,
}

impl Default for MaintenanceWindowState {
    fn default() -> Self {
        Self {
            generation: 0,
            anchor_reset: None,
            seen: false,
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn compact_stable_identity(
    transaction: &Transaction<'_>,
    identity: &QuotaHistoryIdentity,
) -> SqlResult<()> {
    let stored_rows = stable_rows_for_identity(transaction, identity)?;
    if stored_rows.is_empty() {
        return Ok(());
    }

    let mut five_state = MaintenanceWindowState::default();
    let mut seven_state = MaintenanceWindowState::default();
    let mut planned = Vec::with_capacity(stored_rows.len());
    for stored in &stored_rows {
        let five = maintenance_window_metadata(
            stored.row.five_hour_used_percent,
            stored.row.five_hour_resets_at,
            stored.row.five_hour_cycle_generation,
            stored.row.five_hour_reset_anchor,
            &mut five_state,
        );
        let seven = maintenance_window_metadata(
            stored.row.seven_day_used_percent,
            stored.row.seven_day_resets_at,
            stored.row.seven_day_cycle_generation,
            stored.row.seven_day_reset_anchor,
            &mut seven_state,
        );
        planned.push((five, seven));
    }

    // A stable final observation is evidence that a reset-only run may be
    // compressed.  The check is intentionally conservative: it requires the
    // entire observed band to fit within five seconds and to span five
    // minutes, and it never crosses a generation boundary.
    let five_evidence = stable_final_anchor_indices(
        &stored_rows,
        QuotaWindow::FiveHour,
        &planned,
    );
    let seven_evidence = stable_final_anchor_indices(
        &stored_rows,
        QuotaWindow::SevenDay,
        &planned,
    );
    for (index, (five, seven)) in planned.iter_mut().enumerate() {
        if five_evidence.contains(&index) {
            five.1 = Some(1);
        }
        if seven_evidence.contains(&index) {
            seven.1 = Some(1);
        }
    }

    for (stored, (five, seven)) in stored_rows.iter().zip(planned.iter()) {
        let row = &stored.row;
        if row.five_hour_cycle_generation != five.0
            || row.five_hour_reset_anchor != five.1
            || row.seven_day_cycle_generation != seven.0
            || row.seven_day_reset_anchor != seven.1
        {
            transaction.execute(
                r#"
                UPDATE quota_snapshots
                SET five_hour_cycle_generation = ?1,
                    five_hour_reset_anchor = ?2,
                    seven_day_cycle_generation = ?3,
                    seven_day_reset_anchor = ?4
                WHERE id = ?5;
                "#,
                params![five.0, five.1, seven.0, seven.1, stored.id],
            )?;
        }
    }

    let mut delete_ids = Vec::new();
    let mut retained_index = 0usize;
    for index in 1..stored_rows.len() {
        let current = &stored_rows[index].row;
        let previous = &stored_rows[retained_index].row;
        let (five_generation, five_anchor) = planned[index].0;
        let (seven_generation, seven_anchor) = planned[index].1;
        if five_anchor.is_some_and(|anchor| anchor != 0)
            || seven_anchor.is_some_and(|anchor| anchor != 0)
        {
            retained_index = index;
            continue;
        }
        if !same_non_reset_payload(previous, current) {
            retained_index = index;
            continue;
        }
        let five_delta = reset_delta(previous.five_hour_resets_at, current.five_hour_resets_at);
        let seven_delta = reset_delta(previous.seven_day_resets_at, current.seven_day_resets_at);
        // Compare the planned metadata of the retained row.  During the
        // first policy migration the persisted generation fields are often
        // NULL, so comparing them with the planned current row would make a
        // valid same-generation heartbeat look like a generation change and
        // prevent compaction.
        let (retained_five_generation, _) = planned[retained_index].0;
        let (retained_seven_generation, _) = planned[retained_index].1;
        let same_generation = retained_five_generation == five_generation
            && retained_seven_generation == seven_generation;
        let five_has_later_anchor = planned[index + 1..].iter().any(|planned| {
            planned.0.0 == five_generation && planned.0.1.is_some_and(|anchor| anchor != 0)
        });
        let seven_has_later_anchor = planned[index + 1..].iter().any(|planned| {
            planned.1.0 == seven_generation && planned.1.1.is_some_and(|anchor| anchor != 0)
        });
        let five_compacted = reset_change_is_compacted(
            five_delta,
            five_has_later_anchor,
        );
        let seven_compacted = reset_change_is_compacted(
            seven_delta,
            seven_has_later_anchor,
        );
        if same_generation && five_compacted && seven_compacted {
            delete_ids.push(stored_rows[index].id);
        } else {
            retained_index = index;
        }
    }
    for id in delete_ids {
        transaction.execute("DELETE FROM quota_snapshots WHERE id = ?1;", params![id])?;
    }
    Ok(())
}

fn reset_change_is_compacted(delta: Option<f64>, has_later_stable_anchor: bool) -> bool {
    match delta {
        Some(delta) if delta <= super::RESET_MATCH_GRACE_SECONDS => true,
        Some(_) => has_later_stable_anchor,
        None => true,
    }
}

fn maintenance_window_metadata(
    used: Option<i32>,
    reset: Option<f64>,
    existing_generation: Option<i64>,
    existing_anchor: Option<i64>,
    state: &mut MaintenanceWindowState,
) -> (Option<i64>, Option<i64>) {
    let Some(used) = used else {
        return (existing_generation, existing_anchor);
    };
    // The on-disk marker is NOT NULL with a default of zero.  Treat zero as
    // "not yet accepted" during migration; otherwise the first legacy row
    // would appear to have an existing marker and no generation-0 anchor
    // would ever be backfilled.
    let existing_anchor = existing_anchor
        .filter(|anchor| *anchor != 0)
        .map(|_| 1);
    let reset = reset.filter(|reset| reset.is_finite());
    let first_observation = !state.seen;
    let mut new_cycle = false;
    if first_observation {
        state.seen = true;
        state.generation = existing_generation.unwrap_or(0).max(0);
        state.anchor_reset = reset.map(|value| value.round() as i64);
    } else if existing_anchor.is_some() {
        // Runtime-confirmed anchors are authoritative replay checkpoints.  A
        // same-generation stable drift moves the accepted reset baseline even
        // though it does not increment the cycle generation.
        state.generation = state
            .generation
            .max(existing_generation.unwrap_or(state.generation).max(0));
        state.anchor_reset = reset.map(|value| value.round() as i64);
    } else {
        state.generation = state
            .generation
            .max(existing_generation.unwrap_or(state.generation).max(0));
        let previous_anchor = state.anchor_reset;
        let strict_new_cycle = used == 0
            && reset.zip(previous_anchor).is_some_and(|(reset, anchor)| {
                (reset - anchor as f64).abs() > NEW_CYCLE_RESET_THRESHOLD_SECONDS
            });
        if strict_new_cycle {
            new_cycle = true;
            state.generation = state.generation.saturating_add(1);
            state.anchor_reset = reset.map(|value| value.round() as i64);
        }
    }
    (
        Some(state.generation),
        Some(existing_anchor.unwrap_or_else(|| {
            if first_observation || new_cycle {
                1
            } else {
                0
            }
        })),
    )
}

fn stable_final_anchor_indices(
    rows: &[StoredQuotaHistoryRow],
    window: QuotaWindow,
    planned: &[((Option<i64>, Option<i64>), (Option<i64>, Option<i64>))],
) -> HashSet<usize> {
    let mut result = HashSet::new();
    // Keep one active candidate per generation, just like the runtime
    // candidate map.  In particular, a cumulative drift that widens the
    // band beyond five seconds restarts the candidate at the current row;
    // taking min/max over an entire generation would incorrectly discard a
    // later stable suffix.
    let mut active_generation: Option<i64> = None;
    let mut accepted_reset: Option<f64> = None;
    // (first row, minimum reset, maximum reset, sample count, last row)
    let mut candidate: Option<(usize, f64, f64, usize, usize)> = None;

    for (index, stored) in rows.iter().enumerate() {
        let (generation, anchor) = match window {
            QuotaWindow::FiveHour => planned[index].0,
            QuotaWindow::SevenDay => planned[index].1,
        };
        let Some(generation) = generation else {
            continue;
        };
        if active_generation != Some(generation) {
            active_generation = Some(generation);
            accepted_reset = None;
            candidate = None;
        }
        let reset = match window {
            QuotaWindow::FiveHour => stored.row.five_hour_resets_at,
            QuotaWindow::SevenDay => stored.row.seven_day_resets_at,
        };

        // Persisted/current anchors establish the baseline and terminate any
        // candidate that preceded them.  A marker without a usable reset is
        // still an explicit boundary, but cannot establish a reset baseline.
        if anchor.is_some_and(|anchor| anchor != 0) {
            accepted_reset = reset.filter(|reset| reset.is_finite());
            candidate = None;
            continue;
        }
        let Some(reset) = reset.filter(|reset| reset.is_finite()) else {
            continue;
        };

        // If the first usable sample in a generation follows a legacy row
        // without a reset, it becomes the baseline.  Samples within the
        // normal five-second write grace likewise do not form a candidate.
        let Some(baseline_reset) = accepted_reset else {
            accepted_reset = Some(reset);
            candidate = None;
            continue;
        };
        if (reset - baseline_reset).abs() <= super::RESET_MATCH_GRACE_SECONDS {
            candidate = None;
            continue;
        }

        let mut next_candidate = match candidate.take() {
            Some((first_index, min_reset, max_reset, count, last_index)) => {
                let next_min = min_reset.min(reset);
                let next_max = max_reset.max(reset);
                let out_of_band = rows[index].row.created_at < rows[last_index].row.created_at
                    || next_max - next_min > super::STABLE_CANDIDATE_BAND_SECONDS;
                if out_of_band {
                    // A candidate that already covered five minutes would
                    // have been accepted on its last observation below.  An
                    // unfinished candidate is discarded and restarted at
                    // the current sample.
                    None
                } else {
                    Some((
                        first_index,
                        next_min,
                        next_max,
                        count.saturating_add(1),
                        index,
                    ))
                }
            }
            None => None,
        };

        if next_candidate.is_none() {
            next_candidate = Some((index, reset, reset, 1, index));
        }
        if let Some((first_index, min_reset, max_reset, count, last_index)) = next_candidate {
            if count >= 2
                && rows[last_index].row.created_at - rows[first_index].row.created_at
                    >= super::STABLE_CANDIDATE_SPAN_SECONDS
                && max_reset - min_reset <= super::STABLE_CANDIDATE_BAND_SECONDS
            {
                result.insert(last_index);
                accepted_reset = Some(reset);
                candidate = None;
            } else {
                candidate = Some((first_index, min_reset, max_reset, count, last_index));
            }
        }
    }

    if let Some((first_index, _min_reset, _max_reset, count, last_index)) = candidate {
        if count >= 2
            && rows[last_index].row.created_at - rows[first_index].row.created_at
                >= super::STABLE_CANDIDATE_SPAN_SECONDS
        {
            result.insert(last_index);
        }
    }
    result
}

fn same_non_reset_payload(previous: &QuotaHistoryRow, current: &QuotaHistoryRow) -> bool {
    previous.account_key == current.account_key
        && previous.source == current.source
        && previous.plan_type == current.plan_type
        && previous.limit_name == current.limit_name
        && previous.account_name == current.account_name
        && previous.five_hour_used_percent == current.five_hour_used_percent
        && previous.seven_day_used_percent == current.seven_day_used_percent
        && previous.status == current.status
        && previous.identity_version == current.identity_version
        && previous.home_identity == current.home_identity
        && previous.stable_account_key == current.stable_account_key
        && previous.identity_plan_type == current.identity_plan_type
        && previous.identity_limit_id == current.identity_limit_id
}

fn reset_delta(previous: Option<f64>, current: Option<f64>) -> Option<f64> {
    match (previous, current) {
        (Some(previous), Some(current)) if previous.is_finite() && current.is_finite() => {
            Some((current - previous).abs())
        }
        _ => None,
    }
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
