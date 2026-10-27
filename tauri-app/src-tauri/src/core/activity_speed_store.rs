use rusqlite::{params_from_iter, types::Value, Connection, OptionalExtension, Row, Transaction};
use std::collections::BTreeMap;
use std::fmt;

const SCHEMA: &str =
    include_str!("../../../../Sources/CodexTokenBar/Resources/activity-speed-schema.sql");
const SCHEMA_VERSION: &str = "2";
const BUCKET_SECONDS: i64 = 300;
const RAW_RETENTION: f64 = 7.0 * 86_400.0;
const ROLLUP_RETENTION: f64 = 30.0 * 86_400.0;
const MAX_SAMPLE_SPAN: f64 = 3_600.0;
const MAX_TEXT_LENGTH: usize = 256;
const MAX_SERIES: usize = 64;
const MAX_TREND_POINTS: usize = 512;
const MAX_BATCH_SIZE: usize = 4_096;

pub(super) type ActivitySpeedResult<T> = Result<T, ActivitySpeedStoreError>;

#[derive(Debug)]
pub(super) enum ActivitySpeedStoreError {
    Sql(rusqlite::Error),
    InvalidNow,
    InvalidFilter,
    InvalidSample,
    UnsupportedSchema,
    TooManySeries,
    TooManySamples,
}

impl From<rusqlite::Error> for ActivitySpeedStoreError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}

impl fmt::Display for ActivitySpeedStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sql(error) => write!(f, "activity speed SQLite error: {error}"),
            Self::InvalidNow => f.write_str("activity speed time is invalid"),
            Self::InvalidFilter => f.write_str("activity speed trend start is invalid"),
            Self::InvalidSample => f.write_str("activity speed sample is invalid"),
            Self::UnsupportedSchema => f.write_str("activity speed schema is unsupported"),
            Self::TooManySeries => {
                f.write_str("activity speed query exceeds its bounded series limit")
            }
            Self::TooManySamples => {
                f.write_str("activity speed batch exceeds its bounded sample limit")
            }
        }
    }
}

impl std::error::Error for ActivitySpeedStoreError {}

#[path = "activity_speed_store_models.rs"]
mod models;
#[path = "activity_speed_store_write.rs"]
mod write;

pub(super) use models::{
    ActivitySpeedAggregate, ActivitySpeedDimensions, ActivitySpeedFilter, ActivitySpeedQueryResult,
    ActivitySpeedSample, ActivitySpeedSeries, ActivitySpeedTrendPoint, LEGACY_SOURCE_IDENTITY,
};

pub(super) fn create_schema(connection: &Connection) -> ActivitySpeedResult<()> {
    let transaction = connection.unchecked_transaction()?;
    let metadata_exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='activity_speed_meta')",
        [],
        |row| row.get(0),
    )?;
    if !metadata_exists {
        transaction.execute_batch(SCHEMA)?;
    } else {
        let version: Option<String> = transaction
            .query_row(
                "SELECT value FROM activity_speed_meta WHERE key='schema_version'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        match version.as_deref() {
            Some("1") => migrate_v1(&transaction)?,
            Some(SCHEMA_VERSION) => transaction.execute_batch(SCHEMA)?,
            _ => return Err(ActivitySpeedStoreError::UnsupportedSchema),
        }
    }
    let version: Option<String> = transaction
        .query_row(
            "SELECT value FROM activity_speed_meta WHERE key='schema_version'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if version.as_deref() != Some(SCHEMA_VERSION) {
        return Err(ActivitySpeedStoreError::UnsupportedSchema);
    }
    transaction.commit()?;
    Ok(())
}

