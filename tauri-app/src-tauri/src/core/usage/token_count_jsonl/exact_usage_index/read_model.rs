//! Summary and dashboard read models on the original Exact owner.
//!
//! dashboard_data_at owns one deferred snapshot on self.connection. Its TEMP
//! selectors/views, totals, time series, rankings and optional excerpts remain
//! on that same handle until the original commit. No query service opens its
//! own connection. The standalone page reader uses only the registered,
//! published-read-only open and its original anchor/target/page snapshot.
//!
//! This is not a pure-function module: TEMP preparation mutates connection-local
//! state, and permitted excerpt verification can persist physical proofs using
//! a savepoint inside the current snapshot. Published-read-only mode skips it.
//! Aggregate repair and display-watermark transactions belong to projections;
//! this module must not call them to prepare a read.

use super::ExactUsageIndex;
use super::connection::open_published_index_read_only;
use super::contracts::{ExactDashboardData, PublishedDashboardReadMetadata,
    CURRENT_SCHEMA_VERSION, DASHBOARD_AGGREGATE_SCHEMA_VERSION,
    DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY, ATTRIBUTION_PROVENANCE_EPOCH_KEY,
    FIVE_MINUTE_INTERVAL_SECONDS, nonnegative_u64, saturating_u32, source_range_from_columns};
use super::store_metadata::{metadata_i64, metadata_text};
use super::sources::{canonical_codex_home, file_signature_from_handle,
    lightweight_file_signature, resolve_file_within_codex_home, ResolvedSessionFile};
use super::{database_path, excerpt_warning, representations,
    run_after_dashboard_snapshot_hook_for_testing};
use super::super::{history_compression_enabled, SummaryFileContribution,
    TokenUsageSummary, TokenUsageSummarySnapshot};
use super::super::rollout_source;
use super::super::session_parser::{read_event_excerpt_batch, ExactEventSourceOffsets};
use crate::core::{localtime, startup_trace};
use crate::core::time_series_timeline::{aligned_bin_starts, LONG_RECENT_INTERVAL_SECONDS, LONG_RECENT_POINT_COUNT};
use crate::models::{ActivityDay, CacheHitRankingItem, CacheRequestUsage, DashboardStats,
    LocalDataWarning, ModelTokenBreakdown, RecentUsagePoint, RecentUsageSourceContribution,
    SessionCacheUsage, TokenCacheBreakdown, TokenCacheUsage, TurnCacheUsage};
use rusqlite::{params, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, Instant};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};
#[cfg(test)]
use super::PUBLISHED_EVENT_COUNT_CALLS;

const HOURLY_INTERVAL_SECONDS: i64 = 60 * 60;
const SEVEN_DAY_POINT_COUNT: i64 = 30 * 24;
const SIX_HOUR_INTERVAL_SECONDS: i64 = 6 * 60 * 60;
const THIRTY_DAY_POINT_COUNT: i64 = 30 * 4;
const CACHE_USAGE_MIN_INPUT_TOKENS: i64 = 1_000;
const CACHE_USAGE_CANDIDATE_LIMIT: i64 = 40;
// A full-history timestamp range can make SQLite choose hundreds of thousands
// of scattered row reads. Bind one published file at a time so each UNION
// branch can seek the existing source index, without relying on join ordering.
const ACTIVITY_DAYS_SQL: &str = r#"
    SELECT e.timestamp, e.model, e.tokens, e.input_tokens,
           e.cached_input_tokens, e.output_tokens
    FROM main.canonical_usage_events e
    WHERE e.tokens > 0 AND e.timestamp >= ?1 AND e.timestamp < ?2
      AND e.file_generation = ?3 AND e.file_path = ?4
"#;
const FILE_EVENT_COUNT_SQL: &str = r#"
    SELECT COUNT(*)
    FROM main.canonical_usage_events
    WHERE tokens > 0 AND file_generation = ?1 AND file_path = ?2
"#;

/// Reads one page of request-level numeric details for an indexed logical turn.
/// This path opens the existing exact index read-only and never scans source
/// files, synchronizes the index, or runs a schema/aggregate migration.
pub(in super::super) fn read_cache_turn_requests(
    codex_home: &Path,
    turn_id: &str,
    offset: u32,
    limit: u32,
) -> Result<Vec<CacheRequestUsage>, String> {
    let event_id = turn_id
        .rsplit_once('-')
        .and_then(|(_, suffix)| suffix.parse::<i64>().ok())
        .filter(|event_id| *event_id > 0)
        .ok_or_else(|| "缓存排行轮次标识无效".to_string())?;
    let limit = limit.min(101);
    if limit == 0 {
        return Ok(Vec::new());
    }

    let path = database_path(codex_home)?;
    let connection = open_published_index_read_only(&path, StdDuration::from_secs(2)).map_err(|error| {
        format!("无法只读打开精确 token 索引以读取缓存轮次请求：{error}")
    })?.ok_or("精确 token 索引尚不可用，无法读取请求明细")?;
    // The anchor, target and page must describe one published generation.
    let connection = connection.unchecked_transaction()
        .map_err(|error| format!("无法开始缓存轮次请求只读快照：{error}"))?;
    let schema_version = metadata_i64(&connection, "schema_version")?;
    if schema_version != Some(CURRENT_SCHEMA_VERSION) {
        return Err("精确 token 索引版本尚未就绪，无法读取缓存轮次请求".into());
    }
    let aggregate_version = metadata_i64(&connection, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)?;
    if aggregate_version != Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION) {
        return Err("缓存轮次聚合尚未升级完成，无法读取请求明细".into());
    }

    let source_hint: Option<i64> = connection.query_row(
        "SELECT source_id FROM event_rows WHERE id = ?1", [event_id], |row| row.get(0),
    ).optional().map_err(|error| format!("无法定位缓存轮次来源：{error}"))?;
    type Target = (i64, i64, String, String, Option<i64>, Option<i64>);
    let read_target = |hint: Option<i64>| -> Result<Option<Target>, String> {
        let scope = if hint.is_some() { "AND c.source_id = ?3" } else { "" };
        let sql = format!(r#"
            SELECT f.source_id, c.source_file_generation, c.file_path,
                   c.session_id, c.user_prompt_start, c.user_prompt_end
            FROM dashboard_turn_candidates c
            JOIN published_files f ON f.generation = c.source_file_generation
                AND f.path = c.file_path AND f.session_id = c.session_id
            WHERE c.aggregate_generation = (
                SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'
            ) AND c.event_id = ?1
              AND (c.session_id || '-' || CAST(c.timestamp AS TEXT) || '-' || CAST(c.event_id AS TEXT)) = ?2
              {scope}
            LIMIT 1
        "#);
        let decode = |row: &rusqlite::Row<'_>| -> rusqlite::Result<Target> {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?))
        };
        let result = if let Some(source_id) = hint {
            connection.query_row(&sql, params![event_id, turn_id, source_id], decode)
        } else {
            connection.query_row(&sql, params![event_id, turn_id], decode)
        };
        result.optional().map_err(|error| format!("无法读取缓存轮次归属：{error}"))
    };
    let target = read_target(source_hint)?;
    // Retention can remove a raw representative while the turn still owns
    // surviving requests. Its persisted target remains authoritative.
    let target = if target.is_none() && source_hint.is_some() {
        read_target(None)?
    } else { target };
    let Some((source_id, file_generation, file_path, session_id, prompt_start, prompt_end)) = target
        else { return Ok(Vec::new()); };
    let mut statement = connection.prepare(r#"
            SELECT
                e.id,
                e.timestamp,
                e.model,
                e.tokens,
                e.input_tokens,
                e.cached_input_tokens,
                e.output_tokens
            FROM published_events e
            WHERE e.source_id = ?1
              AND e.file_generation = ?2 AND e.file_path = ?3 AND e.session_id = ?4
              AND e.user_prompt_start IS ?5 AND e.user_prompt_end IS ?6
              AND e.tokens > 0
            ORDER BY e.timestamp, e.ordinal, e.id
            LIMIT ?7 OFFSET ?8
            "#,
        )
        .map_err(|error| format!("无法准备缓存轮次请求明细查询：{error}"))?;
    let rows = statement
        .query_map(params![source_id, file_generation, file_path, session_id,
            prompt_start, prompt_end, i64::from(limit), i64::from(offset)], |row| {
            let request_id = row.get::<_, i64>(0)?;
            let timestamp = row.get::<_, i64>(1)?;
            let input_tokens = nonnegative_u64(row.get::<_, i64>(4)?);
            let cached_input_tokens = nonnegative_u64(row.get::<_, i64>(5)?).min(input_tokens);
            Ok(CacheRequestUsage {
                id: request_id.to_string(),
                timestamp: format_rfc3339_unix(timestamp).unwrap_or_default(),
                model: row.get(2)?,
                breakdown: TokenCacheBreakdown {
                    total_tokens: nonnegative_u64(row.get::<_, i64>(3)?),
                    input_tokens,
                    cached_input_tokens,
                    output_tokens: nonnegative_u64(row.get::<_, i64>(6)?),
                    calls: 1,
                },
            })
        })
        .map_err(|error| format!("无法读取缓存轮次请求明细：{error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码缓存轮次请求明细：{error}"))
}

struct IndexedTurnCandidate {
    usage: TurnCacheUsage,
    file_path: PathBuf,
    file_size: u64,
    file_modified_ns: String,
    source_offsets: ExactEventSourceOffsets,
}

#[derive(Clone, Copy, Default)]
struct UsageBinTotals {
    tokens: u64,
    calls: u32,
    input_tokens: u64,
    cached_input_tokens: u64,
    output_tokens: u64,
}

impl UsageBinTotals {
    fn add_breakdown(&mut self, breakdown: UsageBinTotals) {
        self.tokens = self.tokens.saturating_add(breakdown.tokens);
        self.calls = self.calls.saturating_add(breakdown.calls);
        self.input_tokens = self.input_tokens.saturating_add(breakdown.input_tokens);
        self.cached_input_tokens = self
            .cached_input_tokens
            .saturating_add(breakdown.cached_input_tokens);
        self.output_tokens = self.output_tokens.saturating_add(breakdown.output_tokens);
    }

