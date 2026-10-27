//! Durable numeric history and sparse five-minute completed-body speed trends.
//!
//! Callers retain the historical logical path; production routes its source
//! partition into business container A. Isolated tests use plain SQLite files.
//! Payloads contain measurements and metadata only, never response text.

use crate::models::SpeedSample;
use rusqlite::{params, OptionalExtension, TransactionBehavior};
#[cfg(test)]
use rusqlite::{Connection, Transaction};
#[cfg(not(test))]
use crate::core::business_store_connection::{StoreConnection as Connection, StoreTransaction as Transaction};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

const BUCKET_SECONDS: i64 = 300;
const DEDUP_RETENTION_SECONDS: f64 = 30.0 * 86_400.0;
const AGGREGATE_RETENTION_SECONDS: f64 = 90.0 * 86_400.0;
const MAX_BACKFILL_SECONDS: f64 = 30.0 * 86_400.0;
const SCHEMA_VERSION: &str = "1";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BodySpeedTrendPoint {
    /// UTC Unix seconds, aligned to five minutes, thirty minutes, or two hours.
    pub bucket_start: i64,
    pub model: String,
    pub output_tokens: i64,
    pub duration_seconds: f64,
    pub sample_count: i64,
    pub tokens_per_second: f64,
}

#[derive(Clone, Debug)]
struct TrendRow {
    ended_at: f64,
    bucket_start: i64,
    model: String,
    output_tokens: i64,
    duration_seconds: f64,
    eligible: bool,
}

/// SQLite storage for completed-body detail rows and their weighted speed trend.
/// The host decides when sample revisions change and calls `ingest` only then.
pub struct BodySpeedTrendStore {
    path: PathBuf,
}

impl BodySpeedTrendStore {
    pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Self> {
        let store = Self {
            path: path.as_ref().to_path_buf(),
        };
        let connection = store.connect()?;
        Self::create_schema(&connection)?;
        Ok(store)
    }

    /// Upsert numeric body history and adjust old/new trend contributions atomically.
    /// `retention_days` accepts 15 or 30; all other values use the 30-day default.
    pub fn ingest(
        &self,
        samples: &[SpeedSample],
        now: f64,
        retention_days: u16,
    ) -> rusqlite::Result<usize> {
        if !safe_now(now) {
            return Ok(0);
        }
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = Self::ingest_transaction(
            &transaction,
            samples,
            now,
            normalized_retention_days(retention_days),
        )?;
        transaction.commit()?;
        Ok(changed)
    }

