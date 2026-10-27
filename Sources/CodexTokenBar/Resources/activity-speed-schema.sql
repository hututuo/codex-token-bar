CREATE TABLE IF NOT EXISTS activity_speed_meta (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;
INSERT OR IGNORE INTO activity_speed_meta(key, value) VALUES ('schema_version', '2');

CREATE TABLE IF NOT EXISTS activity_speed_samples (
    source_identity TEXT NOT NULL,
    id TEXT NOT NULL,
    display_mode TEXT NOT NULL,
    estimator_id TEXT NOT NULL,
    estimator_version TEXT NOT NULL,
    metric_kind TEXT NOT NULL,
    client TEXT NOT NULL,
    model TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL NOT NULL,
    output_rate REAL NOT NULL CHECK (output_rate >= 0),
    covered_seconds REAL NOT NULL CHECK (covered_seconds > 0),
    weighted_output REAL NOT NULL CHECK (weighted_output >= 0),
    CHECK (ended_at > started_at),
    PRIMARY KEY (source_identity, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS activity_speed_samples_v2_time
    ON activity_speed_samples(ended_at, started_at, source_identity);
CREATE INDEX IF NOT EXISTS activity_speed_samples_v2_scope_time
    ON activity_speed_samples(source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, ended_at);

-- Retains only the stable source-scoped ID and end time after raw detail expires.
CREATE TABLE IF NOT EXISTS activity_speed_sample_ids (
    source_identity TEXT NOT NULL,
    id TEXT NOT NULL,
    ended_at REAL NOT NULL,
    PRIMARY KEY (source_identity, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS activity_speed_sample_ids_v2_time
    ON activity_speed_sample_ids(ended_at, source_identity);

CREATE TABLE IF NOT EXISTS activity_speed_buckets_5m (
    source_identity TEXT NOT NULL,
    display_mode TEXT NOT NULL,
    estimator_id TEXT NOT NULL,
    estimator_version TEXT NOT NULL,
    metric_kind TEXT NOT NULL,
    client TEXT NOT NULL,
    model TEXT NOT NULL,
    bucket_start INTEGER NOT NULL,
    weighted_output REAL NOT NULL CHECK (weighted_output >= 0),
    covered_seconds REAL NOT NULL CHECK (covered_seconds > 0),
    sample_count INTEGER NOT NULL CHECK (sample_count > 0),
    PRIMARY KEY (
        source_identity, display_mode, estimator_id, estimator_version,
        metric_kind, client, model, bucket_start
    )
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS activity_speed_buckets_v2_time
    ON activity_speed_buckets_5m(bucket_start, source_identity);