fn migrate_v1(transaction: &Transaction<'_>) -> ActivitySpeedResult<()> {
    transaction.execute_batch(
        "ALTER TABLE activity_speed_samples RENAME TO activity_speed_samples_v1_legacy;
         ALTER TABLE activity_speed_sample_ids RENAME TO activity_speed_sample_ids_v1_legacy;
         ALTER TABLE activity_speed_buckets_5m RENAME TO activity_speed_buckets_5m_v1_legacy;",
    )?;
    transaction.execute_batch(SCHEMA)?;
    transaction.execute(
        "INSERT INTO activity_speed_sample_ids(source_identity, id, ended_at) SELECT ?1, id, ended_at FROM activity_speed_sample_ids_v1_legacy",
        [LEGACY_SOURCE_IDENTITY],
    )?;
    transaction.execute(
        "INSERT INTO activity_speed_samples(source_identity, id, display_mode, estimator_id, estimator_version, metric_kind, client, model, started_at, ended_at, output_rate, covered_seconds, weighted_output) SELECT ?1, id, display_mode, estimator_id, estimator_version, metric_kind, client, model, started_at, ended_at, output_rate, covered_seconds, weighted_output FROM activity_speed_samples_v1_legacy",
        [LEGACY_SOURCE_IDENTITY],
    )?;
    transaction.execute(
        "INSERT INTO activity_speed_buckets_5m(source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start, weighted_output, covered_seconds, sample_count) SELECT ?1, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start, weighted_output, covered_seconds, sample_count FROM activity_speed_buckets_5m_v1_legacy",
        [LEGACY_SOURCE_IDENTITY],
    )?;
    let updated = transaction.execute(
        "UPDATE activity_speed_meta SET value='2' WHERE key='schema_version' AND value='1'",
        [],
    )?;
    if updated != 1 {
        return Err(ActivitySpeedStoreError::UnsupportedSchema);
    }
    Ok(())
}

pub(super) use write::{add_sample, add_samples};

pub(super) fn query(
    connection: &Connection,
    now: f64,
    filter: &ActivitySpeedFilter,
    trend_point_limit: usize,
) -> ActivitySpeedResult<ActivitySpeedQueryResult> {
    validate_now(now)?;
    if filter
        .trend_since
        .is_some_and(|since| !since.is_finite() || since < 0.0 || since > now)
    {
        return Err(ActivitySpeedStoreError::InvalidFilter);
    }
    let transaction = connection.unchecked_transaction()?;
    prune(&transaction, now)?;
    transaction.commit()?;
    let limit = trend_point_limit.clamp(1, MAX_TREND_POINTS);
    let mut values = BTreeMap::<ActivitySpeedDimensions, ActivitySpeedSeries>::new();
    for (minutes, slot) in [(5, 0), (15, 1), (30, 2)] {
        for (dimensions, aggregate) in
            read_rolling(connection, now, f64::from(minutes * 60), filter)?
        {
            let series = values
                .entry(dimensions.clone())
                .or_insert_with(|| ActivitySpeedSeries::new(dimensions));
            match slot {
                0 => series.rolling_5m = Some(aggregate),
                1 => series.rolling_15m = Some(aggregate),
                _ => series.rolling_30m = Some(aggregate),
            }
        }
    }
    for (dimensions, points) in read_trend(connection, now, 5, filter, limit)? {
        values
            .entry(dimensions.clone())
            .or_insert_with(|| ActivitySpeedSeries::new(dimensions))
            .five_minute_trend = points;
    }
    for (dimensions, points) in read_trend(connection, now, 30, filter, limit)? {
        values
            .entry(dimensions.clone())
            .or_insert_with(|| ActivitySpeedSeries::new(dimensions))
            .thirty_minute_trend = points;
    }
    if values.len() > MAX_SERIES {
        return Err(ActivitySpeedStoreError::TooManySeries);
    }
    Ok(ActivitySpeedQueryResult {
        series: values.into_values().collect(),
    })
}

