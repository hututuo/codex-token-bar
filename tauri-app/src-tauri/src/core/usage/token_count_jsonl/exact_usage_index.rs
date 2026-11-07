mod ingest;
mod sources;
use ingest::{
    STAGING_MIN_FREE_RESERVE_BYTES, STAGING_MANIFEST_SCHEMA_VERSION, stage_full_rebuilds,
    staging_job_batches, ensure_staging_capacity, stage_or_reuse_full_rebuild,
    open_staging_connection, staging_schema_sql, validated_staged_full_rebuild,
    import_staged_full_rebuild, remove_staging_directory, staging_directory,
    staging_database_path, staging_database_paths, staging_database_digest,
    prepare_scan_temp_tables, process_scan_file_with_progress, reserve_staging_source,
    process_session_file, validate_building_generation_commit_scope, hash_file_chunk,
    prune_obsolete_file_versions, remove_staging_database_storage, hash_file_prefix,
    event_enrichment_source_count, event_enrichment_receipt_count,
    event_enrichment_pending_candidates, event_enrichment_pending_candidates_for_generation,
};
#[cfg(not(test))]
use ingest::{attach_stage_alias, detach_stage_alias};
#[cfg(test)]
pub(super) use ingest::staging_batch_shape_for_testing;
pub(super) use sources::{
    PreciseScanCandidate, PreciseScanDiscovery, ReadOnlySourceProbe, read_only_source_probe,
    estimate_precise_scan_total, estimate_precise_scan_total_with_source_revision,
};
use sources::{
    visit_session_files, canonical_codex_home, ResolvedSessionFile,
    resolve_file_within_codex_home, ensure_source_observations, record_source_observation,
    physical_file_stamp, lightweight_file_signature, file_signature,
    file_signature_from_handle, is_history_repair_workspace,
};
// Preserve the original lexical targets inside moved bodies without wrappers.
use super::{session_parser, scan_failure, precise_source_read_progress,
    record_dashboard_source_scan_for_testing};
mod read_model;
mod projections;
pub(super) use read_model::read_cache_turn_requests;
use read_model::{format_rfc3339_unix, format_rfc3339_nanos};
#[cfg(test)]
use read_model::format_precise_dashboard_phases;
use projections::{
    is_known_dashboard_pricing_revision, startup_attribution_safety_state,
    dashboard_5m_projection_matches_published_files, mark_dashboard_changed,
    rebuild_published_dashboard_aggregates, refresh_dashboard_file_aggregates,
    refresh_dashboard_turn_candidates_for_changed_generations,
    refresh_dashboard_turn_candidates_for_session, update_dashboard_append_aggregates,
    backfill_missing_dashboard_aggregates_for_generation, visible_duplicate_session_lineage,
    attribution_ledger_integrity_mismatch, synchronize_attribution_ledger,
    attribution_ledger_integrity, attribution_safety_state,
    rotate_attribution_provenance_epoch, opaque_attribution_source_id,
};
use ledger::{
    staged_enrichment_matches_published_events, prune_published_tombstone_versions,
    discard_schema11_tombstone_pending_children, record_missing_event_enrichment_source,
};
use store_metadata::{
    required_startup_metadata_text, required_startup_metadata_i64,
    required_startup_metadata_u64, optional_startup_metadata_u64, startup_metadata_bool,
};
use contracts::{nonnegative_u64, saturating_u32, source_range_from_columns};
// Preserve lexical paths inside moved bodies without new wrapper calls.
use super::{accounting, update_precise_dashboard_progress};
mod connection;
mod contracts;
mod store_metadata;
use connection::{
    Connection, Transaction, ManagedIndexConnection, open_published_index_read_only,
    existing_regular_index, open_index_connection_with_recovery, quick_check_staged,
    quick_check_index, index_integrity_gate, optional_index_sidecar_signature,
    invalidate_index_integrity_signature, open_index_connection, open_read_only_source,
    open_read_only_index, reject_orphaned_index_rows, verify_no_orphaned_index_rows,
};
#[cfg(not(test))]
use connection::open_exact_business_store;
#[cfg(test)]
pub(super) use connection::{IntegrityGateEnterHook, IntegrityGateReleaseHook,
    BeforeFinishIndexConnectionHook, integrity_receipt_path_for_testing};
use contracts::{
    INDEX_SCHEMA_VERSION, CURRENT_SCHEMA_VERSION, ACCOUNTING_SCHEMA_VERSION,
    GITHUB_BASE_SCHEMA_VERSION, LEGACY_SESSION_PARSER_REVISION,
    LEGACY_STAGED_PARSER_REVISION, PAGINATED_V4_PARSER_REVISION,
    PAGINATED_V4_STAGED_REVISION, PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION,
    PRE_COMPACTION_SESSION_PARSER_REVISION, PRE_COMPACTION_STAGED_PARSER_REVISION,
    EXACT_SESSION_PARSER_REVISION, FORK_REPLAY_BOUNDARY_REVISION,
    EVENT_ENRICHMENT_REVISION_KEY, PRE_COMPACTION_EVENT_ENRICHMENT_REVISION,
    EVENT_ENRICHMENT_REVISION, SESSION_CATALOG_SCHEMA_VERSION,
    ATTRIBUTION_PROVENANCE_EPOCH_KEY, ATTRIBUTION_LEDGER_EPOCH_KEY,
    ATTRIBUTION_LEDGER_INTEGRITY_KEY, ATTRIBUTION_UNSAFE_EPOCH_KEY,
    ATTRIBUTION_UNSAFE_GENERATION_KEY, ATTRIBUTION_UNSAFE_ID_KEY,
    ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY, ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY,
    BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY, DASHBOARD_REVISION_KEY,
    BUILDING_DASHBOARD_CHANGED_KEY, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY,
    DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY, DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
    DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY,
    DASHBOARD_AGGREGATE_SCHEMA_VERSION, DASHBOARD_AGGREGATE_PRICING_REVISION,
    ExactScanCompleteness, ExactScanDiagnostics, FileSignature, PhysicalFileStamp,
    IndexedFileCheckpoint, FullRebuildJob, StagingSourceBase, EventEnrichmentCandidate,
    StagedFullRebuild, StageSourceValidation, StageStoreSignature, StagedFullRebuildResult,
    StagedFullRebuildError, StageManifest, canonicalize_legacy_fingerprint,
    sqlite_sidecar_path, checked_i64, checked_optional_i64,
};
pub(super) use contracts::{
    ExactSyncMode, AttributionSafetyState, StartupIndexIdentity, DashboardAggregateIdentity,
    ExactDashboardData, PublishedDashboardReadMetadata, PARSER_REPAIR_VERIFY_KEY,
    STAGED_FULL_REBUILD_PARSER_REVISION, ORPHAN_REPAIR_REVISION_KEY, ORPHAN_REPAIR_REVISION,
};
use store_metadata::{
    table_row_count, table_exists_checked, metadata_text, metadata_i64, set_metadata,
    column_exists_checked,
};
use super::rollout_source::{self, RolloutReader, SourceHandle};
pub(super) mod cycle_range;
mod retention;
mod reconciler;
mod ledger;
mod canonical;
mod message_links;
mod dashboard_buckets;
mod schema;
mod session_catalog;
use session_catalog::{initialize_session_catalog_schema, validate_session_catalog_schema_version};
use schema::{initialize_index_schema, initialize_legacy_index_schema};
#[cfg(test)]
mod steady_refresh_tests;
use dashboard_buckets::refresh_range as refresh_dashboard_5m_range;
mod empty_sources;
mod representations;
mod runtime_recovery;
mod external_state;
mod thread_metadata;
mod migration;
mod publication;
use publication::publish_schema11_pending_generation;
use migration::{
    schema11_legacy_generation_state, schema11_lineage, schema11_migration_facts,
    Schema11MigrationFacts,
};
use thread_metadata::{
    publish_thread_metadata_only, stage_thread_metadata, sync_thread_metadata,
    ThreadMetadataStage,
};
#[cfg(any(test, feature = "business-store-fixture"))]
use thread_metadata::StagedThreadMetadata;
mod stage_row_codec;
mod stage_pool;
mod stage_pool_backup;

pub(crate) fn with_staging_quiesced_for_container_maintenance<T>(operation:impl FnOnce()->Result<T,String>)->Result<T,String> {
    stage_pool::with_idle_handles(operation)
}
pub(crate) fn start_stage_maintenance() { stage_pool::start_background_maintenance(); }
use super::accounting::{AccountingState, ACCOUNTING_REVISION};
use super::fingerprint_codec;
use super::session_files::session_id_from_file;
use super::session_parser::{
    probe_explicit_subagent_session_file, read_event_excerpt_batch, stream_session_file_exact,
    stream_session_file_exact_from, stream_session_file_exact_with_progress, ExactChunkHash, ExactEventSourceOffsets, ExactSessionEventSink,
    ExactSessionParserState, ExactTokenEvent, ExplicitSubagentSessionFileProbe, SourceByteRange,
    UsageSnapshotFingerprint, EXACT_INDEX_CHUNK_SIZE,
};
use super::{
    history_compression_enabled, IndexedSessionCatalogEntry, IndexedSessionCatalogSnapshot, IndexedSessionMetadata,
    SummaryFileContribution, TokenUsageSummary, TokenUsageSummarySnapshot,
};
#[cfg(not(test))]
use crate::core::app_paths;
use crate::core::localtime;
use crate::core::time_series_timeline::{
    aligned_bin_starts, LONG_RECENT_INTERVAL_SECONDS, LONG_RECENT_POINT_COUNT,
};
use crate::core::{
    app_operation_lock::AppOperationGuard, atomic_file, cross_process_lock::CrossProcessFileLock,
    startup_trace,
};
use crate::models::{
    ActivityDay, CacheHitRankingItem, CacheRequestUsage, DashboardStats, LocalDataWarning,
    ModelTokenBreakdown, RecentUsagePoint, RecentUsageSourceContribution, SessionCacheUsage,
    TokenCacheBreakdown, TokenCacheUsage, TurnCacheUsage,
};
use fs2::available_space;
#[cfg(test)]
use rusqlite::backup::Backup;
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration as StdDuration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};
use uuid::Uuid;

const MIGRATION_STAGE_TOTAL: u64 = 6;
const STORAGE_MAINTENANCE_LAST_CHECKED_KEY: &str = "storage_maintenance_last_checked_unix";
const STORAGE_MAINTENANCE_LAST_COMPACTED_KEY: &str = "storage_maintenance_last_compacted_unix";
const STORAGE_MAINTENANCE_INTERVAL_SECONDS: i64 = 24 * 60 * 60;
const STORAGE_MAINTENANCE_MIN_FREE_BYTES: u64 = 64 * 1024 * 1024;
const STORAGE_MAINTENANCE_ABSOLUTE_FREE_BYTES: u64 = 256 * 1024 * 1024;
const STORAGE_MAINTENANCE_MIN_FREE_PERCENT: u64 = 20;
const STORAGE_MAINTENANCE_DISK_RESERVE_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone, Copy)]
struct ExactStorageMaintenancePolicy {
    minimum_check_interval_seconds: i64,
    minimum_free_bytes: u64,
    absolute_free_bytes: u64,
    minimum_free_percent: u64,
    disk_reserve_bytes: u64,
}