    fn into_breakdown(self) -> TokenCacheBreakdown {
        TokenCacheBreakdown {
            total_tokens: self.tokens,
            input_tokens: self.input_tokens,
            cached_input_tokens: self.cached_input_tokens,
            output_tokens: self.output_tokens,
            calls: self.calls,
        }
    }
}

/// Controls how local-day projections are evaluated. Production dashboard
/// reads use the system IANA rules at each event timestamp; the fixed variant
/// remains for deterministic unit tests and callers that intentionally inject
/// an offset. Neither mode changes the UTC event rows or five-minute buckets.
#[derive(Clone, Copy)]
enum LocalDayMode {
    Fixed(UtcOffset),
    System,
}

impl LocalDayMode {
    fn date_at(self, unix_timestamp: i64) -> Date {
        match self {
            Self::Fixed(offset) => OffsetDateTime::from_unix_timestamp(unix_timestamp)
                .unwrap_or(OffsetDateTime::UNIX_EPOCH)
                .to_offset(offset)
                .date(),
            Self::System => localtime::local_date_at(unix_timestamp),
        }
    }

    fn day_bounds(self, date: Date) -> Result<(i64, i64), String> {
        match self {
            Self::Fixed(offset) => fixed_local_day_bounds(date, offset),
            Self::System => localtime::local_day_bounds(date),
        }
    }
}


impl ExactUsageIndex {
    pub(in super::super) fn published_summary(&self, now: OffsetDateTime) -> Result<TokenUsageSummarySnapshot, String> {
        let tx = self.connection.unchecked_transaction().map_err(|error| error.to_string())?;
        let aggregate = self.dashboard_aggregate_identity()?;
        let checked = aggregate.settled_through.and_then(format_rfc3339_unix).unwrap_or_default();
        let result = TokenUsageSummarySnapshot {
            summary: self.summary_with_system_timezone(now)?,
            unreported_compaction_unix: Some(self.unreported_compaction_unix()?),
            dashboard_revision: self.dashboard_revision()?,
            aggregate_boundary_unix: aggregate.settled_through.unwrap_or(0),
            exact_generation: Some(self.published_generation()?),
            aggregate_schema_version: aggregate.schema_version,
            aggregate_pricing_revision: aggregate.pricing_revision,
            aggregate_exact_generation: aggregate.exact_generation,
            aggregate_published_generation: aggregate.published_generation,
            generated_at: now.format(&Rfc3339).map_err(|error| error.to_string())?,
            checked_at: checked,
            data_updated_at: self.latest_published_source_modified_at()?,
        };
        tx.commit().map_err(|error| error.to_string())?;
        Ok(result)
    }

    pub(in super::super) fn is_empty(&self) -> Result<bool, String> {
        self.connection
            .query_row(
                "SELECT NOT EXISTS(SELECT 1 FROM published_events LIMIT 1)",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("无法检查精确 token 索引：{error}"))
    }

    pub(in super::super) fn summary(
        &self,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
    ) -> Result<TokenUsageSummary, String> {
        self.summary_at(now_utc, LocalDayMode::Fixed(local_offset))
    }

    /// Computes the summary's local-day projection with the system IANA rules
    /// at each event timestamp. Exact event rows and UTC five-minute buckets
    /// remain untouched; only the read-time projection changes.
    pub(in super::super) fn summary_with_system_timezone(
        &self,
        now_utc: OffsetDateTime,
    ) -> Result<TokenUsageSummary, String> {
        self.summary_at(now_utc, LocalDayMode::System)
    }

