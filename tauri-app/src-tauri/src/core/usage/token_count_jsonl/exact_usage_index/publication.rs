//! Apply a validated pending generation within the caller's transaction.
//!
//! The parent finalizer owns transaction creation, publication watermarks,
//! certification, stage-consumption receipts and the single commit. This module
//! only applies pending rows; it must keep using the parent's bound transaction.

use super::ledger;
use super::connection::Transaction;
use super::store_metadata::table_exists_checked;
use rusqlite::{params, OptionalExtension};

pub(super) fn publish_schema11_pending_generation(
    transaction: &Transaction<'_>,
    generation: i64,
) -> Result<(), String> {
    ledger::verify_pending_history_layout(transaction)?;
    let active_generation = transaction
        .query_row(
            "SELECT generation FROM active_building_generation",
            [],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|error| format!("无法读取 schema 11 活动 building generation：{error}"))?;
    if active_generation != Some(generation) {
        return Err("schema 11 发布代次不是唯一活动 building generation，已停止发布".into());
    }
    let wrong_generation = transaction
        .query_row(
            r#"
            SELECT EXISTS(
                SELECT 1 FROM pending_sources WHERE target_generation <> ?1
                UNION ALL
                SELECT 1 FROM pending_dashboard_5m WHERE target_generation <> ?1
                UNION ALL
                SELECT 1 FROM pending_dashboard_5m_tombstones WHERE target_generation <> ?1
                UNION ALL
                SELECT 1 FROM pending_dashboard_turn_candidates WHERE target_generation <> ?1
                UNION ALL
                SELECT 1 FROM pending_dashboard_turn_tombstones WHERE target_generation <> ?1
            )
            "#,
            params![generation],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法验证 schema 11 pending 代次：{error}"))?;
    if wrong_generation {
        return Err("schema 11 pending 来源混入其他 building generation，已停止发布".into());
    }
    let tombstone_has_children = transaction
        .query_row(
            r#"
            SELECT EXISTS(
                SELECT 1 FROM pending_sources p
                WHERE p.target_generation = ?1 AND p.mode = 'tombstone'
                  AND (
                    EXISTS(SELECT 1 FROM pending_event_rows e
                           WHERE e.source_id = p.source_id)
                    OR EXISTS(SELECT 1 FROM pending_fingerprints f
                              WHERE f.source_id = p.source_id)
                    OR EXISTS(SELECT 1 FROM pending_chunks c
                              WHERE c.source_id = p.source_id)
                    OR EXISTS(SELECT 1 FROM pending_enrichment e
                              WHERE e.source_id = p.source_id)
                    OR EXISTS(SELECT 1 FROM pending_dashboard_source_totals t
                              WHERE t.source_id = p.source_id)
                    OR EXISTS(SELECT 1 FROM pending_dashboard_source_5m b
                              WHERE b.source_id = p.source_id)
                    OR EXISTS(SELECT 1 FROM pending_dashboard_turn_candidates t
                              WHERE t.target_generation = ?1
                                AND t.source_id = p.source_id)
                  )
            )
            "#,
            params![generation],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法验证 schema 11 墓碑发布范围：{error}"))?;
    if tombstone_has_children {
        return Err("schema 11 单文件墓碑仍携带暂存子行，已停止发布并保留现场".into());
    }

    if table_exists_checked(transaction, "source_representations")? {
        transaction.execute("DELETE FROM source_representations WHERE source_id IN (SELECT source_id FROM pending_sources WHERE target_generation=?1)",
            params![generation]).map_err(|e|e.to_string())?;
    }
    ledger::publish_bindings(transaction, generation)?;

    // Full replacements and tombstones discard only the affected source's
    // published children. The transaction still exposes the old current layer
    // to every other connection until all replacements and the publication
    // receipt commit together.
    transaction
        .execute_batch(
            r#"
            DELETE FROM event_rows
            WHERE source_id IN (
                SELECT source_id FROM pending_sources WHERE mode IN ('full', 'tombstone')
            ) AND NOT EXISTS(SELECT 1 FROM pending_event_rows p WHERE p.id=event_rows.id);

            DELETE FROM source_chunks
            WHERE source_id IN (
                SELECT source_id FROM pending_sources WHERE mode IN ('full', 'tombstone')
            );
            DELETE FROM source_enrichment
            WHERE source_id IN (
                SELECT source_id FROM pending_sources WHERE mode IN ('full', 'tombstone')
            );
            DELETE FROM dashboard_source_totals
            WHERE source_id IN (
                SELECT source_id FROM pending_sources WHERE mode IN ('full', 'tombstone')
            );
            DELETE FROM dashboard_source_5m
            WHERE source_id IN (
                SELECT source_id FROM pending_sources WHERE mode IN ('full', 'tombstone')
            );

            INSERT INTO event_rows(
                id, source_id, ordinal, timestamp, tokens, input_tokens,
                cached_input_tokens, output_tokens, reasoning_output_tokens, model,
                user_prompt_start, user_prompt_end, assistant_response_start,
                assistant_response_end, accounting_kind, reported_total_tokens, token_source_offset, legacy_tokens
            )
            SELECT e.id, e.source_id, e.ordinal, e.timestamp, e.tokens, e.input_tokens,
                   e.cached_input_tokens, e.output_tokens, e.reasoning_output_tokens,
                   e.model, e.user_prompt_start, e.user_prompt_end,
                   e.assistant_response_start, e.assistant_response_end, e.accounting_kind, e.reported_total_tokens, e.token_source_offset, e.legacy_tokens
            FROM pending_event_rows e
            JOIN pending_sources p ON p.source_id = e.source_id
            WHERE p.target_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata
                WHERE key = 'building_generation'
            ) AND p.mode <> 'tombstone'
            ON CONFLICT(id) DO UPDATE SET model=COALESCE(event_rows.model,excluded.model),
                user_prompt_start=COALESCE(event_rows.user_prompt_start,excluded.user_prompt_start),
                user_prompt_end=COALESCE(event_rows.user_prompt_end,excluded.user_prompt_end),
                assistant_response_start=COALESCE(event_rows.assistant_response_start,excluded.assistant_response_start),
                assistant_response_end=COALESCE(event_rows.assistant_response_end,excluded.assistant_response_end),
                tokens=excluded.tokens,input_tokens=excluded.input_tokens,cached_input_tokens=excluded.cached_input_tokens,
                output_tokens=excluded.output_tokens,reasoning_output_tokens=excluded.reasoning_output_tokens,
                accounting_kind=excluded.accounting_kind,reported_total_tokens=excluded.reported_total_tokens
            WHERE (event_rows.model IS NULL AND excluded.model IS NOT NULL)
                OR (event_rows.user_prompt_start IS NULL AND excluded.user_prompt_start IS NOT NULL)
                OR (event_rows.user_prompt_end IS NULL AND excluded.user_prompt_end IS NOT NULL)
                OR (event_rows.assistant_response_start IS NULL AND excluded.assistant_response_start IS NOT NULL)
                OR (event_rows.assistant_response_end IS NULL AND excluded.assistant_response_end IS NOT NULL)
                OR event_rows.tokens IS NOT excluded.tokens OR event_rows.input_tokens IS NOT excluded.input_tokens
                OR event_rows.cached_input_tokens IS NOT excluded.cached_input_tokens OR event_rows.output_tokens IS NOT excluded.output_tokens
                OR event_rows.reasoning_output_tokens IS NOT excluded.reasoning_output_tokens
                OR event_rows.accounting_kind IS NOT excluded.accounting_kind OR event_rows.reported_total_tokens IS NOT excluded.reported_total_tokens;

            INSERT OR IGNORE INTO source_fingerprints(source_id, fingerprint)
            SELECT f.source_id, f.fingerprint
            FROM pending_fingerprints f JOIN pending_sources p USING(source_id)
            WHERE p.mode <> 'tombstone';

            INSERT INTO source_chunks(source_id, chunk_index, byte_count, sha256)
            SELECT c.source_id, c.chunk_index, c.byte_count, c.sha256
            FROM pending_chunks c JOIN pending_sources p USING(source_id)
            WHERE p.mode <> 'tombstone'
            ON CONFLICT(source_id, chunk_index) DO UPDATE SET
                byte_count = excluded.byte_count,
                sha256 = excluded.sha256;

            INSERT INTO source_enrichment(
                source_id, revision, parser_revision, completed_size,
                completed_prefix_sha256
            )
            SELECT e.source_id, e.revision, e.parser_revision,
                   e.completed_size, e.completed_prefix_sha256
            FROM pending_enrichment e JOIN pending_sources p USING(source_id)
            WHERE p.mode <> 'tombstone'
            ON CONFLICT(source_id) DO UPDATE SET
                revision = excluded.revision,
                parser_revision = excluded.parser_revision,
                completed_size = excluded.completed_size,
                completed_prefix_sha256 = excluded.completed_prefix_sha256;

            INSERT INTO dashboard_source_totals(
                source_id, total_tokens, calls, input_tokens, cached_input_tokens,
                output_tokens, first_timestamp, last_timestamp
            )
            SELECT t.source_id, t.total_tokens, t.calls, t.input_tokens,
                   t.cached_input_tokens, t.output_tokens,
                   t.first_timestamp, t.last_timestamp
            FROM pending_dashboard_source_totals t
            JOIN pending_sources p USING(source_id)
            WHERE p.mode = 'full'
            ON CONFLICT(source_id) DO UPDATE SET
                total_tokens = excluded.total_tokens,
                calls = excluded.calls,
                input_tokens = excluded.input_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                output_tokens = excluded.output_tokens,
                first_timestamp = excluded.first_timestamp,
                last_timestamp = excluded.last_timestamp;

            INSERT INTO dashboard_source_totals(
                source_id, total_tokens, calls, input_tokens, cached_input_tokens,
                output_tokens, first_timestamp, last_timestamp
            )
            SELECT t.source_id, t.total_tokens, t.calls, t.input_tokens,
                   t.cached_input_tokens, t.output_tokens,
                   t.first_timestamp, t.last_timestamp
            FROM pending_dashboard_source_totals t
            JOIN pending_sources p USING(source_id)
            WHERE p.mode = 'delta'
            ON CONFLICT(source_id) DO UPDATE SET
                total_tokens = dashboard_source_totals.total_tokens + excluded.total_tokens,
                calls = dashboard_source_totals.calls + excluded.calls,
                input_tokens = dashboard_source_totals.input_tokens + excluded.input_tokens,
                cached_input_tokens = dashboard_source_totals.cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = dashboard_source_totals.output_tokens + excluded.output_tokens,
                first_timestamp = CASE
                    WHEN dashboard_source_totals.first_timestamp IS NULL THEN excluded.first_timestamp
                    WHEN excluded.first_timestamp IS NULL THEN dashboard_source_totals.first_timestamp
                    ELSE MIN(dashboard_source_totals.first_timestamp, excluded.first_timestamp)
                END,
                last_timestamp = CASE
                    WHEN dashboard_source_totals.last_timestamp IS NULL THEN excluded.last_timestamp
                    WHEN excluded.last_timestamp IS NULL THEN dashboard_source_totals.last_timestamp
                    ELSE MAX(dashboard_source_totals.last_timestamp, excluded.last_timestamp)
                END;

            INSERT INTO dashboard_source_5m(
                source_id, bucket_start, model_key, model, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens
            )
            SELECT b.source_id, b.bucket_start, b.model_key, b.model,
                   b.total_tokens, b.calls, b.input_tokens,
                   b.cached_input_tokens, b.output_tokens
            FROM pending_dashboard_source_5m b
            JOIN pending_sources p USING(source_id)
            WHERE p.mode = 'full'
            ON CONFLICT(source_id, bucket_start, model_key) DO UPDATE SET
                model = excluded.model, total_tokens = excluded.total_tokens,
                calls = excluded.calls, input_tokens = excluded.input_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                output_tokens = excluded.output_tokens;

            INSERT INTO dashboard_source_5m(
                source_id, bucket_start, model_key, model, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens
            )
            SELECT b.source_id, b.bucket_start, b.model_key, b.model,
                   b.total_tokens, b.calls, b.input_tokens,
                   b.cached_input_tokens, b.output_tokens
            FROM pending_dashboard_source_5m b
            JOIN pending_sources p USING(source_id)
            WHERE p.mode = 'delta'
            ON CONFLICT(source_id, bucket_start, model_key) DO UPDATE SET
                model = excluded.model,
                total_tokens = dashboard_source_5m.total_tokens + excluded.total_tokens,
                calls = dashboard_source_5m.calls + excluded.calls,
                input_tokens = dashboard_source_5m.input_tokens + excluded.input_tokens,
                cached_input_tokens = dashboard_source_5m.cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = dashboard_source_5m.output_tokens + excluded.output_tokens;

            DELETE FROM dashboard_5m_current
            WHERE EXISTS(
                SELECT 1 FROM pending_dashboard_5m_tombstones t
                WHERE t.target_generation = (
                    SELECT CAST(value AS INTEGER) FROM metadata
                    WHERE key = 'building_generation'
                )
                  AND t.bucket_start = dashboard_5m_current.bucket_start
                  AND t.model_key = dashboard_5m_current.model_key
            );
            INSERT INTO dashboard_5m_current(
                bucket_start, model_key, model, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens
            )
            SELECT bucket_start, model_key, model, total_tokens, calls,
                   input_tokens, cached_input_tokens, output_tokens
            FROM pending_dashboard_5m
            WHERE target_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata
                WHERE key = 'building_generation'
            )
            ON CONFLICT(bucket_start, model_key) DO UPDATE SET
                model = excluded.model, total_tokens = excluded.total_tokens,
                calls = excluded.calls, input_tokens = excluded.input_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                output_tokens = excluded.output_tokens;

            DELETE FROM dashboard_turn_candidates_current
            WHERE EXISTS(
                SELECT 1 FROM pending_dashboard_turn_tombstones t
                WHERE t.target_generation = (
                    SELECT CAST(value AS INTEGER) FROM metadata
                    WHERE key = 'building_generation'
                )
                  AND t.source_id = dashboard_turn_candidates_current.source_id
                  AND t.ordinal = dashboard_turn_candidates_current.ordinal
            ) OR source_id IN (
                SELECT source_id FROM pending_sources WHERE mode = 'tombstone'
            );
            INSERT INTO dashboard_turn_candidates_current(
                source_id, ordinal, event_id, source_file_generation, timestamp,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                user_prompt_start, user_prompt_end, assistant_response_start,
                assistant_response_end, turn_index, session_calls,
                request_count, low_hit_count, zero_hit_count
            )
            SELECT source_id, ordinal, event_id, source_file_generation, timestamp,
                   total_tokens, input_tokens, cached_input_tokens, output_tokens,
                   user_prompt_start, user_prompt_end, assistant_response_start,
                   assistant_response_end, turn_index, session_calls,
                   request_count, low_hit_count, zero_hit_count
            FROM pending_dashboard_turn_candidates
            WHERE target_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata
                WHERE key = 'building_generation'
            )
            ON CONFLICT(source_id, ordinal) DO UPDATE SET
                event_id = excluded.event_id,
                source_file_generation = excluded.source_file_generation,
                timestamp = excluded.timestamp, total_tokens = excluded.total_tokens,
                input_tokens = excluded.input_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                output_tokens = excluded.output_tokens,
                user_prompt_start = excluded.user_prompt_start,
                user_prompt_end = excluded.user_prompt_end,
                assistant_response_start = excluded.assistant_response_start,
                assistant_response_end = excluded.assistant_response_end,
                turn_index = excluded.turn_index, session_calls = excluded.session_calls,
                request_count = excluded.request_count,
                low_hit_count = excluded.low_hit_count,
                zero_hit_count = excluded.zero_hit_count;

            UPDATE sources SET
                deleted = (SELECT p.deleted FROM pending_sources p
                           WHERE p.source_id = sources.source_id),
                last_seen_generation = (SELECT p.target_generation FROM pending_sources p
                                        WHERE p.source_id = sources.source_id),
                size = (SELECT p.size FROM pending_sources p
                        WHERE p.source_id = sources.source_id),
                modified_ns = (SELECT p.modified_ns FROM pending_sources p
                               WHERE p.source_id = sources.source_id),
                prefix_sha256 = (SELECT p.prefix_sha256 FROM pending_sources p
                                 WHERE p.source_id = sources.source_id),
                append_ready = (SELECT p.append_ready FROM pending_sources p
                                WHERE p.source_id = sources.source_id),
                resume_offset = (SELECT p.resume_offset FROM pending_sources p
                                 WHERE p.source_id = sources.source_id),
                previous_total_tokens = (SELECT p.previous_total_tokens FROM pending_sources p
                                         WHERE p.source_id = sources.source_id),
                fork_replay_started_ns = (SELECT p.fork_replay_started_ns FROM pending_sources p
                                          WHERE p.source_id = sources.source_id),
                fork_replay_active = (SELECT p.fork_replay_active FROM pending_sources p
                                      WHERE p.source_id = sources.source_id),
                is_explicit_subagent_fork = (SELECT p.is_explicit_subagent_fork
                                             FROM pending_sources p
                                             WHERE p.source_id = sources.source_id),
                last_skipped_fork_replay_token_ns = (
                    SELECT p.last_skipped_fork_replay_token_ns FROM pending_sources p
                    WHERE p.source_id = sources.source_id
                ),
                current_model = (SELECT p.current_model FROM pending_sources p
                                 WHERE p.source_id = sources.source_id),
                current_user_prompt_start = (SELECT p.current_user_prompt_start
                                             FROM pending_sources p
                                             WHERE p.source_id = sources.source_id),
                current_user_prompt_end = (SELECT p.current_user_prompt_end
                                           FROM pending_sources p
                                           WHERE p.source_id = sources.source_id),
                assistant_response_start = (SELECT p.assistant_response_start
                                            FROM pending_sources p
                                            WHERE p.source_id = sources.source_id),
                assistant_response_end = (SELECT p.assistant_response_end
                                          FROM pending_sources p
                                          WHERE p.source_id = sources.source_id),
                audit_chunk_index = (SELECT p.audit_chunk_index FROM pending_sources p
                                     WHERE p.source_id = sources.source_id),
                accounting_state = (SELECT p.accounting_state FROM pending_sources p WHERE p.source_id = sources.source_id)
            WHERE source_id IN (SELECT source_id FROM pending_sources);

            DELETE FROM pending_sources;
            DELETE FROM pending_dashboard_5m
            WHERE target_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata
                WHERE key = 'building_generation'
            );
            DELETE FROM pending_dashboard_5m_tombstones
            WHERE target_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata
                WHERE key = 'building_generation'
            );
            DELETE FROM pending_dashboard_turn_candidates
            WHERE target_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata
                WHERE key = 'building_generation'
            );
            DELETE FROM pending_dashboard_turn_tombstones
            WHERE target_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata
                WHERE key = 'building_generation'
            );
            "#,
        )
        .map_err(|error| format!("无法合并 schema 11 pending generation：{error}"))?;
    Ok(())
}