impl Default for ExactStorageMaintenancePolicy {
    fn default() -> Self {
        Self {
            minimum_check_interval_seconds: STORAGE_MAINTENANCE_INTERVAL_SECONDS,
            minimum_free_bytes: STORAGE_MAINTENANCE_MIN_FREE_BYTES,
            absolute_free_bytes: STORAGE_MAINTENANCE_ABSOLUTE_FREE_BYTES,
            minimum_free_percent: STORAGE_MAINTENANCE_MIN_FREE_PERCENT,
            disk_reserve_bytes: STORAGE_MAINTENANCE_DISK_RESERVE_BYTES,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum ExactStorageMaintenanceOutcome {
    NotDue,
    Busy,
    BelowThreshold {
        database_bytes: u64,
        free_bytes: u64,
    },
    InsufficientSpace {
        database_bytes: u64,
        free_bytes: u64,
        available_bytes: u64,
        required_bytes: u64,
    },
    Compacted {
        before_bytes: u64,
        after_bytes: u64,
        reclaimed_bytes: u64,
    },
}

pub(super) struct ExactUsageIndex {
    connection: ManagedIndexConnection,
    // Keep the process-local Home lease alive for the complete index
    // operation, including migration, scan, and session-catalog publication.
    // The sidecar file lock below remains the cross-process boundary.
    _operation_lock: Option<AppOperationGuard>,
    published_read_only: bool,
    /// True while one or more durable migration markers still need the
    /// normal scan/final publication to complete.  The open phase may repair
    /// DDL and orphan rows, but the attribution ledger is only authoritative
    /// after `finalize_generation` has committed it.
    migration_pending: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum MigrationAssessment {
    Compatible,
    KnownMigrationRequired(Vec<&'static str>),
    UpgradeRequired {
        component: &'static str,
        stored: String,
        supported: String,
    },
    Corrupt {
        component: &'static str,
        raw_value: String,
    },
}

// Schema-11 migration is deliberately file-backed and resumable.  The
// manifest is a small control receipt; all user rows remain in SQLite and are
// copied through SQLite's online-backup API before any DDL runs.  Keep the
// phase names stable so an interrupted switch can be resumed by a later
// process without guessing which side of the rename was committed.
const SCHEMA11_CANDIDATE_MANIFEST_VERSION: u32 = 1;
const SCHEMA11_CANDIDATE_SUFFIX: &str = ".schema11-candidate";
const SCHEMA11_ROLLBACK_SUFFIX: &str = ".schema11-rollback";
const SCHEMA11_MIGRATION_SUFFIX: &str = ".schema11-migration.json";
const SCHEMA11_MIGRATION_SPACE_RESERVE_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
enum Schema11CandidatePhase {
    Prepared,
    Copied,
    Migrated,
    Validated,
    Switching,
    Switched,
    Retained,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct Schema11FileStamp {
    size: u64,
    modified_ns: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct Schema11SourceReceipt {
    schema_version: i64,
    revision: Option<String>,
    dashboard_revision: Option<String>,
    published_generation: Option<i64>,
    building_generation: Option<i64>,
    database: Schema11FileStamp,
    wal: Option<Schema11FileStamp>,
}

/// Proof made by this open, never deserialized from a manifest. A rename may
/// carry it to the canonical path only while DB/WAL stamps and lineage match.
/// Restarted migrations must make a new proof before they can reuse work.
struct Schema11ValidatedStorage {
    receipt: Schema11SourceReceipt,
    facts: Option<Schema11MigrationFacts>,
}

struct IndexPreparationTrace {
    stage: &'static str,
    started: Instant,
    complete: bool,
}

impl IndexPreparationTrace {
    fn new(stage: &'static str) -> Self {
        Self { stage, started: Instant::now(), complete: false }
    }

    fn record(&self, status: &str) {
        startup_trace::mark_performance(format!(
            "exact_prepare stage={} elapsed_ms={} status={status}",
            self.stage, self.started.elapsed().as_millis(),
        ));
    }

    fn advance(&mut self, stage: &'static str) {
        self.record("ok");
        self.stage = stage;
        self.started = Instant::now();
    }

    fn finish(mut self) {
        self.record("ok");
        self.complete = true;
    }
}

impl Drop for IndexPreparationTrace {
    fn drop(&mut self) {
        if !self.complete { self.record("error"); }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct Schema11CandidateManifest {
    manifest_version: u32,
    source_path: String,
    candidate_path: String,
    rollback_path: String,
    source_receipt: Schema11SourceReceipt,
    #[serde(default)]
    source_facts: Option<Schema11MigrationFacts>,
    phase: Schema11CandidatePhase,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ExactIndexUpgradeRequired {
    pub(crate) component: String,
    pub(crate) stored: String,
    pub(crate) supported: String,
}

impl MigrationAssessment {
    fn upgrade_required(&self) -> Option<ExactIndexUpgradeRequired> {
        match self {
            Self::UpgradeRequired {
                component,
                stored,
                supported,
            } => Some(ExactIndexUpgradeRequired {
                component: (*component).into(),
                stored: stored.clone(),
                supported: supported.clone(),
            }),
            Self::Compatible | Self::KnownMigrationRequired(_) | Self::Corrupt { .. } => None,
        }
    }

    fn blocking_error(&self) -> Option<String> {
        match self {
            Self::UpgradeRequired {
                component,
                stored,
                supported,
            } => {
                let display_component = match *component {
                    "legacy schema" => "schema",
                    "event enrichment" => "历史字段补全",
                    "session catalog schema" => "会话目录 schema",
                    "aggregate pricing" => "aggregate 计价契约",
                    other => other,
                };
                let version_relation = match *component {
                    "legacy schema" => "低于最低兼容版本",
                    "event enrichment" => "高于或不同于当前支持版本",
                    _ => "高于当前支持版本",
                };
                let version_separator = if *component == "event enrichment" {
                    ""
                } else {
                    " "
                };
                Some(format!(
                    "精确 token {display_component}{version_separator}版本 {stored} {version_relation} {supported}，需要升级软件，已拒绝覆盖；已拒绝写入或删除索引"
                ))
            }
            Self::Corrupt {
                component,
                raw_value,
            } => {
                let display_component = if *component == "schema_version" {
                    "schema 版本"
                } else {
                    *component
                };
                Some(format!(
                    "精确 token {display_component}未知或损坏（{raw_value:?}），已拒绝把损坏值当作缺失后覆盖"
                ))
            }
            Self::Compatible | Self::KnownMigrationRequired(_) => None,
        }
    }
}

/// Read-only compatibility probe used by the command boundary before starting
/// a precise owner. It deliberately does not run quick_check, DDL, repair, or
/// any cleanup, so a newer binary's index remains byte-for-byte untouched.
pub(super) fn index_upgrade_required(
    codex_home: &Path,
) -> Result<Option<ExactIndexUpgradeRequired>, String> {
    let path = database_path(codex_home)?;
    let read_only = open_published_index_read_only(&path, StdDuration::from_secs(1)).map_err(|error| {
        format!(
            "无法只读探测精确 token 索引兼容性 {}：{error}",
            path.display()
        )
    })?;
    let Some(read_only) = read_only else { return Ok(None); };
    let read_only = read_only.unchecked_transaction()
        .map_err(|error| format!("无法开始精确 token 兼容性只读快照：{error}"))?;
    let assessment = assess_index_migration(&read_only, true)?;
    if let Some(upgrade) = assessment.upgrade_required() {
        return Ok(Some(upgrade));
    }
    if let Some(error) = assessment.blocking_error() {
        return Err(error);
    }
    Ok(None)
}

/// v0.9.2 disables delete-and-rebuild recovery. A future repair workflow must
/// build and validate a separate candidate before a user-confirmed switch.
pub(super) fn rebuild_derived_storage_for_current_version(codex_home: &Path) -> Result<(), String> {
    let _ = codex_home;
    Err("自动删除式恢复入口已关闭；已保留上一份可信索引，等待候选库修复流程".into())
}

#[cfg(test)]
type AfterPrefixScanHook = Box<dyn FnOnce(&Path)>;
#[cfg(test)]
type AfterFileCommitHook = Box<dyn FnOnce(&Path) -> Result<(), String>>;
#[cfg(test)]
struct BeforeStagingOpenHook {
    target: PathBuf,
    action: Box<dyn FnOnce(&Path) + Send>,
}

#[cfg(test)]
static BEFORE_STAGING_OPEN_HOOK: OnceLock<Mutex<Option<BeforeStagingOpenHook>>> = OnceLock::new();
#[cfg(test)]
thread_local! {
    static AFTER_PREFIX_SCAN_HOOK: RefCell<Option<AfterPrefixScanHook>> = RefCell::new(None);
    static AFTER_FILE_COMMIT_HOOK: RefCell<Option<AfterFileCommitHook>> = RefCell::new(None);
    static AFTER_DASHBOARD_SNAPSHOT_HOOK: RefCell<Option<Box<dyn FnOnce()>>> = RefCell::new(None);
    static PREFIX_REHASH_COUNT: Cell<u64> = const { Cell::new(0) };
    static FAIL_SCHEMA9_MIGRATION_STAGE: Cell<u8> = const { Cell::new(0) };
    static FAIL_SCHEMA11_MIGRATION_STAGE: Cell<u8> = const { Cell::new(0) };
    static MIGRATION_AVAILABLE_BYTES_OVERRIDE: Cell<Option<u64>> = const { Cell::new(None) };
    static PREPARATION_FACTS_COUNT: Cell<u64> = const { Cell::new(0) };
    static AGGREGATE_REBUILD_COUNT: Cell<u64> = const { Cell::new(0) };
    static PUBLISHED_EVENT_COUNT_CALLS: Cell<u64> = const { Cell::new(0) };
}
#[cfg(test)]
static FULL_SCAN_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static APPEND_SCAN_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static METADATA_VALIDATION_BYTES: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static FAIL_AFTER_STAGING: AtomicBool = AtomicBool::new(false);
#[cfg(test)]
static STAGE_ACTIVE_WORKERS: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static STAGE_PEAK_WORKERS: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static STAGE_DELAY_MILLISECONDS: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static OPEN_MIGRATION_WORK_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static OPEN_DDL_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static OPEN_WRITE_TRANSACTION_COUNT: AtomicU64 = AtomicU64::new(0);
fn assess_index_migration(
    connection: &Connection,
    existed_before: bool,
) -> Result<MigrationAssessment, String> {
    if !existed_before {
        return Ok(MigrationAssessment::Compatible);
    }
    retention::validate(connection)?;
    ledger::validate(connection)?;
    if table_exists_checked(connection, "metadata")? { representations::validate(connection)?; }
    let metadata_exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'metadata')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法只读检查精确 token 元数据表：{error}"))?;
    if !metadata_exists {
        let has_user_tables = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND lower(substr(name,1,7)) <> 'sqlite_')",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("无法只读检查精确 token 旧表：{error}"))?;
        return Ok(if has_user_tables {
            MigrationAssessment::Corrupt {
                component: "schema_version",
                raw_value: "missing metadata table".into(),
            }
        } else {
            MigrationAssessment::Compatible
        });
    }

    let raw_schema = metadata_text(connection, "schema_version")?;
    let Some(raw_schema) = raw_schema else {
        let has_other_tables = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND lower(substr(name,1,7)) <> 'sqlite_' AND name <> 'metadata')",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("无法只读检查无版本精确 token 索引：{error}"))?;
        return Ok(if has_other_tables {
            MigrationAssessment::Corrupt {
                component: "schema_version",
                raw_value: "missing".into(),
            }
        } else {
            MigrationAssessment::Compatible
        });
    };
    let schema = match raw_schema.parse::<i64>() {
        Ok(value) => value,
        Err(_) => {
            return Ok(MigrationAssessment::Corrupt {
                component: "schema_version",
                raw_value: raw_schema,
            })
        }
    };
    if schema < GITHUB_BASE_SCHEMA_VERSION {
        return Ok(MigrationAssessment::UpgradeRequired {
            component: "legacy schema",
            stored: schema.to_string(),
            supported: GITHUB_BASE_SCHEMA_VERSION.to_string(),
        });
    }
    if schema > CURRENT_SCHEMA_VERSION {
        return Ok(MigrationAssessment::UpgradeRequired {
            component: "schema",
            stored: schema.to_string(),
            supported: CURRENT_SCHEMA_VERSION.to_string(),
        });
    }

    for (key, supported, component) in [
        (
            "fork_replay_boundary_revision",
            FORK_REPLAY_BOUNDARY_REVISION,
            "fork replay",
        ),
        (
            ORPHAN_REPAIR_REVISION_KEY,
            ORPHAN_REPAIR_REVISION,
            "orphan repair",
        ),
        (
            EVENT_ENRICHMENT_REVISION_KEY,
            EVENT_ENRICHMENT_REVISION,
            "event enrichment",
        ),
    ] {
        if let Some(stored) = metadata_text(connection, key)? {
            let compatible_previous = (key == "fork_replay_boundary_revision"
                && [LEGACY_SESSION_PARSER_REVISION, LEGACY_STAGED_PARSER_REVISION,
                    PAGINATED_V4_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION,
                    PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION,
                    PRE_COMPACTION_STAGED_PARSER_REVISION].contains(&stored.as_str()))
                || (key == EVENT_ENRICHMENT_REVISION_KEY
                    && stored == PRE_COMPACTION_EVENT_ENRICHMENT_REVISION);
            if stored != supported && !compatible_previous {
                return Ok(MigrationAssessment::UpgradeRequired {
                    component,
                    stored,
                    supported: supported.into(),
                });
            }
        }
    }
    if let Some(raw) = metadata_text(connection, "session_catalog_schema_version")? {
        let stored = match raw.parse::<i64>() {
            Ok(value) => value,
            Err(_) => {
                return Ok(MigrationAssessment::Corrupt {
                    component: "session catalog schema",
                    raw_value: raw,
                })
            }
        };
        if stored > SESSION_CATALOG_SCHEMA_VERSION {
            return Ok(MigrationAssessment::UpgradeRequired {
                component: "session catalog schema",
                stored: stored.to_string(),
                supported: SESSION_CATALOG_SCHEMA_VERSION.to_string(),
            });
        }
    }
    if let Some(raw) = metadata_text(connection, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)? {
        let stored = match raw.parse::<i64>() {
            Ok(value) => value,
            Err(_) => {
                return Ok(MigrationAssessment::Corrupt {
                    component: "aggregate schema",
                    raw_value: raw,
                })
            }
        };
        if stored > DASHBOARD_AGGREGATE_SCHEMA_VERSION {
            return Ok(MigrationAssessment::UpgradeRequired {
                component: "aggregate schema",
                stored: stored.to_string(),
                supported: DASHBOARD_AGGREGATE_SCHEMA_VERSION.to_string(),
            });
        }
    }
    if let Some(stored) = metadata_text(connection, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY)? {
        if !is_known_dashboard_pricing_revision(&stored) {
            return Ok(MigrationAssessment::UpgradeRequired {
                component: "aggregate pricing",
                stored,
                supported: DASHBOARD_AGGREGATE_PRICING_REVISION.into(),
            });
        }
    }

    let mut stages = Vec::new();
    if !table_exists_checked(connection,"usage_ledger_duplicates")?
        || metadata_i64(connection,"canonical_projection_pending")?.unwrap_or(0)!=0 {
        stages.push("canonicalLedger");
    }
    if schema < INDEX_SCHEMA_VERSION
        || !column_exists_checked(connection, "files", "current_model")?
        || !column_exists_checked(connection, "files", "is_explicit_subagent_fork")?
        || !column_exists_checked(connection, "events", "model")?
        || !column_exists_checked(connection, "events", "reasoning_output_tokens")?
    {
        stages.push("schema");
    }
    if schema < ACCOUNTING_SCHEMA_VERSION { stages.push("accounting"); }
    if schema < CURRENT_SCHEMA_VERSION { stages.push("representation"); }
    if metadata_text(connection, "fork_replay_boundary_revision")?.as_deref()
        != Some(FORK_REPLAY_BOUNDARY_REVISION)
    {
        stages.push("forkReplay");
    }
    if metadata_text(connection, ORPHAN_REPAIR_REVISION_KEY)?.as_deref()
        != Some(ORPHAN_REPAIR_REVISION)
    {
        stages.push("orphanRepair");
    }
    if metadata_text(connection, EVENT_ENRICHMENT_REVISION_KEY)?.as_deref()
        != Some(EVENT_ENRICHMENT_REVISION)
    {
        stages.push("eventEnrichment");
    }
    if metadata_text(connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
        .is_none_or(|value| value.trim().is_empty())
        || metadata_text(connection, ATTRIBUTION_LEDGER_EPOCH_KEY)?
            .is_none_or(|value| value.trim().is_empty())
        || metadata_text(connection, ATTRIBUTION_LEDGER_INTEGRITY_KEY)?
            .is_none_or(|value| value.trim().is_empty())
    {
        stages.push("attribution");
    }
    let session_catalog_supported = SESSION_CATALOG_SCHEMA_VERSION.to_string();
    if metadata_text(connection, "session_catalog_schema_version")?.as_deref()
        != Some(session_catalog_supported.as_str())
    {
        stages.push("sessionCatalog");
    }
    let aggregate_supported = DASHBOARD_AGGREGATE_SCHEMA_VERSION.to_string();
    if metadata_text(connection, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)?.as_deref()
        != Some(aggregate_supported.as_str())
    {
        stages.push("aggregate");
    }
    Ok(if stages.is_empty() {
        MigrationAssessment::Compatible
    } else {
        MigrationAssessment::KnownMigrationRequired(stages)
    })
}

fn pragma_u64(connection: &Connection, name: &str) -> Result<u64, String> {
    connection
        .query_row(&format!("PRAGMA {name}"), [], |row| row.get::<_, u64>(0))
        .map_err(|error| format!("无法读取精确 token 索引 {name}：{error}"))
}

pub(super) fn maintain_exact_index_storage_if_due(
    codex_home: &Path,
    now_unix: i64,
) -> Result<ExactStorageMaintenanceOutcome, String> {
    let _progress = super::PreciseProgressSuppression::enter();
    let mut index = ExactUsageIndex::open(codex_home)?;
    index.maintain_storage_if_due(now_unix, ExactStorageMaintenancePolicy::default(), None)
}

#[cfg(test)]
pub(super) fn maintain_exact_index_storage_for_testing(
    codex_home: &Path,
    now_unix: i64,
    minimum_check_interval_seconds: i64,
    available_bytes: u64,
) -> Result<ExactStorageMaintenanceOutcome, String> {
    let _progress = super::PreciseProgressSuppression::enter();
    let mut index = ExactUsageIndex::open(codex_home)?;
    index.maintain_storage_if_due(
        now_unix,
        ExactStorageMaintenancePolicy {
            minimum_check_interval_seconds,
            minimum_free_bytes: 1,
            absolute_free_bytes: 1,
            minimum_free_percent: 0,
            disk_reserve_bytes: 0,
        },
        Some(available_bytes),
    )
}

#[cfg(not(test))]
fn prepare_exact_store_for_home(home: &Path, path: &Path) -> Result<(), String> {
    use crate::core::business_store_route as route;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("无法准备精确索引目录：{e}"))?;
    }
    let legacy = app_paths::tauri_usage_cache_dir().ok_or("无法定位旧用量索引目录")?
        .join("exact-token-index").join(format!("{}.sqlite3", stable_path_fingerprint(home)));
    if route::exact_sources_already_consumed(path, &[path.to_path_buf(), legacy.clone()])? {
        return Ok(());
    }
    let already_imported = route::exact_store_has_objects(path)?;
    let mut sources = Vec::new();
    let mut manifests = Vec::new();
    for input in [path, legacy.as_path()] {
        let (source, manifest) = exact_legacy_recovery::runtime_source(input, already_imported)?;
        if let Some(source) = source { sources.push(source); }
        if let Some(manifest) = manifest { manifests.push(manifest); }
        if legacy == path { break; }
    }
    exact_legacy_recovery::verify_manifests(&manifests)?;
    drop(route::open_exact_store(path, &sources)?);
    exact_legacy_recovery::verify_manifests(&manifests)
}

impl ExactUsageIndex {
    pub(super) fn open(codex_home: &Path) -> Result<Self, String> {
        let path=database_path(codex_home)?;
        #[cfg(not(test))]
        prepare_exact_store_for_home(codex_home, &path)?;
        Self::open_at(codex_home,path)
    }

    #[cfg(test)]
    pub(super) fn open_at_for_testing(home: &Path, path: PathBuf) -> Result<Self, String> {
        Self::open_at(home, path)
    }

    fn open_at(codex_home: &Path,path: PathBuf) -> Result<Self, String> {
        let mut preparation = IndexPreparationTrace::new("in_process_lock");
        let operation_lock = AppOperationGuard::acquire(codex_home)?;
        preparation.advance("file_lock");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "无法创建精确 token 索引目录 {}：{}",
                    parent.display(),
                    error
                )
            })?;
        }
        let operation_lock_path = sqlite_sidecar_path(&path, ".operation.lock");
        super::update_precise_dashboard_progress(
            codex_home,
            "preparing",
            "正在打开精确索引",
            0,
            None,
        );
        let _operation_lock = CrossProcessFileLock::acquire_wait_with_hook(
            &operation_lock_path,
            "精确 token 索引",
            StdDuration::from_secs(30),
            || {
                super::update_precise_dashboard_progress(
                    codex_home,
                    "waiting",
                    "等待其他精确统计实例完成",
                    0,
                    None,
                )
            },
        )?;
        // Schema 9/10 are migrated in a managed sibling database.  The
        // active database is only opened read-only while the candidate is
        // copied and validated; the normal writable connection is created
        // only after the atomic switch has completed. Always consult the
        // managed manifest first: during the narrow rename window the
        // canonical path is intentionally absent, and treating that state as
        // a fresh install would create an empty replacement database.
        preparation.advance("candidate_prepare");
        let candidate_validation = prepare_schema11_candidate_if_needed(&path, codex_home)?;
        preparation.advance("compatibility_probe");
        let existed_before = existing_regular_index(&path)?;
        let (migration_assessment, metadata_table_exists) = if existed_before {
            let read_only =
                open_read_only_index(&path, StdDuration::from_secs(1)).map_err(|error| {
                    format!(
                        "无法在完整性检查前只读探测精确 token 索引 {}，已保留原索引并拒绝自动重建：{error}",
                        path.display()
                    )
                })?;
            let metadata_table_exists = read_only
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'metadata')",
                    [],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(|error| {
                    format!(
                        "无法只读检查精确 token 元数据表，已保留原索引并拒绝自动重建：{error}"
                    )
                })?;
            let assessment = assess_index_migration(&read_only, true).map_err(|error| {
                format!("无法只读检查精确 token 索引兼容性，已保留原索引并拒绝自动重建：{error}")
            })?;
            if let Some(error) = assessment.blocking_error() {
                return Err(error);
            }
            // Supported schema 9+ databases share the files/events graph
            // checked by the orphan verifier. If its one-time marker is
            // absent, check that graph on the existing read-only handle before
            // opening a writer or running compatibility DDL. A failed
            // preflight must leave the original database bytes untouched.
            if metadata_table_exists
                && metadata_i64(&read_only, "schema_version")?
                    .is_some_and(|version| version >= GITHUB_BASE_SCHEMA_VERSION)
                && metadata_text(&read_only, ORPHAN_REPAIR_REVISION_KEY)?.as_deref()
                    != Some(ORPHAN_REPAIR_REVISION)
            {
                reject_orphaned_index_rows(&read_only)?;
            }
            (assessment, metadata_table_exists)
        } else {
            (MigrationAssessment::Compatible, false)
        };
        // Schema 11 already has the structural/catalog layout. Component
        // accounting, representation and canonical-ledger upgrades install
        // their own schemas; they must not rewrite catalog markers before
        // the structural receipt is reused by the semantic transaction.
        let needs_migration_work = matches!(
            &migration_assessment,
            MigrationAssessment::KnownMigrationRequired(stages)
                if stages.iter().any(|stage| !["accounting", "representation", "canonicalLedger"].contains(stage))
        );
        preparation.advance("open_integrity");
        let (mut connection, recovered_corrupt_index) = open_index_connection_with_recovery(
            &path,
            existed_before,
            !existed_before || !metadata_table_exists || candidate_validation.is_some(),
            candidate_validation.as_ref(),
        )?;
        preparation.advance("schema_and_provenance");
        let raw_schema_version = metadata_text(&connection, "schema_version")?;
        let has_schema_version = raw_schema_version.is_some();
        let schema_version = raw_schema_version.and_then(|value| value.parse::<i64>().ok());
        let needs_schema_initialization = !existed_before
            || recovered_corrupt_index
            || !metadata_table_exists
            || schema_version.is_none()
            || needs_migration_work;
        // A future session-catalog revision must be rejected before any index
        // migration or schema DDL runs.  In particular, do not let the
        // legacy initializer below DROP a table owned by a newer build.
        validate_session_catalog_schema_version(&connection)?;
        for (key, supported, component) in [
            (
                "fork_replay_boundary_revision",
                FORK_REPLAY_BOUNDARY_REVISION,
                "fork replay",
            ),
            (
                ORPHAN_REPAIR_REVISION_KEY,
                ORPHAN_REPAIR_REVISION,
                "orphan repair",
            ),
        ] {
            if let Some(revision) = metadata_text(&connection, key)? {
                if revision != supported && !(key == "fork_replay_boundary_revision" && [LEGACY_SESSION_PARSER_REVISION, PAGINATED_V4_PARSER_REVISION, PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION].contains(&revision.as_str())) {
                    return Err(format!(
                        "精确 token {component} revision {revision} 高于或不同于当前支持版本 {supported}，需要升级软件，已拒绝覆盖"
                    ));
                }
            }
        }
        if let Some(version) = metadata_i64(&connection, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)? {
            if version > DASHBOARD_AGGREGATE_SCHEMA_VERSION {
                return Err(format!(
                    "精确 token aggregate schema {version} 高于当前支持版本 {DASHBOARD_AGGREGATE_SCHEMA_VERSION}，需要升级软件，已拒绝覆盖"
                ));
            }
        }
        if let Some(revision) =
            metadata_text(&connection, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY)?
        {
            if !is_known_dashboard_pricing_revision(&revision) {
                return Err(format!(
                    "精确 token aggregate 计价契约 {revision} 未知，需要升级软件，已拒绝覆盖"
                ));
            }
        }
        let stored_event_enrichment_revision =
            metadata_text(&connection, EVENT_ENRICHMENT_REVISION_KEY)?;
        if stored_event_enrichment_revision
            .as_deref()
            .is_some_and(|revision| {
                revision != EVENT_ENRICHMENT_REVISION
                    && revision != PRE_COMPACTION_EVENT_ENRICHMENT_REVISION
            })
        {
            return Err(format!(
                "精确 token 历史字段补全版本 {} 高于或不同于当前支持版本 {}，已拒绝覆盖",
                stored_event_enrichment_revision
                    .as_deref()
                    .unwrap_or_default(),
                EVENT_ENRICHMENT_REVISION
            ));
        }
        let event_enrichment_requires_sync = schema_version.is_some()
            && stored_event_enrichment_revision.as_deref() != Some(EVENT_ENRICHMENT_REVISION)
            && event_enrichment_source_count(&connection)? > 0;
        let mut should_report_migration = schema_version.is_some_and(|version| {
            (GITHUB_BASE_SCHEMA_VERSION..INDEX_SCHEMA_VERSION).contains(&version)
        }) || event_enrichment_requires_sync;
        if !should_report_migration && schema_version == Some(INDEX_SCHEMA_VERSION) {
            // A prior build can have advanced schema_version before a replay,
            // orphan, catalog, or attribution marker was durably written. Keep
            // the migration channel visible and retry those markers on open.
            should_report_migration = metadata_text(&connection, "fork_replay_boundary_revision")?
                .as_deref()
                != Some(FORK_REPLAY_BOUNDARY_REVISION)
                || metadata_text(&connection, ORPHAN_REPAIR_REVISION_KEY)?.as_deref()
                    != Some(ORPHAN_REPAIR_REVISION)
                || metadata_i64(&connection, "session_catalog_schema_version")?
                    != Some(SESSION_CATALOG_SCHEMA_VERSION)
                || !column_exists_checked(&connection, "events", "reasoning_output_tokens")?
                || metadata_text(&connection, EVENT_ENRICHMENT_REVISION_KEY)?.as_deref()
                    != Some(EVENT_ENRICHMENT_REVISION)
                || metadata_text(&connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?.is_none()
                || metadata_text(&connection, ATTRIBUTION_LEDGER_EPOCH_KEY)?.is_none()
                || metadata_text(&connection, ATTRIBUTION_LEDGER_INTEGRITY_KEY)?.is_none();
        }
        let mut replay_migration_complete = true;
        if existed_before && !recovered_corrupt_index {
            if !has_schema_version {
                let has_unmarked_tables = connection
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND lower(substr(name,1,7)) <> 'sqlite_' AND name <> 'metadata')",
                        [],
                        |row| row.get::<_, bool>(0),
                    )
                    .map_err(|error| format!("无法检查无 schema 标记的精确 token 索引：{error}"))?;
                if has_unmarked_tables {
                    return Err(
                        "精确 token 索引缺少 schema 版本标记，已拒绝把未知旧数据静默升级".into(),
                    );
                }
            }
            if has_schema_version && schema_version.is_none() {
                return Err("精确 token 索引 schema 版本未知或损坏，已拒绝覆盖".into());
            }
            if schema_version.is_some_and(|version| version > CURRENT_SCHEMA_VERSION) {
                return Err(format!(
                    "精确 token 索引版本 {:?} 高于当前支持版本 {}，已拒绝覆盖",
                    schema_version, CURRENT_SCHEMA_VERSION
                ));
            }
            if schema_version.is_some_and(|version| {
                !(GITHUB_BASE_SCHEMA_VERSION..=CURRENT_SCHEMA_VERSION).contains(&version)
            }) {
                return Err(format!(
                    "精确 token 索引 schema {schema_version:?} 不在 v0.9.1 升级基线内；已保留原数据库并停止写入"
                ));
            } else if schema_version.is_some() && needs_migration_work {
                if schema_version == Some(GITHUB_BASE_SCHEMA_VERSION) {
                    #[cfg(test)]
                    OPEN_MIGRATION_WORK_COUNT.fetch_add(1, Ordering::SeqCst);
                    #[cfg(test)]
                    OPEN_DDL_COUNT.fetch_add(1, Ordering::SeqCst);
                    #[cfg(test)]
                    OPEN_WRITE_TRANSACTION_COUNT.fetch_add(1, Ordering::SeqCst);
                    if should_report_migration {
                        super::update_precise_dashboard_progress(
                            codex_home,
                            "migrating",
                            "正在升级索引；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失（字段）",
                            0,
                            Some(MIGRATION_STAGE_TOTAL),
                        );
                    }
                    migrate_github_base_index_schema(&connection)?;
                    if should_report_migration {
                        super::update_precise_dashboard_progress(
                            codex_home,
                            "migrating",
                            "正在升级索引；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失（字段完成）",
                            1,
                            Some(MIGRATION_STAGE_TOTAL),
                        );
                    }
                }
                #[cfg(test)]
                OPEN_MIGRATION_WORK_COUNT.fetch_add(1, Ordering::SeqCst);
                #[cfg(test)]
                OPEN_WRITE_TRANSACTION_COUNT.fetch_add(1, Ordering::SeqCst);
                replay_migration_complete = repair_explicit_subagent_replay_boundary(&connection)?;
                if should_report_migration {
                    super::update_precise_dashboard_progress(
                        codex_home,
                        "migrating",
                        if replay_migration_complete {
                            "正在升级索引；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失（replay 完成）"
                        } else {
                            "正在升级索引；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失（replay 待重试）"
                        },
                        2,
                        Some(MIGRATION_STAGE_TOTAL),
                    );
                }
            }
        }
        if needs_schema_initialization {
            #[cfg(test)]
            OPEN_MIGRATION_WORK_COUNT.fetch_add(1, Ordering::SeqCst);
            #[cfg(test)]
            OPEN_DDL_COUNT.fetch_add(1, Ordering::SeqCst);
            initialize_index_schema(&connection)?;
            // Existing databases can contain child rows written while an older
            // connection had foreign_keys=OFF. quick_check validates page/index
            // structure, but it does not report those logical orphans.
            if should_report_migration {
                super::update_precise_dashboard_progress(
                    codex_home,
                    "migrating",
                    "正在升级索引；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失（孤儿行）",
                    3,
                    Some(MIGRATION_STAGE_TOTAL),
                );
            }
            #[cfg(test)]
            OPEN_MIGRATION_WORK_COUNT.fetch_add(1, Ordering::SeqCst);
            #[cfg(test)]
            OPEN_WRITE_TRANSACTION_COUNT.fetch_add(1, Ordering::SeqCst);
            verify_no_orphaned_index_rows(&mut connection)?;
            if should_report_migration {
                super::update_precise_dashboard_progress(
                    codex_home,
                    "migrating",
                    "正在升级索引；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失（会话目录）",
                    4,
                    Some(MIGRATION_STAGE_TOTAL),
                );
            }
            #[cfg(test)]
            OPEN_MIGRATION_WORK_COUNT.fetch_add(1, Ordering::SeqCst);
            #[cfg(test)]
            OPEN_DDL_COUNT.fetch_add(1, Ordering::SeqCst);
            #[cfg(test)]
            OPEN_WRITE_TRANSACTION_COUNT.fetch_add(1, Ordering::SeqCst);
            initialize_session_catalog_schema(&connection)?;
            if schema_version.is_none()
                && metadata_text(&connection, "fork_replay_boundary_revision")?.as_deref()
                    != Some(FORK_REPLAY_BOUNDARY_REVISION)
            {
                #[cfg(test)]
                OPEN_MIGRATION_WORK_COUNT.fetch_add(1, Ordering::SeqCst);
                #[cfg(test)]
                OPEN_WRITE_TRANSACTION_COUNT.fetch_add(1, Ordering::SeqCst);
                replay_migration_complete = repair_explicit_subagent_replay_boundary(&connection)?;
            }
        }
        if (!should_report_migration || replay_migration_complete)
            && !event_enrichment_requires_sync
            && schema_version != Some(INDEX_SCHEMA_VERSION)
            && schema_version != Some(CURRENT_SCHEMA_VERSION)
            && schema_version != Some(ACCOUNTING_SCHEMA_VERSION)
        {
            set_metadata(
                &connection,
                "schema_version",
                &INDEX_SCHEMA_VERSION.to_string(),
            )?;
            set_metadata(
                &connection,
                EVENT_ENRICHMENT_REVISION_KEY,
                EVENT_ENRICHMENT_REVISION,
            )?;
            // The v0.9.1 schema-9 database is upgraded in place. Only a new
            // database starts from zero.
            if !has_schema_version {
                set_metadata(&connection, "revision", &fresh_revision_seed().to_string())?;
                set_metadata(&connection, "published_generation", "0")?;
                connection
                    .execute(
                        "DELETE FROM metadata WHERE key IN (
                            'building_generation',
                            'building_changed',
                            'building_dashboard_changed',
                            'building_attribution_provenance_rotate'
                        )",
                        [],
                    )
                    .map_err(|error| format!("无法初始化精确 token 同步状态：{error}"))?;
            }
        }
        if metadata_i64(&connection, "published_generation")?.is_none() {
            set_metadata(&connection, "published_generation", "0")?;
        }

        let identity = codex_home_identity(codex_home);
        let stored_identity = metadata_text(&connection, "codex_home_identity")?;
        let logical_identity_mismatch = stored_identity
            .as_deref()
            .is_some_and(|stored| stored != identity);
        if logical_identity_mismatch {
            return Err(
                "精确 token 索引的规范化 Codex Home 路径不匹配；已保留原数据库并停止写入".into(),
            );
        }
        if stored_identity.is_none() {
            set_metadata(&connection, "codex_home_identity", &identity)?;
        }
        ensure_source_observations(&connection)?;
        if metadata_text(&connection, "codex_home_physical_identity")?.is_some() {
            connection
                .execute(
                    "DELETE FROM metadata WHERE key = 'codex_home_physical_identity'",
                    [],
                )
                .map_err(|error| format!("无法移除旧 Codex Home 物理身份元数据：{error}"))?;
        }
        if metadata_text(&connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
            .is_none_or(|value| value.trim().is_empty())
        {
            rotate_attribution_provenance_epoch(&connection)?;
        }
        if should_report_migration {
            super::update_precise_dashboard_progress(
                codex_home,
                "migrating",
                if event_enrichment_requires_sync {
                    "正在准备补全历史模型与 reasoning 信息；首次升级可能需要几分钟，原始数据不会丢失"
                } else {
                    "正在升级索引；首次可能短暂占用 CPU 和磁盘，原始数据不会丢失（等待扫描回填归因账本）"
                },
                5,
                Some(MIGRATION_STAGE_TOTAL),
            );
        }

        // Older v8 indexes do not have a dashboard-specific lineage marker.
        // Seed it from the existing generic revision once, so upgrading keeps
        // the old aggregate cache addressable without a history rebuild. A
        // malformed/missing value is treated as absent by metadata_i64 and is
        // safely re-seeded from the trusted generic revision.
        if metadata_i64(&connection, DASHBOARD_REVISION_KEY)?.is_none() {
            let revision =
                metadata_i64(&connection, "revision")?.unwrap_or_else(fresh_revision_seed);
            set_metadata(&connection, DASHBOARD_REVISION_KEY, &revision.to_string())?;
        }
        // Capture structural proof before the additive protection tables are
        // installed. Those known writes do not change the validated events.
        let accounting_receipt = accounting_structural_receipt(&connection,candidate_validation.as_ref())?;
        retention::install(&connection)?;
        ledger::install(&connection)?;
        preparation.advance("accounting_migration");
        apply_accounting_migration(&mut connection, accounting_receipt)?;
        dashboard_buckets::install(&connection)?;
        canonical::ensure_published_projection(&connection)?;
        representations::migrate(&mut connection, &path, existed_before)?;
        retention::install(&connection)?;
        preparation.advance("finalize_open");
        let migration_markers_complete = !should_report_migration
            || migration_markers_complete(&connection, replay_migration_complete)?;
        if should_report_migration && migration_markers_complete {
            super::update_precise_dashboard_progress(
                codex_home,
                "migrating",
                "索引升级完成，正在准备精确扫描",
                MIGRATION_STAGE_TOTAL,
                Some(MIGRATION_STAGE_TOTAL),
            );
        }

        if migration_markers_complete {
            connection.mark_receipt_eligible();
        } else {
            connection.mark_receipt_dirty();
        }
        if migration_markers_complete {
            super::update_precise_dashboard_progress(
                codex_home,
                "preparing",
                "索引结构已就绪，准备扫描精确历史",
                0,
                None,
            );
        } else {
            super::update_precise_dashboard_progress(
                codex_home,
                "migrating",
                "索引升级等待正式扫描回填归因账本",
                5,
                Some(MIGRATION_STAGE_TOTAL),
            );
        }
        preparation.finish();
        Ok(Self {
            connection,
            _operation_lock: Some(operation_lock),
            migration_pending: !migration_markers_complete,
            published_read_only: false,
        })
    }

    fn maintain_storage_if_due(
        &mut self,
        now_unix: i64,
        policy: ExactStorageMaintenancePolicy,
        available_bytes_override: Option<u64>,
    ) -> Result<ExactStorageMaintenanceOutcome, String> {
        if self.migration_pending {
            return Ok(ExactStorageMaintenanceOutcome::NotDue);
        }
        #[cfg(not(test))]
        {
            use crate::core::business_store_route::{
                ContainerMaintenanceOutcome, ContainerMaintenancePolicy,
            };
            let outcome = crate::core::business_store_route::maintain_container_storage_if_due(
                now_unix,
                ContainerMaintenancePolicy {
                    minimum_check_interval_seconds: policy.minimum_check_interval_seconds,
                    minimum_free_bytes: policy.minimum_free_bytes,
                    absolute_free_bytes: policy.absolute_free_bytes,
                    minimum_free_percent: policy.minimum_free_percent,
                    disk_reserve_bytes: policy.disk_reserve_bytes,
                },
                available_bytes_override,
            )?;
            return Ok(match outcome {
                ContainerMaintenanceOutcome::NotDue => ExactStorageMaintenanceOutcome::NotDue,
                ContainerMaintenanceOutcome::Busy => ExactStorageMaintenanceOutcome::Busy,
                ContainerMaintenanceOutcome::BelowThreshold {
                    database_bytes,
                    free_bytes,
                } => ExactStorageMaintenanceOutcome::BelowThreshold {
                    database_bytes,
                    free_bytes,
                },
                ContainerMaintenanceOutcome::InsufficientSpace {
                    database_bytes,
                    free_bytes,
                    available_bytes,
                    required_bytes,
                } => ExactStorageMaintenanceOutcome::InsufficientSpace {
                    database_bytes,
                    free_bytes,
                    available_bytes,
                    required_bytes,
                },
                ContainerMaintenanceOutcome::Compacted {
                    before_bytes,
                    after_bytes,
                    reclaimed_bytes,
                } => ExactStorageMaintenanceOutcome::Compacted {
                    before_bytes,
                    after_bytes,
                    reclaimed_bytes,
                },
            });
        }
        #[cfg(test)]
        {
        let last_checked = metadata_i64(&self.connection, STORAGE_MAINTENANCE_LAST_CHECKED_KEY)?;
        if last_checked.is_some_and(|last| {
            now_unix.saturating_sub(last) < policy.minimum_check_interval_seconds
        }) {
            return Ok(ExactStorageMaintenanceOutcome::NotDue);
        }

        let index_path = self.connection.path.clone();
        let operation_lock_path = sqlite_sidecar_path(&index_path, ".operation.lock");
        let Some(_operation_lock) =
            CrossProcessFileLock::try_acquire(&operation_lock_path, "精确 token 索引存储维护")?
        else {
            return Ok(ExactStorageMaintenanceOutcome::Busy);
        };
        let integrity_gate = index_integrity_gate(&index_path);
        let _integrity_guard = integrity_gate.enter_silent(&index_path);

        let page_size = pragma_u64(&self.connection, "page_size")?;
        let page_count = pragma_u64(&self.connection, "page_count")?;
        let free_pages = pragma_u64(&self.connection, "freelist_count")?;
        let database_bytes = page_count.saturating_mul(page_size);
        let free_bytes = free_pages.saturating_mul(page_size);
        let ratio_reached = page_count > 0
            && free_pages.saturating_mul(100)
                >= page_count.saturating_mul(policy.minimum_free_percent);
        let should_compact = free_bytes >= policy.minimum_free_bytes
            && (ratio_reached || free_bytes >= policy.absolute_free_bytes);
        if !should_compact {
            self.record_storage_maintenance_check(now_unix, false)?;
            return Ok(ExactStorageMaintenanceOutcome::BelowThreshold {
                database_bytes,
                free_bytes,
            });
        }

        // SQLite documents that VACUUM can need up to roughly twice the
        // current database size in temporary space. Keep an additional fixed
        // reserve so reclaiming a derived cache can never consume the user's
        // last writable bytes.
        let required_bytes = database_bytes
            .saturating_mul(2)
            .saturating_add(policy.disk_reserve_bytes);
        let capacity_root = index_path.parent().unwrap_or_else(|| Path::new("."));
        let available_bytes = if let Some(available_bytes) = available_bytes_override {
            available_bytes
        } else {
            available_space(capacity_root).map_err(|error| {
                format!(
                    "无法检查精确 token 索引维护可用空间 {}：{error}",
                    capacity_root.display()
                )
            })?
        };
        if available_bytes < required_bytes {
            self.record_storage_maintenance_check(now_unix, false)?;
            return Ok(ExactStorageMaintenanceOutcome::InsufficientSpace {
                database_bytes,
                free_bytes,
                available_bytes,
                required_bytes,
            });
        }

        self.connection.mark_receipt_dirty();
        self.connection
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
            .map_err(|error| format!("无法压缩精确 token 索引空闲页：{error}"))?;
        self.record_storage_maintenance_check(now_unix, true)?;
        self.connection.mark_receipt_eligible();

        let after_page_size = pragma_u64(&self.connection, "page_size")?;
        let after_page_count = pragma_u64(&self.connection, "page_count")?;
        let after_bytes = after_page_count.saturating_mul(after_page_size);
        Ok(ExactStorageMaintenanceOutcome::Compacted {
            before_bytes: database_bytes,
            after_bytes,
            reclaimed_bytes: database_bytes.saturating_sub(after_bytes),
        })
        }
    }