    /// Owns a fresh deferred snapshot only when the connection is autocommit;
    /// otherwise reuses the caller's transaction. Fresh file identity selection
    /// and checked i64 folding are deliberately separate from contribution reuse.
    fn summary_at(
        &self,
        now_utc: OffsetDateTime,
        local_day_mode: LocalDayMode,
    ) -> Result<TokenUsageSummary, String> {
        let today = local_day_mode.date_at(now_utc.unix_timestamp());
        let (start, end) = local_day_mode.day_bounds(today)?;
        // The UNION-backed event view makes a global published-file join
        // build an automatic index over every event on each unchanged read.
        // Read fresh file identities and bind each source before aggregation;
        // never reuse a contribution map selected only by file generation.
        let snapshot = if self.connection.is_autocommit() {
            Some(self.connection.unchecked_transaction()
                .map_err(|error| format!("无法开始精确摘要读取事务：{error}"))?)
        } else { None };
        let files = self.published_file_generations()?;
        let mut statement = self.connection.prepare(r#"
            SELECT COALESCE(SUM(tokens),0),
                   COALESCE(SUM(CASE WHEN timestamp>=?1 AND timestamp<?2 THEN tokens ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN timestamp>=?1 AND timestamp<?2 THEN 1 ELSE 0 END),0)
            FROM canonical_usage_events
            WHERE tokens>0 AND file_generation=?3 AND file_path=?4
        "#).map_err(|error| format!("无法准备精确摘要来源查询：{error}"))?;
        let (mut total, mut today_tokens, mut today_requests) = (0_i64, 0_i64, 0_i64);
        for (path, generation) in files {
            let (file_total, file_today, file_requests): (i64,i64,i64) = statement
                .query_row(params![start,end,generation,path], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?)))
                .map_err(|error| format!("无法汇总精确 token 用量：{error}"))?;
            // Match SQLite's integer SUM failure instead of silently extending
            // or saturating the old accounting range when folding sources.
            total = total.checked_add(file_total).ok_or("无法汇总精确 token 用量：integer overflow")?;
            today_tokens = today_tokens.checked_add(file_today).ok_or("无法汇总精确 token 用量：integer overflow")?;
            today_requests = today_requests.checked_add(file_requests).ok_or("无法汇总精确 token 用量：integer overflow")?;
        }
        let summary = TokenUsageSummary {
            total_tokens: nonnegative_u64(total),
            today_tokens: nonnegative_u64(today_tokens),
            today_requests: saturating_u32(today_requests),
            today_model_breakdowns: self.model_breakdowns_between(start, end, local_day_mode)?,
        };
        if let Some(snapshot) = snapshot {
            snapshot.commit().map_err(|error| format!("无法结束精确摘要读取事务：{error}"))?;
        }
        Ok(summary)
    }

    /// Builds the lightweight total/today/model projection from per-file
    /// contributions. A missing map uses the indexed per-file reads to seed
    /// it; later Summary owners only re-read files whose
    /// published generation changed.  This deliberately does not touch
    /// dashboard time-series, heatmap, ranking, or aggregate publication
    /// tables.
    /// Owns its existing snapshot and reuses only the caller-supplied file map
    /// under the original generation rules. Do not route summary_at through it.
    pub(in super::super) fn summary_with_file_contributions(
        &self,
        now_utc: OffsetDateTime,
        previous: Option<&HashMap<String, SummaryFileContribution>>,
    ) -> Result<(TokenUsageSummary, HashMap<String, SummaryFileContribution>), String> {
        let snapshot = self.connection.unchecked_transaction()
            .map_err(|error| format!("无法开始轻量摘要读取事务：{error}"))?;
        let today = LocalDayMode::System.date_at(now_utc.unix_timestamp());
        let (start, end) = LocalDayMode::System.day_bounds(today)?;
        let current_files = self.published_file_generations()?;
        let (contributions, recomputed_files, mode) = match previous {
            None => (
                self.summary_file_contributions_full(start, end, &current_files)?,
                current_files.len(),
                "seed",
            ),
            Some(previous) => {
                let mut current = HashMap::with_capacity(current_files.len());
                let mut recomputed = 0_usize;
                for (path, generation) in current_files {
                    let reusable = previous
                        .get(&path)
                        .filter(|contribution| contribution.generation == generation)
                        .cloned();
                    let contribution = if let Some(reusable) = reusable {
                        reusable
                    } else {
                        recomputed = recomputed.saturating_add(1);
                        self.summary_file_contribution(&path, generation, start, end)?
                    };
                    current.insert(path, contribution);
                }
                (current, recomputed, "incremental")
            }
        };
        startup_trace::mark_performance(format!(
            "summary_projection mode={mode} visible_files={} recomputed_files={recomputed_files}",
            contributions.len()
        ));
        let mut summary = summary_from_file_contributions(&contributions);
        summary.today_model_breakdowns = self.model_breakdowns_from_events(start, end)?;
        snapshot.commit().map_err(|error| format!("无法结束轻量摘要读取事务：{error}"))?;
        Ok((summary, contributions))
    }

    pub(in super::super) fn published_event_count(&self) -> Result<u64, String> {
        #[cfg(test)]
        PUBLISHED_EVENT_COUNT_CALLS.with(|count| count.set(count.get() + 1));
        // COUNT over the joined UNION view also materializes every event.
        // Bind the published file identity before each count instead.
        let snapshot = self.connection.unchecked_transaction()
            .map_err(|error| format!("无法开始已发布事件计数事务：{error}"))?;
        let files = self.published_file_generations()?;
        let mut statement = self.connection.prepare(FILE_EVENT_COUNT_SQL)
            .map_err(|error| format!("无法准备已发布事件计数：{error}"))?;
        let mut total = 0_u64;
        for (path, generation) in files {
            let count = statement.query_row(params![generation, path], |row| row.get::<_, i64>(0))
                .map_err(|error| format!("无法统计待回填的仪表盘事件：{error}"))?;
            total = total.saturating_add(nonnegative_u64(count));
        }
        snapshot.commit().map_err(|error| format!("无法结束已发布事件计数事务：{error}"))?;
        Ok(total)
    }

    fn published_file_generations(&self) -> Result<HashMap<String, i64>, String> {
        let mut statement = self
            .connection
            .prepare("SELECT path, generation FROM main.published_files")
            .map_err(|error| format!("无法准备轻量摘要文件代次：{error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(|error| format!("无法读取轻量摘要文件代次：{error}"))?;
        rows.map(|row| row.map_err(|error| format!("无法解码轻量摘要文件代次：{error}")))
            .collect()
    }

    pub(in super::super) fn latest_published_source_modified_at(&self) -> Result<Option<String>, String> {
        let mut statement = self
            .connection
            .prepare("SELECT modified_ns FROM published_files")
            .map_err(|error| format!("无法准备轻量摘要源更新时间：{error}"))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| format!("无法读取轻量摘要源更新时间：{error}"))?;
        let latest = rows
            .filter_map(|row| row.ok())
            .filter_map(|value| value.parse::<u128>().ok())
            .max();
        Ok(latest.and_then(format_rfc3339_nanos))
    }

    fn summary_file_contributions_full(
        &self,
        start: i64,
        end: i64,
        current_files: &HashMap<String, i64>,
    ) -> Result<HashMap<String, SummaryFileContribution>, String> {
        // The events compatibility view is a UNION. A global grouped join
        // materializes every wide event row before filtering published files.
        // Reuse the indexed per-file projection used by later incremental reads.
        let mut contributions = HashMap::with_capacity(current_files.len());
        for (path, generation) in current_files {
            contributions.insert(path.clone(), self.summary_file_contribution(path, *generation, start, end)?);
        }
        Ok(contributions)
    }

    fn summary_file_contribution(
        &self,
        path: &str,
        generation: i64,
        start: i64,
        end: i64,
    ) -> Result<SummaryFileContribution, String> {
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    model,
                    COALESCE(SUM(tokens), 0),
                    COALESCE(SUM(CASE WHEN timestamp >= ?1 AND timestamp < ?2 THEN tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN timestamp >= ?1 AND timestamp < ?2 THEN input_tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN timestamp >= ?1 AND timestamp < ?2 THEN MIN(cached_input_tokens, input_tokens) ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN timestamp >= ?1 AND timestamp < ?2 THEN output_tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN timestamp >= ?1 AND timestamp < ?2 THEN 1 ELSE 0 END), 0)
                FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0)
                WHERE file_generation = ?3 AND file_path = ?4
                GROUP BY model
                "#,
            )
            .map_err(|error| format!("无法准备轻量摘要文件增量：{error}"))?;
        let rows = statement
            .query_map(params![start, end, generation, path], |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            })
            .map_err(|error| format!("无法读取轻量摘要文件增量：{error}"))?;
        let mut contribution = SummaryFileContribution {
            generation,
            ..SummaryFileContribution::default()
        };
        let mut model_breakdowns = Vec::new();
        for row in rows {
            let (model, total, today, input, cached, output, calls) =
                row.map_err(|error| format!("无法解码轻量摘要文件增量：{error}"))?;
            contribution.total_tokens = contribution
                .total_tokens
                .saturating_add(nonnegative_u64(total));
            contribution.today_tokens = contribution
                .today_tokens
                .saturating_add(nonnegative_u64(today));
            contribution.today_requests = contribution
                .today_requests
                .saturating_add(saturating_u32(calls));
            if calls > 0 {
                model_breakdowns.push(ModelTokenBreakdown { event_start_unix: None,
                    model,
                    breakdown: TokenCacheBreakdown {
                        input_tokens: nonnegative_u64(input),
                        cached_input_tokens: nonnegative_u64(cached),
                        output_tokens: nonnegative_u64(output),
                        total_tokens: nonnegative_u64(today),
                        calls: saturating_u32(calls),
                    },
                });
            }
        }
        model_breakdowns.sort_by(|left, right| {
            right
                .breakdown
                .total_tokens
                .cmp(&left.breakdown.total_tokens)
                .then_with(|| left.model.cmp(&right.model))
        });
        contribution.today_model_breakdowns = model_breakdowns;
        Ok(contribution)
    }

    fn model_breakdowns_between(
        &self,
        start: i64,
        end: i64,
        local_day_mode: LocalDayMode,
    ) -> Result<Vec<ModelTokenBreakdown>, String> {
        if matches!(local_day_mode, LocalDayMode::System) {
            return self.model_breakdowns_from_events(start, end);
        }
        let mut statement = self
            .connection
            .prepare(
                r#"
            SELECT
                model,
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(calls), 0), MIN(bucket_start)
            FROM dashboard_5m b
            WHERE b.file_generation = COALESCE(
                (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'),
                0
            )
              AND b.bucket_start >= ?1 AND b.bucket_start < ?2
            GROUP BY model, bucket_start / 86400
            ORDER BY SUM(total_tokens) DESC
            "#,
            )
            .map_err(|error| format!("无法准备今日逐模型 token 汇总：{error}"))?;
        let rows = statement
            .query_map(params![start, end], |row| {
                Ok(ModelTokenBreakdown { event_start_unix: row.get(6)?,
                    model: row.get(0)?,
                    breakdown: TokenCacheBreakdown {
                        input_tokens: nonnegative_u64(row.get::<_, i64>(1)?),
                        cached_input_tokens: nonnegative_u64(row.get::<_, i64>(2)?),
                        output_tokens: nonnegative_u64(row.get::<_, i64>(3)?),
                        total_tokens: nonnegative_u64(row.get::<_, i64>(4)?),
                        calls: saturating_u32(row.get::<_, i64>(5)?),
                    },
                })
            })
            .map_err(|error| format!("无法读取今日逐模型 token 汇总：{error}"))?;
        rows.map(|row| row.map_err(|error| format!("无法解码今日逐模型 token 汇总：{error}")))
            .collect()
    }

    fn model_breakdowns_from_events(
        &self,
        start: i64,
        end: i64,
    ) -> Result<Vec<ModelTokenBreakdown>, String> {
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    e.model,
                    COALESCE(SUM(e.input_tokens), 0),
                    COALESCE(SUM(MIN(e.cached_input_tokens, e.input_tokens)), 0),
                    COALESCE(SUM(e.output_tokens), 0),
                    COALESCE(SUM(e.tokens), 0),
                    COUNT(*), MIN(e.timestamp)
                FROM (SELECT * FROM canonical_usage_events WHERE tokens > 0) e
                JOIN published_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                GROUP BY e.model, e.timestamp / 86400
                ORDER BY SUM(e.tokens) DESC
                "#,
            )
            .map_err(|error| format!("无法准备本地日逐模型 token 汇总：{error}"))?;
        let rows = statement
            .query_map(params![start, end], |row| {
                Ok(ModelTokenBreakdown { event_start_unix: row.get(6)?,
                    model: row.get(0)?,
                    breakdown: TokenCacheBreakdown {
                        input_tokens: nonnegative_u64(row.get::<_, i64>(1)?),
                        cached_input_tokens: nonnegative_u64(row.get::<_, i64>(2)?),
                        output_tokens: nonnegative_u64(row.get::<_, i64>(3)?),
                        total_tokens: nonnegative_u64(row.get::<_, i64>(4)?),
                        calls: saturating_u32(row.get::<_, i64>(5)?),
                    },
                })
            })
            .map_err(|error| format!("无法读取本地日逐模型 token 汇总：{error}"))?;
        rows.map(|row| row.map_err(|error| format!("无法解码本地日逐模型 token 汇总：{error}")))
            .collect()
    }

    pub(in super::super) fn dashboard_data(
        &self,
        codex_home: &Path,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<ExactDashboardData, String> {
        self.dashboard_data_at(
            codex_home,
            now_utc,
            local_offset,
            LocalDayMode::Fixed(local_offset),
            crate::core::quota::cached_seven_day_reset_at(codex_home),
            warnings,
        )
    }

    /// Read the complete dashboard with per-event system IANA local-day
    /// classification. UTC event timestamps and 5-minute aggregate rows are
    /// read-only; a timezone change only misses the disposable local view.
    pub(in super::super) fn dashboard_data_with_system_timezone(
        &self,
        codex_home: &Path,
        now_utc: OffsetDateTime,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<ExactDashboardData, String> {
        self.dashboard_data_at(
            codex_home,
            now_utc,
            localtime::local_offset_at(now_utc.unix_timestamp()),
            LocalDayMode::System,
            crate::core::quota::cached_seven_day_reset_at(codex_home),
            warnings,
        )
    }

    #[cfg(test)]
    pub(in super::super) fn dashboard_data_for_quota_period_for_testing(
        &self, codex_home: &Path, now: OffsetDateTime, reset_at: i64,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<ExactDashboardData, String> {
        self.dashboard_data_at(codex_home, now, UtcOffset::UTC,
            LocalDayMode::Fixed(UtcOffset::UTC), Some(reset_at), warnings)
    }

    fn dashboard_data_at(
        &self,
        codex_home: &Path,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
        local_day_mode: LocalDayMode,
        quota_reset_at: Option<i64>,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<ExactDashboardData, String> {
        let dashboard_started = Instant::now();
        // The small temp published-files selector avoids copying every event,
        // but the view still reads main.events. Keep the complete dashboard in
        // one deferred WAL snapshot so a concurrent publisher cannot make the
        // totals, time series, and rankings observe different generations.
        let snapshot_transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|error| format!("无法开始精确 token 仪表盘读取事务：{error}"))?;
        let published = if self.published_read_only {
            Some(PublishedDashboardReadMetadata { revision: self.dashboard_revision()?,
                aggregate: self.dashboard_aggregate_identity()?, attribution: self.attribution_safety_state()? })
        } else { None };
        let settled_through = match &published {
            Some(metadata) => metadata.aggregate.settled_through.ok_or("已发布旧索引尚无完整图表覆盖证明；已知汇总仍可读取")?
                .min(Self::latest_eligible_aggregate_boundary(now_utc)),
            None => Self::latest_eligible_aggregate_boundary(now_utc),
        };
        let prepare_started = Instant::now();
        self.prepare_dashboard_event_snapshot()?;
        run_after_dashboard_snapshot_hook_for_testing();
        let prepare_snapshot_ms = prepare_started.elapsed().as_millis();

        let activity_started = Instant::now();
        let activity_days = self.activity_days(now_utc, local_day_mode)?;
        let activity_days_ms = activity_started.elapsed().as_millis();

        let stats_started = Instant::now();
        let (stats, summary) = self.stats(&activity_days, now_utc, local_day_mode)?;
        let stats_ms = stats_started.elapsed().as_millis();

        let usage_series_started = Instant::now();
        let (recent_usage_24h, recent_usage_7d, recent_usage_30d) =
            self.usage_series_bundle(now_utc, local_offset, settled_through, quota_reset_at)?;
        let usage_series_ms = usage_series_started.elapsed().as_millis();

        let cache_ranking_started = Instant::now();
        let cache_hit_ranking = self.cache_hit_ranking(local_offset)?;
        let cache_ranking_ms = cache_ranking_started.elapsed().as_millis();

        let cache_usage_started = Instant::now();
        let cache_usage = self.cache_usage(codex_home, warnings, now_utc)?;
        let cache_usage_ms = cache_usage_started.elapsed().as_millis();
        let total_ms = dashboard_started.elapsed().as_millis();
        startup_trace::mark_performance(format_precise_dashboard_phases(
            prepare_snapshot_ms,
            activity_days_ms,
            stats_ms,
            usage_series_ms,
            cache_ranking_ms,
            cache_usage_ms,
            total_ms,
        ));

        let data = ExactDashboardData {
            summary,
            stats,
            activity_days,
            recent_usage_24h,
            recent_usage_7d,
            recent_usage_30d,
            cache_hit_ranking,
            cache_usage,
            settled_through,
            published,
        };
        snapshot_transaction
            .commit()
            .map_err(|error| format!("无法结束精确 token 仪表盘读取事务：{error}"))?;
        Ok(data)
    }

    #[cfg(test)]
    pub(in super::super) fn dashboard_temp_object_types_for_testing(
        &self,
    ) -> Result<HashMap<String, String>, String> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT name, type FROM sqlite_temp_master WHERE name LIKE 'dashboard_%' OR name IN ('published_files','published_events')",
            )
            .map_err(|error| format!("无法检查仪表盘临时对象：{error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|error| format!("无法读取仪表盘临时对象：{error}"))?;
        rows.map(|row| row.map_err(|error| format!("无法解码仪表盘临时对象：{error}")))
            .collect()
    }

    #[cfg(test)]
    pub(in super::super) fn published_event_read_plans_for_testing(
        &self, start: i64, end: i64,
    ) -> Result<(Vec<String>, Vec<String>), String> {
        self.prepare_dashboard_event_snapshot()?;
        let (path, generation) = self.published_file_generations()?.into_iter().next()
            .ok_or("query-plan fixture needs a published file")?;
        let mut activity = self.connection.prepare(&format!("EXPLAIN QUERY PLAN {ACTIVITY_DAYS_SQL}"))
            .map_err(|error| error.to_string())?;
        let activity_plan = activity.query_map(params![start, end, generation, path], |row| row.get::<_, String>(3))
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>().map_err(|error| error.to_string())?;
        let mut count = self.connection.prepare(&format!("EXPLAIN QUERY PLAN {FILE_EVENT_COUNT_SQL}"))
            .map_err(|error| error.to_string())?;
        let count_plan = count.query_map(params![generation, path], |row| row.get::<_, String>(3))
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>().map_err(|error| error.to_string())?;
        Ok((activity_plan, count_plan))
    }

    /// Writes connection-local TEMP objects on self.connection. The dashboard
    /// caller already owns the deferred snapshot; this must not open/commit one.
    fn prepare_dashboard_event_snapshot(&self) -> Result<(), String> {
        self.connection
            .execute_batch(
                r#"
                DROP TABLE IF EXISTS temp.dashboard_session_rows;
                DROP VIEW IF EXISTS temp.published_dashboard_5m;
                DROP VIEW IF EXISTS temp.published_dashboard_file_5m;
                DROP VIEW IF EXISTS temp.published_dashboard_file_totals;
                DROP VIEW IF EXISTS temp.dashboard_snapshot_events;
                DROP TABLE IF EXISTS temp.dashboard_snapshot_files;
                -- Materialize only the small file-generation selector. The old
                -- path copied every published event into a temp table and built
                -- two temp indexes on every dashboard read. On a real 280k-event
                -- index that preparation alone took tens of seconds and could
                -- exhaust temp storage. A temp view keeps all aggregate reads on
                -- the durable main.events indexes without repeating the expensive
                -- published-files grouping.
                CREATE TEMP TABLE dashboard_snapshot_files AS
                SELECT *
                FROM main.published_files;
                CREATE UNIQUE INDEX dashboard_snapshot_files_path_idx
                    ON dashboard_snapshot_files(path);
                CREATE TEMP VIEW dashboard_snapshot_events AS
                SELECT e.*
                FROM main.canonical_usage_events e
                JOIN dashboard_snapshot_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                WHERE e.tokens > 0;

                CREATE TEMP VIEW published_dashboard_file_totals AS
                SELECT t.*
                FROM main.dashboard_file_totals t
                JOIN dashboard_snapshot_files f
                  ON f.generation = t.file_generation
                 AND f.path = t.file_path;

                CREATE TEMP VIEW published_dashboard_5m AS
                SELECT b.*
                FROM main.dashboard_5m b
                WHERE b.file_generation = COALESCE(
                    (
                        SELECT CAST(value AS INTEGER)
                        FROM main.metadata
                        WHERE key = 'published_generation'
                    ),
                    0
                );

                -- `dashboard_5m` is the rolling chart projection. Lifetime
                -- model totals must use the per-file projection, which keeps
                -- all historical buckets and is filtered through the current
                -- published file generation selector.
                CREATE TEMP VIEW published_dashboard_file_5m AS
                SELECT b.*
                FROM main.dashboard_file_5m b
                JOIN dashboard_snapshot_files f
                  ON f.generation = b.file_generation
                 AND f.path = b.file_path;

                -- Events are physically ordered by file generation/path. Fold
                -- them to one small row per file first, then join the published
                -- selector and group the roughly file-count-sized result by
                -- session. Grouping the dashboard_snapshot_events view directly makes
                -- SQLite revisit events once per file and spill every event into
                -- a session GROUP BY temp B-tree on large indexes.
                CREATE TEMP TABLE dashboard_session_rows AS
                WITH session_totals AS (
                    SELECT
                        f.session_id,
                        SUM(t.total_tokens) AS total_tokens,
                        SUM(t.output_tokens) AS output_tokens,
                        MAX(t.last_timestamp) AS updated_at
                    FROM published_dashboard_file_totals t
                    JOIN dashboard_snapshot_files f
                      ON f.generation = t.file_generation
                     AND f.path = t.file_path
                    GROUP BY f.session_id
                ), logical_turns AS (
                    SELECT
                        session_id,
                        COUNT(*) AS calls,
                        SUM(input_tokens) AS input_tokens,
                        SUM(cached_input_tokens) AS cached_tokens
                    FROM dashboard_turn_candidates
                    WHERE aggregate_generation = COALESCE(
                        (
                            SELECT CAST(value AS INTEGER)
                            FROM main.metadata
                            WHERE key = 'published_generation'
                        ),
                        0
                    )
                    GROUP BY session_id
                )
                SELECT
                    s.session_id,
                    COALESCE(t.calls, 0) AS calls,
                    s.total_tokens,
                    COALESCE(t.input_tokens, 0) AS input_tokens,
                    COALESCE(t.cached_tokens, 0) AS cached_tokens,
                    s.output_tokens,
                    COALESCE(m.updated_at, s.updated_at) AS updated_at,
                    s.updated_at AS last_activity_at,
                    COALESCE(
                        NULLIF(TRIM(m.title), ''),
                        '会话 ' || SUBSTR(s.session_id, 1, 8)
                    ) AS title
                FROM session_totals s
                LEFT JOIN logical_turns t ON t.session_id = s.session_id
                LEFT JOIN session_metadata m ON m.session_id = s.session_id;
                "#,
            )
            .map_err(|error| format!("无法建立精确 token 聚合快照：{error}"))
    }

    fn activity_days(
        &self,
        now_utc: OffsetDateTime,
        local_day_mode: LocalDayMode,
    ) -> Result<Vec<ActivityDay>, String> {
        let today = local_day_mode.date_at(now_utc.unix_timestamp());
        let start_day = today - Duration::days(364);
        let (start_unix, _) = local_day_mode.day_bounds(start_day)?;
        let (_, local_end_unix) = local_day_mode.day_bounds(today)?;
        // Exact events are already durable rows. Include the current local
        // day through the requested read instant (rather than the delayed
        // aggregate settlement watermark); the latter only protects UTC
        // five-minute charts from an in-flight bucket.
        let end_unix = local_end_unix.min(now_utc.unix_timestamp().saturating_add(1));
        let mut grouped = HashMap::<Date, UsageBinTotals>::new();
        let mut model_grouped = HashMap::<Date, Vec<ModelTokenBreakdown>>::new();
        let mut statement = self
            .connection
            .prepare(ACTIVITY_DAYS_SQL)
            .map_err(|error| format!("无法准备 365 日精确 token 汇总：{error}"))?;
        // Use the same file selector and WAL snapshot as the other dashboard
        // reads. Binding a file identity avoids compatibility-UNION plans that
        // flatten a CROSS JOIN back into the broad timestamp scan.
        let mut files = self.connection
            .prepare("SELECT path, generation FROM temp.dashboard_snapshot_files")
            .map_err(|error| format!("无法准备 365 日精确 token 文件范围：{error}"))?;
        let file_rows = files.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        }).map_err(|error| format!("无法读取 365 日精确 token 文件范围：{error}"))?;
        for file in file_rows {
            let (path, generation) = file
                .map_err(|error| format!("无法解码 365 日精确 token 文件范围：{error}"))?;
            let rows = statement
                .query_map(params![start_unix, end_unix, generation, path], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                    ))
                })
                .map_err(|error| format!("无法读取 365 日精确 token 汇总：{error}"))?;
            for row in rows {
                let (timestamp, model, tokens, input, cached, output) =
                    row.map_err(|error| format!("无法解码 365 日精确 token 汇总：{error}"))?;
                let date = local_day_mode.date_at(timestamp);
                let totals = UsageBinTotals {
                    tokens: nonnegative_u64(tokens),
                    calls: 1,
                    input_tokens: nonnegative_u64(input),
                    cached_input_tokens: nonnegative_u64(cached).min(nonnegative_u64(input)),
                    output_tokens: nonnegative_u64(output),
                };
                grouped.entry(date).or_default().add_breakdown(totals);
                add_model_usage_breakdown(model_grouped.entry(date).or_default(), model, totals, timestamp);
            }
        }
        Ok((0..365)
            .map(|offset| {
                let day = start_day + Duration::days(offset);
                let date = format_date(day);
                let totals = grouped.remove(&day).unwrap_or_default();
                ActivityDay {
                    model_breakdowns: model_grouped.remove(&day).unwrap_or_default(),
                    date,
                    tokens: totals.tokens,
                    calls: totals.calls,
                    cache_hit_rate: if totals.input_tokens == 0 {
                        0.0
                    } else {
                        (totals.cached_input_tokens as f64 / totals.input_tokens as f64)
                            .clamp(0.0, 1.0)
                    },
                    five_hour_remaining_percent: None,
                    seven_day_remaining_percent: None,
                }
            })
            .collect())
    }

    fn stats(
        &self,
        days: &[ActivityDay],
        now_utc: OffsetDateTime,
        local_day_mode: LocalDayMode,
    ) -> Result<(DashboardStats, TokenUsageSummary), String> {
        let today = local_day_mode.date_at(now_utc.unix_timestamp());
        let (today_start, today_end) = local_day_mode.day_bounds(today)?;
        let row = self
            .connection
            .query_row(
                r#"
                SELECT
                    COALESCE(SUM(total_tokens), 0),
                    COALESCE(SUM(calls), 0),
                    COUNT(DISTINCT session_id),
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(cached_input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    MIN(first_timestamp),
                    COALESCE((
                        SELECT SUM(e.tokens)
                        FROM temp.dashboard_snapshot_events e
                        WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                    ), 0),
                    COALESCE((
                        SELECT COUNT(*)
                        FROM temp.dashboard_snapshot_events e
                        WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                    ), 0)
                FROM published_dashboard_file_totals
                "#,
                params![today_start, today_end],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, Option<i64>>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, i64>(8)?,
                    ))
                },
            )
            .map_err(|error| format!("无法读取精确 token 总览：{error}"))?;
        let peak_thread = self
            .connection
            .query_row(
                r#"
                SELECT COALESCE(MAX(total), 0)
                FROM (
                    SELECT SUM(total_tokens) AS total
                    FROM published_dashboard_file_totals
                    GROUP BY session_id
                )
                "#,
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("无法读取精确 token 会话峰值：{error}"))?;
        let unreported_compaction_unix = self.unreported_compaction_unix()?;
        let mut model_breakdowns = Vec::new();
        let mut model_statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    COALESCE(MAX(model), model_key),
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(cached_input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(total_tokens), 0),
                    COALESCE(SUM(calls), 0), MIN(bucket_start)
                FROM published_dashboard_file_5m
                GROUP BY model_key, bucket_start / 86400
                "#,
            )
            .map_err(|error| format!("无法准备逐模型精确 token 总览：{error}"))?;
        let model_rows = model_statement
            .query_map([], |row| {
                Ok(ModelTokenBreakdown { event_start_unix: row.get(6)?,
                    model: row.get(0)?,
                    breakdown: TokenCacheBreakdown {
                        input_tokens: nonnegative_u64(row.get::<_, i64>(1)?),
                        cached_input_tokens: nonnegative_u64(row.get::<_, i64>(2)?),
                        output_tokens: nonnegative_u64(row.get::<_, i64>(3)?),
                        total_tokens: nonnegative_u64(row.get::<_, i64>(4)?),
                        calls: saturating_u32(row.get::<_, i64>(5)?),
                    },
                })
            })
            .map_err(|error| format!("无法读取逐模型精确 token 总览：{error}"))?;
        for model_row in model_rows {
            model_breakdowns.push(
                model_row.map_err(|error| format!("无法解码逐模型精确 token 总览：{error}"))?,
            );
        }

        let stats = DashboardStats {
            total_tokens: nonnegative_u64(row.0),
            peak_day_tokens: days.iter().map(|day| day.tokens).max().unwrap_or(0),
            peak_thread_tokens: nonnegative_u64(peak_thread),
            current_streak_days: current_streak_days(days, today),
            longest_streak_days: longest_streak_days(days),
            total_calls: saturating_u32(row.1),
            total_threads: saturating_u32(row.2),
            total_input_tokens: nonnegative_u64(row.3),
            total_cached_input_tokens: nonnegative_u64(row.4),
            total_output_tokens: nonnegative_u64(row.5),
            model_breakdowns,
            first_usage_at: row.6.and_then(format_rfc3339_unix),
            unreported_compaction_unix,
        };
        Ok((
            stats,
            TokenUsageSummary {
                total_tokens: nonnegative_u64(row.0),
                today_tokens: nonnegative_u64(row.7),
                today_requests: saturating_u32(row.8),
                today_model_breakdowns: self.model_breakdowns_between(
                    today_start,
                    today_end,
                    local_day_mode,
                )?,
            },
        ))
    }

    /// Retain exact event timestamps for unresolved compaction requests in
    /// the published generation. These rows are explicit unknown-usage
    /// diagnostics and are excluded from normal event totals.
    pub(in super::super) fn unreported_compaction_unix(&self) -> Result<Vec<i64>, String> {
        let mut statement = self.connection.prepare(
            r#"
            WITH unreported AS (
                SELECT e.timestamp
                FROM canonical_usage_events e
                JOIN published_files f
                  ON f.source_id = e.source_id
                 AND f.generation = e.file_generation
                WHERE e.accounting_kind = ?1 AND e.accounting_kind <> 0
                UNION
                SELECT retained.timestamp
                FROM retained_usage_events retained
                JOIN retained_usage_sources history
                  ON history.snapshot_id = retained.snapshot_id
                WHERE retained.accounting_kind = ?1 AND retained.accounting_kind = 4
                  AND NOT EXISTS (
                      SELECT 1
                      FROM event_rows current
                      JOIN sources source
                        ON source.source_id = current.source_id
                       AND source.session_id = history.session_id
                       AND source.path = history.path
                      JOIN usage_ledger_bindings binding
                        ON binding.event_id = current.id
                       AND binding.source_id = current.source_id
                      JOIN retained_usage_fingerprints fingerprint
                        ON fingerprint.snapshot_id = retained.snapshot_id
                       AND fingerprint.value = binding.fingerprint
                      WHERE current.source_id = history.source_id
                        AND current.ordinal = retained.position
                        AND current.timestamp = retained.timestamp
                        AND (retained.token_source_offset IS NULL
                             OR current.token_source_offset = retained.token_source_offset)
                        AND current.accounting_kind = 0
                  )
            )
            SELECT DISTINCT timestamp FROM unreported ORDER BY timestamp
            "#,
        ).map_err(|error| format!("无法准备未报告 compaction 时间诊断：{error}"))?;
        let rows = statement.query_map(
            params![super::accounting::UNREPORTED_COMPACTION],
            |row| row.get::<_, i64>(0),
        ).map_err(|error| format!("无法读取未报告 compaction 时间诊断：{error}"))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("无法解码未报告 compaction 时间诊断：{error}"))
    }

    fn usage_series_bundle(
        &self,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
        settled_through: i64,
        quota_reset_at: Option<i64>,
    ) -> Result<
        (
            Vec<RecentUsagePoint>,
            Vec<RecentUsagePoint>,
            Vec<RecentUsagePoint>,
        ),
        String,
    > {
        let latest_closed_start = settled_through.saturating_sub(FIVE_MINUTE_INTERVAL_SECONDS);
        let aggregate_anchor = OffsetDateTime::from_unix_timestamp(latest_closed_start)
            .unwrap_or(OffsetDateTime::UNIX_EPOCH);
        let five_minute_starts = aligned_bin_starts(
            latest_closed_start,
            LONG_RECENT_INTERVAL_SECONDS,
            LONG_RECENT_POINT_COUNT,
        );
        let start = *five_minute_starts
            .first()
            .unwrap_or(&now_utc.unix_timestamp());
        let end = five_minute_starts
            .last()
            .copied()
            .unwrap_or(now_utc.unix_timestamp())
            .saturating_add(LONG_RECENT_INTERVAL_SECONDS)
            .min(settled_through);

        // Grouping by model is sufficient for both the model breakdown and
        // the overall totals: every event belongs to exactly one model group,
        // including the NULL model group. The three public series are then
        // exact downsamplings of this one five-minute aggregate.
        let mut grouped = HashMap::<i64, UsageBinTotals>::new();
        let mut model_grouped = HashMap::<i64, Vec<ModelTokenBreakdown>>::new();
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    bucket_start,
                    model,
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(cached_input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(total_tokens), 0),
                    COALESCE(SUM(calls), 0)
                FROM published_dashboard_5m
                WHERE bucket_start >= ?2 AND bucket_start < ?3
                GROUP BY 1, model
                ORDER BY 1
                "#,
            )
            .map_err(|error| format!("无法准备精确 token 五分钟时间序列：{error}"))?;
        let rows = statement
            .query_map(params![LONG_RECENT_INTERVAL_SECONDS, start, end], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    ModelTokenBreakdown { event_start_unix: None,
                        model: row.get(1)?,
                        breakdown: TokenCacheBreakdown {
                            input_tokens: nonnegative_u64(row.get::<_, i64>(2)?),
                            cached_input_tokens: nonnegative_u64(row.get::<_, i64>(3)?),
                            output_tokens: nonnegative_u64(row.get::<_, i64>(4)?),
                            total_tokens: nonnegative_u64(row.get::<_, i64>(5)?),
                            calls: saturating_u32(row.get::<_, i64>(6)?),
                        },
                    },
                ))
            })
            .map_err(|error| format!("无法读取精确 token 五分钟时间序列：{error}"))?;
        for row in rows {
            let (bin, breakdown) =
                row.map_err(|error| format!("无法解码精确 token 五分钟时间序列：{error}"))?;
            let totals = UsageBinTotals {
                tokens: breakdown.breakdown.total_tokens,
                calls: breakdown.breakdown.calls,
                input_tokens: breakdown.breakdown.input_tokens,
                cached_input_tokens: breakdown.breakdown.cached_input_tokens,
                output_tokens: breakdown.breakdown.output_tokens,
            };
            grouped.entry(bin).or_default().add_breakdown(totals);
            add_model_usage_breakdown(
                model_grouped.entry(bin).or_default(),
                breakdown.model,
                totals,
                bin,
            );
        }

        let provenance_epoch = metadata_text(&self.connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| "精确 token 来源谱系标识缺失".to_string())?;
        let mut source_grouped = HashMap::<i64, Vec<RecentUsageSourceContribution>>::new();
        let mut source_statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    bucket_start,
                    source_id,
                    tokens,
                    calls,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens
                FROM attribution_source_buckets
                WHERE provenance_epoch = ?1
                  AND bucket_start >= ?2
                  AND bucket_start < ?3
                ORDER BY bucket_start, source_id
                "#,
            )
            .map_err(|error| format!("无法准备精确 token 匿名来源时间序列：{error}"))?;
        let source_rows = source_statement
            .query_map(params![&provenance_epoch, start, end], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            })
            .map_err(|error| format!("无法读取精确 token 匿名来源时间序列：{error}"))?;
        for row in source_rows {
            let (bin, source_id, tokens, calls, input, cached, output) =
                row.map_err(|error| format!("无法解码精确 token 匿名来源时间序列：{error}"))?;
            source_grouped
                .entry(bin)
                .or_default()
                .push(RecentUsageSourceContribution {
                    source_id,
                    tokens: nonnegative_u64(tokens),
                    calls: saturating_u32(calls),
                    input_tokens: nonnegative_u64(input),
                    cached_input_tokens: nonnegative_u64(cached).min(nonnegative_u64(input)),
                    output_tokens: nonnegative_u64(output),
                });
        }

        let mut recent = usage_series_from_five_minute(
            aggregate_anchor, local_offset,
            LONG_RECENT_INTERVAL_SECONDS, LONG_RECENT_POINT_COUNT,
            &grouped, &model_grouped, Some(&provenance_epoch), &source_grouped,
        );
        // Two bounded range reads only. No minute projection is produced for
        // interior buckets, historical buckets, or an unknown/expired quota.
        let edge_starts: Vec<i64> = quota_reset_at
            .filter(|reset| *reset > now_utc.unix_timestamp() && reset.rem_euclid(300) != 0)
            .map(|reset| vec![align_usage_bin(reset - 604_800, 300), align_usage_bin(reset, 300)])
            .unwrap_or_default();
        let first_edge = edge_starts.first().copied().unwrap_or(0);
        let last_edge = edge_starts.get(1).copied().unwrap_or(0);
        // Guard-band reads do not widen either the emitted minute buckets or
        // the accounting exclusion. Adjacent rows are discarded below.
        let first_start = if edge_starts.is_empty() { 0 } else { first_edge - 180 };
        let last_start = if edge_starts.is_empty() { 0 } else { last_edge - 180 };
        let first_end = if edge_starts.is_empty() { 0 } else { first_edge + 300 + 180 };
        let last_end = if edge_starts.is_empty() { 0 } else { last_edge + 300 + 180 };
        let mut minute_statement = self.connection.prepare(
            r#"
            SELECT timestamp / 60 * 60, model,
                   SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens),
                   SUM(tokens), COUNT(*)
            FROM temp.dashboard_snapshot_events
            WHERE (timestamp >= ?1 AND timestamp < ?2)
               OR (timestamp >= ?3 AND timestamp < ?4)
            GROUP BY 1, model ORDER BY 1, model
            "#,
        ).map_err(|error| format!("无法准备周期分钟明细：{error}"))?;
        let minute_rows = minute_statement.query_map(params![first_start, first_end, last_start, last_end], |row| {
            Ok(ModelTokenBreakdown {
                event_start_unix: Some(row.get(0)?),
                model: row.get(1)?,
                breakdown: TokenCacheBreakdown {
                    input_tokens: nonnegative_u64(row.get::<_, i64>(2)?),
                    cached_input_tokens: nonnegative_u64(row.get::<_, i64>(3)?),
                    output_tokens: nonnegative_u64(row.get::<_, i64>(4)?),
                    total_tokens: nonnegative_u64(row.get::<_, i64>(5)?),
                    calls: saturating_u32(row.get::<_, i64>(6)?),
                },
            })
        }).map_err(|error| format!("无法读取周期分钟明细：{error}"))?;
        let mut minutes_by_bucket = HashMap::<i64, Vec<ModelTokenBreakdown>>::new();
        for row in minute_rows {
            let row = row.map_err(|error| format!("无法解码周期分钟明细：{error}"))?;
            let bucket = align_usage_bin(row.event_start_unix.unwrap_or(0), 300);
            if !edge_starts.contains(&bucket) { continue; }
            minutes_by_bucket.entry(bucket).or_default().push(row);
        }
        for point in &mut recent {
            if let Some(minutes) = minutes_by_bucket.remove(&point.start_unix) {
                let mut total = UsageBinTotals::default();
                for minute in &minutes {
                    total.add_breakdown(UsageBinTotals {
                        tokens: minute.breakdown.total_tokens,
                        calls: minute.breakdown.calls,
                        input_tokens: minute.breakdown.input_tokens,
                        cached_input_tokens: minute.breakdown.cached_input_tokens,
                        output_tokens: minute.breakdown.output_tokens,
                    });
                }
                if total.tokens == point.tokens && total.calls == point.calls
                    && total.input_tokens == point.input_tokens
                    && total.cached_input_tokens == point.cached_input_tokens
                    && total.output_tokens == point.output_tokens {
                    point.minute_model_breakdowns = Some(minutes);
                }
            }
        }

        Ok((
            recent,
            usage_series_from_five_minute(
                aggregate_anchor,
                local_offset,
                HOURLY_INTERVAL_SECONDS,
                SEVEN_DAY_POINT_COUNT,
                &grouped,
                &model_grouped,
                None,
                &HashMap::new(),
            ),
            usage_series_from_five_minute(
                aggregate_anchor,
                local_offset,
                SIX_HOUR_INTERVAL_SECONDS,
                THIRTY_DAY_POINT_COUNT,
                &grouped,
                &model_grouped,
                None,
                &HashMap::new(),
            ),
        ))
    }

    fn cache_hit_ranking(
        &self,
        local_offset: UtcOffset,
    ) -> Result<Vec<CacheHitRankingItem>, String> {
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    session_id,
                    calls,
                    input_tokens,
                    cached_tokens,
                    updated_at,
                    title
                FROM dashboard_session_rows
                WHERE calls > 1 AND input_tokens >= ?1
                ORDER BY
                    (cached_tokens * 1.0 / input_tokens) ASC,
                    (input_tokens - cached_tokens) DESC,
                    title ASC
                LIMIT 10
                "#,
            )
            .map_err(|error| format!("无法准备缓存命中排行：{error}"))?;
        let rows = statement
            .query_map(params![CACHE_USAGE_MIN_INPUT_TOKENS], |row| {
                Ok((
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })
            .map_err(|error| format!("无法读取缓存命中排行：{error}"))?;
        let mut items = Vec::new();
        for (index, row) in rows.enumerate() {
            let (calls, input, cached, updated_at, title) =
                row.map_err(|error| format!("无法解码缓存命中排行：{error}"))?;
            items.push(CacheHitRankingItem {
                rank: u32::try_from(index + 1).unwrap_or(u32::MAX),
                title,
                subtitle: format!(
                    "{} 轮 · {}",
                    saturating_u32(calls),
                    updated_at
                        .and_then(|timestamp| OffsetDateTime::from_unix_timestamp(timestamp).ok())
                        .map(|timestamp| {
                            timestamp
                                .to_offset(local_offset)
                                .format(format_description!("[month]-[day] [hour]:[minute]"))
                                .unwrap_or_else(|_| "未知时间".into())
                        })
                        .unwrap_or_else(|| "未知时间".into())
                ),
                hit_rate: cache_hit_rate(input, cached),
                input_tokens: nonnegative_u64(input),
                cached_tokens: nonnegative_u64(cached),
            });
        }
        Ok(items)
    }

    fn cache_usage(
        &self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
        now: OffsetDateTime,
    ) -> Result<TokenCacheUsage, String> {
        let active_since = history_compression_enabled(codex_home)
            .then(|| now.unix_timestamp() - 7 * 24 * 60 * 60);
        let sessions = self.session_candidates(active_since)?;
        let turns = self.turn_candidates(codex_home, warnings, active_since)?;
        Ok(TokenCacheUsage { sessions, turns, ranking_active_since: active_since.and_then(format_rfc3339_unix) })
    }

    fn session_candidates(&self, active_since: Option<i64>) -> Result<Vec<SessionCacheUsage>, String> {
        let mut selected_ids = HashSet::new();
        let mut selected = Vec::new();
        for (multi_turn_only, latest_first) in
            [(true, false), (true, true), (false, false), (false, true)]
        {
            for item in self.query_session_candidates(multi_turn_only, latest_first, active_since)? {
                if selected_ids.insert(item.id.clone()) {
                    selected.push(item);
                }
            }
        }
        Ok(selected)
    }

    fn query_session_candidates(
        &self,
        multi_turn_only: bool,
        latest_first: bool,
        active_since: Option<i64>,
    ) -> Result<Vec<SessionCacheUsage>, String> {
        let turn_predicate = if multi_turn_only { "AND calls > 1" } else { "" };
        let ordering = if latest_first {
            "ORDER BY updated_at IS NULL, updated_at DESC, hit_rate ASC, uncached DESC, input_tokens DESC, session_id ASC"
        } else {
            "ORDER BY hit_rate ASC, uncached DESC, input_tokens DESC, updated_at DESC, session_id ASC"
        };
        let sql = format!(
            r#"
            SELECT
                session_id,
                calls,
                total_tokens,
                input_tokens,
                cached_tokens,
                output_tokens,
                updated_at,
                title,
                CASE WHEN input_tokens > 0 THEN cached_tokens * 1.0 / input_tokens ELSE 0 END AS hit_rate,
                input_tokens - cached_tokens AS uncached
            FROM dashboard_session_rows
            WHERE calls > 0
              AND (?1 = 1 OR input_tokens >= ?2)
              AND (?4 IS NULL OR last_activity_at >= ?4)
              {turn_predicate}
            {ordering}
            LIMIT ?3
            "#
        );
        let mut statement = self
            .connection
            .prepare(&sql)
            .map_err(|error| format!("无法准备会话缓存候选：{error}"))?;
        let rows = statement
            .query_map(
                params![
                    latest_first,
                    CACHE_USAGE_MIN_INPUT_TOKENS,
                    CACHE_USAGE_CANDIDATE_LIMIT,
                    active_since
                ],
                |row| {
                    Ok(SessionCacheUsage {
                        id: row.get(0)?,
                        title: row.get(7)?,
                        last_updated: row.get::<_, Option<i64>>(6)?.and_then(format_rfc3339_unix),
                        breakdown: TokenCacheBreakdown {
                            calls: saturating_u32(row.get::<_, i64>(1)?),
                            total_tokens: nonnegative_u64(row.get::<_, i64>(2)?),
                            input_tokens: nonnegative_u64(row.get::<_, i64>(3)?),
                            cached_input_tokens: nonnegative_u64(row.get::<_, i64>(4)?),
                            output_tokens: nonnegative_u64(row.get::<_, i64>(5)?),
                        },
                    })
                },
            )
            .map_err(|error| format!("无法读取会话缓存候选：{error}"))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("无法解码会话缓存候选：{error}"))
    }

    /// Numeric ranking may enrich excerpts by calling verify_excerpt_source.
    /// That verification can write physical proofs/binding availability in a
    /// savepoint on this same snapshot. Published-read-only mode skips enrichment;
    /// do not move it to an independent connection or label all reads as pure.
    fn turn_candidates(
        &self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
        active_since: Option<i64>,
    ) -> Result<Vec<TurnCacheUsage>, String> {
        let mut selected_ids = HashSet::new();
        let mut selected = Vec::new();
        for (later_turn_only, latest_first) in
            [(true, false), (true, true), (false, false), (false, true)]
        {
            for item in self.query_turn_candidates(later_turn_only, latest_first, active_since)? {
                if selected_ids.insert(item.usage.id.clone()) {
                    selected.push(item);
                }
            }
        }

        if self.published_read_only { return Ok(selected.into_iter().map(|item| item.usage).collect()); }

        let canonical_home = canonical_codex_home(codex_home)?;
        let mut requested_excerpts: HashMap<PathBuf, Vec<ExactEventSourceOffsets>> = HashMap::new();
        for item in &selected {
            requested_excerpts.entry(item.file_path.clone()).or_default().push(item.source_offsets);
        }
        let mut excerpt_batches: HashMap<PathBuf, Result<HashMap<ExactEventSourceOffsets, (String, String)>, String>> = HashMap::new();
        let mut verified_excerpts = HashMap::new();
        let mut changed_excerpt_sources = HashSet::new();
        Ok(selected
            .into_iter()
            .map(|mut item| {
                if changed_excerpt_sources.contains(&item.file_path) {
                    return item.usage;
                }
                let ResolvedSessionFile::Accepted(file) = resolve_file_within_codex_home(
                    &canonical_home,
                    &item.file_path,
                    "缓存排行摘录",
                    warnings,
                ) else {
                    return item.usage;
                };
                // Optional raw text is deferred for actual compressed storage,
                // independent of the seven-day ranking preference.
                if !rollout_source::physical_path(&file).is_ok_and(|physical| !rollout_source::is_compressed(&physical)) {
                    return item.usage;
                }
                let before = match lightweight_file_signature(&file, None) {
                    Ok(Some(signature)) => signature,
                    Ok(None) => return item.usage,
                    Err(error) => {
                        warnings.push(excerpt_warning(error));
                        return item.usage;
                    }
                };
                if !before.matches_stored(item.file_size, &item.file_modified_ns) {
                    changed_excerpt_sources.insert(item.file_path.clone());
                    warnings.push(excerpt_warning(format!(
                        "会话摘录源文件已在索引后变化，将在下一次刷新重建：{}",
                        file.display()
                    )));
                    return item.usage;
                }
                match representations::current_excerpt_observation(&self.connection, &file, before) {
                    Ok(true) => {},
                    Ok(false) => return item.usage,
                    Err(error) => { warnings.push(excerpt_warning(error)); return item.usage; }
                }
                if item.source_offsets.user_prompt.is_none() && item.source_offsets.assistant_response.is_none() {
                    return item.usage;
                }
                let verified = verified_excerpts.entry(file.clone()).or_insert_with(||
                    representations::verify_excerpt_source(&self.connection, &file));
                match verified {
                    Ok(true) => {}
                    Ok(false) => return item.usage,
                    Err(error) => {warnings.push(excerpt_warning(error.clone())); return item.usage;}
                }
                let batch = excerpt_batches.entry(file.clone()).or_insert_with(|| {
                    let requests = requested_excerpts.get(&item.file_path).map(Vec::as_slice).unwrap_or(&[]);
                    read_event_excerpt_batch(&file, requests, |handle| {
                        if file_signature_from_handle(handle, &file)? == before { Ok(()) }
                        else { Err(format!("会话摘录描述符在读取期间变化：{}", file.display())) }
                    }).map(|values|
                        requests.iter().copied().zip(values).collect())
                });
                match batch.as_ref().map(|values| values.get(&item.source_offsets)) {
                    Ok(Some((user_prompt, assistant_response))) => match lightweight_file_signature(&file, None) {
                        Ok(Some(after)) if after == before => {
                            item.usage.user_prompt = user_prompt.clone();
                            item.usage.assistant_response = assistant_response.clone();
                        }
                        Ok(_) => warnings.push(excerpt_warning(format!(
                            "会话摘录源文件在读取期间变化，将在下一次刷新重建：{}",
                            file.display()
                        ))),
                        Err(error) => warnings.push(excerpt_warning(error)),
                    },
                    Ok(None) => {},
                    Err(error) => warnings.push(excerpt_warning(error.clone())),
                }
                item.usage
            })
            .collect())
    }

    fn query_turn_candidates(
        &self,
        later_turn_only: bool,
        latest_first: bool,
        active_since: Option<i64>,
    ) -> Result<Vec<IndexedTurnCandidate>, String> {
        let turn_predicate = if later_turn_only {
            "AND c.turn_index > 1"
        } else {
            ""
        };
        let ordering = if latest_first {
            "ORDER BY timestamp DESC, hit_rate ASC, uncached DESC, input_tokens DESC, file_path DESC, ordinal DESC"
        } else {
            "ORDER BY hit_rate ASC, uncached DESC, input_tokens DESC, timestamp DESC, file_path DESC, ordinal DESC"
        };
        let sql = format!(
            r#"
            WITH selected_turns AS (
                SELECT
                    c.*,
                    CASE WHEN c.input_tokens > 0
                        THEN c.cached_input_tokens * 1.0 / c.input_tokens
                        ELSE 0
                    END AS hit_rate,
                    c.input_tokens - c.cached_input_tokens AS uncached
                FROM dashboard_turn_candidates c
                WHERE c.aggregate_generation = COALESCE(
                    (
                        SELECT CAST(value AS INTEGER)
                        FROM metadata
                        WHERE key = 'published_generation'
                    ),
                    0
                )
                  AND (?1 = 1 OR c.input_tokens >= ?2)
                  AND (?4 IS NULL OR c.session_id IN (
                    SELECT session_id FROM dashboard_session_rows WHERE last_activity_at >= ?4
                  ))
                  {turn_predicate}
                {ordering}
                LIMIT ?3
            )
            SELECT
                turn_rows.event_id,
                turn_rows.file_path,
                turn_rows.ordinal,
                turn_rows.timestamp,
                turn_rows.session_id,
                turn_rows.total_tokens,
                turn_rows.input_tokens,
                turn_rows.cached_input_tokens,
                turn_rows.output_tokens,
                binding.user_prompt_start,
                binding.user_prompt_end,
                binding.assistant_response_start,
                binding.assistant_response_end,
                turn_rows.turn_index AS turn_index_in_session,
                COALESCE(
                    NULLIF(TRIM(m.title), ''),
                    '会话 ' || SUBSTR(turn_rows.session_id, 1, 8)
                ) AS title,
                f.size,
                f.modified_ns,
                turn_rows.request_count,
                turn_rows.low_hit_count,
                turn_rows.zero_hit_count
            FROM selected_turns AS turn_rows
            LEFT JOIN usage_ledger_bindings binding ON binding.event_id=turn_rows.event_id
                AND (binding.available=1 OR EXISTS(SELECT 1 FROM source_representations r WHERE r.source_id=binding.source_id AND r.verification='metadata_only'))
                AND binding.raw_generation=(SELECT raw_generation FROM usage_ledger_sources ls WHERE ls.source_id=binding.source_id AND ls.missing=0)
            LEFT JOIN session_metadata m ON m.session_id = turn_rows.session_id
            JOIN files f
              ON f.generation = turn_rows.source_file_generation
             AND f.path = turn_rows.file_path
            {ordering}
            "#
        );
        let mut statement = self
            .connection
            .prepare(&sql)
            .map_err(|error| format!("无法准备轮次缓存候选：{error}"))?;
        let rows = statement
            .query_map(
                params![
                    latest_first,
                    CACHE_USAGE_MIN_INPUT_TOKENS,
                    CACHE_USAGE_CANDIDATE_LIMIT,
                    active_since
                ],
                |row| {
                    let event_id = row.get::<_, i64>(0)?;
                    let timestamp = row.get::<_, i64>(3)?;
                    let session_id = row.get::<_, String>(4)?;
                    Ok(IndexedTurnCandidate {
                        file_path: PathBuf::from(row.get::<_, String>(1)?),
                        file_size: nonnegative_u64(row.get::<_, i64>(15)?),
                        file_modified_ns: row.get(16)?,
                        source_offsets: ExactEventSourceOffsets {
                            user_prompt: source_range_from_columns(
                                row.get::<_, Option<i64>>(9)?,
                                row.get::<_, Option<i64>>(10)?,
                            ),
                            assistant_response: source_range_from_columns(
                                row.get::<_, Option<i64>>(11)?,
                                row.get::<_, Option<i64>>(12)?,
                            ),
                        },
                        usage: TurnCacheUsage {
                            id: format!("{session_id}-{timestamp}-{event_id}"),
                            session_id,
                            session_title: row.get(14)?,
                            timestamp: format_rfc3339_unix(timestamp).unwrap_or_default(),
                            turn_index_in_session: saturating_u32(row.get::<_, i64>(13)?),
                            user_prompt: String::new(),
                            assistant_response: String::new(),
                            request_count: saturating_u32(row.get::<_, i64>(17)?),
                            low_hit_count: saturating_u32(row.get::<_, i64>(18)?),
                            zero_hit_count: saturating_u32(row.get::<_, i64>(19)?),
                            breakdown: TokenCacheBreakdown {
                                total_tokens: nonnegative_u64(row.get::<_, i64>(5)?),
                                input_tokens: nonnegative_u64(row.get::<_, i64>(6)?),
                                cached_input_tokens: nonnegative_u64(row.get::<_, i64>(7)?),
                                output_tokens: nonnegative_u64(row.get::<_, i64>(8)?),
                                calls: 1,
                            },
                        },
                    })
                },
            )
            .map_err(|error| format!("无法读取轮次缓存候选：{error}"))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("无法解码轮次缓存候选：{error}"))
    }
}

