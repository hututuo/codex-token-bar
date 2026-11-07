//! Derived dashboard projections, display watermarks and attribution state.
//!
//! ensure_dashboard_aggregates owns its existing IMMEDIATE repair transaction;
//! mark_dashboard_aggregate_published owns a separate display-marker transaction.
//! Neither is part of dashboard_data_at's deferred read snapshot. Checks/identity
//! getters only read the supplied owner; the write-capable APIs are distinct.
//!
//! Per-file aggregate helpers and synchronize_attribution_ledger borrow the
//! caller's transaction. finalize_generation still owns publication, its order
//! and its sole commit. Attribution epochs/floors preserve historical evidence
//! and must not be treated as freely disposable dashboard buckets.

use super::ExactUsageIndex;
use super::connection::{Connection, Transaction};
use super::contracts::{AttributionSafetyState, DashboardAggregateIdentity,
    checked_i64, nonnegative_u64, FIVE_MINUTE_INTERVAL_SECONDS, AGGREGATE_BOUNDARY_GRACE_SECONDS,
    ATTRIBUTION_PROVENANCE_EPOCH_KEY, ATTRIBUTION_LEDGER_EPOCH_KEY,
    ATTRIBUTION_LEDGER_INTEGRITY_KEY, ATTRIBUTION_UNSAFE_EPOCH_KEY,
    ATTRIBUTION_UNSAFE_GENERATION_KEY, ATTRIBUTION_UNSAFE_ID_KEY,
    ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY, ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY,
    BUILDING_DASHBOARD_CHANGED_KEY, DASHBOARD_REVISION_KEY,
    DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY, DASHBOARD_AGGREGATE_SCHEMA_VERSION,
    DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY, DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
    DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY,
    DASHBOARD_AGGREGATE_PRICING_REVISION};
use super::store_metadata::{metadata_i64, metadata_text, set_metadata,
    optional_startup_metadata_u64, required_startup_metadata_text, startup_metadata_bool};
use super::canonical;
use super::dashboard_buckets::refresh_range as refresh_dashboard_5m_range;
use crate::core::{startup_trace, time_series_timeline::LONG_RECENT_INTERVAL_SECONDS};
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Instant;
use time::OffsetDateTime;
use uuid::Uuid;
#[cfg(test)]
use super::AGGREGATE_REBUILD_COUNT;


pub(super) fn is_known_dashboard_pricing_revision(value: &str) -> bool {
    matches!(value, "raw-token-v0" | DASHBOARD_AGGREGATE_PRICING_REVISION)
}
impl ExactUsageIndex {
    pub(in super::super) fn dashboard_revision(&self) -> Result<u64, String> {
        let revision = self.revision()?;
        Ok(
            optional_startup_metadata_u64(&self.connection, DASHBOARD_REVISION_KEY)?
                .unwrap_or(revision),
        )
    }

    pub(in super::super) fn dashboard_aggregate_identity(
        &self,
    ) -> Result<DashboardAggregateIdentity, String> {
        Ok(DashboardAggregateIdentity {
            schema_version: metadata_text(
                &self.connection,
                DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY,
            )?,
            pricing_revision: metadata_text(
                &self.connection,
                DASHBOARD_AGGREGATE_PRICING_REVISION_KEY,
            )?,
            exact_generation: optional_startup_metadata_u64(
                &self.connection,
                DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY,
            )?,
            published_generation: optional_startup_metadata_u64(
                &self.connection,
                DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
            )?,
            settled_through: metadata_i64(
                &self.connection,
                DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY,
            )?,
        })
    }

