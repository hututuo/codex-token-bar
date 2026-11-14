//! Bounded history for local non-Codex quota-provider observations.
//!
//! The caller supplies a connection opened through the multi-client usage
//! database path. This module owns only its optional table and never touches
//! token-ledger rows.

use super::multi_client_product::{ClientQuotaHistorySample, QuotaProviderSnapshot};
use rusqlite::{params, Connection, OptionalExtension};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const TABLE_NAME: &str = "client_quota_observations";
const MAX_ROWS_PER_CLIENT: i64 = 500_000;
const HISTORY_SECONDS: f64 = 30.0 * 24.0 * 60.0 * 60.0;
const SAMPLE_BUCKET_SECONDS: f64 = 5.0 * 60.0;
const MAX_WINDOW_ID_BYTES: usize = 128;

pub(crate) fn ensure_schema(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS client_quota_observations (
            client TEXT NOT NULL,
            source TEXT NOT NULL,
            window_id TEXT NOT NULL,
            observed_at REAL NOT NULL,
            used_percent REAL NOT NULL CHECK(used_percent >= 0 AND used_percent <= 100),
            resets_at REAL,
            PRIMARY KEY(client,source,window_id,observed_at)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS client_quota_observations_source_time
            ON client_quota_observations(client,source,observed_at);
        CREATE INDEX IF NOT EXISTS client_quota_observations_client_time
            ON client_quota_observations(client,observed_at);
        "#,
    )
}

/// Store current observations using their provider-supplied capture time.
/// Identical readings are sampled at most once per five-minute bucket; value
/// or reset changes are retained immediately.
pub(crate) fn record_history(
    connection: &Connection,
    readings: &[QuotaProviderSnapshot],
    now: f64,
) -> Result<(), String> {
    if !now.is_finite() {
        return Err("当前时间无效".into());
    }
    ensure_schema(connection).map_err(|error| error.to_string())?;
    let cutoff = now - HISTORY_SECONDS;
    let transaction = connection
        .unchecked_transaction()
        .map_err(|error| error.to_string())?;
    let mut observations = Vec::new();
    for reading in readings {
        if !valid_record_state(&reading.state) || !valid_client(&reading.client) {
            continue;
        }
        for sample in &reading.history {
            let source = sample.source.as_deref().unwrap_or(&reading.source);
            if sample.observed_at.is_finite()
                && sample.observed_at <= now
                && sample.observed_at >= cutoff
                && sample.used_percent.is_finite()
                && (0.0..=100.0).contains(&sample.used_percent)
                && valid_window_source(&reading.client, source, &sample.window_id)
                && sample.resets_at.is_none_or(f64::is_finite)
            {
                observations.push(Observation {
                    client: reading.client.clone(),
                    source: source.to_owned(),
                    window_id: sample.window_id.clone(),
                    observed_at: sample.observed_at,
                    used_percent: sample.used_percent,
                    resets_at: sample.resets_at,
                });
            }
        }
        let Some(observed_at) = captured_epoch_seconds(reading.captured_at.as_deref()) else {
            continue;
        };
        if observed_at > now || observed_at < cutoff {
            continue;
        }
        for window in &reading.windows {
            let window_id = window.id.as_deref().unwrap_or(window.label.as_str()).trim();
            let Some(used_percent) = window
                .used_percent
                .filter(|value| value.is_finite() && (0.0..=100.0).contains(value))
            else {
                continue;
            };
            if !valid_window_source(&reading.client, &reading.source, window_id) {
                continue;
            }
            observations.push(Observation {
                client: reading.client.clone(),
                source: reading.source.clone(),
                window_id: window_id.to_owned(),
                observed_at,
                used_percent,
                resets_at: reset_epoch_seconds(window.resets_at.as_deref()),
            });
        }
    }
    observations.sort_by(|left, right| {
        left.client
            .cmp(&right.client)
            .then_with(|| left.source.cmp(&right.source))
            .then_with(|| left.window_id.cmp(&right.window_id))
            .then_with(|| left.observed_at.total_cmp(&right.observed_at))
    });
    for observation in observations {
        record_observation(&transaction, &observation).map_err(|error| error.to_string())?;
    }
    transaction.commit().map_err(|error| error.to_string())
}