    /// Load retained numeric body samples oldest to newest for in-memory bootstrap.
    pub fn read_samples(
        &self,
        now: f64,
        retention_days: u16,
    ) -> rusqlite::Result<Vec<SpeedSample>> {
        if !safe_now(now) {
            return Ok(Vec::new());
        }
        let retention_days = normalized_retention_days(retention_days);
        let connection = self.connect()?;
        let mut statement = connection.prepare(
            "SELECT payload_json FROM speed_samples \
             WHERE ended_at >= ?1 AND ended_at <= ?2 \
             ORDER BY ended_at ASC, id ASC",
        )?;
        let mut rows = statement.query(params![now - f64::from(retention_days) * 86_400.0, now])?;
        let mut samples = Vec::new();
        while let Some(row) = rows.next()? {
            let json: String = row.get(0)?;
            let sample = serde_json::from_str(&json).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })?;
            samples.push(sample);
        }
        Ok(samples)
    }

    /// Read the persisted raw-history preference. Invalid metadata is treated as a
    /// database error so callers do not silently replace an unreadable setting.
    pub fn retention_days(&self) -> rusqlite::Result<u16> {
        let connection = self.connect()?;
        let value: String = connection.query_row(
            "SELECT value FROM speed_trend_meta WHERE key = 'body_retention_days'",
            [],
            |row| row.get(0),
        )?;
        let days = value
            .parse::<u16>()
            .map_err(|_| rusqlite::Error::InvalidQuery)?;
        if matches!(days, 15 | 30) {
            Ok(days)
        } else {
            Err(rusqlite::Error::InvalidQuery)
        }
    }

    /// Return sparse five-minute, thirty-minute, or two-hour weighted points.
    pub fn read(&self, now: f64, days: u16) -> rusqlite::Result<Vec<BodySpeedTrendPoint>> {
        if !safe_now(now) || !matches!(days, 1 | 7 | 30) {
            return Ok(Vec::new());
        }
        let resolution = match days {
            1 => 300_i64,
            7 => 1_800_i64,
            30 => 7_200_i64,
            _ => unreachable!(),
        };
        let cutoff = now - f64::from(days) * 86_400.0;
        let first_bucket = bucket_start(cutoff).unwrap_or(0);
        let last_bucket = bucket_start(now).unwrap_or(0);
        let max_points = (i64::from(days) * 86_400) / resolution;
        let connection = self.connect()?;
        let mut statement = connection.prepare(
            "WITH grouped AS ( \
                 SELECT (bucket_start / ?1) * ?1 AS bucket_start, model, \
                        SUM(output_tokens) AS output_tokens, \
                        SUM(duration_seconds) AS duration_seconds, \
                        SUM(sample_count) AS sample_count \
                 FROM speed_5m WHERE bucket_start >= ?2 AND bucket_start <= ?3 \
                 GROUP BY (bucket_start / ?1) * ?1, model \
             ), ranked AS ( \
                 SELECT bucket_start, model, output_tokens, duration_seconds, sample_count, \
                        ROW_NUMBER() OVER (PARTITION BY model ORDER BY bucket_start DESC) AS point_rank \
                 FROM grouped \
             ) \
             SELECT bucket_start, model, output_tokens, duration_seconds, sample_count \
             FROM ranked WHERE point_rank <= ?4 \
             ORDER BY bucket_start ASC, model ASC",
        )?;
        let mut rows =
            statement.query(params![resolution, first_bucket, last_bucket, max_points])?;
        let mut points = Vec::new();
        while let Some(row) = rows.next()? {
            let bucket_start: i64 = row.get(0)?;
            let model: String = row.get(1)?;
            let output_tokens: i64 = row.get(2)?;
            let duration_seconds: f64 = row.get(3)?;
            let sample_count: i64 = row.get(4)?;
            if output_tokens <= 0
                || sample_count <= 0
                || !duration_seconds.is_finite()
                || duration_seconds <= 0.0
            {
                continue;
            }
            let tokens_per_second = output_tokens as f64 / duration_seconds;
            if !tokens_per_second.is_finite() || tokens_per_second <= 0.0 {
                continue;
            }
            points.push(BodySpeedTrendPoint {
                bucket_start,
                model,
                output_tokens,
                duration_seconds,
                sample_count,
                tokens_per_second,
            });
        }
        Ok(points)
    }

    fn connect(&self) -> rusqlite::Result<Connection> {
        #[cfg(test)]
        let connection = Connection::open(&self.path)?;
        #[cfg(not(test))]
        let connection = {
            let identity = self.path.file_name().and_then(|name| name.to_str())
                .ok_or_else(|| rusqlite::Error::InvalidPath(self.path.clone()))?;
            let logical = format!("body-speed/{identity}");
            crate::core::business_store_route::open_store("body-speed", identity, &logical, &[self.path.clone()])
                .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error))))?
        };
        connection.busy_timeout(Duration::from_secs(3))?;
        Ok(connection)
    }

    fn create_schema(connection: &Connection) -> rusqlite::Result<()> {
        connection.execute(
            "CREATE TABLE IF NOT EXISTS speed_trend_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID",
            [],
        )?;
        let existing: Option<String> = connection
            .query_row(
                "SELECT value FROM speed_trend_meta WHERE key = 'schema_version'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if existing
            .as_deref()
            .is_some_and(|value| value != SCHEMA_VERSION)
        {
            return Err(rusqlite::Error::InvalidQuery);
        }
        connection.execute(
            "INSERT OR IGNORE INTO speed_trend_meta(key, value) VALUES('schema_version', ?1)",
            [SCHEMA_VERSION],
        )?;
        connection.execute(
            "INSERT OR IGNORE INTO speed_trend_meta(key, value) VALUES('body_retention_days', '30')",
            [],
        )?;
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS speed_samples (\
                 id TEXT PRIMARY KEY NOT NULL, ended_at REAL NOT NULL, model TEXT NOT NULL, \
                 included INTEGER NOT NULL, payload_json TEXT NOT NULL\
             ) WITHOUT ROWID;\
             CREATE INDEX IF NOT EXISTS speed_samples_ended_model ON speed_samples(ended_at, model);\
             CREATE INDEX IF NOT EXISTS speed_samples_model_ended ON speed_samples(model, ended_at);\
             CREATE TABLE IF NOT EXISTS speed_sample_ids (\
                 id TEXT PRIMARY KEY NOT NULL, ended_at REAL NOT NULL, bucket_start INTEGER NOT NULL, \
                 model TEXT NOT NULL, output_tokens INTEGER NOT NULL, duration_seconds REAL NOT NULL, \
                 trend_eligible INTEGER NOT NULL\
             ) WITHOUT ROWID;\
             CREATE INDEX IF NOT EXISTS speed_sample_ids_ended ON speed_sample_ids(ended_at);\
             CREATE TABLE IF NOT EXISTS speed_5m (\
                 bucket_start INTEGER NOT NULL, model TEXT NOT NULL, output_tokens INTEGER NOT NULL, \
                 duration_seconds REAL NOT NULL, sample_count INTEGER NOT NULL, \
                 PRIMARY KEY(bucket_start, model)\
             ) WITHOUT ROWID;",
        )?;
        Ok(())
    }

    fn ingest_transaction(
        transaction: &Transaction<'_>,
        samples: &[SpeedSample],
        now: f64,
        retention_days: u16,
    ) -> rusqlite::Result<usize> {
        let raw_cutoff = now - f64::from(retention_days) * 86_400.0;
        let id_cutoff = now - DEDUP_RETENTION_SECONDS;
        let trend_cutoff = now - MAX_BACKFILL_SECONDS;
        let mut changed_ids = HashSet::new();

        transaction.execute(
            "INSERT INTO speed_trend_meta(key, value) VALUES('body_retention_days', ?1) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [retention_days.to_string()],
        )?;

        let mut raw_upsert = transaction.prepare_cached(
            "INSERT INTO speed_samples(id, ended_at, model, included, payload_json) \
             VALUES(?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT(id) DO UPDATE SET ended_at = excluded.ended_at, model = excluded.model, \
                 included = excluded.included, payload_json = excluded.payload_json \
             WHERE speed_samples.ended_at != excluded.ended_at \
                OR speed_samples.model != excluded.model \
                OR speed_samples.included != excluded.included \
                OR speed_samples.payload_json != excluded.payload_json",
        )?;
        let mut insert_id = transaction.prepare_cached(
            "INSERT INTO speed_sample_ids(id, ended_at, bucket_start, model, output_tokens, duration_seconds, trend_eligible) \
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(id) DO NOTHING",
        )?;
        let mut select_id = transaction.prepare_cached(
            "SELECT ended_at, bucket_start, model, output_tokens, duration_seconds, trend_eligible \
             FROM speed_sample_ids WHERE id = ?1",
        )?;
        let mut update_id = transaction.prepare_cached(
            "UPDATE speed_sample_ids SET ended_at = ?1, bucket_start = ?2, model = ?3, \
                 output_tokens = ?4, duration_seconds = ?5, trend_eligible = ?6 WHERE id = ?7",
        )?;
        let mut add_aggregate = transaction.prepare_cached(
            "INSERT INTO speed_5m(bucket_start, model, output_tokens, duration_seconds, sample_count) \
             VALUES(?1, ?2, ?3, ?4, 1) ON CONFLICT(bucket_start, model) DO UPDATE SET \
                 output_tokens = output_tokens + excluded.output_tokens, \
                 duration_seconds = duration_seconds + excluded.duration_seconds, \
                 sample_count = sample_count + 1 \
             WHERE output_tokens <= 9223372036854775807 - excluded.output_tokens \
               AND sample_count < 9223372036854775807 \
               AND duration_seconds <= 1.7976931348623157e308 - excluded.duration_seconds",
        )?;
        let mut subtract_aggregate = transaction.prepare_cached(
            "UPDATE speed_5m SET output_tokens = output_tokens - ?1, \
                 duration_seconds = duration_seconds - ?2, sample_count = sample_count - 1 \
             WHERE bucket_start = ?3 AND model = ?4 \
               AND output_tokens >= ?1 AND sample_count > 0",
        )?;
        let mut remove_empty = transaction.prepare_cached(
            "DELETE FROM speed_5m WHERE bucket_start = ?1 AND model = ?2 AND sample_count <= 0",
        )?;

        for sample in samples {
            if !valid_raw_body_sample(sample) || sample.ended_at > now {
                continue;
            }
            let model = sample.model.as_deref().unwrap_or("unknown");
            let age = now - sample.ended_at;
            if age <= f64::from(retention_days) * 86_400.0 {
                let payload_json = serde_json::to_string(sample)
                    .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
                if raw_upsert.execute(params![
                    sample.id,
                    sample.ended_at,
                    model,
                    if body_sample_is_qualified(sample) {
                        1_i64
                    } else {
                        0_i64
                    },
                    payload_json
                ])? > 0
                {
                    changed_ids.insert(sample.id.as_str());
                }
            }

            if sample.ended_at < trend_cutoff {
                continue;
            }
            let Some(bucket) = bucket_start(sample.ended_at) else {
                continue;
            };
            let eligible =
                body_sample_is_qualified(sample) && recognized_model(sample.model.as_deref());
            let trend_model = model;
            let output_tokens = i64::from(sample.output_tokens);
            let duration = sample.duration_seconds;
            let inserted = insert_id.execute(params![
                sample.id,
                sample.ended_at,
                bucket,
                trend_model,
                output_tokens,
                duration,
                if eligible { 1_i64 } else { 0_i64 }
            ])? > 0;
            if inserted {
                if eligible {
                    if add_aggregate.execute(params![
                        bucket,
                        trend_model,
                        output_tokens,
                        duration
                    ])? == 0
                    {
                        return Err(rusqlite::Error::InvalidQuery);
                    }
                }
                changed_ids.insert(sample.id.as_str());
                continue;
            }

            let old = select_id
                .query_row([sample.id.as_str()], |row| {
                    Ok(TrendRow {
                        ended_at: row.get(0)?,
                        bucket_start: row.get(1)?,
                        model: row.get(2)?,
                        output_tokens: row.get(3)?,
                        duration_seconds: row.get(4)?,
                        eligible: row.get::<_, i64>(5)? == 1,
                    })
                })
                .optional()?;
            let Some(old) = old else { continue };
            let same = old.ended_at == sample.ended_at
                && old.bucket_start == bucket
                && old.model == trend_model
                && old.output_tokens == output_tokens
                && old.duration_seconds == duration
                && old.eligible == eligible;
            if same {
                continue;
            }
            if old.eligible {
                if subtract_aggregate.execute(params![
                    old.output_tokens,
                    old.duration_seconds,
                    old.bucket_start,
                    old.model
                ])? == 0
                {
                    return Err(rusqlite::Error::InvalidQuery);
                }
                remove_empty.execute(params![old.bucket_start, old.model])?;
            }
            update_id.execute(params![
                sample.ended_at,
                bucket,
                trend_model,
                output_tokens,
                duration,
                if eligible { 1_i64 } else { 0_i64 },
                sample.id
            ])?;
            if eligible {
                if add_aggregate.execute(params![bucket, trend_model, output_tokens, duration])?
                    == 0
                {
                    return Err(rusqlite::Error::InvalidQuery);
                }
            }
            changed_ids.insert(sample.id.as_str());
        }

        transaction.execute(
            "DELETE FROM speed_samples WHERE ended_at < ?1",
            [raw_cutoff],
        )?;
        transaction.execute(
            "DELETE FROM speed_sample_ids WHERE ended_at < ?1",
            [id_cutoff],
        )?;
        let aggregate_cutoff = bucket_start(now - AGGREGATE_RETENTION_SECONDS).unwrap_or(i64::MIN);
        transaction.execute(
            "DELETE FROM speed_5m WHERE bucket_start < ?1",
            [aggregate_cutoff],
        )?;
        Ok(changed_ids.len())
    }
}