    fn record_storage_maintenance_check(
        &mut self,
        now_unix: i64,
        compacted: bool,
    ) -> Result<(), String> {
        self.connection.mark_receipt_dirty();
        set_metadata(
            &self.connection,
            STORAGE_MAINTENANCE_LAST_CHECKED_KEY,
            &now_unix.to_string(),
        )?;
        if compacted {
            set_metadata(
                &self.connection,
                STORAGE_MAINTENANCE_LAST_COMPACTED_KEY,
                &now_unix.to_string(),
            )?;
        }
        self.connection.mark_receipt_eligible();
        Ok(())
    }

    pub(super) fn refresh_session_catalog<F>(
        &mut self,
        codex_home: &Path,
        parser: F,
    ) -> Result<(), String>
    where
        F: FnMut(&[u8]) -> Result<IndexedSessionMetadata, String>,
    {
        session_catalog::refresh(&mut self.connection, codex_home, parser)
    }

    pub(super) fn session_catalog_snapshot(&self) -> Result<IndexedSessionCatalogSnapshot, String> {
        session_catalog::snapshot(&self.connection)
    }

    #[cfg(test)]
    pub(super) fn set_after_prefix_scan_hook_for_testing(hook: impl FnOnce(&Path) + 'static) {
        AFTER_PREFIX_SCAN_HOOK.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(hook));
        });
    }

    #[cfg(test)]
    pub(super) fn set_after_dashboard_snapshot_hook_for_testing(hook: impl FnOnce() + 'static) {
        AFTER_DASHBOARD_SNAPSHOT_HOOK.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(hook));
        });
    }

    #[cfg(test)]
    pub(super) fn set_before_staging_open_hook_for_testing(
        target: PathBuf,
        hook: impl FnOnce(&Path) + Send + 'static,
    ) {
        let slot = BEFORE_STAGING_OPEN_HOOK.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) =
            Some(BeforeStagingOpenHook {
                target,
                action: Box::new(hook),
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
        METADATA_VALIDATION_BYTES.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn scan_bytes_for_testing() -> (u64, u64) {
        (
            FULL_SCAN_BYTES.load(Ordering::SeqCst),
            APPEND_SCAN_BYTES.load(Ordering::SeqCst),
        )
    }

    #[cfg(test)]
    pub(super) fn metadata_validation_bytes_for_testing() -> u64 {
        METADATA_VALIDATION_BYTES.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(super) fn fail_after_staging_once_for_testing() {
        FAIL_AFTER_STAGING.store(true, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn fail_schema9_migration_stage_for_testing(stage: u8) {
        FAIL_SCHEMA9_MIGRATION_STAGE.with(|value| value.set(stage));
        FAIL_SCHEMA11_MIGRATION_STAGE.with(|value| value.set(stage));
    }

    #[cfg(test)]
    pub(super) fn override_migration_available_bytes_for_testing(available_bytes: u64) {
        MIGRATION_AVAILABLE_BYTES_OVERRIDE.with(|value| value.set(Some(available_bytes)));
    }

    #[cfg(test)]
    pub(super) fn reset_empty_source_work_for_testing() {
        empty_sources::reset_test_counters();
    }

    #[cfg(test)]
    pub(super) fn empty_source_work_for_testing() -> (u64, u64, u64) {
        empty_sources::test_counters()
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
    pub(super) fn reset_preparation_work_for_testing() {
        PREPARATION_FACTS_COUNT.with(|value| value.set(0));
        AGGREGATE_REBUILD_COUNT.with(|value| value.set(0));
    }

    #[cfg(test)]
    pub(super) fn preparation_work_for_testing() -> (u64, u64) {
        (PREPARATION_FACTS_COUNT.with(Cell::get), AGGREGATE_REBUILD_COUNT.with(Cell::get))
    }

    #[cfg(test)]
    pub(super) fn reset_open_work_counters_for_testing() {
        OPEN_MIGRATION_WORK_COUNT.store(0, Ordering::SeqCst);
        OPEN_DDL_COUNT.store(0, Ordering::SeqCst);
        OPEN_WRITE_TRANSACTION_COUNT.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn open_work_counters_for_testing() -> (u64, u64, u64) {
        (
            OPEN_MIGRATION_WORK_COUNT.load(Ordering::SeqCst),
            OPEN_DDL_COUNT.load(Ordering::SeqCst),
            OPEN_WRITE_TRANSACTION_COUNT.load(Ordering::SeqCst),
        )
    }

    #[cfg(test)]
    pub(super) fn mark_receipt_dirty_for_testing(&mut self) {
        self.connection.mark_receipt_dirty();
    }

    pub(super) fn sync(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<u64, String> {
        self.sync_with_scan_plan(codex_home, warnings, None, None)
    }

    /// Runs the unchanged durable index scan while optionally exposing a
    /// best-effort, UI-only denominator for progress. The estimate is never
    /// consulted by generation, tombstone, fingerprint, or publish logic.
    pub(super) fn sync_with_scan_total(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
        scan_total: Option<u64>,
    ) -> Result<u64, String> {
        self.sync_with_scan_plan(codex_home, warnings, None, scan_total)
    }

    /// Runs the durable scan, consuming a read-only discovery plan as a
    /// candidate hint.  The plan may be stale by the time this starts; every
    /// candidate is still opened and signed by `process_session_file`, while
    /// files created after discovery wait for the next scheduled discovery.
    pub(super) fn sync_with_scan_plan(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
        discovery: Option<PreciseScanDiscovery>,
        scan_total_override: Option<u64>,
    ) -> Result<u64, String> {
        self.sync_with_scan_plan_mode(
            codex_home,
            warnings,
            discovery,
            scan_total_override,
            ExactSyncMode::Full,
        )
    }

    pub(super) fn sync_with_scan_plan_mode(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
        discovery: Option<PreciseScanDiscovery>,
        scan_total_override: Option<u64>,
        mode: ExactSyncMode,
    ) -> Result<u64, String> {
        let revision = self.sync_with_scan_plan_mode_once(codex_home, warnings, discovery, scan_total_override, mode)?;
        if !self.migration_pending && metadata_text(&self.connection, PARSER_REPAIR_VERIFY_KEY)?.is_some() {
            // One bounded metadata-fast pass after a planned parser repair.
            // It clears a completed rewrite episode, but still detects genuine
            // lineage/ledger faults. Never launch this from a period read.
            let verified = self.sync_with_scan_plan_mode_once(codex_home, warnings, None, scan_total_override, mode)?;
            self.connection.mark_receipt_dirty();
            self.connection.execute("DELETE FROM metadata WHERE key=?1", [PARSER_REPAIR_VERIFY_KEY]).map_err(|e|e.to_string())?;
            self.connection.mark_receipt_eligible();
            return Ok(verified);
        }
        Ok(revision)
    }

    fn sync_with_scan_plan_mode_once(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
        discovery: Option<PreciseScanDiscovery>,
        scan_total_override: Option<u64>,
        mode: ExactSyncMode,
    ) -> Result<u64, String> {
        let cleanup_index_path = database_path(codex_home)?;
        let result = (|| -> Result<u64, String> {
            // The derived aggregate layer is disposable, but a newer build may
            // have written a schema this binary does not understand. Reject it
            // before the scan transaction can touch any aggregate rows.
            self.validate_dashboard_aggregate_compatibility()?;
            let scan_total =
                scan_total_override.or_else(|| discovery.as_ref().map(|plan| plan.candidate_total));
            let mut diagnostics = ExactScanDiagnostics {
                candidate_count: discovery
                    .as_ref()
                    .map(|plan| plan.candidates.len() as u64)
                    .unwrap_or_default(),
                ..ExactScanDiagnostics::default()
            };
            let index_path = database_path(codex_home)?;
            let operation_lock_path = sqlite_sidecar_path(&index_path, ".operation.lock");
            let _operation_lock = CrossProcessFileLock::acquire_wait_with_hook(
                &operation_lock_path,
                "精确 token 索引",
                StdDuration::from_secs(30),
                || {
                    super::update_precise_dashboard_progress(
                        codex_home,
                        "waiting",
                        "等待其他精确统计实例完成",
                        0,
                        scan_total,
                    )
                },
            )?;
            let integrity_gate = index_integrity_gate(&index_path);
            let _sync_gate_guard = integrity_gate.enter_silent(&index_path);
            let reusable_discovery = discovery.filter(|plan| plan.is_usable(codex_home));

            // Historical model/reasoning enrichment is a one-time, serial owner.
            // A brand-new index has no published files to enrich yet; let the
            // normal checkpoint scan create its first generation instead of
            // returning early after merely stamping the enrichment revision.
            // Once a generation has been published, enrichment owns that old
            // watermark first and then the same owner continues through the
            // ordinary checkpoint path.
            let has_published_sources = event_enrichment_source_count(&self.connection)? > 0;
            if has_published_sources
                && metadata_text(&self.connection, EVENT_ENRICHMENT_REVISION_KEY)?.as_deref()
                    != Some(EVENT_ENRICHMENT_REVISION)
            {
                let enrichment_revision =
                    self.synchronize_event_enrichment(codex_home, &index_path, warnings, mode)?;
                if metadata_text(&self.connection, EVENT_ENRICHMENT_REVISION_KEY)?.as_deref()
                    != Some(EVENT_ENRICHMENT_REVISION)
                {
                    return Ok(enrichment_revision);
                }
                if !self.migration_pending {
                    self.connection.mark_receipt_eligible();
                }
            }

            if !self.migration_pending && mode.builds_dashboard_derived_data()
                && metadata_i64(&self.connection, "building_generation")?.is_none() {
                message_links::repair(&mut self.connection, codex_home, warnings)?;
            }

            // A steady-state refresh is common: the source files and state
            // database have not changed since the last publication. Probe that
            // case before touching the durable scan state. In particular, do not
            // call begin_or_resume_generation here: it allocates a new generation
            // and copies the published dashboard rows even when the scan would be
            // a no-op.
            if !self.migration_pending
                && metadata_i64(&self.connection, "building_generation")?.is_none()
            {
                let sources_changed = if let Some(plan) = reusable_discovery.as_ref() {
                    self.sources_changed_from_discovery(plan)?
                } else {
                    self.sources_changed(codex_home, warnings)?
                };
                // A source probe can prove that JSONL files are unchanged while a
                // previously published attribution bucket was removed or edited.
                // The ledger integrity digest is cheap to recompute from SQLite;
                // only a mismatch bypasses the normal no-op fast path so the next
                // full owner can rotate and rebuild the ledger. Summary owners do
                // not pay this cost or start a repair scan.
                let ledger_integrity_mismatch = mode.builds_dashboard_derived_data()
                    && attribution_ledger_integrity_mismatch(&self.connection)?;
                let safety_retry_required = mode.builds_dashboard_derived_data()
                    && (metadata_i64(&self.connection, ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY)?
                        .unwrap_or(0)
                        != 0
                        || metadata_i64(
                            &self.connection,
                            ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY,
                        )?
                        .unwrap_or(0)
                            != 0);
                if !sources_changed && !ledger_integrity_mismatch && !safety_retry_required {
                    // A rewrite can leave an obsolete file generation behind even
                    // when the next source probe is otherwise unchanged.  Clean
                    // only those already-published superseded rows here; this is
                    // a metadata-only repair and never reads JSONL bodies or
                    // allocates a new generation.  The common no-op path still
                    // performs zero writes because the candidate query is empty.
                    let obsolete_paths = self
                        .connection
                        .prepare(
                            r#"
                        SELECT DISTINCT candidate.path
                        FROM files candidate
                        WHERE candidate.generation < (
                            SELECT MAX(visible.generation)
                            FROM files visible
                            WHERE visible.path = candidate.path
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
                        )
                        .map_err(|error| format!("无法检查会话文件旧索引版本：{error}"))?
                        .query_map([], |row| row.get::<_, String>(0))
                        .map_err(|error| format!("无法读取会话文件旧索引版本：{error}"))?
                        .collect::<Result<Vec<_>, _>>()
                        .map_err(|error| format!("无法解码会话文件旧索引版本：{error}"))?;
                    for path in obsolete_paths {
                        prune_obsolete_file_versions(&self.connection, &path)?;
                    }
                    let previous = (
                        metadata_text(&self.connection, "state_size")?,
                        metadata_text(&self.connection, "state_modified_ns")?,
                    );
                    let staged_thread_metadata =
                        stage_thread_metadata(codex_home, previous,
                            metadata_text(&self.connection, "state_source_signature")?, warnings)?;
                    if !mode.builds_dashboard_derived_data() {
                        // Summary owns exact facts only. Leave state_5.sqlite
                        // metadata for the Full owner; its signature is not
                        // advanced here, so a later owner will retry the same
                        // incremental metadata publication.
                        return match staged_thread_metadata {
                            ThreadMetadataStage::Updated(staged) => {
                                publish_thread_metadata_only(&mut self.connection, staged)
                            }
                            ThreadMetadataStage::Unchanged | ThreadMetadataStage::Failed => {
                                self.revision()
                            }
                        };
                    }
                    if !safety_retry_required {
                        // A preceding Summary owner may have committed new exact
                        // events while intentionally leaving the disposable
                        // aggregate generation behind. A Full request with no
                        // new JSONL must still consume that dirty derived scope.
                        // A state database that changed but could not be read is
                        // deliberately kept in this metadata-only path: the
                        // published JSONL rows remain trustworthy, and retrying
                        // the same read on the next cadence must not allocate a
                        // generation or write a WAL. Active rollout additions or
                        // removals are already surfaced by sources_changed.
                        let revision = match staged_thread_metadata {
                            ThreadMetadataStage::Updated(staged) => {
                                publish_thread_metadata_only(&mut self.connection, staged)?
                            }
                            ThreadMetadataStage::Unchanged | ThreadMetadataStage::Failed => {
                                self.revision()?
                            }
                        };
                        self.ensure_dashboard_aggregates(codex_home)?;
                        return Ok(revision);
                    }
                } else {
                    // The source-change probe owns a separate temporary selector.
                    // Release it once discovery hands over to the durable scan.
                    self.connection
                        .execute("DROP TABLE IF EXISTS temp.source_change_files_snapshot", [])
                        .map_err(|error| format!("无法清理精确 token 源文件快照：{error}"))?;
                }
            }

            self.connection.mark_receipt_dirty();
            let mut scan_completeness = ExactScanCompleteness::default();
            prune_published_tombstone_versions(&self.connection)?;
            prepare_scan_temp_tables(&self.connection)?;
            let generation = begin_or_resume_generation(&mut self.connection, mode)?;
            let mut full_rebuild_jobs = Vec::new();
            let mut empty_source_jobs = Vec::new();
            let mut scanned_files = 0_u64;
            let mut scanned_paths = HashSet::new();
            super::update_precise_dashboard_progress(
                codex_home,
                "scanning",
                "正在扫描精确历史；首次建立索引可能需要数分钟",
                0,
                scan_total,
            );
            if let Some(plan) = reusable_discovery {
                if plan.unresolved_boundary {
                    scan_completeness.mark_incomplete();
                }
                for message in plan.boundary_warnings {
                    warnings.push(scan_warning(message));
                }
                for candidate in plan.candidates {
                    process_scan_file_with_progress(
                        &mut self.connection,
                        generation,
                        codex_home,
                        &candidate.canonical_path,
                        warnings,
                        &mut scan_completeness,
                        &mut full_rebuild_jobs,
                        &mut empty_source_jobs,
                        &mut scanned_files,
                        &mut scanned_paths,
                        scan_total,
                        &mut diagnostics,
                        candidate.signature,
                        mode,
                    )?;
                }
            } else {
                let mut visit = |connection: &mut Connection,
                                 file: &Path,
                                 warnings: &mut Vec<LocalDataWarning>,
                                 scan_completeness: &mut ExactScanCompleteness|
                 -> Result<(), String> {
                    process_scan_file_with_progress(
                        connection,
                        generation,
                        codex_home,
                        file,
                        warnings,
                        scan_completeness,
                        &mut full_rebuild_jobs,
                        &mut empty_source_jobs,
                        &mut scanned_files,
                        &mut scanned_paths,
                        scan_total,
                        &mut diagnostics,
                        None,
                        mode,
                    )
                };
                visit_session_files(
                    &mut self.connection,
                    codex_home,
                    warnings,
                    &mut scan_completeness,
                    &mut visit,
                )?;
            }
            empty_sources::import_new_sources(
                &mut self.connection, generation, &empty_source_jobs,
                &mut full_rebuild_jobs, warnings, &mut scan_completeness, &mut diagnostics,
            )?;
            diagnostics.scanned_files = scanned_files;
            diagnostics.full_rebuild_files = diagnostics
                .full_rebuild_files
                .saturating_add(full_rebuild_jobs.len() as u64);
            let full_rebuild_total = full_rebuild_jobs.len() as u64;
            let mut completed_full_rebuilds = 0_u64;
            if full_rebuild_total > 0 {
                super::update_precise_dashboard_progress(
                    codex_home,
                    "scanning",
                    "正在解析需要补齐的精确历史文件",
                    0,
                    Some(full_rebuild_total),
                );
            }
            for batch in staging_job_batches(&full_rebuild_jobs) {
                let estimated_bytes = batch
                    .iter()
                    .fold(0_u64, |total, job| total.saturating_add(job.signature.size));
                ensure_staging_capacity(&index_path, estimated_bytes)?;
                let progress_home = codex_home.to_path_buf();
                let completed_before_batch = completed_full_rebuilds;
                let progress_callback: Arc<dyn Fn(u64) + Send + Sync> =
                    Arc::new(move |staged_count| {
                        super::update_precise_dashboard_progress(
                            &progress_home,
                            "scanning",
                            "正在解析需要补齐的精确历史文件",
                            completed_before_batch.saturating_add(staged_count),
                            Some(full_rebuild_total),
                        );
                    });
                let staged = stage_full_rebuilds(
                    &batch,
                    &index_path,
                    generation,
                    codex_home,
                    warnings,
                    &mut scan_completeness,
                    Some(progress_callback),
                )?;
                completed_full_rebuilds =
                    completed_full_rebuilds.saturating_add(staged.len() as u64);
                diagnostics.full_body_bytes = diagnostics.full_body_bytes.saturating_add(
                    staged.iter().fold(0_u64, |total, item| {
                        total.saturating_add(item.committed_signature.size)
                    }),
                );
                #[cfg(test)]
                if FAIL_AFTER_STAGING.swap(false, Ordering::SeqCst) {
                    return Err("injected interruption after durable exact token staging".into());
                }
                for staged_file in staged {
                    import_staged_full_rebuild(
                        &mut self.connection,
                        generation,
                        &staged_file,
                        mode,
                    )?;
                    remove_staging_database_storage(&staged_file.database_path)?;
                    run_after_file_commit_hook_for_testing(&staged_file.job.file)?;
                }
            }
            if scan_completeness.block_generation_publish {
                self.connection.mark_receipt_dirty();
                return Err("会话根目录暂时不可用，已保留上一份可信索引并停止本轮发布".into());
            }
            if scan_completeness.incomplete_source_scan {
                self.connection.mark_receipt_dirty();
                return Err("会话源扫描不完整，已保留上一份可信索引和本轮断点，停止发布".into());
            }
            if let Err(error) =
                validate_building_generation_commit_scope(&mut self.connection, generation, codex_home)
            {
                scan_completeness.block_publish();
                warnings.push(scan_warning(error));
            }
            if scan_completeness.block_generation_publish {
                self.connection.mark_receipt_dirty();
                return Err("会话根目录暂时不可用，已保留上一份可信索引并停止本轮发布".into());
            }
            super::update_precise_dashboard_progress(
                codex_home,
                "publishing",
                "正在原子提交精确索引 generation",
                0,
                Some(1),
            );
            let run_migrations = !migration_markers_complete(&self.connection, true)?;
            let finalize_started = Instant::now();
            let revision = finalize_generation(
                &mut self.connection,
                generation,
                codex_home,
                warnings,
                scan_completeness,
                mode,
                run_migrations,
            )?;
            startup_trace::mark_performance(format!(
                "precise_sync_finalize elapsed_ms={} derived={}",
                finalize_started.elapsed().as_millis(), u8::from(mode.builds_dashboard_derived_data()),
            ));
            diagnostics.published_watermark = revision;
            startup_trace::mark_performance(format!(
            "precise_scan candidate_count={} scanned_files={} append_scan_bytes={} metadata_validation_bytes={} metadata_only_files={} full_body_bytes={} pending_tail_bytes={} full_rebuild_files={} source_drift={} published_watermark={}",
            diagnostics.candidate_count,
            diagnostics.scanned_files,
            diagnostics.append_scan_bytes,
            diagnostics.metadata_validation_bytes,
            diagnostics.metadata_only_files,
            diagnostics.full_body_bytes,
            diagnostics.pending_tail_bytes,
            diagnostics.full_rebuild_files,
            u8::from(diagnostics.source_drift),
            diagnostics.published_watermark,
        ));
            if self.migration_pending {
                let migration_complete = migration_markers_complete(&self.connection, true)?;
                if migration_complete {
                    self.migration_pending = false;
                    super::update_precise_dashboard_progress(
                        codex_home,
                        "migrating",
                        "索引升级完成，归因账本已提交",
                        MIGRATION_STAGE_TOTAL,
                        Some(MIGRATION_STAGE_TOTAL),
                    );
                } else {
                    super::update_precise_dashboard_progress(
                        codex_home,
                        "migrating",
                        "索引升级尚未完成，保留已发布数据并将在下次启动继续",
                        5,
                        Some(MIGRATION_STAGE_TOTAL),
                    );
                }
            }
            remove_staging_directory(&index_path)?;
            if !self.migration_pending {
                self.connection.mark_receipt_eligible();
            } else {
                self.connection.mark_receipt_dirty();
            }
            super::update_precise_dashboard_progress(
                codex_home,
                "publishing",
                "正在提交精确统计结果",
                1,
                Some(1),
            );
            if self.migration_pending {
                super::update_precise_dashboard_progress(
                    codex_home,
                    "migrating",
                    "索引升级尚未完成，保留已发布数据并将在下次启动继续",
                    5,
                    Some(MIGRATION_STAGE_TOTAL),
                );
            }
            if mode.builds_dashboard_derived_data() {
                self.ensure_dashboard_aggregates(codex_home)?;
                if !self.migration_pending {
                    message_links::repair(&mut self.connection, codex_home, warnings)?;
                }
            }
            Ok(self.revision()?.max(revision))
        })();
        if result.is_ok() && !self.migration_pending {
            // Excluded accounting rows are handled by the numeric policy, not a
            // permanent refresh warning. Actual scan/migration failures remain visible.
            if let Err(error) = record_successful_migration_retention(&self.connection, &cleanup_index_path) {
                warnings.push(scan_warning(format!(
                    "索引已成功刷新，迁移成功标识暂未写入；旧数据保留，下次刷新重试：{error}"
                )));
            }
        }
        result
    }

    /// Refreshes the disposable session title projection without starting a
    /// new exact generation. A Summary owner may have already published the
    /// latest events; a Full request promoted afterwards still needs to make
    /// the dashboard's session metadata current before reading the snapshot.
    pub(super) fn sync_thread_metadata_without_scan(
        &mut self,
        codex_home: &Path,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<u64, String> {
        let previous = (
            metadata_text(&self.connection, "state_size")?,
            metadata_text(&self.connection, "state_modified_ns")?,
        );
        match stage_thread_metadata(codex_home, previous,
            metadata_text(&self.connection, "state_source_signature")?, warnings)? {
            ThreadMetadataStage::Updated(staged) => {
                self.connection.mark_receipt_dirty();
                let result = publish_thread_metadata_only(&mut self.connection, staged);
                if result.is_ok() && !self.migration_pending {
                    self.connection.mark_receipt_eligible();
                }
                result
            }
            ThreadMetadataStage::Unchanged | ThreadMetadataStage::Failed => self.revision(),
        }
    }

    fn synchronize_event_enrichment(
        &mut self,
        codex_home: &Path,
        index_path: &Path,
        warnings: &mut Vec<LocalDataWarning>,
        mode: ExactSyncMode,
    ) -> Result<u64, String> {
        self.connection.mark_receipt_dirty();
        let total = event_enrichment_source_count(&self.connection)?;
        let completed_receipts = event_enrichment_receipt_count(&self.connection)?.min(total);
        let candidates = event_enrichment_pending_candidates(&self.connection)?;
        super::update_precise_dashboard_progress(
            codex_home,
            "backfillingModel",
            "正在补全历史模型与 reasoning 信息；首次升级可能需要几分钟，原始数据不会丢失",
            completed_receipts,
            Some(total),
        );

        if candidates.is_empty() {
            let mut revision = self.revision()?;
            let published = metadata_i64(&self.connection, "published_generation")?.unwrap_or(0);
            if let Some(building) = metadata_i64(&self.connection, "building_generation")?
                .filter(|building| *building > published)
            {
                prepare_scan_temp_tables(&self.connection)?;
                self.connection
                    .execute(
                        r#"
                        INSERT OR IGNORE INTO exact_seen_files(path)
                        WITH latest AS (
                            SELECT path, MAX(generation) AS generation
                            FROM files
                            WHERE generation <= ?1
                            GROUP BY path
                        )
                        SELECT f.path
                        FROM latest
                        JOIN files f
                          ON f.path = latest.path
                         AND f.generation = latest.generation
                        WHERE f.deleted = 0
                        "#,
                        params![building],
                    )
                    .map_err(|error| format!("无法恢复历史字段补全发布清单：{error}"))?;
                revision = finalize_generation(
                    &mut self.connection,
                    building,
                    codex_home,
                    warnings,
                    ExactScanCompleteness::default(),
                    mode,
                    true,
                )?;
            }
            let transaction = self
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|error| format!("无法开始历史字段补全完成事务：{error}"))?;
            set_metadata(
                &transaction,
                EVENT_ENRICHMENT_REVISION_KEY,
                EVENT_ENRICHMENT_REVISION,
            )?;
            set_metadata(
                &transaction,
                "schema_version",
                &CURRENT_SCHEMA_VERSION.to_string(),
            )?;
            transaction
                .commit()
                .map_err(|error| format!("无法提交历史字段补全完成状态：{error}"))?;
            self.migration_pending = !migration_markers_complete(&self.connection, true)?;
            return Ok(revision);
        }

        prepare_scan_temp_tables(&self.connection)?;
        self.connection
            .execute(
                "INSERT OR IGNORE INTO exact_seen_files(path) SELECT path FROM main.published_files",
                [],
            )
            .map_err(|error| format!("无法固定历史字段补全来源清单：{error}"))?;
        let generation = begin_or_resume_generation(&mut self.connection, mode)?;
        let mut scan_completeness = ExactScanCompleteness::default();
        let mut jobs = Vec::with_capacity(candidates.len());
        let mut completed = completed_receipts;

        for candidate in candidates {
            let file = PathBuf::from(&candidate.path);
            let handle = match RolloutReader::open(&file) {
                Ok(handle) => handle,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    record_missing_event_enrichment_source(
                        &mut self.connection,
                        generation,
                        &candidate,
                    )?;
                    self.connection
                        .execute(
                            "DELETE FROM exact_seen_files WHERE path = ?1",
                            params![&candidate.path],
                        )
                        .map_err(|error| format!("无法登记历史字段补全来源删除：{error}"))?;
                    #[cfg(test)]
                    if FAIL_AFTER_STAGING.swap(false, Ordering::SeqCst) {
                        return Err(
                            "injected interruption after durable exact token staging".into()
                        );
                    }
                    completed = completed.saturating_add(1);
                    super::update_precise_dashboard_progress(
                        codex_home,
                        "backfillingModel",
                        "正在补全历史模型与 reasoning 信息；首次升级可能需要几分钟，原始数据不会丢失",
                        completed,
                        Some(total),
                    );
                    continue;
                }
                Err(error) => {
                    scan_completeness.mark_incomplete();
                    warnings.push(scan_warning(format!(
                        "历史字段补全暂时无法读取来源，保留上次可信数据并将在下次启动继续：{}（{}）",
                        file.display(),
                        error
                    )));
                    super::update_precise_dashboard_progress(
                        codex_home,
                        "backfillingModel",
                        "历史 model/reasoning 补全等待重试；原始数据不会丢失",
                        completed,
                        Some(total),
                    );
                    continue;
                }
            };
            let current_signature = match file_signature_from_handle(&handle, &file) {
                Ok(signature) => signature,
                Err(error) => {
                    scan_completeness.mark_incomplete();
                    warnings.push(scan_warning(format!(
                        "历史字段补全暂时无法确认来源数据，保留上次可信数据并将在下次启动继续：{}（{}）",
                        file.display(),
                        error
                    )));
                    continue;
                }
            };
            drop(handle);
            let stable_published_prefix = current_signature.size >= candidate.signature.size;
            if !stable_published_prefix {
                set_metadata(
                    &self.connection,
                    BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY,
                    "1",
                )?;
            }
            let staging_base =
                reserve_staging_source(&self.connection, &candidate.path, &candidate.session_id)?;
            jobs.push(FullRebuildJob {
                file,
                path: candidate.path,
                session_id: candidate.session_id,
                source_id: staging_base.source_id,
                base_generation: staging_base.generation,
                base_resume_offset: staging_base.resume_offset,
                base_prefix_sha256: staging_base.prefix_sha256,
                signature: if stable_published_prefix {
                    candidate.signature
                } else {
                    current_signature
                },
                event_enrichment: true,
                expected_published_prefix_sha256: stable_published_prefix
                    .then_some(candidate.prefix_sha256),
            });
        }

        for batch in staging_job_batches(&jobs) {
            let estimated_bytes = batch
                .iter()
                .fold(0_u64, |sum, job| sum.saturating_add(job.signature.size));
            ensure_staging_capacity(index_path, estimated_bytes)?;
            let progress_home = codex_home.to_path_buf();
            let completed_before_batch = completed;
            let progress_callback: Arc<dyn Fn(u64) + Send + Sync> = Arc::new(move |staged_count| {
                super::update_precise_dashboard_progress(
                    &progress_home,
                    "backfillingModel",
                    "正在补全历史模型与 reasoning 信息；首次升级可能需要几分钟，原始数据不会丢失",
                    completed_before_batch.saturating_add(staged_count),
                    Some(total),
                );
            });
            let staged = stage_full_rebuilds(
                &batch,
                index_path,
                generation,
                codex_home,
                warnings,
                &mut scan_completeness,
                Some(progress_callback),
            )?;
            if staged.len() != batch.len() {
                scan_completeness.mark_incomplete();
            }
            #[cfg(test)]
            if FAIL_AFTER_STAGING.swap(false, Ordering::SeqCst) {
                return Err("injected interruption after durable exact token staging".into());
            }

            for mut staged_file in staged {
                let prefix_matches = staged_file
                    .job
                    .expected_published_prefix_sha256
                    .is_none_or(|expected| expected == staged_file.prefix_sha256);
                let events_match = prefix_matches
                    && staged_enrichment_matches_published_events(&self.connection, &staged_file)?;
                if !prefix_matches {
                    set_metadata(
                        &self.connection,
                        BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY,
                        "1",
                    )?;
                    let current_signature = file_signature(&staged_file.job.file)?;
                    ensure_staging_capacity(index_path, current_signature.size)?;
                    let replacement_job = FullRebuildJob {
                        signature: current_signature,
                        expected_published_prefix_sha256: None,
                        ..staged_file.job.clone()
                    };
                    let mut local_warnings = Vec::new();
                    staged_file = match stage_or_reuse_full_rebuild(
                        &replacement_job,
                        index_path,
                        generation,
                        codex_home,
                        &mut local_warnings,
                    ) {
                        Ok(staged) => staged,
                        Err(StagedFullRebuildError::IncompleteSource(error)) => {
                            scan_completeness.mark_incomplete();
                            warnings.push(scan_warning(error));
                            continue;
                        }
                        Err(StagedFullRebuildError::Fatal(error)) => return Err(error),
                    };
                    warnings.append(&mut local_warnings);
                } else if !events_match {
                    // The current parser disagrees with the old event identity or
                    // numeric payload.  Keep the scope to this source and publish
                    // the staged current-parser result as its reconciliation.
                    set_metadata(
                        &self.connection,
                        BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY,
                        "1",
                    )?;
                }
                import_staged_full_rebuild(&mut self.connection, generation, &staged_file, mode)?;
                remove_staging_database_storage(&staged_file.database_path)?;
                completed = completed.saturating_add(1).min(total);
            }
        }

        let pending_before_publish = match metadata_i64(&self.connection, "building_generation")? {
            Some(building) => {
                event_enrichment_pending_candidates_for_generation(&self.connection, building)?
            }
            None => event_enrichment_pending_candidates(&self.connection)?,
        };
        if scan_completeness.incomplete_source_scan || !pending_before_publish.is_empty() {
            super::update_precise_dashboard_progress(
                codex_home,
                "backfillingModel",
                "历史 model/reasoning 补全未完成，保留上一整份可信索引并将在下次启动继续",
                completed,
                Some(total),
            );
            self.migration_pending = true;
            self.connection.mark_receipt_dirty();
            return self.revision();
        }

        let revision = finalize_generation(
            &mut self.connection,
            generation,
            codex_home,
            warnings,
            ExactScanCompleteness::default(),
            mode,
            true,
        )?;
        let pending = event_enrichment_pending_candidates(&self.connection)?;
        if pending.is_empty() {
            let transaction = self
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|error| format!("无法开始历史字段补全发布事务：{error}"))?;
            set_metadata(
                &transaction,
                EVENT_ENRICHMENT_REVISION_KEY,
                EVENT_ENRICHMENT_REVISION,
            )?;
            set_metadata(
                &transaction,
                "schema_version",
                &CURRENT_SCHEMA_VERSION.to_string(),
            )?;
            transaction
                .commit()
                .map_err(|error| format!("无法提交历史字段补全发布状态：{error}"))?;
            super::update_precise_dashboard_progress(
                codex_home,
                "migrating",
                "历史 model/reasoning 补全已完成，正在提交索引升级",
                total,
                Some(total),
            );
        } else {
            super::update_precise_dashboard_progress(
                codex_home,
                "backfillingModel",
                "历史 model/reasoning 补全未完成，保留上次可信数据并将在下次启动继续",
                total.saturating_sub(pending.len() as u64),
                Some(total),
            );
        }
        self.migration_pending = !migration_markers_complete(&self.connection, true)?;
        remove_staging_directory(index_path)?;
        if !self.migration_pending {
            self.connection.mark_receipt_eligible();
        }
        Ok(revision)
    }

    pub(super) fn revision(&self) -> Result<u64, String> {
        Ok(u64::try_from(metadata_i64(&self.connection, "revision")?.unwrap_or(0)).unwrap_or(0))
    }

    pub(super) fn migration_pending(&self) -> bool {
        self.migration_pending
    }

    pub(super) fn published_generation(&self) -> Result<u64, String> {
        let raw = metadata_text(&self.connection, "published_generation")?
            .ok_or_else(|| "精确 token 索引已发布代次缺失".to_string())?;
        raw.parse::<u64>()
            .map_err(|_| "精确 token 索引已发布代次无效".to_string())
    }

}

/// Historical startup probe: despite the old read-only description inside its
/// body, production calls open_read_only_index and may enter legacy admission
/// when a physical input exists. Keep it in startup orchestration, outside the
/// same-connection read model; do not substitute it for published-only reads.
pub(super) fn peek_startup_identity(
    codex_home: &Path,
) -> Result<Option<StartupIndexIdentity>, String> {
    let path = database_path(codex_home)?;
    // Until the one-time copy is published, the old cache database still
    // supplies a read-only last-good identity. No migration occurs here.
    #[cfg(not(test))]
    let path = if !path.exists() {
        app_paths::tauri_usage_cache_dir().map(|root|root.join("exact-token-index").join(format!("{}.sqlite3",stable_path_fingerprint(codex_home))))
            .filter(|legacy|legacy.is_file()).unwrap_or(path)
    } else { path };
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err(format!(
                "拒绝只读检查符号链接形式的精确 token 索引：{}",
                path.display()
            ));
        }
        Ok(metadata) if !metadata.is_file() => {
            return Err(format!(
                "精确 token 索引路径不是普通文件：{}",
                path.display()
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "无法检查精确 token 索引 {}：{error}",
                path.display()
            ));
        }
    }

    let connection = open_read_only_index(&path, StdDuration::from_millis(100))
        .map_err(|error| format!("无法只读打开精确 token 索引 {}：{error}", path.display()))?;
    let schema_version = required_startup_metadata_i64(&connection, "schema_version")?;
    if !(GITHUB_BASE_SCHEMA_VERSION..=CURRENT_SCHEMA_VERSION).contains(&schema_version) {
        return Err(format!(
            "精确 token 启动缓存只接受 schema {}…{}，当前为 {}",
            GITHUB_BASE_SCHEMA_VERSION, INDEX_SCHEMA_VERSION, schema_version
        ));
    }
    // A freshly staged full index is built with the current parser and is
    // atomically published without these one-time migration markers. An
    // existing index gets the markers on normal open. Missing is therefore
    // valid for a V20 envelope that independently matches this exact
    // revision/generation/provenance; an explicitly incompatible marker is
    // never valid.
    let parser_revision = metadata_text(&connection, "fork_replay_boundary_revision")?;
    if parser_revision
        .as_deref()
        .is_some_and(|revision| ![EXACT_SESSION_PARSER_REVISION, PRE_COMPACTION_SESSION_PARSER_REVISION,
            LEGACY_SESSION_PARSER_REVISION, LEGACY_STAGED_PARSER_REVISION,
            PAGINATED_V4_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION,
            PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION].contains(&revision))
    {
        return Err(format!(
            "精确 token 启动缓存 parser revision 不兼容：{}",
            parser_revision.as_deref().unwrap_or_default()
        ));
    }
    let orphan_repair_revision = metadata_text(&connection, ORPHAN_REPAIR_REVISION_KEY)?;
    if orphan_repair_revision
        .as_deref()
        .is_some_and(|revision| revision != ORPHAN_REPAIR_REVISION)
    {
        return Err(format!(
            "精确 token 启动缓存逻辑完整性版本不兼容：{}",
            orphan_repair_revision.as_deref().unwrap_or_default()
        ));
    }
    let canonical_home = fs::canonicalize(codex_home).map_err(|error| {
        format!(
            "无法确认精确 token 启动缓存 Home {}：{error}",
            codex_home.display()
        )
    })?;
    let expected_home_identity = canonical_home.to_string_lossy();
    let stored_home_identity = required_startup_metadata_text(&connection, "codex_home_identity")?;
    if stored_home_identity != expected_home_identity {
        return Err("精确 token 启动缓存 Home identity 不匹配".into());
    }
    let revision = required_startup_metadata_u64(&connection, "revision")?;
    let dashboard_revision =
        optional_startup_metadata_u64(&connection, DASHBOARD_REVISION_KEY)?.unwrap_or(revision);
    let published_generation = required_startup_metadata_u64(&connection, "published_generation")?;
    let attribution_safety = startup_attribution_safety_state(&connection, published_generation)?;
    Ok(Some(StartupIndexIdentity {
        revision,
        dashboard_revision,
        published_generation,
        attribution_safety,
    }))
}

#[cfg(test)]
mod precise_dashboard_phase_trace_tests {
    use super::format_precise_dashboard_phases;

    #[test]
    fn phase_trace_label_is_fixed_bounded_and_non_sensitive() {
        let label = format_precise_dashboard_phases(1, 2, 3, 4, 5, 6, 7);
        assert!(label.len() < 512);
        assert_eq!(
            label.split_whitespace().collect::<Vec<_>>(),
            vec![
                "precise_dashboard_phases",
                "prepare_snapshot_ms=1",
                "activity_days_ms=2",
                "stats_ms=3",
                "usage_series_ms=4",
                "cache_ranking_ms=5",
                "cache_usage_ms=6",
                "total_ms=7",
                "status=ok",
            ]
        );
        for forbidden in [
            "path", "home", "token", "model", "title", "prompt", "error", "/",
        ] {
            assert!(!label.contains(forbidden), "unexpected field: {forbidden}");
        }
    }
}

fn begin_or_resume_generation(
    connection: &mut Connection,
    _mode: ExactSyncMode,
) -> Result<i64, String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始精确 token 同步状态事务：{error}"))?;
    let published = metadata_i64(&transaction, "published_generation")?.unwrap_or(0);
    set_metadata(&transaction,"building_discovery_started_us",&(OffsetDateTime::now_utc().unix_timestamp_nanos()/1000).to_string())?;
    if let Some(building) = metadata_i64(&transaction, "building_generation")? {
        if building > published {
            // A scan started by an older binary may not have initialized the
            // dashboard-only change marker. Preserve its generic dirty bit so
            // a resumed event scan cannot accidentally publish a stale
            // numeric dashboard lineage.
            if metadata_i64(&transaction, BUILDING_DASHBOARD_CHANGED_KEY)?.is_none() {
                let changed = metadata_i64(&transaction, "building_changed")?.unwrap_or(0);
                set_metadata(
                    &transaction,
                    BUILDING_DASHBOARD_CHANGED_KEY,
                    if changed != 0 { "1" } else { "0" },
                )?;
            }
            transaction
                .commit()
                .map_err(|error| format!("无法确认精确 token 续扫状态：{error}"))?;
            return Ok(building);
        }
        transaction
            .execute(
                "DELETE FROM metadata WHERE key IN (
                    'building_generation',
                    'building_changed',
                    'building_dashboard_changed',
                    'building_attribution_provenance_rotate'
                )",
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
    set_metadata(&transaction, BUILDING_DASHBOARD_CHANGED_KEY, "0")?;
    set_metadata(
        &transaction,
        BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY,
        "0",
    )?;
    // Schema 11 exposes the published aggregate layer through generation-
    // aware overlay views. Starting a generation therefore writes no copied
    // events, fingerprints, chunks, file aggregates, global buckets, or turn
    // candidates; only later deltas/replacements occupy pending storage.
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

/// Sole owner of the final IMMEDIATE publication transaction. Ledger retention,
/// canonical/attribution projections, pending publication, revision/watermarks
/// and stage-consumption receipts keep their existing order and single commit.
fn finalize_generation(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: ExactScanCompleteness,
    mode: ExactSyncMode,
    run_migrations: bool,
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

    // A previous summary-only generation may still own unprojected numeric
    // changes. Do not certify those as covered merely because this full pass
    // updated its own changed sources. The post-publish incremental repair
    // must retain the older watermark until it consumes that gap.
    let derived_was_current = metadata_i64(&transaction,DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?
        == metadata_i64(&transaction,"published_generation")?;
    ledger::preserve_pending_missing(&transaction)?;
    let canonical_changed=canonical::refresh(&transaction,generation)?;
    let canonical_repair=canonical_changed || metadata_i64(&transaction,"canonical_projection_pending")?.unwrap_or(0)!=0;
    if canonical_repair { mark_dashboard_changed(&transaction)?; }

    let missing_count = transaction
        .query_row(
            r#"
            SELECT COUNT(*)
            FROM sources s
            WHERE s.deleted = 0
              AND NOT EXISTS(SELECT 1 FROM usage_ledger_sources l WHERE l.source_id=s.source_id AND l.missing=1)
              AND NOT EXISTS (
                  SELECT 1
                  FROM exact_seen_files seen
                  WHERE seen.path = s.path
              )
            "#,
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法检查本轮已删除的会话文件：{error}"))?;
    if missing_count > 0 {
        // Losing a raw file revokes its excerpt binding, not its published
        // consumption. Keep the checkpoint and ledger for a later restore.
        transaction.execute_batch(r#"
            UPDATE usage_ledger_bindings SET available=0 WHERE source_id IN(
                SELECT s.source_id FROM sources s WHERE s.deleted=0
                  AND NOT EXISTS(SELECT 1 FROM exact_seen_files f WHERE f.path=s.path));
            UPDATE usage_ledger_sources SET missing=1 WHERE source_id IN(
                SELECT s.source_id FROM sources s WHERE s.deleted=0
                  AND NOT EXISTS(SELECT 1 FROM exact_seen_files f WHERE f.path=s.path));
        "#).map_err(|e|format!("无法保留缺失来源的历史账本：{e}"))?;
        mark_dashboard_changed(&transaction)?;
    }

    if mode.builds_dashboard_derived_data()
        && sync_thread_metadata(&transaction, codex_home, warnings)?
    {
        // Thread titles and timestamps are refreshed in the same SQLite
        // publication transaction, but they do not alter numeric token
        // aggregates or five-minute attribution buckets. Keep the generic
        // revision moving for metadata consumers while leaving the dashboard
        // numeric cache lineage intact.
        set_metadata(&transaction, "building_changed", "1")?;
    }
    if mode.builds_dashboard_derived_data() {
        backfill_missing_dashboard_aggregates_for_generation(&transaction, generation)?;
    }
    let rotate_attribution_provenance = canonical_changed ||
        metadata_i64(&transaction, BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY)?.unwrap_or(0) != 0;
    let source_index_changed =
        metadata_i64(&transaction, BUILDING_DASHBOARD_CHANGED_KEY)?.unwrap_or(0) != 0;
    if mode.builds_dashboard_derived_data()
        && source_index_changed
        && metadata_i64(&transaction, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)?
            == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
    {
        refresh_dashboard_turn_candidates_for_changed_generations(
            &transaction,
            generation,
            generation.saturating_sub(1),
        )?;
    }
    let _current_scan_unsafe_cause_detected =
        if mode.builds_dashboard_derived_data() || run_migrations || source_index_changed {
            let safety_before = attribution_safety_state(&transaction)?;
            let lineage_ambiguity_detected =
                visible_duplicate_session_lineage(&transaction, generation)?;
            let ledger_integrity_mismatch = attribution_ledger_integrity_mismatch(&transaction)?;
            let detected = rotate_attribution_provenance
                || lineage_ambiguity_detected
                || ledger_integrity_mismatch
                || scan_completeness.incomplete_source_scan;
            // One unresolved incident owns one provenance rotation. A file that is
            // truncated/replaced on every normal poll, or a duplicate UUID that stays
            // present, must remain sticky unsafe without creating an epoch/WAL storm.
            let rotate_for_new_unsafe_incident =
                detected && safety_before.unsafe_since_generation.is_none();
            if synchronize_attribution_ledger(
                &transaction,
                generation,
                source_index_changed,
                rotate_for_new_unsafe_incident,
                ledger_integrity_mismatch || canonical_repair,
            )? {
                mark_dashboard_changed(&transaction)?;
            }
            let provenance_epoch = metadata_text(&transaction, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| "精确 token 来源谱系标识缺失".to_string())?;
            if rotate_for_new_unsafe_incident {
                set_metadata(
                    &transaction,
                    ATTRIBUTION_UNSAFE_EPOCH_KEY,
                    &provenance_epoch,
                )?;
                set_metadata(
                    &transaction,
                    ATTRIBUTION_UNSAFE_GENERATION_KEY,
                    &generation.to_string(),
                )?;
                set_metadata(
                    &transaction,
                    ATTRIBUTION_UNSAFE_ID_KEY,
                    &Uuid::new_v4().to_string(),
                )?;
                mark_dashboard_changed(&transaction)?;
            }
            let previous_current_scan_unsafe =
                metadata_i64(&transaction, ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY)?.unwrap_or(0) != 0;
            if previous_current_scan_unsafe != detected {
                mark_dashboard_changed(&transaction)?;
            }
            set_metadata(
                &transaction,
                ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY,
                if detected { "1" } else { "0" },
            )?;
            let current_scan_incomplete = scan_completeness.incomplete_source_scan;
            let previous_current_scan_incomplete =
                metadata_i64(&transaction, ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY)?.unwrap_or(0)
                    != 0;
            if previous_current_scan_incomplete != current_scan_incomplete {
                mark_dashboard_changed(&transaction)?;
            }
            set_metadata(
                &transaction,
                ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY,
                if current_scan_incomplete { "1" } else { "0" },
            )?;
            detected
        } else {
            false
        };
    let pending_source_count = transaction
        .query_row(
            "SELECT COUNT(*) FROM pending_sources WHERE target_generation = ?1",
            params![generation],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法统计 schema 11 pending 来源：{error}"))?;
    let changed = metadata_i64(&transaction, "building_changed")?.unwrap_or(0) != 0;
    let dashboard_changed =
        metadata_i64(&transaction, BUILDING_DASHBOARD_CHANGED_KEY)?.unwrap_or(0) != 0;
    let current_revision = metadata_i64(&transaction, "revision")?.unwrap_or(0);
    let revision = if changed || pending_source_count > 0 {
        if dashboard_changed || pending_source_count > 0 {
            publish_schema11_pending_generation(&transaction, generation)?;
            set_metadata(
                &transaction,
                "published_generation",
                &generation.to_string(),
            )?;
        }
        current_revision.saturating_add(1)
    } else {
        current_revision
    };
    set_metadata(&transaction, "revision", &revision.to_string())?;
    if canonical_repair {
        rebuild_published_dashboard_aggregates(&transaction)?;
        let published=metadata_i64(&transaction,"published_generation")?.unwrap_or(0);
        set_metadata(&transaction,DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY,&published.to_string())?;
    }
    let current_dashboard_revision =
        metadata_i64(&transaction, DASHBOARD_REVISION_KEY)?.unwrap_or(current_revision);
    let dashboard_revision = if dashboard_changed {
        current_dashboard_revision.saturating_add(1)
    } else {
        current_dashboard_revision
    };
    set_metadata(
        &transaction,
        DASHBOARD_REVISION_KEY,
        &dashboard_revision.to_string(),
    )?;
    if mode.builds_dashboard_derived_data() && derived_was_current
        && metadata_i64(&transaction, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)?
            == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
    {
        // Every changed file updated its derived rows in the same transaction
        // that wrote/replaced its events. Unchanged files keep their prior
        // versioned aggregate rows, selected through published_files.
        let aggregate_generation = metadata_i64(&transaction, "published_generation")?.unwrap_or(0);
        set_metadata(
            &transaction,
            DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY,
            &aggregate_generation.to_string(),
        )?;
        transaction
            .execute(
                "DELETE FROM dashboard_5m WHERE file_generation <> ?1",
                params![aggregate_generation],
            )
            .map_err(|error| format!("无法清理旧版全局五分钟聚合：{error}"))?;
        transaction
            .execute(
                "DELETE FROM dashboard_turn_candidates WHERE aggregate_generation <> ?1",
                params![aggregate_generation],
            )
            .map_err(|error| format!("无法清理旧版轮次候选聚合：{error}"))?;
    }
    transaction
        .execute(
            "DELETE FROM metadata WHERE key IN (
                'building_generation',
                'building_changed',
                'building_dashboard_changed',
                'building_attribution_provenance_rotate'
            )",
            [],
        )
        .map_err(|error| format!("无法结束精确 token 同步状态：{error}"))?;
    canonical::certify(&transaction)?;
    #[cfg(not(test))]
    transaction.consume_exact_stage_generation(generation)?;
    transaction
        .commit()
        .map_err(|error| format!("无法原子发布完整精确 token 代次：{error}"))?;
    Ok(u64::try_from(revision).unwrap_or(0))
}

fn schema11_candidate_path(index_path: &Path) -> PathBuf {
    let mut value = index_path.as_os_str().to_os_string();
    value.push(SCHEMA11_CANDIDATE_SUFFIX);
    PathBuf::from(value)
}

fn schema11_rollback_path(index_path: &Path) -> PathBuf {
    let mut value = index_path.as_os_str().to_os_string();
    value.push(SCHEMA11_ROLLBACK_SUFFIX);
    PathBuf::from(value)
}

fn schema11_manifest_path(index_path: &Path) -> PathBuf {
    let mut value = index_path.as_os_str().to_os_string();
    value.push(SCHEMA11_MIGRATION_SUFFIX);
    PathBuf::from(value)
}

// A physical legacy receipt describes physical DB/WAL stamps, not the new A
// namespace. Preserve pre-hotfix receipts, including 0.9.8's derived migration
// work. Canonical A is authoritative; unfinished derived work can be prepared
// again without guessing whether a physical receipt belongs to A or an old DB.
/// May register a verified legacy migration receipt in A before selecting paths.
/// This is recovery/admission work, not pure path construction; only
/// schema11_paths_for_namespace is a side-effect-free path formatter.
fn active_schema11_paths(index_path: &Path) -> Result<(PathBuf, PathBuf, PathBuf), String> {
    #[cfg(not(test))]
    let isolated = {
        use crate::core::business_store_route as route;
        let mut isolated = route::preserves_legacy_exact_migration(index_path)?;
        if !isolated && schema11_manifest_path(index_path).try_exists().map_err(|e| e.to_string())? {
            let (_, proof) = exact_legacy_recovery::runtime_source(index_path, route::exact_store_has_objects(index_path)?)?;
            let proof = proof.ok_or("旧迁移凭据在核验时移走，已停止写入")?;
            route::preserve_legacy_exact_migration(index_path, &[proof])?;
            isolated = true;
        }
        isolated
    };
    #[cfg(test)]
    let isolated = false;
    Ok(schema11_paths_for_namespace(index_path, isolated))
}

/// Reuses the caller's bound handle for current ownership checks; a newly
/// discovered legacy manifest still falls back to the effectful admission path.
/// The _on suffix does not guarantee that this call is read-only.
fn active_schema11_paths_on(connection: &Connection, index_path: &Path) -> Result<(PathBuf, PathBuf, PathBuf), String> {
    #[cfg(not(test))]
    {
        let isolated = connection.preserves_legacy_exact_migration(index_path)?;
        if !isolated && schema11_manifest_path(index_path).try_exists().map_err(|error| error.to_string())? {
            // A newly discovered physical legacy manifest still needs the
            // original proof/admission path. Absence is never cached.
            return active_schema11_paths(index_path);
        }
        Ok(schema11_paths_for_namespace(index_path, isolated))
    }
    #[cfg(test)]
    { let _ = connection; active_schema11_paths(index_path) }
}

fn schema11_paths_for_namespace(index_path: &Path, isolated: bool) -> (PathBuf, PathBuf, PathBuf) {
    let base = if isolated { sqlite_sidecar_path(index_path, ".container-v1") } else { index_path.to_path_buf() };
    (schema11_candidate_path(&base), schema11_rollback_path(&base), schema11_manifest_path(&base))
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn verify_runtime_recovery_fixture(home: &Path) -> Result<serde_json::Value, String> {
    runtime_recovery::verify_fixture(home)
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn verify_backfill_performance_fixture(home: &Path) -> Result<serde_json::Value, String> {
    ledger::verify_performance_fixture(home)
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn verify_native_scale_fixture(home: &Path) -> Result<serde_json::Value, String> {
    ledger::verify_scale_fixture(home)
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn verify_held_owner_lookup_fixture() -> Result<serde_json::Value, String> {
    stage_pool::fixture_owner_lookup_report()
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn run_pool_crash_step(root: &Path, point: &str, resume: bool) -> Result<serde_json::Value, String> {
    stage_pool::run_crash_step(root,point,resume)
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn verify_legacy_migration_fixture(home: &Path, path: &Path) -> Result<bool, String> {
    prepare_exact_store_for_home(home, path)?;
    let paths = active_schema11_paths(path)?;
    // Run the same production reader preparation as the application, not the
    // cfg(test) standalone SQLite path. A current committed source needs no
    // schema change, even when its physical legacy siblings still exist.
    if prepare_schema11_candidate_if_needed(path, home)?.is_some() {
        return Err("fixture unexpectedly required a structural migration".into());
    }
    Ok(paths != schema11_paths_for_namespace(path, false))
}

/// Historical name: production obtains the durable namespace seal and may
/// CREATE that seal before returning its observation. Only test builds read
/// physical file metadata. Keep this in migration orchestration, not a pure
/// filesystem-signature helper or the published-reader path.
fn schema11_file_stamp(path: &Path) -> Result<Schema11FileStamp, String> {
    #[cfg(not(test))]
    {
        if crate::core::business_store_route::exact_store_observation(path)?.is_none() {
            crate::core::business_store_route::seal_exact_store(path)?;
        }
        let (size, _, _, sealed_at) = crate::core::business_store_route::exact_store_observation(path)?
            .ok_or_else(|| "精确 token 模块缺少耐久 seal".to_string())?;
        let modified_ns = (sealed_at * 1_000_000_000.0).round() as i64;
        return Ok(Schema11FileStamp { size, modified_ns: modified_ns.to_string() });
    }
    #[cfg(test)]
    {
    let signature = file_signature(path)?;
    Ok(Schema11FileStamp {
        size: signature.size,
        modified_ns: signature.modified_ns.to_string(),
    })
    }
}

fn schema11_source_receipt(index_path: &Path) -> Result<Schema11SourceReceipt, String> {
    let connection = open_read_only_index(index_path, StdDuration::from_secs(1))
        .map_err(|error| format!("无法读取 schema 11 活动索引收据：{error}"))?;
    let before = schema11_source_receipt_from_connection(index_path, &connection)?;
    quick_check_index(&connection, Some(index_path))?;
    let after = schema11_source_receipt_from_connection(index_path, &connection)?;
    if before != after {
        return Err("活动索引在完整性检查期间发生变化；已保留原库".into());
    }
    Ok(after)
}

fn schema11_source_receipt_without_quick_check(
    index_path: &Path,
) -> Result<Schema11SourceReceipt, String> {
    let connection = open_read_only_index(index_path, StdDuration::from_secs(1))
        .map_err(|error| format!("无法读取 schema 11 活动索引收据：{error}"))?;
    schema11_source_receipt_from_connection(index_path, &connection)
}

fn schema11_source_receipt_from_connection(
    index_path: &Path,
    connection: &Connection,
) -> Result<Schema11SourceReceipt, String> {
    let schema_version = metadata_i64(connection, "schema_version")?
        .ok_or_else(|| "schema 11 候选迁移缺少活动索引 schema 版本".to_string())?;
    Ok(Schema11SourceReceipt {
        schema_version,
        revision: metadata_text(connection, "revision")?,
        dashboard_revision: metadata_text(connection, DASHBOARD_REVISION_KEY)?,
        published_generation: metadata_i64(connection, "published_generation")?,
        building_generation: metadata_i64(connection, "building_generation")?,
        database: schema11_file_stamp(index_path)?,
        wal: optional_index_sidecar_signature(&sqlite_sidecar_path(index_path, "-wal"))?.map(
            |signature| Schema11FileStamp {
                size: signature.size,
                modified_ns: signature.modified_ns.to_string(),
            },
        ),
    })
}

fn schema11_receipt_matches_current(
    index_path: &Path,
    expected: &Schema11SourceReceipt,
) -> Result<bool, String> {
    Ok(schema11_source_receipt_without_quick_check(index_path)? == *expected)
}

fn schema11_receipt_metadata_matches(
    connection: &Connection,
    expected: &Schema11SourceReceipt,
) -> Result<bool, String> {
    Ok(metadata_i64(connection, "schema_version")? == Some(expected.schema_version)
        && metadata_text(connection, "revision")? == expected.revision
        && metadata_text(connection, DASHBOARD_REVISION_KEY)? == expected.dashboard_revision
        && metadata_i64(connection, "published_generation")? == expected.published_generation
        && metadata_i64(connection, "building_generation")? == expected.building_generation)
}

fn schema11_receipt_matches_current_with_integrity(
    index_path: &Path,
    expected: &Schema11SourceReceipt,
) -> Result<bool, String> {
    Ok(schema11_source_receipt(index_path)? == *expected)
}

fn schema11_store_manifest(
    manifest_path: &Path,
    manifest: &Schema11CandidateManifest,
) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(manifest)
        .map_err(|error| format!("无法编码 schema 11 候选迁移清单：{error}"))?;
    atomic_file::write_atomically(manifest_path, &bytes)
        .map_err(|error| format!("无法耐久写入 schema 11 候选迁移清单：{error}"))
}

fn schema11_load_manifest(manifest_path: &Path) -> Result<Schema11CandidateManifest, String> {
    let bytes = fs::read(manifest_path)
        .map_err(|error| format!("无法读取 schema 11 候选迁移清单：{error}"))?;
    serde_json::from_slice(&bytes)
        .map_err(|error| format!("schema 11 候选迁移清单损坏，已保留活动库和候选库：{error}"))
}

fn schema11_sync_file(path: &Path) -> Result<(), String> {
    #[cfg(not(test))]
    {
        return crate::core::business_store_route::seal_exact_store(path);
    }
    #[cfg(test)]
    {
    fs::OpenOptions::new()
        .read(true)
        // Windows FlushFileBuffers requires GENERIC_WRITE. This opens an
        // existing candidate without creating or truncating its contents.
        .write(true)
        .open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("无法同步 schema 11 候选文件 {}：{error}", path.display()))
    }
}

fn schema11_sync_parent(path: &Path) -> Result<(), String> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    crate::core::atomic_file::sync_parent(parent)
        .map_err(|error| format!("无法同步 schema 11 候选目录 {}：{error}", parent.display()))
}

fn schema11_move_sidecar_if_present(source: &Path, destination: &Path) -> Result<(), String> {
    if !source.exists() {
        return Ok(());
    }
    if destination.exists() {
        return Err(format!(
            "schema 11 切换目标旁车文件已存在：{}",
            destination.display()
        ));
    }
    fs::rename(source, destination).map_err(|error| {
        format!(
            "无法迁移 schema 11 数据库旁车文件 {} -> {}：{error}",
            source.display(),
            destination.display()
        )
    })
}

fn schema11_migration_capacity(index_path: &Path) -> Result<(), String> {
    #[cfg(not(test))]
    let (database_bytes, wal_bytes) = {
        let (size, _, _, _) = crate::core::business_store_route::exact_store_observation(index_path)?
            .ok_or_else(|| "无法检查 schema 11 模块 seal".to_string())?;
        (size, 0u64)
    };
    #[cfg(test)]
    let (database_bytes, wal_bytes) = {
    let database_bytes = file_signature(index_path)?.size;
    let wal_bytes = optional_index_sidecar_signature(&sqlite_sidecar_path(index_path, "-wal"))?
        .map(|signature| signature.size)
        .unwrap_or(0);
        (database_bytes, wal_bytes)
    };
    #[cfg(test)]
    let overridden_free = MIGRATION_AVAILABLE_BYTES_OVERRIDE.with(|value| value.replace(None));
    #[cfg(not(test))]
    let overridden_free = None;
    let available = if let Some(available) = overridden_free {
        available
    } else {
        #[cfg(not(test))]
        let capacity_root = crate::core::business_store_route::container_path()?
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        #[cfg(test)]
        let capacity_root = index_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        available_space(&capacity_root)
            .map_err(|error| format!("无法检查 schema 11 迁移空间：{error}"))?
    };
    // Free space already excludes the legacy database. Budget a candidate
    // copy plus VACUUM's temporary database and rollback journal. WAL pages
    // may enlarge the backup, so include them in each allocation estimate.
    let required = database_bytes
        .saturating_add(wal_bytes)
        .saturating_mul(3)
        .saturating_add(SCHEMA11_MIGRATION_SPACE_RESERVE_BYTES);
    if available < required {
        return Err(format!(
            "精确 token schema 11 迁移空间不足；需要约 {} MiB、可用约 {} MiB，未开始迁移并保留活动库",
            required.div_ceil(1024 * 1024),
            available / (1024 * 1024)
        ));
    }
    Ok(())
}

fn schema11_copy_candidate(index_path: &Path, candidate_path: &Path) -> Result<(), String> {
    #[cfg(not(test))]
    {
        crate::core::business_store_route::clone_exact_store(index_path, candidate_path)
            .map(|_| ())
    }
    #[cfg(test)]
    {
    let source = open_read_only_index(index_path, StdDuration::from_secs(5))
        .map_err(|error| format!("无法只读打开 schema 11 迁移活动库：{error}"))?;
    let mut destination = Connection::open(candidate_path)
        .map_err(|error| format!("无法创建 schema 11 候选库：{error}"))?;
    destination
        .busy_timeout(StdDuration::from_secs(30))
        .map_err(|error| format!("无法设置 schema 11 候选库等待时间：{error}"))?;
    {
        let backup = Backup::new(&source, &mut destination)
            .map_err(|error| format!("无法创建 schema 11 SQLite 备份：{error}"))?;
        backup
            .run_to_completion(128, StdDuration::from_millis(2), None)
            .map_err(|error| format!("无法完成 schema 11 SQLite 备份：{error}"))?;
    }
    destination
        .execute_batch(
            "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;",
        )
        .map_err(|error| format!("无法规范化 schema 11 候选库日志模式：{error}"))?;
    drop(destination);
    schema11_sync_file(candidate_path)
    }
}

fn copy_schema11_fingerprints(
    transaction: &Transaction<'_>,
    select_sql: &str,
    target_table: &str,
) -> Result<(), String> {
    let mut select = transaction
        .prepare(select_sql)
        .map_err(|error| format!("无法准备 schema 11 指纹迁移读取：{error}"))?;
    let mut rows = select
        .query([])
        .map_err(|error| format!("无法读取 schema 11 迁移指纹：{error}"))?;
    let insert_sql = format!("INSERT INTO {target_table}(source_id, fingerprint) VALUES (?1, ?2)");
    let mut insert = transaction
        .prepare(&insert_sql)
        .map_err(|error| format!("无法准备 schema 11 指纹迁移写入：{error}"))?;
    while let Some(row) = rows
        .next()
        .map_err(|error| format!("无法遍历 schema 11 迁移指纹：{error}"))?
    {
        let source_id = row
            .get::<_, i64>(0)
            .map_err(|error| format!("无法解码 schema 11 指纹来源：{error}"))?;
        let encoded = canonicalize_legacy_fingerprint(
            row.get_ref(1)
                .map_err(|error| format!("无法读取 schema 11 旧指纹值：{error}"))?,
        )?;
        insert
            .execute(params![source_id, encoded])
            .map_err(|error| format!("无法写入 schema 11 canonical 指纹：{error}"))?;
    }
    Ok(())
}

fn migrate_schema9_or10_to_schema11_candidate(candidate_path: &Path) -> Result<(), String> {
    let connection = open_index_connection(candidate_path, false, false)?;
    let schema_version = metadata_i64(&connection, "schema_version")?
        .ok_or_else(|| "schema 11 候选库缺少旧 schema 版本".to_string())?;
    if schema_version == INDEX_SCHEMA_VERSION {
        return Ok(());
    }
    if !matches!(schema_version, GITHUB_BASE_SCHEMA_VERSION | 10) {
        return Err(format!(
            "schema 11 候选迁移只接受 schema 9/10，实际为 {schema_version}"
        ));
    }
    let mut preparation = IndexPreparationTrace::new("candidate_restructure");
    let generations = schema11_legacy_generation_state(&connection)?;
    let legacy_alter_table = pragma_u64(&connection, "legacy_alter_table")?;
    connection
        .execute_batch("PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON;")
        .map_err(|error| format!("无法准备 schema 11 候选迁移连接：{error}"))?;
    let migration = (|| {
        let transaction = connection
            .unchecked_transaction()
            .map_err(|error| format!("无法开始 schema 11 候选迁移事务：{error}"))?;
        transaction
            .execute_batch(
                r#"
                DROP VIEW IF EXISTS published_events;
                DROP VIEW IF EXISTS published_files;
                DROP INDEX IF EXISTS files_path_generation_idx;
                DROP INDEX IF EXISTS events_timestamp_idx;
                DROP INDEX IF EXISTS events_file_summary_idx;
                DROP INDEX IF EXISTS events_session_idx;
                DROP INDEX IF EXISTS events_input_tokens_idx;
                DROP INDEX IF EXISTS dashboard_file_5m_time_idx;
                DROP INDEX IF EXISTS dashboard_turn_candidates_order_idx;
                DROP INDEX IF EXISTS dashboard_turn_candidates_session_idx;
                ALTER TABLE files RENAME TO schema11_legacy_files;
                ALTER TABLE events RENAME TO schema11_legacy_events;
                ALTER TABLE event_enrichment_sources RENAME TO schema11_legacy_enrichment;
                ALTER TABLE dashboard_file_totals RENAME TO schema11_legacy_file_totals;
                ALTER TABLE dashboard_file_5m RENAME TO schema11_legacy_file_5m;
                ALTER TABLE dashboard_5m RENAME TO schema11_legacy_dashboard_5m;
                ALTER TABLE dashboard_turn_candidates RENAME TO schema11_legacy_turns;
                ALTER TABLE file_fingerprints RENAME TO schema11_legacy_fingerprints;
                ALTER TABLE file_chunks RENAME TO schema11_legacy_chunks;
                "#,
            )
            .map_err(|error| format!("无法隔离 schema 11 候选旧表：{error}"))?;
        maybe_fail_schema11_migration_for_testing(1)?;
        initialize_index_schema(&transaction)?;
        preparation.advance("candidate_copy_sources_events");

        let published = generations.published;
        let building = generations.building;
        transaction
            .execute_batch(
                r#"
                CREATE TEMP TABLE schema11_current_versions(
                    path TEXT PRIMARY KEY,
                    generation INTEGER NOT NULL
                ) WITHOUT ROWID;
                CREATE TEMP TABLE schema11_building_versions(
                    path TEXT PRIMARY KEY,
                    generation INTEGER NOT NULL
                ) WITHOUT ROWID;
                CREATE TEMP TABLE schema11_delta_sources(
                    source_id INTEGER PRIMARY KEY
                ) WITHOUT ROWID;
                "#,
            )
            .map_err(|error| format!("无法创建 schema 11 候选映射表：{error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO schema11_current_versions(path, generation)
                SELECT path, MAX(generation)
                FROM schema11_legacy_files
                WHERE generation <= ?1
                GROUP BY path
                "#,
                params![published],
            )
            .map_err(|error| format!("无法固定 schema 11 已发布来源：{error}"))?;
        if let Some(building) = building {
            transaction
                .execute(
                    r#"
                    INSERT INTO schema11_building_versions(path, generation)
                    SELECT path, generation FROM schema11_legacy_files
                    WHERE generation = ?1
                    "#,
                    params![building],
                )
                .map_err(|error| format!("无法固定 schema 11 未完成来源：{error}"))?;
        }
        transaction
            .execute(
                r#"
                WITH paths AS (
                    SELECT path FROM schema11_current_versions
                    UNION SELECT path FROM schema11_building_versions
                )
                INSERT INTO sources(
                    source_id, path, session_id, deleted, last_seen_generation,
                    size, modified_ns, prefix_sha256, append_ready, resume_offset,
                    previous_total_tokens, fork_replay_started_ns,
                    fork_replay_active, is_explicit_subagent_fork,
                    last_skipped_fork_replay_token_ns, current_model,
                    current_user_prompt_start, current_user_prompt_end,
                    assistant_response_start, assistant_response_end, audit_chunk_index
                )
                SELECT
                    ROW_NUMBER() OVER (ORDER BY paths.path), paths.path,
                    COALESCE(current.session_id, building.session_id, ''),
                    COALESCE(current.deleted, 1), COALESCE(current.generation, 0),
                    COALESCE(current.size, 0), COALESCE(current.modified_ns, '0'),
                    COALESCE(current.prefix_sha256, X''),
                    COALESCE(current.append_ready, 0), current.resume_offset,
                    current.previous_total_tokens, current.fork_replay_started_ns,
                    COALESCE(current.fork_replay_active, 0),
                    COALESCE(current.is_explicit_subagent_fork, 0),
                    current.last_skipped_fork_replay_token_ns, current.current_model,
                    current.current_user_prompt_start, current.current_user_prompt_end,
                    current.assistant_response_start, current.assistant_response_end,
                    COALESCE(current.audit_chunk_index, 0)
                FROM paths
                LEFT JOIN schema11_current_versions cv ON cv.path = paths.path
                LEFT JOIN schema11_legacy_files current
                  ON current.path = cv.path AND current.generation = cv.generation
                LEFT JOIN schema11_building_versions bv ON bv.path = paths.path
                LEFT JOIN schema11_legacy_files building
                  ON building.path = bv.path AND building.generation = bv.generation
                ORDER BY paths.path
                "#,
                [],
            )
            .map_err(|error| format!("无法迁移 schema 11 稳定来源表：{error}"))?;

        // An old building row is a delta only when every published event and
        // fingerprint is present with exactly the same data. Anything that
        // cannot be proved is retained as a full pending replacement.
        transaction
            .execute(
                r#"
                INSERT INTO schema11_delta_sources(source_id)
                SELECT s.source_id
                FROM sources s
                JOIN schema11_current_versions cv ON cv.path = s.path
                JOIN schema11_building_versions bv ON bv.path = s.path
                JOIN schema11_legacy_files current
                  ON current.path = cv.path AND current.generation = cv.generation
                JOIN schema11_legacy_files building
                  ON building.path = bv.path AND building.generation = bv.generation
                WHERE current.deleted = 0 AND building.deleted = 0
                  AND building.size >= current.size
                  AND NOT EXISTS (
                    SELECT 1 FROM schema11_legacy_events old
                    WHERE old.file_path = s.path AND old.file_generation = cv.generation
                      AND NOT EXISTS (
                        SELECT 1 FROM schema11_legacy_events candidate
                        WHERE candidate.file_path = old.file_path
                          AND candidate.file_generation = bv.generation
                          AND candidate.ordinal = old.ordinal
                          AND candidate.timestamp = old.timestamp
                          AND candidate.session_id = old.session_id
                          AND candidate.tokens = old.tokens
                          AND candidate.input_tokens = old.input_tokens
                          AND candidate.cached_input_tokens = old.cached_input_tokens
                          AND candidate.output_tokens = old.output_tokens
                          AND candidate.reasoning_output_tokens IS old.reasoning_output_tokens
                          AND candidate.model IS old.model
                          AND candidate.user_prompt_start IS old.user_prompt_start
                          AND candidate.user_prompt_end IS old.user_prompt_end
                          AND candidate.assistant_response_start IS old.assistant_response_start
                          AND candidate.assistant_response_end IS old.assistant_response_end
                      )
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM schema11_legacy_fingerprints old
                    WHERE old.file_path = s.path AND old.file_generation = cv.generation
                      AND NOT EXISTS (
                        SELECT 1 FROM schema11_legacy_fingerprints candidate
                        WHERE candidate.file_path = old.file_path
                          AND candidate.file_generation = bv.generation
                          AND candidate.fingerprint = old.fingerprint
                      )
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM schema11_legacy_chunks old
                    WHERE old.file_path = s.path AND old.file_generation = cv.generation
                      AND NOT EXISTS (
                        SELECT 1 FROM schema11_legacy_chunks candidate
                        WHERE candidate.file_path = old.file_path
                          AND candidate.file_generation = bv.generation
                          AND candidate.chunk_index = old.chunk_index
                      )
                  )
                "#,
                [],
            )
            .map_err(|error| format!("无法证明 schema 11 未完成追加来源：{error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO pending_sources(
                    source_id, target_generation, mode, deleted, size, modified_ns,
                    prefix_sha256, append_ready, resume_offset, previous_total_tokens,
                    fork_replay_started_ns, fork_replay_active,
                    is_explicit_subagent_fork, last_skipped_fork_replay_token_ns,
                    current_model, current_user_prompt_start, current_user_prompt_end,
                    assistant_response_start, assistant_response_end, audit_chunk_index
                )
                SELECT s.source_id, building.generation,
                       CASE WHEN building.deleted <> 0 THEN 'tombstone'
                            WHEN d.source_id IS NOT NULL THEN 'delta' ELSE 'full' END,
                       building.deleted, building.size, building.modified_ns,
                       building.prefix_sha256, building.append_ready,
                       building.resume_offset, building.previous_total_tokens,
                       building.fork_replay_started_ns, building.fork_replay_active,
                       building.is_explicit_subagent_fork,
                       building.last_skipped_fork_replay_token_ns,
                       building.current_model, building.current_user_prompt_start,
                       building.current_user_prompt_end,
                       building.assistant_response_start,
                       building.assistant_response_end, building.audit_chunk_index
                FROM schema11_building_versions bv
                JOIN sources s ON s.path = bv.path
                JOIN schema11_legacy_files building
                  ON building.path = bv.path AND building.generation = bv.generation
                LEFT JOIN schema11_delta_sources d ON d.source_id = s.source_id
                "#,
                [],
            )
            .map_err(|error| format!("无法迁移 schema 11 pending 来源：{error}"))?;
        maybe_fail_schema11_migration_for_testing(2)?;

        transaction
            .execute_batch(
                r#"
                INSERT INTO event_rows(
                    id, source_id, ordinal, timestamp, tokens, input_tokens,
                    cached_input_tokens, output_tokens, reasoning_output_tokens, model,
                    user_prompt_start, user_prompt_end, assistant_response_start,
                    assistant_response_end
                )
                SELECT e.id, s.source_id, e.ordinal, e.timestamp, e.tokens,
                       e.input_tokens, e.cached_input_tokens, e.output_tokens,
                       COALESCE(e.reasoning_output_tokens, 0), e.model,
                       e.user_prompt_start, e.user_prompt_end,
                       e.assistant_response_start, e.assistant_response_end
                FROM schema11_legacy_events e
                JOIN schema11_current_versions v
                  ON v.path = e.file_path AND v.generation = e.file_generation
                JOIN sources s ON s.path = e.file_path;

                INSERT INTO pending_event_rows(
                    id, source_id, ordinal, timestamp, tokens, input_tokens,
                    cached_input_tokens, output_tokens, reasoning_output_tokens, model,
                    user_prompt_start, user_prompt_end, assistant_response_start,
                    assistant_response_end
                )
                SELECT e.id, s.source_id, e.ordinal, e.timestamp, e.tokens,
                       e.input_tokens, e.cached_input_tokens, e.output_tokens,
                       COALESCE(e.reasoning_output_tokens, 0), e.model,
                       e.user_prompt_start, e.user_prompt_end,
                       e.assistant_response_start, e.assistant_response_end
                FROM schema11_legacy_events e
                JOIN schema11_building_versions v
                  ON v.path = e.file_path AND v.generation = e.file_generation
                JOIN sources s ON s.path = e.file_path
                JOIN pending_sources p ON p.source_id = s.source_id
                WHERE p.mode = 'full'
                   OR (p.mode = 'delta' AND NOT EXISTS (
                        SELECT 1 FROM event_rows current
                        WHERE current.source_id = s.source_id
                          AND current.ordinal = e.ordinal
                   ));
                "#,
            )
            .map_err(|error| format!("无法迁移 schema 11 事件：{error}"))?;

        preparation.advance("candidate_copy_fingerprints_chunks");
        copy_schema11_fingerprints(
            &transaction,
            r#"
            SELECT s.source_id, f.fingerprint
            FROM schema11_legacy_fingerprints f
            JOIN schema11_current_versions v
              ON v.path = f.file_path AND v.generation = f.file_generation
            JOIN sources s ON s.path = f.file_path
            ORDER BY s.source_id
            "#,
            "source_fingerprints",
        )?;
        copy_schema11_fingerprints(
            &transaction,
            r#"
            SELECT s.source_id, f.fingerprint
            FROM schema11_legacy_fingerprints f
            JOIN schema11_building_versions v
              ON v.path = f.file_path AND v.generation = f.file_generation
            JOIN sources s ON s.path = f.file_path
            JOIN pending_sources p ON p.source_id = s.source_id
            WHERE p.mode = 'full'
               OR (p.mode = 'delta' AND NOT EXISTS (
                    SELECT 1 FROM schema11_legacy_fingerprints current
                    JOIN schema11_current_versions cv
                      ON cv.path = current.file_path
                     AND cv.generation = current.file_generation
                    WHERE current.file_path = f.file_path
                      AND current.fingerprint = f.fingerprint
               ))
            ORDER BY s.source_id
            "#,
            "pending_fingerprints",
        )?;
        transaction
            .execute_batch(
                r#"
                INSERT INTO source_chunks(source_id, chunk_index, byte_count, sha256)
                SELECT s.source_id, c.chunk_index, c.byte_count, c.sha256
                FROM schema11_legacy_chunks c
                JOIN schema11_current_versions v
                  ON v.path = c.file_path AND v.generation = c.file_generation
                JOIN sources s ON s.path = c.file_path;
                INSERT INTO pending_chunks(source_id, chunk_index, byte_count, sha256)
                SELECT s.source_id, c.chunk_index, c.byte_count, c.sha256
                FROM schema11_legacy_chunks c
                JOIN schema11_building_versions v
                  ON v.path = c.file_path AND v.generation = c.file_generation
                JOIN sources s ON s.path = c.file_path
                JOIN pending_sources p ON p.source_id = s.source_id
                WHERE p.mode = 'full'
                   OR (p.mode = 'delta' AND NOT EXISTS (
                        SELECT 1 FROM source_chunks current
                        WHERE current.source_id = s.source_id
                          AND current.chunk_index = c.chunk_index
                          AND current.byte_count = c.byte_count
                          AND current.sha256 = c.sha256
                   ));
                "#,
            )
            .map_err(|error| format!("无法迁移 schema 11 指纹分块：{error}"))?;
        maybe_fail_schema11_migration_for_testing(3)?;
        preparation.advance("candidate_copy_derived_tables");

        transaction
            .execute_batch(
                r#"
                INSERT INTO source_enrichment(
                    source_id, revision, parser_revision, completed_size,
                    completed_prefix_sha256
                )
                SELECT s.source_id, e.revision, e.parser_revision,
                       e.completed_size, e.completed_prefix_sha256
                FROM schema11_legacy_enrichment e
                JOIN sources s ON s.path = e.path
                WHERE NOT EXISTS(
                    SELECT 1 FROM schema11_building_versions v
                    WHERE v.path = e.path AND v.generation = e.file_generation
                );
                INSERT INTO pending_enrichment(
                    source_id, revision, parser_revision, completed_size,
                    completed_prefix_sha256
                )
                SELECT s.source_id, e.revision, e.parser_revision,
                       e.completed_size, e.completed_prefix_sha256
                FROM schema11_legacy_enrichment e
                JOIN sources s ON s.path = e.path
                JOIN schema11_building_versions v
                  ON v.path = e.path AND v.generation = e.file_generation
                JOIN pending_sources p ON p.source_id = s.source_id
                WHERE p.mode <> 'tombstone';

                INSERT INTO dashboard_source_totals(
                    source_id, total_tokens, calls, input_tokens,
                    cached_input_tokens, output_tokens, first_timestamp, last_timestamp
                )
                SELECT s.source_id, t.total_tokens, t.calls, t.input_tokens,
                       t.cached_input_tokens, t.output_tokens,
                       t.first_timestamp, t.last_timestamp
                FROM schema11_legacy_file_totals t
                JOIN schema11_current_versions v
                  ON v.path = t.file_path AND v.generation = t.file_generation
                JOIN sources s ON s.path = t.file_path;
                INSERT INTO dashboard_source_5m(
                    source_id, bucket_start, model_key, model, total_tokens, calls,
                    input_tokens, cached_input_tokens, output_tokens
                )
                SELECT s.source_id, t.bucket_start, t.model_key, t.model,
                       t.total_tokens, t.calls, t.input_tokens,
                       t.cached_input_tokens, t.output_tokens
                FROM schema11_legacy_file_5m t
                JOIN schema11_current_versions v
                  ON v.path = t.file_path AND v.generation = t.file_generation
                JOIN sources s ON s.path = t.file_path;

                INSERT INTO pending_dashboard_source_totals(
                    source_id, total_tokens, calls, input_tokens,
                    cached_input_tokens, output_tokens, first_timestamp, last_timestamp
                )
                SELECT s.source_id, t.total_tokens, t.calls, t.input_tokens,
                       t.cached_input_tokens, t.output_tokens,
                       t.first_timestamp, t.last_timestamp
                FROM schema11_legacy_file_totals t
                JOIN schema11_building_versions v
                  ON v.path = t.file_path AND v.generation = t.file_generation
                JOIN sources s ON s.path = t.file_path
                JOIN pending_sources p ON p.source_id = s.source_id
                WHERE p.mode = 'full';
                INSERT INTO pending_dashboard_source_5m(
                    source_id, bucket_start, model_key, model, total_tokens, calls,
                    input_tokens, cached_input_tokens, output_tokens
                )
                SELECT s.source_id, t.bucket_start, t.model_key, t.model,
                       t.total_tokens, t.calls, t.input_tokens,
                       t.cached_input_tokens, t.output_tokens
                FROM schema11_legacy_file_5m t
                JOIN schema11_building_versions v
                  ON v.path = t.file_path AND v.generation = t.file_generation
                JOIN sources s ON s.path = t.file_path
                JOIN pending_sources p ON p.source_id = s.source_id
                WHERE p.mode = 'full';

                INSERT INTO pending_dashboard_source_totals(
                    source_id, total_tokens, calls, input_tokens,
                    cached_input_tokens, output_tokens, first_timestamp, last_timestamp
                )
                SELECT source_id, SUM(tokens), COUNT(*), SUM(input_tokens),
                       SUM(MIN(cached_input_tokens, input_tokens)), SUM(output_tokens),
                       MIN(timestamp), MAX(timestamp)
                FROM pending_event_rows
                WHERE source_id IN (SELECT source_id FROM schema11_delta_sources)
                GROUP BY source_id;
                INSERT INTO pending_dashboard_source_5m(
                    source_id, bucket_start, model_key, model, total_tokens, calls,
                    input_tokens, cached_input_tokens, output_tokens
                )
                SELECT source_id, timestamp - (timestamp % 300), COALESCE(model, ''),
                       MAX(model), SUM(tokens), COUNT(*), SUM(input_tokens),
                       SUM(MIN(cached_input_tokens, input_tokens)), SUM(output_tokens)
                FROM pending_event_rows
                WHERE source_id IN (SELECT source_id FROM schema11_delta_sources)
                GROUP BY source_id, timestamp - (timestamp % 300), COALESCE(model, '');
                "#,
            )
            .map_err(|error| format!("无法迁移 schema 11 文件聚合：{error}"))?;

        let aggregate_generation =
            metadata_i64(&transaction, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?
                .filter(|value| *value >= 0 && *value <= published)
                .unwrap_or(published);
        transaction
            .execute(
                r#"
                INSERT INTO dashboard_5m_current(
                    bucket_start, model_key, model, total_tokens, calls,
                    input_tokens, cached_input_tokens, output_tokens
                )
                SELECT bucket_start, model_key, model, total_tokens, calls,
                       input_tokens, cached_input_tokens, output_tokens
                FROM schema11_legacy_dashboard_5m WHERE file_generation = ?1
                "#,
                params![aggregate_generation],
            )
            .map_err(|error| format!("无法迁移 schema 11 已发布全局聚合：{error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO dashboard_turn_candidates_current(
                    source_id, ordinal, event_id, source_file_generation,
                    timestamp, total_tokens, input_tokens, cached_input_tokens,
                    output_tokens, user_prompt_start, user_prompt_end,
                    assistant_response_start, assistant_response_end,
                    turn_index, session_calls
                )
                SELECT s.source_id, t.ordinal, e.id, s.last_seen_generation,
                       t.timestamp, t.total_tokens, t.input_tokens,
                       t.cached_input_tokens, t.output_tokens, t.user_prompt_start,
                       t.user_prompt_end, t.assistant_response_start,
                       t.assistant_response_end, t.turn_index, t.session_calls
                FROM schema11_legacy_turns t
                JOIN sources s ON s.path = t.file_path
                JOIN event_rows e ON e.source_id = s.source_id AND e.ordinal = t.ordinal
                WHERE t.aggregate_generation = ?1
                "#,
                params![aggregate_generation],
            )
            .map_err(|error| format!("无法迁移 schema 11 已发布轮次聚合：{error}"))?;
        if let Some(building) = building {
            let has_building_aggregate = transaction
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM schema11_legacy_dashboard_5m WHERE file_generation = ?1)",
                    params![building],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(|error| format!("无法检查 schema 11 未完成全局聚合：{error}"))?;
            if has_building_aggregate {
                transaction
                    .execute(
                        r#"
                        INSERT INTO pending_dashboard_5m(
                            target_generation, bucket_start, model_key, model,
                            total_tokens, calls, input_tokens, cached_input_tokens,
                            output_tokens
                        )
                        SELECT ?1, bucket_start, model_key, model, total_tokens,
                               calls, input_tokens, cached_input_tokens, output_tokens
                        FROM schema11_legacy_dashboard_5m WHERE file_generation = ?1
                        "#,
                        params![building],
                    )
                    .map_err(|error| format!("无法迁移 schema 11 未完成全局聚合：{error}"))?;
                transaction
                    .execute(
                        r#"
                        INSERT INTO pending_dashboard_5m_tombstones(
                            target_generation, bucket_start, model_key
                        )
                        SELECT ?1, c.bucket_start, c.model_key
                        FROM dashboard_5m_current c
                        WHERE NOT EXISTS(
                            SELECT 1 FROM pending_dashboard_5m p
                            WHERE p.target_generation = ?1
                              AND p.bucket_start = c.bucket_start
                              AND p.model_key = c.model_key
                        )
                        "#,
                        params![building],
                    )
                    .map_err(|error| format!("无法迁移 schema 11 全局聚合墓碑：{error}"))?;
            }
            let has_building_turns = transaction
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM schema11_legacy_turns WHERE aggregate_generation = ?1)",
                    params![building],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(|error| format!("无法检查 schema 11 未完成轮次聚合：{error}"))?;
            if has_building_turns {
                transaction
                    .execute(
                        r#"
                        INSERT INTO pending_dashboard_turn_candidates(
                            target_generation, source_id, ordinal, event_id,
                            source_file_generation, timestamp, total_tokens,
                            input_tokens, cached_input_tokens, output_tokens,
                            user_prompt_start, user_prompt_end,
                            assistant_response_start, assistant_response_end,
                            turn_index, session_calls
                        )
                        SELECT ?1, s.source_id, t.ordinal, COALESCE(pe.id, e.id),
                               COALESCE(p.target_generation, s.last_seen_generation),
                               t.timestamp, t.total_tokens,
                               t.input_tokens, t.cached_input_tokens, t.output_tokens,
                               t.user_prompt_start, t.user_prompt_end,
                               t.assistant_response_start, t.assistant_response_end,
                               t.turn_index, t.session_calls
                        FROM schema11_legacy_turns t
                        JOIN sources s ON s.path = t.file_path
                        LEFT JOIN pending_sources p
                          ON p.source_id = s.source_id AND p.target_generation = ?1
                        LEFT JOIN pending_event_rows pe
                          ON pe.source_id = s.source_id AND pe.ordinal = t.ordinal
                        LEFT JOIN event_rows e
                          ON e.source_id = s.source_id AND e.ordinal = t.ordinal
                        WHERE t.aggregate_generation = ?1
                          AND (p.mode IS NULL OR p.mode <> 'tombstone')
                          AND (
                            (p.mode IS NULL AND e.id IS NOT NULL)
                            OR (p.mode = 'full' AND pe.id IS NOT NULL)
                            OR (p.mode = 'delta' AND COALESCE(pe.id, e.id) IS NOT NULL)
                          )
                        "#,
                        params![building],
                    )
                    .map_err(|error| format!("无法迁移 schema 11 未完成轮次聚合：{error}"))?;
                transaction
                    .execute(
                        r#"
                        INSERT INTO pending_dashboard_turn_tombstones(
                            target_generation, source_id, ordinal
                        )
                        SELECT ?1, c.source_id, c.ordinal
                        FROM dashboard_turn_candidates_current c
                        WHERE NOT EXISTS(
                            SELECT 1 FROM pending_dashboard_turn_candidates p
                            WHERE p.target_generation = ?1
                              AND p.source_id = c.source_id AND p.ordinal = c.ordinal
                        )
                        "#,
                        params![building],
                    )
                    .map_err(|error| format!("无法迁移 schema 11 轮次聚合墓碑：{error}"))?;
            }
        }
        transaction
            .execute(
                r#"
                INSERT INTO metadata(key, value) VALUES(
                    'event_id_sequence',
                    CAST(MAX(
                        COALESCE((SELECT MAX(id) FROM event_rows), 0),
                        COALESCE((SELECT MAX(id) FROM pending_event_rows), 0)
                    ) AS TEXT)
                ) ON CONFLICT(key) DO UPDATE SET value = excluded.value
                "#,
                [],
            )
            .map_err(|error| format!("无法迁移 schema 11 事件序列：{error}"))?;
        maybe_fail_schema11_migration_for_testing(4)?;

        transaction
            .execute_batch(
                r#"
                DROP TABLE schema11_legacy_events;
                DROP TABLE schema11_legacy_fingerprints;
                DROP TABLE schema11_legacy_chunks;
                DROP TABLE schema11_legacy_enrichment;
                DROP TABLE schema11_legacy_file_totals;
                DROP TABLE schema11_legacy_file_5m;
                DROP TABLE schema11_legacy_dashboard_5m;
                DROP TABLE schema11_legacy_turns;
                DROP TABLE schema11_legacy_files;
                DELETE FROM metadata WHERE key = 'codex_home_physical_identity';
                INSERT INTO metadata(key, value) VALUES ('schema_version', '11')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                "#,
            )
            .map_err(|error| format!("无法完成 schema 11 候选表切换：{error}"))?;
        // Full candidate validation checks foreign keys after VACUUM and
        // before any switch. The private conversion need not scan them twice.
        preparation.advance("candidate_commit");
        maybe_fail_schema11_migration_for_testing(5)?;
        transaction
            .commit()
            .map_err(|error| format!("无法提交 schema 11 候选迁移：{error}"))
    })();
    let restore = restore_identity_migration_pragmas(&connection, legacy_alter_table);
    match (migration, restore) {
        (Err(error), Ok(())) => return Err(error),
        (Err(error), Err(restore_error)) => {
            return Err(format!(
                "{error}；同时无法恢复 SQLite 约束：{restore_error}"
            ))
        }
        (Ok(()), Err(error)) => return Err(error),
        (Ok(()), Ok(())) => {}
    }
    preparation.advance("candidate_vacuum");
    #[cfg(test)]
    connection
        .execute_batch("VACUUM; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
        .map_err(|error| format!("无法压实 schema 11 候选库：{error}"))?;
    #[cfg(not(test))]
    crate::core::business_store_route::seal_exact_store(candidate_path)?;
    preparation.finish();
    // The caller immediately advances to the Migrated phase and performs the
    // complete candidate validation, including quick_check. Repeating it here
    // scans the same private database twice without creating a new durability
    // boundary between the checks.
    Ok(())
}

#[cfg(test)]
fn maybe_fail_schema11_migration_for_testing(stage: u8) -> Result<(), String> {
    FAIL_SCHEMA11_MIGRATION_STAGE.with(|value| {
        if value.get() == stage {
            value.set(0);
            Err(format!(
                "injected schema 11 candidate migration failure at stage {stage}"
            ))
        } else {
            Ok(())
        }
    })
}

#[cfg(not(test))]
fn maybe_fail_schema11_migration_for_testing(_stage: u8) -> Result<(), String> {
    Ok(())
}

fn prepare_schema11_candidate_if_needed(
    index_path: &Path,
    codex_home: &Path,
) -> Result<Option<Schema11ValidatedStorage>, String> {
    let (candidate_path, rollback_path, manifest_path) = active_schema11_paths(index_path)?;

    let has_candidate = existing_regular_index(&candidate_path)?;
    let has_rollback = existing_regular_index(&rollback_path)?;
    if !manifest_path.exists() {
        if has_candidate || has_rollback {
            return Err("发现未登记的 schema 11 候选库或回滚库；为避免覆盖，已停止自动迁移".into());
        }
        if !existing_regular_index(index_path)? {
            return Ok(None);
        }
        // Probe only the schema marker before invoking the migration receipt.
        // A schema-11 compatible open must keep using the normal integrity
        // receipt path; running candidate `quick_check` here would duplicate
        // that work on every launch and would inspect the database before the
        // read-only compatibility gate rejects future revisions.
        let Ok(source) = open_read_only_index(index_path, StdDuration::from_secs(1)) else {
            // This is only a migration-routing probe. Let the normal read-only
            // compatibility/integrity path classify and report any open or
            // page error with its established non-destructive diagnostics.
            return Ok(None);
        };
        let Ok(metadata_exists) = source.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'metadata')",
            [],
            |row| row.get::<_, bool>(0),
        ) else {
            return Ok(None);
        };
        let source_schema = if metadata_exists {
            match source
                .query_row(
                    "SELECT value FROM metadata WHERE key = 'schema_version'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()
            {
                Ok(value) => value.and_then(|value| value.parse::<i64>().ok()),
                Err(_) => return Ok(None),
            }
        } else {
            None
        };
        drop(source);
        if !matches!(source_schema, Some(GITHUB_BASE_SCHEMA_VERSION | 10)) {
            return Ok(None);
        }
        let mut preparation = IndexPreparationTrace::new("source_integrity");
        let source_receipt = schema11_source_receipt(index_path)?;
        preparation.advance("source_facts");
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在核对旧索引并准备 schema 11 无损升级",
            0,
            None,
        );
        schema11_migration_capacity(index_path)?;
        let source_connection = open_read_only_index(index_path, StdDuration::from_secs(5))
            .map_err(|error| format!("无法只读读取 schema 11 迁移基线：{error}"))?;
        let source_facts_started = Instant::now();
        let source_facts =
            schema11_migration_facts(&source_connection, source_receipt.schema_version)?;
        // The proof is owned data. Release the baseline connection before
        // resume can rename the source: SQLite's Windows handle does not
        // share delete access, so retaining it here blocks our own switch.
        drop(source_connection);
        startup_trace::mark_performance(format!(
            "schema11_migration stage=source_facts elapsed_ms={}",
            source_facts_started.elapsed().as_millis()
        ));
        preparation.finish();
        let mut manifest = Schema11CandidateManifest {
            manifest_version: SCHEMA11_CANDIDATE_MANIFEST_VERSION,
            source_path: index_path.to_string_lossy().into_owned(),
            candidate_path: candidate_path.to_string_lossy().into_owned(),
            rollback_path: rollback_path.to_string_lossy().into_owned(),
            source_receipt,
            source_facts: Some(source_facts),
            phase: Schema11CandidatePhase::Prepared,
        };
        schema11_store_manifest(&manifest_path, &manifest)?;
        let validation = schema11_resume_candidate(
            &mut manifest,
            &manifest_path,
            index_path,
            &candidate_path,
            &rollback_path,
            codex_home,
            true,
        )?;
        return Ok(Some(validation));
    }

    let mut manifest = schema11_load_manifest(&manifest_path)?;
    if manifest.manifest_version != SCHEMA11_CANDIDATE_MANIFEST_VERSION
        || manifest.source_path != index_path.to_string_lossy()
        || manifest.candidate_path != candidate_path.to_string_lossy()
        || manifest.rollback_path != rollback_path.to_string_lossy()
    {
        return Err("schema 11 候选迁移清单与当前索引路径不匹配，已保留全部现场".into());
    }
    if manifest.phase == Schema11CandidatePhase::Retained {
        if !existing_regular_index(index_path)? {
            return Err("已迁移账本缺失；保留旧库并停止自动重建".into());
        }
        return Ok(None);
    }
    let validation = schema11_resume_candidate(
        &mut manifest,
        &manifest_path,
        index_path,
        &candidate_path,
        &rollback_path,
        codex_home,
        false,
    )?;
    Ok(Some(validation))
}

fn schema11_resume_candidate(
    manifest: &mut Schema11CandidateManifest,
    manifest_path: &Path,
    index_path: &Path,
    candidate_path: &Path,
    rollback_path: &Path,
    codex_home: &Path,
    source_integrity_verified: bool,
) -> Result<Schema11ValidatedStorage, String> {
    let resumed_from_validated = manifest.phase == Schema11CandidatePhase::Validated;
    if manifest.phase == Schema11CandidatePhase::Switched {
        // The switched schema 11 database is allowed to accumulate a durable
        // unfinished generation before the first successful refresh. The
        // source facts were already checked before the atomic switch; on a
        // later open validate structure and integrity without comparing the
        // now-legitimate pending overlay to the pre-switch snapshot.
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在复核已切换的 schema 11 索引",
            0,
            None,
        );
        return validate_schema11_storage(index_path, None);
    }
    if manifest.phase == Schema11CandidatePhase::Switching {
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在完成 schema 11 索引原子切换",
            0,
            None,
        );
        let facts = manifest
            .source_facts
            .clone()
            .ok_or_else(|| "schema 11 切换清单缺少对账事实".to_string())?;
        return schema11_finish_candidate_switch(
            manifest,
            manifest_path,
            index_path,
            candidate_path,
            rollback_path,
            &facts,
            None,
        );
    }
    if !schema11_receipt_matches_current(index_path, &manifest.source_receipt)? {
        return Err(
            "活动索引在 schema 11 候选迁移期间发生变化；候选库、回滚库和清单均已保留".into(),
        );
    }
    if !source_integrity_verified
        && !schema11_receipt_matches_current_with_integrity(index_path, &manifest.source_receipt)?
    {
        return Err("活动索引在 schema 11 恢复校验期间发生变化；已保留现场".into());
    }
    let source_facts = if let Some(facts) = manifest.source_facts.clone() {
        facts
    } else {
        let source = open_read_only_index(index_path, StdDuration::from_secs(5))
            .map_err(|error| format!("无法读取 schema 11 候选迁移对账事实：{error}"))?;
        let facts = schema11_migration_facts(&source, manifest.source_receipt.schema_version)?;
        manifest.source_facts = Some(facts.clone());
        schema11_store_manifest(manifest_path, manifest)?;
        facts
    };

    let mut validation = None;
    if manifest.phase == Schema11CandidatePhase::Prepared {
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在复制旧索引到 schema 11 受管候选库",
            0,
            None,
        );
        let stage_started = Instant::now();
        if existing_regular_index(candidate_path)? {
            let candidate = open_read_only_index(candidate_path, StdDuration::from_secs(5))
                .map_err(|error| format!("无法验证已有 schema 11 候选副本：{error}"))?;
            let candidate_facts =
                schema11_migration_facts(&candidate, manifest.source_receipt.schema_version)?;
            if !candidate_facts.preserves(&source_facts) {
                return Err("已有 schema 11 候选库不是活动库的完整副本；已保留现场".into());
            }
        } else {
            schema11_copy_candidate(index_path, candidate_path)?;
        }
        startup_trace::mark_performance(format!(
            "schema11_migration stage=copy_candidate elapsed_ms={}",
            stage_started.elapsed().as_millis()
        ));
        maybe_fail_schema11_migration_for_testing(6)?;
        manifest.phase = Schema11CandidatePhase::Copied;
        schema11_store_manifest(manifest_path, manifest)?;
    }

    if manifest.phase == Schema11CandidatePhase::Copied {
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在转换 schema 11 索引结构并压实候选库",
            0,
            None,
        );
        let stage_started = Instant::now();
        migrate_schema9_or10_to_schema11_candidate(candidate_path)?;
        startup_trace::mark_performance(format!(
            "schema11_migration stage=convert_and_vacuum elapsed_ms={}",
            stage_started.elapsed().as_millis()
        ));
        maybe_fail_schema11_migration_for_testing(7)?;
        manifest.phase = Schema11CandidatePhase::Migrated;
        schema11_store_manifest(manifest_path, manifest)?;
    }

    if manifest.phase == Schema11CandidatePhase::Migrated {
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在校验 schema 11 候选库数据与完整性",
            0,
            None,
        );
        let stage_started = Instant::now();
        validation = Some(validate_schema11_candidate(candidate_path, &source_facts)?);
        startup_trace::mark_performance(format!(
            "schema11_migration stage=validate_candidate elapsed_ms={}",
            stage_started.elapsed().as_millis()
        ));
        if !schema11_receipt_matches_current(index_path, &manifest.source_receipt)? {
            return Err("活动索引在 schema 11 候选校验期间发生变化；尚未切换".into());
        }
        maybe_fail_schema11_migration_for_testing(8)?;
        manifest.phase = Schema11CandidatePhase::Validated;
        schema11_store_manifest(manifest_path, manifest)?;
        maybe_fail_schema11_migration_for_testing(13)?;
    }

    if manifest.phase == Schema11CandidatePhase::Validated {
        if resumed_from_validated {
            // A prior process may have stopped after persisting Validated. The
            // private candidate has crossed a process boundary since its last
            // facts check, so revalidate it before any rename can occur.
            validation = Some(validate_schema11_candidate(candidate_path, &source_facts)?);
        }
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在同步并准备原子切换 schema 11 索引",
            0,
            None,
        );
        schema11_sync_file(candidate_path)?;
        schema11_sync_parent(index_path)?;
        manifest.phase = Schema11CandidatePhase::Switching;
        schema11_store_manifest(manifest_path, manifest)?;
        maybe_fail_schema11_migration_for_testing(9)?;
    }

    if manifest.phase == Schema11CandidatePhase::Switching {
        super::update_precise_dashboard_progress(
            codex_home,
            "migrating",
            "正在完成 schema 11 索引原子切换",
            0,
            None,
        );
        let stage_started = Instant::now();
        let validated = schema11_finish_candidate_switch(
            manifest,
            manifest_path,
            index_path,
            candidate_path,
            rollback_path,
            &source_facts,
            validation,
        )?;
        startup_trace::mark_performance(format!(
            "schema11_migration stage=switch_candidate elapsed_ms={}",
            stage_started.elapsed().as_millis()
        ));
        return Ok(validated);
    }
    Err("schema 11 迁移未到达可验证阶段；已保留全部现场".into())
}

fn schema11_finish_candidate_switch(
    manifest: &mut Schema11CandidateManifest,
    manifest_path: &Path,
    index_path: &Path,
    candidate_path: &Path,
    rollback_path: &Path,
    facts: &Schema11MigrationFacts,
    validated: Option<Schema11ValidatedStorage>,
) -> Result<Schema11ValidatedStorage, String> {
    #[cfg(not(test))]
    {
        use crate::core::business_store_route as route;
        if existing_regular_index(index_path)? && !route::owns_exact_migration_artifact(rollback_path)? {
            if !schema11_receipt_matches_current(index_path, &manifest.source_receipt)? {
                return Err("活动索引在候选切换前发生变化；已保留候选库和清单".into());
            }
            crate::core::business_store_route::clone_exact_store(index_path, rollback_path)?;
            maybe_fail_schema11_migration_for_testing(10)?;
        }
        if !route::owns_exact_migration_artifact(rollback_path)? {
            return Err("schema 11 切换缺少受管回滚命名空间；已保留候选和清单".into());
        }
        if route::owns_exact_migration_artifact(candidate_path)? {
            crate::core::business_store_route::replace_exact_store(candidate_path, index_path)?;
            schema11_sync_file(index_path)?;
            maybe_fail_schema11_migration_for_testing(11)?;
        }
        let validation = validate_schema11_candidate(index_path, facts)?;
        maybe_fail_schema11_migration_for_testing(12)?;
        manifest.phase = Schema11CandidatePhase::Switched;
        schema11_store_manifest(manifest_path, manifest)?;
        crate::core::business_store_route::remove_exact_store(candidate_path)?;
        return Ok(validation);
    }
    #[cfg(test)]
    {
    if existing_regular_index(index_path)? && !existing_regular_index(rollback_path)? {
        if !schema11_receipt_matches_current(index_path, &manifest.source_receipt)? {
            return Err("活动索引在原子切换前发生变化；已保留候选库和清单".into());
        }
        fs::rename(index_path, rollback_path)
            .map_err(|error| format!("无法为 schema 11 活动库建立受管回滚副本：{error}"))?;
        maybe_fail_schema11_migration_for_testing(10)?;
        schema11_move_sidecar_if_present(
            &sqlite_sidecar_path(index_path, "-wal"),
            &sqlite_sidecar_path(rollback_path, "-wal"),
        )?;
        schema11_move_sidecar_if_present(
            &sqlite_sidecar_path(index_path, "-shm"),
            &sqlite_sidecar_path(rollback_path, "-shm"),
        )?;
        schema11_move_sidecar_if_present(
            &sqlite_sidecar_path(index_path, "-journal"),
            &sqlite_sidecar_path(rollback_path, "-journal"),
        )?;
        schema11_sync_parent(index_path)?;
    }
    if !existing_regular_index(rollback_path)? {
        return Err("schema 11 切换缺少受管回滚数据库；已保留候选和清单".into());
    }
    if !existing_regular_index(index_path)? {
        // A crash can occur after the main database rename but before its WAL
        // and SHM siblings were moved. Complete that sidecar move before the
        // canonical path is reused by the independent candidate database.
        schema11_move_sidecar_if_present(
            &sqlite_sidecar_path(index_path, "-wal"),
            &sqlite_sidecar_path(rollback_path, "-wal"),
        )?;
        schema11_move_sidecar_if_present(
            &sqlite_sidecar_path(index_path, "-shm"),
            &sqlite_sidecar_path(rollback_path, "-shm"),
        )?;
        schema11_move_sidecar_if_present(
            &sqlite_sidecar_path(index_path, "-journal"),
            &sqlite_sidecar_path(rollback_path, "-journal"),
        )?;
        if !existing_regular_index(candidate_path)? {
            return Err("schema 11 候选切换未完成；下次启动将按清单继续".into());
        }
        fs::rename(candidate_path, index_path)
            .map_err(|error| format!("无法把 schema 11 候选库切换为活动库：{error}"))?;
        schema11_sync_parent(index_path)?;
        maybe_fail_schema11_migration_for_testing(11)?;
    } else if existing_regular_index(candidate_path)? {
        return Err("schema 11 候选与活动库同时存在；已停止切换并保留现场".into());
    }
    schema11_sync_file(index_path)?;
    schema11_sync_parent(index_path)?;
    // Only a proof produced during this locked open may cross the rename.
    // A resumed Switching phase has no in-memory proof and revalidates fully.
    let validation = if let Some(validated) = validated.filter(|verified| {
        schema11_receipt_matches_current(index_path, &verified.receipt).unwrap_or(false)
    }) {
        startup_trace::mark_performance("exact_prepare reuse=validated_candidate_after_rename");
        validated
    } else {
        validate_schema11_candidate(index_path, facts)?
    };
    maybe_fail_schema11_migration_for_testing(12)?;
    manifest.phase = Schema11CandidatePhase::Switched;
    schema11_store_manifest(manifest_path, manifest)?;
    Ok(validation)
    }
}

fn validate_schema11_candidate(
    index_path: &Path,
    expected_facts: &Schema11MigrationFacts,
) -> Result<Schema11ValidatedStorage, String> {
    validate_schema11_storage(index_path, Some(expected_facts))
}

fn validate_schema11_storage(
    index_path: &Path,
    expected_facts: Option<&Schema11MigrationFacts>,
) -> Result<Schema11ValidatedStorage, String> {
    let preparation = IndexPreparationTrace::new("candidate_validation");
    let connection = open_read_only_index(index_path, StdDuration::from_secs(5))
        .map_err(|error| format!("无法只读打开 schema 11 候选库：{error}"))?;
    let storage_before = schema11_source_receipt_from_connection(index_path, &connection)?;
    if matches!(metadata_i64(&connection, "schema_version")?, Some(12) | Some(ACCOUNTING_SCHEMA_VERSION) | Some(CURRENT_SCHEMA_VERSION)) {
        // Resume manifests written by a previous schema-12 accounting build.
        let receipt=metadata_text(&connection,"accounting_structural_receipt")?.ok_or("Missing accounting structural receipt")?;
        let facts: Schema11MigrationFacts=serde_json::from_str(&receipt).map_err(|e|e.to_string())?;
        if expected_facts.is_some_and(|expected| !facts.preserves(expected)) { return Err("Accounting structural receipt mismatch".into()); }
        quick_check_index(&connection, Some(index_path))?;
        if connection.query_row("PRAGMA foreign_key_check", [], |_| Ok(true))
            .optional().map_err(|e| e.to_string())?.unwrap_or(false) {
            return Err("Accounting converted index foreign key check failed".into());
        }
        let receipt = schema11_source_receipt_from_connection(index_path, &connection)?;
        if receipt != storage_before { return Err("校验期间 schema 12 索引发生变化；已保留现场".into()); }
        preparation.finish();
        return Ok(Schema11ValidatedStorage { receipt, facts: Some(facts) });
    }
    if metadata_i64(&connection, "schema_version")? != Some(INDEX_SCHEMA_VERSION) {
        return Err("schema 11 候选库 schema 版本不是 11".into());
    }
    quick_check_index(&connection, Some(index_path))?;
    let foreign_key_failure = connection
        .query_row("PRAGMA foreign_key_check", [], |_| Ok(true))
        .optional()
        .map_err(|error| format!("无法执行 schema 11 候选库外键检查：{error}"))?
        .unwrap_or(false);
    if foreign_key_failure {
        return Err("schema 11 候选库 foreign_key_check 未通过".into());
    }
    if expected_facts.is_none() {
        let mut fingerprints = connection
            .prepare(
                "SELECT fingerprint FROM source_fingerprints UNION ALL SELECT fingerprint FROM pending_fingerprints",
            )
            .map_err(|error| format!("无法读取 schema 11 候选指纹：{error}"))?;
        let rows = fingerprints
            .query_map([], |row| row.get::<_, Vec<u8>>(0))
            .map_err(|error| format!("无法遍历 schema 11 候选指纹：{error}"))?;
        for row in rows {
            let value = row.map_err(|error| format!("无法解码 schema 11 候选指纹：{error}"))?;
            fingerprint_codec::decode(&value)
                .map_err(|error| format!("schema 11 候选指纹不是 canonical codec：{error}"))?;
        }
        drop(fingerprints);
    }
    let stale_pending = connection
        .query_row(
            r#"
            SELECT EXISTS(
                SELECT p.target_generation FROM pending_sources p
                WHERE NOT EXISTS(SELECT 1 FROM active_building_generation b
                                 WHERE b.generation = p.target_generation)
                UNION ALL
                SELECT p.target_generation FROM pending_dashboard_5m p
                WHERE NOT EXISTS(SELECT 1 FROM active_building_generation b
                                 WHERE b.generation = p.target_generation)
                UNION ALL
                SELECT p.target_generation FROM pending_dashboard_5m_tombstones p
                WHERE NOT EXISTS(SELECT 1 FROM active_building_generation b
                                 WHERE b.generation = p.target_generation)
                UNION ALL
                SELECT p.target_generation FROM pending_dashboard_turn_candidates p
                WHERE NOT EXISTS(SELECT 1 FROM active_building_generation b
                                 WHERE b.generation = p.target_generation)
                UNION ALL
                SELECT p.target_generation FROM pending_dashboard_turn_tombstones p
                WHERE NOT EXISTS(SELECT 1 FROM active_building_generation b
                                 WHERE b.generation = p.target_generation)
            )
            "#,
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查 schema 11 候选 pending 代次：{error}"))?;
    if stale_pending {
        return Err("schema 11 候选库包含未绑定唯一活动 building generation 的 pending 行".into());
    }
    let invalid_turn_reference = connection
        .query_row(
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM dashboard_turn_candidates_current t
                JOIN sources s ON s.source_id = t.source_id
                LEFT JOIN event_rows e
                  ON e.id = t.event_id AND e.source_id = t.source_id
                 AND e.ordinal = t.ordinal
                WHERE e.id IS NULL
                   OR t.source_file_generation <> s.last_seen_generation
                UNION ALL
                SELECT 1
                FROM pending_dashboard_turn_candidates t
                JOIN sources s ON s.source_id = t.source_id
                LEFT JOIN pending_sources p
                  ON p.source_id = t.source_id
                 AND p.target_generation = t.target_generation
                LEFT JOIN pending_event_rows pe
                  ON pe.id = t.event_id AND pe.source_id = t.source_id
                 AND pe.ordinal = t.ordinal
                LEFT JOIN event_rows e
                  ON e.id = t.event_id AND e.source_id = t.source_id
                 AND e.ordinal = t.ordinal
                WHERE t.source_file_generation <> COALESCE(
                          p.target_generation, s.last_seen_generation
                      )
                   OR p.mode = 'tombstone'
                   OR (p.mode IS NULL AND e.id IS NULL)
                   OR (p.mode = 'full' AND pe.id IS NULL)
                   OR (p.mode = 'delta' AND pe.id IS NULL AND e.id IS NULL)
            )
            "#,
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查 schema 11 轮次候选事件引用：{error}"))?;
    if invalid_turn_reference {
        return Err(
            "schema 11 候选库轮次候选未绑定同一 source/ordinal 的稳定事件与真实文件代次"
                .into(),
        );
    }
    if let Some(expected_facts) = expected_facts {
        let actual_facts = schema11_migration_facts(&connection, INDEX_SCHEMA_VERSION)?;
        if !actual_facts.preserves(expected_facts) {
            return Err(format!(
                "schema 11 候选库事件、指纹、分块、聚合或 lineage 对账失败：expected={expected_facts:?}, actual={actual_facts:?}"
            ));
        }
    }
    let receipt = schema11_source_receipt_from_connection(index_path, &connection)?;
    if receipt != storage_before { return Err("校验期间 schema 11 索引发生变化；已保留现场".into()); }
    preparation.finish();
    Ok(Schema11ValidatedStorage { receipt, facts: expected_facts.cloned() })
}

#[cfg(test)]
pub(super) fn cleanup_schema11_migration_for_testing(codex_home: &Path) -> Result<(), String> {
    let index_path = database_path(codex_home)?;
    cleanup_successful_schema11_migration(&index_path)
}

const MIGRATION_RETENTION_KEY: &str = "release_upgrade_retention_v1";

fn migration_retention_receipt(source: &Path, manifest: Option<&Schema11CandidateManifest>) -> serde_json::Value {
    let base = manifest.and_then(|m| m.candidate_path.strip_suffix(SCHEMA11_CANDIDATE_SUFFIX))
        .map(PathBuf::from).unwrap_or_else(|| source.to_path_buf());
    serde_json::json!({
        "sourcePath": source.to_string_lossy(),
        "rollbackPath": schema11_rollback_path(&base).to_string_lossy(),
        "manifestPath": schema11_manifest_path(&base).to_string_lossy(),
        "sourceSchema": manifest.map(|m| m.source_receipt.schema_version).unwrap_or(CURRENT_SCHEMA_VERSION),
        "targetSchema": CURRENT_SCHEMA_VERSION, "status": "copied"
    })
}

/// Metadata travels with relocation. Only a published ordinary sync marks it
/// successful; old databases and all migration evidence remain for next release.
fn record_successful_migration_retention(connection: &Connection, index_path: &Path) -> Result<(), String> {
    let mut receipt: Option<serde_json::Value> = metadata_text(connection, MIGRATION_RETENTION_KEY)?
        .map(|v| serde_json::from_str(&v).map_err(|e| format!("无法读取迁移保留标识：{e}")))
        .transpose()?;
    if receipt.as_ref().is_some_and(|r| r["status"] == "succeeded") { return Ok(()); }
    let (candidate_path, _, manifest_path) = active_schema11_paths_on(connection, index_path)?;
    if manifest_path.exists() {
        let mut manifest = schema11_load_manifest(&manifest_path)?;
        if !matches!(manifest.phase, Schema11CandidatePhase::Switched | Schema11CandidatePhase::Retained)
            || manifest.source_path != index_path.to_string_lossy()
            || existing_regular_index(&candidate_path)? { return Ok(()); }
        if receipt.is_none() { receipt = Some(migration_retention_receipt(index_path, Some(&manifest))); }
        manifest.phase = Schema11CandidatePhase::Retained;
        schema11_store_manifest(&manifest_path, &manifest)?;
    }
    let Some(mut receipt) = receipt else { return Ok(()); };
    receipt["status"] = serde_json::json!("succeeded");
    receipt["publishedGeneration"] = serde_json::json!(metadata_i64(connection, "published_generation")?);
    receipt["completedAtUnix"] = serde_json::json!(OffsetDateTime::now_utc().unix_timestamp());
    set_metadata(connection, MIGRATION_RETENTION_KEY, &receipt.to_string())
}

#[cfg(test)]
fn cleanup_successful_schema11_migration(index_path: &Path) -> Result<(), String> {
    let connection = Connection::open(index_path).map_err(|e| e.to_string())?;
    record_successful_migration_retention(&connection, index_path)
}

#[cfg(test)]
pub(super) fn verify_no_orphaned_index_rows_for_testing(
    connection: &mut Connection,
) -> Result<(), String> {
    verify_no_orphaned_index_rows(connection)
}

#[cfg(test)]
pub(super) fn open_index_for_testing(path: &Path) -> Result<Connection, String> {
    let connection = open_index_connection(path, true, true)?;
    initialize_index_schema(&connection)?;
    Ok(connection)
}

#[cfg(test)]
pub(super) fn open_existing_index_for_testing(path: &Path) -> Result<Connection, String> {
    open_index_connection(path, false, false)
}

fn delete_file_version_rows(
    transaction: &Transaction<'_>,
    generation: i64,
    path: &str,
) -> Result<(), String> {
    // Keep replacement idempotent even for legacy databases whose DELETE did
    // not run ON DELETE CASCADE. The child-first order is valid with FK ON and
    // also removes stale rows when an old writer left an orphan behind.
    transaction
        .execute(
            "DELETE FROM events WHERE file_generation = ?1 AND file_path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理精确 token 会话事件：{error}"))?;
    transaction
        .execute(
            "DELETE FROM file_fingerprints WHERE file_generation = ?1 AND file_path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理精确 token 会话去重状态：{error}"))?;
    transaction
        .execute(
            "DELETE FROM file_chunks WHERE file_generation = ?1 AND file_path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理精确 token 会话分块状态：{error}"))?;
    transaction
        .execute(
            "DELETE FROM files WHERE generation = ?1 AND path = ?2",
            params![generation, path],
        )
        .map_err(|error| format!("无法清理精确 token 会话文件版本：{error}"))?;
    Ok(())
}

fn migrate_github_base_index_schema(connection: &Connection) -> Result<(), String> {
    let source_count = table_row_count(connection, "files")?;
    ensure_identity_migration_capacity(connection, source_count)?;
    if pragma_u64(connection, "foreign_keys")? != 1 {
        return Err("精确 token schema 9→10 迁移前外键约束未启用，已拒绝修改".into());
    }
    let legacy_alter_table = pragma_u64(connection, "legacy_alter_table")?;

    // SQLite rewrites child-table foreign-key declarations when their parent
    // is renamed while foreign-key enforcement is enabled. Disable enforcement
    // only for this transaction and use legacy rename semantics so the large
    // events/chunks/aggregate tables continue to reference the replacement
    // `files` table without being copied or cascade-deleted. The complete graph
    // is checked before commit and enforcement is restored immediately after.
    connection
        .execute_batch("PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON;")
        .map_err(|error| format!("无法准备精确 token schema 9→10 原子换表：{error}"))?;
    if pragma_u64(connection, "foreign_keys")? != 0 {
        let _ = restore_identity_migration_pragmas(connection, legacy_alter_table);
        return Err("精确 token schema 9→10 无法安全暂停外键执行，已拒绝修改".into());
    }

    let migration_result = migrate_github_base_index_schema_transaction(connection, source_count);
    let restore_result = restore_identity_migration_pragmas(connection, legacy_alter_table);
    match (migration_result, restore_result) {
        (Err(migration_error), Ok(())) => Err(migration_error),
        (Err(migration_error), Err(restore_error)) => Err(format!(
            "{migration_error}；同时无法恢复 SQLite 外键设置：{restore_error}"
        )),
        (Ok(()), Err(restore_error)) => Err(format!(
            "精确 token schema 9→10 已提交，但无法恢复 SQLite 外键设置：{restore_error}"
        )),
        (Ok(()), Ok(())) => {
            if pragma_u64(connection, "foreign_keys")? != 1 {
                return Err("精确 token schema 9→10 后外键约束未恢复".into());
            }
            let foreign_key_failure = connection
                .query_row("PRAGMA foreign_key_check", [], |_| Ok(true))
                .optional()
                .map_err(|error| format!("无法复核精确 token 迁移外键：{error}"))?
                .unwrap_or(false);
            if foreign_key_failure {
                return Err("精确 token schema 9→10 提交后外键复核失败".into());
            }
            Ok(())
        }
    }
}

fn restore_identity_migration_pragmas(
    connection: &Connection,
    legacy_alter_table: u64,
) -> Result<(), String> {
    connection
        .execute_batch(if legacy_alter_table == 0 {
            "PRAGMA legacy_alter_table = OFF; PRAGMA foreign_keys = ON;"
        } else {
            "PRAGMA legacy_alter_table = ON; PRAGMA foreign_keys = ON;"
        })
        .map_err(|error| format!("无法恢复精确 token 迁移连接设置：{error}"))
}

fn migrate_github_base_index_schema_transaction(
    connection: &Connection,
    source_count: i64,
) -> Result<(), String> {
    let transaction = connection
        .unchecked_transaction()
        .map_err(|error| format!("无法开始精确 token 字段迁移事务：{error}"))?;
    transaction
        .execute_batch("PRAGMA defer_foreign_keys = ON;")
        .map_err(|error| format!("无法延迟精确 token 迁移外键检查：{error}"))?;
    let event_count = table_row_count(&transaction, "events")?;
    let fingerprint_count = table_row_count(&transaction, "file_fingerprints")?;
    let chunk_count = table_row_count(&transaction, "file_chunks")?;
    let receipt_count = table_row_count(&transaction, "event_enrichment_sources")?;
    let catalog_count = if table_exists_checked(&transaction, "session_catalog_files")? {
        table_row_count(&transaction, "session_catalog_files")?
    } else {
        0
    };
    let aggregate_total = transaction
        .query_row(
            "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_file_totals",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法读取精确 token 聚合对账值：{error}"))?;
    let aggregate_bucket_total = transaction
        .query_row(
            "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_file_5m",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法读取精确 token 分桶聚合对账值：{error}"))?;
    let lineage_keys = [
        "revision",
        "dashboard_revision",
        "published_generation",
        "building_generation",
        "building_changed",
        "building_dashboard_changed",
        "building_attribution_provenance_rotate",
        DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY,
        DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
        DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY,
        ATTRIBUTION_PROVENANCE_EPOCH_KEY,
        ATTRIBUTION_LEDGER_EPOCH_KEY,
        ATTRIBUTION_LEDGER_INTEGRITY_KEY,
    ];
    let lineage_before = lineage_keys
        .iter()
        .map(|key| metadata_text(&transaction, key))
        .collect::<Result<Vec<_>, _>>()?;

    transaction
        .execute_batch(
            r#"
            CREATE TABLE files_schema10_migration (
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
            INSERT INTO files_schema10_migration (
                generation, path, deleted, session_id, size, modified_ns,
                prefix_sha256, append_ready, resume_offset,
                previous_total_tokens, fork_replay_started_ns,
                fork_replay_active, is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns, current_model,
                current_user_prompt_start, current_user_prompt_end,
                assistant_response_start, assistant_response_end,
                audit_chunk_index
            )
            SELECT generation, path, deleted, session_id, size, modified_ns,
                   prefix_sha256, append_ready, resume_offset,
                   previous_total_tokens, fork_replay_started_ns,
                   fork_replay_active, is_explicit_subagent_fork,
                   last_skipped_fork_replay_token_ns, current_model,
                   current_user_prompt_start, current_user_prompt_end,
                   assistant_response_start, assistant_response_end,
                   audit_chunk_index
            FROM files;
            ALTER TABLE files RENAME TO files_schema9_backup;
            ALTER TABLE files_schema10_migration RENAME TO files;
            DROP TABLE files_schema9_backup;
            CREATE INDEX files_path_generation_idx
                ON files(path, generation DESC);
            "#,
        )
        .map_err(|error| format!("无法原子迁移精确 token 文件指纹表：{error}"))?;
    maybe_fail_schema9_migration_for_testing(1)?;

    transaction
        .execute_batch(
            r#"
            CREATE TABLE event_enrichment_sources_schema10_migration (
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
            INSERT INTO event_enrichment_sources_schema10_migration (
                path, revision, parser_revision, file_generation,
                completed_size, completed_prefix_sha256
            )
            SELECT path, revision, parser_revision, file_generation,
                   completed_size, completed_prefix_sha256
            FROM event_enrichment_sources;
            ALTER TABLE event_enrichment_sources
                RENAME TO event_enrichment_sources_schema9_backup;
            ALTER TABLE event_enrichment_sources_schema10_migration
                RENAME TO event_enrichment_sources;
            DROP TABLE event_enrichment_sources_schema9_backup;
            "#,
        )
        .map_err(|error| format!("无法原子迁移历史字段补全收据表：{error}"))?;
    maybe_fail_schema9_migration_for_testing(2)?;

    let had_session_catalog = table_exists_checked(&transaction, "session_catalog_files")?;
    transaction
        .execute_batch(
            r#"
            CREATE TABLE session_catalog_files_schema2_migration (
                path TEXT PRIMARY KEY,
                archived INTEGER NOT NULL,
                thread_id TEXT NOT NULL,
                cwd TEXT NOT NULL,
                source TEXT NOT NULL,
                session_id TEXT,
                forked_from_id TEXT,
                parent_thread_id TEXT,
                size INTEGER NOT NULL,
                modified_ns TEXT NOT NULL,
                created_ns TEXT NOT NULL,
                modified_at INTEGER,
                created_at INTEGER,
                first_line_bytes INTEGER NOT NULL,
                first_line_sha256 BLOB NOT NULL,
                last_seen_generation INTEGER NOT NULL
            ) WITHOUT ROWID;
            "#,
        )
        .map_err(|error| format!("无法创建会话目录 schema 2 迁移表：{error}"))?;
    if had_session_catalog {
        transaction
            .execute_batch(
                r#"
                INSERT INTO session_catalog_files_schema2_migration (
                    path, archived, thread_id, cwd, source, session_id,
                    forked_from_id, parent_thread_id, size, modified_ns,
                    created_ns, modified_at, created_at, first_line_bytes,
                    first_line_sha256, last_seen_generation
                )
                SELECT path, archived, thread_id, cwd, source, session_id,
                       forked_from_id, parent_thread_id, size, modified_ns,
                       created_ns, modified_at, created_at, first_line_bytes,
                       first_line_sha256, last_seen_generation
                FROM session_catalog_files;
                ALTER TABLE session_catalog_files
                    RENAME TO session_catalog_files_schema1_backup;
                ALTER TABLE session_catalog_files_schema2_migration
                    RENAME TO session_catalog_files;
                DROP TABLE session_catalog_files_schema1_backup;
                "#,
            )
            .map_err(|error| format!("无法原子迁移会话标题目录：{error}"))?;
    } else {
        transaction
            .execute_batch(
                "ALTER TABLE session_catalog_files_schema2_migration RENAME TO session_catalog_files;",
            )
            .map_err(|error| format!("无法发布空会话标题目录：{error}"))?;
    }
    transaction
        .execute_batch(
            r#"
            CREATE INDEX session_catalog_thread_id_idx
                ON session_catalog_files(thread_id, path);
            INSERT INTO metadata(key, value)
            VALUES ('session_catalog_schema_version', '2')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            INSERT OR IGNORE INTO metadata(key, value)
            SELECT 'session_catalog_published_generation',
                   CAST(COALESCE(MAX(last_seen_generation), 0) AS TEXT)
            FROM session_catalog_files;
            "#,
        )
        .map_err(|error| format!("无法发布会话标题目录 schema 2：{error}"))?;
    maybe_fail_schema9_migration_for_testing(3)?;

    transaction
        .execute(
            "DELETE FROM metadata WHERE key = 'codex_home_physical_identity'",
            [],
        )
        .map_err(|error| format!("无法清除旧统计根目录物理身份：{error}"))?;
    transaction
        .execute(
            "INSERT INTO metadata(key, value) VALUES ('schema_version', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [INDEX_SCHEMA_VERSION.to_string()],
        )
        .map_err(|error| format!("无法在迁移事务中发布精确 token schema 10：{error}"))?;
    let migrated_source_count = table_row_count(&transaction, "files")?;
    let migrated_event_count = table_row_count(&transaction, "events")?;
    let migrated_fingerprint_count = table_row_count(&transaction, "file_fingerprints")?;
    let migrated_chunk_count = table_row_count(&transaction, "file_chunks")?;
    let migrated_receipt_count = table_row_count(&transaction, "event_enrichment_sources")?;
    let migrated_catalog_count = table_row_count(&transaction, "session_catalog_files")?;
    let migrated_aggregate_total = transaction
        .query_row(
            "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_file_totals",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法读取迁移后精确 token 聚合对账值：{error}"))?;
    let migrated_aggregate_bucket_total = transaction
        .query_row(
            "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_file_5m",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法读取迁移后精确 token 分桶聚合对账值：{error}"))?;
    if (
        source_count,
        event_count,
        fingerprint_count,
        chunk_count,
        receipt_count,
        catalog_count,
        aggregate_total,
        aggregate_bucket_total,
    ) != (
        migrated_source_count,
        migrated_event_count,
        migrated_fingerprint_count,
        migrated_chunk_count,
        migrated_receipt_count,
        migrated_catalog_count,
        migrated_aggregate_total,
        migrated_aggregate_bucket_total,
    ) {
        return Err("精确 token schema 9→10 元数据或聚合对账失败".into());
    }
    let lineage_after = lineage_keys
        .iter()
        .map(|key| metadata_text(&transaction, key))
        .collect::<Result<Vec<_>, _>>()?;
    if lineage_after != lineage_before {
        return Err("精确 token schema 9→10 发布代次或断点状态对账失败".into());
    }
    let foreign_key_failure = transaction
        .query_row("PRAGMA foreign_key_check", [], |_| Ok(true))
        .optional()
        .map_err(|error| format!("无法执行精确 token 迁移外键检查：{error}"))?
        .unwrap_or(false);
    if foreign_key_failure {
        return Err("精确 token schema 9→10 外键检查失败".into());
    }
    maybe_fail_schema9_migration_for_testing(4)?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交精确 token 字段迁移事务：{error}"))
}

#[cfg(test)]
fn maybe_fail_schema9_migration_for_testing(stage: u8) -> Result<(), String> {
    FAIL_SCHEMA9_MIGRATION_STAGE.with(|value| {
        if value.get() == stage {
            value.set(0);
            Err(format!(
                "injected schema 9 migration failure at stage {stage}"
            ))
        } else {
            Ok(())
        }
    })
}

#[cfg(not(test))]
fn maybe_fail_schema9_migration_for_testing(_stage: u8) -> Result<(), String> {
    Ok(())
}

fn ensure_identity_migration_capacity(
    connection: &Connection,
    source_count: i64,
) -> Result<(), String> {
    let path = connection
        .query_row(
            "SELECT file FROM pragma_database_list WHERE name = 'main'",
            [],
            |row| row.get::<_, String>(0),
        )
        .map(PathBuf::from)
        .map_err(|error| format!("无法定位精确 token 迁移数据库：{error}"))?;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    #[cfg(test)]
    let overridden_free = MIGRATION_AVAILABLE_BYTES_OVERRIDE.with(|value| value.replace(None));
    #[cfg(not(test))]
    let overridden_free = None;
    let free = if let Some(overridden_free) = overridden_free {
        overridden_free
    } else {
        available_space(parent)
            .map_err(|error| format!("无法检查精确 token 迁移空间 {}：{error}", parent.display()))?
    };
    let required = u64::try_from(source_count.max(0))
        .unwrap_or(u64::MAX)
        .saturating_mul(1_024)
        .saturating_add(16 * 1_024 * 1_024)
        .saturating_add(STAGING_MIN_FREE_RESERVE_BYTES);
    if free < required {
        return Err(format!(
            "精确 token schema 9→10 迁移空间不足；需要约 {} MiB、可用约 {} MiB，未开始迁移并保留旧库",
            required.div_ceil(1024 * 1024),
            free / (1024 * 1024)
        ));
    }
    Ok(())
}

fn repair_explicit_subagent_replay_boundary(connection: &Connection) -> Result<bool, String> {
    // Keep published rows readable while the normal per-file synchronization
    // path stages and atomically publishes a corrected replacement. This
    // migration only invalidates the physical checkpoint for files whose first
    // line proves an explicit subagent fork; it never deletes token events or
    // rescans the full JSONL corpus.
    let files_relation_exists = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table', 'view') AND name = 'files'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法检查精确 token 文件表：{error}"))?
        > 0;
    if !files_relation_exists {
        return Ok(true);
    }
    // Schema 9→10 changes only the statistics identity contract. A current
    // replay marker remains valid and must not trigger a JSONL pass merely
    // because the metadata table lost filesystem-object columns.
    let stored_revision = metadata_text(connection, "fork_replay_boundary_revision")?;
    if stored_revision.as_deref() == Some(FORK_REPLAY_BOUNDARY_REVISION)
    {
        return Ok(true);
    }

    let mut statement = connection
        .prepare(
            r#"
            SELECT DISTINCT path, (fork_replay_active = 1 AND is_explicit_subagent_fork = 0)
            FROM files
            WHERE deleted = 0
            "#,
        )
        .map_err(|error| format!("无法准备子 Agent replay 兼容迁移：{error}"))?;
    let candidates = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)))
        .map_err(|error| format!("无法读取子 Agent replay 兼容候选：{error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码子 Agent replay 兼容候选：{error}"))?;
    drop(statement);

    let mut explicit_paths = Vec::new();
    let mut unresolved_candidate = false;
    for (path, legacy_candidate) in candidates {
        let boundary = RolloutReader::open(Path::new(&path)).map_err(|e| e.to_string())
            .and_then(|mut f| super::session_parser::paginated_subagent_boundary(&mut f));
        match boundary {
            Ok(value) if stored_revision.as_deref() == Some(PAGINATED_V5_PARSER_REVISION) && value != Some(u64::MAX) => continue,
            Ok(Some(_)) => { explicit_paths.push(path); continue; }
            Err(_) => { unresolved_candidate = true; continue; }
            Ok(None) if stored_revision.as_deref() == Some(PAGINATED_V4_PARSER_REVISION) || stored_revision.as_deref() == Some(PAGINATED_V5_PARSER_REVISION) || !legacy_candidate => continue,
            Ok(None) => {}
        }
        match probe_explicit_subagent_session_file(Path::new(&path)) {
            ExplicitSubagentSessionFileProbe::Explicit => explicit_paths.push(path),
            ExplicitSubagentSessionFileProbe::NonExplicit => {}
            ExplicitSubagentSessionFileProbe::Unresolved => {
                // Do not make an unreadable or incomplete candidate look
                // migrated. A later startup must retry it without blocking
                // the dashboard from using the already-published rows.
                unresolved_candidate = true;
            }
        }
    }
    let transaction = connection
        .unchecked_transaction()
        .map_err(|error| format!("无法开始子 Agent replay 原位迁移：{error}"))?;
    for path in &explicit_paths {
        // Deliberately invalidate only this file's physical checkpoint. The
        // published generation remains readable until the corrected file is
        // atomically replaced by the normal synchronization path.
        transaction
            .execute(
                r#"
                UPDATE files
                SET is_explicit_subagent_fork = 1,
                    append_ready = 0,
                    resume_offset = NULL,
                    modified_ns = 'paginated-boundary-migration'
                WHERE path = ?1 AND deleted = 0
                "#,
                params![path],
            )
            .map_err(|error| format!("无法标记子 Agent replay 定向修复：{error}"))?;
    }

    if !explicit_paths.is_empty() {
        set_metadata(&transaction, PARSER_REPAIR_VERIFY_KEY, EXACT_SESSION_PARSER_REVISION)?;
    }
    if !unresolved_candidate {
        set_metadata(
            &transaction,
            "fork_replay_boundary_revision",
            FORK_REPLAY_BOUNDARY_REVISION,
        )?;
    }
    transaction
        .commit()
        .map_err(|error| format!("无法提交子 Agent replay 原位迁移：{error}"))?;
    Ok(!unresolved_candidate)
}

/// Accounting conversion follows the unchanged schema-11 candidate proof.
/// DDL, checkpoints, derived totals and revision commit in the original DB.
fn accounting_structural_receipt(
    connection: &Connection,
    validation: Option<&Schema11ValidatedStorage>,
) -> Result<Option<String>, String> {
    // This receipt exists only to finish a still-managed structural switch.
    // An ordinary schema-11 open has no candidate to compare with: hashing
    // millions of fingerprints here would not establish any new safety fact.
    let Some(validation) = validation else { return Ok(None); };
    let preparation = IndexPreparationTrace::new("accounting_structural_facts");
    let reusable = validation.facts.as_ref().filter(|facts| {
        connection.total_changes() == 0
            && schema11_receipt_metadata_matches(connection, &validation.receipt).unwrap_or(false)
            && schema11_lineage(connection).is_ok_and(|lineage| lineage == facts.lineage)
    });
    let receipt = if let Some(facts) = reusable {
        startup_trace::mark_performance("exact_prepare reuse=accounting_structural_facts");
        serde_json::to_string(facts).map_err(|e| e.to_string())?
    } else {
        serde_json::to_string(&schema11_migration_facts(connection, INDEX_SCHEMA_VERSION)?)
            .map_err(|e| e.to_string())?
    };
    preparation.finish();
    Ok(Some(receipt))
}

fn migrate_accounting(
    connection: &mut Connection,
    validation: Option<&Schema11ValidatedStorage>,
) -> Result<(), String> {
    let receipt=accounting_structural_receipt(connection,validation)?;
    apply_accounting_migration(connection,receipt)
}

fn apply_accounting_migration(connection: &mut Connection,receipt: Option<String>) -> Result<(),String> {
    if let Some(revision) = metadata_text(connection, "accounting_revision")? {
        if revision != ACCOUNTING_REVISION {
            return Err(format!("Unknown accounting revision {revision}; preserved index"));
        }
        if metadata_i64(connection, "schema_version")?.unwrap_or(0) < ACCOUNTING_SCHEMA_VERSION {
            if !column_exists_checked(connection, "event_rows", "accounting_kind")? {
                return Err("Accounting marker does not match event structure".into());
            }
            let tx = connection.transaction().map_err(|e| e.to_string())?;
            if let Some(receipt) = receipt {
                set_metadata(&tx, "accounting_structural_receipt", &receipt)?;
            }
            set_metadata(&tx, "schema_version", &ACCOUNTING_SCHEMA_VERSION.to_string())?;
            tx.commit().map_err(|e| e.to_string())?;
        }
        return Ok(());
    }
    let mut preparation = IndexPreparationTrace::new("accounting_schema");
    let tx = connection.transaction().map_err(|e| e.to_string())?;
    for (table, column, definition) in [
        ("sources", "accounting_state", "TEXT"),
        ("pending_sources", "accounting_state", "TEXT"),
        ("event_rows", "accounting_kind", "INTEGER NOT NULL DEFAULT 0"),
        ("event_rows", "reported_total_tokens", "INTEGER"),
        ("event_rows", "token_source_offset", "INTEGER"),
        ("event_rows", "legacy_tokens", "INTEGER"),
        ("pending_event_rows", "accounting_kind", "INTEGER NOT NULL DEFAULT 0"),
        ("pending_event_rows", "reported_total_tokens", "INTEGER"),
        ("pending_event_rows", "token_source_offset", "INTEGER"),
        ("pending_event_rows", "legacy_tokens", "INTEGER"),
    ] {
        if !column_exists_checked(&tx, table, column)? {
            tx.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {definition};"))
                .map_err(|e| e.to_string())?;
        }
    }
    tx.execute_batch("DROP VIEW files; DROP VIEW events; DROP VIEW published_files; DROP VIEW published_events;")
        .map_err(|e| e.to_string())?;
    initialize_index_schema(&tx)?;
    tx.execute_batch("CREATE INDEX IF NOT EXISTS event_rows_unresolved_accounting ON event_rows(accounting_kind) WHERE accounting_kind <> 0;").map_err(|e|e.to_string())?;
    preparation.advance("accounting_normalize_rows");
    let mut legacy_count = 0i64;
    for table in ["event_rows", "pending_event_rows"] {
        legacy_count += tx.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get::<_, i64>(0)).map_err(|e| e.to_string())?;
        tx.execute_batch(&format!("UPDATE {table} SET legacy_tokens=tokens,
            accounting_kind=CASE WHEN input_tokens>=0 AND output_tokens>=0
            AND cached_input_tokens BETWEEN 0 AND input_tokens
            AND COALESCE(reasoning_output_tokens,0) BETWEEN 0 AND output_tokens
            AND input_tokens<=9223372036854775807-output_tokens
            AND (input_tokens>0 OR output_tokens>0) THEN 0 ELSE 3 END;
            UPDATE {table} SET tokens=CASE WHEN accounting_kind=0 THEN input_tokens+output_tokens ELSE 0 END;"))
            .map_err(|e| e.to_string())?;
    }
    // Keep historical enrichment receipts on their original parser revision.
    // The bumped event-enrichment contract must reparse those sources before
    // they can be marked complete for compaction accounting.
    preparation.advance("accounting_aggregates");
    rebuild_published_dashboard_aggregates(&tx)?;
    let pending = {
        let mut stmt = tx.prepare("SELECT p.target_generation,s.path FROM pending_sources p JOIN sources s USING(source_id) WHERE p.deleted=0").map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?))).map_err(|e| e.to_string())?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| e.to_string())?
    };
    for (generation,path) in pending { refresh_dashboard_file_aggregates(&tx,generation,&path)?; }
    if let Some(building) = metadata_i64(&tx, "building_generation")? {
        refresh_dashboard_turn_candidates_for_changed_generations(&tx, building, metadata_i64(&tx,"published_generation")?.unwrap_or(0))?;
    }
    // The projections just rebuilt in this transaction already implement the
    // current pricing/accounting contract. Publish their version now so the
    // first full read cannot copy/rebuild the same derived tables again.
    let published = metadata_i64(&tx, "published_generation")?.unwrap_or(0);
    if !dashboard_5m_projection_matches_published_files(&tx, published)? {
        return Err("会计迁移聚合对账失败；已回滚并保留原索引".into());
    }
    set_metadata(&tx, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY, &DASHBOARD_AGGREGATE_SCHEMA_VERSION.to_string())?;
    set_metadata(&tx, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY, DASHBOARD_AGGREGATE_PRICING_REVISION)?;
    set_metadata(&tx, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY, &published.to_string())?;
    preparation.advance("accounting_attribution_ledger");
    // Preserve orphan lineage contributions, whose source bytes may no longer
    // exist, and replace only lineages supported by currently published rows.
    tx.execute_batch("UPDATE attribution_source_buckets SET tokens=input_tokens+output_tokens;")
        .map_err(|e| e.to_string())?;
    let epoch = metadata_text(&tx, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?.unwrap_or_default();
    // Replace every currently published lineage, including ones whose only
    // legacy events became diagnostics, so stale calls cannot survive.
    let published_sessions = {
        let mut stmt = tx.prepare("SELECT DISTINCT session_id FROM published_files").map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).map_err(|e| e.to_string())?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| e.to_string())?
    };
    for session in published_sessions {
        tx.execute("DELETE FROM attribution_source_buckets WHERE provenance_epoch=?1 AND source_id=?2",
            params![epoch, opaque_attribution_source_id(&session)]).map_err(|e| e.to_string())?;
    }
    let source_totals = {
        let mut stmt = tx.prepare("SELECT session_id,timestamp-(timestamp%300),SUM(tokens),COUNT(*),SUM(input_tokens),SUM(cached_input_tokens),SUM(output_tokens) FROM published_events WHERE tokens>0 GROUP BY 1,2").map_err(|e| e.to_string())?;
        let rows=stmt.query_map([], |r| Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?,r.get::<_,i64>(2)?,r.get::<_,i64>(3)?,r.get::<_,i64>(4)?,r.get::<_,i64>(5)?,r.get::<_,i64>(6)?))).map_err(|e| e.to_string())?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| e.to_string())?
    };
    for (session,bucket,tokens,calls,input,cached,output) in source_totals {
        tx.execute("INSERT INTO attribution_source_buckets(provenance_epoch,source_id,bucket_start,tokens,calls,input_tokens,cached_input_tokens,output_tokens) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(provenance_epoch,source_id,bucket_start) DO UPDATE SET tokens=excluded.tokens,calls=excluded.calls,input_tokens=excluded.input_tokens,cached_input_tokens=excluded.cached_input_tokens,output_tokens=excluded.output_tokens",
            params![epoch,opaque_attribution_source_id(&session),bucket,tokens,calls,input,cached,output]).map_err(|e|e.to_string())?;
    }
    set_metadata(&tx, ATTRIBUTION_LEDGER_INTEGRITY_KEY, &attribution_ledger_integrity(&tx,&epoch)?)?;
    if let Some(receipt) = receipt {
        set_metadata(&tx,"accounting_structural_receipt",&receipt)?;
    }
    set_metadata(&tx,"accounting_coverage",if legacy_count>0 {"legacy-source-audit-required"} else {"complete"})?;
    set_metadata(&tx,"accounting_revision",ACCOUNTING_REVISION)?;
    set_metadata(&tx,"schema_version",&ACCOUNTING_SCHEMA_VERSION.to_string())?;
    let revision=metadata_i64(&tx,"revision")?.unwrap_or(0).saturating_add(1);
    set_metadata(&tx,"revision",&revision.to_string())?;
    set_metadata(&tx,DASHBOARD_REVISION_KEY,&revision.to_string())?;
    preparation.advance("accounting_commit");
    tx.commit().map_err(|e|e.to_string())?;
    preparation.finish();
    Ok(())
}