pub(crate) fn has_recordable_observation(readings: &[QuotaProviderSnapshot], now: f64) -> bool {
    readings.iter().any(|reading| {
        valid_record_state(&reading.state)
            && valid_client(&reading.client)
            && (captured_epoch_seconds(reading.captured_at.as_deref()).is_some_and(|observed_at| {
                observed_at <= now && observed_at >= now - HISTORY_SECONDS
            }) && reading.windows.iter().any(|window| {
                let id = window.id.as_deref().unwrap_or(window.label.as_str()).trim();
                valid_window_source(&reading.client, &reading.source, id)
                    && window
                        .used_percent
                        .is_some_and(|value| value.is_finite() && (0.0..=100.0).contains(&value))
            }) || reading.history.iter().any(|sample| {
                sample.observed_at.is_finite()
                    && sample.observed_at <= now
                    && sample.observed_at >= now - HISTORY_SECONDS
                    && sample.used_percent.is_finite()
                    && (0.0..=100.0).contains(&sample.used_percent)
                    && valid_window_source(
                        &reading.client,
                        sample.source.as_deref().unwrap_or(&reading.source),
                        &sample.window_id,
                    )
            }))
    })
}

#[derive(Clone)]
struct Observation {
    client: String,
    source: String,
    window_id: String,
    observed_at: f64,
    used_percent: f64,
    resets_at: Option<f64>,
}

fn record_observation(connection: &Connection, observation: &Observation) -> rusqlite::Result<()> {
    if observation
        .resets_at
        .is_some_and(|reset| reset <= observation.observed_at)
    {
        return Ok(());
    }
    let exact: Option<(f64, Option<f64>)> = connection
        .query_row(
            "SELECT used_percent,resets_at FROM client_quota_observations \
             WHERE client=?1 AND source=?2 AND window_id=?3 AND observed_at=?4",
            params![
                observation.client,
                observation.source,
                observation.window_id,
                observation.observed_at
            ],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if exact == Some((observation.used_percent, observation.resets_at)) {
        return Ok(());
    }
    let latest: Option<(f64, f64, Option<f64>)> = connection
        .query_row(
            "SELECT observed_at,used_percent,resets_at FROM client_quota_observations \
             WHERE client=?1 AND source=?2 AND window_id=?3 \
             ORDER BY observed_at DESC LIMIT 1",
            params![
                observation.client,
                observation.source,
                observation.window_id
            ],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    if latest.is_some_and(|(latest_at, latest_used, latest_reset)| {
        observation.used_percent == latest_used
            && observation.resets_at == latest_reset
            && bucket_start(observation.observed_at) == bucket_start(latest_at)
    }) {
        return Ok(());
    }
    connection.execute(
        "INSERT INTO client_quota_observations \
         (client,source,window_id,observed_at,used_percent,resets_at) \
         VALUES (?1,?2,?3,?4,?5,?6) \
         ON CONFLICT(client,source,window_id,observed_at) DO UPDATE SET \
         used_percent=excluded.used_percent,resets_at=excluded.resets_at",
        params![
            observation.client,
            observation.source,
            observation.window_id,
            observation.observed_at,
            observation.used_percent,
            observation.resets_at
        ],
    )?;
    Ok(())
}

/// Read all recent source timelines for one client. Older schema-2 databases
/// may not have this optional table yet; they read as empty until first write.
pub(crate) fn read_history(
    connection: &Connection,
    client: &str,
    now: f64,
) -> Result<Vec<ClientQuotaHistorySample>, String> {
    if !now.is_finite() {
        return Err("当前时间无效".into());
    }
    if !table_exists(connection).map_err(|error| error.to_string())? {
        return Ok(Vec::new());
    }
    let cutoff = now - HISTORY_SECONDS;
    let count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM client_quota_observations \
             WHERE client=?1 AND observed_at>=?2 AND observed_at<=?3",
            params![client, cutoff, now],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if count > MAX_ROWS_PER_CLIENT {
        return Err(format!(
            "{client} 最近 30 天有 {count} 条额度观测，超过 {} 条安全读取上限；未返回截断曲线",
            MAX_ROWS_PER_CLIENT
        ));
    }
    let mut statement = connection
        .prepare(
            "SELECT window_id,observed_at,used_percent,resets_at,source \
             FROM client_quota_observations \
             WHERE client=?1 AND observed_at>=?2 AND observed_at<=?3 \
             ORDER BY observed_at ASC,source COLLATE BINARY ASC,window_id COLLATE BINARY ASC",
        )
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map(params![client, cutoff, now], |row| {
            Ok(ClientQuotaHistorySample {
                window_id: row.get(0)?,
                observed_at: row.get(1)?,
                used_percent: row.get(2)?,
                resets_at: row.get(3)?,
                source: Some(row.get(4)?),
            })
        })
        .map_err(|error| error.to_string())?;
    let mut history = rows
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|error| error.to_string())?;
    history.retain(|sample| {
        sample.source.as_deref().is_some_and(|source| {
            valid_window_source(client, source, &sample.window_id)
                && sample
                    .resets_at
                    .is_none_or(|reset| reset > sample.observed_at)
        })
    });
    if history.iter().any(|sample| {
        !sample.observed_at.is_finite()
            || !sample.used_percent.is_finite()
            || !(0.0..=100.0).contains(&sample.used_percent)
            || sample.resets_at.is_some_and(|reset| !reset.is_finite())
    }) {
        return Err(format!("{client} 的额度历史含无效数值，未返回曲线"));
    }
    Ok(history)
}

fn table_exists(connection: &Connection) -> rusqlite::Result<bool> {
    connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [TABLE_NAME],
        |row| row.get(0),
    )
}