fn normalized_retention_days(days: u16) -> u16 {
    if matches!(days, 15 | 30) {
        days
    } else {
        30
    }
}

fn safe_now(now: f64) -> bool {
    now.is_finite() && now >= 0.0 && now < i64::MAX as f64 - AGGREGATE_RETENTION_SECONDS
}

fn bucket_start(timestamp: f64) -> Option<i64> {
    if !timestamp.is_finite() || timestamp < 0.0 {
        return None;
    }
    let bucket = (timestamp / BUCKET_SECONDS as f64).floor() * BUCKET_SECONDS as f64;
    (bucket.is_finite() && bucket < i64::MAX as f64).then_some(bucket as i64)
}

fn is_completed_body_sample(sample: &SpeedSample) -> bool {
    sample.measurement_kind.as_deref() == Some("completed_body")
        && sample.tokenizer.as_deref() == Some("o200k_base")
}

fn recognized_model(model: Option<&str>) -> bool {
    model.is_some_and(|model| {
        let trimmed = model.trim();
        !trimmed.is_empty() && !trimmed.eq_ignore_ascii_case("unknown")
    })
}

/// Reuse the completed-body trust policy without applying a token-count threshold.
fn body_sample_is_qualified(sample: &SpeedSample) -> bool {
    let mut effective = sample.clone();
    super::completed_body::apply_body_quality(&mut effective);
    matches!(effective.confidence.as_str(), "medium" | "high")
}

