use super::session_files::session_id_from_file;
use super::session_parser::{
    read_event_excerpts, stream_session_file_exact, stream_session_file_exact_from, ExactChunkHash,
    ExactEventSourceOffsets, ExactSessionEventSink, ExactSessionParserState, ExactTokenEvent,
    SourceByteRange, UsageSnapshotFingerprint, EXACT_INDEX_CHUNK_SIZE,
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
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration as StdDuration, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

const INDEX_SCHEMA_VERSION: i64 = 5;
const LEGACY_APPEND_MIGRATION_SCHEMA_VERSION: i64 = 4;
const HOURLY_INTERVAL_SECONDS: i64 = 60 * 60;
const SEVEN_DAY_POINT_COUNT: i64 = 7 * 24;
const SIX_HOUR_INTERVAL_SECONDS: i64 = 6 * 60 * 60;
const THIRTY_DAY_POINT_COUNT: i64 = 30 * 4;
const CACHE_USAGE_MIN_INPUT_TOKENS: i64 = 1_000;
const CACHE_USAGE_CANDIDATE_LIMIT: i64 = 40;
const PARALLEL_STAGING_MIN_BYTES: u64 = EXACT_INDEX_CHUNK_SIZE;
const PARALLEL_HEAVY_FILE_BYTES: u64 = 512 * 1024 * 1024;

pub(super) struct ExactUsageIndex {
    connection: ManagedIndexConnection,
}

struct ManagedIndexConnection {
    connection: Option<Connection>,
    path: PathBuf,
}

impl ManagedIndexConnection {
    fn from_registered(connection: Connection, path: PathBuf) -> Self {
        Self {
            connection: Some(connection),
            path,
        }
    }
}

impl Deref for ManagedIndexConnection {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        self.connection
            .as_ref()
            .expect("managed exact index connection is available before drop")
    }
}

impl DerefMut for ManagedIndexConnection {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.connection
            .as_mut()
            .expect("managed exact index connection is available before drop")
    }
}