fn valid_window_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_WINDOW_ID_BYTES && !value.chars().any(char::is_control)
}

fn valid_record_state(state: &str) -> bool {
    matches!(state, "available" | "stale" | "cached")
}

fn valid_client(client: &str) -> bool {
    matches!(client, "claudeCode" | "claudeDesktop" | "antigravity")
}

fn valid_window_source(client: &str, source: &str, window_id: &str) -> bool {
    let allowed_source = match client {
        "claudeCode" => source == "local-statusline",
        "claudeDesktop" => {
            matches!(source, "local-desktop-history" | "local-desktop-http-cache")
        }
        "antigravity" => source == "local-antigravity-rpc",
        _ => false,
    };
    let allowed_window = match client {
        "claudeCode" | "claudeDesktop" => matches!(window_id, "5h" | "7d"),
        "antigravity" => matches!(
            window_id,
            "gemini-5h" | "gemini-weekly" | "3p-5h" | "3p-weekly"
        ),
        _ => false,
    };
    allowed_source && allowed_window && valid_window_id(window_id)
}

fn captured_epoch_seconds(value: Option<&str>) -> Option<f64> {
    let timestamp = OffsetDateTime::parse(value?, &Rfc3339).ok()?;
    let seconds = timestamp.unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    seconds.is_finite().then_some(seconds)
}

fn reset_epoch_seconds(value: Option<&str>) -> Option<f64> {
    let timestamp = OffsetDateTime::parse(value?, &Rfc3339).ok()?;
    let seconds = timestamp.unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    seconds.is_finite().then_some(seconds)
}