fn summary_from_file_contributions(
    contributions: &HashMap<String, SummaryFileContribution>,
) -> TokenUsageSummary {
    let mut summary = TokenUsageSummary::default();
    let mut model_breakdowns = HashMap::<Option<String>, TokenCacheBreakdown>::new();
    for contribution in contributions.values() {
        summary.total_tokens = summary
            .total_tokens
            .saturating_add(contribution.total_tokens);
        summary.today_tokens = summary
            .today_tokens
            .saturating_add(contribution.today_tokens);
        summary.today_requests = summary
            .today_requests
            .saturating_add(contribution.today_requests);
        for model in &contribution.today_model_breakdowns {
            let aggregate = model_breakdowns.entry(model.model.clone()).or_default();
            aggregate.input_tokens = aggregate
                .input_tokens
                .saturating_add(model.breakdown.input_tokens);
            aggregate.cached_input_tokens = aggregate
                .cached_input_tokens
                .saturating_add(model.breakdown.cached_input_tokens);
            aggregate.output_tokens = aggregate
                .output_tokens
                .saturating_add(model.breakdown.output_tokens);
            aggregate.total_tokens = aggregate
                .total_tokens
                .saturating_add(model.breakdown.total_tokens);
            aggregate.calls = aggregate.calls.saturating_add(model.breakdown.calls);
        }
    }
    summary.today_model_breakdowns = model_breakdowns
        .into_iter()
        .map(|(model, breakdown)| ModelTokenBreakdown { event_start_unix: None, model, breakdown })
        .collect();
    summary.today_model_breakdowns.sort_by(|left, right| {
        right
            .breakdown
            .total_tokens
            .cmp(&left.breakdown.total_tokens)
            .then_with(|| left.model.cmp(&right.model))
    });
    summary
}