impl Drop for ManagedIndexConnection {
    fn drop(&mut self) {
        let states = index_integrity_states();
        let mut states = states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        drop(self.connection.take());
        finish_index_connection(&mut states, &self.path);
    }
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct IndexStorageSignature {
    database: FileSignature,
    wal: Option<FileSignature>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct IndexIntegrityState {
    signature: IndexStorageSignature,
    active_connections: usize,
}

#[derive(Clone, Debug)]
struct IndexedFileCheckpoint {
    generation: i64,
    size: u64,
    identity: FileIdentity,
    resume_offset: u64,
    parser_state: ExactSessionParserState,
    audit_chunk_index: u64,
}

#[derive(Clone, Debug)]
struct FullRebuildJob {
    file: PathBuf,
    path: String,
    session_id: String,
    signature: FileSignature,
}

#[derive(Clone, Debug)]
struct StagedFullRebuild {
    job: FullRebuildJob,
    database_path: PathBuf,
    prefix_sha256: [u8; 32],
    resume_offset: u64,
    parser_state: ExactSessionParserState,
    event_count: u64,
}

struct StagedFullRebuildResult {
    order: usize,
    result: Result<StagedFullRebuild, String>,
    warnings: Vec<LocalDataWarning>,
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
type AfterFileCommitHook = Box<dyn FnOnce(&Path) -> Result<(), String>>;

#[cfg(test)]
thread_local! {
    static AFTER_PREFIX_SCAN_HOOK: RefCell<Option<AfterPrefixScanHook>> = RefCell::new(None);
    static AFTER_FILE_COMMIT_HOOK: RefCell<Option<AfterFileCommitHook>> = RefCell::new(None);
    static PREFIX_REHASH_COUNT: Cell<u64> = const { Cell::new(0) };
}
#[cfg(test)]
static FULL_SCAN_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static APPEND_SCAN_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static FAIL_AFTER_STAGING: AtomicBool = AtomicBool::new(false);
#[cfg(test)]
static STAGE_ACTIVE_WORKERS: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static STAGE_PEAK_WORKERS: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static STAGE_DELAY_MILLISECONDS: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static QUICK_CHECK_COUNT: AtomicU64 = AtomicU64::new(0);
static INDEX_INTEGRITY_STATES: OnceLock<Mutex<HashMap<PathBuf, IndexIntegrityState>>> =
    OnceLock::new();

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
            && schema_version != Some(LEGACY_APPEND_MIGRATION_SCHEMA_VERSION)
        {
            // The index is fully rebuildable. Replacing an obsolete database,
            // rather than dropping its text columns in place, guarantees that
            // deleted SQLite pages and WAL frames cannot retain conversation
            // plaintext from schema v1.
            drop(connection);
            remove_index_storage(&path)?;
            connection = managed_index_connection(&path, open_index_connection(&path)?)?;
            schema_version = None;
        }
        initialize_index_schema(&connection)?;
        if schema_version == Some(LEGACY_APPEND_MIGRATION_SCHEMA_VERSION) {
            migrate_v4_index_for_append(&connection)?;
            set_metadata(
                &connection,
                "schema_version",
                &INDEX_SCHEMA_VERSION.to_string(),
            )?;
            schema_version = Some(INDEX_SCHEMA_VERSION);
        }
        if schema_version != Some(INDEX_SCHEMA_VERSION) {
            set_metadata(
                &connection,
                "schema_version",
                &INDEX_SCHEMA_VERSION.to_string(),
            )?;
            set_metadata(&connection, "revision", &fresh_revision_seed().to_string())?;
            set_metadata(&connection, "published_generation", "0")?;
            connection
                .execute(
                    "DELETE FROM metadata WHERE key IN ('building_generation', 'building_changed')",
                    [],
                )
                .map_err(|error| format!("无法初始化精确 token 同步状态：{error}"))?;
        }
        if metadata_i64(&connection, "published_generation")?.is_none() {
            set_metadata(&connection, "published_generation", "0")?;
        }

        let identity = codex_home_identity(codex_home);
        if metadata_text(&connection, "codex_home_identity")?.as_deref() != Some(&identity) {
            connection
                .execute_batch(
                    r#"
                    DELETE FROM events;
                    DELETE FROM file_fingerprints;
                    DELETE FROM file_chunks;
                    DELETE FROM files;
                    DELETE FROM session_metadata;
                    DELETE FROM metadata
                    WHERE key NOT IN ('schema_version');
                    "#,
                )
                .map_err(|error| format!("无法切换精确 token 索引数据源：{error}"))?;
            set_metadata(&connection, "codex_home_identity", &identity)?;
            set_metadata(&connection, "revision", &fresh_revision_seed().to_string())?;
            set_metadata(&connection, "published_generation", "0")?;
        }

        Ok(Self { connection })
    }

    #[cfg(test)]
    pub(super) fn set_after_prefix_scan_hook_for_testing(hook: impl FnOnce(&Path) + 'static) {
        AFTER_PREFIX_SCAN_HOOK.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(hook));
        });
    }

    #[cfg(test)]
    pub(super) fn set_after_file_commit_hook_for_testing(
        hook: impl FnOnce(&Path) -> Result<(), String> + 'static,
    ) {
        AFTER_FILE_COMMIT_HOOK.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(hook));
        });
    }

    #[cfg(test)]
    pub(super) fn reset_prefix_rehash_count_for_testing() {
        PREFIX_REHASH_COUNT.with(|count| count.set(0));
    }

    #[cfg(test)]
    pub(super) fn prefix_rehash_count_for_testing() -> u64 {
        PREFIX_REHASH_COUNT.with(Cell::get)
    }

    #[cfg(test)]
    pub(super) fn reset_scan_bytes_for_testing() {
        FULL_SCAN_BYTES.store(0, Ordering::SeqCst);
        APPEND_SCAN_BYTES.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn scan_bytes_for_testing() -> (u64, u64) {
        (
            FULL_SCAN_BYTES.load(Ordering::SeqCst),
            APPEND_SCAN_BYTES.load(Ordering::SeqCst),
        )
    }

    #[cfg(test)]
    pub(super) fn fail_after_staging_once_for_testing() {
        FAIL_AFTER_STAGING.store(true, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn reset_stage_concurrency_for_testing(delay_milliseconds: u64) {
        STAGE_ACTIVE_WORKERS.store(0, Ordering::SeqCst);
        STAGE_PEAK_WORKERS.store(0, Ordering::SeqCst);
        STAGE_DELAY_MILLISECONDS.store(delay_milliseconds, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn stage_peak_concurrency_for_testing() -> usize {
        STAGE_PEAK_WORKERS.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(super) fn clear_integrity_signature_for_testing(codex_home: &Path) {
        if let Ok(path) = database_path(codex_home) {
            invalidate_index_integrity_signature(&path);
        }
    }

    #[cfg(test)]
    pub(super) fn reset_quick_check_count_for_testing() {
        QUICK_CHECK_COUNT.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn quick_check_count_for_testing() -> u64 {
        QUICK_CHECK_COUNT.load(Ordering::SeqCst)
    }

    pub(super) fn sync(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<u64, String> {
        prune_published_tombstone_versions(&self.connection)?;
        prepare_scan_temp_tables(&self.connection)?;
        let generation = begin_or_resume_generation(&mut self.connection)?;
        let mut full_rebuild_jobs = Vec::new();
        visit_session_files(
            &mut self.connection,
            codex_home,
            warnings,
            |connection, file, warnings| {
                if let Some(job) =
                    process_session_file(connection, generation, codex_home, file, warnings)?
                {
                    full_rebuild_jobs.push(job);
                }
                Ok(())
            },
        )?;
        let index_path = database_path(codex_home)?;
        let staged = stage_full_rebuilds(&full_rebuild_jobs, &index_path, codex_home, warnings)?;
        #[cfg(test)]
        if FAIL_AFTER_STAGING.swap(false, Ordering::SeqCst) {
            return Err("injected interruption after durable exact token staging".into());
        }
        for staged_file in staged {
            import_staged_full_rebuild(&mut self.connection, generation, &staged_file)?;
            remove_index_storage(&staged_file.database_path)?;
            run_after_file_commit_hook_for_testing(&staged_file.job.file)?;
        }
        let revision = finalize_generation(&mut self.connection, generation, codex_home, warnings)?;
        remove_staging_directory(&index_path)?;
        Ok(revision)
    }

    pub(super) fn revision(&self) -> Result<u64, String> {
        Ok(u64::try_from(metadata_i64(&self.connection, "revision")?.unwrap_or(0)).unwrap_or(0))
    }

    pub(super) fn sources_changed(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<bool, String> {
        if metadata_i64(&self.connection, "building_generation")?.is_some() {
            return Ok(true);
        }
        prepare_scan_temp_tables(&self.connection)?;
        self.prepare_source_change_snapshot()?;
        let published_files = self.source_change_snapshot_signatures()?;
        let mut seen_files = HashSet::with_capacity(published_files.len());
        let mut changed = false;
        visit_session_files(
            &mut self.connection,
            codex_home,
            warnings,
            |_connection, file, _warnings| {
                let path = file.to_string_lossy().into_owned();
                if !seen_files.insert(path.clone()) {
                    return Ok(());
                }
                let signature = file_signature(file)?;
                let unchanged = published_files.get(&path).is_some_and(
                    |(size, modified_ns, device_id, file_id, changed_ns)| {
                        signature.matches_stored(
                            *size,
                            modified_ns,
                            device_id,
                            file_id,
                            changed_ns,
                        )
                    },
                );
                changed |= !unchanged;
                Ok(())
            },
        )?;
        let deleted = published_files
            .keys()
            .any(|path| !seen_files.contains(path));
        Ok(changed || deleted)
    }

    fn prepare_source_change_snapshot(&self) -> Result<(), String> {
        self.connection
            .execute_batch(
                r#"
                DROP TABLE IF EXISTS temp.published_files;
                CREATE TEMP TABLE published_files AS
                SELECT *
                FROM main.published_files;
                CREATE UNIQUE INDEX published_files_path_snapshot_idx
                    ON published_files(path);
                "#,
            )
            .map_err(|error| format!("无法建立精确 token 源文件快照：{error}"))
    }

    fn source_change_snapshot_signatures(
        &self,
    ) -> Result<HashMap<String, (u64, String, String, String, String)>, String> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT path, size, modified_ns, device_id, file_id, changed_ns FROM temp.published_files",
            )
            .map_err(|error| format!("无法读取精确 token 源文件快照：{error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    (
                        nonnegative_u64(row.get::<_, i64>(1)?),
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                    ),
                ))
            })
            .map_err(|error| format!("无法遍历精确 token 源文件快照：{error}"))?;
        let mut signatures = HashMap::new();
        for row in rows {
            let (path, signature) =
                row.map_err(|error| format!("无法解析精确 token 源文件快照：{error}"))?;
            signatures.insert(path, signature);
        }
        Ok(signatures)
    }

    pub(super) fn is_empty(&self) -> Result<bool, String> {
        self.connection
            .query_row(
                "SELECT NOT EXISTS(SELECT 1 FROM published_events LIMIT 1)",
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
                FROM published_events
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
        self.prepare_dashboard_event_snapshot()?;
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

    fn prepare_dashboard_event_snapshot(&self) -> Result<(), String> {
        self.connection
            .execute_batch(
                r#"
                DROP TABLE IF EXISTS temp.dashboard_turn_positions;
                DROP TABLE IF EXISTS temp.dashboard_session_rows;
                DROP TABLE IF EXISTS temp.published_events;
                DROP TABLE IF EXISTS temp.published_files;
                -- Materialize the small published file set first, then join the
                -- indexed event table directly. Selecting main.published_events
                -- here would evaluate the published-files grouping a second time.
                CREATE TEMP TABLE published_files AS
                SELECT *
                FROM main.published_files;
                CREATE UNIQUE INDEX published_files_path_snapshot_idx
                    ON published_files(path);
                CREATE TEMP TABLE published_events AS
                SELECT e.*
                FROM main.events e
                JOIN published_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path;
                CREATE INDEX published_events_timestamp_snapshot_idx
                    ON published_events(timestamp);
                CREATE INDEX published_events_session_snapshot_idx
                    ON published_events(session_id, timestamp, file_path, ordinal);
                CREATE TEMP TABLE dashboard_turn_positions AS
                SELECT
                    id,
                    ROW_NUMBER() OVER (
                        PARTITION BY session_id
                        ORDER BY timestamp ASC, file_path ASC, ordinal ASC
                    ) AS turn_index_in_session
                FROM published_events;
                CREATE UNIQUE INDEX dashboard_turn_positions_id_idx
                    ON dashboard_turn_positions(id);
                CREATE TEMP TABLE dashboard_session_rows AS
                SELECT
                    e.session_id,
                    COUNT(*) AS calls,
                    SUM(e.tokens) AS total_tokens,
                    SUM(e.input_tokens) AS input_tokens,
                    SUM(MIN(e.cached_input_tokens, e.input_tokens)) AS cached_tokens,
                    SUM(e.output_tokens) AS output_tokens,
                    COALESCE(m.updated_at, MAX(e.timestamp)) AS updated_at,
                    COALESCE(
                        NULLIF(TRIM(m.title), ''),
                        '会话 ' || SUBSTR(e.session_id, 1, 8)
                    ) AS title
                FROM published_events e
                LEFT JOIN session_metadata m ON m.session_id = e.session_id
                GROUP BY e.session_id;
                "#,
            )
            .map_err(|error| format!("无法建立精确 token 聚合快照：{error}"))
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
                FROM published_events
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
                FROM published_events
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
                    FROM published_events
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
                FROM published_events
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
            WITH selected_turns AS (
                SELECT
                    e.*,
                    p.turn_index_in_session,
                    CASE WHEN e.input_tokens > 0
                        THEN MIN(e.cached_input_tokens, e.input_tokens) * 1.0 / e.input_tokens
                        ELSE 0
                    END AS hit_rate,
                    e.input_tokens - MIN(e.cached_input_tokens, e.input_tokens) AS uncached
                FROM published_events e
                JOIN dashboard_turn_positions p ON p.id = e.id
                WHERE e.input_tokens >= ?1 {turn_predicate}
                {ordering}
                LIMIT ?2
            )
            SELECT
                turn_rows.id,
                turn_rows.file_path,
                turn_rows.ordinal,
                turn_rows.timestamp,
                turn_rows.session_id,
                turn_rows.tokens,
                turn_rows.input_tokens,
                MIN(turn_rows.cached_input_tokens, turn_rows.input_tokens),
                turn_rows.output_tokens,
                turn_rows.user_prompt_start,
                turn_rows.user_prompt_end,
                turn_rows.assistant_response_start,
                turn_rows.assistant_response_end,
                turn_rows.turn_index_in_session,
                COALESCE(
                    NULLIF(TRIM(m.title), ''),
                    '会话 ' || SUBSTR(turn_rows.session_id, 1, 8)
                ) AS title,
                f.size,
                f.modified_ns,
                f.device_id,
                f.file_id,
                f.changed_ns
            FROM selected_turns AS turn_rows
            LEFT JOIN session_metadata m ON m.session_id = turn_rows.session_id
            JOIN published_files f ON f.path = turn_rows.file_path
            {ordering}
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
    file_generation: i64,
    file_path: &'transaction str,
    ordinal: u64,
}

impl ExactSessionEventSink for SqliteEventSink<'_> {
    fn insert_fingerprint(
        &mut self,
        fingerprint: &UsageSnapshotFingerprint,
    ) -> Result<bool, String> {
        let encoded = encode_fingerprint(fingerprint);
        let inserted = self
            .transaction
            .execute(
                "INSERT OR IGNORE INTO exact_fingerprints(fingerprint) VALUES (?1)",
                params![encoded.as_slice()],
            )
            .map_err(|error| format!("无法写入精确 token 去重索引：{error}"))?
            > 0;
        if inserted {
            self.transaction
                .execute(
                    r#"
                    INSERT OR IGNORE INTO file_fingerprints(
                        file_generation,
                        file_path,
                        fingerprint
                    ) VALUES (?1, ?2, ?3)
                    "#,
                    params![self.file_generation, self.file_path, encoded.as_slice()],
                )
                .map_err(|error| format!("无法持久化精确 token 去重状态：{error}"))?;
        }
        Ok(inserted)
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
                    file_generation,
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
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                "#,
                params![
                    self.file_generation,
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

struct StagingEventSink<'transaction> {
    transaction: &'transaction Transaction<'transaction>,
    ordinal: u64,
}

impl ExactSessionEventSink for StagingEventSink<'_> {
    fn insert_fingerprint(
        &mut self,
        fingerprint: &UsageSnapshotFingerprint,
    ) -> Result<bool, String> {
        let encoded = encode_fingerprint(fingerprint);
        self.transaction
            .execute(
                "INSERT OR IGNORE INTO fingerprints(fingerprint) VALUES (?1)",
                params![encoded.as_slice()],
            )
            .map(|inserted| inserted > 0)
            .map_err(|error| format!("无法写入精确 token 暂存去重状态：{error}"))
    }

    fn insert_event(&mut self, event: &ExactTokenEvent) -> Result<(), String> {
        self.ordinal = self.ordinal.saturating_add(1);
        self.transaction
            .execute(
                r#"
                INSERT INTO events(
                    ordinal,
                    timestamp,
                    tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                "#,
                params![
                    checked_i64(self.ordinal, "暂存事件序号")?,
                    event.timestamp.unix_timestamp(),
                    checked_i64(event.tokens, "暂存 token 总数")?,
                    checked_i64(event.input_tokens, "暂存输入 token")?,
                    checked_i64(event.cached_input_tokens, "暂存缓存输入 token")?,
                    checked_i64(event.output_tokens, "暂存输出 token")?,
                    checked_optional_i64(
                        event.source_offsets.user_prompt.map(|range| range.start),
                        "暂存用户问题起始位置",
                    )?,
                    checked_optional_i64(
                        event.source_offsets.user_prompt.map(|range| range.end),
                        "暂存用户问题结束位置",
                    )?,
                    checked_optional_i64(
                        event
                            .source_offsets
                            .assistant_response
                            .map(|range| range.start),
                        "暂存回答起始位置",
                    )?,
                    checked_optional_i64(
                        event
                            .source_offsets
                            .assistant_response
                            .map(|range| range.end),
                        "暂存回答结束位置",
                    )?,
                ],
            )
            .map(|_| ())
            .map_err(|error| format!("无法写入精确 token 暂存事件：{error}"))
    }
}

struct StageManifest {
    path: String,
    session_id: String,
    size: i64,
    modified_ns: String,
    device_id: String,
    file_id: String,
    changed_ns: String,
    prefix_sha256: Vec<u8>,
    resume_offset: i64,
    previous_total_tokens: Option<i64>,
    fork_replay_started_ns: Option<String>,
    fork_replay_active: bool,
    last_skipped_fork_replay_token_ns: Option<String>,
    current_user_prompt_start: Option<i64>,
    current_user_prompt_end: Option<i64>,
    assistant_response_start: Option<i64>,
    assistant_response_end: Option<i64>,
    event_count: i64,
    fingerprint_count: i64,
    chunk_count: i64,
}

#[cfg(test)]
struct StageActivityGuard;

#[cfg(test)]
impl StageActivityGuard {
    fn begin() -> Self {
        let active = STAGE_ACTIVE_WORKERS.fetch_add(1, Ordering::SeqCst) + 1;
        STAGE_PEAK_WORKERS.fetch_max(active, Ordering::SeqCst);
        let delay = STAGE_DELAY_MILLISECONDS.load(Ordering::SeqCst);
        if delay > 0 {
            thread::sleep(StdDuration::from_millis(delay));
        }
        Self
    }
}

#[cfg(test)]
impl Drop for StageActivityGuard {
    fn drop(&mut self) {
        STAGE_ACTIVE_WORKERS.fetch_sub(1, Ordering::SeqCst);
    }
}

#[cfg(not(test))]
struct StageActivityGuard;

#[cfg(not(test))]
impl StageActivityGuard {
    fn begin() -> Self {
        Self
    }
}

fn encode_fingerprint(fingerprint: &UsageSnapshotFingerprint) -> [u8; 9 * 8] {
    let mut encoded = [0_u8; 9 * 8];
    for (index, value) in fingerprint.iter().enumerate() {
        let start = index * 8;
        encoded[start..start + 8].copy_from_slice(&value.to_le_bytes());
    }
    encoded
}

fn stage_full_rebuilds(
    jobs: &[FullRebuildJob],
    index_path: &Path,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<Vec<StagedFullRebuild>, String> {
    if jobs.is_empty() {
        return Ok(Vec::new());
    }
    ensure_staging_directory(index_path)?;
    let mut ordered_jobs = jobs.to_vec();
    ordered_jobs.sort_by(|left, right| {
        right
            .signature
            .size
            .cmp(&left.signature.size)
            .then_with(|| left.path.cmp(&right.path))
    });

    let mut results = if ordered_jobs.len() == 1 {
        vec![stage_full_rebuild_result(
            0,
            &ordered_jobs[0],
            index_path,
            codex_home,
        )]
    } else {
        let indexed_jobs = ordered_jobs.iter().enumerate().collect::<Vec<_>>();
        let (heavy_jobs, light_jobs): (Vec<_>, Vec<_>) = indexed_jobs
            .into_iter()
            .partition(|(_, job)| job.signature.size >= PARALLEL_HEAVY_FILE_BYTES);
        let has_heavy_jobs = !heavy_jobs.is_empty();
        let next_light_job = AtomicUsize::new(0);
        let collected = Mutex::new(Vec::with_capacity(ordered_jobs.len()));
        let worker_count = cold_build_worker_count(ordered_jobs.len());
        thread::scope(|scope| {
            if has_heavy_jobs {
                scope.spawn(|| {
                    for (order, job) in heavy_jobs {
                        let result = stage_full_rebuild_result(order, job, index_path, codex_home);
                        collected
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner())
                            .push(result);
                    }
                });
            }
            let light_worker_count = if light_jobs.is_empty() {
                0
            } else if has_heavy_jobs {
                worker_count.saturating_sub(1).max(1)
            } else {
                worker_count
            };
            for _ in 0..light_worker_count {
                scope.spawn(|| loop {
                    let light_index = next_light_job.fetch_add(1, Ordering::SeqCst);
                    let Some((order, job)) = light_jobs.get(light_index).copied() else {
                        break;
                    };
                    let result = stage_full_rebuild_result(order, job, index_path, codex_home);
                    collected
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .push(result);
                });
            }
        });
        collected
            .into_inner()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    };
    #[cfg(test)]
    STAGE_DELAY_MILLISECONDS.store(0, Ordering::SeqCst);

    results.sort_by_key(|result| result.order);
    let mut staged = Vec::with_capacity(results.len());
    let mut first_error = None;
    for mut result in results {
        warnings.append(&mut result.warnings);
        match result.result {
            Ok(value) => staged.push(value),
            Err(error) if first_error.is_none() => first_error = Some(error),
            Err(_) => {}
        }
    }
    if let Some(error) = first_error {
        return Err(error);
    }
    Ok(staged)
}

fn stage_full_rebuild_result(
    order: usize,
    job: &FullRebuildJob,
    index_path: &Path,
    codex_home: &Path,
) -> StagedFullRebuildResult {
    let mut warnings = Vec::new();
    let result = stage_or_reuse_full_rebuild(job, index_path, codex_home, &mut warnings);
    StagedFullRebuildResult {
        order,
        result,
        warnings,
    }
}

fn cold_build_worker_count(job_count: usize) -> usize {
    if job_count <= 1 {
        return 1;
    }
    let available = thread::available_parallelism()
        .map(|parallelism| parallelism.get())
        .unwrap_or(2);
    let resource_cap = if available >= 10 {
        6
    } else if available >= 8 {
        5
    } else if available >= 6 {
        4
    } else if available >= 4 {
        3
    } else {
        2
    };
    job_count.min(resource_cap)
}

fn stage_or_reuse_full_rebuild(
    job: &FullRebuildJob,
    index_path: &Path,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<StagedFullRebuild, String> {
    let database_path = staging_database_path(index_path, &job.path);
    if let Some(staged) = reusable_staged_full_rebuild(&database_path, job)? {
        return Ok(staged);
    }
    build_staged_full_rebuild(job, database_path, codex_home, warnings)
}

fn build_staged_full_rebuild(
    job: &FullRebuildJob,
    database_path: PathBuf,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<StagedFullRebuild, String> {
    let _activity = StageActivityGuard::begin();
    remove_index_storage(&database_path)?;
    let mut handle = fs::File::open(&job.file).map_err(|error| {
        format!(
            "读取精确 token 暂存源文件失败：{}（{}）",
            job.file.display(),
            error
        )
    })?;
    let current_signature = file_signature_from_handle(&handle, &job.file)?;
    if current_signature != job.signature {
        return Err(format!(
            "会话文件在进入并行暂存前发生变化，将在下一次刷新重试：{}",
            relative_display_path(codex_home, &job.file)
        ));
    }

    let mut stage = open_staging_connection(&database_path)?;
    initialize_staging_schema(&stage)?;
    let transaction = stage
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始精确 token 单文件暂存事务：{error}"))?;
    let mut sink = StagingEventSink {
        transaction: &transaction,
        ordinal: 0,
    };
    let parsed = stream_session_file_exact(
        &job.file,
        &mut handle,
        job.signature.size,
        &job.session_id,
        &mut sink,
        warnings,
    )?;
    let event_count = sink.ordinal;
    drop(sink);
    #[cfg(test)]
    FULL_SCAN_BYTES.fetch_add(job.signature.size, Ordering::SeqCst);
    run_after_prefix_scan_hook_for_testing(&job.file);

    if parsed.bytes_read != job.signature.size {
        return Err(format!(
            "会话文件固定前缀未完整扫描，将在下一次刷新重试：{}",
            relative_display_path(codex_home, &job.file)
        ));
    }
    validate_same_file_prefix(&job.file, &mut handle, job.signature, parsed.prefix_sha256)
        .map_err(|reason| {
            format!(
                "会话文件在精确扫描期间发生非追加变化，将在下一次刷新重试：{}（{}）",
                relative_display_path(codex_home, &job.file),
                reason
            )
        })?;

    {
        let mut insert_chunk = transaction
            .prepare(
                r#"
                INSERT INTO chunks(chunk_index, byte_count, sha256)
                VALUES (?1, ?2, ?3)
                "#,
            )
            .map_err(|error| format!("无法准备精确 token 暂存分块写入：{error}"))?;
        for chunk in &parsed.chunk_hashes {
            insert_chunk
                .execute(params![
                    checked_i64(chunk.index, "暂存分块序号")?,
                    checked_i64(chunk.byte_count, "暂存分块字节数")?,
                    chunk.sha256.as_slice(),
                ])
                .map_err(|error| format!("无法写入精确 token 暂存分块：{error}"))?;
        }
    }
    let fingerprint_count = transaction
        .query_row("SELECT COUNT(*) FROM fingerprints", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|error| format!("无法统计精确 token 暂存去重状态：{error}"))?;
    let state = parsed.state;
    transaction
        .execute(
            r#"
            INSERT INTO manifest(
                complete,
                path,
                session_id,
                size,
                modified_ns,
                device_id,
                file_id,
                changed_ns,
                prefix_sha256,
                resume_offset,
                previous_total_tokens,
                fork_replay_started_ns,
                fork_replay_active,
                last_skipped_fork_replay_token_ns,
                current_user_prompt_start,
                current_user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                event_count,
                fingerprint_count,
                chunk_count
            ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
            "#,
            params![
                &job.path,
                &job.session_id,
                checked_i64(job.signature.size, "暂存会话文件大小")?,
                job.signature.modified_ns.to_string(),
                job.signature.identity.device_id.to_string(),
                job.signature.identity.file_id.to_string(),
                job.signature.changed_ns.to_string(),
                parsed.prefix_sha256.as_slice(),
                checked_i64(parsed.resume_offset, "暂存会话文件续扫位置")?,
                checked_optional_i64(state.previous_total_tokens, "暂存累计 token")?,
                timestamp_ns_text(state.fork_replay_started_at),
                state.fork_replay_active,
                timestamp_ns_text(state.last_skipped_fork_replay_token_at),
                checked_optional_i64(
                    state.current_user_prompt.map(|range| range.start),
                    "暂存检查点用户问题起始位置",
                )?,
                checked_optional_i64(
                    state.current_user_prompt.map(|range| range.end),
                    "暂存检查点用户问题结束位置",
                )?,
                checked_optional_i64(
                    state.assistant_response.map(|range| range.start),
                    "暂存检查点回答起始位置",
                )?,
                checked_optional_i64(
                    state.assistant_response.map(|range| range.end),
                    "暂存检查点回答结束位置",
                )?,
                checked_i64(event_count, "暂存事件数量")?,
                fingerprint_count,
                checked_i64(parsed.chunk_hashes.len() as u64, "暂存分块数量")?,
            ],
        )
        .map_err(|error| format!("无法完成精确 token 单文件暂存清单：{error}"))?;
    transaction
        .commit()
        .map_err(|error| format!("无法耐久提交精确 token 单文件暂存：{error}"))?;
    quick_check_index(&stage)?;

    Ok(StagedFullRebuild {
        job: job.clone(),
        database_path,
        prefix_sha256: parsed.prefix_sha256,
        resume_offset: parsed.resume_offset,
        parser_state: parsed.state,
        event_count,
    })
}

fn open_staging_connection(path: &Path) -> Result<Connection, String> {
    let connection = Connection::open(path).map_err(|error| {
        format!(
            "无法打开精确 token 单文件暂存 {}：{}",
            path.display(),
            error
        )
    })?;
    connection
        .busy_timeout(StdDuration::from_secs(30))
        .map_err(|error| format!("无法设置精确 token 暂存等待时间：{error}"))?;
    connection
        .execute_batch(
            r#"
            PRAGMA journal_mode = DELETE;
            PRAGMA synchronous = FULL;
            PRAGMA temp_store = FILE;
            PRAGMA cache_size = -4096;
            "#,
        )
        .map_err(|error| format!("无法配置精确 token 单文件暂存：{error}"))?;
    Ok(connection)
}

fn initialize_staging_schema(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(
            r#"
            CREATE TABLE manifest (
                complete INTEGER PRIMARY KEY CHECK(complete = 1),
                path TEXT NOT NULL,
                session_id TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_ns TEXT NOT NULL,
                device_id TEXT NOT NULL,
                file_id TEXT NOT NULL,
                changed_ns TEXT NOT NULL,
                prefix_sha256 BLOB NOT NULL,
                resume_offset INTEGER NOT NULL,
                previous_total_tokens INTEGER,
                fork_replay_started_ns TEXT,
                fork_replay_active INTEGER NOT NULL,
                last_skipped_fork_replay_token_ns TEXT,
                current_user_prompt_start INTEGER,
                current_user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER,
                event_count INTEGER NOT NULL,
                fingerprint_count INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE fingerprints (
                fingerprint BLOB PRIMARY KEY
            ) WITHOUT ROWID;

            CREATE TABLE events (
                ordinal INTEGER PRIMARY KEY,
                timestamp INTEGER NOT NULL,
                tokens INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                user_prompt_start INTEGER,
                user_prompt_end INTEGER,
                assistant_response_start INTEGER,
                assistant_response_end INTEGER
            ) WITHOUT ROWID;

            CREATE TABLE chunks (
                chunk_index INTEGER PRIMARY KEY,
                byte_count INTEGER NOT NULL,
                sha256 BLOB NOT NULL
            ) WITHOUT ROWID;
            "#,
        )
        .map_err(|error| format!("无法初始化精确 token 单文件暂存结构：{error}"))
}

fn reusable_staged_full_rebuild(
    database_path: &Path,
    job: &FullRebuildJob,
) -> Result<Option<StagedFullRebuild>, String> {
    if !existing_regular_index(database_path)? {
        return Ok(None);
    }
    let reusable = (|| {
        let stage = sqlite::open_read_only(database_path, StdDuration::from_secs(1))
            .map_err(|error| format!("无法只读打开精确 token 单文件暂存：{error}"))?;
        validated_staged_full_rebuild(&stage, database_path, job)
    })();
    match reusable {
        Ok(Some(staged)) => Ok(Some(staged)),
        Ok(None) | Err(_) => {
            remove_index_storage(database_path)?;
            Ok(None)
        }
    }
}

fn validated_staged_full_rebuild(
    connection: &Connection,
    database_path: &Path,
    job: &FullRebuildJob,
) -> Result<Option<StagedFullRebuild>, String> {
    quick_check_index(connection)?;
    let manifest = connection
        .query_row(
            r#"
            SELECT
                path,
                session_id,
                size,
                modified_ns,
                device_id,
                file_id,
                changed_ns,
                prefix_sha256,
                resume_offset,
                previous_total_tokens,
                fork_replay_started_ns,
                fork_replay_active,
                last_skipped_fork_replay_token_ns,
                current_user_prompt_start,
                current_user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                event_count,
                fingerprint_count,
                chunk_count
            FROM manifest
            WHERE complete = 1
            LIMIT 1
            "#,
            [],
            |row| {
                Ok(StageManifest {
                    path: row.get(0)?,
                    session_id: row.get(1)?,
                    size: row.get(2)?,
                    modified_ns: row.get(3)?,
                    device_id: row.get(4)?,
                    file_id: row.get(5)?,
                    changed_ns: row.get(6)?,
                    prefix_sha256: row.get(7)?,
                    resume_offset: row.get(8)?,
                    previous_total_tokens: row.get(9)?,
                    fork_replay_started_ns: row.get(10)?,
                    fork_replay_active: row.get(11)?,
                    last_skipped_fork_replay_token_ns: row.get(12)?,
                    current_user_prompt_start: row.get(13)?,
                    current_user_prompt_end: row.get(14)?,
                    assistant_response_start: row.get(15)?,
                    assistant_response_end: row.get(16)?,
                    event_count: row.get(17)?,
                    fingerprint_count: row.get(18)?,
                    chunk_count: row.get(19)?,
                })
            },
        )
        .optional()
        .map_err(|error| format!("无法读取精确 token 单文件暂存清单：{error}"))?;
    let Some(manifest) = manifest else {
        return Ok(None);
    };
    if manifest.path != job.path
        || manifest.session_id != job.session_id
        || !job.signature.matches_stored(
            nonnegative_u64(manifest.size),
            &manifest.modified_ns,
            &manifest.device_id,
            &manifest.file_id,
            &manifest.changed_ns,
        )
        || manifest.size < 0
        || manifest.resume_offset < 0
        || nonnegative_u64(manifest.resume_offset) > job.signature.size
        || manifest.event_count < 0
        || manifest.fingerprint_count < 0
        || manifest.chunk_count < 0
    {
        return Ok(None);
    }
    let prefix_sha256: [u8; 32] = match manifest.prefix_sha256.as_slice().try_into() {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    let event_count = connection
        .query_row("SELECT COUNT(*) FROM events", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|error| format!("无法验证精确 token 暂存事件数量：{error}"))?;
    let fingerprint_count = connection
        .query_row("SELECT COUNT(*) FROM fingerprints", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|error| format!("无法验证精确 token 暂存去重数量：{error}"))?;
    let chunk_count = connection
        .query_row("SELECT COUNT(*) FROM chunks", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|error| format!("无法验证精确 token 暂存分块数量：{error}"))?;
    let malformed_hashes = connection
        .query_row(
            r#"
            SELECT
                EXISTS(SELECT 1 FROM fingerprints WHERE length(fingerprint) <> 72),
                EXISTS(SELECT 1 FROM chunks WHERE length(sha256) <> 32)
            "#,
            [],
            |row| Ok(row.get::<_, bool>(0)? || row.get::<_, bool>(1)?),
        )
        .map_err(|error| format!("无法验证精确 token 暂存哈希形状：{error}"))?;
    let expected_chunks = job
        .signature
        .size
        .checked_sub(1)
        .map_or(0, |offset| offset / EXACT_INDEX_CHUNK_SIZE + 1);
    if event_count != manifest.event_count
        || fingerprint_count != manifest.fingerprint_count
        || chunk_count != manifest.chunk_count
        || nonnegative_u64(chunk_count) != expected_chunks
        || malformed_hashes
    {
        return Ok(None);
    }
    let fork_replay_started_at = parse_timestamp_ns(manifest.fork_replay_started_ns.clone());
    let last_skipped_fork_replay_token_at =
        parse_timestamp_ns(manifest.last_skipped_fork_replay_token_ns.clone());
    if manifest.fork_replay_started_ns.is_some() && fork_replay_started_at.is_none()
        || manifest.last_skipped_fork_replay_token_ns.is_some()
            && last_skipped_fork_replay_token_at.is_none()
    {
        return Ok(None);
    }

    Ok(Some(StagedFullRebuild {
        job: job.clone(),
        database_path: database_path.to_path_buf(),
        prefix_sha256,
        resume_offset: nonnegative_u64(manifest.resume_offset),
        parser_state: ExactSessionParserState {
            previous_total_tokens: manifest.previous_total_tokens.map(nonnegative_u64),
            fork_replay_started_at,
            fork_replay_active: manifest.fork_replay_active,
            last_skipped_fork_replay_token_at,
            current_user_prompt: source_range_from_columns(
                manifest.current_user_prompt_start,
                manifest.current_user_prompt_end,
            ),
            assistant_response: source_range_from_columns(
                manifest.assistant_response_start,
                manifest.assistant_response_end,
            ),
        },
        event_count: nonnegative_u64(manifest.event_count),
    }))
}

fn import_staged_full_rebuild(
    connection: &mut Connection,
    generation: i64,
    staged: &StagedFullRebuild,
) -> Result<(), String> {
    let validated = {
        let stage = sqlite::open_read_only(&staged.database_path, StdDuration::from_secs(1))
            .map_err(|error| format!("无法只读打开待导入的精确 token 暂存：{error}"))?;
        validated_staged_full_rebuild(&stage, &staged.database_path, &staged.job)?
            .ok_or_else(|| "精确 token 单文件暂存在导入前失效".to_string())?
    };
    let stage_path = staged.database_path.to_str().ok_or_else(|| {
        format!(
            "精确 token 暂存路径不是有效 UTF-8：{}",
            staged.database_path.display()
        )
    })?;
    connection
        .execute(
            "ATTACH DATABASE ?1 AS exact_stage_import",
            params![stage_path],
        )
        .map_err(|error| format!("无法附加待导入的精确 token 暂存：{error}"))?;

    let import_result = (|| {
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始精确 token 暂存导入事务：{error}"))?;
        ensure_active_build_generation(&transaction, generation)?;
        transaction
            .execute(
                "DELETE FROM files WHERE generation = ?1 AND path = ?2",
                params![generation, &validated.job.path],
            )
            .map_err(|error| format!("无法清理本轮待重建会话版本：{error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO files(
                    generation,
                    path,
                    deleted,
                    session_id,
                    size,
                    modified_ns,
                    device_id,
                    file_id,
                    changed_ns,
                    prefix_sha256
                ) VALUES (?1, ?2, 0, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                "#,
                params![
                    generation,
                    &validated.job.path,
                    &validated.job.session_id,
                    checked_i64(validated.job.signature.size, "导入会话文件大小")?,
                    validated.job.signature.modified_ns.to_string(),
                    validated.job.signature.identity.device_id.to_string(),
                    validated.job.signature.identity.file_id.to_string(),
                    validated.job.signature.changed_ns.to_string(),
                    validated.prefix_sha256.as_slice(),
                ],
            )
            .map_err(|error| format!("无法登记待导入的精确 token 会话：{error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO file_fingerprints(file_generation, file_path, fingerprint)
                SELECT ?1, ?2, fingerprint
                FROM exact_stage_import.fingerprints
                "#,
                params![generation, &validated.job.path],
            )
            .map_err(|error| format!("无法批量导入精确 token 去重状态：{error}"))?;
        let imported_events = transaction
            .execute(
                r#"
                INSERT INTO events(
                    file_generation,
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
                )
                SELECT
                    ?1,
                    ?2,
                    ordinal,
                    timestamp,
                    ?3,
                    tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end
                FROM exact_stage_import.events
                ORDER BY ordinal
                "#,
                params![generation, &validated.job.path, &validated.job.session_id],
            )
            .map_err(|error| format!("无法批量导入精确 token 暂存事件：{error}"))?;
        let imported_events = u64::try_from(imported_events)
            .map_err(|_| "精确 token 暂存事件导入数量超出支持范围".to_string())?;
        if imported_events != validated.event_count {
            return Err(format!(
                "精确 token 暂存事件导入数量不一致：预期 {}，实际 {}",
                validated.event_count, imported_events
            ));
        }
        transaction
            .execute(
                r#"
                INSERT INTO file_chunks(
                    file_generation,
                    file_path,
                    chunk_index,
                    byte_count,
                    sha256
                )
                SELECT ?1, ?2, chunk_index, byte_count, sha256
                FROM exact_stage_import.chunks
                "#,
                params![generation, &validated.job.path],
            )
            .map_err(|error| format!("无法批量导入精确 token 暂存分块：{error}"))?;
        save_file_checkpoint(
            &transaction,
            generation,
            &validated.job.path,
            validated.job.signature,
            validated.resume_offset,
            validated.parser_state,
            0,
        )?;
        set_metadata(&transaction, "building_changed", "1")?;
        transaction
            .commit()
            .map_err(|error| format!("无法提交精确 token 单文件暂存导入：{error}"))
    })();

    let detach_result = connection
        .execute_batch("DETACH DATABASE exact_stage_import")
        .map_err(|error| format!("无法卸载已导入的精确 token 暂存：{error}"));
    match (import_result, detach_result) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

fn ensure_staging_directory(index_path: &Path) -> Result<(), String> {
    let directory = staging_directory(index_path);
    match fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err(format!(
                "拒绝使用符号链接形式的精确 token 暂存目录：{}",
                directory.display()
            ));
        }
        Ok(metadata) if !metadata.is_dir() => {
            return Err(format!(
                "精确 token 暂存路径不是目录：{}",
                directory.display()
            ));
        }
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "无法检查精确 token 暂存目录 {}：{}",
                directory.display(),
                error
            ));
        }
    }
    fs::create_dir_all(&directory).map_err(|error| {
        format!(
            "无法创建精确 token 暂存目录 {}：{}",
            directory.display(),
            error
        )
    })?;
    let metadata = fs::symlink_metadata(&directory).map_err(|error| {
        format!(
            "无法复核精确 token 暂存目录 {}：{}",
            directory.display(),
            error
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!(
            "精确 token 暂存目录身份异常：{}",
            directory.display()
        ));
    }
    Ok(())
}

fn remove_staging_directory(index_path: &Path) -> Result<(), String> {
    let directory = staging_directory(index_path);
    match fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝删除符号链接形式的精确 token 暂存目录：{}",
            directory.display()
        )),
        Ok(metadata) if !metadata.is_dir() => Err(format!(
            "精确 token 暂存路径不是目录：{}",
            directory.display()
        )),
        Ok(_) => fs::remove_dir_all(&directory).map_err(|error| {
            format!(
                "无法清理精确 token 暂存目录 {}：{}",
                directory.display(),
                error
            )
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "无法检查精确 token 暂存目录 {}：{}",
            directory.display(),
            error
        )),
    }
}

fn staging_directory(index_path: &Path) -> PathBuf {
    let mut value = index_path.as_os_str().to_os_string();
    value.push(".staging");
    PathBuf::from(value)
}

fn staging_database_path(index_path: &Path, source_path: &str) -> PathBuf {
    let digest = Sha256::digest(source_path.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    staging_directory(index_path).join(format!("{digest}.sqlite3"))
}

fn prepare_scan_temp_tables(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(
            r#"
            CREATE TEMP TABLE IF NOT EXISTS exact_seen_files (
                path TEXT PRIMARY KEY
            ) WITHOUT ROWID;
            CREATE TEMP TABLE IF NOT EXISTS exact_seen_directories (
                path TEXT PRIMARY KEY,
                processed INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS exact_seen_directories_processed_idx
                ON exact_seen_directories(processed, path);
            CREATE TEMP TABLE IF NOT EXISTS exact_fingerprints (
                fingerprint BLOB PRIMARY KEY
            ) WITHOUT ROWID;
            DELETE FROM exact_seen_files;
            DELETE FROM exact_seen_directories;
            DELETE FROM exact_fingerprints;
            "#,
        )
        .map_err(|error| format!("无法准备精确 token 索引外存临时表：{error}"))
}

fn prune_published_tombstone_versions(connection: &Connection) -> Result<(), String> {
    loop {
        let tombstone = connection
            .query_row(
                r#"
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
                SELECT f.path, f.generation
                FROM latest
                JOIN files f
                  ON f.path = latest.path
                 AND f.generation = latest.generation
                WHERE f.deleted = 1
                LIMIT 1
                "#,
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()
            .map_err(|error| format!("无法检查已发布的会话删除墓碑：{error}"))?;
        let Some((path, tombstone_generation)) = tombstone else {
            return Ok(());
        };
        connection
            .execute(
                "DELETE FROM files WHERE path = ?1 AND generation <= ?2",
                params![path, tombstone_generation],
            )
            .map_err(|error| format!("无法清理已发布删除会话的旧索引版本：{error}"))?;
    }
}

fn begin_or_resume_generation(connection: &mut Connection) -> Result<i64, String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始精确 token 同步状态事务：{error}"))?;
    let published = metadata_i64(&transaction, "published_generation")?.unwrap_or(0);
    if let Some(building) = metadata_i64(&transaction, "building_generation")? {
        if building > published {
            transaction
                .commit()
                .map_err(|error| format!("无法确认精确 token 续扫状态：{error}"))?;
            return Ok(building);
        }
        transaction
            .execute(
                "DELETE FROM metadata WHERE key IN ('building_generation', 'building_changed')",
                [],
            )
            .map_err(|error| format!("无法修复失效的精确 token 同步状态：{error}"))?;
    }
    let maximum_generation = transaction
        .query_row(
            "SELECT COALESCE(MAX(generation), 0) FROM files",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法读取精确 token 文件代次：{error}"))?
        .max(published);
    let generation = maximum_generation
        .checked_add(1)
        .ok_or_else(|| "精确 token 文件代次已超出 SQLite 整数范围".to_string())?;
    set_metadata(&transaction, "building_generation", &generation.to_string())?;
    set_metadata(&transaction, "building_changed", "0")?;
    transaction
        .commit()
        .map_err(|error| format!("无法持久化精确 token 同步状态：{error}"))?;
    Ok(generation)
}

fn ensure_active_build_generation(
    transaction: &Transaction<'_>,
    expected: i64,
) -> Result<(), String> {
    if metadata_i64(transaction, "building_generation")? == Some(expected) {
        Ok(())
    } else {
        Err("精确 token 同步代次已由另一个扫描发布或替换".into())
    }
}

fn finalize_generation(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<u64, String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始精确 token 发布事务：{error}"))?;
    if metadata_i64(&transaction, "building_generation")? != Some(generation) {
        let revision = metadata_i64(&transaction, "revision")?.unwrap_or(0);
        transaction
            .commit()
            .map_err(|error| format!("无法结束已被替换的精确 token 扫描：{error}"))?;
        return Ok(u64::try_from(revision).unwrap_or(0));
    }

    let missing_count = transaction
        .query_row(
            r#"
            WITH latest AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation <= ?1
                GROUP BY path
            )
            SELECT COUNT(*)
            FROM latest
            JOIN files f
              ON f.path = latest.path
             AND f.generation = latest.generation
            WHERE f.deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM exact_seen_files seen
                  WHERE seen.path = latest.path
              )
            "#,
            params![generation],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法检查本轮已删除的会话文件：{error}"))?;
    if missing_count > 0 {
        transaction
            .execute(
                r#"
                WITH latest AS (
                    SELECT path, MAX(generation) AS generation
                    FROM files
                    WHERE generation <= ?1
                    GROUP BY path
                ),
                missing AS (
                    SELECT latest.path
                    FROM latest
                    JOIN files f
                      ON f.path = latest.path
                     AND f.generation = latest.generation
                    WHERE f.deleted = 0
                      AND NOT EXISTS (
                          SELECT 1
                          FROM exact_seen_files seen
                          WHERE seen.path = latest.path
                      )
                )
                DELETE FROM events
                WHERE file_generation = ?1
                  AND file_path IN (SELECT path FROM missing)
                "#,
                params![generation],
            )
            .map_err(|error| format!("无法清理本轮已删除会话的暂存事件：{error}"))?;
        transaction
            .execute(
                r#"
                WITH latest AS (
                    SELECT path, MAX(generation) AS generation
                    FROM files
                    WHERE generation <= ?1
                    GROUP BY path
                ),
                missing AS (
                    SELECT latest.path
                    FROM latest
                    JOIN files f
                      ON f.path = latest.path
                     AND f.generation = latest.generation
                    WHERE f.deleted = 0
                      AND NOT EXISTS (
                          SELECT 1
                          FROM exact_seen_files seen
                          WHERE seen.path = latest.path
                      )
                )
                INSERT INTO files(
                    generation,
                    path,
                    deleted,
                    session_id,
                    size,
                    modified_ns,
                    device_id,
                    file_id,
                    changed_ns,
                    prefix_sha256
                )
                SELECT ?1, path, 1, '', 0, '0', '0', '0', '0', X''
                FROM missing
                WHERE true
                ON CONFLICT(generation, path) DO UPDATE SET
                    deleted = 1,
                    session_id = '',
                    size = 0,
                    modified_ns = '0',
                    device_id = '0',
                    file_id = '0',
                    changed_ns = '0',
                    prefix_sha256 = X''
                "#,
                params![generation],
            )
            .map_err(|error| format!("无法登记本轮已删除的会话文件：{error}"))?;
        set_metadata(&transaction, "building_changed", "1")?;
    }

    if sync_thread_metadata(&transaction, codex_home, warnings)? {
        set_metadata(&transaction, "building_changed", "1")?;
    }
    let changed = metadata_i64(&transaction, "building_changed")?.unwrap_or(0) != 0;
    let current_revision = metadata_i64(&transaction, "revision")?.unwrap_or(0);
    let revision = if changed {
        set_metadata(
            &transaction,
            "published_generation",
            &generation.to_string(),
        )?;
        current_revision.saturating_add(1)
    } else {
        current_revision
    };
    set_metadata(&transaction, "revision", &revision.to_string())?;
    transaction
        .execute(
            "DELETE FROM metadata WHERE key IN ('building_generation', 'building_changed')",
            [],
        )
        .map_err(|error| format!("无法结束精确 token 同步状态：{error}"))?;
    transaction
        .commit()
        .map_err(|error| format!("无法原子发布完整精确 token 代次：{error}"))?;
    Ok(u64::try_from(revision).unwrap_or(0))
}

fn process_session_file(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<Option<FullRebuildJob>, String> {
    let canonical = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    let path = canonical.to_string_lossy().into_owned();
    let newly_seen = connection
        .execute(
            "INSERT OR IGNORE INTO exact_seen_files(path) VALUES (?1)",
            params![&path],
        )
        .map_err(|error| format!("无法记录会话文件扫描状态：{error}"))?
        > 0;
    if !newly_seen {
        return Ok(None);
    }
    prune_obsolete_file_versions(connection, &path)?;

    let mut handle = fs::File::open(file)
        .map_err(|error| format!("读取会话文件失败：{}（{}）", file.display(), error))?;
    let signature = file_signature_from_handle(&handle, file)?;
    let unchanged = connection
        .query_row(
            r#"
            SELECT deleted, size, modified_ns, device_id, file_id, changed_ns
            FROM files
            WHERE path = ?1 AND generation <= ?2
            ORDER BY generation DESC
            LIMIT 1
            "#,
            params![&path, generation],
            |row| {
                Ok((
                    row.get::<_, bool>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                ))
            },
        )
        .optional()
        .map_err(|error| format!("无法读取会话文件索引签名：{error}"))?
        .is_some_and(
            |(deleted, size, modified_ns, device_id, file_id, changed_ns)| {
                !deleted
                    && signature.matches_stored(
                        nonnegative_u64(size),
                        &modified_ns,
                        &device_id,
                        &file_id,
                        &changed_ns,
                    )
            },
        );
    if unchanged {
        return Ok(None);
    }

    if let Some(checkpoint) = indexed_file_checkpoint(connection, &path, generation)? {
        if signature.size > checkpoint.size
            && signature.identity == checkpoint.identity
            && append_session_file(
                connection,
                generation,
                codex_home,
                file,
                &path,
                &mut handle,
                signature,
                &checkpoint,
                warnings,
            )?
        {
            return Ok(None);
        }
    }

    if signature.size < PARALLEL_STAGING_MIN_BYTES {
        rebuild_session_file_direct(
            connection,
            generation,
            codex_home,
            file,
            &path,
            &mut handle,
            signature,
            warnings,
        )?;
        return Ok(None);
    }

    Ok(Some(FullRebuildJob {
        file: canonical,
        path,
        session_id: session_id_from_file(file),
        signature,
    }))
}

#[allow(clippy::too_many_arguments)]
fn rebuild_session_file_direct(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    path: &str,
    handle: &mut fs::File,
    signature: FileSignature,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<(), String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始单文件精确 token 索引事务：{error}"))?;
    ensure_active_build_generation(&transaction, generation)?;
    transaction
        .execute(
            "DELETE FROM files WHERE generation = ?1 AND path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理本轮变更会话的旧文件版本：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO files(
                generation,
                path,
                deleted,
                session_id,
                size,
                modified_ns,
                device_id,
                file_id,
                changed_ns,
                prefix_sha256
            ) VALUES (?1, ?2, 0, ?3, ?4, ?5, ?6, ?7, ?8, X'')
            "#,
            params![
                generation,
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
        transaction: &transaction,
        file_generation: generation,
        file_path: path,
        ordinal: 0,
    };
    let parsed = stream_session_file_exact(
        file,
        handle,
        signature.size,
        &session_id,
        &mut sink,
        warnings,
    )?;
    #[cfg(test)]
    FULL_SCAN_BYTES.fetch_add(signature.size, Ordering::SeqCst);
    drop(sink);
    debug_assert_eq!(parsed.bytes_read, signature.size);

    run_after_prefix_scan_hook_for_testing(file);
    validate_same_file_prefix(file, handle, signature, parsed.prefix_sha256).map_err(|reason| {
        format!(
            "会话文件在精确扫描期间发生非追加变化，将在下一次刷新重试：{}（{}）",
            relative_display_path(codex_home, file),
            reason
        )
    })?;
    transaction
        .execute(
            "UPDATE files SET prefix_sha256 = ?3 WHERE generation = ?1 AND path = ?2",
            params![generation, path, parsed.prefix_sha256.as_slice()],
        )
        .map_err(|error| format!("无法保存会话文件前缀校验值：{error}"))?;
    replace_file_chunks(&transaction, generation, path, 0, &parsed.chunk_hashes)?;
    save_file_checkpoint(
        &transaction,
        generation,
        path,
        signature,
        parsed.resume_offset,
        parsed.state,
        0,
    )?;
    if parsed.bytes_read != signature.size {
        return Err(format!(
            "会话文件固定前缀未完整扫描，将在下一次刷新重试：{}",
            relative_display_path(codex_home, file)
        ));
    }
    set_metadata(&transaction, "building_changed", "1")?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交单文件精确 token 索引：{error}"))?;
    run_after_file_commit_hook_for_testing(file)
}

fn indexed_file_checkpoint(
    connection: &Connection,
    path: &str,
    generation: i64,
) -> Result<Option<IndexedFileCheckpoint>, String> {
    connection
        .query_row(
            r#"
            SELECT
                generation,
                size,
                device_id,
                file_id,
                resume_offset,
                previous_total_tokens,
                fork_replay_started_ns,
                fork_replay_active,
                last_skipped_fork_replay_token_ns,
                current_user_prompt_start,
                current_user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                audit_chunk_index
            FROM files
            WHERE path = ?1
              AND generation <= ?2
              AND deleted = 0
              AND append_ready = 1
              AND resume_offset IS NOT NULL
            ORDER BY generation DESC
            LIMIT 1
            "#,
            params![path, generation],
            |row| {
                let size = nonnegative_u64(row.get::<_, i64>(1)?);
                let device_id = row.get::<_, String>(2)?.parse::<u64>().unwrap_or_default();
                let file_id = row.get::<_, String>(3)?.parse::<u64>().unwrap_or_default();
                let resume_offset = nonnegative_u64(row.get::<_, i64>(4)?);
                let previous_total_tokens = row.get::<_, Option<i64>>(5)?.map(nonnegative_u64);
                let fork_replay_started_at = parse_timestamp_ns(row.get::<_, Option<String>>(6)?);
                let fork_replay_active = row.get::<_, bool>(7)?;
                let last_skipped_fork_replay_token_at =
                    parse_timestamp_ns(row.get::<_, Option<String>>(8)?);
                let current_user_prompt = source_range_from_columns(
                    row.get::<_, Option<i64>>(9)?,
                    row.get::<_, Option<i64>>(10)?,
                );
                let assistant_response = source_range_from_columns(
                    row.get::<_, Option<i64>>(11)?,
                    row.get::<_, Option<i64>>(12)?,
                );
                Ok(IndexedFileCheckpoint {
                    generation: row.get(0)?,
                    size,
                    identity: FileIdentity { device_id, file_id },
                    resume_offset,
                    parser_state: ExactSessionParserState {
                        previous_total_tokens,
                        fork_replay_started_at,
                        fork_replay_active,
                        last_skipped_fork_replay_token_at,
                        current_user_prompt,
                        assistant_response,
                    },
                    audit_chunk_index: nonnegative_u64(row.get::<_, i64>(13)?),
                })
            },
        )
        .optional()
        .map_err(|error| format!("无法读取会话文件追加检查点：{error}"))
}

#[allow(clippy::too_many_arguments)]
fn append_session_file(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    path: &str,
    handle: &mut fs::File,
    signature: FileSignature,
    checkpoint: &IndexedFileCheckpoint,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<bool, String> {
    if checkpoint.resume_offset > checkpoint.size
        || !audit_checkpoint_chunk(connection, handle, file, path, checkpoint)?
    {
        return Ok(false);
    }

    let tail_chunk_index = checkpoint
        .size
        .checked_sub(1)
        .map(|offset| offset / EXACT_INDEX_CHUNK_SIZE);
    let stored_tail = match tail_chunk_index {
        Some(index) => stored_file_chunk(connection, checkpoint.generation, path, index)?,
        None => None,
    };
    if checkpoint.size > 0 && stored_tail.is_none() {
        return Ok(false);
    }
    let hashing_start_offset = tail_chunk_index
        .unwrap_or(0)
        .saturating_mul(EXACT_INDEX_CHUNK_SIZE);
    // 活动文件的未完成行可以合法地跨过块边界：此时续扫起点（resume_offset，
    // 未完成行的行首）落在尾块起点之前，续扫不变量无法满足。必须回退全量
    // 重建（Ok(false)）而不是让流式层报错——报错会使整轮同步失败，检查点
    // 固化后每轮复现，该 Home 的精确统计将永久停摆无自愈。
    if checkpoint.resume_offset < hashing_start_offset {
        return Ok(false);
    }

    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始单文件追加索引事务：{error}"))?;
    ensure_active_build_generation(&transaction, generation)?;
    // 中断恢复会复用同一 building 代次（begin_or_resume_generation）：此时追加检查点
    // 行就在本代次内，先删本代次行再从同代次 INSERT SELECT 会把源行连同级联的
    // events/指纹/分块一起删掉（copied == 0），追加被迫退化为整文件重扫。同代次
    // 直接基于既有行续扫，收尾由 save_file_checkpoint 覆盖检查点。
    if checkpoint.generation != generation
        && !copy_append_checkpoint_rows(&transaction, generation, checkpoint.generation, path)?
    {
        return Ok(false);
    }
    transaction
        .execute("DELETE FROM exact_fingerprints", [])
        .map_err(|error| format!("无法重置会话 token 去重表：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT OR IGNORE INTO exact_fingerprints(fingerprint)
            SELECT fingerprint
            FROM file_fingerprints
            WHERE file_generation = ?1 AND file_path = ?2
            "#,
            params![generation, path],
        )
        .map_err(|error| format!("无法恢复会话 token 去重检查点：{error}"))?;
    let ordinal = transaction
        .query_row(
            r#"
            SELECT COALESCE(MAX(ordinal), 0)
            FROM events
            WHERE file_generation = ?1 AND file_path = ?2
            "#,
            params![generation, path],
            |row| row.get::<_, i64>(0),
        )
        .map(nonnegative_u64)
        .map_err(|error| format!("无法读取会话文件追加事件序号：{error}"))?;

    let session_id = session_id_from_file(file);
    let mut sink = SqliteEventSink {
        transaction: &transaction,
        file_generation: generation,
        file_path: path,
        ordinal,
    };
    let parsed = stream_session_file_exact_from(
        file,
        handle,
        hashing_start_offset,
        checkpoint.resume_offset,
        signature.size,
        Some(checkpoint.size),
        checkpoint.parser_state,
        &session_id,
        &mut sink,
        warnings,
    )?;
    #[cfg(test)]
    APPEND_SCAN_BYTES.fetch_add(
        signature.size.saturating_sub(hashing_start_offset),
        Ordering::SeqCst,
    );
    drop(sink);
    run_after_prefix_scan_hook_for_testing(file);

    if checkpoint.size > 0 && parsed.validation_chunk_hash.as_ref() != stored_tail.as_ref() {
        return Ok(false);
    }
    if parsed.bytes_read != signature.size {
        return Err(format!(
            "会话文件追加前缀未完整扫描，将在下一次刷新重试：{}",
            relative_display_path(codex_home, file)
        ));
    }
    validate_append_scan_prefix(file, handle, signature, &parsed.chunk_hashes).map_err(
        |reason| {
            format!(
                "会话文件在追加扫描期间发生非追加变化，将在下一次刷新重试：{}（{}）",
                relative_display_path(codex_home, file),
                reason
            )
        },
    )?;

    replace_file_chunks(
        &transaction,
        generation,
        path,
        tail_chunk_index.unwrap_or(0),
        &parsed.chunk_hashes,
    )?;
    let old_chunk_count = checkpoint
        .size
        .checked_sub(1)
        .map_or(0, |offset| offset / EXACT_INDEX_CHUNK_SIZE + 1);
    let next_audit_chunk = if old_chunk_count == 0 {
        0
    } else {
        checkpoint.audit_chunk_index.saturating_add(1) % old_chunk_count
    };
    save_file_checkpoint(
        &transaction,
        generation,
        path,
        signature,
        parsed.resume_offset,
        parsed.state,
        next_audit_chunk,
    )?;
    set_metadata(&transaction, "building_changed", "1")?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交单文件追加 token 索引：{error}"))?;
    run_after_file_commit_hook_for_testing(file)?;
    Ok(true)
}

/// 把旧代次的追加检查点行（files 及级联的 events/指纹/分块）复制进当前代次。
/// 返回 false 表示检查点源行不存在（复制不到恰好一行），调用方应回退全量重建。
fn copy_append_checkpoint_rows(
    transaction: &Transaction<'_>,
    generation: i64,
    checkpoint_generation: i64,
    path: &str,
) -> Result<bool, String> {
    transaction
        .execute(
            "DELETE FROM files WHERE generation = ?1 AND path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理本轮追加会话的旧文件版本：{error}"))?;
    let copied = transaction
        .execute(
            r#"
            INSERT INTO files(
                generation,
                path,
                deleted,
                session_id,
                size,
                modified_ns,
                device_id,
                file_id,
                changed_ns,
                prefix_sha256,
                append_ready,
                resume_offset,
                previous_total_tokens,
                fork_replay_started_ns,
                fork_replay_active,
                last_skipped_fork_replay_token_ns,
                current_user_prompt_start,
                current_user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                audit_chunk_index
            )
            SELECT
                ?1,
                path,
                0,
                session_id,
                size,
                modified_ns,
                device_id,
                file_id,
                changed_ns,
                prefix_sha256,
                append_ready,
                resume_offset,
                previous_total_tokens,
                fork_replay_started_ns,
                fork_replay_active,
                last_skipped_fork_replay_token_ns,
                current_user_prompt_start,
                current_user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                audit_chunk_index
            FROM files
            WHERE generation = ?2 AND path = ?3
            "#,
            params![generation, checkpoint_generation, path],
        )
        .map_err(|error| format!("无法复制会话文件追加检查点：{error}"))?;
    if copied != 1 {
        return Ok(false);
    }
    transaction
        .execute(
            r#"
            INSERT INTO events(
                file_generation,
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
            )
            SELECT
                ?1,
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
            FROM events
            WHERE file_generation = ?2 AND file_path = ?3
            "#,
            params![generation, checkpoint_generation, path],
        )
        .map_err(|error| format!("无法复制会话文件既有 token 事件：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO file_fingerprints(file_generation, file_path, fingerprint)
            SELECT ?1, file_path, fingerprint
            FROM file_fingerprints
            WHERE file_generation = ?2 AND file_path = ?3
            "#,
            params![generation, checkpoint_generation, path],
        )
        .map_err(|error| format!("无法复制会话文件去重状态：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO file_chunks(
                file_generation,
                file_path,
                chunk_index,
                byte_count,
                sha256
            )
            SELECT ?1, file_path, chunk_index, byte_count, sha256
            FROM file_chunks
            WHERE file_generation = ?2 AND file_path = ?3
            "#,
            params![generation, checkpoint_generation, path],
        )
        .map_err(|error| format!("无法复制会话文件分块校验状态：{error}"))?;
    Ok(true)
}

fn audit_checkpoint_chunk(
    connection: &Connection,
    handle: &mut fs::File,
    file: &Path,
    path: &str,
    checkpoint: &IndexedFileCheckpoint,
) -> Result<bool, String> {
    let chunk_count = checkpoint
        .size
        .checked_sub(1)
        .map_or(0, |offset| offset / EXACT_INDEX_CHUNK_SIZE + 1);
    if chunk_count == 0 {
        return Ok(true);
    }
    let tail_index = (checkpoint.size - 1) / EXACT_INDEX_CHUNK_SIZE;
    let audit_index = checkpoint.audit_chunk_index % chunk_count;
    if audit_index == tail_index {
        return Ok(true);
    }
    let Some(stored) = stored_file_chunk(connection, checkpoint.generation, path, audit_index)?
    else {
        return Ok(false);
    };
    let current = hash_file_chunk(handle, file, stored.index, stored.byte_count)?;
    Ok(current == stored)
}

fn stored_file_chunk(
    connection: &Connection,
    generation: i64,
    path: &str,
    chunk_index: u64,
) -> Result<Option<ExactChunkHash>, String> {
    connection
        .query_row(
            r#"
            SELECT byte_count, sha256
            FROM file_chunks
            WHERE file_generation = ?1
              AND file_path = ?2
              AND chunk_index = ?3
            "#,
            params![generation, path, checked_i64(chunk_index, "分块序号")?],
            |row| {
                let bytes = row.get::<_, Vec<u8>>(1)?;
                let mut sha256 = [0_u8; 32];
                if bytes.len() == sha256.len() {
                    sha256.copy_from_slice(&bytes);
                }
                Ok(ExactChunkHash {
                    index: chunk_index,
                    byte_count: nonnegative_u64(row.get::<_, i64>(0)?),
                    sha256,
                })
            },
        )
        .optional()
        .map_err(|error| format!("无法读取会话文件分块校验值：{error}"))
}

fn hash_file_chunk(
    handle: &mut fs::File,
    path: &Path,
    chunk_index: u64,
    byte_count: u64,
) -> Result<ExactChunkHash, String> {
    let offset = chunk_index
        .checked_mul(EXACT_INDEX_CHUNK_SIZE)
        .ok_or_else(|| format!("会话文件分块位置溢出：{}", path.display()))?;
    handle.seek(SeekFrom::Start(offset)).map_err(|error| {
        format!(
            "无法定位会话文件分块以完成一致性校验：{}（{}）",
            path.display(),
            error
        )
    })?;
    let mut remaining = byte_count;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    while remaining > 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64)).unwrap_or(buffer.len());
        let bytes_read = handle
            .read(&mut buffer[..requested])
            .map_err(|error| format!("复核会话文件分块失败：{}（{}）", path.display(), error))?;
        if bytes_read == 0 {
            return Err(format!(
                "复核会话文件分块时提前到达结尾：{}",
                path.display()
            ));
        }
        hasher.update(&buffer[..bytes_read]);
        remaining = remaining.saturating_sub(bytes_read as u64);
    }
    Ok(ExactChunkHash {
        index: chunk_index,
        byte_count,
        sha256: hasher.finalize().into(),
    })
}

fn validate_append_scan_prefix(
    path: &Path,
    handle: &mut fs::File,
    start_signature: FileSignature,
    chunk_hashes: &[ExactChunkHash],
) -> Result<(), String> {
    let handle_after = file_signature_from_handle(handle, path)?;
    let path_after = file_signature(path)?;
    validate_prefix_identity(start_signature, handle_after, path_after)?;
    if handle_after == start_signature && path_after == start_signature {
        return Ok(());
    }
    let tail_index = start_signature
        .size
        .checked_sub(1)
        .map(|offset| offset / EXACT_INDEX_CHUNK_SIZE);
    let Some(tail_index) = tail_index else {
        return Ok(());
    };
    let Some(scanned_tail) = chunk_hashes.iter().find(|chunk| chunk.index == tail_index) else {
        return Err("追加扫描缺少末块校验值".into());
    };
    let prefix_byte_count = start_signature
        .size
        .saturating_sub(tail_index.saturating_mul(EXACT_INDEX_CHUNK_SIZE));
    let current_tail = hash_file_chunk(handle, path, tail_index, prefix_byte_count)?;
    if current_tail.sha256 != scanned_tail.sha256
        || current_tail.byte_count != scanned_tail.byte_count
    {
        return Err("扫描起点末块内的既有字节被改写".into());
    }
    if handle_after.size == start_signature.size || path_after.size == start_signature.size {
        return Err("扫描期间文件元数据变化但没有保持纯追加形态".into());
    }
    Ok(())
}

fn replace_file_chunks(
    transaction: &Transaction<'_>,
    generation: i64,
    path: &str,
    starting_at: u64,
    chunks: &[ExactChunkHash],
) -> Result<(), String> {
    transaction
        .execute(
            r#"
            DELETE FROM file_chunks
            WHERE file_generation = ?1
              AND file_path = ?2
              AND chunk_index >= ?3
            "#,
            params![generation, path, checked_i64(starting_at, "分块起始序号")?],
        )
        .map_err(|error| format!("无法清理会话文件待更新分块：{error}"))?;
    let mut statement = transaction
        .prepare(
            r#"
            INSERT INTO file_chunks(
                file_generation,
                file_path,
                chunk_index,
                byte_count,
                sha256
            ) VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )
        .map_err(|error| format!("无法准备会话文件分块写入：{error}"))?;
    for chunk in chunks {
        statement
            .execute(params![
                generation,
                path,
                checked_i64(chunk.index, "分块序号")?,
                checked_i64(chunk.byte_count, "分块字节数")?,
                chunk.sha256.as_slice(),
            ])
            .map_err(|error| format!("无法写入会话文件分块校验值：{error}"))?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn save_file_checkpoint(
    transaction: &Transaction<'_>,
    generation: i64,
    path: &str,
    signature: FileSignature,
    resume_offset: u64,
    state: ExactSessionParserState,
    audit_chunk_index: u64,
) -> Result<(), String> {
    let current_user_prompt_start = checked_optional_i64(
        state.current_user_prompt.map(|range| range.start),
        "检查点用户问题起始位置",
    )?;
    let current_user_prompt_end = checked_optional_i64(
        state.current_user_prompt.map(|range| range.end),
        "检查点用户问题结束位置",
    )?;
    let assistant_response_start = checked_optional_i64(
        state.assistant_response.map(|range| range.start),
        "检查点回答起始位置",
    )?;
    let assistant_response_end = checked_optional_i64(
        state.assistant_response.map(|range| range.end),
        "检查点回答结束位置",
    )?;
    transaction
        .execute(
            r#"
            UPDATE files
            SET
                size = ?3,
                modified_ns = ?4,
                device_id = ?5,
                file_id = ?6,
                changed_ns = ?7,
                append_ready = 1,
                resume_offset = ?8,
                previous_total_tokens = ?9,
                fork_replay_started_ns = ?10,
                fork_replay_active = ?11,
                last_skipped_fork_replay_token_ns = ?12,
                current_user_prompt_start = ?13,
                current_user_prompt_end = ?14,
                assistant_response_start = ?15,
                assistant_response_end = ?16,
                audit_chunk_index = ?17
            WHERE generation = ?1 AND path = ?2
            "#,
            params![
                generation,
                path,
                checked_i64(signature.size, "会话文件大小")?,
                signature.modified_ns.to_string(),
                signature.identity.device_id.to_string(),
                signature.identity.file_id.to_string(),
                signature.changed_ns.to_string(),
                checked_i64(resume_offset, "会话文件续扫位置")?,
                checked_optional_i64(state.previous_total_tokens, "检查点累计 token")?,
                timestamp_ns_text(state.fork_replay_started_at),
                state.fork_replay_active,
                timestamp_ns_text(state.last_skipped_fork_replay_token_at),
                current_user_prompt_start,
                current_user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                checked_i64(audit_chunk_index, "滚动审计分块序号")?,
            ],
        )
        .map_err(|error| format!("无法保存会话文件追加检查点：{error}"))?;
    Ok(())
}

fn timestamp_ns_text(value: Option<OffsetDateTime>) -> Option<String> {
    value.map(|timestamp| timestamp.unix_timestamp_nanos().to_string())
}

fn parse_timestamp_ns(value: Option<String>) -> Option<OffsetDateTime> {
    value
        .and_then(|raw| raw.parse::<i128>().ok())
        .and_then(|nanoseconds| OffsetDateTime::from_unix_timestamp_nanos(nanoseconds).ok())
}

fn prune_obsolete_file_versions(connection: &Connection, path: &str) -> Result<(), String> {
    let has_obsolete = connection
        .query_row(
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM files candidate
                WHERE candidate.path = ?1
                  AND candidate.generation < (
                      SELECT MAX(visible.generation)
                      FROM files visible
                      WHERE visible.path = ?1
                        AND visible.generation <= COALESCE(
                            (
                                SELECT CAST(value AS INTEGER)
                                FROM metadata
                                WHERE key = 'published_generation'
                            ),
                            0
                        )
                  )
            )
            "#,
            params![path],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查会话文件旧索引版本：{error}"))?;
    if !has_obsolete {
        return Ok(());
    }
    connection
        .execute(
            r#"
            DELETE FROM files
            WHERE path = ?1
              AND generation < (
                  SELECT MAX(visible.generation)
                  FROM files visible
                  WHERE visible.path = ?1
                    AND visible.generation <= COALESCE(
                        (
                            SELECT CAST(value AS INTEGER)
                            FROM metadata
                            WHERE key = 'published_generation'
                        ),
                        0
                    )
              )
            "#,
            params![path],
        )
        .map(|_| ())
        .map_err(|error| format!("无法清理会话文件旧索引版本：{error}"))
}

fn visit_session_files(
    connection: &mut Connection,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    mut visit: impl FnMut(&mut Connection, &Path, &mut Vec<LocalDataWarning>) -> Result<(), String>,
) -> Result<(), String> {
    super::record_dashboard_source_scan_for_testing();
    let canonical_home = canonical_codex_home(codex_home)?;
    let sessions_root = codex_home.join("sessions");
    if sessions_root.exists() {
        enqueue_directory(connection, &canonical_home, &sessions_root, warnings)?;
        loop {
            let directory = connection
                .query_row(
                    "SELECT path FROM exact_seen_directories WHERE processed = 0 ORDER BY path LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| format!("无法读取会话目录外存队列：{error}"))?;
            let Some(directory) = directory else {
                break;
            };
            connection
                .execute(
                    "UPDATE exact_seen_directories SET processed = 1 WHERE path = ?1",
                    params![&directory],
                )
                .map_err(|error| format!("无法推进会话目录外存队列：{error}"))?;
            let directory = PathBuf::from(directory);
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
                    enqueue_directory(connection, &canonical_home, &path, warnings)?;
                } else if path
                    .extension()
                    .is_some_and(|extension| extension == "jsonl")
                {
                    if let Some(file) =
                        resolve_file_within_codex_home(&canonical_home, &path, "会话目录", warnings)
                    {
                        visit(connection, &file, warnings)?;
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

    visit_active_rollouts(connection, codex_home, &canonical_home, warnings, visit)
}

fn enqueue_directory(
    connection: &Connection,
    canonical_home: &Path,
    directory: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<(), String> {
    let canonical = match fs::canonicalize(directory) {
        Ok(canonical) if canonical.starts_with(canonical_home) => canonical,
        Ok(canonical) => {
            warnings.push(scan_warning(format!(
                "拒绝读取 Codex Home 外的会话目录：{} -> {}",
                directory.display(),
                canonical.display()
            )));
            return Ok(());
        }
        Err(error) => {
            warnings.push(scan_warning(format!(
                "无法确认会话目录边界：{}（{}）",
                directory.display(),
                error
            )));
            return Ok(());
        }
    };
    connection
        .execute(
            "INSERT OR IGNORE INTO exact_seen_directories(path, processed) VALUES (?1, 0)",
            params![canonical.to_string_lossy().as_ref()],
        )
        .map(|_| ())
        .map_err(|error| format!("无法写入会话目录外存队列：{error}"))
}

fn visit_active_rollouts(
    index_connection: &mut Connection,
    codex_home: &Path,
    canonical_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    mut visit: impl FnMut(&mut Connection, &Path, &mut Vec<LocalDataWarning>) -> Result<(), String>,
) -> Result<(), String> {
    let database = codex_home.join("state_5.sqlite");
    if !database.exists() {
        return Ok(());
    }
    let state_connection = sqlite::open_read_only(&database, StdDuration::from_millis(100))
        .map_err(|error| {
            let message = format!(
                "读取 active rollout 索引失败：{}（{}）",
                database.display(),
                error
            );
            warnings.push(scan_warning(message.clone()));
            message
        })?;
    if !column_exists(&state_connection, "threads", "rollout_path") {
        return Ok(());
    }
    let archived_filter = if column_exists(&state_connection, "threads", "archived") {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let sql = format!(
        "SELECT rollout_path FROM threads WHERE {archived_filter} AND rollout_path IS NOT NULL AND rollout_path <> ''"
    );
    let mut statement = state_connection
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
                visit(index_connection, &file, warnings)?;
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
) -> Result<(ManagedIndexConnection, bool), String> {
    if !existed_before {
        let connection = open_index_connection(path)?;
        return managed_index_connection(path, connection)
            .map(|connection| (connection, false));
    }

    let states = index_integrity_states();
    let mut states = states
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let signature_before_open = index_storage_signature(path)?;
    let signature_is_verified = states.get(path).is_some_and(|state| {
        state.active_connections > 0 || state.signature == signature_before_open
    });
    let integrity_failure = match open_index_connection(path) {
        Ok(connection) if signature_is_verified => {
            let signature = index_storage_signature(path)?;
            let connection =
                register_index_connection(&mut states, path, connection, signature);
            return Ok((connection, false));
        }
        Ok(connection) => match quick_check_index(&connection) {
            Ok(()) => {
                let signature = index_storage_signature(path)?;
                let connection =
                    register_index_connection(&mut states, path, connection, signature);
                return Ok((connection, false));
            }
            Err(error) => {
                drop(connection);
                error
            }
        },
        Err(error) => error,
    };
    states.remove(path);
    drop(states);

    remove_index_storage(path).map_err(|rebuild_error| {
        format!(
            "精确 token 索引完整性检查失败，且无法移除损坏索引：{integrity_failure}；{rebuild_error}"
        )
    })?;
    let connection = open_index_connection(path).map_err(|rebuild_error| {
        format!(
            "精确 token 索引完整性检查失败，自动重建也失败：{integrity_failure}；{rebuild_error}"
        )
    })?;
    managed_index_connection(path, connection)
        .map(|connection| (connection, true))
        .map_err(|rebuild_error| {
            format!(
                "精确 token 索引完整性检查失败，自动重建也失败：{integrity_failure}；{rebuild_error}"
            )
        })
}

fn quick_check_index(connection: &Connection) -> Result<(), String> {
    #[cfg(test)]
    QUICK_CHECK_COUNT.fetch_add(1, Ordering::SeqCst);
    let result = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法完成 SQLite quick_check：{error}"))?;
    if result.eq_ignore_ascii_case("ok") {
        Ok(())
    } else {
        Err(format!("SQLite quick_check 报告损坏：{result}"))
    }
}

fn index_integrity_states() -> &'static Mutex<HashMap<PathBuf, IndexIntegrityState>> {
    INDEX_INTEGRITY_STATES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn index_storage_signature(path: &Path) -> Result<IndexStorageSignature, String> {
    Ok(IndexStorageSignature {
        database: file_signature(path)?,
        wal: optional_index_sidecar_signature(&sqlite_sidecar_path(path, "-wal"))?,
    })
}

fn optional_index_sidecar_signature(path: &Path) -> Result<Option<FileSignature>, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝读取符号链接形式的精确 token 索引侧写文件：{}",
            path.display()
        )),
        Ok(metadata) if !metadata.is_file() => Err(format!(
            "精确 token 索引侧写路径不是普通文件：{}",
            path.display()
        )),
        Ok(_) => file_signature(path).map(Some),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!(
            "无法检查精确 token 索引侧写路径 {}：{}",
            path.display(),
            error
        )),
    }
}

fn managed_index_connection(
    path: &Path,
    connection: Connection,
) -> Result<ManagedIndexConnection, String> {
    let states = index_integrity_states();
    let mut states = states
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let signature = index_storage_signature(path)?;
    Ok(register_index_connection(
        &mut states,
        path,
        connection,
        signature,
    ))
}

fn register_index_connection(
    states: &mut HashMap<PathBuf, IndexIntegrityState>,
    path: &Path,
    connection: Connection,
    signature: IndexStorageSignature,
) -> ManagedIndexConnection {
    let active_connections = states
        .get(path)
        .map(|state| state.active_connections)
        .unwrap_or(0)
        .saturating_add(1);
    states.insert(
        path.to_path_buf(),
        IndexIntegrityState {
            signature,
            active_connections,
        },
    );
    ManagedIndexConnection::from_registered(connection, path.to_path_buf())
}

fn finish_index_connection(
    states: &mut HashMap<PathBuf, IndexIntegrityState>,
    path: &Path,
) {
    let remaining_connections = states
        .get(path)
        .map(|state| state.active_connections.saturating_sub(1))
        .unwrap_or(0);
    match index_storage_signature(path) {
        Ok(signature) => {
            states.insert(
                path.to_path_buf(),
                IndexIntegrityState {
                    signature,
                    active_connections: remaining_connections,
                },
            );
        }
        Err(_) if remaining_connections == 0 => {
            states.remove(path);
        }
        Err(_) => {
            if let Some(state) = states.get_mut(path) {
                state.active_connections = remaining_connections;
            }
        }
    }
}

fn invalidate_index_integrity_signature(path: &Path) {
    let states = index_integrity_states();
    let mut states = states
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    states.remove(path);
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
            PRAGMA cache_size = -16384;
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
                generation INTEGER NOT NULL,
                path TEXT NOT NULL,
                deleted INTEGER NOT NULL,
                session_id TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_ns TEXT NOT NULL,
                device_id TEXT NOT NULL,
                file_id TEXT NOT NULL,
                changed_ns TEXT NOT NULL,
                prefix_sha256 BLOB NOT NULL,
                append_ready INTEGER NOT NULL DEFAULT 0,
                resume_offset INTEGER,
                previous_total_tokens INTEGER,
                fork_replay_started_ns TEXT,
                fork_replay_active INTEGER NOT NULL DEFAULT 0,
                last_skipped_fork_replay_token_ns TEXT,
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
            CREATE INDEX IF NOT EXISTS events_session_idx
                ON events(session_id, timestamp, file_generation, file_path, ordinal);

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

fn migrate_v4_index_for_append(connection: &Connection) -> Result<(), String> {
    let additions = [
        ("append_ready", "INTEGER NOT NULL DEFAULT 0"),
        ("resume_offset", "INTEGER"),
        ("previous_total_tokens", "INTEGER"),
        ("fork_replay_started_ns", "TEXT"),
        ("fork_replay_active", "INTEGER NOT NULL DEFAULT 0"),
        ("last_skipped_fork_replay_token_ns", "TEXT"),
        ("current_user_prompt_start", "INTEGER"),
        ("current_user_prompt_end", "INTEGER"),
        ("assistant_response_start", "INTEGER"),
        ("assistant_response_end", "INTEGER"),
        ("audit_chunk_index", "INTEGER NOT NULL DEFAULT 0"),
    ];
    for (column, definition) in additions {
        if column_exists(connection, "files", column) {
            continue;
        }
        connection
            .execute(
                &format!("ALTER TABLE files ADD COLUMN {column} {definition}"),
                [],
            )
            .map_err(|error| format!("无法增量迁移精确 token 追加索引字段 {column}：{error}"))?;
    }
    Ok(())
}

fn remove_index_storage(path: &Path) -> Result<(), String> {
    invalidate_index_integrity_signature(path);
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

    if handle_before == start_signature && path_before == start_signature {
        return Ok(());
    }

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
    #[cfg(test)]
    PREFIX_REHASH_COUNT.with(|count| count.set(count.get().saturating_add(1)));

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

#[cfg(test)]
fn run_after_file_commit_hook_for_testing(path: &Path) -> Result<(), String> {
    let hook = AFTER_FILE_COMMIT_HOOK.with(|slot| slot.borrow_mut().take());
    match hook {
        Some(hook) => hook(path),
        None => Ok(()),
    }
}

#[cfg(not(test))]
fn run_after_file_commit_hook_for_testing(_path: &Path) -> Result<(), String> {
    Ok(())
}

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