    /// Computes aggregate lag from the existing durable metadata for one Full
    /// request. This is intentionally transient; no pending flag is persisted
    /// or kept in the coordinator.
    pub(in super::super) fn dashboard_aggregate_is_lagging(&self) -> Result<bool, String> {
        let identity = self.dashboard_aggregate_identity()?;
        let published_generation = self.published_generation()?;
        let schema_matches = identity
            .schema_version
            .as_deref()
            .and_then(|value| value.parse::<i64>().ok())
            == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION);
        Ok(!schema_matches
            || identity.pricing_revision.as_deref() != Some(DASHBOARD_AGGREGATE_PRICING_REVISION)
            || identity.exact_generation != Some(published_generation)
            || identity.published_generation != Some(published_generation)
            || identity.settled_through.is_none())
    }

    pub(in super::super) fn attribution_safety_state(&self) -> Result<AttributionSafetyState, String> {
        attribution_safety_state(&self.connection)
    }

    /// Clears only the exact clean generation represented by a durable
    /// synthetic cutover. A stale acknowledgement, or any scan that still sees
    /// the unsafe cause, is rejected without changing provenance state.
    pub(in super::super) fn acknowledge_attribution_safety(
        &mut self,
        provenance_epoch: &str,
        unsafe_id: &str,
        through_generation: u64,
    ) -> Result<bool, String> {
        self.connection.mark_receipt_dirty();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始精确 token 归因安全确认事务：{error}"))?;
        let state = attribution_safety_state(&transaction)?;
        if state.provenance_epoch != provenance_epoch
            || state.unsafe_since_generation.is_none()
            || state.unsafe_id.as_deref() != Some(unsafe_id)
            || state.current_scan_unsafe_cause_detected
            || state.current_scan_incomplete
            || through_generation != state.generation
            || through_generation < state.unsafe_since_generation.unwrap_or(u64::MAX)
        {
            transaction
                .commit()
                .map_err(|error| format!("无法结束未生效的精确 token 归因安全确认：{error}"))?;
            self.connection.mark_receipt_eligible();
            return Ok(false);
        }
        transaction
            .execute(
                "DELETE FROM metadata WHERE key IN (?1, ?2, ?3)",
                params![
                    ATTRIBUTION_UNSAFE_EPOCH_KEY,
                    ATTRIBUTION_UNSAFE_GENERATION_KEY,
                    ATTRIBUTION_UNSAFE_ID_KEY,
                ],
            )
            .map_err(|error| format!("无法清除精确 token 归因安全断点：{error}"))?;
        let revision = metadata_i64(&transaction, "revision")?
            .unwrap_or(0)
            .saturating_add(1);
        set_metadata(&transaction, "revision", &revision.to_string())?;
        set_metadata(&transaction, DASHBOARD_REVISION_KEY, &revision.to_string())?;
        transaction
            .commit()
            .map_err(|error| format!("无法提交精确 token 归因安全确认：{error}"))?;
        self.connection.mark_receipt_eligible();
        Ok(true)
    }

    /// Ensures the disposable numeric aggregate layer is complete for the
    /// currently published exact generation. The first upgrade groups the
    /// existing SQLite events once in one transaction; it never opens JSONL.
    /// Normal append/rewrite transactions maintain the same tables per file.
    /// Write-capable repair entrypoint: it may count events, notify progress,
    /// rebuild projections and commit its own IMMEDIATE transaction. Call before
    /// entering the dashboard read snapshot; an identity match remains a no-op.
    pub(in super::super) fn ensure_dashboard_aggregates(&mut self, codex_home: &Path) -> Result<(), String> {
        let aggregate_started = Instant::now();
        self.validate_dashboard_aggregate_compatibility()?;
        let stored_version =
            metadata_i64(&self.connection, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)?;
        let published_generation =
            metadata_i64(&self.connection, "published_generation")?.unwrap_or(0);
        let aggregate_generation =
            metadata_i64(&self.connection, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?;
        let pricing_revision =
            metadata_text(&self.connection, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY)?;
        let projection_matches = stored_version == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
            && aggregate_generation == Some(published_generation)
            && pricing_revision.as_deref() == Some(DASHBOARD_AGGREGATE_PRICING_REVISION)
            && dashboard_5m_projection_matches_published_files(
                &self.connection,
                published_generation,
            )?;
        // Display publication owns its separate generation/settled watermark.
        // A correct numeric projection needs no migration count or writer just
        // because the dashboard has not published those markers yet.
        if projection_matches {
            return Ok(());
        }

        let count_started = Instant::now();
        let event_count = self.published_event_count()?;
        let count_ms = count_started.elapsed().as_millis();
        let rebuild_started = Instant::now();
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在升级统计聚合；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失",
            0,
            Some(event_count.max(1)),
        );
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始仪表盘聚合升级事务：{error}"))?;
        let can_repair_incrementally = stored_version == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
            && pricing_revision.as_deref() == Some(DASHBOARD_AGGREGATE_PRICING_REVISION)
            && aggregate_generation
                .is_some_and(|generation| generation >= 0 && generation < published_generation);
        if can_repair_incrementally {
            incremental_rebuild_published_dashboard_aggregates(
                &transaction,
                aggregate_generation.unwrap_or(published_generation),
                published_generation,
            )?;
            if !dashboard_5m_projection_matches_published_files(&transaction, published_generation)?
            {
                rebuild_published_dashboard_aggregates(&transaction)?;
            }
        } else if !projection_matches {
            rebuild_published_dashboard_aggregates(&transaction)?;
        }
        if !dashboard_5m_projection_matches_published_files(&transaction, published_generation)? {
            return Err("仪表盘五分钟聚合自检失败，已拒绝发布不完整历史".to_string());
        }
        set_metadata(
            &transaction,
            DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY,
            &DASHBOARD_AGGREGATE_SCHEMA_VERSION.to_string(),
        )?;
        set_metadata(
            &transaction,
            DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY,
            &published_generation.to_string(),
        )?;
        set_metadata(
            &transaction,
            DASHBOARD_AGGREGATE_PRICING_REVISION_KEY,
            DASHBOARD_AGGREGATE_PRICING_REVISION,
        )?;
        transaction
            .commit()
            .map_err(|error| format!("无法提交仪表盘聚合升级：{error}"))?;
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "统计聚合升级完成，准备发布最新摘要",
            event_count.max(1),
            Some(event_count.max(1)),
        );
        startup_trace::mark_performance(format!(
            "precise_aggregate_repair count_ms={count_ms} rebuild_ms={} total_ms={} events={event_count} incremental={}",
            rebuild_started.elapsed().as_millis(), aggregate_started.elapsed().as_millis(),
            u8::from(can_repair_incrementally),
        ));
        Ok(())
    }

    pub(super) fn validate_dashboard_aggregate_compatibility(&self) -> Result<(), String> {
        let stored_version =
            metadata_i64(&self.connection, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)?;
        if stored_version.is_some_and(|version| version > DASHBOARD_AGGREGATE_SCHEMA_VERSION) {
            return Err(format!(
                "仪表盘聚合索引版本 {:?} 高于当前支持版本 {}，已拒绝覆盖",
                stored_version, DASHBOARD_AGGREGATE_SCHEMA_VERSION
            ));
        }
        if let Some(pricing_revision) =
            metadata_text(&self.connection, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY)?
        {
            if !is_known_dashboard_pricing_revision(&pricing_revision) {
                return Err(format!(
                    "仪表盘聚合计价契约 {pricing_revision} 未被当前版本识别，已拒绝覆盖"
                ));
            }
        }
        Ok(())
    }

    pub(in super::super) fn dashboard_5m_projection_is_complete(&self) -> Result<bool, String> {
        let published_generation =
            metadata_i64(&self.connection, "published_generation")?.unwrap_or(0);
        dashboard_5m_projection_matches_published_files(&self.connection, published_generation)
    }

    pub(in super::super) fn latest_eligible_aggregate_boundary(now_utc: OffsetDateTime) -> i64 {
        let delayed = now_utc
            .unix_timestamp()
            .saturating_sub(AGGREGATE_BOUNDARY_GRACE_SECONDS);
        delayed - delayed.rem_euclid(FIVE_MINUTE_INTERVAL_SECONDS)
    }

    /// Writes display lineage in its original independent transaction. This
    /// marker is distinct from numeric repair and exact-generation publication.
    pub(in super::super) fn mark_dashboard_aggregate_published(
        &mut self,
        exact_generation: u64,
        settled_through: i64,
    ) -> Result<(), String> {
        let exact_generation = i64::try_from(exact_generation)
            .map_err(|_| "精确索引代次超出 SQLite 支持范围".to_string())?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始发布仪表盘聚合水位：{error}"))?;
        set_metadata(
            &transaction,
            DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
            &exact_generation.to_string(),
        )?;
        set_metadata(
            &transaction,
            DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY,
            &settled_through.to_string(),
        )?;
        set_metadata(
            &transaction,
            DASHBOARD_AGGREGATE_PRICING_REVISION_KEY,
            DASHBOARD_AGGREGATE_PRICING_REVISION,
        )?;
        transaction
            .commit()
            .map_err(|error| format!("无法提交仪表盘聚合水位：{error}"))
    }

}