pub(super) fn format_precise_dashboard_phases(
    prepare_snapshot_ms: u128,
    activity_days_ms: u128,
    stats_ms: u128,
    usage_series_ms: u128,
    cache_ranking_ms: u128,
    cache_usage_ms: u128,
    total_ms: u128,
) -> String {
    format!(
        "precise_dashboard_phases prepare_snapshot_ms={prepare_snapshot_ms} activity_days_ms={activity_days_ms} stats_ms={stats_ms} usage_series_ms={usage_series_ms} cache_ranking_ms={cache_ranking_ms} cache_usage_ms={cache_usage_ms} total_ms={total_ms} status=ok"
    )
}

fn add_model_usage_breakdown(
    grouped: &mut Vec<ModelTokenBreakdown>,
    model: Option<String>,
    totals: UsageBinTotals,
    timestamp: i64,
) {
    let price_day = timestamp.div_euclid(86400) * 86400;
    if let Some(existing) = grouped.iter_mut().find(|item| item.model == model && item.event_start_unix == Some(price_day)) {
        let current = UsageBinTotals {
            tokens: existing.breakdown.total_tokens,
            calls: existing.breakdown.calls,
            input_tokens: existing.breakdown.input_tokens,
            cached_input_tokens: existing.breakdown.cached_input_tokens,
            output_tokens: existing.breakdown.output_tokens,
        };
        let mut combined = current;
        combined.add_breakdown(totals);
        existing.breakdown = combined.into_breakdown();
    } else {
        grouped.push(ModelTokenBreakdown { event_start_unix: Some(price_day),
            model,
            breakdown: totals.into_breakdown(),
        });
    }
}