#[cfg(windows)]
fn reject_session_catalog_reparse_point(
    path: &Path,
    metadata: &fs::Metadata,
) -> Result<(), String> {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;

    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!(
            "会话目录增量索引拒绝 Windows 重解析点：{}",
            path.display()
        ));
    }
    Ok(())
}

#[cfg(not(windows))]
fn reject_session_catalog_reparse_point(
    path: &Path,
    metadata: &fs::Metadata,
) -> Result<(), String> {
    if metadata.file_type().is_symlink() {
        return Err(format!("会话目录增量索引拒绝符号链接：{}", path.display()));
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn fail_next_session_catalog_publish_for_testing() {
    session_catalog::fail_next_session_catalog_publish_for_testing();
}

// SQLite backup copies every table (including pending, retained evidence and
// canonical bindings) from a WAL-consistent snapshot. Keep the upgraded legacy
// DB as recovery material; schema 13 makes earlier releases refuse to write it.
#[cfg(test)]
pub(super) fn relocate_legacy_index(home: &Path,legacy: &Path,destination: &Path) -> Result<(),String> {
    if legacy==destination || existing_regular_index(destination)? ||
        (!existing_regular_index(legacy)? && !schema11_manifest_path(legacy).exists()) { return Ok(()); }
    let _legacy=ExactUsageIndex::open_at(home,legacy.to_path_buf())?;
    let _legacy_file_lock=CrossProcessFileLock::acquire_wait_with_hook(
        &sqlite_sidecar_path(legacy,".operation.lock"),"旧历史账本迁移",StdDuration::from_secs(30),||{})?;
    let parent=destination.parent().ok_or("历史账本目标目录无效")?;
    fs::create_dir_all(parent).map_err(|e|e.to_string())?;
    let _destination_lock=CrossProcessFileLock::acquire_wait_with_hook(
        &sqlite_sidecar_path(destination,".operation.lock"),"历史账本迁移",StdDuration::from_secs(30),||{})?;
    if existing_regular_index(destination)? { return Ok(()); }
    let required=file_signature(legacy)?.size
        .saturating_add(optional_index_sidecar_signature(&sqlite_sidecar_path(legacy,"-wal"))?.map(|s|s.size).unwrap_or(0))
        .saturating_add(SCHEMA11_MIGRATION_SPACE_RESERVE_BYTES);
    if available_space(parent).map_err(|e|e.to_string())?<required { return Err("历史账本迁移空间不足；旧库已保留".into()); }
    let candidate=sqlite_sidecar_path(destination,".ledger-copy");
    schema11_copy_candidate(legacy,&candidate)?;
    {
        let copy=open_read_only_index(&candidate,StdDuration::from_secs(5)).map_err(|e|e.to_string())?;
        let checked:String=copy.query_row("PRAGMA quick_check",[],|r|r.get(0)).map_err(|e|e.to_string())?;
        if checked!="ok" { return Err("历史账本副本校验失败；旧库已保留".into()); }
        retention::validate(&copy)?;
        ledger::validate(&copy)?;
    }
    {
        let copy = Connection::open(&candidate).map_err(|e| e.to_string())?;
        let manifest_path = schema11_manifest_path(legacy);
        let manifest = if manifest_path.exists() { Some(schema11_load_manifest(&manifest_path)?) } else { None };
        set_metadata(&copy, MIGRATION_RETENTION_KEY, &migration_retention_receipt(legacy, manifest.as_ref()).to_string())?;
    }
    schema11_sync_file(&candidate)?;
    fs::rename(&candidate,destination).map_err(|e|e.to_string())?;
    // Share the platform-aware directory synchronization used by candidate
    // publication, including the Windows directory handle flags.
    schema11_sync_parent(destination)?;
    Ok(())
}

pub(crate) fn bootstrap_legacy_indexes() -> Result<(), String> {
    #[cfg(test)]
    return Ok(());

    #[cfg(not(test))]
    {
        let current_root = app_paths::usage_history_dir()
            .ok_or_else(|| "无法定位精确 token 索引目录".to_string())?;
        let cache_root = app_paths::tauri_usage_cache_dir()
            .ok_or_else(|| "无法定位旧精确 token 索引目录".to_string())?
            .join("exact-token-index");
        exact_legacy_recovery::bootstrap_at(&current_root, &cache_root, |target, sources, manifests| {
            // Canonicalization on Windows adds the physical path prefix. Do
            // this before deriving the store ID, not after the first import.
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(|e| format!("无法准备旧索引导入目录：{e}"))?;
            }
            let _ = crate::core::business_store_route::open_exact_store_during_bootstrap(target, &sources)?;
            if !manifests.is_empty() {
                crate::core::business_store_route::preserve_legacy_exact_migration(target, manifests)?;
            }
            Ok(())
        })
    }
}

fn collect_exact_legacy_inputs(
    source_root: &Path,
    target_root: &Path,
    inputs: &mut Vec<(PathBuf, PathBuf)>,
    migration_manifests: &mut Vec<PathBuf>,
) -> Result<(), String> {
    fn walk(
        directory: &Path,
        source_root: &Path,
        target_root: &Path,
        inputs: &mut Vec<(PathBuf, PathBuf)>,
        migration_manifests: &mut Vec<PathBuf>,
    ) -> Result<(), String> {
        let entries = match fs::read_dir(directory) {
            Ok(entries) => entries,
            Err(error) => return Err(format!("无法枚举旧精确 token 索引目录 {}：{error}", directory.display())),
        };
        for entry in entries {
            let entry = entry.map_err(|error| error.to_string())?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path).map_err(|error| error.to_string())?;
            if metadata.file_type().is_symlink() {
                if path.file_name().and_then(|name| name.to_str()).is_some_and(|name| {
                    name.ends_with(".sqlite3") || name.ends_with(".schema11-migration.json")
                }) {
                    return Err(format!("旧精确 token 输入是符号链接；拒绝切换：{}", path.display()));
                }
                continue;
            }
            reject_session_catalog_reparse_point(&path, &metadata)?;
            if metadata.is_dir() {
                walk(&path, source_root, target_root, inputs, migration_manifests)?;
                continue;
            }
            if !metadata.is_file() { continue; }
            let name = path.file_name().and_then(|value| value.to_str()).unwrap_or_default();
            if name.ends_with(".schema11-migration.json") {
                migration_manifests.push(path);
                continue;
            }
            if path.extension().and_then(|value| value.to_str()).is_some_and(|ext| ext.eq_ignore_ascii_case("sqlite3")) {
                let relative = path.strip_prefix(source_root).map_err(|error| error.to_string())?;
                inputs.push((target_root.join(relative), path));
            }
        }
        Ok(())
    }
    match fs::metadata(source_root) {
        Ok(metadata) if metadata.is_dir() => {
            // A configured root may itself be a legitimate directory symlink.
            // Descendant symlink policy remains enforced by walk above.
            walk(source_root, source_root, target_root, inputs, migration_manifests)?;
        }
        Ok(_) => return Err(format!("旧精确 token 索引根不是目录：{}", source_root.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A dangling configured-root symlink is an unreadable source, not
            // a genuinely absent directory that can be initialized as empty.
            match fs::symlink_metadata(source_root) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(format!("无法检查旧精确 token 索引根 {}：{error}",source_root.display())),
                Ok(_) => return Err(format!("旧精确 token 索引根无法解析：{}",source_root.display())),
            }
        }
        Err(error) => return Err(format!("无法检查旧精确 token 索引根 {}：{error}",source_root.display())),
    }
    Ok(())
}