/// History preserves low-confidence body measurements, while excluding malformed rows.
fn valid_raw_body_sample(sample: &SpeedSample) -> bool {
    is_completed_body_sample(sample)
        && !sample.id.is_empty()
        && sample.id.len() <= 128
        && !sample.thread_id.is_empty()
        && sample.thread_id.len() <= 512
        && !sample.turn_id.is_empty()
        && sample.turn_id.len() <= 512
        && !sample.item_id.is_empty()
        && sample.item_id.len() <= 512
        && sample.model.as_ref().is_none_or(|model| model.len() <= 256)
        && sample
            .network_warning
            .as_ref()
            .is_none_or(|warning| warning.len() <= 512)
        && sample.source.len() <= 128
        && matches!(sample.confidence.as_str(), "low" | "medium" | "high")
        && sample
            .body_phase
            .as_ref()
            .is_none_or(|phase| phase.len() <= 64)
        && sample
            .quality_reason
            .as_ref()
            .is_none_or(|reason| reason.len() <= 256)
        && sample.started_at.is_finite()
        && sample.ended_at.is_finite()
        && sample.duration_seconds.is_finite()
        && sample.tokens_per_second.is_finite()
        && sample.started_at >= 0.0
        && sample.ended_at >= sample.started_at
        && sample.duration_seconds >= 0.0
        && sample.tokens_per_second >= 0.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use uuid::Uuid;

    fn store() -> (BodySpeedTrendStore, PathBuf) {
        let path = std::env::temp_dir().join(format!("speed-trend-{}.sqlite", Uuid::new_v4()));
        (BodySpeedTrendStore::open(&path).unwrap(), path)
    }

    fn sample(
        id: &str,
        model: Option<&str>,
        ended_at: f64,
        tokens: u32,
        duration: f64,
        warning: Option<&str>,
    ) -> SpeedSample {
        SpeedSample {
            id: id.into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            item_id: id.into(),
            model: model.map(str::to_owned),
            started_at: ended_at - duration,
            ended_at,
            output_tokens: tokens,
            output_characters: u64::from(tokens),
            output_bytes: u64::from(tokens),
            chunk_count: 4,
            duration_seconds: duration,
            tokens_per_second: f64::from(tokens) / duration,
            confidence: "medium".into(),
            network_warning: warning.map(str::to_owned),
            source: "test".into(),
            measurement_kind: Some("completed_body".into()),
            tokenizer: Some("o200k_base".into()),
            body_phase: Some("final_answer".into()),
            quality_reason: None,
        }
    }

    #[test]
    fn ingestion_is_idempotent_and_changed_sample_replaces_its_contribution() {
        let (store, path) = store();
        let now = 1_728_000.0 + 60.0;
        let first = sample("one", Some("model-a"), now, 100, 2.0, None);
        store
            .ingest(&[first.clone(), first.clone()], now, 30)
            .unwrap();
        let initial = store.read(now, 1).unwrap();
        assert_eq!(initial.len(), 1);
        assert_eq!(initial[0].output_tokens, 100);
        assert_eq!(initial[0].sample_count, 1);

        let corrected = sample("one", Some("model-b"), now, 200, 4.0, None);
        store.ingest(&[corrected], now, 30).unwrap();
        let updated = store.read(now, 1).unwrap();
        assert_eq!(updated.len(), 1);
        assert_eq!(updated[0].model, "model-b");
        assert_eq!(updated[0].output_tokens, 200);
        assert_eq!(updated[0].tokens_per_second, 50.0);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn sparse_rollups_keep_weighted_rates_and_models_separate() {
        let (store, path) = store();
        let base = 1_728_000.0;
        let now = base + 86_400.0;
        let samples = [
            sample("a", Some("model-a"), base + 60.0, 100, 2.0, None),
            sample("b", Some("model-a"), base + 360.0, 300, 6.0, None),
            sample("c", Some("model-a"), base + 1_860.0, 50, 1.0, None),
            sample("d", Some("model-b"), base + 7_260.0, 200, 4.0, None),
        ];
        store.ingest(&samples, now, 30).unwrap();
        let five_minute = store.read(now, 1).unwrap();
        assert_eq!(five_minute.len(), 4);
        assert!(five_minute
            .iter()
            .all(|point| point.tokens_per_second == 50.0));
        let thirty_minute = store.read(now, 7).unwrap();
        assert_eq!(thirty_minute.len(), 3);
        let merged = thirty_minute
            .iter()
            .find(|point| point.model == "model-a")
            .unwrap();
        assert_eq!(merged.sample_count, 2);
        assert_eq!(merged.output_tokens, 400);
        assert_eq!(merged.duration_seconds, 8.0);
        assert_eq!(merged.tokens_per_second, 50.0);
        let two_hour = store.read(now, 30).unwrap();
        assert_eq!(two_hour.len(), 2);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn history_keeps_low_quality_and_small_qualifying_samples_after_raw_expiry() {
        let (store, path) = store();
        let now = 2_000_000.0 + 60.0;
        let small = sample("small", Some("model-a"), now, 3, 1.0, None);
        let warned = sample(
            "warned",
            Some("model-a"),
            now,
            100,
            2.0,
            Some("network pause"),
        );
        store
            .ingest(&[small.clone(), warned.clone()], now, 15)
            .unwrap();
        assert_eq!(store.retention_days().unwrap(), 15);
        assert_eq!(store.read(now, 1).unwrap().len(), 1);
        assert_eq!(store.read_samples(now, 15).unwrap().len(), 2);

        let later = now + 20.0 * 86_400.0;
        store.ingest(&[], later, 15).unwrap();
        assert!(store.read_samples(later, 15).unwrap().is_empty());
        assert_eq!(store.read(later, 30).unwrap().len(), 1);
        assert_eq!(
            BodySpeedTrendStore::open(&path)
                .unwrap()
                .retention_days()
                .unwrap(),
            15
        );
        let _ = fs::remove_file(path);
    }

    #[test]
    fn future_and_nonfinite_samples_are_rejected_but_unknown_model_history_is_kept() {
        let (store, path) = store();
        let now = 2_500_000.0 + 60.0;
        let unknown = sample("unknown", Some("unknown"), now, 100, 2.0, None);
        let future = sample("future", Some("model-a"), now + 3_600.0, 100, 2.0, None);
        let mut nonfinite = sample("nonfinite", Some("model-a"), now, 100, 2.0, None);
        nonfinite.tokens_per_second = f64::INFINITY;
        store
            .ingest(&[unknown, future, nonfinite], now, 30)
            .unwrap();
        assert!(store.read(now, 1).unwrap().is_empty());
        let history = store.read_samples(now, 30).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].id, "unknown");
        let _ = fs::remove_file(path);
    }
}
