use super::session_files::session_id_from_file;
use super::session_parser::{
    read_event_excerpts, stream_session_file_exact, ExactEventSourceOffsets, ExactSessionEventSink,
    ExactTokenEvent, SourceByteRange, UsageSnapshotFingerprint,
};
use super::TokenUsageSummary;
#[cfg(not(test))]
use crate::core::app_paths;
use crate::core::sqlite;
use crate::core::time_series_timeline::{
    aligned_bin_starts, LONG_RECENT_INTERVAL_SECONDS, LONG_RECENT_POINT_COUNT,
};
use crate::models::{
    ActivityDay, CacheHitRankingItem, DashboardStats, LocalDataWarning, RecentUsagePoint,
    SessionCacheUsage, TokenCacheBreakdown, TokenCacheUsage, TurnCacheUsage,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

const INDEX_SCHEMA_VERSION: i64 = 3;
const HOURLY_INTERVAL_SECONDS: i64 = 60 * 60;
const SEVEN_DAY_POINT_COUNT: i64 = 7 * 24;
const SIX_HOUR_INTERVAL_SECONDS: i64 = 6 * 60 * 60;
const THIRTY_DAY_POINT_COUNT: i64 = 30 * 4;
const CACHE_USAGE_MIN_INPUT_TOKENS: i64 = 1_000;
const CACHE_USAGE_CANDIDATE_LIMIT: i64 = 40;

pub(super) struct ExactUsageIndex {
    connection: Connection,
}

pub(super) struct ExactDashboardData {
    pub(super) summary: TokenUsageSummary,
    pub(super) stats: DashboardStats,
    pub(super) activity_days: Vec<ActivityDay>,
    pub(super) recent_usage_24h: Vec<RecentUsagePoint>,
    pub(super) recent_usage_7d: Vec<RecentUsagePoint>,
    pub(super) recent_usage_30d: Vec<RecentUsagePoint>,
    pub(super) cache_hit_ranking: Vec<CacheHitRankingItem>,
    pub(super) cache_usage: TokenCacheUsage,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileIdentity {
    device_id: u64,
    file_id: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileSignature {
    size: u64,
    modified_ns: u128,
    identity: FileIdentity,
    changed_ns: i128,
}

struct IndexedTurnCandidate {
    usage: TurnCacheUsage,
    file_path: PathBuf,
    file_size: u64,
    file_modified_ns: String,
    file_device_id: String,
    file_id: String,
    file_changed_ns: String,
    source_offsets: ExactEventSourceOffsets,
}

#[cfg(test)]
type AfterPrefixScanHook = Box<dyn FnOnce(&Path)>;

#[cfg(test)]
thread_local! {
    static AFTER_PREFIX_SCAN_HOOK: RefCell<Option<AfterPrefixScanHook>> = RefCell::new(None);
}

impl ExactUsageIndex {
    pub(super) fn open(codex_home: &Path) -> Result<Self, String> {
        let path = database_path(codex_home)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "无法创建精确 token 索引目录 {}：{}",
                    parent.display(),
                    error
                )
            })?;
        }
        let existed_before = existing_regular_index(&path)?;
        let (mut connection, recovered_corrupt_index) =
            open_index_connection_with_recovery(&path, existed_before)?;
        let mut schema_version = metadata_i64(&connection, "schema_version")?;
        if existed_before
            && !recovered_corrupt_index
            && schema_version != Some(INDEX_SCHEMA_VERSION)
        {
            // The index is fully rebuildable. Replacing an obsolete database,
            // rather than dropping its text columns in place, guarantees that
            // deleted SQLite pages and WAL frames cannot retain conversation
            // plaintext from schema v1.
            drop(connection);
            remove_index_storage(&path)?;
            connection = open_index_connection(&path)?;
            schema_version = None;
        }
        initialize_index_schema(&connection)?;
        if schema_version != Some(INDEX_SCHEMA_VERSION) {
            set_metadata(
                &connection,
                "schema_version",
                &INDEX_SCHEMA_VERSION.to_string(),
            )?;
            set_metadata(&connection, "revision", &fresh_revision_seed().to_string())?;
        }

        let identity = codex_home_identity(codex_home);
        if metadata_text(&connection, "codex_home_identity")?.as_deref() != Some(&identity) {
            connection
                .execute_batch(
                    r#"
                    DELETE FROM events;
                    DELETE FROM files;
                    DELETE FROM session_metadata;
                    "#,
                )
                .map_err(|error| format!("无法切换精确 token 索引数据源：{error}"))?;
            set_metadata(&connection, "codex_home_identity", &identity)?;
            set_metadata(&connection, "revision", &fresh_revision_seed().to_string())?;
        }

        Ok(Self { connection })
    }

    #[cfg(test)]
    pub(super) fn set_after_prefix_scan_hook_for_testing(hook: impl FnOnce(&Path) + 'static) {
        AFTER_PREFIX_SCAN_HOOK.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(hook));
        });
    }

    pub(super) fn sync(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<u64, String> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始精确 token 索引事务：{error}"))?;
        transaction
            .execute_batch(
                r#"
                CREATE TEMP TABLE IF NOT EXISTS exact_seen_files (
                    path TEXT PRIMARY KEY
                ) WITHOUT ROWID;
                CREATE TEMP TABLE IF NOT EXISTS exact_seen_directories (
                    path TEXT PRIMARY KEY
                ) WITHOUT ROWID;
                CREATE TEMP TABLE IF NOT EXISTS exact_fingerprints (
                    fingerprint BLOB PRIMARY KEY
                ) WITHOUT ROWID;
                DELETE FROM exact_seen_files;
                DELETE FROM exact_seen_directories;
                DELETE FROM exact_fingerprints;
                "#,
            )
            .map_err(|error| format!("无法准备精确 token 索引临时表：{error}"))?;

        let mut changed = false;
        visit_session_files(
            &transaction,
            codex_home,
            warnings,
            |transaction, file, warnings| {
                if process_session_file(transaction, codex_home, file, warnings)? {
                    changed = true;
                }
                Ok(())
            },
        )?;

        let deleted = transaction
            .query_row(
                "SELECT COUNT(*) FROM files WHERE path NOT IN (SELECT path FROM exact_seen_files)",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("无法检查已删除的会话文件：{error}"))?;
        if deleted > 0 {
            transaction
                .execute(
                    "DELETE FROM files WHERE path NOT IN (SELECT path FROM exact_seen_files)",
                    [],
                )
                .map_err(|error| format!("无法移除已删除会话的精确 token 索引：{error}"))?;
            changed = true;
        }

        if sync_thread_metadata(&transaction, codex_home, warnings)? {
            changed = true;
        }

        let current_revision = metadata_i64(&transaction, "revision")?.unwrap_or(0);
        let revision = if changed {
            current_revision.saturating_add(1)
        } else {
            current_revision
        };
        set_metadata(&transaction, "revision", &revision.to_string())?;
        transaction
            .commit()
            .map_err(|error| format!("无法提交精确 token 索引：{error}"))?;
        Ok(u64::try_from(revision).unwrap_or(0))
    }

    pub(super) fn revision(&self) -> Result<u64, String> {
        Ok(u64::try_from(metadata_i64(&self.connection, "revision")?.unwrap_or(0)).unwrap_or(0))
    }

    pub(super) fn sources_changed(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<bool, String> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|error| format!("无法开始精确 token 变更检查：{error}"))?;
        transaction
            .execute_batch(
                r#"
                CREATE TEMP TABLE IF NOT EXISTS exact_seen_files (
                    path TEXT PRIMARY KEY
                ) WITHOUT ROWID;
                CREATE TEMP TABLE IF NOT EXISTS exact_seen_directories (
                    path TEXT PRIMARY KEY
                ) WITHOUT ROWID;
                DELETE FROM exact_seen_files;
                DELETE FROM exact_seen_directories;
                "#,
            )
            .map_err(|error| format!("无法准备精确 token 变更检查：{error}"))?;
        let mut changed = false;
        visit_session_files(
            &transaction,
            codex_home,
            warnings,
            |transaction, file, _warnings| {
                let canonical = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
                let path = canonical.to_string_lossy().into_owned();
                let newly_seen = transaction
                    .execute(
                        "INSERT OR IGNORE INTO exact_seen_files(path) VALUES (?1)",
                        params![path],
                    )
                    .map_err(|error| format!("无法记录会话文件变更检查：{error}"))?
                    > 0;
                if !newly_seen {
                    return Ok(());
                }
                let signature = file_signature(file)?;
                let unchanged = transaction
                    .query_row(
                        "SELECT size, modified_ns, device_id, file_id, changed_ns FROM files WHERE path = ?1",
                        params![path],
                        |row| {
                            Ok((
                                row.get::<_, i64>(0)?,
                                row.get::<_, String>(1)?,
                                row.get::<_, String>(2)?,
                                row.get::<_, String>(3)?,
                                row.get::<_, String>(4)?,
                            ))
                        },
                    )
                    .optional()
                    .map_err(|error| format!("无法读取会话文件变更签名：{error}"))?
                    .is_some_and(
                        |(size, modified_ns, device_id, file_id, changed_ns)| {
                            signature.matches_stored(
                                nonnegative_u64(size),
                                &modified_ns,
                                &device_id,
                                &file_id,
                                &changed_ns,
                            )
                        },
                    );
                changed |= !unchanged;
                Ok(())
            },
        )?;
        let deleted = transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM files WHERE path NOT IN (SELECT path FROM exact_seen_files))",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("无法检查已删除的会话文件：{error}"))?;
        Ok(changed || deleted)
    }

    pub(super) fn is_empty(&self) -> Result<bool, String> {
        self.connection
            .query_row(
                "SELECT NOT EXISTS(SELECT 1 FROM events LIMIT 1)",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("无法检查精确 token 索引：{error}"))
    }

    pub(super) fn summary(
        &self,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
    ) -> Result<TokenUsageSummary, String> {
        let today = now_utc.to_offset(local_offset).date();
        let (start, end) = local_day_bounds(today, local_offset)?;
        let (total, today_tokens, today_requests) = self
            .connection
            .query_row(
                r#"
                SELECT
                    COALESCE(SUM(tokens), 0),
                    COALESCE(SUM(CASE WHEN timestamp >= ?1 AND timestamp < ?2 THEN tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN timestamp >= ?1 AND timestamp < ?2 THEN 1 ELSE 0 END), 0)
                FROM events
                "#,
                params![start, end],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .map_err(|error| format!("无法汇总精确 token 用量：{error}"))?;
        Ok(TokenUsageSummary {
            total_tokens: nonnegative_u64(total),
            today_tokens: nonnegative_u64(today_tokens),
            today_requests: saturating_u32(today_requests),
        })
    }

    pub(super) fn dashboard_data(
        &self,
        codex_home: &Path,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<ExactDashboardData, String> {
        let activity_days = self.activity_days(now_utc, local_offset)?;
        let stats = self.stats(&activity_days, now_utc, local_offset)?;
        let summary = self.summary(now_utc, local_offset)?;
        let recent_usage_24h = self.usage_series(
            now_utc,
            local_offset,
            LONG_RECENT_INTERVAL_SECONDS,
            LONG_RECENT_POINT_COUNT,
        )?;
        let recent_usage_7d = self.usage_series(
            now_utc,
            local_offset,
            HOURLY_INTERVAL_SECONDS,
            SEVEN_DAY_POINT_COUNT,
        )?;
        let recent_usage_30d = self.usage_series(
            now_utc,
            local_offset,
            SIX_HOUR_INTERVAL_SECONDS,
            THIRTY_DAY_POINT_COUNT,
        )?;
        let cache_hit_ranking = self.cache_hit_ranking(local_offset)?;
        let cache_usage = self.cache_usage(codex_home, warnings)?;

        Ok(ExactDashboardData {
            summary,
            stats,
            activity_days,
            recent_usage_24h,
            recent_usage_7d,
            recent_usage_30d,
            cache_hit_ranking,
            cache_usage,
        })
    }

    fn activity_days(
        &self,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
    ) -> Result<Vec<ActivityDay>, String> {
        let today = now_utc.to_offset(local_offset).date();
        let start_day = today - Duration::days(364);
        let (start_unix, _) = local_day_bounds(start_day, local_offset)?;
        let (_, end_unix) = local_day_bounds(today, local_offset)?;
        let offset_seconds = local_offset.whole_seconds();
        let mut grouped = HashMap::new();
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    strftime('%Y-%m-%d', timestamp, 'unixepoch', printf('%+d seconds', ?1)),
                    COALESCE(SUM(tokens), 0),
                    COUNT(*),
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(MIN(cached_input_tokens, input_tokens)), 0)
                FROM events
                WHERE timestamp >= ?2 AND timestamp < ?3
                GROUP BY 1
                "#,
            )
            .map_err(|error| format!("无法准备 365 日精确 token 汇总：{error}"))?;
        let rows = statement
            .query_map(params![offset_seconds, start_unix, end_unix], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })
            .map_err(|error| format!("无法读取 365 日精确 token 汇总：{error}"))?;
        for row in rows {
            let (date, tokens, calls, input, cached) =
                row.map_err(|error| format!("无法解码 365 日精确 token 汇总：{error}"))?;
            grouped.insert(date, (tokens, calls, input, cached));
        }

        Ok((0..365)
            .map(|offset| {
                let day = start_day + Duration::days(offset);
                let date = format_date(day);
                let (tokens, calls, input, cached) = grouped.remove(&date).unwrap_or((0, 0, 0, 0));
                ActivityDay {
                    date,
                    tokens: nonnegative_u64(tokens),
                    calls: saturating_u32(calls),
                    cache_hit_rate: cache_hit_rate(input, cached),
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
        local_offset: UtcOffset,
    ) -> Result<DashboardStats, String> {
        let row = self
            .connection
            .query_row(
                r#"
                SELECT
                    COALESCE(SUM(tokens), 0),
                    COUNT(*),
                    COUNT(DISTINCT session_id),
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(MIN(cached_input_tokens, input_tokens)), 0),
                    COALESCE(SUM(output_tokens), 0),
                    MIN(timestamp)
                FROM events
                "#,
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, Option<i64>>(6)?,
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
                    SELECT SUM(tokens) AS total
                    FROM events
                    GROUP BY session_id
                )
                "#,
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("无法读取精确 token 会话峰值：{error}"))?;
        let today = now_utc.to_offset(local_offset).date();

        Ok(DashboardStats {
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
            first_usage_at: row.6.and_then(format_rfc3339_unix),
        })
    }

    fn usage_series(
        &self,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
        interval_seconds: i64,
        point_count: i64,
    ) -> Result<Vec<RecentUsagePoint>, String> {
        let bin_starts =
            aligned_bin_starts(now_utc.unix_timestamp(), interval_seconds, point_count);
        let start = *bin_starts.first().unwrap_or(&now_utc.unix_timestamp());
        let end = bin_starts
            .last()
            .copied()
            .unwrap_or(now_utc.unix_timestamp())
            .saturating_add(interval_seconds);
        let mut grouped = HashMap::new();
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    timestamp - (timestamp % ?1),
                    COALESCE(SUM(tokens), 0),
                    COUNT(*),
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(MIN(cached_input_tokens, input_tokens)), 0),
                    COALESCE(SUM(output_tokens), 0)
                FROM events
                WHERE timestamp >= ?2 AND timestamp < ?3
                GROUP BY 1
                "#,
            )
            .map_err(|error| format!("无法准备精确 token 时间序列：{error}"))?;
        let rows = statement
            .query_map(params![interval_seconds, start, end], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            })
            .map_err(|error| format!("无法读取精确 token 时间序列：{error}"))?;
        for row in rows {
            let (bin, tokens, calls, input, cached, output) =
                row.map_err(|error| format!("无法解码精确 token 时间序列：{error}"))?;
            grouped.insert(bin, (tokens, calls, input, cached, output));
        }

        Ok(bin_starts
            .into_iter()
            .map(|start_unix| {
                let (tokens, calls, input, cached, output) =
                    grouped.remove(&start_unix).unwrap_or((0, 0, 0, 0, 0));
                let timestamp = OffsetDateTime::from_unix_timestamp(start_unix)
                    .unwrap_or(OffsetDateTime::UNIX_EPOCH)
                    .to_offset(local_offset);
                RecentUsagePoint {
                    label: timestamp
                        .format(format_description!("[hour]:[minute]"))
                        .unwrap_or_else(|_| "00:00".into()),
                    start_unix,
                    tokens: nonnegative_u64(tokens),
                    calls: saturating_u32(calls),
                    input_tokens: nonnegative_u64(input),
                    cached_input_tokens: nonnegative_u64(cached),
                    output_tokens: nonnegative_u64(output),
                    cache_hit_rate: (input > 0).then(|| cache_hit_rate(input, cached)),
                    five_hour_remaining_percent: None,
                    seven_day_remaining_percent: None,
                }
            })
            .collect())
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
                    e.session_id,
                    COUNT(*) AS calls,
                    SUM(e.input_tokens) AS input_tokens,
                    SUM(MIN(e.cached_input_tokens, e.input_tokens)) AS cached_tokens,
                    COALESCE(m.updated_at, MAX(e.timestamp)) AS updated_at,
                    COALESCE(NULLIF(TRIM(m.title), ''), '会话 ' || SUBSTR(e.session_id, 1, 8)) AS title
                FROM events e
                LEFT JOIN session_metadata m ON m.session_id = e.session_id
                GROUP BY e.session_id
                HAVING calls > 1 AND input_tokens >= ?1
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
    ) -> Result<TokenCacheUsage, String> {
        let sessions = self.session_candidates()?;
        let turns = self.turn_candidates(codex_home, warnings)?;
        Ok(TokenCacheUsage { sessions, turns })
    }

    fn session_candidates(&self) -> Result<Vec<SessionCacheUsage>, String> {
        let mut selected_ids = HashSet::new();
        let mut selected = Vec::new();
        for (multi_turn_only, latest_first) in
            [(true, false), (true, true), (false, false), (false, true)]
        {
            for item in self.query_session_candidates(multi_turn_only, latest_first)? {
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
    ) -> Result<Vec<SessionCacheUsage>, String> {
        let turn_predicate = if multi_turn_only { "AND calls > 1" } else { "" };
        let ordering = if latest_first {
            "ORDER BY updated_at IS NULL, updated_at DESC, hit_rate ASC, uncached DESC, input_tokens DESC, session_id ASC"
        } else {
            "ORDER BY hit_rate ASC, uncached DESC, input_tokens DESC, updated_at DESC, session_id ASC"
        };
        let sql = format!(
            r#"
            WITH session_rows AS (
                SELECT
                    e.session_id,
                    COUNT(*) AS calls,
                    SUM(e.tokens) AS total_tokens,
                    SUM(e.input_tokens) AS input_tokens,
                    SUM(MIN(e.cached_input_tokens, e.input_tokens)) AS cached_tokens,
                    SUM(e.output_tokens) AS output_tokens,
                    COALESCE(m.updated_at, MAX(e.timestamp)) AS updated_at,
                    COALESCE(NULLIF(TRIM(m.title), ''), '会话 ' || SUBSTR(e.session_id, 1, 8)) AS title
                FROM events e
                LEFT JOIN session_metadata m ON m.session_id = e.session_id
                GROUP BY e.session_id
            )
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
            FROM session_rows
            WHERE calls > 0 AND input_tokens >= ?1 {turn_predicate}
            {ordering}
            LIMIT ?2
            "#
        );
        let mut statement = self
            .connection
            .prepare(&sql)
            .map_err(|error| format!("无法准备会话缓存候选：{error}"))?;
        let rows = statement
            .query_map(
                params![CACHE_USAGE_MIN_INPUT_TOKENS, CACHE_USAGE_CANDIDATE_LIMIT],
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

    fn turn_candidates(
        &self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<Vec<TurnCacheUsage>, String> {
        let mut selected_ids = HashSet::new();
        let mut selected = Vec::new();
        for (later_turn_only, latest_first) in
            [(true, false), (true, true), (false, false), (false, true)]
        {
            for item in self.query_turn_candidates(later_turn_only, latest_first)? {
                if selected_ids.insert(item.usage.id.clone()) {
                    selected.push(item);
                }
            }
        }

        let canonical_home = canonical_codex_home(codex_home)?;
        Ok(selected
            .into_iter()
            .map(|mut item| {
                let Some(file) = resolve_file_within_codex_home(
                    &canonical_home,
                    &item.file_path,
                    "缓存排行摘录",
                    warnings,
                ) else {
                    return item.usage;
                };
                let before = match file_signature(&file) {
                    Ok(signature) => signature,
                    Err(error) => {
                        warnings.push(excerpt_warning(error));
                        return item.usage;
                    }
                };
                if !before.matches_stored(
                    item.file_size,
                    &item.file_modified_ns,
                    &item.file_device_id,
                    &item.file_id,
                    &item.file_changed_ns,
                ) {
                    warnings.push(excerpt_warning(format!(
                        "会话摘录源文件已在索引后变化，将在下一次刷新重建：{}",
                        file.display()
                    )));
                    return item.usage;
                }
                match read_event_excerpts(&file, item.source_offsets) {
                    Ok((user_prompt, assistant_response)) => match file_signature(&file) {
                        Ok(after) if after == before => {
                            item.usage.user_prompt = user_prompt;
                            item.usage.assistant_response = assistant_response;
                        }
                        Ok(_) => warnings.push(excerpt_warning(format!(
                            "会话摘录源文件在读取期间变化，将在下一次刷新重建：{}",
                            file.display()
                        ))),
                        Err(error) => warnings.push(excerpt_warning(error)),
                    },
                    Err(error) => warnings.push(excerpt_warning(error)),
                }
                item.usage
            })
            .collect())
    }

    fn query_turn_candidates(
        &self,
        later_turn_only: bool,
        latest_first: bool,
    ) -> Result<Vec<IndexedTurnCandidate>, String> {
        let turn_predicate = if later_turn_only {
            "AND turn_index_in_session > 1"
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
            WITH ordered_turns AS (
                SELECT
                    e.*,
                    ROW_NUMBER() OVER (
                        PARTITION BY e.session_id
                        ORDER BY e.timestamp ASC, e.file_path ASC, e.ordinal ASC
                    ) AS turn_index_in_session
                FROM events e
            ),
            turn_rows AS (
                SELECT
                    t.*,
                    COALESCE(NULLIF(TRIM(m.title), ''), '会话 ' || SUBSTR(t.session_id, 1, 8)) AS title,
                    CASE WHEN t.input_tokens > 0
                        THEN MIN(t.cached_input_tokens, t.input_tokens) * 1.0 / t.input_tokens
                        ELSE 0
                    END AS hit_rate,
                    t.input_tokens - MIN(t.cached_input_tokens, t.input_tokens) AS uncached
                FROM ordered_turns t
                LEFT JOIN session_metadata m ON m.session_id = t.session_id
            )
            SELECT
                id,
                file_path,
                ordinal,
                timestamp,
                session_id,
                tokens,
                input_tokens,
                MIN(cached_input_tokens, input_tokens),
                output_tokens,
                user_prompt_start,
                user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                turn_index_in_session,
                title,
                (SELECT size FROM files f WHERE f.path = turn_rows.file_path),
                (SELECT modified_ns FROM files f WHERE f.path = turn_rows.file_path),
                (SELECT device_id FROM files f WHERE f.path = turn_rows.file_path),
                (SELECT file_id FROM files f WHERE f.path = turn_rows.file_path),
                (SELECT changed_ns FROM files f WHERE f.path = turn_rows.file_path)
            FROM turn_rows
            WHERE input_tokens >= ?1 {turn_predicate}
            {ordering}
            LIMIT ?2
            "#
        );
        let mut statement = self
            .connection
            .prepare(&sql)
            .map_err(|error| format!("无法准备轮次缓存候选：{error}"))?;
        let rows = statement
            .query_map(
                params![CACHE_USAGE_MIN_INPUT_TOKENS, CACHE_USAGE_CANDIDATE_LIMIT],
                |row| {
                    let event_id = row.get::<_, i64>(0)?;
                    let timestamp = row.get::<_, i64>(3)?;
                    let session_id = row.get::<_, String>(4)?;
                    Ok(IndexedTurnCandidate {
                        file_path: PathBuf::from(row.get::<_, String>(1)?),
                        file_size: nonnegative_u64(row.get::<_, i64>(15)?),
                        file_modified_ns: row.get(16)?,
                        file_device_id: row.get(17)?,
                        file_id: row.get(18)?,
                        file_changed_ns: row.get(19)?,
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

struct SqliteEventSink<'transaction> {
    transaction: &'transaction Transaction<'transaction>,
    file_path: &'transaction str,
    ordinal: u64,
}

impl ExactSessionEventSink for SqliteEventSink<'_> {
    fn insert_fingerprint(
        &mut self,
        fingerprint: &UsageSnapshotFingerprint,
    ) -> Result<bool, String> {
        let mut encoded = [0_u8; 9 * 8];
        for (index, value) in fingerprint.iter().enumerate() {
            let start = index * 8;
            encoded[start..start + 8].copy_from_slice(&value.to_le_bytes());
        }
        self.transaction
            .execute(
                "INSERT OR IGNORE INTO exact_fingerprints(fingerprint) VALUES (?1)",
                params![encoded.as_slice()],
            )
            .map(|changed| changed > 0)
            .map_err(|error| format!("无法写入精确 token 去重索引：{error}"))
    }

    fn insert_event(&mut self, event: &ExactTokenEvent) -> Result<(), String> {
        self.ordinal = self.ordinal.saturating_add(1);
        let user_prompt_start = checked_optional_i64(
            event.source_offsets.user_prompt.map(|range| range.start),
            "用户问题起始位置",
        )?;
        let user_prompt_end = checked_optional_i64(
            event.source_offsets.user_prompt.map(|range| range.end),
            "用户问题结束位置",
        )?;
        let assistant_response_start = checked_optional_i64(
            event
                .source_offsets
                .assistant_response
                .map(|range| range.start),
            "回答起始位置",
        )?;
        let assistant_response_end = checked_optional_i64(
            event
                .source_offsets
                .assistant_response
                .map(|range| range.end),
            "回答结束位置",
        )?;
        self.transaction
            .execute(
                r#"
                INSERT INTO events(
                    file_path,
                    ordinal,
                    timestamp,
                    session_id,
                    tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                "#,
                params![
                    self.file_path,
                    checked_i64(self.ordinal, "事件序号")?,
                    event.timestamp.unix_timestamp(),
                    event.session_id,
                    checked_i64(event.tokens, "token 总数")?,
                    checked_i64(event.input_tokens, "输入 token")?,
                    checked_i64(event.cached_input_tokens, "缓存输入 token")?,
                    checked_i64(event.output_tokens, "输出 token")?,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end,
                ],
            )
            .map_err(|error| format!("无法写入精确 token 事件索引：{error}"))?;
        Ok(())
    }
}

fn process_session_file(
    transaction: &Transaction<'_>,
    codex_home: &Path,
    file: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<bool, String> {
    let canonical = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    let path = canonical.to_string_lossy().into_owned();
    let newly_seen = transaction
        .execute(
            "INSERT OR IGNORE INTO exact_seen_files(path) VALUES (?1)",
            params![path],
        )
        .map_err(|error| format!("无法记录会话文件扫描状态：{error}"))?
        > 0;
    if !newly_seen {
        return Ok(false);
    }

    let mut handle = fs::File::open(file)
        .map_err(|error| format!("读取会话文件失败：{}（{}）", file.display(), error))?;
    let signature = file_signature_from_handle(&handle, file)?;
    let unchanged = transaction
        .query_row(
            "SELECT size, modified_ns, device_id, file_id, changed_ns FROM files WHERE path = ?1",
            params![path],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            },
        )
        .optional()
        .map_err(|error| format!("无法读取会话文件索引签名：{error}"))?
        .is_some_and(|(size, modified_ns, device_id, file_id, changed_ns)| {
            signature.matches_stored(
                nonnegative_u64(size),
                &modified_ns,
                &device_id,
                &file_id,
                &changed_ns,
            )
        });
    if unchanged {
        return Ok(false);
    }

    transaction
        .execute("DELETE FROM events WHERE file_path = ?1", params![path])
        .map_err(|error| format!("无法清理变更会话的旧 token 索引：{error}"))?;
    transaction
        .execute("DELETE FROM files WHERE path = ?1", params![path])
        .map_err(|error| format!("无法清理变更会话的旧文件索引：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO files(
                path,
                session_id,
                size,
                modified_ns,
                device_id,
                file_id,
                changed_ns,
                prefix_sha256
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, X'')
            "#,
            params![
                path,
                session_id_from_file(file),
                checked_i64(signature.size, "会话文件大小")?,
                signature.modified_ns.to_string(),
                signature.identity.device_id.to_string(),
                signature.identity.file_id.to_string(),
                signature.changed_ns.to_string(),
            ],
        )
        .map_err(|error| format!("无法登记会话文件索引：{error}"))?;
    transaction
        .execute("DELETE FROM exact_fingerprints", [])
        .map_err(|error| format!("无法重置会话 token 去重表：{error}"))?;

    let session_id = session_id_from_file(file);
    let mut sink = SqliteEventSink {
        transaction,
        file_path: &path,
        ordinal: 0,
    };
    let parsed = stream_session_file_exact(
        file,
        &mut handle,
        signature.size,
        &session_id,
        &mut sink,
        warnings,
    )?;
    debug_assert_eq!(parsed.bytes_read, signature.size);

    run_after_prefix_scan_hook_for_testing(file);
    validate_same_file_prefix(file, &mut handle, signature, parsed.prefix_sha256).map_err(
        |reason| {
            format!(
                "会话文件在精确扫描期间发生非追加变化，将在下一次刷新重试：{}（{}）",
                relative_display_path(codex_home, file),
                reason
            )
        },
    )?;
    transaction
        .execute(
            "UPDATE files SET prefix_sha256 = ?2 WHERE path = ?1",
            params![path, parsed.prefix_sha256.as_slice()],
        )
        .map_err(|error| format!("无法保存会话文件前缀校验值：{error}"))?;

    if parsed.bytes_read != signature.size {
        return Err(format!(
            "会话文件固定前缀未完整扫描，将在下一次刷新重试：{}",
            relative_display_path(codex_home, file)
        ));
    }
    Ok(true)
}

fn visit_session_files(
    transaction: &Transaction<'_>,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    mut visit: impl FnMut(&Transaction<'_>, &Path, &mut Vec<LocalDataWarning>) -> Result<(), String>,
) -> Result<(), String> {
    super::record_dashboard_source_scan_for_testing();
    let canonical_home = canonical_codex_home(codex_home)?;
    let sessions_root = codex_home.join("sessions");
    if sessions_root.exists() {
        let mut directories = vec![sessions_root];
        while let Some(directory) = directories.pop() {
            let canonical = match fs::canonicalize(&directory) {
                Ok(canonical) if canonical.starts_with(&canonical_home) => canonical,
                Ok(canonical) => {
                    warnings.push(scan_warning(format!(
                        "拒绝读取 Codex Home 外的会话目录：{} -> {}",
                        directory.display(),
                        canonical.display()
                    )));
                    continue;
                }
                Err(error) => {
                    warnings.push(scan_warning(format!(
                        "无法确认会话目录边界：{}（{}）",
                        directory.display(),
                        error
                    )));
                    continue;
                }
            };
            let directory_key = canonical.to_string_lossy();
            let newly_seen = transaction
                .execute(
                    "INSERT OR IGNORE INTO exact_seen_directories(path) VALUES (?1)",
                    params![directory_key.as_ref()],
                )
                .map_err(|error| format!("无法记录会话目录扫描状态：{error}"))?
                > 0;
            if !newly_seen {
                continue;
            }
            let entries = fs::read_dir(&directory).map_err(|error| {
                let message = format!("读取会话目录失败：{}（{}）", directory.display(), error);
                warnings.push(scan_warning(message.clone()));
                message
            })?;
            for entry in entries {
                let entry = entry.map_err(|error| {
                    let message =
                        format!("读取会话目录项失败：{}（{}）", directory.display(), error);
                    warnings.push(scan_warning(message.clone()));
                    message
                })?;
                let path = entry.path();
                let metadata = fs::symlink_metadata(&path).map_err(|error| {
                    let message =
                        format!("读取会话目录项元数据失败：{}（{}）", path.display(), error);
                    warnings.push(scan_warning(message.clone()));
                    message
                })?;
                if metadata.file_type().is_dir() {
                    directories.push(path);
                } else if path
                    .extension()
                    .is_some_and(|extension| extension == "jsonl")
                {
                    if let Some(file) =
                        resolve_file_within_codex_home(&canonical_home, &path, "会话目录", warnings)
                    {
                        visit(transaction, &file, warnings)?;
                    }
                }
            }
        }
    } else {
        warnings.push(scan_warning(format!(
            "会话目录不存在：{}",
            sessions_root.display()
        )));
    }

    visit_active_rollouts(transaction, codex_home, &canonical_home, warnings, visit)
}

fn visit_active_rollouts(
    transaction: &Transaction<'_>,
    codex_home: &Path,
    canonical_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    mut visit: impl FnMut(&Transaction<'_>, &Path, &mut Vec<LocalDataWarning>) -> Result<(), String>,
) -> Result<(), String> {
    let database = codex_home.join("state_5.sqlite");
    if !database.exists() {
        return Ok(());
    }
    let connection =
        sqlite::open_read_only(&database, StdDuration::from_millis(100)).map_err(|error| {
            let message = format!(
                "读取 active rollout 索引失败：{}（{}）",
                database.display(),
                error
            );
            warnings.push(scan_warning(message.clone()));
            message
        })?;
    if !column_exists(&connection, "threads", "rollout_path") {
        return Ok(());
    }
    let archived_filter = if column_exists(&connection, "threads", "archived") {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let sql = format!(
        "SELECT rollout_path FROM threads WHERE {archived_filter} AND rollout_path IS NOT NULL AND rollout_path <> ''"
    );
    let mut statement = connection
        .prepare(&sql)
        .map_err(|error| format!("读取 active rollout 路径失败：{error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("读取 active rollout 路径失败：{error}"))?;
    for row in rows {
        let raw = row.map_err(|error| format!("读取 active rollout 路径失败：{error}"))?;
        let path = {
            let path = PathBuf::from(raw);
            if path.is_absolute() {
                path
            } else {
                codex_home.join(path)
            }
        };
        if path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
        {
            if let Some(file) =
                resolve_file_within_codex_home(canonical_home, &path, "active rollout", warnings)
            {
                visit(transaction, &file, warnings)?;
            }
        }
    }
    Ok(())
}

fn sync_thread_metadata(
    transaction: &Transaction<'_>,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<bool, String> {
    let database = codex_home.join("state_5.sqlite");
    let signature = if database.is_file() {
        Some(file_signature(&database)?)
    } else {
        None
    };
    let previous = (
        metadata_text(transaction, "state_size")?,
        metadata_text(transaction, "state_modified_ns")?,
    );
    let current = signature.map(|value| (value.size.to_string(), value.modified_ns.to_string()));
    if previous == current.clone().unzip() {
        return Ok(false);
    }

    transaction
        .execute("DELETE FROM session_metadata", [])
        .map_err(|error| format!("无法刷新会话标题索引：{error}"))?;
    if let Some((size, modified_ns)) = current {
        match sqlite::open_read_only(&database, StdDuration::from_secs(3)) {
            Ok(connection) => match connection.prepare(
                r#"
                SELECT id, title, first_user_message, preview, COALESCE(updated_at_ms, updated_at)
                FROM threads
                "#,
            ) {
                Ok(mut statement) => {
                    let rows = statement
                        .query_map([], |row| {
                            Ok((
                                row.get::<_, String>(0)?,
                                first_non_empty([
                                    row.get::<_, Option<String>>(1)?,
                                    row.get::<_, Option<String>>(2)?,
                                    row.get::<_, Option<String>>(3)?,
                                ])
                                .unwrap_or_else(|| "Untitled".into()),
                                row.get::<_, Option<i64>>(4)?
                                    .map(normalize_thread_timestamp),
                            ))
                        })
                        .map_err(|error| format!("读取会话标题索引失败：{error}"))?;
                    for row in rows {
                        let (session_id, title, updated_at) =
                            row.map_err(|error| format!("读取会话标题索引失败：{error}"))?;
                        transaction
                            .execute(
                                "INSERT OR REPLACE INTO session_metadata(session_id, title, updated_at) VALUES (?1, ?2, ?3)",
                                params![session_id, title, updated_at],
                            )
                            .map_err(|error| format!("写入会话标题索引失败：{error}"))?;
                    }
                }
                Err(error) => warnings.push(thread_info_warning(format!(
                    "读取会话标题索引结构失败：{}（{}）",
                    database.display(),
                    error
                ))),
            },
            Err(error) => warnings.push(thread_info_warning(format!(
                "读取会话标题索引失败：{}（{}）",
                database.display(),
                error
            ))),
        }
        set_metadata(transaction, "state_size", &size)?;
        set_metadata(transaction, "state_modified_ns", &modified_ns)?;
    } else {
        transaction
            .execute(
                "DELETE FROM metadata WHERE key IN ('state_size', 'state_modified_ns')",
                [],
            )
            .map_err(|error| format!("无法清理会话标题索引签名：{error}"))?;
    }
    Ok(true)
}

fn existing_regular_index(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝打开符号链接形式的精确 token 索引：{}",
            path.display()
        )),
        Ok(metadata) if !metadata.is_file() => Err(format!(
            "精确 token 索引路径不是普通文件：{}",
            path.display()
        )),
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!(
            "无法检查精确 token 索引路径 {}：{}",
            path.display(),
            error
        )),
    }
}

fn open_index_connection_with_recovery(
    path: &Path,
    existed_before: bool,
) -> Result<(Connection, bool), String> {
    if !existed_before {
        return open_index_connection(path).map(|connection| (connection, false));
    }

    let integrity_failure = match open_index_connection(path) {
        Ok(connection) => match quick_check_index(&connection) {
            Ok(()) => return Ok((connection, false)),
            Err(error) => {
                drop(connection);
                error
            }
        },
        Err(error) => error,
    };

    remove_index_storage(path).map_err(|rebuild_error| {
        format!(
            "精确 token 索引完整性检查失败，且无法移除损坏索引：{integrity_failure}；{rebuild_error}"
        )
    })?;
    open_index_connection(path)
        .map(|connection| (connection, true))
        .map_err(|rebuild_error| {
            format!(
                "精确 token 索引完整性检查失败，自动重建也失败：{integrity_failure}；{rebuild_error}"
            )
        })
}

fn quick_check_index(connection: &Connection) -> Result<(), String> {
    let result = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法完成 SQLite quick_check：{error}"))?;
    if result.eq_ignore_ascii_case("ok") {
        Ok(())
    } else {
        Err(format!("SQLite quick_check 报告损坏：{result}"))
    }
}

fn open_index_connection(path: &Path) -> Result<Connection, String> {
    let connection = Connection::open(path)
        .map_err(|error| format!("无法打开精确 token 索引 {}：{}", path.display(), error))?;
    connection
        .busy_timeout(StdDuration::from_secs(30))
        .map_err(|error| format!("无法设置精确 token 索引等待时间：{error}"))?;
    connection
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA temp_store = FILE;
            PRAGMA cache_size = -8192;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;
            "#,
        )
        .map_err(|error| format!("无法初始化精确 token 索引连接：{error}"))?;
    Ok(connection)
}

fn initialize_index_schema(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_ns TEXT NOT NULL,
                device_id TEXT NOT NULL,
                file_id TEXT NOT NULL,
                changed_ns TEXT NOT NULL,
                prefix_sha256 BLOB NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY,
                file_path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                session_id TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                UNIQUE(file_path, ordinal)
            );

            CREATE INDEX IF NOT EXISTS events_timestamp_idx
                ON events(timestamp);
            CREATE INDEX IF NOT EXISTS events_session_idx
                ON events(session_id, timestamp, file_path, ordinal);

            CREATE TABLE IF NOT EXISTS session_metadata (
                session_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                updated_at INTEGER
            ) WITHOUT ROWID;
            "#,
        )
        .map_err(|error| format!("无法初始化精确 token 索引结构：{error}"))
}

fn remove_index_storage(path: &Path) -> Result<(), String> {
    let mut existing = Vec::new();
    for candidate in [
        path.to_path_buf(),
        sqlite_sidecar_path(path, "-wal"),
        sqlite_sidecar_path(path, "-shm"),
    ] {
        match fs::symlink_metadata(&candidate) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(format!(
                    "拒绝删除符号链接形式的旧精确 token 索引：{}",
                    candidate.display()
                ));
            }
            Ok(metadata) if !metadata.is_file() => {
                return Err(format!(
                    "旧精确 token 索引路径不是普通文件：{}",
                    candidate.display()
                ));
            }
            Ok(_) => existing.push(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "无法检查旧精确 token 索引 {}：{}",
                    candidate.display(),
                    error
                ));
            }
        }
    }
    for candidate in existing {
        fs::remove_file(&candidate).map_err(|error| {
            format!(
                "无法移除旧精确 token 索引 {}：{}",
                candidate.display(),
                error
            )
        })?;
    }
    Ok(())
}

fn sqlite_sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

fn database_path(codex_home: &Path) -> Result<PathBuf, String> {
    #[cfg(test)]
    {
        return Ok(codex_home
            .join(".codex-token-bar-test-cache")
            .join("exact-token-index.sqlite3"));
    }

    #[cfg(not(test))]
    let root = app_paths::tauri_usage_cache_dir()
        .ok_or_else(|| "无法定位 Tauri 用量缓存目录".to_string())?;
    #[cfg(not(test))]
    Ok(root
        .join("exact-token-index")
        .join(format!("{}.sqlite3", stable_path_fingerprint(codex_home))))
}

fn canonical_codex_home(codex_home: &Path) -> Result<PathBuf, String> {
    fs::canonicalize(codex_home).map_err(|error| {
        format!(
            "无法确认所选 Codex Home 的物理边界：{}（{}）",
            codex_home.display(),
            error
        )
    })
}

fn resolve_file_within_codex_home(
    canonical_home: &Path,
    candidate: &Path,
    source: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> Option<PathBuf> {
    let canonical = match fs::canonicalize(candidate) {
        Ok(canonical) => canonical,
        Err(error) => {
            warnings.push(scan_warning(format!(
                "无法确认 {source} 会话文件边界：{}（{}）",
                candidate.display(),
                error
            )));
            return None;
        }
    };
    if !canonical.starts_with(canonical_home) {
        warnings.push(scan_warning(format!(
            "拒绝读取 Codex Home 外的 {source} 会话文件：{} -> {}",
            candidate.display(),
            canonical.display()
        )));
        return None;
    }
    let is_jsonl_file = fs::metadata(&canonical).is_ok_and(|metadata| metadata.is_file())
        && canonical
            .extension()
            .is_some_and(|extension| extension == "jsonl");
    if !is_jsonl_file {
        warnings.push(scan_warning(format!(
            "拒绝读取非 JSONL 普通文件：{}",
            canonical.display()
        )));
        return None;
    }
    Some(canonical)
}

#[cfg(not(test))]
fn stable_path_fingerprint(path: &Path) -> String {
    let identity = codex_home_identity(path);
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in identity.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn codex_home_identity(path: &Path) -> String {
    fs::canonicalize(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

impl FileSignature {
    fn matches_stored(
        self,
        size: u64,
        modified_ns: &str,
        device_id: &str,
        file_id: &str,
        changed_ns: &str,
    ) -> bool {
        size == self.size
            && modified_ns.parse::<u128>().ok() == Some(self.modified_ns)
            && device_id.parse::<u64>().ok() == Some(self.identity.device_id)
            && file_id.parse::<u64>().ok() == Some(self.identity.file_id)
            && changed_ns.parse::<i128>().ok() == Some(self.changed_ns)
    }

    fn has_same_identity(self, other: Self) -> bool {
        self.identity == other.identity
    }
}

fn file_signature(path: &Path) -> Result<FileSignature, String> {
    let handle = fs::File::open(path)
        .map_err(|error| format!("打开会话文件失败：{}（{}）", path.display(), error))?;
    file_signature_from_handle(&handle, path)
}

fn file_signature_from_handle(handle: &fs::File, path: &Path) -> Result<FileSignature, String> {
    let metadata = handle
        .metadata()
        .map_err(|error| format!("读取会话文件元数据失败：{}（{}）", path.display(), error))?;
    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let modified_ns = modified
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let (identity, changed_ns) = platform_file_identity(handle, &metadata, path)?;
    Ok(FileSignature {
        size: metadata.len(),
        modified_ns,
        identity,
        changed_ns,
    })
}

#[cfg(unix)]
fn platform_file_identity(
    _handle: &fs::File,
    metadata: &fs::Metadata,
    _path: &Path,
) -> Result<(FileIdentity, i128), String> {
    use std::os::unix::fs::MetadataExt;

    let changed_ns = i128::from(metadata.ctime())
        .saturating_mul(1_000_000_000)
        .saturating_add(i128::from(metadata.ctime_nsec()));
    Ok((
        FileIdentity {
            device_id: metadata.dev(),
            file_id: metadata.ino(),
        },
        changed_ns,
    ))
}

#[cfg(windows)]
fn platform_file_identity(
    handle: &fs::File,
    _metadata: &fs::Metadata,
    path: &Path,
) -> Result<(FileIdentity, i128), String> {
    use std::mem::MaybeUninit;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::Storage::FileSystem::{
        FileBasicInfo, GetFileInformationByHandle, GetFileInformationByHandleEx,
        BY_HANDLE_FILE_INFORMATION, FILE_BASIC_INFO,
    };

    let raw_handle = handle.as_raw_handle() as HANDLE;
    let mut identity_info = MaybeUninit::<BY_HANDLE_FILE_INFORMATION>::zeroed();
    if unsafe { GetFileInformationByHandle(raw_handle, identity_info.as_mut_ptr()) } == 0 {
        return Err(format!(
            "读取会话文件 Windows 身份失败：{}（{}）",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let identity_info = unsafe { identity_info.assume_init() };

    let mut basic_info = MaybeUninit::<FILE_BASIC_INFO>::zeroed();
    if unsafe {
        GetFileInformationByHandleEx(
            raw_handle,
            FileBasicInfo,
            basic_info.as_mut_ptr().cast(),
            std::mem::size_of::<FILE_BASIC_INFO>() as u32,
        )
    } == 0
    {
        return Err(format!(
            "读取会话文件 Windows 变更时间失败：{}（{}）",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let basic_info = unsafe { basic_info.assume_init() };
    let file_id =
        (u64::from(identity_info.nFileIndexHigh) << 32) | u64::from(identity_info.nFileIndexLow);
    Ok((
        FileIdentity {
            device_id: u64::from(identity_info.dwVolumeSerialNumber),
            file_id,
        },
        i128::from(basic_info.ChangeTime).saturating_mul(100),
    ))
}

#[cfg(not(any(unix, windows)))]
fn platform_file_identity(
    _handle: &fs::File,
    metadata: &fs::Metadata,
    _path: &Path,
) -> Result<(FileIdentity, i128), String> {
    let changed_ns = metadata
        .modified()
        .unwrap_or(SystemTime::UNIX_EPOCH)
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .min(i128::MAX as u128) as i128;
    Ok((
        FileIdentity {
            device_id: 0,
            file_id: 0,
        },
        changed_ns,
    ))
}

fn validate_same_file_prefix(
    path: &Path,
    handle: &mut fs::File,
    start_signature: FileSignature,
    scanned_hash: [u8; 32],
) -> Result<(), String> {
    let handle_before = file_signature_from_handle(handle, path)?;
    let path_before = file_signature(path)?;
    validate_prefix_identity(start_signature, handle_before, path_before)?;

    let current_hash = hash_file_prefix(handle, start_signature.size, path)?;

    let handle_after = file_signature_from_handle(handle, path)?;
    let path_after = file_signature(path)?;
    validate_prefix_identity(start_signature, handle_after, path_after)?;
    if current_hash != scanned_hash {
        return Err("扫描起点内的既有字节被改写".into());
    }
    Ok(())
}

fn validate_prefix_identity(
    start: FileSignature,
    handle: FileSignature,
    path: FileSignature,
) -> Result<(), String> {
    if !start.has_same_identity(handle) || !start.has_same_identity(path) {
        return Err("文件身份（设备号/文件号）已变化".into());
    }
    if handle.size < start.size || path.size < start.size {
        return Err("文件已截断到扫描起点之前".into());
    }
    Ok(())
}

fn hash_file_prefix(
    handle: &mut fs::File,
    prefix_size: u64,
    path: &Path,
) -> Result<[u8; 32], String> {
    handle.seek(SeekFrom::Start(0)).map_err(|error| {
        format!(
            "无法定位会话文件前缀以完成一致性校验：{}（{}）",
            path.display(),
            error
        )
    })?;
    let mut remaining = prefix_size;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    while remaining > 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64)).unwrap_or(buffer.len());
        let bytes_read = handle
            .read(&mut buffer[..requested])
            .map_err(|error| format!("复核会话文件前缀失败：{}（{}）", path.display(), error))?;
        if bytes_read == 0 {
            return Err(format!(
                "复核会话文件前缀时提前到达结尾：{}（尚缺 {} 字节）",
                path.display(),
                remaining
            ));
        }
        hasher.update(&buffer[..bytes_read]);
        remaining = remaining.saturating_sub(bytes_read as u64);
    }
    Ok(hasher.finalize().into())
}

#[cfg(test)]
fn run_after_prefix_scan_hook_for_testing(path: &Path) {
    let hook = AFTER_PREFIX_SCAN_HOOK.with(|slot| slot.borrow_mut().take());
    if let Some(hook) = hook {
        hook(path);
    }
}

#[cfg(not(test))]
fn run_after_prefix_scan_hook_for_testing(_path: &Path) {}

fn fresh_revision_seed() -> i64 {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    i64::try_from(nanos.min(i64::MAX as u128)).unwrap_or(i64::MAX - 1)
}

fn metadata_text(connection: &Connection, key: &str) -> Result<Option<String>, String> {
    connection
        .query_row(
            "SELECT value FROM metadata WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| format!("无法读取精确 token 索引元数据 {key}：{error}"))
}

fn metadata_i64(connection: &Connection, key: &str) -> Result<Option<i64>, String> {
    Ok(metadata_text(connection, key)?.and_then(|value| value.parse().ok()))
}

fn set_metadata(connection: &Connection, key: &str, value: &str) -> Result<(), String> {
    connection
        .execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES (?1, ?2)",
            params![key, value],
        )
        .map(|_| ())
        .map_err(|error| format!("无法写入精确 token 索引元数据 {key}：{error}"))
}

fn checked_i64(value: u64, label: &str) -> Result<i64, String> {
    i64::try_from(value).map_err(|_| format!("{label}超出 SQLite 精确整数范围"))
}

fn checked_optional_i64(value: Option<u64>, label: &str) -> Result<Option<i64>, String> {
    value.map(|value| checked_i64(value, label)).transpose()
}

fn source_range_from_columns(start: Option<i64>, end: Option<i64>) -> Option<SourceByteRange> {
    let start = u64::try_from(start?).ok()?;
    let end = u64::try_from(end?).ok()?;
    (end >= start).then_some(SourceByteRange { start, end })
}

fn nonnegative_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

fn saturating_u32(value: i64) -> u32 {
    if value <= 0 {
        0
    } else {
        u32::try_from(value).unwrap_or(u32::MAX)
    }
}

fn cache_hit_rate(input: i64, cached: i64) -> f64 {
    if input <= 0 {
        0.0
    } else {
        (cached.max(0).min(input) as f64 / input as f64).clamp(0.0, 1.0)
    }
}

fn local_day_bounds(date: Date, offset: UtcOffset) -> Result<(i64, i64), String> {
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

fn format_rfc3339_unix(timestamp: i64) -> Option<String> {
    OffsetDateTime::from_unix_timestamp(timestamp)
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

fn column_exists(connection: &Connection, table: &str, column: &str) -> bool {
    let Ok(mut statement) = connection.prepare(&format!("PRAGMA table_info({table})")) else {
        return false;
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(1)) else {
        return false;
    };
    let exists = rows.filter_map(Result::ok).any(|name| name == column);
    exists
}

fn first_non_empty(values: [Option<String>; 3]) -> Option<String> {
    values.into_iter().find_map(|value| {
        let trimmed = value?.trim().to_string();
        (!trimmed.is_empty()).then_some(trimmed)
    })
}

fn normalize_thread_timestamp(value: i64) -> i64 {
    if value > 10_000_000_000 {
        value / 1000
    } else {
        value
    }
}

fn relative_display_path(codex_home: &Path, path: &Path) -> String {
    path.strip_prefix(codex_home)
        .unwrap_or(path)
        .display()
        .to_string()
}

fn scan_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "jsonl_scan".into(),
        message,
    }
}

fn thread_info_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "thread_info".into(),
        message,
    }
}

fn excerpt_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "thread_excerpt".into(),
        message,
    }
}