fn bucket_start(timestamp: f64) -> i64 {
    (timestamp / SAMPLE_BUCKET_SECONDS).floor() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::multi_client_product::QuotaProviderWindow;

    fn open_schema_two_without_history() -> Connection {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE client_usage_events(client TEXT NOT NULL,event_id TEXT NOT NULL,session_id TEXT NOT NULL,model TEXT NOT NULL,timestamp REAL NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,payload TEXT NOT NULL,PRIMARY KEY(client,event_id));\
                 CREATE TABLE client_usage_revisions(revision INTEGER PRIMARY KEY AUTOINCREMENT,client TEXT NOT NULL,event_id TEXT NOT NULL,captured_at REAL NOT NULL,payload TEXT NOT NULL);\
                 CREATE TABLE client_file_checkpoints(client TEXT NOT NULL,source_key TEXT NOT NULL,offset INTEGER NOT NULL,size INTEGER NOT NULL,modified REAL NOT NULL,identity TEXT NOT NULL,PRIMARY KEY(client,source_key));\
                 CREATE TABLE multi_usage_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);\
                 PRAGMA user_version=2;",
            )
            .unwrap();
        connection
    }

    fn reading(
        client: &str,
        source: &str,
        state: &str,
        captured_at: Option<String>,
        used: f64,
    ) -> QuotaProviderSnapshot {
        QuotaProviderSnapshot {
            client: client.into(),
            state: state.into(),
            source: source.into(),
            captured_at,
            windows: vec![QuotaProviderWindow {
                id: Some(
                    if client == "antigravity" {
                        "gemini-5h"
                    } else {
                        "5h"
                    }
                    .into(),
                ),
                label: "5h".into(),
                used_percent: Some(used),
                resets_at: Some("1970-01-01T02:00:00Z".into()),
            }],
            notice: String::new(),
            history: Vec::new(),
        }
    }

    fn timestamp(seconds: i64) -> String {
        OffsetDateTime::from_unix_timestamp(seconds)
            .unwrap()
            .format(&Rfc3339)
            .unwrap()
    }

    #[test]
    fn older_schema_two_reads_empty_then_lazily_adds_optional_history_table() {
        let connection = open_schema_two_without_history();
        assert!(read_history(&connection, "claudeDesktop", 2_000.0)
            .unwrap()
            .is_empty());
        assert!(!table_exists(&connection).unwrap());
        let reading = reading(
            "claudeDesktop",
            "local-desktop-history",
            "available",
            Some(timestamp(1_000)),
            12.5,
        );
        record_history(&connection, &[reading], 2_000.0).unwrap();
        let history = read_history(&connection, "claudeDesktop", 2_000.0).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].source.as_deref(), Some("local-desktop-history"));
        let version: i64 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, 2);
    }

    #[test]
    fn identical_samples_dedupe_per_five_minutes_and_changed_fraction_is_kept() {
        let connection = Connection::open_in_memory().unwrap();
        let first = reading(
            "claudeDesktop",
            "local-desktop-history",
            "available",
            Some(timestamp(1_000)),
            12.345,
        );
        record_history(&connection, &[first.clone()], 2_000.0).unwrap();
        let repeated = reading(
            "claudeDesktop",
            "local-desktop-history",
            "available",
            Some(timestamp(1_100)),
            12.345,
        );
        record_history(&connection, &[repeated], 2_000.0).unwrap();
        let changed = reading(
            "claudeDesktop",
            "local-desktop-history",
            "available",
            Some(timestamp(1_101)),
            12.346,
        );
        record_history(&connection, &[changed], 2_000.0).unwrap();
        let history = read_history(&connection, "claudeDesktop", 2_000.0).unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].used_percent, 12.345);
        assert_eq!(history[1].used_percent, 12.346);

        let same_timestamp_update = reading(
            "claudeDesktop",
            "local-desktop-history",
            "available",
            Some(timestamp(1_101)),
            12.347,
        );
        record_history(&connection, &[same_timestamp_update], 2_000.0).unwrap();
        let history = read_history(&connection, "claudeDesktop", 2_000.0).unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[1].used_percent, 12.347);
    }

    #[test]
    fn rejects_unknown_future_api_and_invalid_percentage_observations() {
        let connection = Connection::open_in_memory().unwrap();
        let readings = [
            reading(
                "claudeDesktop",
                "local-desktop-history",
                "available",
                None,
                10.0,
            ),
            reading(
                "claudeDesktop",
                "local-desktop-history",
                "available",
                Some(timestamp(2_001)),
                10.0,
            ),
            reading(
                "claudeCode",
                "local-statusline",
                "api",
                Some(timestamp(1_000)),
                10.0,
            ),
            reading(
                "antigravity",
                "local-antigravity-rpc",
                "available",
                Some(timestamp(1_000)),
                100.01,
            ),
            reading(
                "futureClient",
                "local-statusline",
                "available",
                Some(timestamp(1_000)),
                10.0,
            ),
        ];
        record_history(&connection, &readings, 2_000.0).unwrap();
        let total: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM client_quota_observations",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(total, 0);

        let mut expired = reading(
            "claudeDesktop",
            "local-desktop-history",
            "available",
            Some(timestamp(1_000)),
            10.0,
        );
        expired.windows[0].resets_at = Some(timestamp(1_000));
        record_history(&connection, &[expired], 2_000.0).unwrap();
        let total: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM client_quota_observations",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(total, 0);
    }

    #[test]
    fn reads_keep_client_sources_separate_for_frontend_filtering() {
        let connection = Connection::open_in_memory().unwrap();
        let readings = [
            reading(
                "claudeDesktop",
                "local-desktop-history",
                "available",
                Some(timestamp(1_000)),
                10.0,
            ),
            reading(
                "antigravity",
                "local-antigravity-rpc",
                "available",
                Some(timestamp(1_000)),
                20.0,
            ),
            reading(
                "claudeDesktop",
                "local-desktop-http-cache",
                "available",
                Some(timestamp(1_000)),
                30.0,
            ),
        ];
        record_history(&connection, &readings, 2_000.0).unwrap();
        let desktop = read_history(&connection, "claudeDesktop", 2_000.0).unwrap();
        assert_eq!(desktop.len(), 2);
        assert!(desktop.iter().any(|sample| sample.source.as_deref()
            == Some("local-desktop-history")
            && sample.used_percent == 10.0));
        assert!(desktop.iter().any(|sample| sample.source.as_deref()
            == Some("local-desktop-http-cache")
            && sample.used_percent == 30.0));
        let antigravity = read_history(&connection, "antigravity", 2_000.0).unwrap();
        assert_eq!(antigravity.len(), 1);
        assert_eq!(
            antigravity[0].source.as_deref(),
            Some("local-antigravity-rpc")
        );
        assert_eq!(antigravity[0].used_percent, 20.0);
    }
}