pub(super) fn startup_attribution_safety_state(
    connection: &Connection,
    published_generation: u64,
) -> Result<AttributionSafetyState, String> {
    let provenance_epoch =
        required_startup_metadata_text(connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?;
    if Uuid::parse_str(&provenance_epoch).is_err() {
        return Err("精确 token 启动缓存来源谱系标识无效".into());
    }
    let unsafe_epoch = metadata_text(connection, ATTRIBUTION_UNSAFE_EPOCH_KEY)?;
    if unsafe_epoch
        .as_deref()
        .is_some_and(|value| Uuid::parse_str(value).is_err())
    {
        return Err("精确 token 启动缓存 unsafe 谱系标识无效".into());
    }
    let unsafe_generation =
        optional_startup_metadata_u64(connection, ATTRIBUTION_UNSAFE_GENERATION_KEY)?;
    let unsafe_id = metadata_text(connection, ATTRIBUTION_UNSAFE_ID_KEY)?;
    if unsafe_id
        .as_deref()
        .is_some_and(|value| Uuid::parse_str(value).is_err())
    {
        return Err("精确 token 启动缓存 unsafe 事件标识无效".into());
    }
    let current_scan_unsafe_cause_detected =
        startup_metadata_bool(connection, ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY)?;
    let current_scan_incomplete =
        startup_metadata_bool(connection, ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY)?;
    let unresolved_matches_current = unsafe_epoch.as_deref() == Some(provenance_epoch.as_str())
        && unsafe_generation.is_some()
        && unsafe_id.is_some();
    if (unsafe_epoch.is_some() || unsafe_generation.is_some() || unsafe_id.is_some())
        && !unresolved_matches_current
    {
        return Err("精确 token 启动缓存 unsafe 谱系元数据不完整".into());
    }
    Ok(AttributionSafetyState {
        provenance_epoch,
        generation: published_generation,
        unsafe_since_generation: unresolved_matches_current
            .then_some(unsafe_generation)
            .flatten(),
        unsafe_id: unresolved_matches_current.then_some(unsafe_id).flatten(),
        current_scan_unsafe_cause_detected,
        current_scan_incomplete,
    })
}

type Dashboard5mProjectionSignature = (i64, Option<i64>, Option<i64>, i64, i64, i64, i64, i64);

pub(super) fn dashboard_5m_projection_matches_published_files(
    connection: &Connection,
    published_generation: i64,
) -> Result<bool, String> {
    let expected = connection
        .query_row(
            r#"
            WITH expected AS (
                SELECT
                    b.bucket_start,
                    b.model_key,
                    SUM(b.total_tokens) AS total_tokens,
                    SUM(b.calls) AS calls,
                    SUM(b.input_tokens) AS input_tokens,
                    SUM(b.cached_input_tokens) AS cached_input_tokens,
                    SUM(b.output_tokens) AS output_tokens
                FROM dashboard_file_5m b
                JOIN published_files f
                  ON f.generation = b.file_generation
                 AND f.path = b.file_path
                GROUP BY b.bucket_start, b.model_key
            )
            SELECT
                COUNT(*),
                MIN(bucket_start),
                MAX(bucket_start),
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(calls), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(output_tokens), 0)
            FROM expected
            "#,
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                ))
            },
        )
        .map_err(|error| format!("无法计算已发布单文件五分钟聚合签名：{error}"))?;
    let actual: Dashboard5mProjectionSignature = connection
        .query_row(
            r#"
            SELECT
                COUNT(*),
                MIN(bucket_start),
                MAX(bucket_start),
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(calls), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(output_tokens), 0)
            FROM dashboard_5m
            WHERE file_generation = ?1
            "#,
            params![published_generation],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                ))
            },
        )
        .map_err(|error| format!("无法计算全局五分钟聚合签名：{error}"))?;
    Ok(expected == actual)
}

/// Carries the already-published dashboard layer across an exact generation
/// that was advanced by a Summary owner, then repairs only files and sessions
/// touched by that generation. The expensive event-wide rebuild remains
/// reserved for the first aggregate migration, an unknown aggregate lineage,
/// or a pricing/schema change.
fn incremental_rebuild_published_dashboard_aggregates(
    transaction: &Transaction<'_>,
    previous_generation: i64,
    generation: i64,
) -> Result<(), String> {
    if previous_generation == generation {
        return Ok(());
    }

    let affected_bounds = transaction
        .query_row(
            r#"
            WITH touched AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation > ?2 AND generation <= ?1
                GROUP BY path
            )
            SELECT MIN(bucket_start), MAX(bucket_start)
            FROM (
                SELECT b.bucket_start
                FROM dashboard_file_5m b
                JOIN touched t
                  ON t.path = b.file_path
                 AND t.generation = b.file_generation
                UNION ALL
                SELECT e.timestamp - (e.timestamp % 300)
                FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
                JOIN files current
                  ON current.generation = e.file_generation
                 AND current.path = e.file_path
                 AND current.deleted = 0
                JOIN touched t
                  ON t.path = e.file_path
                 AND t.generation = e.file_generation
            )
            "#,
            params![generation, previous_generation],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .map(|(start, end)| start.zip(end))
        .map_err(|error| format!("无法读取增量聚合受影响桶范围：{error}"))?;

    transaction
        .execute(
            r#"
            WITH touched AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation > ?2 AND generation <= ?1
                GROUP BY path
            )
            DELETE FROM dashboard_file_totals
            WHERE file_generation IN (SELECT generation FROM touched)
            "#,
            params![generation, previous_generation],
        )
        .map_err(|error| format!("无法清理增量单文件总量聚合：{error}"))?;
    transaction
        .execute(
            r#"
            WITH touched AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation > ?2 AND generation <= ?1
                GROUP BY path
            )
            DELETE FROM dashboard_file_5m
            WHERE file_generation IN (SELECT generation FROM touched)
            "#,
            params![generation, previous_generation],
        )
        .map_err(|error| format!("无法清理增量单文件五分钟聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_file_totals(
                file_generation, file_path, session_id, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens,
                first_timestamp, last_timestamp
            )
            SELECT
                e.file_generation,
                e.file_path,
                MAX(e.session_id),
                SUM(e.tokens),
                COUNT(*),
                SUM(e.input_tokens),
                SUM(MIN(e.cached_input_tokens, e.input_tokens)),
                SUM(e.output_tokens),
                MIN(e.timestamp),
                MAX(e.timestamp)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
            JOIN (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation > ?2 AND generation <= ?1 AND deleted = 0
                GROUP BY path
            ) touched
              ON touched.generation = e.file_generation
             AND touched.path = e.file_path
            GROUP BY e.file_generation, e.file_path
            "#,
            params![generation, previous_generation],
        )
        .map_err(|error| format!("无法写入增量单文件总量聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT OR IGNORE INTO dashboard_file_5m(
                file_generation, file_path, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT
                e.file_generation,
                e.file_path,
                e.timestamp - (e.timestamp % 300),
                COALESCE(e.model, ''),
                e.model,
                SUM(e.tokens),
                COUNT(*),
                SUM(e.input_tokens),
                SUM(MIN(e.cached_input_tokens, e.input_tokens)),
                SUM(e.output_tokens)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
            JOIN (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation > ?2 AND generation <= ?1 AND deleted = 0
                GROUP BY path
            ) touched
              ON touched.generation = e.file_generation
             AND touched.path = e.file_path
            GROUP BY e.file_generation, e.file_path,
                e.timestamp - (e.timestamp % 300), COALESCE(e.model, '')
            "#,
            params![generation, previous_generation],
        )
        .map_err(|error| format!("无法写入增量单文件五分钟聚合：{error}"))?;

    if let Some((start, end)) = affected_bounds {
        refresh_dashboard_5m_range(transaction, generation, start, end)?;
    }
    refresh_dashboard_turn_candidates_for_changed_generations(
        transaction,
        generation,
        previous_generation,
    )?;

    Ok(())
}