#[path = "exact_legacy_recovery.rs"]
mod exact_legacy_recovery;

#[cfg(test)]
#[path = "exact_legacy_discovery_tests.rs"]
mod exact_legacy_discovery_tests;

pub(super) fn database_path(codex_home: &Path) -> Result<PathBuf, String> {
    #[cfg(test)]
    {
        if let Some(path) = std::env::var_os("CODEX_TOKEN_BAR_TEST_EXACT_INDEX_PATH") {
            let path = PathBuf::from(path);
            if !path.is_absolute() {
                return Err(
                    "CODEX_TOKEN_BAR_TEST_EXACT_INDEX_PATH must be an absolute path".to_string(),
                );
            }
            return Ok(path);
        }
        let canonical_home =
            fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf());
        return Ok(canonical_home
            .join(".codex-token-bar-test-cache")
            .join("exact-token-index.sqlite3"));
    }

    #[cfg(not(test))]
    let root = app_paths::usage_history_dir()
        .ok_or_else(|| "无法定位持久用量数据目录".to_string())?;
    #[cfg(not(test))]
    Ok(root
        .join(format!("{}.sqlite3", stable_path_fingerprint(codex_home))))
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
fn run_after_dashboard_snapshot_hook_for_testing() {
    let hook = AFTER_DASHBOARD_SNAPSHOT_HOOK.with(|slot| slot.borrow_mut().take());
    if let Some(hook) = hook {
        hook();
    }
}

