//! Exact index tables, compatibility views and write triggers.
//!
//! Callers retain the original connection and transaction ownership. Keep SQL
//! batches and their execution order intact, including conditional column upgrades.

use super::dashboard_buckets;
use super::sources::ensure_source_observations;
use super::connection::Connection;
use super::store_metadata::column_exists_checked;

pub(super) fn initialize_index_schema(connection: &Connection) -> Result<(), String> {
    ensure_source_observations(connection)?;
    connection
        .execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS sources (
                source_id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                session_id TEXT NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0,
                last_seen_generation INTEGER NOT NULL DEFAULT 0,
                size INTEGER NOT NULL DEFAULT 0,
                modified_ns TEXT NOT NULL DEFAULT '0',
                prefix_sha256 BLOB NOT NULL DEFAULT X'',
                append_ready INTEGER NOT NULL DEFAULT 0,
                resume_offset INTEGER,
                previous_total_tokens INTEGER,
                fork_replay_started_ns TEXT,
                fork_replay_active INTEGER NOT NULL DEFAULT 0,
                is_explicit_subagent_fork INTEGER NOT NULL DEFAULT 0,
                last_skipped_fork_replay_token_ns TEXT,
                current_model TEXT,
                current_user_prompt_start INTEGER,
                current_user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                audit_chunk_index INTEGER NOT NULL DEFAULT 0,
                accounting_state TEXT
            ) WITHOUT ROWID;

            -- `sources` and the tables without a `pending_` prefix are always
            -- the last published generation. A scan writes only the pending
            -- layer; compatibility views expose a virtual target generation
            -- to the existing bounded parser without hiding lastGood.
            CREATE TABLE IF NOT EXISTS pending_sources (
                source_id INTEGER PRIMARY KEY REFERENCES sources(source_id) ON DELETE CASCADE,
                target_generation INTEGER NOT NULL,
                mode TEXT NOT NULL CHECK(mode IN ('delta', 'full', 'tombstone')),
                deleted INTEGER NOT NULL DEFAULT 0,
                size INTEGER NOT NULL DEFAULT 0,
                modified_ns TEXT NOT NULL DEFAULT '0',
                prefix_sha256 BLOB NOT NULL DEFAULT X'',
                append_ready INTEGER NOT NULL DEFAULT 0,
                resume_offset INTEGER,
                previous_total_tokens INTEGER,
                fork_replay_started_ns TEXT,
                fork_replay_active INTEGER NOT NULL DEFAULT 0,
                is_explicit_subagent_fork INTEGER NOT NULL DEFAULT 0,
                last_skipped_fork_replay_token_ns TEXT,
                current_model TEXT,
                current_user_prompt_start INTEGER,
                current_user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                audit_chunk_index INTEGER NOT NULL DEFAULT 0,
                accounting_state TEXT
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS event_rows (
                id INTEGER PRIMARY KEY,
                source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
                model TEXT,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                accounting_kind INTEGER NOT NULL DEFAULT 0,
                reported_total_tokens INTEGER, token_source_offset INTEGER, legacy_tokens INTEGER,
                UNIQUE(source_id, ordinal)
            );
            CREATE TABLE IF NOT EXISTS pending_event_rows (
                id INTEGER PRIMARY KEY,
                source_id INTEGER NOT NULL REFERENCES pending_sources(source_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
                model TEXT,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                accounting_kind INTEGER NOT NULL DEFAULT 0,
                reported_total_tokens INTEGER, token_source_offset INTEGER, legacy_tokens INTEGER,
                UNIQUE(source_id, ordinal)
            );
            CREATE INDEX IF NOT EXISTS event_rows_timestamp_idx ON event_rows(timestamp);
            CREATE INDEX IF NOT EXISTS event_rows_source_idx
                ON event_rows(source_id, timestamp, tokens, ordinal);
            CREATE INDEX IF NOT EXISTS event_rows_input_idx
                ON event_rows(input_tokens, cached_input_tokens, timestamp, source_id, ordinal);
            CREATE INDEX IF NOT EXISTS pending_event_rows_source_idx
                ON pending_event_rows(source_id, timestamp, ordinal);

            CREATE TABLE IF NOT EXISTS source_fingerprints (
                source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                fingerprint BLOB NOT NULL,
                PRIMARY KEY(source_id, fingerprint)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_fingerprints (
                source_id INTEGER NOT NULL REFERENCES pending_sources(source_id) ON DELETE CASCADE,
                fingerprint BLOB NOT NULL,
                PRIMARY KEY(source_id, fingerprint)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS source_chunks (
                source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                byte_count INTEGER NOT NULL,
                sha256 BLOB NOT NULL,
                PRIMARY KEY(source_id, chunk_index)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_chunks (
                source_id INTEGER NOT NULL REFERENCES pending_sources(source_id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                byte_count INTEGER NOT NULL,
                sha256 BLOB NOT NULL,
                PRIMARY KEY(source_id, chunk_index)
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS source_enrichment (
                source_id INTEGER PRIMARY KEY REFERENCES sources(source_id) ON DELETE CASCADE,
                revision TEXT NOT NULL,
                parser_revision TEXT NOT NULL,
                completed_size INTEGER NOT NULL,
                completed_prefix_sha256 BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_enrichment (
                source_id INTEGER PRIMARY KEY REFERENCES pending_sources(source_id) ON DELETE CASCADE,
                revision TEXT NOT NULL,
                parser_revision TEXT NOT NULL,
                completed_size INTEGER NOT NULL,
                completed_prefix_sha256 BLOB NOT NULL
            ) WITHOUT ROWID;

            -- Pending file aggregates are replacements for full rebuilds and
            -- suffix deltas for append scans. The read views merge the latter
            -- without copying the published rows into every generation.
            CREATE TABLE IF NOT EXISTS dashboard_source_totals (
                source_id INTEGER PRIMARY KEY REFERENCES sources(source_id) ON DELETE CASCADE,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                first_timestamp INTEGER,
                last_timestamp INTEGER
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_dashboard_source_totals (
                source_id INTEGER PRIMARY KEY REFERENCES pending_sources(source_id) ON DELETE CASCADE,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                first_timestamp INTEGER,
                last_timestamp INTEGER
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS dashboard_source_5m (
                source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                bucket_start INTEGER NOT NULL,
                model_key TEXT NOT NULL,
                model TEXT,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(source_id, bucket_start, model_key)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_dashboard_source_5m (
                source_id INTEGER NOT NULL REFERENCES pending_sources(source_id) ON DELETE CASCADE,
                bucket_start INTEGER NOT NULL,
                model_key TEXT NOT NULL,
                model TEXT,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(source_id, bucket_start, model_key)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS dashboard_source_5m_time_idx
                ON dashboard_source_5m(bucket_start, source_id);

            -- Global five-minute and turn projections use sparse replacement
            -- rows plus explicit tombstones. That keeps the target generation
            -- queryable while writes stay proportional to affected buckets.
            CREATE TABLE IF NOT EXISTS dashboard_5m_current (
                bucket_start INTEGER NOT NULL,
                model_key TEXT NOT NULL,
                model TEXT,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(bucket_start, model_key)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_dashboard_5m (
                target_generation INTEGER NOT NULL,
                bucket_start INTEGER NOT NULL,
                model_key TEXT NOT NULL,
                model TEXT,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(target_generation, bucket_start, model_key)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_dashboard_5m_tombstones (
                target_generation INTEGER NOT NULL,
                bucket_start INTEGER NOT NULL,
                model_key TEXT NOT NULL,
                PRIMARY KEY(target_generation, bucket_start, model_key)
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS dashboard_turn_candidates_current (
                source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                event_id INTEGER NOT NULL,
                source_file_generation INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                turn_index INTEGER NOT NULL,
                session_calls INTEGER NOT NULL,
                request_count INTEGER NOT NULL DEFAULT 0,
                low_hit_count INTEGER NOT NULL DEFAULT 0,
                zero_hit_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(source_id, ordinal)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_dashboard_turn_candidates (
                target_generation INTEGER NOT NULL,
                source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                event_id INTEGER NOT NULL,
                source_file_generation INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                turn_index INTEGER NOT NULL,
                session_calls INTEGER NOT NULL,
                request_count INTEGER NOT NULL DEFAULT 0,
                low_hit_count INTEGER NOT NULL DEFAULT 0,
                zero_hit_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(target_generation, source_id, ordinal)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_dashboard_turn_tombstones (
                target_generation INTEGER NOT NULL,
                source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                PRIMARY KEY(target_generation, source_id, ordinal)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS dashboard_turn_candidates_order_idx
                ON dashboard_turn_candidates_current(timestamp, input_tokens, cached_input_tokens);
            CREATE INDEX IF NOT EXISTS pending_dashboard_turn_candidates_order_idx
                ON pending_dashboard_turn_candidates(
                    target_generation, timestamp, input_tokens, cached_input_tokens
                );

            CREATE TABLE IF NOT EXISTS attribution_source_buckets (
                provenance_epoch TEXT NOT NULL,
                source_id TEXT NOT NULL,
                bucket_start INTEGER NOT NULL,
                tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(provenance_epoch, source_id, bucket_start)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS attribution_source_buckets_time_idx
                ON attribution_source_buckets(provenance_epoch, bucket_start);
            CREATE INDEX IF NOT EXISTS sources_session_idx ON sources(session_id, source_id);
            CREATE INDEX IF NOT EXISTS sources_session_nocase_idx
                ON sources(session_id COLLATE NOCASE, source_id);
            CREATE TABLE IF NOT EXISTS session_metadata (
                session_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                updated_at INTEGER
            ) WITHOUT ROWID;

            INSERT OR IGNORE INTO metadata(key, value) VALUES ('event_id_sequence', '0');

            CREATE VIEW IF NOT EXISTS active_building_generation AS
            SELECT CAST(building.value AS INTEGER) AS generation
            FROM metadata building
            JOIN metadata published ON published.key = 'published_generation'
            WHERE building.key = 'building_generation'
              AND CAST(building.value AS INTEGER) > CAST(published.value AS INTEGER);

            CREATE VIEW IF NOT EXISTS files AS
            SELECT
                s.last_seen_generation AS generation, s.path, s.deleted, s.session_id,
                s.size, s.modified_ns, s.prefix_sha256, s.append_ready, s.resume_offset,
                s.previous_total_tokens, s.fork_replay_started_ns, s.fork_replay_active,
                s.is_explicit_subagent_fork, s.last_skipped_fork_replay_token_ns,
                s.current_model, s.current_user_prompt_start, s.current_user_prompt_end,
                s.assistant_response_start, s.assistant_response_end, s.audit_chunk_index,
                s.source_id, s.accounting_state
            FROM sources s
            UNION ALL
            SELECT
                p.target_generation, s.path, p.deleted, s.session_id,
                p.size, p.modified_ns, p.prefix_sha256, p.append_ready, p.resume_offset,
                p.previous_total_tokens, p.fork_replay_started_ns, p.fork_replay_active,
                p.is_explicit_subagent_fork, p.last_skipped_fork_replay_token_ns,
                p.current_model, p.current_user_prompt_start, p.current_user_prompt_end,
                p.assistant_response_start, p.assistant_response_end, p.audit_chunk_index,
                p.source_id, p.accounting_state
            FROM pending_sources p
            JOIN sources s ON s.source_id = p.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation;

            CREATE VIEW IF NOT EXISTS events AS
            SELECT
                e.id, s.last_seen_generation AS file_generation, s.path AS file_path,
                e.ordinal, e.timestamp, s.session_id, e.tokens, e.input_tokens,
                e.cached_input_tokens, e.output_tokens, e.reasoning_output_tokens,
                e.model, e.user_prompt_start, e.user_prompt_end,
                e.assistant_response_start, e.assistant_response_end, e.source_id, e.accounting_kind, e.reported_total_tokens, e.token_source_offset, e.legacy_tokens
            FROM event_rows e JOIN sources s ON s.source_id = e.source_id
            UNION ALL
            SELECT
                e.id, p.target_generation, s.path, e.ordinal, e.timestamp, s.session_id,
                e.tokens, e.input_tokens, e.cached_input_tokens, e.output_tokens,
                e.reasoning_output_tokens, e.model, e.user_prompt_start, e.user_prompt_end,
                e.assistant_response_start, e.assistant_response_end, e.source_id, e.accounting_kind, e.reported_total_tokens, e.token_source_offset, e.legacy_tokens
            FROM event_rows e
            JOIN pending_sources p ON p.source_id = e.source_id AND p.mode = 'delta'
            JOIN sources s ON s.source_id = e.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation
            UNION ALL
            SELECT
                e.id, p.target_generation, s.path, e.ordinal, e.timestamp, s.session_id,
                e.tokens, e.input_tokens, e.cached_input_tokens, e.output_tokens,
                e.reasoning_output_tokens, e.model, e.user_prompt_start, e.user_prompt_end,
                e.assistant_response_start, e.assistant_response_end, e.source_id, e.accounting_kind, e.reported_total_tokens, e.token_source_offset, e.legacy_tokens
            FROM pending_event_rows e
            JOIN pending_sources p ON p.source_id = e.source_id
            JOIN sources s ON s.source_id = e.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation;

            CREATE VIEW IF NOT EXISTS file_fingerprints AS
            SELECT s.last_seen_generation AS file_generation,
                   s.path AS file_path, f.fingerprint, f.source_id
            FROM source_fingerprints f JOIN sources s ON s.source_id = f.source_id
            UNION ALL
            SELECT p.target_generation, s.path, f.fingerprint, f.source_id
            FROM source_fingerprints f
            JOIN pending_sources p ON p.source_id = f.source_id AND p.mode = 'delta'
            JOIN sources s ON s.source_id = f.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation
            UNION ALL
            SELECT p.target_generation, s.path, f.fingerprint, f.source_id
            FROM pending_fingerprints f
            JOIN pending_sources p ON p.source_id = f.source_id
            JOIN sources s ON s.source_id = f.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation;

            CREATE VIEW IF NOT EXISTS file_chunks AS
            SELECT s.last_seen_generation AS file_generation,
                   s.path AS file_path, c.chunk_index, c.byte_count, c.sha256, c.source_id
            FROM source_chunks c JOIN sources s ON s.source_id = c.source_id
            UNION ALL
            SELECT p.target_generation, s.path, c.chunk_index, c.byte_count, c.sha256, c.source_id
            FROM source_chunks c
            JOIN pending_sources p ON p.source_id = c.source_id AND p.mode = 'delta'
            JOIN sources s ON s.source_id = c.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation
            WHERE NOT EXISTS (
                SELECT 1 FROM pending_chunks replacement
                WHERE replacement.source_id = c.source_id
                  AND replacement.chunk_index = c.chunk_index
            )
            UNION ALL
            SELECT p.target_generation, s.path, c.chunk_index, c.byte_count, c.sha256, c.source_id
            FROM pending_chunks c
            JOIN pending_sources p ON p.source_id = c.source_id
            JOIN sources s ON s.source_id = c.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation;

            CREATE VIEW IF NOT EXISTS event_enrichment_sources AS
            SELECT s.path, e.revision, e.parser_revision,
                   s.last_seen_generation AS file_generation,
                   e.completed_size, e.completed_prefix_sha256, e.source_id
            FROM source_enrichment e JOIN sources s ON s.source_id = e.source_id
            UNION ALL
            SELECT s.path, e.revision, e.parser_revision, p.target_generation,
                   e.completed_size, e.completed_prefix_sha256, e.source_id
            FROM pending_enrichment e
            JOIN pending_sources p ON p.source_id = e.source_id
            JOIN sources s ON s.source_id = e.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation;

            CREATE VIEW IF NOT EXISTS dashboard_file_totals AS
            SELECT s.last_seen_generation AS file_generation,
                   s.path AS file_path, s.session_id,
                   t.total_tokens, t.calls, t.input_tokens, t.cached_input_tokens,
                   t.output_tokens, t.first_timestamp, t.last_timestamp, t.source_id
            FROM dashboard_source_totals t JOIN sources s ON s.source_id = t.source_id
            UNION ALL
            SELECT p.target_generation, s.path, s.session_id,
                   t.total_tokens, t.calls, t.input_tokens, t.cached_input_tokens,
                   t.output_tokens, t.first_timestamp, t.last_timestamp, t.source_id
            FROM pending_dashboard_source_totals t
            JOIN pending_sources p ON p.source_id = t.source_id AND p.mode = 'full'
            JOIN sources s ON s.source_id = t.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation
            UNION ALL
            SELECT p.target_generation, s.path, s.session_id,
                   SUM(parts.total_tokens), SUM(parts.calls), SUM(parts.input_tokens),
                   SUM(parts.cached_input_tokens), SUM(parts.output_tokens),
                   MIN(parts.first_timestamp), MAX(parts.last_timestamp), p.source_id
            FROM pending_sources p
            JOIN sources s ON s.source_id = p.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation
            JOIN (
                SELECT source_id, total_tokens, calls, input_tokens, cached_input_tokens,
                       output_tokens, first_timestamp, last_timestamp
                FROM dashboard_source_totals
                UNION ALL
                SELECT source_id, total_tokens, calls, input_tokens, cached_input_tokens,
                       output_tokens, first_timestamp, last_timestamp
                FROM pending_dashboard_source_totals
            ) parts ON parts.source_id = p.source_id
            WHERE p.mode = 'delta'
            GROUP BY p.target_generation, p.source_id, s.path, s.session_id;

            CREATE VIEW IF NOT EXISTS dashboard_file_5m AS
            SELECT s.last_seen_generation AS file_generation,
                   s.path AS file_path, b.bucket_start, b.model_key, b.model,
                   b.total_tokens, b.calls, b.input_tokens, b.cached_input_tokens,
                   b.output_tokens, b.source_id
            FROM dashboard_source_5m b JOIN sources s ON s.source_id = b.source_id
            UNION ALL
            SELECT p.target_generation, s.path, b.bucket_start, b.model_key, b.model,
                   b.total_tokens, b.calls, b.input_tokens, b.cached_input_tokens,
                   b.output_tokens, b.source_id
            FROM pending_dashboard_source_5m b
            JOIN pending_sources p ON p.source_id = b.source_id AND p.mode = 'full'
            JOIN sources s ON s.source_id = b.source_id
            JOIN active_building_generation active ON active.generation = p.target_generation
            UNION ALL
            SELECT p.target_generation, s.path, parts.bucket_start, parts.model_key,
                   MAX(parts.model), SUM(parts.total_tokens), SUM(parts.calls),
                   SUM(parts.input_tokens), SUM(parts.cached_input_tokens),
                   SUM(parts.output_tokens), p.source_id
            FROM pending_sources p
            JOIN sources s ON s.source_id = p.source_id
            JOIN active_building_generation active ON active.generation = p.target_generation
            JOIN (
                SELECT source_id, bucket_start, model_key, model, total_tokens, calls,
                       input_tokens, cached_input_tokens, output_tokens
                FROM dashboard_source_5m
                UNION ALL
                SELECT source_id, bucket_start, model_key, model, total_tokens, calls,
                       input_tokens, cached_input_tokens, output_tokens
                FROM pending_dashboard_source_5m
            ) parts ON parts.source_id = p.source_id
            WHERE p.mode = 'delta'
            GROUP BY p.target_generation, p.source_id, s.path,
                     parts.bucket_start, parts.model_key;

            CREATE VIEW IF NOT EXISTS dashboard_5m AS
            SELECT
                COALESCE((SELECT CAST(value AS INTEGER) FROM metadata
                          WHERE key = 'published_generation'), 0) AS file_generation,
                c.bucket_start, c.model_key, c.model, c.total_tokens, c.calls,
                c.input_tokens, c.cached_input_tokens, c.output_tokens
            FROM dashboard_5m_current c
            UNION ALL
            SELECT b.generation, c.bucket_start, c.model_key, c.model,
                   c.total_tokens, c.calls, c.input_tokens,
                   c.cached_input_tokens, c.output_tokens
            FROM dashboard_5m_current c
            JOIN active_building_generation b
            WHERE NOT EXISTS (
                    SELECT 1 FROM pending_dashboard_5m p
                    WHERE p.target_generation = b.generation
                      AND p.bucket_start = c.bucket_start AND p.model_key = c.model_key
              )
              AND NOT EXISTS (
                    SELECT 1 FROM pending_dashboard_5m_tombstones t
                    WHERE t.target_generation = b.generation
                      AND t.bucket_start = c.bucket_start AND t.model_key = c.model_key
              )
            UNION ALL
            SELECT p.target_generation, p.bucket_start, p.model_key, p.model,
                   p.total_tokens, p.calls, p.input_tokens,
                   p.cached_input_tokens, p.output_tokens
            FROM pending_dashboard_5m p
            JOIN active_building_generation b ON b.generation = p.target_generation;

            CREATE VIEW IF NOT EXISTS published_files AS
            SELECT
                s.last_seen_generation AS generation, s.path, s.deleted, s.session_id,
                s.size, s.modified_ns, s.prefix_sha256, s.append_ready, s.resume_offset,
                s.previous_total_tokens, s.fork_replay_started_ns, s.fork_replay_active,
                s.is_explicit_subagent_fork, s.last_skipped_fork_replay_token_ns,
                s.current_model, s.current_user_prompt_start, s.current_user_prompt_end,
                s.assistant_response_start, s.assistant_response_end, s.audit_chunk_index,
                s.source_id, s.accounting_state
            FROM sources s
            WHERE s.deleted = 0
              AND s.last_seen_generation <= COALESCE(
                    (SELECT CAST(value AS INTEGER) FROM metadata
                     WHERE key = 'published_generation'), 0);
            CREATE VIEW IF NOT EXISTS published_events AS
            SELECT
                e.id, s.last_seen_generation AS file_generation, s.path AS file_path,
                e.ordinal, e.timestamp, s.session_id, e.tokens, e.input_tokens,
                e.cached_input_tokens, e.output_tokens, e.reasoning_output_tokens,
                e.model, e.user_prompt_start, e.user_prompt_end,
                e.assistant_response_start, e.assistant_response_end, e.source_id, e.accounting_kind, e.reported_total_tokens, e.token_source_offset, e.legacy_tokens
            FROM event_rows e
            JOIN sources s ON s.source_id = e.source_id
            JOIN published_files f ON f.source_id = e.source_id WHERE e.tokens > 0;
            "#,
        )
        .map_err(|error| format!("无法初始化 schema 11 精确 token 索引结构：{error}"))?;
    dashboard_buckets::install(connection)?;

    for table in [
        "dashboard_turn_candidates_current",
        "pending_dashboard_turn_candidates",
    ] {
        for (column, definition) in [
            ("request_count", "INTEGER NOT NULL DEFAULT 0"),
            ("low_hit_count", "INTEGER NOT NULL DEFAULT 0"),
            ("zero_hit_count", "INTEGER NOT NULL DEFAULT 0"),
        ] {
            if !column_exists_checked(connection, table, column)? {
                connection
                    .execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {definition};"))
                    .map_err(|error| format!("无法升级轮次候选字段 {table}.{column}：{error}"))?;
            }
        }
    }
    connection
        .execute_batch(
            r#"
            DROP TRIGGER IF EXISTS dashboard_turn_candidates_schema11_delete;
            DROP TRIGGER IF EXISTS dashboard_turn_candidates_schema11_insert;
            DROP VIEW IF EXISTS dashboard_turn_candidates;
            CREATE VIEW dashboard_turn_candidates AS
            SELECT
                COALESCE((SELECT CAST(value AS INTEGER) FROM metadata
                          WHERE key = 'published_generation'), 0) AS aggregate_generation,
                c.event_id, c.source_file_generation, s.path AS file_path,
                c.ordinal, c.timestamp,
                s.session_id, c.total_tokens, c.input_tokens, c.cached_input_tokens,
                c.output_tokens, c.user_prompt_start, c.user_prompt_end,
                c.assistant_response_start, c.assistant_response_end,
                c.turn_index, c.session_calls, c.request_count,
                c.low_hit_count, c.zero_hit_count, c.source_id
            FROM dashboard_turn_candidates_current c
            JOIN sources s ON s.source_id = c.source_id
            UNION ALL
            SELECT b.generation, c.event_id, c.source_file_generation, s.path,
                   c.ordinal, c.timestamp, s.session_id, c.total_tokens,
                   c.input_tokens, c.cached_input_tokens, c.output_tokens,
                   c.user_prompt_start, c.user_prompt_end, c.assistant_response_start,
                   c.assistant_response_end, c.turn_index, c.session_calls,
                   c.request_count, c.low_hit_count, c.zero_hit_count, c.source_id
            FROM dashboard_turn_candidates_current c
            JOIN sources s ON s.source_id = c.source_id
            JOIN active_building_generation b
            WHERE NOT EXISTS (
                    SELECT 1 FROM pending_dashboard_turn_candidates p
                    WHERE p.target_generation = b.generation
                      AND p.source_id = c.source_id AND p.ordinal = c.ordinal
              )
              AND NOT EXISTS (
                    SELECT 1 FROM pending_dashboard_turn_tombstones t
                    WHERE t.target_generation = b.generation
                      AND t.source_id = c.source_id AND t.ordinal = c.ordinal
              )
            UNION ALL
            SELECT p.target_generation, p.event_id, p.source_file_generation, s.path,
                   p.ordinal, p.timestamp, s.session_id, p.total_tokens,
                   p.input_tokens, p.cached_input_tokens, p.output_tokens,
                   p.user_prompt_start, p.user_prompt_end, p.assistant_response_start,
                   p.assistant_response_end, p.turn_index, p.session_calls,
                   p.request_count, p.low_hit_count, p.zero_hit_count, p.source_id
            FROM pending_dashboard_turn_candidates p
            JOIN sources s ON s.source_id = p.source_id
            JOIN active_building_generation b ON b.generation = p.target_generation;
            "#,
        )
        .map_err(|error| format!("无法重建轮次候选兼容视图：{error}"))?;

    connection
        .execute_batch(
            r#"
            CREATE TRIGGER IF NOT EXISTS pending_sources_schema11_tombstone_insert
            AFTER INSERT ON pending_sources
            WHEN NEW.mode = 'tombstone' BEGIN
                DELETE FROM pending_event_rows WHERE source_id = NEW.source_id;
                DELETE FROM pending_fingerprints WHERE source_id = NEW.source_id;
                DELETE FROM pending_chunks WHERE source_id = NEW.source_id;
                DELETE FROM pending_enrichment WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_source_totals WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_source_5m WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_turn_candidates WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_turn_tombstones WHERE source_id = NEW.source_id;
            END;
            CREATE TRIGGER IF NOT EXISTS pending_sources_schema11_tombstone_update
            AFTER UPDATE OF mode ON pending_sources
            WHEN NEW.mode = 'tombstone' BEGIN
                DELETE FROM pending_event_rows WHERE source_id = NEW.source_id;
                DELETE FROM pending_fingerprints WHERE source_id = NEW.source_id;
                DELETE FROM pending_chunks WHERE source_id = NEW.source_id;
                DELETE FROM pending_enrichment WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_source_totals WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_source_5m WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_turn_candidates WHERE source_id = NEW.source_id;
                DELETE FROM pending_dashboard_turn_tombstones WHERE source_id = NEW.source_id;
            END;

            -- The compatibility views are used by bounded legacy helpers
            -- while a generation is being migrated to the physical pending
            -- tables. Reject any attempt to address the published layer
            -- during an active build instead of silently mutating lastGood.
            CREATE TRIGGER IF NOT EXISTS files_schema11_reject_current_delete
            INSTEAD OF DELETE ON files
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current file delete blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS events_schema11_reject_current_insert
            INSTEAD OF INSERT ON events
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE NEW.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current event insert blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS events_schema11_reject_current_delete
            INSTEAD OF DELETE ON events
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current event delete blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS file_fingerprints_schema11_reject_current_insert
            INSTEAD OF INSERT ON file_fingerprints
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE NEW.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current fingerprint insert blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS file_fingerprints_schema11_reject_current_delete
            INSTEAD OF DELETE ON file_fingerprints
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current fingerprint delete blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS file_chunks_schema11_reject_current_insert
            INSTEAD OF INSERT ON file_chunks
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE NEW.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current chunk insert blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS file_chunks_schema11_reject_current_delete
            INSTEAD OF DELETE ON file_chunks
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current chunk delete blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS event_enrichment_schema11_reject_current_insert
            INSTEAD OF INSERT ON event_enrichment_sources
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE NEW.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current enrichment insert blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS event_enrichment_schema11_reject_current_update
            INSTEAD OF UPDATE ON event_enrichment_sources
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current enrichment update blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS event_enrichment_schema11_reject_current_delete
            INSTEAD OF DELETE ON event_enrichment_sources
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current enrichment delete blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_file_totals_schema11_reject_current_insert
            INSTEAD OF INSERT ON dashboard_file_totals
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE NEW.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current file total insert blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_file_totals_schema11_reject_current_delete
            INSTEAD OF DELETE ON dashboard_file_totals
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current file total delete blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_file_5m_schema11_reject_current_insert
            INSTEAD OF INSERT ON dashboard_file_5m
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE NEW.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current file bucket insert blocked during building generation');
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_file_5m_schema11_reject_current_delete
            INSTEAD OF DELETE ON dashboard_file_5m
            WHEN EXISTS(SELECT 1 FROM active_building_generation b
                        WHERE OLD.file_generation <> b.generation) BEGIN
                SELECT RAISE(ABORT, 'schema11 current file bucket delete blocked during building generation');
            END;

            CREATE TRIGGER IF NOT EXISTS files_schema11_insert
            INSTEAD OF INSERT ON files BEGIN
                SELECT CASE WHEN NEW.generation <> COALESCE(
                    (SELECT generation FROM active_building_generation), -1)
                    THEN RAISE(ABORT, 'schema11 file writes require the active building generation')
                END;
                INSERT OR IGNORE INTO sources(
                    source_id, path, session_id, deleted, last_seen_generation
                ) VALUES (
                    COALESCE(NULLIF(NEW.source_id, 0),
                        (SELECT COALESCE(MAX(source_id), 0) + 1 FROM sources)),
                    NEW.path, COALESCE(NEW.session_id, ''), 1, 0
                );
                SELECT CASE WHEN COALESCE(NEW.session_id, '') <> ''
                    AND (SELECT session_id FROM sources WHERE path = NEW.path) <> ''
                    AND (SELECT session_id FROM sources WHERE path = NEW.path) <> NEW.session_id
                    THEN RAISE(ABORT, 'schema11 source session id changed for one path')
                END;
                UPDATE sources SET session_id = COALESCE(NULLIF(session_id, ''), NEW.session_id, '')
                WHERE path = NEW.path;
                DELETE FROM pending_dashboard_turn_candidates
                WHERE source_id = (SELECT source_id FROM sources WHERE path = NEW.path)
                  AND COALESCE(NEW.deleted, 0) <> 0;
                DELETE FROM pending_dashboard_turn_tombstones
                WHERE source_id = (SELECT source_id FROM sources WHERE path = NEW.path)
                  AND COALESCE(NEW.deleted, 0) <> 0;
                -- Replacing an in-flight delta/full row with a confirmed
                -- tombstone first removes its source-scoped pending children
                -- through the foreign-key cascade. The source row itself is
                -- stable and is never deleted.
                DELETE FROM pending_sources
                WHERE source_id = (SELECT source_id FROM sources WHERE path = NEW.path)
                  AND COALESCE(NEW.deleted, 0) <> 0;
                INSERT INTO pending_sources(
                    source_id, target_generation, mode, deleted, size, modified_ns,
                    prefix_sha256, append_ready, resume_offset, previous_total_tokens,
                    fork_replay_started_ns, fork_replay_active,
                    is_explicit_subagent_fork, last_skipped_fork_replay_token_ns,
                    current_model, current_user_prompt_start, current_user_prompt_end,
                    assistant_response_start, assistant_response_end, audit_chunk_index, accounting_state
                ) VALUES (
                    (SELECT source_id FROM sources WHERE path = NEW.path), NEW.generation,
                    CASE WHEN COALESCE(NEW.deleted, 0) <> 0 THEN 'tombstone' ELSE 'full' END,
                    COALESCE(NEW.deleted, 0), COALESCE(NEW.size, 0),
                    COALESCE(NEW.modified_ns, '0'), COALESCE(NEW.prefix_sha256, X''),
                    COALESCE(NEW.append_ready, 0), NEW.resume_offset,
                    NEW.previous_total_tokens, NEW.fork_replay_started_ns,
                    COALESCE(NEW.fork_replay_active, 0),
                    COALESCE(NEW.is_explicit_subagent_fork, 0),
                    NEW.last_skipped_fork_replay_token_ns, NEW.current_model,
                    NEW.current_user_prompt_start, NEW.current_user_prompt_end,
                    NEW.assistant_response_start, NEW.assistant_response_end,
                    COALESCE(NEW.audit_chunk_index, 0), NEW.accounting_state
                ) ON CONFLICT(source_id) DO UPDATE SET
                    target_generation = excluded.target_generation,
                    mode = CASE
                        WHEN excluded.deleted <> 0 THEN 'tombstone'
                        WHEN pending_sources.mode = 'delta' THEN 'delta'
                        ELSE 'full'
                    END,
                    deleted = excluded.deleted, size = excluded.size,
                    modified_ns = excluded.modified_ns,
                    prefix_sha256 = excluded.prefix_sha256,
                    append_ready = excluded.append_ready,
                    resume_offset = excluded.resume_offset,
                    previous_total_tokens = excluded.previous_total_tokens,
                    fork_replay_started_ns = excluded.fork_replay_started_ns,
                    fork_replay_active = excluded.fork_replay_active,
                    is_explicit_subagent_fork = excluded.is_explicit_subagent_fork,
                    last_skipped_fork_replay_token_ns = excluded.last_skipped_fork_replay_token_ns,
                    current_model = excluded.current_model,
                    current_user_prompt_start = excluded.current_user_prompt_start,
                    current_user_prompt_end = excluded.current_user_prompt_end,
                    assistant_response_start = excluded.assistant_response_start,
                    assistant_response_end = excluded.assistant_response_end,
                    audit_chunk_index = excluded.audit_chunk_index, accounting_state = excluded.accounting_state;
            END;

            CREATE TRIGGER IF NOT EXISTS files_schema11_update_pending
            INSTEAD OF UPDATE ON files
            WHEN EXISTS(
                SELECT 1 FROM metadata b, metadata p
                WHERE b.key = 'building_generation' AND p.key = 'published_generation'
                  AND CAST(b.value AS INTEGER) > CAST(p.value AS INTEGER)
                  AND (OLD.generation = CAST(b.value AS INTEGER)
                       OR OLD.generation = (SELECT last_seen_generation FROM sources
                                            WHERE source_id = OLD.source_id))
            ) BEGIN
                INSERT INTO pending_sources(
                    source_id, target_generation, mode, deleted, size, modified_ns,
                    prefix_sha256, append_ready, resume_offset, previous_total_tokens,
                    fork_replay_started_ns, fork_replay_active,
                    is_explicit_subagent_fork, last_skipped_fork_replay_token_ns,
                    current_model, current_user_prompt_start, current_user_prompt_end,
                    assistant_response_start, assistant_response_end, audit_chunk_index, accounting_state
                ) VALUES (
                    OLD.source_id,
                    (SELECT generation FROM active_building_generation),
                    CASE WHEN COALESCE(NEW.deleted, 0) <> 0 THEN 'tombstone'
                         ELSE COALESCE((SELECT mode FROM pending_sources
                                        WHERE source_id = OLD.source_id), 'delta') END,
                    COALESCE(NEW.deleted, 0), NEW.size, NEW.modified_ns,
                    NEW.prefix_sha256, NEW.append_ready, NEW.resume_offset,
                    NEW.previous_total_tokens, NEW.fork_replay_started_ns,
                    NEW.fork_replay_active, NEW.is_explicit_subagent_fork,
                    NEW.last_skipped_fork_replay_token_ns, NEW.current_model,
                    NEW.current_user_prompt_start, NEW.current_user_prompt_end,
                    NEW.assistant_response_start, NEW.assistant_response_end,
                    NEW.audit_chunk_index, NEW.accounting_state
                ) ON CONFLICT(source_id) DO UPDATE SET
                    target_generation = excluded.target_generation,
                    mode = excluded.mode, deleted = excluded.deleted, size = excluded.size,
                    modified_ns = excluded.modified_ns,
                    prefix_sha256 = excluded.prefix_sha256,
                    append_ready = excluded.append_ready,
                    resume_offset = excluded.resume_offset,
                    previous_total_tokens = excluded.previous_total_tokens,
                    fork_replay_started_ns = excluded.fork_replay_started_ns,
                    fork_replay_active = excluded.fork_replay_active,
                    is_explicit_subagent_fork = excluded.is_explicit_subagent_fork,
                    last_skipped_fork_replay_token_ns = excluded.last_skipped_fork_replay_token_ns,
                    current_model = excluded.current_model,
                    current_user_prompt_start = excluded.current_user_prompt_start,
                    current_user_prompt_end = excluded.current_user_prompt_end,
                    assistant_response_start = excluded.assistant_response_start,
                    assistant_response_end = excluded.assistant_response_end,
                    audit_chunk_index = excluded.audit_chunk_index, accounting_state = excluded.accounting_state;
            END;
            CREATE TRIGGER IF NOT EXISTS files_schema11_update_current
            INSTEAD OF UPDATE ON files
            WHEN NOT EXISTS(
                SELECT 1 FROM metadata b, metadata p
                WHERE b.key = 'building_generation' AND p.key = 'published_generation'
                  AND CAST(b.value AS INTEGER) > CAST(p.value AS INTEGER)
            ) BEGIN
                UPDATE sources SET
                    path = NEW.path, session_id = NEW.session_id, deleted = NEW.deleted,
                    last_seen_generation = NEW.generation, size = NEW.size,
                    modified_ns = NEW.modified_ns, prefix_sha256 = NEW.prefix_sha256,
                    append_ready = NEW.append_ready, resume_offset = NEW.resume_offset,
                    previous_total_tokens = NEW.previous_total_tokens,
                    fork_replay_started_ns = NEW.fork_replay_started_ns,
                    fork_replay_active = NEW.fork_replay_active,
                    is_explicit_subagent_fork = NEW.is_explicit_subagent_fork,
                    last_skipped_fork_replay_token_ns = NEW.last_skipped_fork_replay_token_ns,
                    current_model = NEW.current_model,
                    current_user_prompt_start = NEW.current_user_prompt_start,
                    current_user_prompt_end = NEW.current_user_prompt_end,
                    assistant_response_start = NEW.assistant_response_start,
                    assistant_response_end = NEW.assistant_response_end,
                    audit_chunk_index = NEW.audit_chunk_index, accounting_state = NEW.accounting_state
                WHERE source_id = OLD.source_id;
            END;
            CREATE TRIGGER IF NOT EXISTS files_schema11_delete_pending
            INSTEAD OF DELETE ON files
            WHEN OLD.generation = COALESCE(
                (SELECT target_generation FROM pending_sources
                 WHERE source_id = OLD.source_id), -1)
            BEGIN
                DELETE FROM pending_sources WHERE source_id = OLD.source_id;
            END;
            CREATE TRIGGER IF NOT EXISTS files_schema11_delete_current
            INSTEAD OF DELETE ON files
            WHEN OLD.generation = (SELECT last_seen_generation FROM sources
                                   WHERE source_id = OLD.source_id)
             AND NOT EXISTS(SELECT 1 FROM pending_sources WHERE source_id = OLD.source_id)
             AND NOT EXISTS(SELECT 1 FROM active_building_generation)
            BEGIN
                DELETE FROM sources WHERE source_id = OLD.source_id;
            END;

            CREATE TRIGGER IF NOT EXISTS events_schema11_insert
            INSTEAD OF INSERT ON events BEGIN
                SELECT CASE WHEN NOT EXISTS(
                    SELECT 1 FROM sources s WHERE s.source_id = COALESCE(
                        NULLIF(NEW.source_id, 0),
                        (SELECT source_id FROM sources WHERE path = NEW.file_path))
                ) THEN RAISE(ABORT, 'schema11 event source is missing') END;
                UPDATE metadata SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
                WHERE key = 'event_id_sequence' AND COALESCE(NEW.id, -1) <= 0;
                UPDATE metadata SET value = CAST(NEW.id AS TEXT)
                WHERE key = 'event_id_sequence' AND NEW.id > CAST(value AS INTEGER);
                INSERT INTO pending_event_rows(
                    id, source_id, ordinal, timestamp, tokens, input_tokens,
                    cached_input_tokens, output_tokens, reasoning_output_tokens, model,
                    user_prompt_start, user_prompt_end, assistant_response_start,
                    assistant_response_end, accounting_kind, reported_total_tokens, token_source_offset, legacy_tokens
                ) SELECT
                    CASE WHEN COALESCE(NEW.id, -1) <= 0
                         THEN CAST((SELECT value FROM metadata
                                    WHERE key = 'event_id_sequence') AS INTEGER)
                         ELSE NEW.id END,
                    p.source_id, NEW.ordinal, NEW.timestamp, NEW.tokens, NEW.input_tokens,
                    NEW.cached_input_tokens, NEW.output_tokens,
                    COALESCE(NEW.reasoning_output_tokens, 0), NEW.model,
                    NEW.user_prompt_start, NEW.user_prompt_end,
                    NEW.assistant_response_start, NEW.assistant_response_end, COALESCE(NEW.accounting_kind, 0), NEW.reported_total_tokens, NEW.token_source_offset, NEW.legacy_tokens
                FROM pending_sources p JOIN sources s ON s.source_id = p.source_id
                WHERE s.path = NEW.file_path AND p.target_generation = NEW.file_generation
                  AND p.mode <> 'tombstone';
                INSERT INTO event_rows(
                    id, source_id, ordinal, timestamp, tokens, input_tokens,
                    cached_input_tokens, output_tokens, reasoning_output_tokens, model,
                    user_prompt_start, user_prompt_end, assistant_response_start,
                    assistant_response_end, accounting_kind, reported_total_tokens, token_source_offset, legacy_tokens
                ) SELECT
                    CASE WHEN COALESCE(NEW.id, -1) <= 0
                         THEN CAST((SELECT value FROM metadata
                                    WHERE key = 'event_id_sequence') AS INTEGER)
                         ELSE NEW.id END,
                    s.source_id, NEW.ordinal, NEW.timestamp, NEW.tokens, NEW.input_tokens,
                    NEW.cached_input_tokens, NEW.output_tokens,
                    COALESCE(NEW.reasoning_output_tokens, 0), NEW.model,
                    NEW.user_prompt_start, NEW.user_prompt_end,
                    NEW.assistant_response_start, NEW.assistant_response_end, COALESCE(NEW.accounting_kind, 0), NEW.reported_total_tokens, NEW.token_source_offset, NEW.legacy_tokens
                FROM sources s
                WHERE s.path = NEW.file_path AND s.last_seen_generation = NEW.file_generation
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation)
                  AND NOT EXISTS(SELECT 1 FROM pending_sources p
                                 WHERE p.source_id = s.source_id
                                   AND p.target_generation = NEW.file_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS events_schema11_delete
            INSTEAD OF DELETE ON events BEGIN
                DELETE FROM pending_event_rows
                WHERE id = OLD.id AND EXISTS(
                    SELECT 1 FROM pending_sources p
                    WHERE p.source_id = OLD.source_id
                      AND p.target_generation = OLD.file_generation
                );
                DELETE FROM event_rows
                WHERE id = OLD.id
                  AND OLD.file_generation = (SELECT last_seen_generation FROM sources
                                             WHERE source_id = OLD.source_id)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;

            CREATE TRIGGER IF NOT EXISTS file_fingerprints_schema11_insert
            INSTEAD OF INSERT ON file_fingerprints BEGIN
                INSERT OR IGNORE INTO pending_fingerprints(source_id, fingerprint)
                SELECT p.source_id, NEW.fingerprint FROM pending_sources p
                JOIN sources s ON s.source_id = p.source_id
                WHERE s.path = NEW.file_path AND p.target_generation = NEW.file_generation
                  AND p.mode <> 'tombstone';
                INSERT OR IGNORE INTO source_fingerprints(source_id, fingerprint)
                SELECT s.source_id, NEW.fingerprint FROM sources s
                WHERE s.path = NEW.file_path AND s.last_seen_generation = NEW.file_generation
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation)
                  AND NOT EXISTS(SELECT 1 FROM pending_sources p
                                 WHERE p.source_id = s.source_id
                                   AND p.target_generation = NEW.file_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS file_fingerprints_schema11_delete
            INSTEAD OF DELETE ON file_fingerprints BEGIN
                DELETE FROM pending_fingerprints
                WHERE source_id = OLD.source_id AND fingerprint = OLD.fingerprint
                  AND EXISTS(SELECT 1 FROM pending_sources p
                             WHERE p.source_id = OLD.source_id
                               AND p.target_generation = OLD.file_generation);
                DELETE FROM source_fingerprints
                WHERE source_id = OLD.source_id AND fingerprint = OLD.fingerprint
                  AND OLD.file_generation = (SELECT last_seen_generation FROM sources
                                             WHERE source_id = OLD.source_id)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;

            CREATE TRIGGER IF NOT EXISTS file_chunks_schema11_insert
            INSTEAD OF INSERT ON file_chunks BEGIN
                INSERT OR REPLACE INTO pending_chunks(source_id, chunk_index, byte_count, sha256)
                SELECT p.source_id, NEW.chunk_index, NEW.byte_count, NEW.sha256
                FROM pending_sources p JOIN sources s ON s.source_id = p.source_id
                WHERE s.path = NEW.file_path AND p.target_generation = NEW.file_generation
                  AND p.mode <> 'tombstone';
                INSERT OR REPLACE INTO source_chunks(source_id, chunk_index, byte_count, sha256)
                SELECT s.source_id, NEW.chunk_index, NEW.byte_count, NEW.sha256
                FROM sources s
                WHERE s.path = NEW.file_path AND s.last_seen_generation = NEW.file_generation
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation)
                  AND NOT EXISTS(SELECT 1 FROM pending_sources p
                                 WHERE p.source_id = s.source_id
                                   AND p.target_generation = NEW.file_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS file_chunks_schema11_delete
            INSTEAD OF DELETE ON file_chunks BEGIN
                DELETE FROM pending_chunks
                WHERE source_id = OLD.source_id AND chunk_index = OLD.chunk_index
                  AND EXISTS(SELECT 1 FROM pending_sources p
                             WHERE p.source_id = OLD.source_id
                               AND p.target_generation = OLD.file_generation);
                DELETE FROM source_chunks
                WHERE source_id = OLD.source_id AND chunk_index = OLD.chunk_index
                  AND OLD.file_generation = (SELECT last_seen_generation FROM sources
                                             WHERE source_id = OLD.source_id)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;

            CREATE TRIGGER IF NOT EXISTS event_enrichment_sources_schema11_insert
            INSTEAD OF INSERT ON event_enrichment_sources BEGIN
                INSERT OR REPLACE INTO pending_enrichment(
                    source_id, revision, parser_revision, completed_size,
                    completed_prefix_sha256
                ) SELECT p.source_id, NEW.revision, NEW.parser_revision,
                         NEW.completed_size, NEW.completed_prefix_sha256
                  FROM pending_sources p JOIN sources s ON s.source_id = p.source_id
                 WHERE s.path = NEW.path AND p.target_generation = NEW.file_generation
                   AND p.mode <> 'tombstone';
                INSERT OR REPLACE INTO source_enrichment(
                    source_id, revision, parser_revision, completed_size,
                    completed_prefix_sha256
                ) SELECT s.source_id, NEW.revision, NEW.parser_revision,
                         NEW.completed_size, NEW.completed_prefix_sha256
                  FROM sources s
                 WHERE s.path = NEW.path AND s.last_seen_generation = NEW.file_generation
                   AND NOT EXISTS(SELECT 1 FROM active_building_generation)
                   AND NOT EXISTS(SELECT 1 FROM pending_sources p
                                  WHERE p.source_id = s.source_id
                                    AND p.target_generation = NEW.file_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS event_enrichment_sources_schema11_update
            INSTEAD OF UPDATE ON event_enrichment_sources BEGIN
                UPDATE pending_enrichment SET
                    revision = NEW.revision, parser_revision = NEW.parser_revision,
                    completed_size = NEW.completed_size,
                    completed_prefix_sha256 = NEW.completed_prefix_sha256
                WHERE source_id = OLD.source_id
                  AND EXISTS(SELECT 1 FROM pending_sources p
                             WHERE p.source_id = OLD.source_id
                               AND p.target_generation = OLD.file_generation);
                UPDATE source_enrichment SET
                    revision = NEW.revision, parser_revision = NEW.parser_revision,
                    completed_size = NEW.completed_size,
                    completed_prefix_sha256 = NEW.completed_prefix_sha256
                WHERE source_id = OLD.source_id
                  AND OLD.file_generation = (SELECT last_seen_generation FROM sources
                                             WHERE source_id = OLD.source_id)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS event_enrichment_sources_schema11_delete
            INSTEAD OF DELETE ON event_enrichment_sources BEGIN
                DELETE FROM pending_enrichment
                WHERE source_id = OLD.source_id
                  AND EXISTS(SELECT 1 FROM pending_sources p
                             WHERE p.source_id = OLD.source_id
                               AND p.target_generation = OLD.file_generation);
                DELETE FROM source_enrichment
                WHERE source_id = OLD.source_id
                  AND OLD.file_generation = (SELECT last_seen_generation FROM sources
                                             WHERE source_id = OLD.source_id)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;

            CREATE TRIGGER IF NOT EXISTS dashboard_file_totals_schema11_insert
            INSTEAD OF INSERT ON dashboard_file_totals BEGIN
                INSERT OR REPLACE INTO pending_dashboard_source_totals(
                    source_id, total_tokens, calls, input_tokens, cached_input_tokens,
                    output_tokens, first_timestamp, last_timestamp
                ) SELECT p.source_id, NEW.total_tokens, NEW.calls, NEW.input_tokens,
                         NEW.cached_input_tokens, NEW.output_tokens,
                         NEW.first_timestamp, NEW.last_timestamp
                  FROM pending_sources p JOIN sources s ON s.source_id = p.source_id
                 WHERE s.path = NEW.file_path AND p.target_generation = NEW.file_generation
                   AND p.mode <> 'tombstone';
                INSERT OR REPLACE INTO dashboard_source_totals(
                    source_id, total_tokens, calls, input_tokens, cached_input_tokens,
                    output_tokens, first_timestamp, last_timestamp
                ) SELECT s.source_id, NEW.total_tokens, NEW.calls, NEW.input_tokens,
                         NEW.cached_input_tokens, NEW.output_tokens,
                         NEW.first_timestamp, NEW.last_timestamp
                  FROM sources s
                 WHERE s.path = NEW.file_path AND s.last_seen_generation = NEW.file_generation
                   AND NOT EXISTS(SELECT 1 FROM active_building_generation)
                   AND NOT EXISTS(SELECT 1 FROM pending_sources p
                                  WHERE p.source_id = s.source_id
                                    AND p.target_generation = NEW.file_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_file_totals_schema11_delete
            INSTEAD OF DELETE ON dashboard_file_totals BEGIN
                DELETE FROM pending_dashboard_source_totals
                WHERE source_id = OLD.source_id
                  AND EXISTS(SELECT 1 FROM pending_sources p
                             WHERE p.source_id = OLD.source_id
                               AND p.target_generation = OLD.file_generation);
                DELETE FROM dashboard_source_totals
                WHERE source_id = OLD.source_id
                  AND OLD.file_generation = (SELECT last_seen_generation FROM sources
                                             WHERE source_id = OLD.source_id)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_file_5m_schema11_insert
            INSTEAD OF INSERT ON dashboard_file_5m BEGIN
                INSERT OR REPLACE INTO pending_dashboard_source_5m(
                    source_id, bucket_start, model_key, model, total_tokens, calls,
                    input_tokens, cached_input_tokens, output_tokens
                ) SELECT p.source_id, NEW.bucket_start, NEW.model_key, NEW.model,
                         NEW.total_tokens, NEW.calls, NEW.input_tokens,
                         NEW.cached_input_tokens, NEW.output_tokens
                  FROM pending_sources p JOIN sources s ON s.source_id = p.source_id
                 WHERE s.path = NEW.file_path AND p.target_generation = NEW.file_generation
                   AND p.mode <> 'tombstone';
                INSERT OR REPLACE INTO dashboard_source_5m(
                    source_id, bucket_start, model_key, model, total_tokens, calls,
                    input_tokens, cached_input_tokens, output_tokens
                ) SELECT s.source_id, NEW.bucket_start, NEW.model_key, NEW.model,
                         NEW.total_tokens, NEW.calls, NEW.input_tokens,
                         NEW.cached_input_tokens, NEW.output_tokens
                  FROM sources s
                 WHERE s.path = NEW.file_path AND s.last_seen_generation = NEW.file_generation
                   AND NOT EXISTS(SELECT 1 FROM active_building_generation)
                   AND NOT EXISTS(SELECT 1 FROM pending_sources p
                                  WHERE p.source_id = s.source_id
                                    AND p.target_generation = NEW.file_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_file_5m_schema11_delete
            INSTEAD OF DELETE ON dashboard_file_5m BEGIN
                DELETE FROM pending_dashboard_source_5m
                WHERE source_id = OLD.source_id AND bucket_start = OLD.bucket_start
                  AND model_key = OLD.model_key
                  AND EXISTS(SELECT 1 FROM pending_sources p
                             WHERE p.source_id = OLD.source_id
                               AND p.target_generation = OLD.file_generation);
                DELETE FROM dashboard_source_5m
                WHERE source_id = OLD.source_id AND bucket_start = OLD.bucket_start
                  AND model_key = OLD.model_key
                  AND OLD.file_generation = (SELECT last_seen_generation FROM sources
                                             WHERE source_id = OLD.source_id)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;

            CREATE TRIGGER IF NOT EXISTS dashboard_5m_schema11_delete
            INSTEAD OF DELETE ON dashboard_5m BEGIN
                DELETE FROM pending_dashboard_5m
                WHERE target_generation = OLD.file_generation
                  AND bucket_start = OLD.bucket_start AND model_key = OLD.model_key;
                INSERT OR IGNORE INTO pending_dashboard_5m_tombstones(
                    target_generation, bucket_start, model_key
                ) SELECT OLD.file_generation, OLD.bucket_start, OLD.model_key
                  WHERE OLD.file_generation = COALESCE(
                        (SELECT generation FROM active_building_generation), -1);
                DELETE FROM dashboard_5m_current
                WHERE bucket_start = OLD.bucket_start AND model_key = OLD.model_key
                  AND OLD.file_generation = COALESCE(
                        (SELECT CAST(value AS INTEGER) FROM metadata
                         WHERE key = 'published_generation'), 0)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_5m_schema11_insert
            INSTEAD OF INSERT ON dashboard_5m BEGIN
                INSERT OR REPLACE INTO pending_dashboard_5m(
                    target_generation, bucket_start, model_key, model, total_tokens,
                    calls, input_tokens, cached_input_tokens, output_tokens
                ) SELECT NEW.file_generation, NEW.bucket_start, NEW.model_key, NEW.model,
                         NEW.total_tokens, NEW.calls, NEW.input_tokens,
                         NEW.cached_input_tokens, NEW.output_tokens
                  WHERE NEW.file_generation = COALESCE(
                        (SELECT generation FROM active_building_generation), -1);
                DELETE FROM pending_dashboard_5m_tombstones
                WHERE target_generation = NEW.file_generation
                  AND bucket_start = NEW.bucket_start AND model_key = NEW.model_key;
                INSERT OR REPLACE INTO dashboard_5m_current(
                    bucket_start, model_key, model, total_tokens, calls,
                    input_tokens, cached_input_tokens, output_tokens
                ) SELECT NEW.bucket_start, NEW.model_key, NEW.model, NEW.total_tokens,
                         NEW.calls, NEW.input_tokens, NEW.cached_input_tokens,
                         NEW.output_tokens
                  WHERE NEW.file_generation = COALESCE(
                        (SELECT CAST(value AS INTEGER) FROM metadata
                         WHERE key = 'published_generation'), 0)
                    AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;

            CREATE TRIGGER IF NOT EXISTS dashboard_turn_candidates_schema11_delete
            INSTEAD OF DELETE ON dashboard_turn_candidates BEGIN
                DELETE FROM pending_dashboard_turn_candidates
                WHERE target_generation = OLD.aggregate_generation
                  AND source_id = OLD.source_id AND ordinal = OLD.ordinal;
                INSERT OR IGNORE INTO pending_dashboard_turn_tombstones(
                    target_generation, source_id, ordinal
                ) SELECT OLD.aggregate_generation, OLD.source_id, OLD.ordinal
                  WHERE OLD.aggregate_generation = COALESCE(
                        (SELECT generation FROM active_building_generation), -1);
                DELETE FROM dashboard_turn_candidates_current
                WHERE source_id = OLD.source_id AND ordinal = OLD.ordinal
                  AND OLD.aggregate_generation = COALESCE(
                        (SELECT CAST(value AS INTEGER) FROM metadata
                         WHERE key = 'published_generation'), 0)
                  AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;
            CREATE TRIGGER IF NOT EXISTS dashboard_turn_candidates_schema11_insert
            INSTEAD OF INSERT ON dashboard_turn_candidates BEGIN
                INSERT OR REPLACE INTO pending_dashboard_turn_candidates(
                    target_generation, source_id, ordinal, event_id,
                    source_file_generation, timestamp, total_tokens, input_tokens,
                    cached_input_tokens, output_tokens, user_prompt_start,
                    user_prompt_end, assistant_response_start, assistant_response_end,
                    turn_index, session_calls, request_count, low_hit_count,
                    zero_hit_count
                ) SELECT NEW.aggregate_generation,
                         COALESCE(NULLIF(NEW.source_id, 0),
                                  (SELECT source_id FROM sources WHERE path = NEW.file_path)),
                         NEW.ordinal, NEW.event_id, NEW.source_file_generation,
                         NEW.timestamp, NEW.total_tokens, NEW.input_tokens,
                         NEW.cached_input_tokens, NEW.output_tokens,
                         NEW.user_prompt_start, NEW.user_prompt_end,
                         NEW.assistant_response_start, NEW.assistant_response_end,
                         NEW.turn_index, NEW.session_calls,
                         COALESCE(NEW.request_count, 0),
                         COALESCE(NEW.low_hit_count, 0),
                         COALESCE(NEW.zero_hit_count, 0)
                  WHERE NEW.aggregate_generation = COALESCE(
                        (SELECT generation FROM active_building_generation), -1);
                DELETE FROM pending_dashboard_turn_tombstones
                WHERE target_generation = NEW.aggregate_generation
                  AND source_id = COALESCE(NULLIF(NEW.source_id, 0),
                        (SELECT source_id FROM sources WHERE path = NEW.file_path))
                  AND ordinal = NEW.ordinal;
                INSERT OR REPLACE INTO dashboard_turn_candidates_current(
                    source_id, ordinal, event_id, source_file_generation,
                    timestamp, total_tokens, input_tokens, cached_input_tokens,
                    output_tokens, user_prompt_start, user_prompt_end,
                    assistant_response_start, assistant_response_end,
                    turn_index, session_calls, request_count, low_hit_count,
                    zero_hit_count
                ) SELECT
                    COALESCE(NULLIF(NEW.source_id, 0),
                             (SELECT source_id FROM sources WHERE path = NEW.file_path)),
                    NEW.ordinal, NEW.event_id, NEW.source_file_generation,
                    NEW.timestamp, NEW.total_tokens, NEW.input_tokens,
                    NEW.cached_input_tokens, NEW.output_tokens,
                    NEW.user_prompt_start, NEW.user_prompt_end,
                    NEW.assistant_response_start, NEW.assistant_response_end,
                    NEW.turn_index, NEW.session_calls,
                    COALESCE(NEW.request_count, 0),
                    COALESCE(NEW.low_hit_count, 0),
                    COALESCE(NEW.zero_hit_count, 0)
                  WHERE NEW.aggregate_generation = COALESCE(
                        (SELECT CAST(value AS INTEGER) FROM metadata
                         WHERE key = 'published_generation'), 0)
                    AND NOT EXISTS(SELECT 1 FROM active_building_generation);
            END;
            "#,
        )
        .map_err(|error| format!("无法初始化 schema 11 精确 token 兼容视图写入触发器：{error}"))
}

pub(super) fn initialize_legacy_index_schema(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS files (
                generation INTEGER NOT NULL,
                path TEXT NOT NULL,
                deleted INTEGER NOT NULL,
                session_id TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_ns TEXT NOT NULL,
                prefix_sha256 BLOB NOT NULL,
                append_ready INTEGER NOT NULL DEFAULT 0,
                resume_offset INTEGER,
                previous_total_tokens INTEGER,
                fork_replay_started_ns TEXT,
                fork_replay_active INTEGER NOT NULL DEFAULT 0,
                is_explicit_subagent_fork INTEGER NOT NULL DEFAULT 0,
                last_skipped_fork_replay_token_ns TEXT,
                current_model TEXT,
                current_user_prompt_start INTEGER,
                current_user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                audit_chunk_index INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(generation, path)
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY,
                file_generation INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                session_id TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_output_tokens INTEGER,
                model TEXT,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                UNIQUE(file_generation, file_path, ordinal),
                FOREIGN KEY(file_generation, file_path)
                    REFERENCES files(generation, path)
                    ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS files_path_generation_idx
                ON files(path, generation DESC);
            CREATE INDEX IF NOT EXISTS events_timestamp_idx
                ON events(timestamp);
            -- The status-bar summary joins events to the small published-files
            -- selector by generation and canonical path, then reads only
            -- timestamp and tokens.
            CREATE INDEX IF NOT EXISTS events_file_summary_idx
                ON events(file_generation, file_path, timestamp, tokens);
            CREATE INDEX IF NOT EXISTS events_session_idx
                ON events(session_id, timestamp, file_generation, file_path, ordinal);
            CREATE INDEX IF NOT EXISTS events_input_tokens_idx
                ON events(input_tokens, timestamp, file_generation, file_path, ordinal);

            -- Durable per-source receipts for the one-time model/reasoning
            -- enrichment.  A receipt points at the exact file version that
            -- was parsed by the current SessionParser, so an interrupted
            -- upgrade resumes without rereading already committed sources.
            CREATE TABLE IF NOT EXISTS event_enrichment_sources (
                path TEXT PRIMARY KEY,
                revision TEXT NOT NULL,
                parser_revision TEXT NOT NULL,
                file_generation INTEGER NOT NULL,
                completed_size INTEGER NOT NULL,
                completed_prefix_sha256 BLOB NOT NULL,
                FOREIGN KEY(file_generation, path)
                    REFERENCES files(generation, path)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;

            -- Disposable dashboard aggregates. Rows remain versioned by the
            -- owning file generation, so publication is still controlled by
            -- the existing published_files selector and is crash atomic.
            CREATE TABLE IF NOT EXISTS dashboard_file_totals (
                file_generation INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                session_id TEXT NOT NULL,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                first_timestamp INTEGER,
                last_timestamp INTEGER,
                PRIMARY KEY(file_generation, file_path),
                FOREIGN KEY(file_generation, file_path)
                    REFERENCES files(generation, path)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS dashboard_file_5m (
                file_generation INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                bucket_start INTEGER NOT NULL,
                model_key TEXT NOT NULL,
                model TEXT,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(file_generation, file_path, bucket_start, model_key),
                FOREIGN KEY(file_generation, file_path)
                    REFERENCES files(generation, path)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS dashboard_file_5m_time_idx
                ON dashboard_file_5m(bucket_start, file_generation, file_path);

            CREATE TABLE IF NOT EXISTS dashboard_5m (
                file_generation INTEGER NOT NULL,
                bucket_start INTEGER NOT NULL,
                model_key TEXT NOT NULL,
                model TEXT,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(file_generation, bucket_start, model_key)
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS dashboard_turn_candidates (
                aggregate_generation INTEGER NOT NULL,
                event_id INTEGER NOT NULL,
                source_file_generation INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                session_id TEXT NOT NULL,
                total_tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                turn_index INTEGER NOT NULL,
                session_calls INTEGER NOT NULL,
                request_count INTEGER NOT NULL DEFAULT 0,
                low_hit_count INTEGER NOT NULL DEFAULT 0,
                zero_hit_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(aggregate_generation, file_path, ordinal)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS dashboard_turn_candidates_order_idx
                ON dashboard_turn_candidates(
                    aggregate_generation,
                    timestamp,
                    input_tokens,
                    cached_input_tokens
                );

            CREATE INDEX IF NOT EXISTS dashboard_turn_candidates_session_idx
                ON dashboard_turn_candidates(aggregate_generation, session_id);

            CREATE TABLE IF NOT EXISTS attribution_source_buckets (
                provenance_epoch TEXT NOT NULL,
                source_id TEXT NOT NULL,
                bucket_start INTEGER NOT NULL,
                tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                PRIMARY KEY(provenance_epoch, source_id, bucket_start)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS attribution_source_buckets_time_idx
                ON attribution_source_buckets(provenance_epoch, bucket_start);

            CREATE TABLE IF NOT EXISTS file_fingerprints (
                file_generation INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                fingerprint BLOB NOT NULL,
                PRIMARY KEY(file_generation, file_path, fingerprint),
                FOREIGN KEY(file_generation, file_path)
                    REFERENCES files(generation, path)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS file_chunks (
                file_generation INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                byte_count INTEGER NOT NULL,
                sha256 BLOB NOT NULL,
                PRIMARY KEY(file_generation, file_path, chunk_index),
                FOREIGN KEY(file_generation, file_path)
                    REFERENCES files(generation, path)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS session_metadata (
                session_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                updated_at INTEGER
            ) WITHOUT ROWID;

            CREATE VIEW IF NOT EXISTS published_files AS
            WITH latest AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation <= COALESCE(
                    (
                        SELECT CAST(value AS INTEGER)
                        FROM metadata
                        WHERE key = 'published_generation'
                    ),
                    0
                )
                GROUP BY path
            )
            SELECT f.*
            FROM files f
            JOIN latest
              ON latest.path = f.path
             AND latest.generation = f.generation
            WHERE f.deleted = 0;

            CREATE VIEW IF NOT EXISTS published_events AS
            SELECT e.*
            FROM events e
            JOIN published_files f
              ON f.generation = e.file_generation
             AND f.path = e.file_path;
            "#,
        )
        .map_err(|error| format!("无法初始化精确 token 索引结构：{error}"))
}