/// Writes both build dirty flags in the caller's transaction. Title-only
/// updates use the existing generic revision path and must not call this.
pub(super) fn mark_dashboard_changed(transaction: &Transaction<'_>) -> Result<(), String> {
    set_metadata(transaction, "building_changed", "1")?;
    set_metadata(transaction, BUILDING_DASHBOARD_CHANGED_KEY, "1")
}

pub(super) fn rebuild_published_dashboard_aggregates(transaction: &Transaction<'_>) -> Result<(), String> {
    #[cfg(test)]
    AGGREGATE_REBUILD_COUNT.with(|value| value.set(value.get() + 1));
    transaction
        .execute_batch(
            r#"
            DELETE FROM dashboard_file_5m;
            DELETE FROM dashboard_file_totals;
            DELETE FROM dashboard_5m;
            DELETE FROM dashboard_turn_candidates;

            INSERT INTO dashboard_file_totals(
                file_generation,
                file_path,
                session_id,
                total_tokens,
                calls,
                input_tokens,
                cached_input_tokens,
                output_tokens,
                first_timestamp,
                last_timestamp
            )
            SELECT
                e.file_generation,
                e.file_path,
                MAX(e.session_id),
                COALESCE(SUM(e.tokens), 0),
                COUNT(*),
                COALESCE(SUM(e.input_tokens), 0),
                COALESCE(SUM(MIN(e.cached_input_tokens, e.input_tokens)), 0),
                COALESCE(SUM(e.output_tokens), 0),
                MIN(e.timestamp),
                MAX(e.timestamp)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
            JOIN published_files f
              ON f.generation = e.file_generation
             AND f.path = e.file_path
            GROUP BY e.file_generation, e.file_path;

            INSERT INTO dashboard_file_5m(
                file_generation,
                file_path,
                bucket_start,
                model_key,
                model,
                total_tokens,
                calls,
                input_tokens,
                cached_input_tokens,
                output_tokens
            )
            SELECT
                e.file_generation,
                e.file_path,
                e.timestamp - (e.timestamp % 300),
                COALESCE(e.model, ''),
                e.model,
                COALESCE(SUM(e.tokens), 0),
                COUNT(*),
                COALESCE(SUM(e.input_tokens), 0),
                COALESCE(SUM(MIN(e.cached_input_tokens, e.input_tokens)), 0),
                COALESCE(SUM(e.output_tokens), 0)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
            JOIN published_files f
              ON f.generation = e.file_generation
             AND f.path = e.file_path
            GROUP BY
                e.file_generation,
                e.file_path,
                e.timestamp - (e.timestamp % 300),
                COALESCE(e.model, '');

            INSERT INTO dashboard_5m(
                file_generation, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT
                COALESCE(
                    (
                        SELECT CAST(value AS INTEGER)
                        FROM metadata
                        WHERE key = 'published_generation'
                    ),
                    0
                ),
                b.bucket_start,
                b.model_key,
                MAX(b.model),
                SUM(b.total_tokens),
                SUM(b.calls),
                SUM(b.input_tokens),
                SUM(b.cached_input_tokens),
                SUM(b.output_tokens)
            FROM dashboard_file_5m b
            JOIN published_files f
              ON f.generation = b.file_generation
             AND f.path = b.file_path
            GROUP BY b.bucket_start, b.model_key;
            "#,
        )
        .map_err(|error| format!("无法从精确事件回填仪表盘聚合：{error}"))?;
    let published_generation = metadata_i64(transaction, "published_generation")?.unwrap_or(0);
    transaction
        .execute(
            r#"
            WITH grouped AS (
                SELECT
                    MIN(e.id) AS event_id,
                    e.file_generation AS source_file_generation,
                    e.file_path,
                    COALESCE(
                        MIN(CASE WHEN e.assistant_response_start IS NOT NULL
                            THEN e.ordinal END),
                        MIN(e.ordinal)
                    ) AS ordinal,
                    MAX(e.timestamp) AS timestamp,
                    e.session_id,
                    SUM(e.tokens) AS total_tokens,
                    SUM(e.input_tokens) AS input_tokens,
                    SUM(MIN(e.cached_input_tokens, e.input_tokens)) AS cached_input_tokens,
                    SUM(e.output_tokens) AS output_tokens,
                    COUNT(*) AS request_count,
                    SUM(CASE WHEN e.input_tokens >= 20000
                                  AND MIN(e.cached_input_tokens, e.input_tokens) * 1.0
                                      / e.input_tokens < 0.3
                             THEN 1 ELSE 0 END) AS low_hit_count,
                    SUM(CASE WHEN e.input_tokens > 0
                                  AND MIN(e.cached_input_tokens, e.input_tokens) = 0
                             THEN 1 ELSE 0 END) AS zero_hit_count,
                    MIN(e.user_prompt_start) AS user_prompt_start,
                    MAX(e.user_prompt_end) AS user_prompt_end,
                    MIN(e.assistant_response_start) AS assistant_response_start,
                    MAX(e.assistant_response_end) AS assistant_response_end
                FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
                JOIN published_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                WHERE e.user_prompt_start IS NOT NULL
                GROUP BY e.file_generation, e.file_path, e.session_id,
                    e.user_prompt_start, e.user_prompt_end
            ),
            ranked AS (
                SELECT
                    event_id,
                    source_file_generation,
                    file_path,
                    ordinal,
                    timestamp,
                    session_id,
                    total_tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    request_count,
                    low_hit_count,
                    zero_hit_count,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end,
                    ROW_NUMBER() OVER (
                        PARTITION BY session_id
                        ORDER BY timestamp, file_path, ordinal
                    ) AS turn_index,
                    COUNT(*) OVER (PARTITION BY session_id) AS session_calls
                FROM grouped
            )
            INSERT INTO dashboard_turn_candidates(
                aggregate_generation, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                request_count, low_hit_count, zero_hit_count,
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            )
            SELECT
                ?1, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                request_count, low_hit_count, zero_hit_count,
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            FROM ranked
            "#,
            params![published_generation],
        )
        .map_err(|error| format!("无法从精确事件回填轮次候选聚合：{error}"))?;
    Ok(())
}

pub(super) fn refresh_dashboard_file_aggregates(
    transaction: &Transaction<'_>,
    generation: i64,
    path: &str,
) -> Result<(), String> {
    let current_build_bounds = dashboard_file_bucket_bounds(transaction, generation, path)?;
    let previous_published_bounds = transaction
        .query_row(
            r#"
            SELECT MIN(bucket_start), MAX(bucket_start)
            FROM dashboard_file_5m
            WHERE file_path = ?1
              AND file_generation = (
                  SELECT MAX(generation)
                  FROM files
                  WHERE path = ?1
                    AND generation < ?2
                    AND deleted = 0
              )
            "#,
            params![path, generation],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .map(|(start, end)| start.zip(end))
        .map_err(|error| format!("无法读取单文件旧版五分钟聚合范围：{error}"))?;
    let previous_bounds =
        merge_dashboard_bucket_bounds(current_build_bounds, previous_published_bounds);
    transaction
        .execute(
            "DELETE FROM dashboard_file_5m WHERE file_generation = ?1 AND file_path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理单文件五分钟聚合：{error}"))?;
    transaction
        .execute(
            "DELETE FROM dashboard_file_totals WHERE file_generation = ?1 AND file_path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理单文件总量聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_file_totals(
                file_generation, file_path, session_id, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens,
                first_timestamp, last_timestamp
            )
            SELECT
                file_generation, file_path, MAX(session_id), SUM(tokens), COUNT(*),
                SUM(input_tokens), SUM(MIN(cached_input_tokens, input_tokens)),
                SUM(output_tokens), MIN(timestamp), MAX(timestamp)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0)
            WHERE file_generation = ?1 AND file_path = ?2
            GROUP BY file_generation, file_path
            "#,
            params![generation, path],
        )
        .map_err(|error| format!("无法重建单文件总量聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_file_5m(
                file_generation, file_path, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT
                file_generation,
                file_path,
                timestamp - (timestamp % 300),
                COALESCE(model, ''),
                model,
                SUM(tokens),
                COUNT(*),
                SUM(input_tokens),
                SUM(MIN(cached_input_tokens, input_tokens)),
                SUM(output_tokens)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0)
            WHERE file_generation = ?1 AND file_path = ?2
            GROUP BY file_generation, file_path, timestamp - (timestamp % 300), COALESCE(model, '')
            "#,
            params![generation, path],
        )
        .map_err(|error| format!("无法重建单文件五分钟聚合：{error}"))?;
    let current_bounds = dashboard_file_bucket_bounds(transaction, generation, path)?;
    if let Some((start, end)) = merge_dashboard_bucket_bounds(previous_bounds, current_bounds) {
        refresh_dashboard_5m_range(transaction, generation, start, end)?;
    }
    Ok(())
}