fn usage_series_from_five_minute(
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
    interval_seconds: i64,
    point_count: i64,
    five_minute_grouped: &HashMap<i64, UsageBinTotals>,
    five_minute_model_grouped: &HashMap<i64, Vec<ModelTokenBreakdown>>,
    source_contribution_epoch: Option<&String>,
    five_minute_source_grouped: &HashMap<i64, Vec<RecentUsageSourceContribution>>,
) -> Vec<RecentUsagePoint> {
    let bin_starts = aligned_bin_starts(now_utc.unix_timestamp(), interval_seconds, point_count);
    let start = *bin_starts.first().unwrap_or(&now_utc.unix_timestamp());
    let end = bin_starts
        .last()
        .copied()
        .unwrap_or(now_utc.unix_timestamp())
        .saturating_add(interval_seconds);
    let mut grouped = HashMap::<i64, UsageBinTotals>::new();
    for (&bin, &totals) in five_minute_grouped {
        if bin < start || bin >= end {
            continue;
        }
        grouped
            .entry(align_usage_bin(bin, interval_seconds))
            .or_default()
            .add_breakdown(totals);
    }

    let mut model_grouped = HashMap::<i64, Vec<ModelTokenBreakdown>>::new();
    let mut model_bins = five_minute_model_grouped
        .keys()
        .copied()
        .collect::<Vec<_>>();
    model_bins.sort_unstable();
    for bin in model_bins {
        let model_breakdowns = &five_minute_model_grouped[&bin];
        if bin < start || bin >= end {
            continue;
        }
        let target = align_usage_bin(bin, interval_seconds);
        let target_breakdowns = model_grouped.entry(target).or_default();
        for breakdown in model_breakdowns {
            let totals = UsageBinTotals {
                tokens: breakdown.breakdown.total_tokens,
                calls: breakdown.breakdown.calls,
                input_tokens: breakdown.breakdown.input_tokens,
                cached_input_tokens: breakdown.breakdown.cached_input_tokens,
                output_tokens: breakdown.breakdown.output_tokens,
            };
            add_model_usage_breakdown(target_breakdowns, breakdown.model.clone(), totals, breakdown.event_start_unix.unwrap_or(bin));
        }
    }

    bin_starts
        .into_iter()
        .map(|start_unix| {
            let totals = grouped.remove(&start_unix).unwrap_or_default();
            let timestamp = OffsetDateTime::from_unix_timestamp(start_unix)
                .unwrap_or(OffsetDateTime::UNIX_EPOCH)
                .to_offset(local_offset);
            RecentUsagePoint {
                minute_model_breakdowns: None,
                label: timestamp
                    .format(format_description!("[hour]:[minute]"))
                    .unwrap_or_else(|_| "00:00".into()),
                start_unix,
                tokens: totals.tokens,
                calls: totals.calls,
                input_tokens: totals.input_tokens,
                cached_input_tokens: totals.cached_input_tokens,
                output_tokens: totals.output_tokens,
                model_breakdowns: model_grouped.remove(&start_unix).unwrap_or_default(),
                cache_hit_rate: (totals.input_tokens > 0).then(|| {
                    cache_hit_rate(
                        i64::try_from(totals.input_tokens).unwrap_or(i64::MAX),
                        i64::try_from(totals.cached_input_tokens).unwrap_or(i64::MAX),
                    )
                }),
                five_hour_remaining_percent: None,
                seven_day_remaining_percent: None,
                source_contribution_epoch: source_contribution_epoch.cloned(),
                source_contributions: if source_contribution_epoch.is_some() {
                    five_minute_source_grouped
                        .get(&start_unix)
                        .cloned()
                        .unwrap_or_default()
                } else {
                    Vec::new()
                },
            }
        })
        .collect()
}

