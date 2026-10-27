use super::*;

pub(in crate::core) fn add_sample(
    connection: &Connection,
    sample: &ActivitySpeedSample,
    now: f64,
) -> ActivitySpeedResult<bool> {
    Ok(add_samples(connection, std::slice::from_ref(sample), now)? == 1)
}

pub(in crate::core) fn add_samples(
    connection: &Connection,
    samples: &[ActivitySpeedSample],
    now: f64,
) -> ActivitySpeedResult<usize> {
    validate_now(now)?;
    if samples.len() > MAX_BATCH_SIZE {
        return Err(ActivitySpeedStoreError::TooManySamples);
    }
    for sample in samples {
        validate(sample, now)?;
    }
    if samples.is_empty() {
        return Ok(0);
    }
    let raw_cutoff = now - RAW_RETENTION;
    let rollup_cutoff = now - ROLLUP_RETENTION;
    let transaction = connection.unchecked_transaction()?;
    prune(&transaction, now)?;
    let mut inserted = 0;
    for sample in samples {
        if sample.ended_at < rollup_cutoff {
            continue;
        }
        if insert_sample(&transaction, sample, raw_cutoff, rollup_cutoff)? {
            inserted += 1;
        }
    }
    transaction.commit()?;
    Ok(inserted)
}

fn insert_sample(
    transaction: &Transaction<'_>,
    sample: &ActivitySpeedSample,
    raw_cutoff: f64,
    rollup_cutoff: f64,
) -> ActivitySpeedResult<bool> {
    let inserted = transaction.execute(
        "INSERT OR IGNORE INTO activity_speed_sample_ids(source_identity, id, ended_at) VALUES(?1, ?2, ?3)",
        (&sample.source_identity, &sample.id, sample.ended_at),
    )?;
    if inserted == 0 {
        return Ok(false);
    }

    if sample.ended_at >= raw_cutoff {
        transaction.execute(
            "INSERT INTO activity_speed_samples(source_identity, id, display_mode, estimator_id, estimator_version, metric_kind, client, model, started_at, ended_at, output_rate, covered_seconds, weighted_output) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            (
                &sample.source_identity,
                &sample.id,
                &sample.display_mode,
                &sample.estimator_id,
                &sample.estimator_version,
                &sample.metric_kind,
                &sample.client,
                &sample.model,
                sample.started_at,
                sample.ended_at,
                sample.output_rate,
                sample.covered_seconds,
                sample.output_rate * sample.covered_seconds,
            ),
        )?;
    }

    let mut cursor = sample.started_at.max(rollup_cutoff);
    while cursor < sample.ended_at {
        let bucket = bucket_start(cursor);
        let stop = sample.ended_at.min((bucket + BUCKET_SECONDS) as f64);
        let fraction = (stop - cursor) / (sample.ended_at - sample.started_at);
        let weighted = sample.output_rate * sample.covered_seconds * fraction;
        let covered = sample.covered_seconds * fraction;
        if !weighted.is_finite() || weighted < 0.0 || !covered.is_finite() || covered <= 0.0 {
            return Err(ActivitySpeedStoreError::InvalidSample);
        }
        let previous: (f64, f64) = transaction
            .query_row(
                "SELECT weighted_output, covered_seconds FROM activity_speed_buckets_5m WHERE source_identity=?1 AND display_mode=?2 AND estimator_id=?3 AND estimator_version=?4 AND metric_kind=?5 AND client=?6 AND model=?7 AND bucket_start=?8",
                (
                    &sample.source_identity,
                    &sample.display_mode,
                    &sample.estimator_id,
                    &sample.estimator_version,
                    &sample.metric_kind,
                    &sample.client,
                    &sample.model,
                    bucket,
                ),
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .unwrap_or((0.0, 0.0));
        if !(previous.0 + weighted).is_finite() || !(previous.1 + covered).is_finite() {
            return Err(ActivitySpeedStoreError::InvalidSample);
        }
        transaction.execute(
            "INSERT INTO activity_speed_buckets_5m(source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start, weighted_output, covered_seconds, sample_count) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1) ON CONFLICT(source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start) DO UPDATE SET weighted_output=weighted_output+excluded.weighted_output, covered_seconds=covered_seconds+excluded.covered_seconds, sample_count=sample_count+1",
            (
                &sample.source_identity, &sample.display_mode, &sample.estimator_id, &sample.estimator_version,
                &sample.metric_kind, &sample.client, &sample.model, bucket, weighted, covered,
            ),
        )?;
        cursor = stop;
    }
    Ok(true)
}
