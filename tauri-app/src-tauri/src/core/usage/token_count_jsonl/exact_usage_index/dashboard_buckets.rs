//! Time-range dashboard updates without rebuilding the complete source selector.
use super::{params, Connection, Transaction};

const INSTALL_INDEX_SQL: &str = "CREATE INDEX IF NOT EXISTS pending_dashboard_source_5m_time_idx
    ON pending_dashboard_source_5m(bucket_start, source_id)";

pub(super) fn install(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(INSTALL_INDEX_SQL)
        .map_err(|error| format!("无法安装待发布五分钟聚合时间索引：{error}"))
}

// Keep the compatibility view's current/full/delta semantics, including the
// per-source delta SUM (and its overflow checks). Restrict each arm before
// grouping, then resolve only the returned source IDs. Grouping all `files`
// here makes every per-source update scan the complete catalog again.
const INSERT_RANGE_SQL: &str = r#"
INSERT INTO dashboard_5m(
    file_generation, bucket_start, model_key, model,
    total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
)
WITH ranged AS MATERIALIZED (
    SELECT s.last_seen_generation AS file_generation,
           s.path AS file_path, b.bucket_start, b.model_key, b.model,
           b.total_tokens, b.calls, b.input_tokens, b.cached_input_tokens,
           b.output_tokens, b.source_id
    FROM dashboard_source_5m b
    JOIN sources s ON s.source_id = b.source_id
    WHERE b.bucket_start BETWEEN ?2 AND ?3
    UNION ALL
    SELECT p.target_generation, s.path, b.bucket_start, b.model_key, b.model,
           b.total_tokens, b.calls, b.input_tokens, b.cached_input_tokens,
           b.output_tokens, b.source_id
    FROM pending_dashboard_source_5m b
    JOIN pending_sources p ON p.source_id = b.source_id AND p.mode = 'full'
    JOIN sources s ON s.source_id = b.source_id
    JOIN active_building_generation active ON active.generation = p.target_generation
    WHERE b.bucket_start BETWEEN ?2 AND ?3
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
        FROM dashboard_source_5m WHERE bucket_start BETWEEN ?2 AND ?3
        UNION ALL
        SELECT source_id, bucket_start, model_key, model, total_tokens, calls,
               input_tokens, cached_input_tokens, output_tokens
        FROM pending_dashboard_source_5m WHERE bucket_start BETWEEN ?2 AND ?3
    ) parts ON parts.source_id = p.source_id
    WHERE p.mode = 'delta'
    GROUP BY p.target_generation, p.source_id, s.path, parts.bucket_start, parts.model_key
)
SELECT ?1, b.bucket_start, b.model_key, MAX(b.model),
       SUM(b.total_tokens), SUM(b.calls), SUM(b.input_tokens),
       SUM(b.cached_input_tokens), SUM(b.output_tokens)
FROM ranged b
WHERE b.bucket_start BETWEEN ?2 AND ?3
  AND b.file_generation <= ?1
  AND b.file_generation = (
      SELECT MAX(generation) FROM (
          SELECT s.last_seen_generation AS generation FROM sources s
          WHERE s.source_id = b.source_id AND s.last_seen_generation <= ?1
          UNION ALL
          SELECT p.target_generation FROM pending_sources p
          JOIN active_building_generation active ON active.generation = p.target_generation
          WHERE p.source_id = b.source_id AND p.target_generation <= ?1
      )
  )
  AND EXISTS (
      SELECT 1 FROM sources s WHERE s.source_id = b.source_id
        AND s.last_seen_generation = b.file_generation AND s.deleted = 0
      UNION ALL
      SELECT 1 FROM pending_sources p
      JOIN active_building_generation active ON active.generation = p.target_generation
      WHERE p.source_id = b.source_id AND p.target_generation = b.file_generation AND p.deleted = 0
  )
GROUP BY b.bucket_start, b.model_key
"#;

pub(super) fn refresh_range(
    transaction: &Transaction<'_>,
    generation: i64,
    start: i64,
    end: i64,
) -> Result<(), String> {
    transaction
        .execute(
            "DELETE FROM dashboard_5m WHERE file_generation = ?1 AND bucket_start BETWEEN ?2 AND ?3",
            params![generation, start, end],
        )
        .map_err(|error| format!("无法清理全局五分钟聚合范围：{error}"))?;
    transaction
        .execute(INSERT_RANGE_SQL, params![generation, start, end])
        .map(|_| ())
        .map_err(|error| format!("无法更新全局五分钟聚合范围：{error}"))
}

#[cfg(test)]
mod tests;
