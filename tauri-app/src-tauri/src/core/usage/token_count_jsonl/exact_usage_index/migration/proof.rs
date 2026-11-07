//! schema11 migration facts and durable comparison proofs.
//!
//! This module owns only read-only fact generation and comparison. Candidate
//! files, manifests, phase persistence, switching and rollback remain in the
//! parent state machine. Shared row-digest helpers live in store_metadata so
//! ledger protection uses the same encoding without depending on migration.

use super::super::{
    fingerprint_codec, ledger, IndexPreparationTrace,
};
use super::super::connection::Connection;
use super::super::store_metadata::{metadata_i64, metadata_text, schema11_digest_value,
    schema11_finish_digest, schema11_query_digest, table_exists_checked, table_row_count};
use super::super::contracts::{canonicalize_legacy_fingerprint, ATTRIBUTION_LEDGER_EPOCH_KEY,
    ATTRIBUTION_LEDGER_INTEGRITY_KEY, ATTRIBUTION_PROVENANCE_EPOCH_KEY,
    BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY, BUILDING_DASHBOARD_CHANGED_KEY,
    DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY,
    DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
    DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY, DASHBOARD_REVISION_KEY,
    GITHUB_BASE_SCHEMA_VERSION, INDEX_SCHEMA_VERSION, SESSION_CATALOG_SCHEMA_COLUMNS,
};
#[cfg(test)]
use super::super::PREPARATION_FACTS_COUNT;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(in super::super) struct Schema11MigrationFacts {
    source_count: i64,
    event_count: i64,
    fingerprint_count: i64,
    chunk_count: i64,
    enrichment_count: i64,
    catalog_count: i64,
    catalog_size_total: i64,
    aggregate_total: i64,
    aggregate_bucket_total: i64,
    global_aggregate: Schema11UsageFacts,
    turn_aggregate: Schema11UsageFacts,
    attribution_aggregate: Schema11UsageFacts,
    session_metadata_count: i64,
    session_metadata_title_bytes: i64,
    session_metadata_updated_at_total: i64,
    digests: Schema11MigrationDigests,
    pub(in super::super) lineage: Vec<Option<String>>,
    #[serde(default)]
    protected_tables: std::collections::BTreeMap<String,String>,
}

