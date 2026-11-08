use migration::{
    MigrationAssessment, SCHEMA11_CANDIDATE_MANIFEST_VERSION, SCHEMA11_MIGRATION_SUFFIX,
    SCHEMA11_MIGRATION_SPACE_RESERVE_BYTES, Schema11CandidatePhase, Schema11FileStamp,
    Schema11SourceReceipt, Schema11ValidatedStorage, Schema11CandidateManifest,
    assess_index_migration, schema11_candidate_path, schema11_rollback_path,
    schema11_manifest_path, active_schema11_paths, active_schema11_paths_on,
    schema11_paths_for_namespace, schema11_source_receipt_from_connection,
    schema11_receipt_matches_current, schema11_receipt_metadata_matches,
    schema11_store_manifest, schema11_load_manifest, schema11_sync_file,
    schema11_sync_parent, schema11_migration_capacity, schema11_copy_candidate,
    prepare_schema11_candidate_if_needed, MIGRATION_RETENTION_KEY,
    record_successful_migration_retention, migrate_github_base_index_schema,
    repair_explicit_subagent_replay_boundary, accounting_structural_receipt,
    apply_accounting_migration, collect_exact_legacy_inputs, migration_markers_complete,
};
#[cfg(not(test))]
use migration::prepare_exact_store_for_home;
#[cfg(test)]
pub(super) use migration::{relocate_legacy_index, cleanup_schema11_migration_for_testing};
pub(crate) use migration::bootstrap_legacy_indexes;
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
        crate::core::diagnostics::record(crate::core::diagnostics::Area::Index,
            if status=="ok"{crate::core::diagnostics::Phase::Completed}else{crate::core::diagnostics::Phase::Failed},
            &[("elapsed_ms",self.started.elapsed().as_millis().min(i64::MAX as u128) as i64)]);
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ExactIndexUpgradeRequired {
    pub(crate) component: String,
    pub(crate) stored: String,
    pub(crate) supported: String,
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
    crate::core::diagnostics::record(crate::core::diagnostics::Area::Storage,crate::core::diagnostics::Phase::Completed,
        &[("published_generation",generation as i64),("schema_version",INDEX_SCHEMA_VERSION)]);
    Ok(u64::try_from(revision).unwrap_or(0))
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