pub(super) fn refresh_dashboard_turn_candidates_for_changed_generations(
    transaction: &Transaction<'_>,
    generation: i64,
    previous_generation: i64,
) -> Result<(), String> {
    refresh_dashboard_turn_candidates_for_session(transaction, generation, previous_generation, None)
}

pub(super) fn refresh_dashboard_turn_candidates_for_session(
    transaction: &Transaction<'_>, generation: i64, previous_generation: i64, repaired_session: Option<&str>,
) -> Result<(), String> {
    transaction
        .execute(
            r#"
            WITH touched_paths AS (
                SELECT DISTINCT path
                FROM files
                WHERE generation > ?2 AND generation <= ?1
            ),
            dirty_sessions AS (
                SELECT ?3 AS session_id WHERE ?3 IS NOT NULL
                UNION
                SELECT DISTINCT session_id
                FROM files touched_files
                WHERE touched_files.session_id <> ''
                  AND touched_files.path IN (SELECT path FROM touched_paths)
                  AND touched_files.generation = (
                      SELECT MAX(latest.generation)
                      FROM files latest
                      WHERE latest.path = touched_files.path
                        AND latest.generation <= ?1
                  )
                UNION
                SELECT DISTINCT session_id
                FROM dashboard_turn_candidates
                WHERE aggregate_generation = ?1
                  AND file_path IN (SELECT path FROM touched_paths)
            )
            DELETE FROM dashboard_turn_candidates
            WHERE aggregate_generation = ?1
              AND session_id IN (SELECT session_id FROM dirty_sessions)
            "#,
            params![generation, previous_generation, repaired_session],
        )
        .map_err(|error| format!("无法清理受影响会话的轮次候选聚合：{error}"))?;
    transaction
        .execute(
            r#"
            WITH touched_paths AS (
                SELECT DISTINCT path
                FROM files
                WHERE generation > ?2 AND generation <= ?1
            ),
            dirty_sessions AS (
                SELECT ?3 AS session_id WHERE ?3 IS NOT NULL
                UNION
                SELECT DISTINCT session_id
                FROM files touched_files
                WHERE touched_files.session_id <> ''
                  AND touched_files.path IN (SELECT path FROM touched_paths)
                  AND touched_files.generation = (
                      SELECT MAX(latest.generation)
                      FROM files latest
                      WHERE latest.path = touched_files.path
                        AND latest.generation <= ?1
                  )
                UNION
                SELECT DISTINCT session_id
                FROM dashboard_turn_candidates
                WHERE aggregate_generation = ?1
                  AND file_path IN (SELECT path FROM touched_paths)
            ),
            latest_files AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation <= ?1
                GROUP BY path
            ),
            visible_files AS (
                SELECT latest_files.path, latest_files.generation
                FROM latest_files
                JOIN files f
                  ON f.path = latest_files.path
                 AND f.generation = latest_files.generation
                WHERE f.deleted = 0
            ),
            grouped AS (
                SELECT
                    MIN(e.id) AS event_id,
                    e.file_generation AS source_file_generation,
                    e.file_path,
                    COALESCE(
                        MIN(CASE WHEN e.assistant_response_start IS NOT NULL
                            THEN e.ordinal END),
                        MIN(e.ordinal)
                    ) AS ordinal,
                    MAX(e.timestamp) AS timestamp,
                    e.session_id,
                    SUM(e.tokens) AS total_tokens,
                    SUM(e.input_tokens) AS input_tokens,
                    SUM(MIN(e.cached_input_tokens, e.input_tokens)) AS cached_input_tokens,
                    SUM(e.output_tokens) AS output_tokens,
                    COUNT(*) AS request_count,
                    SUM(CASE WHEN e.input_tokens >= 20000
                                  AND MIN(e.cached_input_tokens, e.input_tokens) * 1.0
                                      / e.input_tokens < 0.3
                             THEN 1 ELSE 0 END) AS low_hit_count,
                    SUM(CASE WHEN e.input_tokens > 0
                                  AND MIN(e.cached_input_tokens, e.input_tokens) = 0
                             THEN 1 ELSE 0 END) AS zero_hit_count,
                    MIN(e.user_prompt_start) AS user_prompt_start,
                    MAX(e.user_prompt_end) AS user_prompt_end,
                    MIN(e.assistant_response_start) AS assistant_response_start,
                    MAX(e.assistant_response_end) AS assistant_response_end
                FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
                JOIN visible_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                WHERE e.user_prompt_start IS NOT NULL
                  AND e.session_id IN (SELECT session_id FROM dirty_sessions)
                GROUP BY e.file_generation, e.file_path, e.session_id,
                    e.user_prompt_start, e.user_prompt_end
            ),
            ranked AS (
                SELECT
                    event_id,
                    source_file_generation,
                    file_path,
                    ordinal,
                    timestamp,
                    session_id,
                    total_tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    request_count,
                    low_hit_count,
                    zero_hit_count,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end,
                    ROW_NUMBER() OVER (
                        PARTITION BY session_id
                        ORDER BY timestamp, file_path, ordinal
                    ) AS turn_index,
                    COUNT(*) OVER (PARTITION BY session_id) AS session_calls
                FROM grouped
            )
            INSERT INTO dashboard_turn_candidates(
                aggregate_generation, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                request_count, low_hit_count, zero_hit_count,
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            )
            SELECT
                ?1, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                request_count, low_hit_count, zero_hit_count,
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            FROM ranked
            "#,
            params![generation, previous_generation, repaired_session],
        )
        .map(|_| ())
        .map_err(|error| format!("无法更新受影响会话的轮次候选聚合：{error}"))
}