impl Schema11MigrationFacts {
    pub(in super::super) fn preserves(&self, expected: &Self) -> bool {
        let mut actual_base=self.clone(); let mut expected_base=expected.clone();
        actual_base.protected_tables.clear(); expected_base.protected_tables.clear();
        actual_base==expected_base && expected.protected_tables.iter().all(|(table,digest)|self.protected_tables.get(table)==Some(digest))
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
struct Schema11UsageFacts {
    row_count: i64,
    total_tokens: i64,
    calls: i64,
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
struct Schema11MigrationDigests {
    sources: String,
    events: String,
    fingerprints: String,
    chunks: String,
    enrichment: String,
    file_totals: String,
    file_buckets: String,
    global_buckets: String,
    turn_candidates: String,
    attribution: String,
    session_catalog: String,
    session_metadata: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in super::super) struct LegacyGenerationState {
    pub(in super::super) published: i64,
    pub(in super::super) building: Option<i64>,
}

pub(in super::super) fn schema11_lineage(connection: &Connection) -> Result<Vec<Option<String>>, String> {
    [
        "revision",
        DASHBOARD_REVISION_KEY,
        "published_generation",
        "building_generation",
        "building_changed",
        BUILDING_DASHBOARD_CHANGED_KEY,
        BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY,
        DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY,
        DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
        DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY,
        ATTRIBUTION_PROVENANCE_EPOCH_KEY,
        ATTRIBUTION_LEDGER_EPOCH_KEY,
        ATTRIBUTION_LEDGER_INTEGRITY_KEY,
    ]
    .iter()
    .map(|key| metadata_text(connection, key))
    .collect()
}

fn schema11_usage_facts(
    connection: &Connection,
    sql: &str,
    parameters: impl rusqlite::Params,
    context: &str,
) -> Result<Schema11UsageFacts, String> {
    connection
        .query_row(sql, parameters, |row| {
            Ok(Schema11UsageFacts {
                row_count: row.get(0)?,
                total_tokens: row.get(1)?,
                calls: row.get(2)?,
                input_tokens: row.get(3)?,
                cached_input_tokens: row.get(4)?,
                output_tokens: row.get(5)?,
            })
        })
        .map_err(|error| format!("无法统计 schema 11 {context}迁移事实：{error}"))
}

fn schema11_catalog_facts(connection: &Connection) -> Result<(i64, i64), String> {
    if !table_exists_checked(connection, "session_catalog_files")? {
        return Ok((0, 0));
    }
    connection
        .query_row(
            "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM session_catalog_files",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|error| format!("无法统计 schema 11 会话目录迁移事实：{error}"))
}

fn schema11_session_metadata_facts(connection: &Connection) -> Result<(i64, i64, i64), String> {
    if !table_exists_checked(connection, "session_metadata")? {
        return Ok((0, 0, 0));
    }
    connection
        .query_row(
            r#"
            SELECT COUNT(*),
                   COALESCE(SUM(LENGTH(CAST(title AS BLOB))), 0),
                   COALESCE(SUM(COALESCE(updated_at, 0)), 0)
            FROM session_metadata
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(|error| format!("无法统计 schema 11 会话标题迁移事实：{error}"))
}

pub(in super::super) fn schema11_legacy_generation_state(
    connection: &Connection,
) -> Result<LegacyGenerationState, String> {
    let published = metadata_i64(connection, "published_generation")?
        .ok_or_else(|| "旧索引缺少 published_generation；已停止 schema 11 自动迁移".to_string())?;
    if published < 0 {
        return Err("旧索引 published_generation 为负数；已停止 schema 11 自动迁移".into());
    }
    let building = metadata_i64(connection, "building_generation")?;
    if building.is_some_and(|value| value <= published) {
        return Err(
            "旧索引 building_generation 未严格晚于 published_generation；已保留原库".into(),
        );
    }
    let maximum = building.unwrap_or(published);
    for (table, column) in [
        ("files", "generation"),
        ("events", "file_generation"),
        ("file_fingerprints", "file_generation"),
        ("file_chunks", "file_generation"),
        ("event_enrichment_sources", "file_generation"),
        ("dashboard_file_totals", "file_generation"),
        ("dashboard_file_5m", "file_generation"),
        ("dashboard_5m", "file_generation"),
        ("dashboard_turn_candidates", "aggregate_generation"),
        ("dashboard_turn_candidates", "source_file_generation"),
    ] {
        let invalid = connection
            .query_row(
                &format!(
                    "SELECT EXISTS(SELECT 1 FROM {table} WHERE {column} < 0 OR {column} > ?1)"
                ),
                params![maximum],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| {
                format!("无法验证旧索引 {table}.{column} 的 generation 边界：{error}")
            })?;
        if invalid {
            return Err(format!(
                "旧索引 {table}.{column} 存在 published/building 之外的代次；已停止自动迁移并保留原库"
            ));
        }
    }
    if let Some(aggregate_generation) =
        metadata_i64(connection, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?
    {
        if aggregate_generation < 0 || aggregate_generation > published {
            return Err("旧索引 dashboard aggregate generation 超出已发布边界；已保留原库".into());
        }
    }
    Ok(LegacyGenerationState {
        published,
        building,
    })
}

fn schema11_fingerprint_digest(
    connection: &Connection,
    sql: &str,
    parameters: impl rusqlite::Params,
    canonical_only: bool,
) -> Result<String, String> {
    let mut statement = connection
        .prepare(sql)
        .map_err(|error| format!("无法准备 schema 11 指纹逐行对账：{error}"))?;
    let mut rows = statement
        .query(parameters)
        .map_err(|error| format!("无法读取 schema 11 指纹逐行对账：{error}"))?;
    let mut hasher = Sha256::new();
    hasher.update(b"codex-token-bar-schema11-fingerprint-digest-v2");
    let mut current_source: Option<(i64, String)> = None;
    let mut canonical_fingerprints = Vec::<Vec<u8>>::new();
    while let Some(row) = rows
        .next()
        .map_err(|error| format!("无法遍历 schema 11 指纹逐行对账：{error}"))?
    {
        let generation = row
            .get::<_, i64>(0)
            .map_err(|error| format!("无法解码 schema 11 指纹代次：{error}"))?;
        let path = row
            .get::<_, String>(1)
            .map_err(|error| format!("无法解码 schema 11 指纹路径：{error}"))?;
        if current_source
            .as_ref()
            .is_some_and(|current| current.0 != generation || current.1 != path)
        {
            let (current_generation, current_path) = current_source
                .take()
                .expect("checked schema 11 fingerprint source");
            schema11_digest_fingerprint_group(
                &mut hasher,
                current_generation,
                &current_path,
                &mut canonical_fingerprints,
            );
        }
        current_source.get_or_insert((generation, path));
        let value = row.get_ref(2)
            .map_err(|error| format!("无法解码 schema 11 指纹值：{error}"))?;
        let canonical = if canonical_only {
            let rusqlite::types::ValueRef::Blob(bytes) = value else {
                return Err("schema 11 候选库仍包含非 BLOB 指纹".into());
            };
            fingerprint_codec::decode(bytes)
                .map_err(|error| format!("schema 11 候选指纹不是 canonical codec：{error}"))?;
            bytes.to_vec()
        } else {
            canonicalize_legacy_fingerprint(value)?
        };
        canonical_fingerprints.push(canonical);
    }
    if let Some((generation, path)) = current_source {
        schema11_digest_fingerprint_group(
            &mut hasher,
            generation,
            &path,
            &mut canonical_fingerprints,
        );
    }
    Ok(schema11_finish_digest(hasher))
}

fn schema11_digest_fingerprint_group(
    hasher: &mut Sha256,
    generation: i64,
    path: &str,
    canonical_fingerprints: &mut Vec<Vec<u8>>,
) {
    // Legacy fixed-width little-endian bytes and canonical unsigned LEB128
    // bytes do not have the same lexicographic order. Sort the canonical form
    // within one source so the digest proves the exact same multiset without
    // retaining the full index in memory.
    canonical_fingerprints.sort_unstable();
    for canonical in canonical_fingerprints.drain(..) {
        hasher.update([0xff]);
        schema11_digest_value(hasher, rusqlite::types::ValueRef::Integer(generation));
        schema11_digest_value(hasher, rusqlite::types::ValueRef::Text(path.as_bytes()));
        schema11_digest_value(hasher, rusqlite::types::ValueRef::Blob(&canonical));
    }
}

fn schema11_migration_digests(
    connection: &Connection,
    schema_version: i64,
) -> Result<Schema11MigrationDigests, String> {
    let catalog_columns = SESSION_CATALOG_SCHEMA_COLUMNS.join(", ");
    let session_catalog = if table_exists_checked(connection, "session_catalog_files")? {
        schema11_query_digest(
            connection,
            &format!("SELECT {catalog_columns} FROM session_catalog_files ORDER BY path"),
            [],
            "会话目录",
        )?
    } else {
        schema11_query_digest(connection, "SELECT 1 WHERE false", [], "会话目录")?
    };
    let session_metadata = if table_exists_checked(connection, "session_metadata")? {
        schema11_query_digest(
            connection,
            "SELECT session_id, title, updated_at FROM session_metadata ORDER BY session_id",
            [],
            "会话标题",
        )?
    } else {
        schema11_query_digest(connection, "SELECT 1 WHERE false", [], "会话标题")?
    };
    let attribution = schema11_query_digest(
        connection,
        r#"
        SELECT provenance_epoch, source_id, bucket_start, tokens, calls,
               input_tokens, cached_input_tokens, output_tokens
        FROM attribution_source_buckets
        ORDER BY provenance_epoch, source_id, bucket_start
        "#,
        [],
        "归因台账",
    )?;

    if schema_version == INDEX_SCHEMA_VERSION {
        return Ok(Schema11MigrationDigests {
            sources: schema11_query_digest(
                connection,
                r#"
                SELECT generation, path, deleted, session_id, size, modified_ns,
                       prefix_sha256, append_ready, resume_offset,
                       previous_total_tokens, fork_replay_started_ns,
                       fork_replay_active, is_explicit_subagent_fork,
                       last_skipped_fork_replay_token_ns, current_model,
                       current_user_prompt_start, current_user_prompt_end,
                       assistant_response_start, assistant_response_end,
                       audit_chunk_index
                FROM files f
                WHERE NOT (
                    f.generation = 0 AND f.deleted = 1
                    AND EXISTS(SELECT 1 FROM pending_sources p
                               WHERE p.source_id = f.source_id)
                )
                ORDER BY generation, path
                "#,
                [],
                "来源",
            )?,
            events: schema11_query_digest(
                connection,
                r#"
                SELECT file_generation, file_path, ordinal, timestamp, session_id,
                       tokens, input_tokens, cached_input_tokens, output_tokens,
                       COALESCE(reasoning_output_tokens, 0), model,
                       user_prompt_start, user_prompt_end,
                       assistant_response_start, assistant_response_end
                FROM events ORDER BY file_generation, file_path, ordinal
                "#,
                [],
                "事件",
            )?,
            fingerprints: schema11_fingerprint_digest(
                connection,
                "SELECT file_generation, file_path, fingerprint FROM file_fingerprints ORDER BY file_generation, file_path, fingerprint",
                [],
                true,
            )?,
            chunks: schema11_query_digest(
                connection,
                "SELECT file_generation, file_path, chunk_index, byte_count, sha256 FROM file_chunks ORDER BY file_generation, file_path, chunk_index",
                [],
                "分块",
            )?,
            enrichment: schema11_query_digest(
                connection,
                "SELECT path, revision, parser_revision, completed_size, completed_prefix_sha256 FROM event_enrichment_sources ORDER BY path",
                [],
                "补全收据",
            )?,
            file_totals: schema11_query_digest(
                connection,
                "SELECT file_generation, file_path, session_id, total_tokens, calls, input_tokens, cached_input_tokens, output_tokens, first_timestamp, last_timestamp FROM dashboard_file_totals ORDER BY file_generation, file_path",
                [],
                "单文件聚合",
            )?,
            file_buckets: schema11_query_digest(
                connection,
                "SELECT file_generation, file_path, bucket_start, model_key, model, total_tokens, calls, input_tokens, cached_input_tokens, output_tokens FROM dashboard_file_5m ORDER BY file_generation, file_path, bucket_start, model_key",
                [],
                "单文件分桶",
            )?,
            global_buckets: schema11_query_digest(
                connection,
                "SELECT bucket_start, model_key, model, total_tokens, calls, input_tokens, cached_input_tokens, output_tokens FROM dashboard_5m ORDER BY file_generation, bucket_start, model_key",
                [],
                "全局分桶",
            )?,
            turn_candidates: schema11_query_digest(
                connection,
                "SELECT file_path, ordinal, source_file_generation, timestamp, session_id, total_tokens, input_tokens, cached_input_tokens, output_tokens, user_prompt_start, user_prompt_end, assistant_response_start, assistant_response_end, turn_index, session_calls FROM dashboard_turn_candidates ORDER BY aggregate_generation, file_path, ordinal",
                [],
                "轮次候选",
            )?,
            attribution,
            session_catalog,
            session_metadata,
        });
    }

    let generations = schema11_legacy_generation_state(connection)?;
    let published = generations.published;
    let building = generations.building;
    let selected_cte = r#"
        WITH current_versions AS (
            SELECT path, MAX(generation) AS generation
            FROM files WHERE generation <= ?1 GROUP BY path
        ), selected_versions AS (
            SELECT path, generation FROM current_versions
            UNION
            SELECT path, generation FROM files
            WHERE ?2 IS NOT NULL AND generation = ?2
        )
    "#;
    let aggregate_generation =
        metadata_i64(connection, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?.unwrap_or(published);
    let global_cte = r#"
        WITH current_rows AS (
            SELECT bucket_start, model_key, model, total_tokens, calls,
                   input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_5m WHERE file_generation = ?1
        ), building_rows AS (
            SELECT bucket_start, model_key, model, total_tokens, calls,
                   input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_5m WHERE ?2 IS NOT NULL AND file_generation = ?2
        ), logical_rows AS (
            SELECT * FROM current_rows
            UNION ALL SELECT * FROM building_rows
            UNION ALL SELECT * FROM current_rows
            WHERE ?2 IS NOT NULL AND NOT EXISTS(SELECT 1 FROM building_rows)
        )
    "#;
    let turn_cte = r#"
        WITH current_versions AS (
            SELECT path, MAX(generation) AS generation
            FROM files
            WHERE generation <= COALESCE(
                (SELECT CAST(value AS INTEGER) FROM metadata
                 WHERE key = 'published_generation'), 0
            )
            GROUP BY path
        ), building_versions AS (
            SELECT path, generation FROM files
            WHERE ?2 IS NOT NULL AND generation = ?2
        ), current_rows AS (
            SELECT t.file_path, t.ordinal,
                   COALESCE(v.generation, t.source_file_generation) AS source_file_generation,
                   t.timestamp, t.session_id, t.total_tokens, t.input_tokens,
                   t.cached_input_tokens, t.output_tokens, t.user_prompt_start,
                   t.user_prompt_end, t.assistant_response_start,
                   t.assistant_response_end, t.turn_index, t.session_calls
            FROM dashboard_turn_candidates t
            LEFT JOIN current_versions v ON v.path = t.file_path
            WHERE t.aggregate_generation = ?1
        ), building_rows AS (
            SELECT t.file_path, t.ordinal,
                   COALESCE(b.generation, v.generation, t.source_file_generation)
                       AS source_file_generation,
                   t.timestamp, t.session_id, t.total_tokens, t.input_tokens,
                   t.cached_input_tokens, t.output_tokens, t.user_prompt_start,
                   t.user_prompt_end, t.assistant_response_start,
                   t.assistant_response_end, t.turn_index, t.session_calls
            FROM dashboard_turn_candidates t
            LEFT JOIN building_versions b ON b.path = t.file_path
            LEFT JOIN current_versions v ON v.path = t.file_path
            WHERE ?2 IS NOT NULL AND t.aggregate_generation = ?2
        ), logical_rows AS (
            SELECT * FROM current_rows
            UNION ALL SELECT * FROM building_rows
            UNION ALL SELECT * FROM current_rows
            WHERE ?2 IS NOT NULL AND NOT EXISTS(SELECT 1 FROM building_rows)
        )
    "#;
    Ok(Schema11MigrationDigests {
        sources: schema11_query_digest(
            connection,
            &format!(
                "{selected_cte} SELECT f.generation, f.path, f.deleted, f.session_id, f.size, f.modified_ns, f.prefix_sha256, f.append_ready, f.resume_offset, f.previous_total_tokens, f.fork_replay_started_ns, f.fork_replay_active, f.is_explicit_subagent_fork, f.last_skipped_fork_replay_token_ns, f.current_model, f.current_user_prompt_start, f.current_user_prompt_end, f.assistant_response_start, f.assistant_response_end, f.audit_chunk_index FROM files f JOIN selected_versions v ON v.path = f.path AND v.generation = f.generation ORDER BY f.generation, f.path"
            ),
            params![published, building],
            "旧来源",
        )?,
        events: schema11_query_digest(
            connection,
            &format!(
                "{selected_cte} SELECT e.file_generation, e.file_path, e.ordinal, e.timestamp, e.session_id, e.tokens, e.input_tokens, e.cached_input_tokens, e.output_tokens, COALESCE(e.reasoning_output_tokens, 0), e.model, e.user_prompt_start, e.user_prompt_end, e.assistant_response_start, e.assistant_response_end FROM events e JOIN selected_versions v ON v.path = e.file_path AND v.generation = e.file_generation ORDER BY e.file_generation, e.file_path, e.ordinal"
            ),
            params![published, building],
            "旧事件",
        )?,
        fingerprints: schema11_fingerprint_digest(
            connection,
            &format!(
                "{selected_cte} SELECT f.file_generation, f.file_path, f.fingerprint FROM file_fingerprints f JOIN selected_versions v ON v.path = f.file_path AND v.generation = f.file_generation ORDER BY f.file_generation, f.file_path, f.fingerprint"
            ),
            params![published, building],
            false,
        )?,
        chunks: schema11_query_digest(
            connection,
            &format!(
                "{selected_cte} SELECT c.file_generation, c.file_path, c.chunk_index, c.byte_count, c.sha256 FROM file_chunks c JOIN selected_versions v ON v.path = c.file_path AND v.generation = c.file_generation ORDER BY c.file_generation, c.file_path, c.chunk_index"
            ),
            params![published, building],
            "旧分块",
        )?,
        enrichment: schema11_query_digest(
            connection,
            "SELECT path, revision, parser_revision, completed_size, completed_prefix_sha256 FROM event_enrichment_sources ORDER BY path",
            [],
            "旧补全收据",
        )?,
        file_totals: schema11_query_digest(
            connection,
            &format!(
                "{selected_cte} SELECT t.file_generation, t.file_path, t.session_id, t.total_tokens, t.calls, t.input_tokens, t.cached_input_tokens, t.output_tokens, t.first_timestamp, t.last_timestamp FROM dashboard_file_totals t JOIN selected_versions v ON v.path = t.file_path AND v.generation = t.file_generation ORDER BY t.file_generation, t.file_path"
            ),
            params![published, building],
            "旧单文件聚合",
        )?,
        file_buckets: schema11_query_digest(
            connection,
            &format!(
                "{selected_cte} SELECT t.file_generation, t.file_path, t.bucket_start, t.model_key, t.model, t.total_tokens, t.calls, t.input_tokens, t.cached_input_tokens, t.output_tokens FROM dashboard_file_5m t JOIN selected_versions v ON v.path = t.file_path AND v.generation = t.file_generation ORDER BY t.file_generation, t.file_path, t.bucket_start, t.model_key"
            ),
            params![published, building],
            "旧单文件分桶",
        )?,
        global_buckets: schema11_query_digest(
            connection,
            &format!(
                "{global_cte} SELECT bucket_start, model_key, model, total_tokens, calls, input_tokens, cached_input_tokens, output_tokens FROM logical_rows ORDER BY bucket_start, model_key"
            ),
            params![aggregate_generation, building],
            "旧全局分桶",
        )?,
        turn_candidates: schema11_query_digest(
            connection,
            &format!(
                "{turn_cte} SELECT file_path, ordinal, source_file_generation, timestamp, session_id, total_tokens, input_tokens, cached_input_tokens, output_tokens, user_prompt_start, user_prompt_end, assistant_response_start, assistant_response_end, turn_index, session_calls FROM logical_rows ORDER BY file_path, ordinal"
            ),
            params![aggregate_generation, building],
            "旧轮次候选",
        )?,
        attribution,
        session_catalog,
        session_metadata,
    })
}

pub(in super::super) fn schema11_migration_facts(
    connection: &Connection,
    schema_version: i64,
) -> Result<Schema11MigrationFacts, String> {
    #[cfg(test)]
    PREPARATION_FACTS_COUNT.with(|value| value.set(value.get() + 1));
    let preparation = IndexPreparationTrace::new("migration_digests");
    let digests = schema11_migration_digests(connection, schema_version)?;
    preparation.finish();
    let (catalog_count, catalog_size_total) = schema11_catalog_facts(connection)?;
    let (session_metadata_count, session_metadata_title_bytes, session_metadata_updated_at_total) =
        schema11_session_metadata_facts(connection)?;
    let attribution_aggregate = schema11_usage_facts(
        connection,
        r#"
        SELECT COUNT(*), COALESCE(SUM(tokens), 0), COALESCE(SUM(calls), 0),
               COALESCE(SUM(input_tokens), 0),
               COALESCE(SUM(cached_input_tokens), 0),
               COALESCE(SUM(output_tokens), 0)
        FROM attribution_source_buckets
        "#,
        [],
        "归因台账",
    )?;
    if schema_version == INDEX_SCHEMA_VERSION {
        return Ok(Schema11MigrationFacts {
            source_count: table_row_count(connection, "sources")?,
            event_count: table_row_count(connection, "events")?,
            fingerprint_count: table_row_count(connection, "file_fingerprints")?,
            chunk_count: table_row_count(connection, "file_chunks")?,
            enrichment_count: table_row_count(connection, "event_enrichment_sources")?,
            catalog_count,
            catalog_size_total,
            aggregate_total: connection
                .query_row(
                    "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_file_totals",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| format!("无法统计 schema 11 文件聚合：{error}"))?,
            aggregate_bucket_total: connection
                .query_row(
                    "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_file_5m",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| format!("无法统计 schema 11 分桶聚合：{error}"))?,
            global_aggregate: schema11_usage_facts(
                connection,
                r#"
                SELECT COUNT(*), COALESCE(SUM(total_tokens), 0),
                       COALESCE(SUM(calls), 0), COALESCE(SUM(input_tokens), 0),
                       COALESCE(SUM(cached_input_tokens), 0),
                       COALESCE(SUM(output_tokens), 0)
                FROM dashboard_5m
                "#,
                [],
                "全局分桶",
            )?,
            turn_aggregate: schema11_usage_facts(
                connection,
                r#"
                SELECT COUNT(*), COALESCE(SUM(total_tokens), 0),
                       COUNT(*), COALESCE(SUM(input_tokens), 0),
                       COALESCE(SUM(cached_input_tokens), 0),
                       COALESCE(SUM(output_tokens), 0)
                FROM dashboard_turn_candidates
                "#,
                [],
                "轮次候选",
            )?,
            attribution_aggregate,
            session_metadata_count,
            session_metadata_title_bytes,
            session_metadata_updated_at_total,
            digests,
            lineage: schema11_lineage(connection)?,
            protected_tables: ledger::protected_table_digests(connection)?,
        });
    }
    if !matches!(schema_version, GITHUB_BASE_SCHEMA_VERSION | 10) {
        return Err(format!(
            "无法为不受支持的 schema {schema_version} 生成 schema 11 迁移对账事实"
        ));
    }
    let generations = schema11_legacy_generation_state(connection)?;
    let published = generations.published;
    let building = generations.building;
    let selected_cte = r#"
        WITH current_versions AS (
            SELECT path, MAX(generation) AS generation
            FROM files WHERE generation <= ?1 GROUP BY path
        ), selected_versions AS (
            SELECT path, generation FROM current_versions
            UNION
            SELECT path, generation FROM files
            WHERE ?2 IS NOT NULL AND generation = ?2
        )
    "#;
    let params = params![published, building];
    let source_count = connection
        .query_row(
            &format!("{selected_cte} SELECT COUNT(DISTINCT path) FROM selected_versions"),
            params,
            |row| row.get(0),
        )
        .map_err(|error| format!("无法统计旧 schema 逻辑来源：{error}"))?;
    let event_count = connection
        .query_row(
            &format!(
                "{selected_cte} SELECT COUNT(*) FROM events e JOIN selected_versions v ON v.path = e.file_path AND v.generation = e.file_generation"
            ),
            params![published, building],
            |row| row.get(0),
        )
        .map_err(|error| format!("无法统计旧 schema 逻辑事件：{error}"))?;
    let fingerprint_count = connection
        .query_row(
            &format!(
                "{selected_cte} SELECT COUNT(*) FROM file_fingerprints f JOIN selected_versions v ON v.path = f.file_path AND v.generation = f.file_generation"
            ),
            params![published, building],
            |row| row.get(0),
        )
        .map_err(|error| format!("无法统计旧 schema 逻辑指纹：{error}"))?;
    let chunk_count = connection
        .query_row(
            &format!(
                "{selected_cte} SELECT COUNT(*) FROM file_chunks c JOIN selected_versions v ON v.path = c.file_path AND v.generation = c.file_generation"
            ),
            params![published, building],
            |row| row.get(0),
        )
        .map_err(|error| format!("无法统计旧 schema 逻辑分块：{error}"))?;
    let enrichment_count = table_row_count(connection, "event_enrichment_sources")?;
    let aggregate_total = connection
        .query_row(
            &format!(
                "{selected_cte} SELECT COALESCE(SUM(t.total_tokens), 0) FROM dashboard_file_totals t JOIN selected_versions v ON v.path = t.file_path AND v.generation = t.file_generation"
            ),
            params![published, building],
            |row| row.get(0),
        )
        .map_err(|error| format!("无法统计旧 schema 逻辑文件聚合：{error}"))?;
    let aggregate_bucket_total = connection
        .query_row(
            &format!(
                "{selected_cte} SELECT COALESCE(SUM(t.total_tokens), 0) FROM dashboard_file_5m t JOIN selected_versions v ON v.path = t.file_path AND v.generation = t.file_generation"
            ),
            params![published, building],
            |row| row.get(0),
        )
        .map_err(|error| format!("无法统计旧 schema 逻辑分桶聚合：{error}"))?;
    let aggregate_generation = metadata_i64(connection, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?
        .filter(|value| *value >= 0 && *value <= published)
        .unwrap_or(published);
    let global_aggregate = schema11_usage_facts(
        connection,
        r#"
        WITH current_rows AS (
            SELECT total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_5m WHERE file_generation = ?1
        ), building_rows AS (
            SELECT total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_5m WHERE ?2 IS NOT NULL AND file_generation = ?2
        ), logical_rows AS (
            SELECT * FROM current_rows
            UNION ALL SELECT * FROM building_rows
            UNION ALL SELECT * FROM current_rows
            WHERE ?2 IS NOT NULL AND NOT EXISTS(SELECT 1 FROM building_rows)
        )
        SELECT COUNT(*), COALESCE(SUM(total_tokens), 0), COALESCE(SUM(calls), 0),
               COALESCE(SUM(input_tokens), 0),
               COALESCE(SUM(cached_input_tokens), 0),
               COALESCE(SUM(output_tokens), 0)
        FROM logical_rows
        "#,
        params![aggregate_generation, building],
        "旧全局分桶",
    )?;
    let turn_aggregate = schema11_usage_facts(
        connection,
        r#"
        WITH current_rows AS (
            SELECT total_tokens, input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_turn_candidates WHERE aggregate_generation = ?1
        ), building_rows AS (
            SELECT total_tokens, input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_turn_candidates
            WHERE ?2 IS NOT NULL AND aggregate_generation = ?2
        ), logical_rows AS (
            SELECT * FROM current_rows
            UNION ALL SELECT * FROM building_rows
            UNION ALL SELECT * FROM current_rows
            WHERE ?2 IS NOT NULL AND NOT EXISTS(SELECT 1 FROM building_rows)
        )
        SELECT COUNT(*), COALESCE(SUM(total_tokens), 0), COUNT(*),
               COALESCE(SUM(input_tokens), 0),
               COALESCE(SUM(cached_input_tokens), 0),
               COALESCE(SUM(output_tokens), 0)
        FROM logical_rows
        "#,
        params![aggregate_generation, building],
        "旧轮次候选",
    )?;
    Ok(Schema11MigrationFacts {
        source_count,
        event_count,
        fingerprint_count,
        chunk_count,
        enrichment_count,
        catalog_count,
        catalog_size_total,
        aggregate_total,
        aggregate_bucket_total,
        global_aggregate,
        turn_aggregate,
        attribution_aggregate,
        session_metadata_count,
        session_metadata_title_bytes,
        session_metadata_updated_at_total,
        digests,
        lineage: schema11_lineage(connection)?,
            protected_tables: ledger::protected_table_digests(connection)?,
    })
}

#[cfg(test)]
mod tests;