fn read_rolling(
    connection: &Connection,
    now: f64,
    window: f64,
    filter: &ActivitySpeedFilter,
) -> ActivitySpeedResult<BTreeMap<ActivitySpeedDimensions, ActivitySpeedAggregate>> {
    let from = now - window;
    let (predicate, mut values) = filter_sql(filter);
    let sql = format!(
        "SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, SUM(weighted_output * ((MIN(ended_at, ?) - MAX(started_at, ?)) / (ended_at - started_at))), SUM(covered_seconds * ((MIN(ended_at, ?) - MAX(started_at, ?)) / (ended_at - started_at))) FROM activity_speed_samples WHERE ended_at > ? AND started_at < ? {predicate} GROUP BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model HAVING SUM(covered_seconds * ((MIN(ended_at, ?) - MAX(started_at, ?)) / (ended_at - started_at))) > 0 ORDER BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model LIMIT ?"
    );
    let mut params = vec![
        Value::Real(now),
        Value::Real(from),
        Value::Real(now),
        Value::Real(from),
        Value::Real(from),
        Value::Real(now),
    ];
    params.append(&mut values);
    params.extend([
        Value::Real(now),
        Value::Real(from),
        Value::Integer((MAX_SERIES + 1) as i64),
    ]);
    let mut statement = connection.prepare(&sql)?;
    let rows = statement
        .query_map(params_from_iter(params.iter()), |row| {
            let dimensions = dimensions(row)?;
            let weighted: f64 = row.get(7)?;
            let covered: f64 = row.get(8)?;
            if !weighted.is_finite() || weighted < 0.0 || !covered.is_finite() || covered <= 0.0 {
                return Err(rusqlite::Error::InvalidQuery);
            }
            Ok((dimensions, ActivitySpeedAggregate::new(weighted, covered)))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if rows.len() > MAX_SERIES {
        return Err(ActivitySpeedStoreError::TooManySeries);
    }
    Ok(rows.into_iter().collect())
}

fn read_trend(
    connection: &Connection,
    now: f64,
    minutes: i64,
    filter: &ActivitySpeedFilter,
    point_limit: usize,
) -> ActivitySpeedResult<BTreeMap<ActivitySpeedDimensions, Vec<ActivitySpeedTrendPoint>>> {
    let retention_cutoff = bucket_start(now - ROLLUP_RETENTION);
    let cutoff = filter
        .trend_since
        .map(|since| bucket_start(since).max(retention_cutoff))
        .unwrap_or(retention_cutoff);
    let last_bucket = bucket_start(now);
    let grouped_bucket = if minutes == 5 {
        "bucket_start"
    } else {
        "(bucket_start / 1800) * 1800"
    };
    let (predicate, mut values) = filter_sql(filter);
    let sql = format!(
        "WITH grouped AS (SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, {grouped_bucket} AS bucket_start, SUM(weighted_output) AS weighted_output, SUM(covered_seconds) AS covered_seconds FROM activity_speed_buckets_5m WHERE bucket_start >= ? AND bucket_start <= ? {predicate} GROUP BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, {grouped_bucket}), ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model ORDER BY bucket_start DESC) AS point_rank FROM grouped) SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start, weighted_output, covered_seconds FROM ranked WHERE point_rank <= ? ORDER BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start LIMIT ?"
    );
    let mut params = vec![Value::Integer(cutoff), Value::Integer(last_bucket)];
    params.append(&mut values);
    params.extend([
        Value::Integer(point_limit as i64),
        Value::Integer((MAX_SERIES * point_limit + 1) as i64),
    ]);
    let mut statement = connection.prepare(&sql)?;
    let rows = statement
        .query_map(params_from_iter(params.iter()), |row| {
            let dimensions = dimensions(row)?;
            let bucket: i64 = row.get(7)?;
            let weighted: f64 = row.get(8)?;
            let covered: f64 = row.get(9)?;
            if !weighted.is_finite() || weighted < 0.0 || !covered.is_finite() || covered <= 0.0 {
                return Err(rusqlite::Error::InvalidQuery);
            }
            Ok((
                dimensions,
                ActivitySpeedTrendPoint {
                    bucket_start: bucket,
                    value: ActivitySpeedAggregate::new(weighted, covered),
                },
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if rows.len() > MAX_SERIES * point_limit {
        return Err(ActivitySpeedStoreError::TooManySeries);
    }
    let mut output = BTreeMap::<ActivitySpeedDimensions, Vec<ActivitySpeedTrendPoint>>::new();
    for (dimensions, point) in rows {
        output.entry(dimensions).or_default().push(point);
    }
    if output.len() > MAX_SERIES {
        return Err(ActivitySpeedStoreError::TooManySeries);
    }
    Ok(output)
}

fn dimensions(row: &Row<'_>) -> rusqlite::Result<ActivitySpeedDimensions> {
    Ok(ActivitySpeedDimensions {
        source_identity: row.get(0)?,
        display_mode: row.get(1)?,
        estimator_id: row.get(2)?,
        estimator_version: row.get(3)?,
        metric_kind: row.get(4)?,
        client: row.get(5)?,
        model: row.get(6)?,
    })
}

fn filter_sql(filter: &ActivitySpeedFilter) -> (String, Vec<Value>) {
    let pairs = [
        ("source_identity", filter.source_identity.as_ref()),
        ("display_mode", filter.display_mode.as_ref()),
        ("estimator_id", filter.estimator_id.as_ref()),
        ("estimator_version", filter.estimator_version.as_ref()),
        ("metric_kind", filter.metric_kind.as_ref()),
        ("client", filter.client.as_ref()),
        ("model", filter.model.as_ref()),
    ];
    let selected = pairs
        .into_iter()
        .filter_map(|(column, value)| value.map(|value| (column, value)));
    let mut clauses = Vec::new();
    let mut values = Vec::new();
    for (column, value) in selected {
        clauses.push(format!("{column}=?"));
        values.push(Value::Text(value.clone()));
    }
    let predicate = if clauses.is_empty() {
        String::new()
    } else {
        format!(" AND {}", clauses.join(" AND "))
    };
    (predicate, values)
}

fn validate(sample: &ActivitySpeedSample, now: f64) -> ActivitySpeedResult<()> {
    validate_now(now)?;
    let labels = [
        &sample.source_identity,
        &sample.id,
        &sample.display_mode,
        &sample.estimator_id,
        &sample.estimator_version,
        &sample.metric_kind,
        &sample.client,
        &sample.model,
    ];
    let span = sample.ended_at - sample.started_at;
    let weighted = sample.output_rate * sample.covered_seconds;
    if labels
        .iter()
        .any(|value| value.is_empty() || value.len() > MAX_TEXT_LENGTH)
        || !sample.started_at.is_finite()
        || !sample.ended_at.is_finite()
        || sample.started_at < 0.0
        || sample.ended_at > now
        || sample.ended_at >= i64::MAX as f64
        || !span.is_finite()
        || span <= 0.0
        || span > MAX_SAMPLE_SPAN
        || !sample.output_rate.is_finite()
        || sample.output_rate < 0.0
        || !sample.covered_seconds.is_finite()
        || sample.covered_seconds <= 0.0
        || sample.covered_seconds > span
        || !weighted.is_finite()
        || weighted < 0.0
    {
        return Err(ActivitySpeedStoreError::InvalidSample);
    }
    Ok(())
}

fn validate_now(now: f64) -> ActivitySpeedResult<()> {
    if !now.is_finite() || now < 0.0 || now >= i64::MAX as f64 - ROLLUP_RETENTION {
        return Err(ActivitySpeedStoreError::InvalidNow);
    }
    Ok(())
}

fn prune(transaction: &Transaction<'_>, now: f64) -> ActivitySpeedResult<()> {
    transaction.execute(
        "DELETE FROM activity_speed_samples WHERE ended_at < ?",
        [now - RAW_RETENTION],
    )?;
    transaction.execute(
        "DELETE FROM activity_speed_sample_ids WHERE ended_at < ?",
        [now - ROLLUP_RETENTION],
    )?;
    transaction.execute(
        "DELETE FROM activity_speed_buckets_5m WHERE bucket_start < ?",
        [bucket_start(now - ROLLUP_RETENTION)],
    )?;
    Ok(())
}

fn bucket_start(timestamp: f64) -> i64 {
    (timestamp / BUCKET_SECONDS as f64).floor() as i64 * BUCKET_SECONDS
}

#[cfg(test)]
#[path = "activity_speed_store_tests.rs"]
mod tests;