fn dashboard_file_bucket_bounds(
    connection: &Connection,
    generation: i64,
    path: &str,
) -> Result<Option<(i64, i64)>, String> {
    connection
        .query_row(
            r#"
            SELECT MIN(bucket_start), MAX(bucket_start)
            FROM dashboard_file_5m
            WHERE file_generation = ?1 AND file_path = ?2
            "#,
            params![generation, path],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .map(|(start, end)| start.zip(end))
        .map_err(|error| format!("无法读取单文件五分钟聚合范围：{error}"))
}

fn merge_dashboard_bucket_bounds(
    left: Option<(i64, i64)>,
    right: Option<(i64, i64)>,
) -> Option<(i64, i64)> {
    match (left, right) {
        (Some(left), Some(right)) => Some((left.0.min(right.0), left.1.max(right.1))),
        (Some(bounds), None) | (None, Some(bounds)) => Some(bounds),
        (None, None) => None,
    }
}


fn rebuild_dashboard_5m_generation(
    transaction: &Transaction<'_>,
    generation: i64,
) -> Result<(), String> {
    transaction
        .execute(
            "DELETE FROM dashboard_5m WHERE file_generation = ?1",
            params![generation],
        )
        .map_err(|error| format!("无法清理本轮全局五分钟聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_5m(
                file_generation, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT
                ?1,
                b.bucket_start,
                b.model_key,
                MAX(b.model),
                SUM(b.total_tokens),
                SUM(b.calls),
                SUM(b.input_tokens),
                SUM(b.cached_input_tokens),
                SUM(b.output_tokens)
            FROM dashboard_file_5m b
            JOIN (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation <= ?1
                GROUP BY path
            ) latest
              ON latest.generation = b.file_generation
             AND latest.path = b.file_path
            JOIN files f
              ON f.generation = latest.generation
             AND f.path = latest.path
             AND f.deleted = 0
            GROUP BY b.bucket_start, b.model_key
            "#,
            params![generation],
        )
        .map(|_| ())
        .map_err(|error| format!("无法重建本轮全局五分钟聚合：{error}"))
}

pub(super) fn update_dashboard_append_aggregates(
    transaction: &Transaction<'_>,
    generation: i64,
    path: &str,
    previous_ordinal: u64,
) -> Result<(), String> {
    let source_id = transaction
        .query_row(
            r#"
            SELECT p.source_id
            FROM pending_sources p JOIN sources s ON s.source_id = p.source_id
            WHERE p.target_generation = ?1 AND s.path = ?2 AND p.mode = 'delta'
            "#,
            params![generation, path],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|error| format!("无法读取单文件增量来源：{error}"))?;
    let Some(source_id) = source_id else {
        return refresh_dashboard_file_aggregates(transaction, generation, path);
    };
    let existing = transaction
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM dashboard_source_totals WHERE source_id = ?1)",
            params![source_id],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查单文件增量聚合水位：{error}"))?;
    if !existing {
        return refresh_dashboard_file_aggregates(transaction, generation, path);
    }
    let previous_ordinal = checked_i64(previous_ordinal, "单文件聚合事件序号")?;
    let affected_bounds = transaction
        .query_row(
            r#"
            SELECT
                MIN(timestamp - (timestamp % 300)),
                MAX(timestamp - (timestamp % 300))
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0)
            WHERE file_generation = ?1 AND file_path = ?2 AND ordinal > ?3
            "#,
            params![generation, path, previous_ordinal],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .map(|(start, end)| start.zip(end))
        .map_err(|error| format!("无法读取单文件追加聚合范围：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO pending_dashboard_source_totals(
                source_id, total_tokens, calls, input_tokens,
                cached_input_tokens, output_tokens, first_timestamp, last_timestamp
            )
            SELECT
                ?4, SUM(tokens), COUNT(*),
                SUM(input_tokens), SUM(MIN(cached_input_tokens, input_tokens)),
                SUM(output_tokens), MIN(timestamp), MAX(timestamp)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0)
            WHERE file_generation = ?1 AND file_path = ?2 AND ordinal > ?3
            HAVING COUNT(*) > 0
            ON CONFLICT(source_id) DO UPDATE SET
                total_tokens = pending_dashboard_source_totals.total_tokens + excluded.total_tokens,
                calls = pending_dashboard_source_totals.calls + excluded.calls,
                input_tokens = pending_dashboard_source_totals.input_tokens + excluded.input_tokens,
                cached_input_tokens = pending_dashboard_source_totals.cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = pending_dashboard_source_totals.output_tokens + excluded.output_tokens,
                first_timestamp = CASE
                    WHEN pending_dashboard_source_totals.first_timestamp IS NULL THEN excluded.first_timestamp
                    WHEN excluded.first_timestamp IS NULL THEN pending_dashboard_source_totals.first_timestamp
                    ELSE MIN(pending_dashboard_source_totals.first_timestamp, excluded.first_timestamp)
                END,
                last_timestamp = CASE
                    WHEN pending_dashboard_source_totals.last_timestamp IS NULL THEN excluded.last_timestamp
                    WHEN excluded.last_timestamp IS NULL THEN pending_dashboard_source_totals.last_timestamp
                    ELSE MAX(pending_dashboard_source_totals.last_timestamp, excluded.last_timestamp)
                END
            "#,
            params![generation, path, previous_ordinal, source_id],
        )
        .map_err(|error| format!("无法更新单文件增量总量聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO pending_dashboard_source_5m(
                source_id, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT
                ?4,
                timestamp - (timestamp % 300),
                COALESCE(model, ''),
                model,
                SUM(tokens),
                COUNT(*),
                SUM(input_tokens),
                SUM(MIN(cached_input_tokens, input_tokens)),
                SUM(output_tokens)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0)
            WHERE file_generation = ?1 AND file_path = ?2 AND ordinal > ?3
            GROUP BY timestamp - (timestamp % 300), COALESCE(model, '')
            ON CONFLICT(source_id, bucket_start, model_key) DO UPDATE SET
                total_tokens = pending_dashboard_source_5m.total_tokens + excluded.total_tokens,
                calls = pending_dashboard_source_5m.calls + excluded.calls,
                input_tokens = pending_dashboard_source_5m.input_tokens + excluded.input_tokens,
                cached_input_tokens = pending_dashboard_source_5m.cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = pending_dashboard_source_5m.output_tokens + excluded.output_tokens,
                model = excluded.model
            "#,
            params![generation, path, previous_ordinal, source_id],
        )
        .map_err(|error| format!("无法更新单文件增量五分钟聚合：{error}"))?;
    if let Some((start, end)) = affected_bounds {
        refresh_dashboard_5m_range(transaction, generation, start, end)?;
    }
    Ok(())
}