#[cfg(not(test))]
fn run_after_dashboard_snapshot_hook_for_testing() {}

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

#[cfg(test)]
fn run_before_staging_open_hook_for_testing(path: &Path) {
    let slot = BEFORE_STAGING_OPEN_HOOK.get_or_init(|| Mutex::new(None));
    let hook = {
        let mut guard = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if guard.as_ref().is_some_and(|pending| pending.target == path) {
            guard.take()
        } else {
            None
        }
    };
    if let Some(hook) = hook {
        (hook.action)(path);
    }
}

#[cfg(not(test))]
fn run_before_staging_open_hook_for_testing(_path: &Path) {}

fn fresh_revision_seed() -> i64 {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    i64::try_from(nanos.min(i64::MAX as u128)).unwrap_or(i64::MAX - 1)
}

fn migration_markers_complete(
    connection: &Connection,
    replay_migration_complete: bool,
) -> Result<bool, String> {
    Ok(metadata_i64(connection,"canonical_projection_pending")?.unwrap_or(0)==0
        && replay_migration_complete
        && metadata_text(connection, "fork_replay_boundary_revision")?.as_deref()
            == Some(FORK_REPLAY_BOUNDARY_REVISION)
        && metadata_text(connection, ORPHAN_REPAIR_REVISION_KEY)?.as_deref()
            == Some(ORPHAN_REPAIR_REVISION)
        && metadata_i64(connection, "session_catalog_schema_version")?
            == Some(SESSION_CATALOG_SCHEMA_VERSION)
        && metadata_text(connection, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
            .is_some_and(|value| !value.trim().is_empty())
        && metadata_text(connection, ATTRIBUTION_LEDGER_EPOCH_KEY)?
            .is_some_and(|value| !value.trim().is_empty())
        && metadata_text(connection, ATTRIBUTION_LEDGER_INTEGRITY_KEY)?
            .is_some_and(|value| !value.trim().is_empty())
        && metadata_text(connection, EVENT_ENRICHMENT_REVISION_KEY)?.as_deref()
            == Some(EVENT_ENRICHMENT_REVISION))
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

fn excerpt_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "thread_excerpt".into(),
        message,
    }
}