fn align_usage_bin(timestamp: i64, interval_seconds: i64) -> i64 {
    timestamp - (timestamp % interval_seconds)
}

fn cache_hit_rate(input: i64, cached: i64) -> f64 {
    if input <= 0 {
        0.0
    } else {
        (cached.max(0).min(input) as f64 / input as f64).clamp(0.0, 1.0)
    }
}

fn fixed_local_day_bounds(date: Date, offset: UtcOffset) -> Result<(i64, i64), String> {
    let start = date
        .with_hms(0, 0, 0)
        .map_err(|error| format!("无法计算本地日期边界：{error}"))?
        .assume_offset(offset)
        .unix_timestamp();
    let end = (date + Duration::days(1))
        .with_hms(0, 0, 0)
        .map_err(|error| format!("无法计算本地日期边界：{error}"))?
        .assume_offset(offset)
        .unix_timestamp();
    Ok((start, end))
}

fn format_date(date: Date) -> String {
    date.format(format_description!("[year]-[month]-[day]"))
        .unwrap_or_else(|_| "1970-01-01".into())
}

pub(super) fn format_rfc3339_unix(timestamp: i64) -> Option<String> {
    OffsetDateTime::from_unix_timestamp(timestamp)
        .ok()
        .and_then(|value| value.format(&Rfc3339).ok())
}

