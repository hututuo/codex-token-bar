//! Durable numeric history and sparse five-minute completed-body speed trends.
//!
//! Callers retain the historical logical path; production migrates the old A
//! partition into a source-scoped namespace in shared usage database B. Isolated
//! tests use plain SQLite files.
//! Payloads contain measurements and metadata only, never response text.

#[cfg(not(test))]
use crate::core::business_store_connection::{
    StoreConnection as Connection, StoreTransaction as Transaction,
};
use crate::models::SpeedSample;
use rusqlite::{params, OptionalExtension, TransactionBehavior};
#[cfg(test)]
use rusqlite::{Connection, Transaction};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

mod migration;
mod legacy_json;

const BUCKET_SECONDS: i64 = 300;
const DEDUP_RETENTION_SECONDS: f64 = 30.0 * 86_400.0;
const AGGREGATE_RETENTION_SECONDS: f64 = 90.0 * 86_400.0;
const MAX_BACKFILL_SECONDS: f64 = 30.0 * 86_400.0;
const SCHEMA_VERSION: &str = "1";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BodySpeedTrendPoint {
    /// UTC Unix seconds, aligned to a display bucket boundary.
    pub bucket_start: i64,
    pub model: String,
    pub output_tokens: i64,
    pub duration_seconds: f64,
    pub sample_count: i64,
    pub tokens_per_second: f64,
    pub bucket_end: Option<i64>,
    pub lower_quartile: Option<f64>,
    pub median: Option<f64>,
    pub upper_quartile: Option<f64>,
    pub bucket_count: Option<i64>,
    pub is_partial: Option<bool>,
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

#[derive(Debug)]
struct DistributionBucket {
    output_tokens: i64,
    duration_seconds: f64,
    sample_count: i64,
    five_minute_rates: Vec<f64>,
}

/// SQLite storage for completed-body detail rows and their weighted speed trend.
/// The host decides when sample revisions change and calls `ingest` only then.
pub struct BodySpeedTrendStore {
    path: PathBuf,
    shared_path: Option<PathBuf>,
}

impl BodySpeedTrendStore {
    pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Self> {
        let store = Self {
            path: path.as_ref().to_path_buf(),
            shared_path: None,
        };
        let connection = store.connect()?;
        Self::create_schema(&connection)?;
        Ok(store)
    }

    /// Open the shared multi-client database, migrating the old A partition
    /// once. Isolated tests continue to use `open` and a plain SQLite file.
    pub fn open_shared(
        legacy_path: impl AsRef<Path>,
        shared_path: impl AsRef<Path>,
    ) -> rusqlite::Result<Self> {
        let store = Self {
            path: legacy_path.as_ref().to_path_buf(),
            shared_path: Some(shared_path.as_ref().to_path_buf()),
        };
        #[cfg(not(test))]
        migration::migrate_body_speed_to_shared(&store.path, store.shared_path.as_ref().unwrap())?;
        let connection = store.connect()?;
        Self::create_schema(&connection)?;
        Ok(store)
    }

    /// Public releases through v0.9.7 persisted these samples in a JSON sibling.
    /// Run after the SQLite/A migration and before choosing the stored retention.
    pub(super) fn import_legacy_json(&self, now: f64) -> rusqlite::Result<()> {
        legacy_json::import(self, now)
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
                bucket_end: None,
                lower_quartile: None,
                median: None,
                upper_quartile: None,
                bucket_count: None,
                is_partial: None,
            });
        }
        Ok(points)
    }

    /// Read completed five-minute rows and summarize their per-row rates into
    /// fixed UTC display buckets. Quantiles weight each five-minute row equally.
    pub fn read_distribution(
        &self,
        now: f64,
        days: u16,
    ) -> rusqlite::Result<Vec<BodySpeedTrendPoint>> {
        if !safe_now(now) || !matches!(days, 1 | 7 | 30) {
            return Ok(Vec::new());
        }
        let resolution = match days {
            1 => 1_800_i64,
            7 => 7_200_i64,
            30 => 21_600_i64,
            _ => unreachable!(),
        };
        let cutoff = now - f64::from(days) * 86_400.0;
        let first_bucket = ceil_bucket_start(cutoff).ok_or(rusqlite::Error::InvalidQuery)?;
        let last_completed_boundary = bucket_start(now).ok_or(rusqlite::Error::InvalidQuery)?;
        if first_bucket >= last_completed_boundary {
            return Ok(Vec::new());
        }

        let connection = self.connect()?;
        let mut statement = connection.prepare(
            "SELECT bucket_start, model, output_tokens, duration_seconds, sample_count \
             FROM speed_5m WHERE bucket_start >= ?1 AND bucket_start < ?2 \
             ORDER BY bucket_start ASC, model ASC",
        )?;
        let mut rows = statement.query(params![first_bucket, last_completed_boundary])?;
        let mut grouped: std::collections::BTreeMap<(i64, String), DistributionBucket> =
            std::collections::BTreeMap::new();
        while let Some(row) = rows.next()? {
            let five_minute_start: i64 = row.get(0)?;
            let model: String = row.get(1)?;
            let output_tokens: i64 = row.get(2)?;
            let duration_seconds: f64 = row.get(3)?;
            let sample_count: i64 = row.get(4)?;
            if output_tokens <= 0
                || sample_count <= 0
                || !duration_seconds.is_finite()
                || duration_seconds <= 0.0
            {
                return Err(rusqlite::Error::InvalidQuery);
            }
            let five_minute_rate = output_tokens as f64 / duration_seconds;
            if !five_minute_rate.is_finite() || five_minute_rate <= 0.0 {
                return Err(rusqlite::Error::InvalidQuery);
            }

            let display_bucket_start = five_minute_start.div_euclid(resolution) * resolution;
            let bucket = grouped
                .entry((display_bucket_start, model))
                .or_insert_with(|| DistributionBucket {
                    output_tokens: 0,
                    duration_seconds: 0.0,
                    sample_count: 0,
                    five_minute_rates: Vec::new(),
                });
            bucket.output_tokens = bucket
                .output_tokens
                .checked_add(output_tokens)
                .ok_or(rusqlite::Error::InvalidQuery)?;
            bucket.sample_count = bucket
                .sample_count
                .checked_add(sample_count)
                .ok_or(rusqlite::Error::InvalidQuery)?;
            bucket.duration_seconds += duration_seconds;
            if !bucket.duration_seconds.is_finite() {
                return Err(rusqlite::Error::InvalidQuery);
            }
            bucket.five_minute_rates.push(five_minute_rate);
        }

        let mut points = Vec::new();
        for ((bucket_start, model), mut bucket) in grouped {
            let bucket_count = i64::try_from(bucket.five_minute_rates.len())
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            if bucket_count < 3 || bucket.sample_count < 6 {
                continue;
            }
            bucket.five_minute_rates.sort_by(f64::total_cmp);
            let lower_quartile = type7_quantile(&bucket.five_minute_rates, 0.25)
                .ok_or(rusqlite::Error::InvalidQuery)?;
            let median = type7_quantile(&bucket.five_minute_rates, 0.50)
                .ok_or(rusqlite::Error::InvalidQuery)?;
            let upper_quartile = type7_quantile(&bucket.five_minute_rates, 0.75)
                .ok_or(rusqlite::Error::InvalidQuery)?;
            let tokens_per_second = bucket.output_tokens as f64 / bucket.duration_seconds;
            if !tokens_per_second.is_finite() || tokens_per_second <= 0.0 {
                return Err(rusqlite::Error::InvalidQuery);
            }
            let nominal_bucket_end = bucket_start
                .checked_add(resolution)
                .ok_or(rusqlite::Error::InvalidQuery)?;
            points.push(BodySpeedTrendPoint {
                bucket_start,
                model,
                output_tokens: bucket.output_tokens,
                duration_seconds: bucket.duration_seconds,
                sample_count: bucket.sample_count,
                tokens_per_second,
                bucket_end: Some(nominal_bucket_end.min(last_completed_boundary)),
                lower_quartile: Some(lower_quartile),
                median: Some(median),
                upper_quartile: Some(upper_quartile),
                bucket_count: Some(bucket_count),
                is_partial: Some(nominal_bucket_end > last_completed_boundary),
            });
        }
        Ok(points)
    }

    fn connect(&self) -> rusqlite::Result<Connection> {
        #[cfg(test)]
        let connection = Connection::open(self.shared_path.as_ref().unwrap_or(&self.path))?;
        #[cfg(not(test))]
        let connection = {
            if let Some(shared_path) = &self.shared_path {
                let (_source_identity, spec) = migration::body_speed_namespace_spec(&self.path)
                    .map_err(|error| {
                        rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(
                            error,
                        )))
                    })?;
                let connection = Connection::open_scoped(
                    shared_path,
                    spec.id,
                    spec.prefix,
                    migration::body_speed_object_names(),
                )?;
                connection
            } else {
                let identity = self
                    .path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .ok_or_else(|| rusqlite::Error::InvalidPath(self.path.clone()))?;
                let logical = format!("body-speed/{identity}");
                crate::core::business_store_route::open_store(
                    "body-speed",
                    identity,
                    &logical,
                    &[self.path.clone()],
                )
                .map_err(|error| {
                    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error)))
                })?
            }
        };
        connection.busy_timeout(Duration::from_secs(3))?;
        Ok(connection)
    }

    fn create_schema(connection: &Connection) -> rusqlite::Result<()> {
        Self::create_schema_tables(connection)?;
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
        Ok(())
    }

    fn create_schema_tables(connection: &Connection) -> rusqlite::Result<()> {
        connection.execute(
            "CREATE TABLE IF NOT EXISTS speed_trend_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID",
            [],
        )?;
        Self::create_body_tables(connection)
    }

    fn create_body_tables(connection: &Connection) -> rusqlite::Result<()> {
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

fn ceil_bucket_start(timestamp: f64) -> Option<i64> {
    if !timestamp.is_finite() {
        return None;
    }
    let bucket = (timestamp / BUCKET_SECONDS as f64).ceil() * BUCKET_SECONDS as f64;
    (bucket.is_finite() && bucket >= i64::MIN as f64 && bucket < i64::MAX as f64)
        .then_some(bucket as i64)
}

fn type7_quantile(sorted_values: &[f64], probability: f64) -> Option<f64> {
    if sorted_values.is_empty() || !probability.is_finite() || !(0.0..=1.0).contains(&probability) {
        return None;
    }
    let index = (sorted_values.len() - 1) as f64 * probability;
    let lower_index = index.floor() as usize;
    let upper_index = index.ceil() as usize;
    let fraction = index - lower_index as f64;
    let lower = *sorted_values.get(lower_index)?;
    let upper = *sorted_values.get(upper_index)?;
    let value = lower + (upper - lower) * fraction;
    (value.is_finite() && value > 0.0).then_some(value)
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
        assert_eq!(initial[0].bucket_end, None);
        assert_eq!(initial[0].median, None);

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
    fn distribution_uses_type7_quartiles_of_five_minute_rates() {
        let (store, path) = store();
        let base = 1_728_000.0;
        let now = base + 86_400.0 - 60.0;
        let samples = [
            sample("q1a", Some("model-a"), base + 30.0, 10, 1.0, None),
            sample("q1b", Some("model-a"), base + 60.0, 10, 1.0, None),
            sample("q1c", Some("model-a"), base + 90.0, 10, 1.0, None),
            sample("q2", Some("model-a"), base + 330.0, 20, 1.0, None),
            sample("q3", Some("model-a"), base + 630.0, 40, 1.0, None),
            sample("q4", Some("model-a"), base + 930.0, 100, 1.0, None),
        ];
        store.ingest(&samples, now, 30).unwrap();

        let points = store.read_distribution(now, 1).unwrap();
        assert_eq!(points.len(), 1);
        let point = &points[0];
        assert_eq!(point.bucket_count, Some(4));
        assert_eq!(point.sample_count, 6);
        assert_eq!(point.lower_quartile, Some(17.5));
        assert_eq!(point.median, Some(30.0));
        assert_eq!(point.upper_quartile, Some(55.0));
        assert_ne!(point.tokens_per_second, point.median.unwrap());
        assert!((point.tokens_per_second - 190.0 / 6.0).abs() < 1e-12);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn distribution_keeps_models_separate_and_requires_three_buckets_and_six_samples() {
        let (store, path) = store();
        let base = 1_728_000.0;
        let now = base + 86_400.0 - 60.0;
        let mut samples = Vec::new();
        for model in ["model-a", "model-b"] {
            for bucket in [0.0, 300.0, 600.0] {
                for copy in 0..2 {
                    let id = format!("{model}-{bucket}-{copy}");
                    samples.push(sample(
                        &id,
                        Some(model),
                        base + bucket + 30.0 + f64::from(copy),
                        if model == "model-a" { 10 } else { 20 },
                        1.0,
                        None,
                    ));
                }
            }
        }
        for bucket in [900.0, 1_200.0] {
            for copy in 0..3 {
                let id = format!("two-buckets-{bucket}-{copy}");
                samples.push(sample(
                    &id,
                    Some("two-buckets"),
                    base + bucket + 30.0 + f64::from(copy),
                    10,
                    1.0,
                    None,
                ));
            }
        }
        for bucket in [0.0, 300.0, 600.0] {
            let id = format!("too-few-samples-{bucket}");
            samples.push(sample(
                &id,
                Some("too-few-samples"),
                base + bucket + 30.0,
                10,
                1.0,
                None,
            ));
        }
        store.ingest(&samples, now, 30).unwrap();

        let points = store.read_distribution(now, 1).unwrap();
        assert_eq!(points.len(), 2);
        assert_eq!(points[0].model, "model-a");
        assert_eq!(points[0].output_tokens, 60);
        assert_eq!(points[1].model, "model-b");
        assert_eq!(points[1].output_tokens, 120);
        assert!(points
            .iter()
            .all(|point| { point.bucket_count == Some(3) && point.sample_count == 6 }));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn distribution_excludes_current_incomplete_five_minute_bucket() {
        let (store, path) = store();
        let base = 1_728_000.0;
        let now = base + 910.0;
        let mut samples = Vec::new();
        for bucket in [0.0, 300.0, 600.0, 900.0] {
            for copy in 0..2 {
                let id = format!("current-boundary-{bucket}-{copy}");
                samples.push(sample(
                    &id,
                    Some("model-a"),
                    base + bucket + 30.0 + f64::from(copy),
                    10,
                    1.0,
                    None,
                ));
            }
        }
        store.ingest(&samples, now, 30).unwrap();

        let points = store.read_distribution(now, 1).unwrap();
        assert_eq!(points.len(), 1);
        assert_eq!(points[0].bucket_count, Some(3));
        assert_eq!(points[0].sample_count, 6);
        assert_eq!(points[0].bucket_end, Some(base as i64 + 900));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn distribution_uses_the_requested_fixed_utc_bucket_widths() {
        let base = 1_728_000.0;
        for (days, width) in [(1_u16, 1_800_i64), (7, 7_200), (30, 21_600)] {
            let (store, path) = store();
            let now = base + f64::from(days) * 86_400.0 - 60.0;
            let mut samples = Vec::new();
            for display_bucket in [0_i64, width] {
                for five_minute in [0_i64, 300, 600] {
                    for copy in 0..2 {
                        let id = format!("{days}-{display_bucket}-{five_minute}-{copy}");
                        let ended_at =
                            base + (display_bucket + five_minute) as f64 + 30.0 + f64::from(copy);
                        samples.push(sample(&id, Some("model-a"), ended_at, 10, 1.0, None));
                    }
                }
            }
            store.ingest(&samples, now, 30).unwrap();

            let points = store.read_distribution(now, days).unwrap();
            assert_eq!(points.len(), 2, "days={days}");
            assert_eq!(points[0].bucket_start, base as i64, "days={days}");
            assert_eq!(points[1].bucket_start - points[0].bucket_start, width);
            assert_eq!(points[0].is_partial, Some(false));
            let _ = fs::remove_file(path);
        }
    }

    #[test]
    fn distribution_marks_a_truncated_last_display_bucket_as_partial() {
        let (store, path) = store();
        let base = 1_728_000.0;
        let now = base + 2_710.0;
        let mut samples = Vec::new();
        for bucket in [1_800.0, 2_100.0, 2_400.0] {
            for copy in 0..2 {
                let id = format!("partial-{bucket}-{copy}");
                samples.push(sample(
                    &id,
                    Some("model-a"),
                    base + bucket + 30.0 + f64::from(copy),
                    10,
                    1.0,
                    None,
                ));
            }
        }
        store.ingest(&samples, now, 30).unwrap();

        let points = store.read_distribution(now, 1).unwrap();
        assert_eq!(points.len(), 1);
        assert_eq!(points[0].bucket_start, base as i64 + 1_800);
        assert_eq!(points[0].bucket_end, Some(base as i64 + 2_700));
        assert_eq!(points[0].is_partial, Some(true));
        assert_eq!(points[0].bucket_count, Some(3));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn distribution_reads_without_rewriting_legacy_rows_or_metadata() {
        let (store, path) = store();
        let base = 1_728_000.0;
        let now = base + 86_400.0 - 60.0;
        let mut samples = Vec::new();
        for bucket in [0.0, 300.0, 600.0] {
            for copy in 0..2 {
                let id = format!("preserved-{bucket}-{copy}");
                samples.push(sample(
                    &id,
                    Some("model-a"),
                    base + bucket + 30.0 + f64::from(copy),
                    10,
                    1.0,
                    None,
                ));
            }
        }
        store.ingest(&samples, now, 15).unwrap();

        let read_rows = || {
            let connection = store.connect().unwrap();
            let mut statement = connection
                .prepare(
                    "SELECT bucket_start, model, output_tokens, duration_seconds, sample_count \
                     FROM speed_5m ORDER BY bucket_start, model",
                )
                .unwrap();
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, f64>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                })
                .unwrap()
                .collect::<rusqlite::Result<Vec<_>>>()
                .unwrap()
        };
        let before_rows = read_rows();
        let before_retention = store.retention_days().unwrap();
        let before_schema: String = store
            .connect()
            .unwrap()
            .query_row(
                "SELECT value FROM speed_trend_meta WHERE key = 'schema_version'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(before_schema, "1");

        assert_eq!(store.read_distribution(now, 1).unwrap().len(), 1);
        assert_eq!(store.read(now, 1).unwrap().len(), 3);
        assert_eq!(read_rows(), before_rows);
        assert_eq!(store.retention_days().unwrap(), before_retention);
        let after_schema: String = store
            .connect()
            .unwrap()
            .query_row(
                "SELECT value FROM speed_trend_meta WHERE key = 'schema_version'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(after_schema, "1");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn distribution_returns_an_error_for_invalid_persisted_rates() {
        let (store, path) = store();
        let base = 1_728_000.0;
        let now = base + 86_400.0 - 60.0;
        let samples = [
            sample("invalid-a", Some("model-a"), base + 30.0, 10, 1.0, None),
            sample("invalid-b", Some("model-a"), base + 330.0, 10, 1.0, None),
            sample("invalid-c", Some("model-a"), base + 630.0, 10, 1.0, None),
        ];
        store.ingest(&samples, now, 30).unwrap();
        store
            .connect()
            .unwrap()
            .execute(
                "UPDATE speed_5m SET duration_seconds = 0 WHERE bucket_start = ?1",
                [base as i64],
            )
            .unwrap();

        assert!(store.read_distribution(now, 1).is_err());
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