#[cfg(test)]
mod candidate_durability_tests {
    use super::*;

    #[test]
    fn candidate_capacity_includes_copy_and_both_vacuum_allocations() {
        let root=std::env::temp_dir().join(format!("candidate-capacity-{}",uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let path=root.join("index.sqlite");
        let bytes=1024 * 1024 * 1024;
        // Sparse metadata fixture: no gigabyte payload is allocated or read.
        fs::File::create(&path).unwrap().set_len(bytes).unwrap();
        MIGRATION_AVAILABLE_BYTES_OVERRIDE.with(|v|v.set(Some(2 * bytes + SCHEMA11_MIGRATION_SPACE_RESERVE_BYTES)));
        assert!(schema11_migration_capacity(&path).unwrap_err().contains("空间不足"));
        MIGRATION_AVAILABLE_BYTES_OVERRIDE.with(|v|v.set(Some(3 * bytes + SCHEMA11_MIGRATION_SPACE_RESERVE_BYTES)));
        schema11_migration_capacity(&path).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().len(),bytes);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn candidate_sync_preserves_bytes_and_flushes_parent() {
        let root=std::env::temp_dir().join(format!("candidate-durability-{}",uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let candidate=root.join("candidate.sqlite");
        let payload=b"candidate contents must survive flush unchanged";
        fs::write(&candidate,payload).unwrap();
        schema11_sync_file(&candidate).unwrap();
        schema11_sync_parent(&candidate).unwrap();
        assert_eq!(fs::read(&candidate).unwrap(),payload);
        let missing=root.join("missing.sqlite");
        assert!(schema11_sync_file(&missing).is_err());
        assert!(!missing.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