pub(super) fn format_rfc3339_nanos(timestamp: u128) -> Option<String> {
    let seconds = i64::try_from(timestamp / 1_000_000_000).ok()?;
    let nanosecond = u32::try_from(timestamp % 1_000_000_000).ok()?;
    OffsetDateTime::from_unix_timestamp(seconds)
        .ok()?
        .replace_nanosecond(nanosecond)
        .ok()
        .and_then(|value| value.format(&Rfc3339).ok())
}

fn current_streak_days(days: &[ActivityDay], today: Date) -> u32 {
    let mut active = HashSet::new();
    for day in days {
        let Ok(date) = Date::parse(&day.date, format_description!("[year]-[month]-[day]")) else {
            continue;
        };
        if date <= today && day.tokens > 0 {
            active.insert(date);
        }
    }
    let yesterday = today - Duration::days(1);
    let mut cursor = if active.contains(&today) {
        today
    } else if active.contains(&yesterday) {
        yesterday
    } else {
        return 0;
    };
    let mut streak = 0_u32;
    while active.contains(&cursor) {
        streak = streak.saturating_add(1);
        cursor -= Duration::days(1);
    }
    streak
}

fn longest_streak_days(days: &[ActivityDay]) -> u32 {
    let mut best = 0_u32;
    let mut current = 0_u32;
    for day in days {
        if day.tokens > 0 {
            current = current.saturating_add(1);
            best = best.max(current);
        } else {
            current = 0;
        }
    }
    best
}