pub(super) fn backfill_missing_dashboard_aggregates_for_generation(
    transaction: &Transaction<'_>,
    generation: i64,
) -> Result<(), String> {
    // This is a bounded repair over files changed in the current building
    // generation only. It is not a historical fallback and never touches
    // unchanged generations or JSONL bodies.
    let inserted_totals = transaction
        .execute(
            r#"
            INSERT INTO dashboard_file_totals(
                file_generation, file_path, session_id, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens,
                first_timestamp, last_timestamp
            )
            SELECT
                e.file_generation, e.file_path, MAX(e.session_id), SUM(e.tokens), COUNT(*),
                SUM(e.input_tokens), SUM(MIN(e.cached_input_tokens, e.input_tokens)),
                SUM(e.output_tokens), MIN(e.timestamp), MAX(e.timestamp)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
            LEFT JOIN dashboard_file_totals t
              ON t.file_generation = e.file_generation
             AND t.file_path = e.file_path
            WHERE e.file_generation = ?1 AND t.file_path IS NULL
            GROUP BY e.file_generation, e.file_path
            "#,
            params![generation],
        )
        .map_err(|error| format!("无法补齐本轮单文件总量聚合：{error}"))?;
    let inserted_buckets = transaction
        .execute(
            r#"
            INSERT INTO dashboard_file_5m(
                file_generation, file_path, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT
                e.file_generation,
                e.file_path,
                e.timestamp - (e.timestamp % 300),
                COALESCE(e.model, ''),
                e.model,
                SUM(e.tokens),
                COUNT(*),
                SUM(e.input_tokens),
                SUM(MIN(e.cached_input_tokens, e.input_tokens)),
                SUM(e.output_tokens)
            FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
            WHERE e.file_generation = ?1
            GROUP BY e.file_generation, e.file_path,
                e.timestamp - (e.timestamp % 300), COALESCE(e.model, '')
            "#,
            params![generation],
        )
        .map_err(|error| format!("无法补齐本轮单文件五分钟聚合：{error}"))?;
    if inserted_totals > 0 || inserted_buckets > 0 {
        rebuild_dashboard_5m_generation(transaction, generation)?;
    }
    Ok(())
}

pub(super) fn visible_duplicate_session_lineage(
    connection: &Connection,
    generation: i64,
) -> Result<bool, String> {
    connection
        .query_row(
            r#"
            WITH latest AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation <= ?1
                GROUP BY path
            ), visible_files AS (
                SELECT f.path, f.session_id
                FROM latest
                JOIN files f
                  ON f.path = latest.path
                 AND f.generation = latest.generation
                WHERE f.deleted = 0
                  AND TRIM(f.session_id) <> ''
                  AND NOT EXISTS(SELECT 1 FROM usage_ledger_sources l WHERE l.source_id=f.source_id AND l.missing=1)
            )
            SELECT EXISTS(
                SELECT 1
                FROM visible_files
                GROUP BY session_id
                HAVING COUNT(*) > 1
                LIMIT 1
            )
            "#,
            params![generation],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查精确 token 重复会话来源：{error}"))
}

pub(super) fn attribution_ledger_integrity_mismatch(connection: &Connection) -> Result<bool, String> {
    let provenance_epoch = metadata_text(connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "精确 token 来源谱系标识缺失".to_string())?;
    if metadata_text(connection, ATTRIBUTION_LEDGER_EPOCH_KEY)?.as_deref()
        != Some(provenance_epoch.as_str())
    {
        return Ok(false);
    }
    let Some(expected) = metadata_text(connection, ATTRIBUTION_LEDGER_INTEGRITY_KEY)? else {
        return Ok(false);
    };
    Ok(attribution_ledger_integrity(connection, &provenance_epoch)? != expected)
}

/// Persists anonymous source x fixed-5m totals on every exact-index sync, including
/// compact summary syncs. Deleted sources stay in the ledger. A non-append rewrite
/// rotates and rebuilds the epoch in this same publication transaction, so readers
/// can observe either the old events+epoch or the new events+epoch, never a mix.
/// Writes attribution rows/epochs and restores canonical legacy floors using
/// the caller's publication transaction. It does not own a second commit.
pub(super) fn synchronize_attribution_ledger(
    transaction: &Transaction<'_>,
    generation: i64,
    source_index_changed: bool,
    rotate_provenance: bool,
    integrity_mismatch: bool,
) -> Result<bool, String> {
    let previous_epoch = metadata_text(transaction, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "精确 token 来源谱系标识缺失".to_string())?;
    let ledger_epoch = metadata_text(transaction, ATTRIBUTION_LEDGER_EPOCH_KEY)?;
    let stored_integrity = metadata_text(transaction, ATTRIBUTION_LEDGER_INTEGRITY_KEY)?;
    let integrity_missing =
        ledger_epoch.as_deref() == Some(previous_epoch.as_str()) && stored_integrity.is_none();
    // A logically missing ledger row is not reported by SQLite quick_check.
    // Rotate and rebuild instead of silently accepting a smaller local total;
    // consumers will see the new epoch and keep ambiguity sticky for the old
    // segment. This also self-heals without imposing a history cap.
    let provenance_epoch = if rotate_provenance {
        let next = Uuid::new_v4().to_string();
        set_metadata(transaction, ATTRIBUTION_PROVENANCE_EPOCH_KEY, &next)?;
        next
    } else {
        previous_epoch
    };
    let rebuild = rotate_provenance
        || integrity_mismatch
        || ledger_epoch.as_deref() != Some(&provenance_epoch);
    if !rebuild && !source_index_changed && !integrity_missing {
        return Ok(false);
    }
    if rebuild {
        transaction
            .execute("DELETE FROM attribution_source_buckets", [])
            .map_err(|error| format!("无法重建精确 token 归因来源账本：{error}"))?;
    }

    let full_query = r#"
        WITH latest AS (
            SELECT path, MAX(generation) AS generation
            FROM files
            WHERE generation <= ?1
            GROUP BY path
        ), visible_files AS (
            SELECT latest.path, latest.generation
            FROM latest
            JOIN files f
              ON f.path = latest.path
             AND f.generation = latest.generation
            WHERE f.deleted = 0
        )
        SELECT
            e.timestamp - (e.timestamp % ?2),
            e.session_id,
            COALESCE(SUM(e.tokens), 0),
            COUNT(*),
            COALESCE(SUM(e.input_tokens), 0),
            COALESCE(SUM(MIN(e.cached_input_tokens, e.input_tokens)), 0),
            COALESCE(SUM(e.output_tokens), 0)
        FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
        JOIN visible_files f
          ON f.generation = e.file_generation
         AND f.path = e.file_path
        GROUP BY 1, 2
        ORDER BY 1, 2
    "#;
    let incremental_query = full_query.replace(
        "GROUP BY 1, 2",
        // Keep the UUID predicate across every copy, while exposing source_id
        // to the compound event view so SQLite can use its per-source indexes.
        // files includes the effective pending layer; selecting only pending
        // source IDs here would lose unchanged copies of an affected UUID.
        "AND lower(e.session_id) IN (SELECT lower(s.session_id) FROM pending_sources p JOIN sources s USING(source_id) WHERE p.target_generation=?1) \
         AND e.source_id IN (SELECT f.source_id FROM files f WHERE lower(f.session_id) IN (SELECT lower(s.session_id) FROM pending_sources p JOIN sources s USING(source_id) WHERE p.target_generation=?1)) GROUP BY 1, 2"
    );
    let mut source_rows = transaction
        .prepare(if rebuild {
            full_query
        } else {
            incremental_query.as_str()
        })
        .map_err(|error| format!("无法准备精确 token 归因来源账本：{error}"))?;
    let mut rows = source_rows
        .query(params![generation, LONG_RECENT_INTERVAL_SECONDS])
        .map_err(|error| format!("无法读取精确 token 归因来源账本：{error}"))?;
    let mut upsert = transaction
        .prepare(
            r#"
            INSERT INTO attribution_source_buckets(
                provenance_epoch,
                source_id,
                bucket_start,
                tokens,
                calls,
                input_tokens,
                cached_input_tokens,
                output_tokens
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(provenance_epoch, source_id, bucket_start) DO UPDATE SET
                tokens = excluded.tokens,
                calls = excluded.calls,
                input_tokens = excluded.input_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                output_tokens = excluded.output_tokens
            "#,
        )
        .map_err(|error| format!("无法准备写入精确 token 归因来源账本：{error}"))?;
    let mut wrote_rows = false;
    while let Some(row) = rows
        .next()
        .map_err(|error| format!("无法遍历精确 token 归因来源账本：{error}"))?
    {
        let bucket_start = row
            .get::<_, i64>(0)
            .map_err(|error| format!("无法解码精确 token 归因桶时间：{error}"))?;
        let session_id = row
            .get::<_, String>(1)
            .map_err(|error| format!("无法解码精确 token 归因来源：{error}"))?;
        let tokens = row
            .get::<_, i64>(2)
            .map_err(|error| format!("无法解码精确 token 归因总量：{error}"))?;
        let calls = row
            .get::<_, i64>(3)
            .map_err(|error| format!("无法解码精确 token 归因调用量：{error}"))?;
        let input = row
            .get::<_, i64>(4)
            .map_err(|error| format!("无法解码精确 token 归因输入量：{error}"))?;
        let cached = row
            .get::<_, i64>(5)
            .map_err(|error| format!("无法解码精确 token 归因缓存量：{error}"))?;
        let output = row
            .get::<_, i64>(6)
            .map_err(|error| format!("无法解码精确 token 归因输出量：{error}"))?;
        upsert
            .execute(params![
                &provenance_epoch,
                opaque_attribution_source_id(&session_id),
                bucket_start,
                tokens.max(0),
                calls.max(0),
                input.max(0),
                cached.max(0).min(input.max(0)),
                output.max(0),
            ])
            .map_err(|error| format!("无法写入精确 token 归因来源账本：{error}"))?;
        wrote_rows = true;
    }
    drop(rows);
    drop(source_rows);
    canonical::restore_legacy_floors(transaction,&provenance_epoch)?;
    set_metadata(transaction, ATTRIBUTION_LEDGER_EPOCH_KEY, &provenance_epoch)?;
    set_metadata(
        transaction,
        ATTRIBUTION_LEDGER_INTEGRITY_KEY,
        &attribution_ledger_integrity(transaction, &provenance_epoch)?,
    )?;
    Ok(rebuild || wrote_rows)
}

pub(super) fn attribution_ledger_integrity(
    connection: &Connection,
    provenance_epoch: &str,
) -> Result<String, String> {
    connection
        .query_row(
            r#"
            SELECT
                COUNT(*),
                COALESCE(SUM(tokens), 0),
                COALESCE(SUM(calls), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(MIN(bucket_start), 0),
                COALESCE(MAX(bucket_start), 0)
            FROM attribution_source_buckets
            WHERE provenance_epoch = ?1
            "#,
            params![provenance_epoch],
            |row| {
                Ok(format!(
                    "{}:{}:{}:{}:{}:{}:{}:{}",
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                ))
            },
        )
        .map_err(|error| format!("无法校验精确 token 归因来源账本完整性：{error}"))
}

pub(super) fn attribution_safety_state(connection: &Connection) -> Result<AttributionSafetyState, String> {
    let provenance_epoch = metadata_text(connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "精确 token 来源谱系标识缺失".to_string())?;
    let generation =
        nonnegative_u64(metadata_i64(connection, "published_generation")?.unwrap_or(0));
    let unsafe_epoch = metadata_text(connection, ATTRIBUTION_UNSAFE_EPOCH_KEY)?;
    let unsafe_generation =
        metadata_i64(connection, ATTRIBUTION_UNSAFE_GENERATION_KEY)?.map(nonnegative_u64);
    let unsafe_id = metadata_text(connection, ATTRIBUTION_UNSAFE_ID_KEY)?;
    let current_scan_unsafe_cause_detected =
        metadata_i64(connection, ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY)?.unwrap_or(0) != 0;
    let current_scan_incomplete =
        metadata_i64(connection, ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY)?.unwrap_or(0) != 0;
    let unresolved_matches_current = unsafe_epoch.as_deref() == Some(provenance_epoch.as_str())
        && unsafe_generation.is_some()
        && unsafe_id
            .as_deref()
            .is_some_and(|value| Uuid::parse_str(value).is_ok());
    Ok(AttributionSafetyState {
        provenance_epoch,
        generation,
        unsafe_since_generation: unresolved_matches_current
            .then_some(unsafe_generation)
            .flatten(),
        unsafe_id: unresolved_matches_current.then_some(unsafe_id).flatten(),
        current_scan_unsafe_cause_detected,
        current_scan_incomplete,
    })
}

pub(super) fn rotate_attribution_provenance_epoch(connection: &Connection) -> Result<(), String> {
    set_metadata(
        connection,
        ATTRIBUTION_PROVENANCE_EPOCH_KEY,
        &Uuid::new_v4().to_string(),
    )
}

pub(super) fn opaque_attribution_source_id(session_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"codex-token-bar-attribution-source-v1\0");
    hasher.update(session_id.as_bytes());
    format!("{:x}", hasher.finalize())
}
