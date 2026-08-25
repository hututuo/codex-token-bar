use super::session_files::session_id_from_file;
use super::session_parser::{
    probe_explicit_subagent_session_file, read_event_excerpts, stream_session_file_exact,
    stream_session_file_exact_from, ExactChunkHash, ExactEventSourceOffsets, ExactSessionEventSink,
    ExactSessionParserState, ExactTokenEvent, ExplicitSubagentSessionFileProbe, SourceByteRange,
    UsageSnapshotFingerprint, EXACT_INDEX_CHUNK_SIZE, USAGE_SNAPSHOT_FINGERPRINT_BYTES,
};
use super::{
    attribution_watch_root_physical_identity, IndexedSessionCatalogEntry,
    IndexedSessionCatalogSnapshot, IndexedSessionMetadata, SummaryFileContribution,
    TokenUsageSummary,
};
#[cfg(not(test))]
use crate::core::app_paths;
use crate::core::localtime;
use crate::core::time_series_timeline::{
    aligned_bin_starts, LONG_RECENT_INTERVAL_SECONDS, LONG_RECENT_POINT_COUNT,
};
use crate::core::{
    app_operation_lock::AppOperationGuard, atomic_file, cross_process_lock::CrossProcessFileLock,
    sqlite, startup_trace,
};
use crate::models::{
    ActivityDay, CacheHitRankingItem, DashboardStats, LocalDataWarning, ModelTokenBreakdown,
    RecentUsagePoint, RecentUsageSourceContribution, SessionCacheUsage, TokenCacheBreakdown,
    TokenCacheUsage, TurnCacheUsage,
};
use fs2::available_space;
use rusqlite::{
    params, Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
#[cfg(test)]
use std::sync::Barrier;
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::thread;
use std::time::{Duration as StdDuration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};
use uuid::Uuid;

// GitHub v0.8.3 ships schema v6 with the current 11-field fingerprint. Every
// later known schema must migrate that index in place; only pre-v6 layouts may
// be discarded because their incompatible fingerprint blobs can re-count data.
const INDEX_SCHEMA_VERSION: i64 = 9;
const GITHUB_BASE_SCHEMA_VERSION: i64 = 6;
const INDEX_INTEGRITY_RECEIPT_VERSION: u32 = 1;
const INDEX_INTEGRITY_RECEIPT_SUFFIX: &str = ".integrity-receipt.json";
// Bump this whenever exact-session parsing changes event or checkpoint
// semantics. The fork-boundary name remains for the main-index migration;
// private staged databases bind the broader parser revision below.
const EXACT_SESSION_PARSER_REVISION: &str = "explicit-subagent-delayed-context-v3";
const FORK_REPLAY_BOUNDARY_REVISION: &str = EXACT_SESSION_PARSER_REVISION;
pub(super) const STAGED_FULL_REBUILD_PARSER_REVISION: &str = EXACT_SESSION_PARSER_REVISION;
// This marker is independent from the parser/schema revisions because it
// records completion of a one-time logical repair for legacy databases that
// were written with foreign-key enforcement disabled. Keep it separate so a
// normal index open can skip the expensive orphan scans after the repair has
// been verified.
pub(super) const ORPHAN_REPAIR_REVISION_KEY: &str = "orphan_repair_revision";
pub(super) const ORPHAN_REPAIR_REVISION: &str = "events-fingerprints-chunks-v1";
const EVENT_ENRICHMENT_REVISION_KEY: &str = "event_enrichment_revision";
const EVENT_ENRICHMENT_REVISION: &str = "model-reasoning-v1";
const SESSION_CATALOG_SCHEMA_VERSION: i64 = 1;
const ATTRIBUTION_PROVENANCE_EPOCH_KEY: &str = "attribution_provenance_epoch";
const ATTRIBUTION_LEDGER_EPOCH_KEY: &str = "attribution_ledger_epoch";
const ATTRIBUTION_LEDGER_INTEGRITY_KEY: &str = "attribution_ledger_integrity_v1";
const ATTRIBUTION_UNSAFE_EPOCH_KEY: &str = "attribution_unsafe_epoch";
const ATTRIBUTION_UNSAFE_GENERATION_KEY: &str = "attribution_unsafe_generation";
const ATTRIBUTION_UNSAFE_ID_KEY: &str = "attribution_unsafe_id";
const ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY: &str = "attribution_current_scan_unsafe";
const ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY: &str = "attribution_current_scan_incomplete";
const BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY: &str = "building_attribution_provenance_rotate";
// `revision` covers every durable index mutation, including refreshed thread
// titles from state_5.sqlite. Dashboard numeric aggregates do not depend on
// those titles, so keep a separate lineage that only advances when event or
// attribution data changes. This prevents metadata churn from invalidating a
// multi-hundred-thousand-event dashboard cache.
const DASHBOARD_REVISION_KEY: &str = "dashboard_revision";
const BUILDING_DASHBOARD_CHANGED_KEY: &str = "building_dashboard_changed";
// Dashboard aggregates are disposable, derived data. Keep their version and
// publication watermarks independent from the exact-event schema/parser so an
// upgrade can rebuild them from SQLite without reopening JSONL bodies.
const DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY: &str = "dashboard_aggregate_schema_version";
const DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY: &str = "dashboard_aggregate_exact_generation";
const DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY: &str =
    "dashboard_aggregate_published_generation";
const DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY: &str = "dashboard_aggregate_settled_through";
const DASHBOARD_AGGREGATE_PRICING_REVISION_KEY: &str = "dashboard_aggregate_pricing_revision";
// Turn candidates are grouped by the originating user message. Bump this
// disposable projection version whenever that grouping contract changes so an
// older event-level ranking cannot survive an upgrade.
const DASHBOARD_AGGREGATE_SCHEMA_VERSION: i64 = 5;
const DASHBOARD_AGGREGATE_PRICING_REVISION: &str = "raw-token-v1";

fn is_known_dashboard_pricing_revision(value: &str) -> bool {
    matches!(value, "raw-token-v0" | DASHBOARD_AGGREGATE_PRICING_REVISION)
}
const FIVE_MINUTE_INTERVAL_SECONDS: i64 = 5 * 60;
const AGGREGATE_BOUNDARY_GRACE_SECONDS: i64 = 15;
const HOURLY_INTERVAL_SECONDS: i64 = 60 * 60;
const SEVEN_DAY_POINT_COUNT: i64 = 30 * 24;
const SIX_HOUR_INTERVAL_SECONDS: i64 = 6 * 60 * 60;
const THIRTY_DAY_POINT_COUNT: i64 = 30 * 4;
const CACHE_USAGE_MIN_INPUT_TOKENS: i64 = 1_000;
const CACHE_USAGE_CANDIDATE_LIMIT: i64 = 40;
const PARALLEL_STAGING_MIN_BYTES: u64 = EXACT_INDEX_CHUNK_SIZE;
const PARALLEL_HEAVY_FILE_BYTES: u64 = 512 * 1024 * 1024;
const STAGING_MAX_WORKERS: usize = 4;
const STAGING_MAX_READY_ARTIFACTS: usize = 8;
const STAGING_MAX_READY_BYTES: u64 = 512 * 1024 * 1024;
const STAGING_MIN_FREE_RESERVE_BYTES: u64 = 64 * 1024 * 1024;
const STAGING_MANIFEST_INTEGRITY: &str = "sqlite-quick-check-v1";
const MIGRATION_STAGE_TOTAL: u64 = 6;

pub(super) struct ExactUsageIndex {
    connection: ManagedIndexConnection,
    // Keep the process-local Home lease alive for the complete index
    // operation, including migration, scan, and session-catalog publication.
    // The sidecar file lock below remains the cross-process boundary.
    _operation_lock: AppOperationGuard,
    /// True while one or more durable migration markers still need the
    /// normal scan/final publication to complete.  The open phase may repair
    /// DDL and orphan rows, but the attribution ledger is only authoritative
    /// after `finalize_generation` has committed it.
    migration_pending: bool,
}

/// Selects which derived work the in-process exact owner is allowed to do.
/// Both modes use the same durable generation/checkpoint scan; Summary only
/// publishes exact events and lets a later Full owner consume the disposable
/// dashboard work from SQLite.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ExactSyncMode {
    Summary,
    Full,
}

impl ExactSyncMode {
    fn builds_dashboard_derived_data(self) -> bool {
        matches!(self, Self::Full)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct AttributionSafetyState {
    pub(super) provenance_epoch: String,
    pub(super) generation: u64,
    pub(super) unsafe_since_generation: Option<u64>,
    pub(super) unsafe_id: Option<String>,
    pub(super) current_scan_unsafe_cause_detected: bool,
    pub(super) current_scan_incomplete: bool,
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
                    "event enrichment" => "历史字段补全",
                    "session catalog schema" => "会话目录 schema",
                    "aggregate pricing" => "aggregate 计价契约",
                    other => other,
                };
                let version_relation = if *component == "event enrichment" {
                    "高于或不同于当前支持版本"
                } else {
                    "高于当前支持版本"
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
    if !existing_regular_index(&path)? {
        return Ok(None);
    }
    let read_only = sqlite::open_read_only(&path, StdDuration::from_secs(1)).map_err(|error| {
        format!(
            "无法只读探测精确 token 索引兼容性 {}：{error}",
            path.display()
        )
    })?;
    let assessment = assess_index_migration(&read_only, true)?;
    if let Some(upgrade) = assessment.upgrade_required() {
        return Ok(Some(upgrade));
    }
    if let Some(error) = assessment.blocking_error() {
        return Err(error);
    }
    Ok(None)
}

/// User-confirmed escape hatch for opening a newer exact index with the
/// current binary. Only Tauri-owned derived storage is removed. Raw JSONL,
/// Codex state databases, settings, quota history, and radar data are outside
/// these paths and are never touched here.
pub(super) fn rebuild_derived_storage_for_current_version(codex_home: &Path) -> Result<(), String> {
    let _operation = AppOperationGuard::acquire(codex_home)?;
    let path = database_path(codex_home)?;
    let Some(_) = index_upgrade_required(codex_home)? else {
        return Err("当前精确 token 索引不需要高版本兼容重建，已拒绝删除".into());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "无法创建精确 token 重建锁目录 {}：{error}",
                parent.display()
            )
        })?;
    }
    let operation_lock_path = sqlite_sidecar_path(&path, ".operation.lock");
    let _cross_process = CrossProcessFileLock::acquire_wait(
        &operation_lock_path,
        "精确 token 索引重建",
        StdDuration::from_secs(30),
    )?;
    remove_index_storage(&path)?;
    remove_staging_directory(&path)?;
    remove_regular_file_if_present(&integrity_receipt_path(&path), "精确 token 完整性收据")?;
    Ok(())
}

/// Read-only identity used to validate a persisted numeric startup envelope.
/// This deliberately does not construct `ExactUsageIndex`: startup must not
/// run schema migration, orphan repair, receipt publication, or quick_check
/// before it can show a trusted last-good snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct StartupIndexIdentity {
    pub(super) revision: u64,
    pub(super) dashboard_revision: u64,
    pub(super) published_generation: u64,
    pub(super) attribution_safety: AttributionSafetyState,
}

/// Durable derived-aggregate lineage. These values already live in the exact
/// index metadata; this DTO only lets cache and UI code compare the existing
/// facts without introducing a second pending/owner state machine.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct DashboardAggregateIdentity {
    pub(super) schema_version: Option<String>,
    pub(super) pricing_revision: Option<String>,
    pub(super) exact_generation: Option<u64>,
    pub(super) published_generation: Option<u64>,
    #[serde(default)]
    pub(super) settled_through: Option<i64>,
}

#[derive(Default)]
struct ExactScanCompleteness {
    incomplete_source_scan: bool,
    block_generation_publish: bool,
}

#[derive(Default)]
struct ExactScanDiagnostics {
    candidate_count: u64,
    scanned_files: u64,
    append_scan_bytes: u64,
    full_body_bytes: u64,
    pending_tail_bytes: u64,
    full_rebuild_files: u64,
    source_drift: bool,
    published_watermark: u64,
}

impl ExactScanCompleteness {
    fn mark_incomplete(&mut self) {
        self.incomplete_source_scan = true;
    }

    fn block_publish(&mut self) {
        self.incomplete_source_scan = true;
        self.block_generation_publish = true;
    }
}

struct ManagedIndexConnection {
    connection: Option<Connection>,
    path: PathBuf,
    receipt_eligible: bool,
}

#[cfg(test)]
fn run_integrity_gate_enter_hook_for_testing(path: &Path) {
    let Some(slot) = INTEGRITY_GATE_ENTER_HOOK.get() else {
        return;
    };
    let hook = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(hook) = hook.as_ref() {
        hook(path);
    }
}

#[cfg(not(test))]
fn run_integrity_gate_enter_hook_for_testing(_path: &Path) {}

#[cfg(test)]
fn run_integrity_gate_release_hook_for_testing(path: &Path) {
    let Some(slot) = INTEGRITY_GATE_RELEASE_HOOK.get() else {
        return;
    };
    let hook = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(hook) = hook.as_ref() {
        hook(path);
    }
}

#[cfg(not(test))]
fn run_integrity_gate_release_hook_for_testing(_path: &Path) {}

#[cfg(test)]
fn run_before_finish_index_connection_hook_for_testing(path: &Path) {
    let Some(slot) = BEFORE_FINISH_INDEX_CONNECTION_HOOK.get() else {
        return;
    };
    let hook = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(hook) = hook.as_ref() {
        hook(path);
    }
}

#[cfg(not(test))]
fn run_before_finish_index_connection_hook_for_testing(_path: &Path) {}

impl ManagedIndexConnection {
    fn from_registered(connection: Connection, path: PathBuf) -> Self {
        Self {
            connection: Some(connection),
            path,
            receipt_eligible: false,
        }
    }

    fn mark_receipt_eligible(&mut self) {
        self.receipt_eligible = true;
    }

    fn mark_receipt_dirty(&mut self) {
        self.receipt_eligible = false;
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
        let receipt = if self.receipt_eligible {
            self.connection
                .as_ref()
                .and_then(|connection| receipt_metadata(connection, &self.path).ok())
        } else {
            None
        };
        drop(self.connection.take());

        // Receipt I/O and the post-close storage signature must stay outside
        // INDEX_INTEGRITY_STATES. The per-path gate serializes concurrent
        // close-time receipts without coupling different index paths.
        let gate = index_integrity_gate(&self.path);
        let _gate_guard = gate.enter(&self.path);
        let signature_after_close = index_storage_signature(&self.path).ok();
        if let (Some(receipt), Some(signature)) = (receipt, signature_after_close) {
            write_integrity_receipt_best_effort(&self.path, receipt, signature);
        }
        run_before_finish_index_connection_hook_for_testing(&self.path);
        let states = index_integrity_states();
        let mut states = states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        finish_index_connection(&mut states, &self.path);
        drop(states);
        drop(_gate_guard);
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
    pub(super) settled_through: i64,
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

#[derive(Clone, Debug)]
struct StagedThreadMetadata {
    signature: Option<(String, String)>,
    rows: Vec<(String, String, Option<i64>)>,
}

enum ThreadMetadataStage {
    /// The state database signature still matches the published metadata.
    Unchanged,
    /// The complete replacement was read successfully and is safe to apply.
    Updated(StagedThreadMetadata),
    /// Reading the replacement failed. Keep the published rows and signature.
    Failed,
}

/// Read-only metadata captured by the startup discovery pass.  The durable
/// scanner remains the only writer/authority; this plan is only a same-owner
/// hint that lets a normal scan consume the candidates without immediately
/// walking the same directory tree again.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct PreciseScanCandidate {
    canonical_path: PathBuf,
    signature: FileSignature,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DirectorySignature {
    path: PathBuf,
    exists: bool,
    is_directory: bool,
    size: u64,
    modified_ns: u128,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct PreciseScanDiscovery {
    pub(super) canonical_home: PathBuf,
    pub(super) physical_home_identity: String,
    pub(super) source_revision: u64,
    pub(super) discovered_at: SystemTime,
    directory_signatures: Vec<DirectorySignature>,
    pub(super) candidates: Vec<PreciseScanCandidate>,
    pub(super) candidate_total: u64,
    boundary_warnings: Vec<String>,
}

impl PreciseScanDiscovery {
    /// The discovery pass is a candidate hint, not an authority.  It remains
    /// usable after a watcher event as long as the physical Home is still the
    /// same; every candidate is reopened and re-signed by the durable scan.
    pub(super) fn is_usable(&self, codex_home: &Path) -> bool {
        let Ok(canonical_home) = canonical_codex_home(codex_home) else {
            return false;
        };
        if canonical_home != self.canonical_home
            || attribution_watch_root_physical_identity(&canonical_home)
                .ok()
                .as_deref()
                != Some(self.physical_home_identity.as_str())
        {
            return false;
        }
        true
    }
}

/// Read-only source-change result for the dashboard cadence. `changed = None`
/// means that discovery could not prove a complete source view; callers must
/// treat that state as unknown and schedule the authoritative precise owner.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ReadOnlySourceProbe {
    pub(super) published_generation: u64,
    pub(super) changed: Option<bool>,
}

/// Probes the published generation and file checkpoints without opening the
/// writable exact index. The filesystem side only reads directory entries and
/// file metadata through the existing discovery candidate seam; it never reads
/// JSONL bodies or creates temporary SQLite tables.
pub(super) fn read_only_source_probe(
    codex_home: &Path,
    timeout: StdDuration,
) -> Result<ReadOnlySourceProbe, String> {
    let path = database_path(codex_home)?;
    if !existing_regular_index(&path)? {
        return Ok(ReadOnlySourceProbe {
            published_generation: 0,
            changed: Some(true),
        });
    }
    let connection = sqlite::open_read_only(&path, timeout).map_err(|error| {
        format!(
            "无法只读打开精确 token 索引源探针 {}：{error}",
            path.display()
        )
    })?;
    let metadata_table_exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'metadata')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法只读检查精确 token 源探针元数据表：{error}"))?;
    if !metadata_table_exists {
        return Ok(ReadOnlySourceProbe {
            published_generation: 0,
            changed: Some(true),
        });
    }
    let published_generation = match metadata_text(&connection, "published_generation")? {
        Some(value) => value.parse::<u64>().map_err(|_| {
            format!(
                "精确 token 源探针已发布代次无效：{value:?}，已拒绝按缺失值覆盖"
            )
        })?,
        None => 0,
    };
    let building_generation = metadata_text(&connection, "building_generation")?;
    let enrichment_complete = metadata_text(&connection, EVENT_ENRICHMENT_REVISION_KEY)?
        .as_deref()
        == Some(EVENT_ENRICHMENT_REVISION);
    let published_view_exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'view' AND name = 'published_files')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法只读检查精确 token 已发布文件视图：{error}"))?;
    if !published_view_exists {
        return Ok(ReadOnlySourceProbe {
            published_generation,
            changed: Some(true),
        });
    }

    let mut statement = connection
        .prepare(
            "SELECT path, size, modified_ns, device_id, file_id, changed_ns FROM published_files",
        )
        .map_err(|error| format!("无法准备精确 token 源探针文件检查点：{error}"))?;
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
        .map_err(|error| format!("无法读取精确 token 源探针文件检查点：{error}"))?;
    let mut published_files = HashMap::new();
    for row in rows {
        let (path, signature) =
            row.map_err(|error| format!("无法解码精确 token 源探针文件检查点：{error}"))?;
        published_files.insert(path, signature);
    }
    drop(statement);

    let discovery = match estimate_precise_scan_total_with_source_revision(
        codex_home,
        timeout,
        0,
    ) {
        Ok(discovery) => discovery,
        Err(_) => {
            return Ok(ReadOnlySourceProbe {
                published_generation,
                changed: None,
            })
        }
    };
    if !discovery.boundary_warnings.is_empty() {
        return Ok(ReadOnlySourceProbe {
            published_generation,
            changed: None,
        });
    }

    let mut seen = HashSet::with_capacity(discovery.candidates.len());
    let mut changed = building_generation.is_some() || !enrichment_complete;
    for candidate in discovery.candidates {
        let path = candidate.canonical_path.to_string_lossy().into_owned();
        if !seen.insert(path.clone()) {
            continue;
        }
        let unchanged = published_files.get(&path).is_some_and(
            |(size, modified_ns, device_id, file_id, changed_ns)| {
                candidate.signature.matches_stored(
                    *size,
                    modified_ns,
                    device_id,
                    file_id,
                    changed_ns,
                )
            },
        );
        changed |= !unchanged;
    }
    changed |= published_files.keys().any(|path| !seen.contains(path));
    Ok(ReadOnlySourceProbe {
        published_generation,
        changed: Some(changed),
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct IndexStorageSignature {
    database: FileSignature,
    wal: Option<FileSignature>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct IndexIntegrityReceipt {
    version: u32,
    canonical_index_path: String,
    database: ReceiptFileSignature,
    wal: Option<ReceiptFileSignature>,
    schema_version: i64,
    parser_revision: String,
    published_generation: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptFileSignature {
    size: u64,
    modified_ns: String,
    device_id: u64,
    file_id: u64,
    changed_ns: String,
}

#[derive(Clone, Debug)]
struct ReceiptMetadata {
    canonical_index_path: String,
    schema_version: i64,
    parser_revision: String,
    published_generation: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct IndexIntegrityState {
    active_connections: usize,
}

struct IntegrityGate {
    in_flight: Mutex<bool>,
    released: Condvar,
}

struct IntegrityGateGuard {
    gate: Arc<IntegrityGate>,
    path: PathBuf,
    notify_release: bool,
}

static INDEX_INTEGRITY_GATES: OnceLock<Mutex<HashMap<PathBuf, Weak<IntegrityGate>>>> =
    OnceLock::new();

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
    event_enrichment: bool,
    expected_published_prefix_sha256: Option<[u8; 32]>,
}

#[derive(Clone, Debug)]
struct EventEnrichmentCandidate {
    path: String,
    session_id: String,
    signature: FileSignature,
    prefix_sha256: [u8; 32],
}

#[derive(Clone, Debug)]
struct StagedFullRebuild {
    job: FullRebuildJob,
    committed_signature: FileSignature,
    database_path: PathBuf,
    artifact_id: String,
    actual_bytes: u64,
    prefix_sha256: [u8; 32],
    resume_offset: u64,
    parser_state: ExactSessionParserState,
    event_count: u64,
}

struct StagedFullRebuildResult {
    order: usize,
    result: Result<StagedFullRebuild, StagedFullRebuildError>,
    warnings: Vec<LocalDataWarning>,
}

enum StagedFullRebuildError {
    IncompleteSource(String),
    Fatal(String),
}

impl From<String> for StagedFullRebuildError {
    fn from(error: String) -> Self {
        Self::Fatal(error)
    }
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

#[derive(Clone, Debug)]
struct StoredSessionCatalogEntry {
    entry: IndexedSessionCatalogEntry,
    modified_ns: String,
    created_ns: String,
    stat_device_id: String,
    stat_file_id: String,
    stat_changed_ns: String,
    device_id: String,
    file_id: String,
    changed_ns: String,
    first_line_bytes: u64,
    first_line_sha256: [u8; 32],
    last_seen_generation: i64,
}

#[derive(Clone, Debug)]
struct SessionCatalogObservation {
    path: PathBuf,
    archived: bool,
    size: u64,
    modified_ns: String,
    created_ns: String,
    stat_device_id: String,
    stat_file_id: String,
    stat_changed_ns: String,
    modified_at: Option<i64>,
    created_at: Option<i64>,
}

#[cfg(test)]
type AfterPrefixScanHook = Box<dyn FnOnce(&Path)>;
#[cfg(test)]
type AfterFileCommitHook = Box<dyn FnOnce(&Path) -> Result<(), String>>;
#[cfg(test)]
pub(super) type IntegrityGateEnterHook = Box<dyn Fn(&Path) + Send + Sync>;
#[cfg(test)]
pub(super) type IntegrityGateReleaseHook = Box<dyn Fn(&Path) + Send + Sync>;
#[cfg(test)]
pub(super) type BeforeFinishIndexConnectionHook = Box<dyn Fn(&Path) + Send + Sync>;
#[cfg(test)]
struct BeforeStagingOpenHook {
    target: PathBuf,
    action: Box<dyn FnOnce(&Path) + Send>,
}

#[cfg(test)]
static BEFORE_STAGING_OPEN_HOOK: OnceLock<Mutex<Option<BeforeStagingOpenHook>>> = OnceLock::new();
#[cfg(test)]
static INTEGRITY_GATE_ENTER_HOOK: OnceLock<Mutex<Option<IntegrityGateEnterHook>>> = OnceLock::new();
#[cfg(test)]
static INTEGRITY_GATE_RELEASE_HOOK: OnceLock<Mutex<Option<IntegrityGateReleaseHook>>> =
    OnceLock::new();
#[cfg(test)]
static BEFORE_FINISH_INDEX_CONNECTION_HOOK: OnceLock<
    Mutex<Option<BeforeFinishIndexConnectionHook>>,
> = OnceLock::new();

#[cfg(test)]
thread_local! {
    static AFTER_PREFIX_SCAN_HOOK: RefCell<Option<AfterPrefixScanHook>> = RefCell::new(None);
    static AFTER_FILE_COMMIT_HOOK: RefCell<Option<AfterFileCommitHook>> = RefCell::new(None);
    static AFTER_DASHBOARD_SNAPSHOT_HOOK: RefCell<Option<Box<dyn FnOnce()>>> = RefCell::new(None);
    static PREFIX_REHASH_COUNT: Cell<u64> = const { Cell::new(0) };
    static FAIL_NEXT_SESSION_CATALOG_PUBLISH: Cell<bool> = const { Cell::new(false) };
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
#[cfg(test)]
static FAIL_NEXT_QUICK_CHECK_QUERY: AtomicBool = AtomicBool::new(false);
#[cfg(test)]
static RECEIPT_WRITE_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static OPEN_MIGRATION_WORK_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static OPEN_DDL_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static OPEN_WRITE_TRANSACTION_COUNT: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static QUICK_CHECK_BARRIER: OnceLock<Mutex<Option<(Arc<Barrier>, HashSet<PathBuf>)>>> =
    OnceLock::new();
static INDEX_INTEGRITY_STATES: OnceLock<Mutex<HashMap<PathBuf, IndexIntegrityState>>> =
    OnceLock::new();

fn assess_index_migration(
    connection: &Connection,
    existed_before: bool,
) -> Result<MigrationAssessment, String> {
    if !existed_before {
        return Ok(MigrationAssessment::Compatible);
    }
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
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%')",
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
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'metadata')",
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
    if schema > INDEX_SCHEMA_VERSION {
        return Ok(MigrationAssessment::UpgradeRequired {
            component: "schema",
            stored: schema.to_string(),
            supported: INDEX_SCHEMA_VERSION.to_string(),
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
            if stored != supported {
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
    if schema != INDEX_SCHEMA_VERSION {
        stages.push("schema");
    } else if !column_exists_checked(connection, "files", "current_model")?
        || !column_exists_checked(connection, "files", "is_explicit_subagent_fork")?
        || !column_exists_checked(connection, "events", "model")?
        || !column_exists_checked(connection, "events", "reasoning_output_tokens")?
    {
        stages.push("schema");
    }
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
        || metadata_text(connection, ATTRIBUTION_LEDGER_EPOCH_KEY)?.is_none_or(|value| value.trim().is_empty())
        || metadata_text(connection, ATTRIBUTION_LEDGER_INTEGRITY_KEY)?.is_none_or(|value| value.trim().is_empty())
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

impl ExactUsageIndex {
    pub(super) fn open(codex_home: &Path) -> Result<Self, String> {
        let operation_lock = AppOperationGuard::acquire(codex_home)?;
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
        let existed_before = existing_regular_index(&path)?;
        let (migration_assessment, metadata_table_exists) = if existed_before {
            let read_only =
                sqlite::open_read_only(&path, StdDuration::from_secs(1)).map_err(|error| {
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
                format!(
                    "无法只读检查精确 token 索引兼容性，已保留原索引并拒绝自动重建：{error}"
                )
            })?;
            if let Some(error) = assessment.blocking_error() {
                return Err(error);
            }
            (assessment, metadata_table_exists)
        } else {
            (MigrationAssessment::Compatible, false)
        };
        let needs_migration_work = matches!(
            &migration_assessment,
            MigrationAssessment::KnownMigrationRequired(_)
        );
        let (mut connection, recovered_corrupt_index) =
            open_index_connection_with_recovery(
                &path,
                existed_before,
                !existed_before || !metadata_table_exists,
            )?;
        let raw_schema_version = metadata_text(&connection, "schema_version")?;
        let mut has_schema_version = raw_schema_version.is_some();
        let mut schema_version = raw_schema_version.and_then(|value| value.parse::<i64>().ok());
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
                if revision != supported {
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
            .is_some_and(|revision| revision != EVENT_ENRICHMENT_REVISION)
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
                        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'metadata')",
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
            if schema_version.is_some_and(|version| version > INDEX_SCHEMA_VERSION) {
                return Err(format!(
                    "精确 token 索引版本 {:?} 高于当前支持版本 {}，已拒绝覆盖",
                    schema_version, INDEX_SCHEMA_VERSION
                ));
            }
            if schema_version.is_some_and(|version| {
                !(GITHUB_BASE_SCHEMA_VERSION..=INDEX_SCHEMA_VERSION).contains(&version)
            }) {
                // The index is fully rebuildable. Replacing an obsolete database,
                // rather than dropping its text columns in place, guarantees that
                // deleted SQLite pages and WAL frames cannot retain conversation
                // plaintext from schema v1. Since v6 this also discards pre-v6
                // 9-field fingerprint blobs that would break deduplication.
                drop(connection);
                remove_index_storage(&path)?;
                connection = managed_index_connection(
                    &path,
                    open_index_connection(&path, true, true)?,
                )?;
                schema_version = None;
                has_schema_version = false;
            } else if schema_version.is_some() && needs_migration_work {
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
            repair_orphaned_index_rows(&mut connection)?;
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
                replay_migration_complete =
                    repair_explicit_subagent_replay_boundary(&connection)?;
            }
        }
        if (!should_report_migration || replay_migration_complete)
            && !event_enrichment_requires_sync
            && schema_version != Some(INDEX_SCHEMA_VERSION)
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
            // Known GitHub v6/v7 databases are upgraded in place. Only a new
            // or intentionally discarded pre-v6 database starts from zero.
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
        let physical_identity = attribution_watch_root_physical_identity(codex_home)?;
        let stored_identity = metadata_text(&connection, "codex_home_identity")?;
        let stored_physical_identity = metadata_text(&connection, "codex_home_physical_identity")?;
        let logical_identity_mismatch = stored_identity
            .as_deref()
            .is_some_and(|stored| stored != identity);
        let physical_identity_mismatch = stored_physical_identity
            .as_deref()
            .is_some_and(|stored| stored != physical_identity);
        if stored_identity.is_none() && event_enrichment_source_count(&connection)? > 0 {
            return Err(
                "精确 token 旧索引缺少 Codex Home 身份，已拒绝在来源不明时覆盖现有数据".into(),
            );
        }
        if logical_identity_mismatch || physical_identity_mismatch {
            connection
                .execute_batch(
                    r#"
                    DELETE FROM events;
                    DELETE FROM attribution_source_buckets;
                    DELETE FROM file_fingerprints;
                    DELETE FROM file_chunks;
                    DELETE FROM files;
                    DELETE FROM session_metadata;
                    DELETE FROM session_catalog_files;
                    DELETE FROM metadata
                    WHERE key NOT IN ('schema_version', 'session_catalog_schema_version');
                    "#,
                )
                .map_err(|error| format!("无法切换精确 token 索引数据源：{error}"))?;
            set_metadata(&connection, "codex_home_identity", &identity)?;
            set_metadata(
                &connection,
                "codex_home_physical_identity",
                &physical_identity,
            )?;
            set_metadata(&connection, "revision", &fresh_revision_seed().to_string())?;
            set_metadata(&connection, "published_generation", "0")?;
            set_metadata(&connection, "session_catalog_published_generation", "0")?;
            set_metadata(
                &connection,
                EVENT_ENRICHMENT_REVISION_KEY,
                EVENT_ENRICHMENT_REVISION,
            )?;
            set_metadata(
                &connection,
                "schema_version",
                &INDEX_SCHEMA_VERSION.to_string(),
            )?;
        } else {
            // Public v0.8.3 indexes persisted the logical Home identity but
            // predate the physical identity marker. Bind that marker in place:
            // absence is a known legacy shape, not evidence that the Home was
            // replaced. Only an explicit mismatch above resets the source.
            if stored_identity.is_none() {
                set_metadata(&connection, "codex_home_identity", &identity)?;
            }
            if stored_physical_identity.is_none() {
                set_metadata(
                    &connection,
                    "codex_home_physical_identity",
                    &physical_identity,
                )?;
            }
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
        Ok(Self {
            connection,
            _operation_lock: operation_lock,
            migration_pending: !migration_markers_complete,
        })
    }

    pub(super) fn refresh_session_catalog<F>(
        &mut self,
        codex_home: &Path,
        mut parser: F,
    ) -> Result<(), String>
    where
        F: FnMut(&[u8]) -> Result<IndexedSessionMetadata, String>,
    {
        self.connection.mark_receipt_dirty();
        let existing = load_stored_session_catalog(&self.connection)?;
        let observations = collect_session_catalog_observations(codex_home)?;
        let published_generation =
            metadata_i64(&self.connection, "session_catalog_published_generation")?.unwrap_or(0);
        let generation = published_generation
            .checked_add(1)
            .ok_or_else(|| "会话目录索引代次溢出".to_string())?;
        let mut entries = Vec::with_capacity(observations.len());
        let mut catalog_changed = observations.len() != existing.len();
        for observation in observations {
            let previous = existing.get(&observation.path);
            let entry = if previous
                .is_some_and(|entry| session_catalog_observation_matches(entry, &observation))
            {
                let mut entry = previous
                    .cloned()
                    .expect("checked existing session catalog entry");
                entry.entry.archived = observation.archived;
                entry.last_seen_generation = generation;
                entry
            } else {
                catalog_changed = true;
                refresh_session_catalog_entry(observation, previous, generation, &mut parser)?
            };
            entries.push(entry);
        }
        if !catalog_changed {
            self.connection.mark_receipt_eligible();
            return Ok(());
        }

        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始会话目录索引发布事务：{error}"))?;
        for entry in &entries {
            transaction
                .execute(
                    r#"
                    INSERT INTO session_catalog_files (
                        path, archived, thread_id, cwd, source, session_id,
                        forked_from_id, parent_thread_id, size, modified_ns,
                        created_ns, modified_at, created_at, stat_device_id,
                        stat_file_id, stat_changed_ns, device_id, file_id,
                        changed_ns, first_line_bytes, first_line_sha256,
                        last_seen_generation
                    ) VALUES (
                        ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                        ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20,
                        ?21, ?22
                    )
                    ON CONFLICT(path) DO UPDATE SET
                        archived = excluded.archived,
                        thread_id = excluded.thread_id,
                        cwd = excluded.cwd,
                        source = excluded.source,
                        session_id = excluded.session_id,
                        forked_from_id = excluded.forked_from_id,
                        parent_thread_id = excluded.parent_thread_id,
                        size = excluded.size,
                        modified_ns = excluded.modified_ns,
                        created_ns = excluded.created_ns,
                        modified_at = excluded.modified_at,
                        created_at = excluded.created_at,
                        stat_device_id = excluded.stat_device_id,
                        stat_file_id = excluded.stat_file_id,
                        stat_changed_ns = excluded.stat_changed_ns,
                        device_id = excluded.device_id,
                        file_id = excluded.file_id,
                        changed_ns = excluded.changed_ns,
                        first_line_bytes = excluded.first_line_bytes,
                        first_line_sha256 = excluded.first_line_sha256,
                        last_seen_generation = excluded.last_seen_generation
                    "#,
                    params![
                        entry.entry.path.to_string_lossy(),
                        i64::from(entry.entry.archived),
                        entry.entry.metadata.thread_id,
                        entry.entry.metadata.cwd,
                        entry.entry.metadata.source,
                        entry.entry.metadata.session_id,
                        entry.entry.metadata.forked_from_id,
                        entry.entry.metadata.parent_thread_id,
                        checked_i64(entry.entry.size, "会话目录文件大小")?,
                        entry.modified_ns,
                        entry.created_ns,
                        entry.entry.modified_at,
                        entry.entry.created_at,
                        entry.stat_device_id,
                        entry.stat_file_id,
                        entry.stat_changed_ns,
                        entry.device_id,
                        entry.file_id,
                        entry.changed_ns,
                        checked_i64(entry.first_line_bytes, "会话目录首行长度")?,
                        entry.first_line_sha256.as_slice(),
                        entry.last_seen_generation,
                    ],
                )
                .map_err(|error| {
                    format!(
                        "无法写入会话目录索引 {}：{error}",
                        entry.entry.path.display()
                    )
                })?;
        }
        transaction
            .execute(
                "DELETE FROM session_catalog_files WHERE last_seen_generation <> ?1",
                [generation],
            )
            .map_err(|error| format!("无法清理会话目录索引中的已删除文件：{error}"))?;
        run_before_session_catalog_publish_hook_for_testing()?;
        set_metadata(
            &transaction,
            "session_catalog_published_generation",
            &generation.to_string(),
        )?;
        transaction
            .commit()
            .map_err(|error| format!("无法原子发布会话目录索引：{error}"))?;
        self.connection.mark_receipt_eligible();
        Ok(())
    }

    pub(super) fn session_catalog_snapshot(&self) -> Result<IndexedSessionCatalogSnapshot, String> {
        let mut entries: Vec<_> = load_stored_session_catalog(&self.connection)?
            .into_values()
            .map(|entry| entry.entry)
            .collect();
        entries.sort_by(|left, right| left.path.cmp(&right.path));
        Ok(IndexedSessionCatalogSnapshot {
            entries,
            warnings: Vec::new(),
        })
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
    pub(super) fn set_integrity_gate_enter_hook_for_testing(hook: Option<IntegrityGateEnterHook>) {
        let slot = INTEGRITY_GATE_ENTER_HOOK.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
    }

    #[cfg(test)]
    pub(super) fn set_integrity_gate_release_hook_for_testing(
        hook: Option<IntegrityGateReleaseHook>,
    ) {
        let slot = INTEGRITY_GATE_RELEASE_HOOK.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
    }

    #[cfg(test)]
    pub(super) fn set_before_finish_index_connection_hook_for_testing(
        hook: Option<BeforeFinishIndexConnectionHook>,
    ) {
        let slot = BEFORE_FINISH_INDEX_CONNECTION_HOOK.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = hook;
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
    pub(super) fn active_integrity_connections_for_testing(path: &Path) -> usize {
        index_integrity_states()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(path)
            .map(|state| state.active_connections)
            .unwrap_or(0)
    }

    #[cfg(test)]
    pub(super) fn reset_quick_check_count_for_testing() {
        QUICK_CHECK_COUNT.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn quick_check_count_for_testing() -> u64 {
        QUICK_CHECK_COUNT.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(super) fn fail_next_quick_check_query_for_testing() {
        FAIL_NEXT_QUICK_CHECK_QUERY.store(true, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn reset_receipt_write_count_for_testing() {
        RECEIPT_WRITE_COUNT.store(0, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(super) fn receipt_write_count_for_testing() -> u64 {
        RECEIPT_WRITE_COUNT.load(Ordering::SeqCst)
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

    #[cfg(test)]
    pub(super) fn set_quick_check_barrier_for_testing(
        barrier: Option<(Arc<Barrier>, HashSet<PathBuf>)>,
    ) {
        let slot = QUICK_CHECK_BARRIER.get_or_init(|| Mutex::new(None));
        *slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = barrier;
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
                    || metadata_i64(&self.connection, ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY)?
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
                let staged_thread_metadata = stage_thread_metadata(codex_home, previous, warnings)?;
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
                // sources_changed uses a temporary published-files snapshot.
                // Drop it before the durable scan so dashboard reads cannot
                // accidentally keep the pre-scan generation selector.
                self.connection
                    .execute("DROP TABLE IF EXISTS temp.published_files", [])
                    .map_err(|error| format!("无法清理精确 token 源文件快照：{error}"))?;
            }
        }

        self.connection.mark_receipt_dirty();
        let mut scan_completeness = ExactScanCompleteness::default();
        let scan_start_home_identity = match attribution_watch_root_physical_identity(codex_home) {
            Ok(identity) => Some(identity),
            Err(error) => {
                scan_completeness.mark_incomplete();
                warnings.push(scan_warning(format!(
                    "精确 token 扫描开始时无法固定 Codex Home 物理身份：{error}"
                )));
                None
            }
        };
        prune_published_tombstone_versions(&self.connection)?;
        prepare_scan_temp_tables(&self.connection)?;
        let generation = begin_or_resume_generation(&mut self.connection, mode)?;
        let mut full_rebuild_jobs = Vec::new();
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
            for message in plan.boundary_warnings {
                scan_completeness.mark_incomplete();
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
                    &mut scanned_files,
                    &mut scanned_paths,
                    scan_total,
                    &mut diagnostics,
                    Some(candidate.signature),
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
        super::update_precise_dashboard_progress(
            codex_home,
            "publishing",
            "正在写入精确索引并发布本轮结果",
            0,
            Some(1),
        );
        diagnostics.scanned_files = scanned_files;
        diagnostics.full_rebuild_files = diagnostics
            .full_rebuild_files
            .saturating_add(full_rebuild_jobs.len() as u64);
        for batch in staging_job_batches(&full_rebuild_jobs) {
            let estimated_bytes = batch
                .iter()
                .fold(0_u64, |total, job| total.saturating_add(job.signature.size));
            ensure_staging_capacity(&index_path, estimated_bytes)?;
            let staged = stage_full_rebuilds(
                &batch,
                &index_path,
                generation,
                codex_home,
                warnings,
                &mut scan_completeness,
                None,
            )?;
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
                remove_index_storage(&staged_file.database_path)?;
                run_after_file_commit_hook_for_testing(&staged_file.job.file)?;
            }
        }
        let scan_home_identity_stable = match attribution_watch_root_physical_identity(codex_home) {
            Ok(identity) if scan_start_home_identity.as_ref() == Some(&identity) => true,
            Ok(_) => {
                scan_completeness.mark_incomplete();
                warnings.push(scan_warning(
                    "Codex Home 在精确 token 扫描期间被同路径替换，本轮归因已停止建立安全覆盖"
                        .into(),
                ));
                false
            }
            Err(error) => {
                scan_completeness.mark_incomplete();
                warnings.push(scan_warning(format!(
                    "精确 token 扫描结束时无法复核 Codex Home 物理身份：{error}"
                )));
                false
            }
        };
        if !scan_home_identity_stable {
            self.connection.mark_receipt_dirty();
            return Err(
                "Codex Home 在精确扫描期间变化或暂时无法确认，已保留上一份可信索引并停止本轮发布"
                    .into(),
            );
        }
        if scan_completeness.block_generation_publish {
            self.connection.mark_receipt_dirty();
            return Err("会话根目录暂时不可用，已保留上一份可信索引并停止本轮发布".into());
        }
        let run_migrations = !migration_markers_complete(&self.connection, true)?;
        let revision = finalize_generation(
            &mut self.connection,
            generation,
            codex_home,
            warnings,
            scan_completeness,
            mode,
            run_migrations,
        )?;
        diagnostics.published_watermark = revision;
        startup_trace::mark_performance(format!(
            "precise_scan candidate_count={} scanned_files={} append_scan_bytes={} full_body_bytes={} pending_tail_bytes={} full_rebuild_files={} source_drift={} published_watermark={}",
            diagnostics.candidate_count,
            diagnostics.scanned_files,
            diagnostics.append_scan_bytes,
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
        }
        Ok(revision)
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
        match stage_thread_metadata(codex_home, previous, warnings)? {
            ThreadMetadataStage::Updated(staged) => {
                publish_thread_metadata_only(&mut self.connection, staged)
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
                &INDEX_SCHEMA_VERSION.to_string(),
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
            let handle = match fs::File::open(&file) {
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
                        return Err("injected interruption after durable exact token staging".into());
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
                        "历史字段补全暂时无法确认来源身份，保留上次可信数据并将在下次启动继续：{}（{}）",
                        file.display(),
                        error
                    )));
                    continue;
                }
            };
            drop(handle);
            let stable_published_prefix = current_signature.identity
                == candidate.signature.identity
                && current_signature.size >= candidate.signature.size;
            if !stable_published_prefix {
                set_metadata(
                    &self.connection,
                    BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY,
                    "1",
                )?;
            }
            jobs.push(FullRebuildJob {
                file,
                path: candidate.path,
                session_id: candidate.session_id,
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
                import_staged_full_rebuild(
                    &mut self.connection,
                    generation,
                    &staged_file,
                    mode,
                )?;
                remove_index_storage(&staged_file.database_path)?;
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
                &INDEX_SCHEMA_VERSION.to_string(),
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

    pub(super) fn dashboard_revision(&self) -> Result<u64, String> {
        let revision = self.revision()?;
        Ok(optional_startup_metadata_u64(&self.connection, DASHBOARD_REVISION_KEY)?
            .unwrap_or(revision))
    }

    pub(super) fn dashboard_aggregate_identity(
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
    pub(super) fn dashboard_aggregate_is_lagging(&self) -> Result<bool, String> {
        let identity = self.dashboard_aggregate_identity()?;
        let published_generation = self.published_generation()?;
        let schema_matches = identity
            .schema_version
            .as_deref()
            .and_then(|value| value.parse::<i64>().ok())
            == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION);
        Ok(!schema_matches
            || identity.pricing_revision.as_deref()
                != Some(DASHBOARD_AGGREGATE_PRICING_REVISION)
            || identity.exact_generation != Some(published_generation)
            || identity.published_generation != Some(published_generation)
            || identity.settled_through.is_none())
    }

    pub(super) fn published_generation(&self) -> Result<u64, String> {
        let raw = metadata_text(&self.connection, "published_generation")?
            .ok_or_else(|| "精确 token 索引已发布代次缺失".to_string())?;
        raw.parse::<u64>()
            .map_err(|_| "精确 token 索引已发布代次无效".to_string())
    }

    pub(super) fn attribution_safety_state(&self) -> Result<AttributionSafetyState, String> {
        attribution_safety_state(&self.connection)
    }

    /// Clears only the exact clean generation represented by a durable
    /// synthetic cutover. A stale acknowledgement, or any scan that still sees
    /// the unsafe cause, is rejected without changing provenance state.
    pub(super) fn acknowledge_attribution_safety(
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
        let mut ignored_scan_completeness = ExactScanCompleteness::default();
        visit_session_files(
            &mut self.connection,
            codex_home,
            warnings,
            &mut ignored_scan_completeness,
            |_connection, file, scan_warnings, scan_completeness| {
                let path = file.to_string_lossy().into_owned();
                if !seen_files.insert(path.clone()) {
                    return Ok(());
                }
                let signature = match file_signature(file) {
                    Ok(signature) => signature,
                    Err(error) => {
                        // A metadata/permission race is a source change, not
                        // proof that the file disappeared.  Let the durable
                        // scan classify it as incomplete and preserve the
                        // published rows instead of aborting the probe.
                        changed = true;
                        scan_completeness.mark_incomplete();
                        scan_warnings.push(scan_warning(format!(
                            "无法读取会话文件签名，本轮保留已有统计：{}（{}）",
                            file.display(),
                            error
                        )));
                        return Ok(());
                    }
                };
                let unchanged = published_files.get(&path).is_some_and(
                    |(size, modified_ns, device_id, file_id, changed_ns)| {
                        signature.matches_stored(*size, modified_ns, device_id, file_id, changed_ns)
                    },
                );
                changed |= !unchanged;
                Ok(())
            },
        )?;
        let deleted = published_files
            .keys()
            .any(|path| !seen_files.contains(path));
        Ok(changed || deleted || ignored_scan_completeness.incomplete_source_scan)
    }

    fn sources_changed_from_discovery(
        &mut self,
        discovery: &PreciseScanDiscovery,
    ) -> Result<bool, String> {
        if metadata_i64(&self.connection, "building_generation")?.is_some() {
            return Ok(true);
        }
        if !discovery.boundary_warnings.is_empty() {
            return Ok(true);
        }
        prepare_scan_temp_tables(&self.connection)?;
        self.prepare_source_change_snapshot()?;
        let published_files = self.source_change_snapshot_signatures()?;
        let mut seen = HashSet::with_capacity(discovery.candidates.len());
        let mut changed = false;
        for candidate in &discovery.candidates {
            let path = candidate.canonical_path.to_string_lossy().into_owned();
            if !seen.insert(path.clone()) {
                continue;
            }
            let unchanged = published_files.get(&path).is_some_and(
                |(size, modified_ns, device_id, file_id, changed_ns)| {
                    candidate.signature.matches_stored(
                        *size,
                        modified_ns,
                        device_id,
                        file_id,
                        changed_ns,
                    )
                },
            );
            changed |= !unchanged;
        }
        let deleted = published_files.keys().any(|path| !seen.contains(path));
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
        self.summary_at(now_utc, LocalDayMode::Fixed(local_offset))
    }

    /// Computes the summary's local-day projection with the system IANA rules
    /// at each event timestamp. Exact event rows and UTC five-minute buckets
    /// remain untouched; only the read-time projection changes.
    pub(super) fn summary_with_system_timezone(
        &self,
        now_utc: OffsetDateTime,
    ) -> Result<TokenUsageSummary, String> {
        self.summary_at(now_utc, LocalDayMode::System)
    }

    fn summary_at(
        &self,
        now_utc: OffsetDateTime,
        local_day_mode: LocalDayMode,
    ) -> Result<TokenUsageSummary, String> {
        let today = local_day_mode.date_at(now_utc.unix_timestamp());
        let (start, end) = local_day_mode.day_bounds(today)?;
        let (total, today_tokens, today_requests) = self
            .connection
            .query_row(
                r#"
                SELECT
                    COALESCE((
                        SELECT SUM(e.tokens)
                        FROM events e
                        JOIN published_files f
                          ON f.generation = e.file_generation
                         AND f.path = e.file_path
                    ), 0),
                    COALESCE((
                        SELECT SUM(e.tokens)
                        FROM events e
                        JOIN published_files f
                          ON f.generation = e.file_generation
                         AND f.path = e.file_path
                        WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                    ), 0),
                    COALESCE((
                        SELECT COUNT(*)
                        FROM events e
                        JOIN published_files f
                          ON f.generation = e.file_generation
                         AND f.path = e.file_path
                        WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                    ), 0)
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
            today_model_breakdowns: self.model_breakdowns_between(start, end, local_day_mode)?,
        })
    }

    /// Builds the lightweight total/today/model projection from per-file
    /// contributions.  A missing previous map performs one grouped SQLite
    /// read and seeds the map; later Summary owners only re-read files whose
    /// published generation changed.  This deliberately does not touch
    /// dashboard time-series, heatmap, ranking, or aggregate publication
    /// tables.
    pub(super) fn summary_with_file_contributions(
        &self,
        now_utc: OffsetDateTime,
        previous: Option<&HashMap<String, SummaryFileContribution>>,
    ) -> Result<
        (
            TokenUsageSummary,
            HashMap<String, SummaryFileContribution>,
        ),
        String,
    > {
        let today = LocalDayMode::System.date_at(now_utc.unix_timestamp());
        let (start, end) = LocalDayMode::System.day_bounds(today)?;
        let current_files = self.published_file_generations()?;
        let (contributions, recomputed_files, mode) = match previous {
            None => (
                self.summary_file_contributions_full(start, end)?,
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
        Ok((summary_from_file_contributions(&contributions), contributions))
    }

    fn published_file_generations(&self) -> Result<HashMap<String, i64>, String> {
        let mut statement = self
            .connection
            .prepare("SELECT path, generation FROM published_files")
            .map_err(|error| format!("无法准备轻量摘要文件代次：{error}"))?;
        let rows = statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|error| format!("无法读取轻量摘要文件代次：{error}"))?;
        rows.map(|row| row.map_err(|error| format!("无法解码轻量摘要文件代次：{error}")))
            .collect()
    }

    pub(super) fn latest_published_source_modified_at(&self) -> Result<Option<String>, String> {
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
    ) -> Result<HashMap<String, SummaryFileContribution>, String> {
        let mut statement = self
            .connection
            .prepare(
                r#"
                SELECT
                    e.file_path,
                    e.file_generation,
                    e.model,
                    COALESCE(SUM(e.tokens), 0),
                    COALESCE(SUM(CASE WHEN e.timestamp >= ?1 AND e.timestamp < ?2 THEN e.tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN e.timestamp >= ?1 AND e.timestamp < ?2 THEN e.input_tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN e.timestamp >= ?1 AND e.timestamp < ?2 THEN MIN(e.cached_input_tokens, e.input_tokens) ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN e.timestamp >= ?1 AND e.timestamp < ?2 THEN e.output_tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN e.timestamp >= ?1 AND e.timestamp < ?2 THEN 1 ELSE 0 END), 0)
                FROM events e
                JOIN published_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                GROUP BY e.file_path, e.file_generation, e.model
                "#,
            )
            .map_err(|error| format!("无法准备轻量摘要全量种子：{error}"))?;
        let rows = statement
            .query_map(params![start, end], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, i64>(8)?,
                ))
            })
            .map_err(|error| format!("无法读取轻量摘要全量种子：{error}"))?;
        let mut contributions = HashMap::<String, SummaryFileContribution>::new();
        for row in rows {
            let (path, generation, model, total, today, input, cached, output, calls) = row
                .map_err(|error| format!("无法解码轻量摘要全量种子：{error}"))?;
            add_summary_file_row(
                &mut contributions,
                path,
                generation,
                model,
                total,
                today,
                input,
                cached,
                output,
                calls,
            );
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
                FROM events
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
            let (model, total, today, input, cached, output, calls) = row
                .map_err(|error| format!("无法解码轻量摘要文件增量：{error}"))?;
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
                model_breakdowns.push(ModelTokenBreakdown {
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
                COALESCE(SUM(calls), 0)
            FROM dashboard_5m b
            WHERE b.file_generation = COALESCE(
                (SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'published_generation'),
                0
            )
              AND b.bucket_start >= ?1 AND b.bucket_start < ?2
            GROUP BY model
            ORDER BY SUM(total_tokens) DESC
            "#,
            )
            .map_err(|error| format!("无法准备今日逐模型 token 汇总：{error}"))?;
        let rows = statement
            .query_map(params![start, end], |row| {
                Ok(ModelTokenBreakdown {
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
                    COUNT(*)
                FROM events e
                JOIN published_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path
                WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                GROUP BY e.model
                ORDER BY SUM(e.tokens) DESC
                "#,
            )
            .map_err(|error| format!("无法准备本地日逐模型 token 汇总：{error}"))?;
        let rows = statement
            .query_map(params![start, end], |row| {
                Ok(ModelTokenBreakdown {
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

    /// Ensures the disposable numeric aggregate layer is complete for the
    /// currently published exact generation. The first upgrade groups the
    /// existing SQLite events once in one transaction; it never opens JSONL.
    /// Normal append/rewrite transactions maintain the same tables per file.
    pub(super) fn ensure_dashboard_aggregates(&mut self, codex_home: &Path) -> Result<(), String> {
        self.validate_dashboard_aggregate_compatibility()?;
        let stored_version =
            metadata_i64(&self.connection, DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)?;
        let published_generation =
            metadata_i64(&self.connection, "published_generation")?.unwrap_or(0);
        let aggregate_generation =
            metadata_i64(&self.connection, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?;
        let aggregate_published_generation = metadata_i64(
            &self.connection,
            DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY,
        )?;
        let aggregate_settled_through = metadata_i64(
            &self.connection,
            DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY,
        )?;
        let pricing_revision =
            metadata_text(&self.connection, DASHBOARD_AGGREGATE_PRICING_REVISION_KEY)?;
        let projection_matches = stored_version == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
            && aggregate_generation == Some(published_generation)
            && pricing_revision.as_deref() == Some(DASHBOARD_AGGREGATE_PRICING_REVISION)
            && dashboard_5m_projection_matches_published_files(
                &self.connection,
                published_generation,
            )?;
        if stored_version == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
            && aggregate_generation == Some(published_generation)
            && aggregate_published_generation == Some(published_generation)
            && aggregate_settled_through.is_some()
            && pricing_revision.as_deref() == Some(DASHBOARD_AGGREGATE_PRICING_REVISION)
            && projection_matches
        {
            return Ok(());
        }

        let event_count = self
            .connection
            .query_row("SELECT COUNT(*) FROM published_events", [], |row| {
                row.get::<_, i64>(0)
            })
            .map(nonnegative_u64)
            .map_err(|error| format!("无法统计待回填的仪表盘事件：{error}"))?;
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
            && aggregate_generation.is_some_and(|generation| {
                generation >= 0 && generation < published_generation
            });
        if can_repair_incrementally {
            incremental_rebuild_published_dashboard_aggregates(
                &transaction,
                aggregate_generation.unwrap_or(published_generation),
                published_generation,
            )?;
            if !dashboard_5m_projection_matches_published_files(
                &transaction,
                published_generation,
            )? {
                rebuild_published_dashboard_aggregates(&transaction)?;
            }
        } else if !projection_matches {
            rebuild_published_dashboard_aggregates(&transaction)?;
        }
        if !dashboard_5m_projection_matches_published_files(
            &transaction,
            published_generation,
        )? {
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
        Ok(())
    }

    fn validate_dashboard_aggregate_compatibility(&self) -> Result<(), String> {
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

    pub(super) fn dashboard_5m_projection_is_complete(&self) -> Result<bool, String> {
        let published_generation =
            metadata_i64(&self.connection, "published_generation")?.unwrap_or(0);
        dashboard_5m_projection_matches_published_files(
            &self.connection,
            published_generation,
        )
    }

    pub(super) fn latest_eligible_aggregate_boundary(now_utc: OffsetDateTime) -> i64 {
        let delayed = now_utc
            .unix_timestamp()
            .saturating_sub(AGGREGATE_BOUNDARY_GRACE_SECONDS);
        delayed - delayed.rem_euclid(FIVE_MINUTE_INTERVAL_SECONDS)
    }

    pub(super) fn mark_dashboard_aggregate_published(
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

    pub(super) fn dashboard_data(
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
            warnings,
        )
    }

    /// Read the complete dashboard with per-event system IANA local-day
    /// classification. UTC event timestamps and 5-minute aggregate rows are
    /// read-only; a timezone change only misses the disposable local view.
    pub(super) fn dashboard_data_with_system_timezone(
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
            warnings,
        )
    }

    fn dashboard_data_at(
        &self,
        codex_home: &Path,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
        local_day_mode: LocalDayMode,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Result<ExactDashboardData, String> {
        let dashboard_started = Instant::now();
        let settled_through = Self::latest_eligible_aggregate_boundary(now_utc);
        // The small temp published-files selector avoids copying every event,
        // but the view still reads main.events. Keep the complete dashboard in
        // one deferred WAL snapshot so a concurrent publisher cannot make the
        // totals, time series, and rankings observe different generations.
        let snapshot_transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|error| format!("无法开始精确 token 仪表盘读取事务：{error}"))?;
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
            self.usage_series_bundle(now_utc, local_offset, settled_through)?;
        let usage_series_ms = usage_series_started.elapsed().as_millis();

        let cache_ranking_started = Instant::now();
        let cache_hit_ranking = self.cache_hit_ranking(local_offset)?;
        let cache_ranking_ms = cache_ranking_started.elapsed().as_millis();

        let cache_usage_started = Instant::now();
        let cache_usage = self.cache_usage(codex_home, warnings)?;
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
        };
        snapshot_transaction
            .commit()
            .map_err(|error| format!("无法结束精确 token 仪表盘读取事务：{error}"))?;
        Ok(data)
    }

    #[cfg(test)]
    pub(super) fn dashboard_temp_object_types_for_testing(
        &self,
    ) -> Result<HashMap<String, String>, String> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT name, type FROM sqlite_temp_master WHERE name LIKE 'dashboard_%' OR name = 'published_events'",
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

    fn prepare_dashboard_event_snapshot(&self) -> Result<(), String> {
        self.connection
            .execute_batch(
                r#"
                DROP TABLE IF EXISTS temp.dashboard_session_rows;
                DROP VIEW IF EXISTS temp.published_dashboard_5m;
                DROP VIEW IF EXISTS temp.published_dashboard_file_5m;
                DROP VIEW IF EXISTS temp.published_dashboard_file_totals;
                DROP VIEW IF EXISTS temp.published_events;
                DROP TABLE IF EXISTS temp.published_files;
                -- Materialize only the small file-generation selector. The old
                -- path copied every published event into a temp table and built
                -- two temp indexes on every dashboard read. On a real 280k-event
                -- index that preparation alone took tens of seconds and could
                -- exhaust temp storage. A temp view keeps all aggregate reads on
                -- the durable main.events indexes without repeating the expensive
                -- published-files grouping.
                CREATE TEMP TABLE published_files AS
                SELECT *
                FROM main.published_files;
                CREATE UNIQUE INDEX published_files_path_snapshot_idx
                    ON published_files(path);
                CREATE TEMP VIEW published_events AS
                SELECT e.*
                FROM main.events e
                JOIN published_files f
                  ON f.generation = e.file_generation
                 AND f.path = e.file_path;

                CREATE TEMP VIEW published_dashboard_file_totals AS
                SELECT t.*
                FROM main.dashboard_file_totals t
                JOIN published_files f
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
                JOIN published_files f
                  ON f.generation = b.file_generation
                 AND f.path = b.file_path;

                -- Events are physically ordered by file generation/path. Fold
                -- them to one small row per file first, then join the published
                -- selector and group the roughly file-count-sized result by
                -- session. Grouping the published_events view directly makes
                -- SQLite revisit events once per file and spill every event into
                -- a session GROUP BY temp B-tree on large indexes.
                CREATE TEMP TABLE dashboard_session_rows AS
                WITH session_totals AS (
                    SELECT
                        f.session_id,
                        SUM(t.calls) AS calls,
                        SUM(t.total_tokens) AS total_tokens,
                        SUM(t.input_tokens) AS input_tokens,
                        SUM(t.cached_input_tokens) AS cached_tokens,
                        SUM(t.output_tokens) AS output_tokens,
                        MAX(t.last_timestamp) AS updated_at
                    FROM published_dashboard_file_totals t
                    JOIN published_files f
                      ON f.generation = t.file_generation
                     AND f.path = t.file_path
                    GROUP BY f.session_id
                ), logical_turns AS (
                    SELECT
                        session_id,
                        COUNT(*) AS calls
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
                    s.input_tokens,
                    s.cached_tokens,
                    s.output_tokens,
                    COALESCE(m.updated_at, s.updated_at) AS updated_at,
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
            .prepare(
                r#"
                SELECT
                    e.timestamp,
                    e.model,
                    e.tokens,
                    e.input_tokens,
                    e.cached_input_tokens,
                    e.output_tokens
                FROM published_events e
                WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                "#,
            )
            .map_err(|error| format!("无法准备 365 日精确 token 汇总：{error}"))?;
        let rows = statement
            .query_map(params![start_unix, end_unix], |row| {
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
            add_model_usage_breakdown(model_grouped.entry(date).or_default(), model, totals);
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
                        FROM published_events e
                        WHERE e.timestamp >= ?1 AND e.timestamp < ?2
                    ), 0),
                    COALESCE((
                        SELECT COUNT(*)
                        FROM published_events e
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
                    COALESCE(SUM(calls), 0)
                FROM published_dashboard_file_5m
                GROUP BY model_key
                "#,
            )
            .map_err(|error| format!("无法准备逐模型精确 token 总览：{error}"))?;
        let model_rows = model_statement
            .query_map([], |row| {
                Ok(ModelTokenBreakdown {
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

    fn usage_series_bundle(
        &self,
        now_utc: OffsetDateTime,
        local_offset: UtcOffset,
        settled_through: i64,
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
                    ModelTokenBreakdown {
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

        Ok((
            usage_series_from_five_minute(
                aggregate_anchor,
                local_offset,
                LONG_RECENT_INTERVAL_SECONDS,
                LONG_RECENT_POINT_COUNT,
                &grouped,
                &model_grouped,
                Some(&provenance_epoch),
                &source_grouped,
            ),
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
            WHERE calls > 0
              AND (?1 = 1 OR input_tokens >= ?2)
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
                    CACHE_USAGE_CANDIDATE_LIMIT
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
                turn_rows.user_prompt_start,
                turn_rows.user_prompt_end,
                turn_rows.assistant_response_start,
                turn_rows.assistant_response_end,
                turn_rows.turn_index AS turn_index_in_session,
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
                    CACHE_USAGE_CANDIDATE_LIMIT
                ],
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

pub(super) fn peek_startup_identity(
    codex_home: &Path,
) -> Result<Option<StartupIndexIdentity>, String> {
    let path = database_path(codex_home)?;
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

    let connection = sqlite::open_read_only(&path, StdDuration::from_millis(100))
        .map_err(|error| format!("无法只读打开精确 token 索引 {}：{error}", path.display()))?;
    let schema_version = required_startup_metadata_i64(&connection, "schema_version")?;
    if !(GITHUB_BASE_SCHEMA_VERSION..=INDEX_SCHEMA_VERSION).contains(&schema_version) {
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
        .is_some_and(|revision| revision != EXACT_SESSION_PARSER_REVISION)
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
    let expected_physical_identity = attribution_watch_root_physical_identity(&canonical_home)?;
    let stored_physical_identity =
        required_startup_metadata_text(&connection, "codex_home_physical_identity")?;
    if stored_physical_identity != expected_physical_identity {
        return Err("精确 token 启动缓存 Home physical identity 不匹配".into());
    }

    let revision = required_startup_metadata_u64(&connection, "revision")?;
    let dashboard_revision = optional_startup_metadata_u64(&connection, DASHBOARD_REVISION_KEY)?
        .unwrap_or(revision);
    let published_generation = required_startup_metadata_u64(&connection, "published_generation")?;
    let attribution_safety = startup_attribution_safety_state(&connection, published_generation)?;
    Ok(Some(StartupIndexIdentity {
        revision,
        dashboard_revision,
        published_generation,
        attribution_safety,
    }))
}

fn add_summary_file_row(
    contributions: &mut HashMap<String, SummaryFileContribution>,
    path: String,
    generation: i64,
    model: Option<String>,
    total: i64,
    today: i64,
    input: i64,
    cached: i64,
    output: i64,
    calls: i64,
) {
    let contribution = contributions
        .entry(path)
        .or_insert_with(|| SummaryFileContribution {
            generation,
            ..SummaryFileContribution::default()
        });
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
        contribution.today_model_breakdowns.push(ModelTokenBreakdown {
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
            let aggregate = model_breakdowns
                .entry(model.model.clone())
                .or_default();
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
        .map(|(model, breakdown)| ModelTokenBreakdown { model, breakdown })
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

fn startup_attribution_safety_state(
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

fn required_startup_metadata_text(connection: &Connection, key: &str) -> Result<String, String> {
    metadata_text(connection, key)?
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("精确 token 启动缓存索引元数据 {key} 缺失"))
}

fn required_startup_metadata_i64(connection: &Connection, key: &str) -> Result<i64, String> {
    let raw = required_startup_metadata_text(connection, key)?;
    raw.parse::<i64>()
        .map_err(|_| format!("精确 token 启动缓存索引元数据 {key} 无效"))
}

fn required_startup_metadata_u64(connection: &Connection, key: &str) -> Result<u64, String> {
    let raw = required_startup_metadata_text(connection, key)?;
    raw.parse::<u64>()
        .map_err(|_| format!("精确 token 启动缓存索引元数据 {key} 无效"))
}

fn optional_startup_metadata_u64(
    connection: &Connection,
    key: &str,
) -> Result<Option<u64>, String> {
    metadata_text(connection, key)?
        .map(|raw| {
            raw.parse::<u64>()
                .map_err(|_| format!("精确 token 启动缓存索引元数据 {key} 无效"))
        })
        .transpose()
}

fn startup_metadata_bool(connection: &Connection, key: &str) -> Result<bool, String> {
    match metadata_text(connection, key)?.as_deref() {
        None | Some("0") => Ok(false),
        Some("1") => Ok(true),
        Some(_) => Err(format!("精确 token 启动缓存索引元数据 {key} 无效")),
    }
}

fn format_precise_dashboard_phases(
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

fn add_model_usage_breakdown(
    grouped: &mut Vec<ModelTokenBreakdown>,
    model: Option<String>,
    totals: UsageBinTotals,
) {
    if let Some(existing) = grouped.iter_mut().find(|item| item.model == model) {
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
        grouped.push(ModelTokenBreakdown {
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
            add_model_usage_breakdown(target_breakdowns, breakdown.model.clone(), totals);
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
                    reasoning_output_tokens,
                    model,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
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
                    checked_i64(event.reasoning_output_tokens, "推理输出 token")?,
                    event.model,
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
                    reasoning_output_tokens,
                    model,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                "#,
                params![
                    checked_i64(self.ordinal, "暂存事件序号")?,
                    event.timestamp.unix_timestamp(),
                    checked_i64(event.tokens, "暂存 token 总数")?,
                    checked_i64(event.input_tokens, "暂存输入 token")?,
                    checked_i64(event.cached_input_tokens, "暂存缓存输入 token")?,
                    checked_i64(event.output_tokens, "暂存输出 token")?,
                    checked_i64(event.reasoning_output_tokens, "暂存推理输出 token")?,
                    event.model,
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
    migration_revision: String,
    parser_revision: String,
    target_building_generation: i64,
    artifact_id: String,
    actual_bytes: i64,
    integrity: String,
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
    is_explicit_subagent_fork: bool,
    last_skipped_fork_replay_token_ns: Option<String>,
    current_model: Option<String>,
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

fn encode_fingerprint(
    fingerprint: &UsageSnapshotFingerprint,
) -> [u8; USAGE_SNAPSHOT_FINGERPRINT_BYTES] {
    let mut encoded = [0_u8; USAGE_SNAPSHOT_FINGERPRINT_BYTES];
    for (index, value) in fingerprint.iter().enumerate() {
        let start = index * 8;
        encoded[start..start + 8].copy_from_slice(&value.to_le_bytes());
    }
    encoded
}

fn stage_full_rebuilds(
    jobs: &[FullRebuildJob],
    index_path: &Path,
    target_generation: i64,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    on_completed: Option<Arc<dyn Fn(u64) + Send + Sync>>,
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

    let completed = AtomicU64::new(0);
    let mut results = if ordered_jobs.len() == 1 {
        vec![stage_full_rebuild_result(
            0,
            &ordered_jobs[0],
            index_path,
            target_generation,
            codex_home,
            &completed,
            on_completed.as_deref(),
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
                        let result = stage_full_rebuild_result(
                            order,
                            job,
                            index_path,
                            target_generation,
                            codex_home,
                            &completed,
                            on_completed.as_deref(),
                        );
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
                    let result = stage_full_rebuild_result(
                        order,
                        job,
                        index_path,
                        target_generation,
                        codex_home,
                        &completed,
                        on_completed.as_deref(),
                    );
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
            Err(StagedFullRebuildError::IncompleteSource(error)) => {
                scan_completeness.mark_incomplete();
                warnings.push(scan_warning(format!(
                    "会话文件暂存读取不完整，本轮保留已有统计：{error}"
                )));
            }
            Err(StagedFullRebuildError::Fatal(error)) if first_error.is_none() => {
                first_error = Some(error);
            }
            Err(StagedFullRebuildError::Fatal(_)) => {}
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
    target_generation: i64,
    codex_home: &Path,
    completed: &AtomicU64,
    on_completed: Option<&(dyn Fn(u64) + Send + Sync)>,
) -> StagedFullRebuildResult {
    let mut warnings = Vec::new();
    let result = stage_or_reuse_full_rebuild(
        job,
        index_path,
        target_generation,
        codex_home,
        &mut warnings,
    );
    if result.is_ok() {
        let value = completed.fetch_add(1, Ordering::SeqCst).saturating_add(1);
        if let Some(on_completed) = on_completed {
            on_completed(value);
        }
    }
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
    job_count.min(resource_cap).min(STAGING_MAX_WORKERS)
}

fn staging_job_batches(jobs: &[FullRebuildJob]) -> Vec<Vec<FullRebuildJob>> {
    let mut ordered = jobs.to_vec();
    ordered.sort_by(|left, right| {
        right
            .signature
            .size
            .cmp(&left.signature.size)
            .then_with(|| left.path.cmp(&right.path))
    });
    let artifact_limit = STAGING_MAX_WORKERS.min(STAGING_MAX_READY_ARTIFACTS);
    let mut batches = Vec::new();
    let mut current = Vec::new();
    let mut current_bytes = 0_u64;
    for job in ordered {
        let oversized = job.signature.size > STAGING_MAX_READY_BYTES;
        let would_overflow = !current.is_empty()
            && current_bytes.saturating_add(job.signature.size) > STAGING_MAX_READY_BYTES;
        if oversized || current.len() >= artifact_limit || would_overflow {
            if !current.is_empty() {
                batches.push(std::mem::take(&mut current));
                current_bytes = 0;
            }
            if oversized {
                batches.push(vec![job]);
                continue;
            }
        }
        current_bytes = current_bytes.saturating_add(job.signature.size);
        current.push(job);
    }
    if !current.is_empty() {
        batches.push(current);
    }
    batches
}

#[cfg(test)]
pub(super) fn staging_batch_shape_for_testing(sizes: &[u64]) -> Vec<Vec<u64>> {
    let jobs = sizes
        .iter()
        .enumerate()
        .map(|(index, size)| FullRebuildJob {
            file: PathBuf::from(format!("/tmp/staging-batch-{index}.jsonl")),
            path: format!("/tmp/staging-batch-{index}.jsonl"),
            session_id: format!("staging-batch-{index}"),
            signature: FileSignature {
                size: *size,
                modified_ns: 0,
                identity: FileIdentity {
                    device_id: 1,
                    file_id: index as u64 + 1,
                },
                changed_ns: 0,
            },
            event_enrichment: false,
            expected_published_prefix_sha256: None,
        })
        .collect::<Vec<_>>();
    staging_job_batches(&jobs)
        .into_iter()
        .map(|batch| batch.into_iter().map(|job| job.signature.size).collect())
        .collect()
}

fn ensure_staging_capacity(index_path: &Path, estimated_bytes: u64) -> Result<(), String> {
    let probe = staging_directory(index_path);
    let probe = probe.parent().unwrap_or_else(|| Path::new("."));
    let free = available_space(probe).map_err(|error| {
        format!(
            "无法检查精确 token 暂存可用空间 {}：{error}",
            probe.display()
        )
    })?;
    let required = estimated_bytes.saturating_add(STAGING_MIN_FREE_RESERVE_BYTES);
    if free < required {
        return Err(format!(
            "精确 token 索引暂存磁盘空间不足：至少需要约 {} MiB，可用约 {} MiB；已保留上一份已发布统计，下次启动可继续",
            required.div_ceil(1024 * 1024),
            free / (1024 * 1024)
        ));
    }
    Ok(())
}

fn stage_or_reuse_full_rebuild(
    job: &FullRebuildJob,
    index_path: &Path,
    target_generation: i64,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<StagedFullRebuild, StagedFullRebuildError> {
    let database_path = staging_database_path(index_path, &job.path);
    if let Some(staged) = reusable_staged_full_rebuild(&database_path, job, target_generation)? {
        return Ok(staged);
    }
    build_staged_full_rebuild(job, database_path, target_generation, codex_home, warnings)
}

fn build_staged_full_rebuild(
    job: &FullRebuildJob,
    database_path: PathBuf,
    target_generation: i64,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<StagedFullRebuild, StagedFullRebuildError> {
    let _activity = StageActivityGuard::begin();
    remove_index_storage(&database_path)?;
    run_before_staging_open_hook_for_testing(&job.file);
    let mut handle = fs::File::open(&job.file).map_err(|error| {
        StagedFullRebuildError::IncompleteSource(format!(
            "读取精确 token 暂存源文件失败：{}（{}）",
            job.file.display(),
            error
        ))
    })?;
    let current_signature = file_signature_from_handle(&handle, &job.file)
        .map_err(StagedFullRebuildError::IncompleteSource)?;
    if current_signature.identity != job.signature.identity
        || current_signature.size < job.signature.size
    {
        return Err(StagedFullRebuildError::IncompleteSource(format!(
            "会话文件在进入并行暂存前被替换或截断，将在下一次刷新重试：{}",
            relative_display_path(codex_home, &job.file)
        )));
    }
    // The handle opened by this worker defines the formal scan boundary.  A
    // discovery signature is only a candidate hint and must never cap normal
    // source processing.  Historical enrichment is the one exception: when
    // it is reconciling an already-published prefix, keep that exact prefix so
    // the receipt can be compared to the old event set; the appended tail is
    // consumed by the following ordinary incremental cadence.
    let committed_signature =
        if job.event_enrichment && job.expected_published_prefix_sha256.is_some() {
            job.signature
        } else {
            current_signature
        };
    let artifact_id = Uuid::new_v4().to_string();
    let migration_revision = if job.event_enrichment {
        EVENT_ENRICHMENT_REVISION
    } else {
        "exact-source-rebuild-v1"
    };

    let staging_sync = prepare_staging_database_sync(&database_path)?;
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
        committed_signature.size,
        &job.session_id,
        &mut sink,
        warnings,
    )
    .map_err(StagedFullRebuildError::IncompleteSource)?;
    let event_count = sink.ordinal;
    drop(sink);
    #[cfg(test)]
    FULL_SCAN_BYTES.fetch_add(committed_signature.size, Ordering::SeqCst);
    run_after_prefix_scan_hook_for_testing(&job.file);

    if parsed.bytes_read != committed_signature.size {
        return Err(StagedFullRebuildError::IncompleteSource(format!(
            "会话文件固定前缀未完整扫描，将在下一次刷新重试：{}",
            relative_display_path(codex_home, &job.file)
        )));
    }
    validate_same_file_prefix(
        &job.file,
        &mut handle,
        committed_signature,
        parsed.prefix_sha256,
    )
    .map_err(|reason| {
        StagedFullRebuildError::IncompleteSource(format!(
            "会话文件在精确扫描期间发生非追加变化，将在下一次刷新重试：{}（{}）",
            relative_display_path(codex_home, &job.file),
            reason
        ))
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
    let state = parsed.state.clone();
    transaction
        .execute(
            r#"
            INSERT INTO manifest(
                complete,
                path,
                session_id,
                migration_revision,
                parser_revision,
                target_building_generation,
                artifact_id,
                actual_bytes,
                integrity,
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
                is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns,
                current_model,
                current_user_prompt_start,
                current_user_prompt_end,
                assistant_response_start,
                assistant_response_end,
                event_count,
                fingerprint_count,
                chunk_count
            ) VALUES (0, ?1, ?2, ?3, ?4, ?5, ?6, 0, '', ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26)
            "#,
            params![
                &job.path,
                &job.session_id,
                migration_revision,
                STAGED_FULL_REBUILD_PARSER_REVISION,
                target_generation,
                &artifact_id,
                checked_i64(committed_signature.size, "暂存会话文件大小")?,
                committed_signature.modified_ns.to_string(),
                committed_signature.identity.device_id.to_string(),
                committed_signature.identity.file_id.to_string(),
                committed_signature.changed_ns.to_string(),
                parsed.prefix_sha256.as_slice(),
                checked_i64(parsed.resume_offset, "暂存会话文件续扫位置")?,
                checked_optional_i64(state.previous_total_tokens, "暂存累计 token")?,
                timestamp_ns_text(state.fork_replay_started_at),
                state.fork_replay_active,
                state.is_explicit_subagent_fork,
                timestamp_ns_text(state.last_skipped_fork_replay_token_at),
                state.current_model,
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
    quick_check_index(&stage, None)?;

    let mut actual_bytes = fs::metadata(&database_path)
        .map_err(|error| format!("无法读取精确 token 暂存大小：{error}"))?
        .len();
    stage
        .execute(
            r#"
            UPDATE manifest
            SET complete = 1,
                actual_bytes = ?1,
                integrity = ?2
            WHERE complete = 0 AND artifact_id = ?3
            "#,
            params![
                checked_i64(actual_bytes, "暂存实际大小")?,
                STAGING_MANIFEST_INTEGRITY,
                &artifact_id,
            ],
        )
        .map_err(|error| format!("无法发布精确 token 暂存清单：{error}"))?;
    let final_bytes = fs::metadata(&database_path)
        .map_err(|error| format!("无法复核精确 token 暂存大小：{error}"))?
        .len();
    if final_bytes != actual_bytes {
        actual_bytes = final_bytes;
        stage
            .execute(
                "UPDATE manifest SET actual_bytes = ?1 WHERE complete = 1 AND artifact_id = ?2",
                params![checked_i64(actual_bytes, "暂存实际大小")?, &artifact_id],
            )
            .map_err(|error| format!("无法校准精确 token 暂存大小：{error}"))?;
    }
    drop(stage);
    sync_staging_database(&database_path, &staging_sync)?;

    Ok(StagedFullRebuild {
        job: FullRebuildJob {
            signature: committed_signature,
            ..job.clone()
        },
        committed_signature,
        database_path,
        artifact_id,
        actual_bytes,
        prefix_sha256: parsed.prefix_sha256,
        resume_offset: parsed.resume_offset,
        parser_state: parsed.state,
        event_count,
    })
}

#[cfg(windows)]
struct StagingDatabaseSyncHandle {
    file: fs::File,
}

#[cfg(not(windows))]
struct StagingDatabaseSyncHandle;

fn prepare_staging_database_sync(path: &Path) -> Result<StagingDatabaseSyncHandle, String> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_DELETE, FILE_SHARE_READ,
            FILE_SHARE_WRITE,
        };

        // Open the handle before SQLite starts using the database and retain it
        // until the final durability barrier. SQLite's Windows handle may use
        // a narrower share contract, so opening a second writable handle only
        // after commit can fail with ERROR_SHARING_VIOLATION.
        fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .access_mode(FILE_GENERIC_READ | FILE_GENERIC_WRITE)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .open(path)
            .map(|file| StagingDatabaseSyncHandle { file })
            .map_err(|error| format!("无法打开精确 token 暂存耐久句柄 {}：{error}", path.display()))
    }

    #[cfg(not(windows))]
    {
        let _ = path;
        Ok(StagingDatabaseSyncHandle)
    }
}

fn sync_staging_database(
    path: &Path,
    handle: &StagingDatabaseSyncHandle,
) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::FlushFileBuffers;

        let flushed = unsafe { FlushFileBuffers(handle.file.as_raw_handle() as _) };
        if flushed == 0 {
            return Err(format!(
                "无法同步精确 token 暂存文件：{}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }

    #[cfg(not(windows))]
    {
        let _ = handle;
        fs::OpenOptions::new()
            .read(true)
            .open(path)
            .and_then(|file| file.sync_all())
            .map_err(|error| format!("无法同步精确 token 暂存文件：{error}"))
    }
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
                complete INTEGER PRIMARY KEY CHECK(complete IN (0, 1)),
                path TEXT NOT NULL,
                session_id TEXT NOT NULL,
                migration_revision TEXT NOT NULL,
                parser_revision TEXT NOT NULL,
                target_building_generation INTEGER NOT NULL,
                artifact_id TEXT NOT NULL,
                actual_bytes INTEGER NOT NULL,
                integrity TEXT NOT NULL,
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
                is_explicit_subagent_fork INTEGER NOT NULL,
                last_skipped_fork_replay_token_ns TEXT,
                current_model TEXT,
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
                reasoning_output_tokens INTEGER NOT NULL,
                model TEXT,
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
    target_generation: i64,
) -> Result<Option<StagedFullRebuild>, String> {
    if !existing_regular_index(database_path)? {
        return Ok(None);
    }
    let reusable = (|| {
        let stage = sqlite::open_read_only(database_path, StdDuration::from_secs(1))
            .map_err(|error| format!("无法只读打开精确 token 单文件暂存：{error}"))?;
        validated_staged_full_rebuild(&stage, database_path, job, target_generation)
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
    target_generation: i64,
) -> Result<Option<StagedFullRebuild>, String> {
    quick_check_index(connection, None)?;
    let manifest = connection
        .query_row(
            r#"
            SELECT
                path,
                session_id,
                migration_revision,
                parser_revision,
                target_building_generation,
                artifact_id,
                actual_bytes,
                integrity,
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
                is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns,
                current_model,
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
                    migration_revision: row.get(2)?,
                    parser_revision: row.get(3)?,
                    target_building_generation: row.get(4)?,
                    artifact_id: row.get(5)?,
                    actual_bytes: row.get(6)?,
                    integrity: row.get(7)?,
                    size: row.get(8)?,
                    modified_ns: row.get(9)?,
                    device_id: row.get(10)?,
                    file_id: row.get(11)?,
                    changed_ns: row.get(12)?,
                    prefix_sha256: row.get(13)?,
                    resume_offset: row.get(14)?,
                    previous_total_tokens: row.get(15)?,
                    fork_replay_started_ns: row.get(16)?,
                    fork_replay_active: row.get(17)?,
                    is_explicit_subagent_fork: row.get(18)?,
                    last_skipped_fork_replay_token_ns: row.get(19)?,
                    current_model: row.get(20)?,
                    current_user_prompt_start: row.get(21)?,
                    current_user_prompt_end: row.get(22)?,
                    assistant_response_start: row.get(23)?,
                    assistant_response_end: row.get(24)?,
                    event_count: row.get(25)?,
                    fingerprint_count: row.get(26)?,
                    chunk_count: row.get(27)?,
                })
            },
        )
        .optional()
        .map_err(|error| format!("无法读取精确 token 单文件暂存清单：{error}"))?;
    let Some(manifest) = manifest else {
        return Ok(None);
    };
    let expected_migration_revision = if job.event_enrichment {
        EVENT_ENRICHMENT_REVISION
    } else {
        "exact-source-rebuild-v1"
    };
    let manifest_signature = match (
        u64::try_from(manifest.size),
        manifest.modified_ns.parse::<u128>(),
        manifest.device_id.parse::<u64>(),
        manifest.file_id.parse::<u64>(),
        manifest.changed_ns.parse::<i128>(),
    ) {
        (Ok(size), Ok(modified_ns), Ok(device_id), Ok(file_id), Ok(changed_ns)) => FileSignature {
            size,
            modified_ns,
            identity: FileIdentity { device_id, file_id },
            changed_ns,
        },
        _ => return Ok(None),
    };
    let artifact_bytes = fs::metadata(database_path)
        .map_err(|error| format!("无法复核精确 token 暂存文件大小：{error}"))?
        .len();
    if manifest.path != job.path
        || manifest.session_id != job.session_id
        || manifest.migration_revision != expected_migration_revision
        || manifest.parser_revision != STAGED_FULL_REBUILD_PARSER_REVISION
        || manifest.target_building_generation != target_generation
        || manifest.artifact_id.trim().is_empty()
        || manifest.integrity != STAGING_MANIFEST_INTEGRITY
        || manifest.actual_bytes < 0
        || nonnegative_u64(manifest.actual_bytes) != artifact_bytes
        || manifest_signature.identity != job.signature.identity
        || manifest_signature.size < job.signature.size
        || (job.event_enrichment
            && job.expected_published_prefix_sha256.is_some()
            && manifest_signature != job.signature)
        || manifest.size < 0
        || manifest.resume_offset < 0
        || nonnegative_u64(manifest.resume_offset) > manifest_signature.size
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
    let mut source_handle = match fs::File::open(&job.file) {
        Ok(handle) => handle,
        Err(_) => return Ok(None),
    };
    if validate_same_file_prefix(
        &job.file,
        &mut source_handle,
        manifest_signature,
        prefix_sha256,
    )
    .is_err()
    {
        return Ok(None);
    }
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
                EXISTS(SELECT 1 FROM fingerprints WHERE length(fingerprint) <> ?1),
                EXISTS(SELECT 1 FROM chunks WHERE length(sha256) <> 32)
            "#,
            params![USAGE_SNAPSHOT_FINGERPRINT_BYTES as i64],
            |row| Ok(row.get::<_, bool>(0)? || row.get::<_, bool>(1)?),
        )
        .map_err(|error| format!("无法验证精确 token 暂存哈希形状：{error}"))?;
    let expected_chunks = manifest_signature
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
        job: FullRebuildJob {
            signature: manifest_signature,
            ..job.clone()
        },
        committed_signature: manifest_signature,
        database_path: database_path.to_path_buf(),
        artifact_id: manifest.artifact_id,
        actual_bytes: artifact_bytes,
        prefix_sha256,
        resume_offset: nonnegative_u64(manifest.resume_offset),
        parser_state: ExactSessionParserState {
            previous_total_tokens: manifest.previous_total_tokens.map(nonnegative_u64),
            fork_replay_started_at,
            fork_replay_active: manifest.fork_replay_active,
            is_explicit_subagent_fork: manifest.is_explicit_subagent_fork,
            last_skipped_fork_replay_token_at,
            current_model: manifest.current_model,
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
    mode: ExactSyncMode,
) -> Result<(), String> {
    let validated = {
        let stage = sqlite::open_read_only(&staged.database_path, StdDuration::from_secs(1))
            .map_err(|error| format!("无法只读打开待导入的精确 token 暂存：{error}"))?;
        validated_staged_full_rebuild(&stage, &staged.database_path, &staged.job, generation)?
            .ok_or_else(|| "精确 token 单文件暂存在导入前失效".to_string())?
    };
    if validated.artifact_id != staged.artifact_id || validated.actual_bytes != staged.actual_bytes
    {
        return Err("精确 token 单文件暂存清单在导入前发生变化".into());
    }
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
        delete_file_version_rows(&transaction, generation, &validated.job.path)?;
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
                    reasoning_output_tokens,
                    model,
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
                    reasoning_output_tokens,
                    model,
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
        if mode.builds_dashboard_derived_data() {
            refresh_dashboard_file_aggregates(&transaction, generation, &validated.job.path)?;
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
        if validated.job.event_enrichment {
            transaction
                .execute(
                    r#"
                    INSERT INTO event_enrichment_sources(
                        path,
                        revision,
                        parser_revision,
                        device_id,
                        file_id,
                        file_generation,
                        completed_size,
                        completed_prefix_sha256
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    ON CONFLICT(path) DO UPDATE SET
                        revision = excluded.revision,
                        parser_revision = excluded.parser_revision,
                        device_id = excluded.device_id,
                        file_id = excluded.file_id,
                        file_generation = excluded.file_generation,
                        completed_size = excluded.completed_size,
                        completed_prefix_sha256 = excluded.completed_prefix_sha256
                    "#,
                    params![
                        &validated.job.path,
                        EVENT_ENRICHMENT_REVISION,
                        STAGED_FULL_REBUILD_PARSER_REVISION,
                        validated.committed_signature.identity.device_id.to_string(),
                        validated.committed_signature.identity.file_id.to_string(),
                        generation,
                        checked_i64(validated.committed_signature.size, "历史字段补全来源大小")?,
                        validated.prefix_sha256.as_slice(),
                    ],
                )
                .map_err(|error| format!("无法保存历史 model/reasoning 补全检查点：{error}"))?;
        }
        mark_dashboard_changed(&transaction)?;
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

fn staged_enrichment_matches_published_events(
    connection: &Connection,
    staged: &StagedFullRebuild,
) -> Result<bool, String> {
    let stage_path = staged.database_path.to_str().ok_or_else(|| {
        format!(
            "历史字段补全暂存路径不是有效 UTF-8：{}",
            staged.database_path.display()
        )
    })?;
    connection
        .execute(
            "ATTACH DATABASE ?1 AS exact_enrichment_compare",
            params![stage_path],
        )
        .map_err(|error| format!("无法附加历史字段补全暂存：{error}"))?;
    let comparison = connection
        .query_row(
            r#"
            SELECT NOT EXISTS(
                SELECT 1
                FROM main.events published
                JOIN main.published_files published_file
                  ON published_file.generation = published.file_generation
                 AND published_file.path = published.file_path
                LEFT JOIN exact_enrichment_compare.events staged
                  ON staged.ordinal = published.ordinal
                WHERE published.file_path = ?1
                  AND (
                    staged.ordinal IS NULL
                    OR staged.timestamp IS NOT published.timestamp
                    OR staged.tokens IS NOT published.tokens
                    OR staged.input_tokens IS NOT published.input_tokens
                    OR staged.cached_input_tokens IS NOT published.cached_input_tokens
                    OR staged.output_tokens IS NOT published.output_tokens
                  )
                UNION ALL
                SELECT 1
                FROM exact_enrichment_compare.events staged
                LEFT JOIN main.events published
                  ON published.file_path = ?1
                 AND published.ordinal = staged.ordinal
                 AND EXISTS (
                     SELECT 1
                     FROM main.published_files published_file
                     WHERE published_file.generation = published.file_generation
                       AND published_file.path = published.file_path
                 )
                WHERE published.ordinal IS NULL
                LIMIT 1
            )
            "#,
            params![&staged.job.path],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法核对历史 model/reasoning 补全事件：{error}"));
    let detach = connection
        .execute_batch("DETACH DATABASE exact_enrichment_compare")
        .map_err(|error| format!("无法卸载历史字段补全暂存：{error}"));
    match (comparison, detach) {
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Ok(matches), Ok(())) => Ok(matches),
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

type Dashboard5mProjectionSignature = (
    i64,
    Option<i64>,
    Option<i64>,
    i64,
    i64,
    i64,
    i64,
    i64,
);

fn dashboard_5m_projection_matches_published_files(
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

fn begin_or_resume_generation(
    connection: &mut Connection,
    mode: ExactSyncMode,
) -> Result<i64, String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始精确 token 同步状态事务：{error}"))?;
    let published = metadata_i64(&transaction, "published_generation")?.unwrap_or(0);
    let aggregate_source_generation = if metadata_i64(
        &transaction,
        DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY,
    )? == Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
    {
        metadata_i64(&transaction, DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)?
            .filter(|generation| *generation >= 0 && *generation <= published)
            .unwrap_or(published)
    } else {
        published
    };
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
    if mode.builds_dashboard_derived_data() {
        transaction
            .execute(
                "DELETE FROM dashboard_5m WHERE file_generation = ?1",
                params![generation],
            )
            .map_err(|error| format!("无法清理新一轮全局五分钟聚合：{error}"))?;
        transaction
            .execute(
                "DELETE FROM dashboard_turn_candidates WHERE aggregate_generation = ?1",
                params![generation],
            )
            .map_err(|error| format!("无法清理新一轮轮次候选聚合：{error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO dashboard_5m(
                    file_generation, bucket_start, model_key, model,
                    total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
                )
                SELECT
                    ?1, bucket_start, model_key, model,
                    total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
                FROM dashboard_5m
                WHERE file_generation = ?2
                "#,
                params![generation, aggregate_source_generation],
            )
            .map_err(|error| format!("无法复制已发布全局五分钟聚合：{error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO dashboard_turn_candidates(
                    aggregate_generation, event_id, source_file_generation,
                    file_path, ordinal, timestamp, session_id,
                    total_tokens, input_tokens, cached_input_tokens, output_tokens,
                    user_prompt_start, user_prompt_end,
                    assistant_response_start, assistant_response_end,
                    turn_index, session_calls
                )
                SELECT
                    ?1, event_id, source_file_generation,
                    file_path, ordinal, timestamp, session_id,
                    total_tokens, input_tokens, cached_input_tokens, output_tokens,
                    user_prompt_start, user_prompt_end,
                    assistant_response_start, assistant_response_end,
                    turn_index, session_calls
                FROM dashboard_turn_candidates
                WHERE aggregate_generation = ?2
                "#,
                params![generation, aggregate_source_generation],
            )
            .map_err(|error| format!("无法复制已发布轮次候选聚合：{error}"))?;
    }
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
                JOIN touched t ON t.path = b.file_path
                WHERE b.file_generation = (
                    SELECT MAX(previous.generation)
                    FROM files previous
                    WHERE previous.path = b.file_path
                      AND previous.generation <= ?2
                      AND previous.deleted = 0
                )
                UNION ALL
                SELECT e.timestamp - (e.timestamp % 300)
                FROM events e
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
            "DELETE FROM dashboard_5m WHERE file_generation = ?1",
            params![generation],
        )
        .map_err(|error| format!("无法清理增量仪表盘五分钟聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_5m(
                file_generation, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT
                ?1, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_5m
            WHERE file_generation = ?2
            "#,
            params![generation, previous_generation],
        )
        .map_err(|error| format!("无法复制已发布增量五分钟聚合：{error}"))?;

    transaction
        .execute(
            "DELETE FROM dashboard_turn_candidates WHERE aggregate_generation = ?1",
            params![generation],
        )
        .map_err(|error| format!("无法清理增量轮次候选聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_turn_candidates(
                aggregate_generation, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            )
            SELECT
                ?1, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            FROM dashboard_turn_candidates
            WHERE aggregate_generation = ?2
            "#,
            params![generation, previous_generation],
        )
        .map_err(|error| format!("无法复制已发布增量轮次候选聚合：{error}"))?;

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
            FROM events e
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
            FROM events e
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

    transaction
        .execute(
            "DELETE FROM dashboard_5m WHERE file_generation <> ?1",
            params![generation],
        )
        .map_err(|error| format!("无法清理旧版增量五分钟聚合：{error}"))?;
    transaction
        .execute(
            "DELETE FROM dashboard_turn_candidates WHERE aggregate_generation <> ?1",
            params![generation],
        )
        .map_err(|error| format!("无法清理旧版增量轮次候选聚合：{error}"))?;
    Ok(())
}

fn mark_dashboard_changed(transaction: &Transaction<'_>) -> Result<(), String> {
    set_metadata(transaction, "building_changed", "1")?;
    set_metadata(transaction, BUILDING_DASHBOARD_CHANGED_KEY, "1")
}

fn rebuild_published_dashboard_aggregates(transaction: &Transaction<'_>) -> Result<(), String> {
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
            FROM events e
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
            FROM events e
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
                    MIN(e.user_prompt_start) AS user_prompt_start,
                    MAX(e.user_prompt_end) AS user_prompt_end,
                    MIN(e.assistant_response_start) AS assistant_response_start,
                    MAX(e.assistant_response_end) AS assistant_response_end
                FROM events e
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
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            )
            SELECT
                ?1, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
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

fn refresh_dashboard_file_aggregates(
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
            FROM events
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
            FROM events
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

fn refresh_dashboard_turn_candidates_for_changed_generations(
    transaction: &Transaction<'_>,
    generation: i64,
    previous_generation: i64,
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
            params![generation, previous_generation],
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
                    MIN(e.user_prompt_start) AS user_prompt_start,
                    MAX(e.user_prompt_end) AS user_prompt_end,
                    MIN(e.assistant_response_start) AS assistant_response_start,
                    MAX(e.assistant_response_end) AS assistant_response_end
                FROM events e
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
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            )
            SELECT
                ?1, event_id, source_file_generation,
                file_path, ordinal, timestamp, session_id,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                user_prompt_start, user_prompt_end,
                assistant_response_start, assistant_response_end,
                turn_index, session_calls
            FROM ranked
            "#,
            params![generation, previous_generation],
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

fn refresh_dashboard_5m_range(
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
            WHERE b.bucket_start BETWEEN ?2 AND ?3
            GROUP BY b.bucket_start, b.model_key
            "#,
            params![generation, start, end],
        )
        .map(|_| ())
        .map_err(|error| format!("无法更新全局五分钟聚合范围：{error}"))
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

fn update_dashboard_append_aggregates(
    transaction: &Transaction<'_>,
    generation: i64,
    path: &str,
    previous_ordinal: u64,
) -> Result<(), String> {
    let existing = transaction
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM dashboard_file_totals WHERE file_generation = ?1 AND file_path = ?2)",
            params![generation, path],
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
            FROM events
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
            INSERT INTO dashboard_file_totals(
                file_generation, file_path, session_id, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens,
                first_timestamp, last_timestamp
            )
            SELECT
                file_generation, file_path, MAX(session_id), SUM(tokens), COUNT(*),
                SUM(input_tokens), SUM(MIN(cached_input_tokens, input_tokens)),
                SUM(output_tokens), MIN(timestamp), MAX(timestamp)
            FROM events
            WHERE file_generation = ?1 AND file_path = ?2 AND ordinal > ?3
            GROUP BY file_generation, file_path
            ON CONFLICT(file_generation, file_path) DO UPDATE SET
                total_tokens = dashboard_file_totals.total_tokens + excluded.total_tokens,
                calls = dashboard_file_totals.calls + excluded.calls,
                input_tokens = dashboard_file_totals.input_tokens + excluded.input_tokens,
                cached_input_tokens = dashboard_file_totals.cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = dashboard_file_totals.output_tokens + excluded.output_tokens,
                first_timestamp = MIN(dashboard_file_totals.first_timestamp, excluded.first_timestamp),
                last_timestamp = MAX(dashboard_file_totals.last_timestamp, excluded.last_timestamp)
            "#,
            params![generation, path, previous_ordinal],
        )
        .map_err(|error| format!("无法更新单文件增量总量聚合：{error}"))?;
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
            FROM events
            WHERE file_generation = ?1 AND file_path = ?2 AND ordinal > ?3
            GROUP BY file_generation, file_path, timestamp - (timestamp % 300), COALESCE(model, '')
            ON CONFLICT(file_generation, file_path, bucket_start, model_key) DO UPDATE SET
                total_tokens = dashboard_file_5m.total_tokens + excluded.total_tokens,
                calls = dashboard_file_5m.calls + excluded.calls,
                input_tokens = dashboard_file_5m.input_tokens + excluded.input_tokens,
                cached_input_tokens = dashboard_file_5m.cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = dashboard_file_5m.output_tokens + excluded.output_tokens,
                model = excluded.model
            "#,
            params![generation, path, previous_ordinal],
        )
        .map_err(|error| format!("无法更新单文件增量五分钟聚合：{error}"))?;
    if let Some((start, end)) = affected_bounds {
        refresh_dashboard_5m_range(transaction, generation, start, end)?;
    }
    Ok(())
}

fn copy_dashboard_file_aggregates(
    transaction: &Transaction<'_>,
    generation: i64,
    checkpoint_generation: i64,
    path: &str,
) -> Result<(), String> {
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_file_totals(
                file_generation, file_path, session_id, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens,
                first_timestamp, last_timestamp
            )
            SELECT ?1, file_path, session_id, total_tokens, calls,
                input_tokens, cached_input_tokens, output_tokens,
                first_timestamp, last_timestamp
            FROM dashboard_file_totals
            WHERE file_generation = ?2 AND file_path = ?3
            "#,
            params![generation, checkpoint_generation, path],
        )
        .map_err(|error| format!("无法复制单文件总量聚合：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO dashboard_file_5m(
                file_generation, file_path, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            )
            SELECT ?1, file_path, bucket_start, model_key, model,
                total_tokens, calls, input_tokens, cached_input_tokens, output_tokens
            FROM dashboard_file_5m
            WHERE file_generation = ?2 AND file_path = ?3
            "#,
            params![generation, checkpoint_generation, path],
        )
        .map_err(|error| format!("无法复制单文件五分钟聚合：{error}"))?;
    Ok(())
}

fn backfill_missing_dashboard_aggregates_for_generation(
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
            FROM events e
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
            FROM events e
            WHERE e.file_generation = ?1
            GROUP BY e.file_generation, e.file_path,
                e.timestamp - (e.timestamp % 300), COALESCE(e.model, '')
            ON CONFLICT(file_generation, file_path, bucket_start, model_key) DO NOTHING
            "#,
            params![generation],
        )
        .map_err(|error| format!("无法补齐本轮单文件五分钟聚合：{error}"))?;
    if inserted_totals > 0 || inserted_buckets > 0 {
        rebuild_dashboard_5m_generation(transaction, generation)?;
    }
    Ok(())
}

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
        let missing_dashboard_bounds = transaction
            .query_row(
                r#"
                WITH latest AS (
                    SELECT path, MAX(generation) AS generation
                    FROM files
                    WHERE generation <= ?1
                    GROUP BY path
                ),
                missing AS (
                    SELECT latest.path, latest.generation
                    FROM latest
                    JOIN files f
                      ON f.path = latest.path
                     AND f.generation = latest.generation
                    WHERE f.deleted = 0
                      AND NOT EXISTS (
                          SELECT 1 FROM exact_seen_files seen WHERE seen.path = latest.path
                      )
                )
                SELECT MIN(b.bucket_start), MAX(b.bucket_start)
                FROM dashboard_file_5m b
                JOIN missing m
                  ON m.path = b.file_path
                 AND m.generation = b.file_generation
                "#,
                params![generation],
                |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
            )
            .map(|(start, end)| start.zip(end))
            .map_err(|error| format!("无法读取已删除会话的聚合范围：{error}"))?;
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
        if mode.builds_dashboard_derived_data() {
            if let Some((start, end)) = missing_dashboard_bounds {
            refresh_dashboard_5m_range(&transaction, generation, start, end)?;
            }
        }
        mark_dashboard_changed(&transaction)?;
    }

    if mode.builds_dashboard_derived_data() && sync_thread_metadata(&transaction, codex_home, warnings)? {
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
    let rotate_attribution_provenance =
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
    let _current_scan_unsafe_cause_detected = if mode.builds_dashboard_derived_data()
        || run_migrations
        || source_index_changed
    {
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
            ledger_integrity_mismatch,
        )? {
            mark_dashboard_changed(&transaction)?;
        }
        let provenance_epoch = metadata_text(&transaction, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| "精确 token 来源谱系标识缺失".to_string())?;
        if rotate_for_new_unsafe_incident {
            set_metadata(&transaction, ATTRIBUTION_UNSAFE_EPOCH_KEY, &provenance_epoch)?;
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
            metadata_i64(&transaction, ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY)?.unwrap_or(0) != 0;
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
    let changed = metadata_i64(&transaction, "building_changed")?.unwrap_or(0) != 0;
    let dashboard_changed =
        metadata_i64(&transaction, BUILDING_DASHBOARD_CHANGED_KEY)?.unwrap_or(0) != 0;
    let current_revision = metadata_i64(&transaction, "revision")?.unwrap_or(0);
    let revision = if changed {
        if dashboard_changed {
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
    if mode.builds_dashboard_derived_data()
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
    transaction
        .commit()
        .map_err(|error| format!("无法原子发布完整精确 token 代次：{error}"))?;
    Ok(u64::try_from(revision).unwrap_or(0))
}

fn visible_duplicate_session_lineage(
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

fn attribution_ledger_integrity_mismatch(connection: &Connection) -> Result<bool, String> {
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
fn synchronize_attribution_ledger(
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
        FROM events e
        JOIN visible_files f
          ON f.generation = e.file_generation
         AND f.path = e.file_path
        GROUP BY 1, 2
        ORDER BY 1, 2
    "#;
    let incremental_query = r#"
        SELECT
            timestamp - (timestamp % ?2),
            session_id,
            COALESCE(SUM(tokens), 0),
            COUNT(*),
            COALESCE(SUM(input_tokens), 0),
            COALESCE(SUM(MIN(cached_input_tokens, input_tokens)), 0),
            COALESCE(SUM(output_tokens), 0)
        FROM events
        WHERE file_generation = ?1
        GROUP BY 1, 2
        ORDER BY 1, 2
    "#;
    let mut source_rows = transaction
        .prepare(if rebuild {
            full_query
        } else {
            incremental_query
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
                tokens = MAX(tokens, excluded.tokens),
                calls = MAX(calls, excluded.calls),
                input_tokens = MAX(input_tokens, excluded.input_tokens),
                cached_input_tokens = MAX(cached_input_tokens, excluded.cached_input_tokens),
                output_tokens = MAX(output_tokens, excluded.output_tokens)
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
    set_metadata(transaction, ATTRIBUTION_LEDGER_EPOCH_KEY, &provenance_epoch)?;
    set_metadata(
        transaction,
        ATTRIBUTION_LEDGER_INTEGRITY_KEY,
        &attribution_ledger_integrity(transaction, &provenance_epoch)?,
    )?;
    Ok(rebuild || wrote_rows)
}

fn attribution_ledger_integrity(
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

#[allow(clippy::too_many_arguments)]
fn process_scan_file_with_progress(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    full_rebuild_jobs: &mut Vec<FullRebuildJob>,
    scanned_files: &mut u64,
    scanned_paths: &mut HashSet<PathBuf>,
    scan_total: Option<u64>,
    diagnostics: &mut ExactScanDiagnostics,
    expected_signature: Option<FileSignature>,
    mode: ExactSyncMode,
) -> Result<(), String> {
    let canonical = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    if !scanned_paths.insert(canonical) {
        return Ok(());
    }
    if let Some(job) = process_session_file(
        connection,
        generation,
        codex_home,
        file,
        warnings,
        scan_completeness,
        diagnostics,
        expected_signature,
        mode,
    )? {
        full_rebuild_jobs.push(job);
    }
    *scanned_files = (*scanned_files).saturating_add(1);
    super::update_precise_dashboard_progress(
        codex_home,
        "scanning",
        "正在扫描精确历史；首次建立索引可能需要数分钟",
        *scanned_files,
        scan_total,
    );
    Ok(())
}

fn process_session_file(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    diagnostics: &mut ExactScanDiagnostics,
    expected_signature: Option<FileSignature>,
    mode: ExactSyncMode,
) -> Result<Option<FullRebuildJob>, String> {
    let canonical = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    let path = canonical.to_string_lossy().into_owned();

    // 单个文件不可读（权限/锁定/iCloud 占位）属持久性错误：整轮报错会让 building
    // 滞留、后台无限重试且 dashboard 永不刷新。删除已经明确发生时不写入
    // exact_seen_files，让本轮正式发布安全登记删除墓碑；其他不可读错误仍抑制
    // 墓碑，保留旧统计待自愈。
    let mut handle = match fs::File::open(file) {
        Ok(handle) => handle,
        Err(error) => {
            // The discovery list is intentionally allowed to become stale.
            // A candidate that disappears before the durable pass is handled
            // by the normal missing-file/tombstone reconciliation on publish;
            // it is not an incomplete scan or an unsafe attribution incident.
            if error.kind() == std::io::ErrorKind::NotFound {
                return Ok(None);
            }
            connection
                .execute(
                    "INSERT OR IGNORE INTO exact_seen_files(path) VALUES (?1)",
                    params![&path],
                )
                .map_err(|error| format!("无法记录会话文件扫描状态：{error}"))?;
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取会话文件失败，本轮跳过该文件：{}（{}）",
                file.display(),
                error
            )));
            return Ok(None);
        }
    };
    let signature = match file_signature_from_handle(&handle, file) {
        Ok(signature) => signature,
        Err(error) => {
            connection
                .execute(
                    "INSERT OR IGNORE INTO exact_seen_files(path) VALUES (?1)",
                    params![&path],
                )
                .map_err(|error| format!("无法记录会话文件扫描状态：{error}"))?;
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取会话文件身份失败，本轮跳过该文件：{}（{}）",
                file.display(),
                error
            )));
            return Ok(None);
        }
    };
    // A discovery candidate is only a hint.  Its signature may legitimately
    // be older than the one observed here because the session appended while
    // the durable pass was waiting or processing another candidate.  The
    // current signature is authoritative; process_session_file below decides
    // append versus rewrite from the persisted checkpoint and prefix audit.
    if expected_signature.is_some_and(|expected| expected != signature) {
        diagnostics.source_drift = true;
    }
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
    let previous_signature = connection
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
        .map_err(|error| format!("无法读取会话文件索引签名：{error}"))?;
    let had_existing_source = previous_signature
        .as_ref()
        .is_some_and(|(deleted, ..)| !deleted);
    let unchanged = previous_signature.as_ref().is_some_and(
        |(deleted, size, modified_ns, device_id, file_id, changed_ns)| {
            !deleted
                && signature.matches_stored(
                    nonnegative_u64(*size),
                    modified_ns,
                    device_id,
                    file_id,
                    changed_ns,
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
                diagnostics,
                mode,
            )?
        {
            return Ok(None);
        }
    }

    // A previously published source that cannot be proven as a pure append may
    // have reordered or replaced events. Rotate only when this generation is
    // atomically published; new files and deletions keep the current lineage.
    if had_existing_source {
        set_metadata(connection, BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY, "1")?;
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
            diagnostics,
        )?;
        return Ok(None);
    }

    Ok(Some(FullRebuildJob {
        file: canonical,
        path,
        session_id: session_id_from_file(file),
        signature,
        event_enrichment: false,
        expected_published_prefix_sha256: None,
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
    diagnostics: &mut ExactScanDiagnostics,
) -> Result<(), String> {
    diagnostics.full_rebuild_files = diagnostics.full_rebuild_files.saturating_add(1);
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始单文件精确 token 索引事务：{error}"))?;
    ensure_active_build_generation(&transaction, generation)?;
    delete_file_version_rows(&transaction, generation, path)?;
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
    diagnostics.full_body_bytes = diagnostics.full_body_bytes.saturating_add(signature.size);
    diagnostics.pending_tail_bytes = diagnostics
        .pending_tail_bytes
        .saturating_add(signature.size.saturating_sub(parsed.resume_offset));
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
    mark_dashboard_changed(&transaction)?;
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
                is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns,
                current_model,
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
                let is_explicit_subagent_fork = row.get::<_, bool>(8)?;
                let last_skipped_fork_replay_token_at =
                    parse_timestamp_ns(row.get::<_, Option<String>>(9)?);
                let current_model = row.get::<_, Option<String>>(10)?;
                let current_user_prompt = source_range_from_columns(
                    row.get::<_, Option<i64>>(11)?,
                    row.get::<_, Option<i64>>(12)?,
                );
                let assistant_response = source_range_from_columns(
                    row.get::<_, Option<i64>>(13)?,
                    row.get::<_, Option<i64>>(14)?,
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
                        is_explicit_subagent_fork,
                        last_skipped_fork_replay_token_at,
                        current_model,
                        current_user_prompt,
                        assistant_response,
                    },
                    audit_chunk_index: nonnegative_u64(row.get::<_, i64>(15)?),
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
    diagnostics: &mut ExactScanDiagnostics,
    mode: ExactSyncMode,
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
    // The parser state is valid at resume_offset (the start of the last
    // complete line or the unfinished tail).  Hash from the containing chunk
    // boundary, then skip to resume_offset for parsing.  This keeps prefix
    // validation chunk-aligned without rebuilding the whole file when an
    // unfinished JSON line crosses the old tail chunk boundary.
    let resume_chunk = checkpoint.resume_offset / EXACT_INDEX_CHUNK_SIZE;
    // At an exact chunk boundary, the previous chunk is the last committed
    // chunk and is still needed for validation_chunk_hash.  Treat the
    // boundary as belonging to that previous chunk for hashing purposes while
    // keeping parsing at the persisted resume offset.
    let hashing_start_chunk =
        if checkpoint.resume_offset > 0 && checkpoint.resume_offset % EXACT_INDEX_CHUNK_SIZE == 0 {
            resume_chunk.saturating_sub(1)
        } else {
            resume_chunk
        };
    let hashing_start_offset = hashing_start_chunk.saturating_mul(EXACT_INDEX_CHUNK_SIZE);

    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始单文件追加索引事务：{error}"))?;
    ensure_active_build_generation(&transaction, generation)?;
    // 中断恢复会复用同一 building 代次（begin_or_resume_generation）：此时追加检查点
    // 行就在本代次内，先删本代次行再从同代次 INSERT SELECT 会把源行连同级联的
    // events/指纹/分块一起删掉（copied == 0），追加被迫退化为整文件重扫。同代次
    // 直接基于既有行续扫，收尾由 save_file_checkpoint 覆盖检查点。
    if checkpoint.generation != generation
        && !copy_append_checkpoint_rows(
            &transaction,
            generation,
            checkpoint.generation,
            path,
            mode,
        )?
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
    let aggregate_ordinal = ordinal;

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
        checkpoint.parser_state.clone(),
        &session_id,
        &mut sink,
        warnings,
    )?;
    #[cfg(test)]
    APPEND_SCAN_BYTES.fetch_add(
        signature.size.saturating_sub(hashing_start_offset),
        Ordering::SeqCst,
    );
    diagnostics.append_scan_bytes = diagnostics
        .append_scan_bytes
        .saturating_add(signature.size.saturating_sub(hashing_start_offset));
    diagnostics.pending_tail_bytes = diagnostics
        .pending_tail_bytes
        .saturating_add(signature.size.saturating_sub(parsed.resume_offset));
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
        hashing_start_chunk,
        &parsed.chunk_hashes,
    )?;
    if mode.builds_dashboard_derived_data() {
        update_dashboard_append_aggregates(&transaction, generation, path, aggregate_ordinal)?;
    }
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
    mark_dashboard_changed(&transaction)?;
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
    mode: ExactSyncMode,
) -> Result<bool, String> {
    delete_file_version_rows(transaction, generation, path)?;
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
                is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns,
                current_model,
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
                is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns,
                current_model,
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
                reasoning_output_tokens,
                model,
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
                reasoning_output_tokens,
                model,
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
    if mode.builds_dashboard_derived_data() {
        copy_dashboard_file_aggregates(transaction, generation, checkpoint_generation, path)?;
    }
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
                is_explicit_subagent_fork = ?12,
                last_skipped_fork_replay_token_ns = ?13,
                current_model = ?14,
                current_user_prompt_start = ?15,
                current_user_prompt_end = ?16,
                assistant_response_start = ?17,
                assistant_response_end = ?18,
                audit_chunk_index = ?19
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
                state.is_explicit_subagent_fork,
                timestamp_ns_text(state.last_skipped_fork_replay_token_at),
                state.current_model,
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
    scan_completeness: &mut ExactScanCompleteness,
    mut visit: impl FnMut(
        &mut Connection,
        &Path,
        &mut Vec<LocalDataWarning>,
        &mut ExactScanCompleteness,
    ) -> Result<(), String>,
) -> Result<(), String> {
    super::record_dashboard_source_scan_for_testing();
    let canonical_home = canonical_codex_home(codex_home)?;
    let canonical_sessions_root = canonical_home.join("sessions");
    let sessions_root = codex_home.join("sessions");
    let archived_sessions_root = codex_home.join("archived_sessions");
    if sessions_root.exists() || archived_sessions_root.exists() {
        if sessions_root.is_dir() {
            enqueue_directory(
                connection,
                &canonical_home,
                &sessions_root,
                warnings,
                scan_completeness,
            )?;
        } else {
            scan_completeness.block_publish();
            warnings.push(scan_warning(format!(
                "会话目录不存在：{}",
                sessions_root.display()
            )));
            suppress_missing_tombstones_under(connection, &sessions_root)?;
        }
        if archived_sessions_root.exists() {
            enqueue_directory(
                connection,
                &canonical_home,
                &archived_sessions_root,
                warnings,
                scan_completeness,
            )?;
        }
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
            // 单个目录/条目不可读属持久性错误，整轮报错会让 building 滞留且每轮
            // 复现。降级为警告并跳过；跳过前把未真正扫描到的已索引路径补进
            // exact_seen_files，抑制 finalize 的删除墓碑（宁可沿用旧统计，不可误删）。
            let entries = match fs::read_dir(&directory) {
                Ok(entries) => entries,
                Err(error) => {
                    if directory == canonical_sessions_root {
                        scan_completeness.block_publish();
                    } else {
                        scan_completeness.mark_incomplete();
                    }
                    warnings.push(scan_warning(format!(
                        "读取会话目录失败，本轮跳过该目录：{}（{}）",
                        directory.display(),
                        error
                    )));
                    suppress_missing_tombstones_under(connection, &directory)?;
                    continue;
                }
            };
            for entry in entries {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(error) => {
                        scan_completeness.mark_incomplete();
                        warnings.push(scan_warning(format!(
                            "读取会话目录项失败，本轮跳过该目录剩余条目：{}（{}）",
                            directory.display(),
                            error
                        )));
                        suppress_missing_tombstones_under(connection, &directory)?;
                        break;
                    }
                };
                let path = entry.path();
                let metadata = match fs::symlink_metadata(&path) {
                    Ok(metadata) => metadata,
                    Err(error) => {
                        scan_completeness.mark_incomplete();
                        warnings.push(scan_warning(format!(
                            "读取会话目录项元数据失败，本轮跳过该条目：{}（{}）",
                            path.display(),
                            error
                        )));
                        suppress_missing_tombstones_under(connection, &path)?;
                        continue;
                    }
                };
                if metadata.file_type().is_dir() {
                    enqueue_directory(
                        connection,
                        &canonical_home,
                        &path,
                        warnings,
                        scan_completeness,
                    )?;
                } else if path
                    .extension()
                    .is_some_and(|extension| extension == "jsonl")
                {
                    if let Some(file) =
                        resolve_file_within_codex_home(&canonical_home, &path, "会话目录", warnings)
                    {
                        visit(connection, &file, warnings, scan_completeness)?;
                    } else {
                        scan_completeness.mark_incomplete();
                    }
                }
            }
        }
    } else {
        scan_completeness.block_publish();
        warnings.push(scan_warning(format!(
            "会话目录不存在：{}",
            sessions_root.display()
        )));
        suppress_missing_tombstones_under(connection, &sessions_root)?;
        suppress_missing_tombstones_under(connection, &archived_sessions_root)?;
    }

    visit_active_rollouts(
        connection,
        codex_home,
        &canonical_home,
        warnings,
        scan_completeness,
        visit,
    )
}

/// 把 root（文件或目录）下所有已索引路径补进 exact_seen_files：不可读条目本轮
/// 未真正扫描，finalize_generation 不得把它们当作已删除的会话打墓碑。
fn suppress_missing_tombstones_under(connection: &Connection, root: &Path) -> Result<(), String> {
    let exact = root.to_string_lossy().into_owned();
    // 前缀比较用 substr 而非 LIKE：路径里的 % 与 _ 不能被当作通配符。
    let prefix = format!("{exact}/");
    connection
        .execute(
            r#"
            INSERT OR IGNORE INTO exact_seen_files(path)
            SELECT DISTINCT path FROM files
            WHERE path = ?1 OR substr(path, 1, length(?2)) = ?2
            "#,
            params![exact, prefix],
        )
        .map(|_| ())
        .map_err(|error| format!("无法抑制不可读会话条目的删除墓碑：{error}"))
}

/// Performs a read-only candidate discovery for the progress UI and the
/// immediately following durable scan.
///
/// This deliberately does not open the exact index, touch any temporary scan
/// tables, or participate in generation/fingerprint/tombstone decisions. The
/// durable scanner remains the sole source of truth; this plan may become
/// stale while files are being created, removed, or rewritten. Directory
/// metadata is retained for diagnostics, but never decides whether the
/// durable scanner may consume the candidate list.
pub(super) fn estimate_precise_scan_total(
    codex_home: &Path,
    timeout: StdDuration,
) -> Result<PreciseScanDiscovery, String> {
    estimate_precise_scan_total_with_source_revision(codex_home, timeout, 0)
}

pub(super) fn estimate_precise_scan_total_with_source_revision(
    codex_home: &Path,
    timeout: StdDuration,
    source_revision: u64,
) -> Result<PreciseScanDiscovery, String> {
    let deadline = Instant::now()
        .checked_add(timeout)
        .unwrap_or_else(Instant::now);
    let canonical_home = canonical_codex_home(codex_home)?;
    let physical_home_identity = attribution_watch_root_physical_identity(&canonical_home)?;
    let discovered_at = SystemTime::now();
    let mut candidates = HashMap::new();
    let mut directories = HashMap::new();
    let mut boundary_warnings = Vec::new();
    let state_database = codex_home.join("state_5.sqlite");
    directories.insert(state_database.clone(), directory_signature(&state_database));

    for root_name in ["sessions", "archived_sessions"] {
        let root = codex_home.join(root_name);
        directories.insert(root.clone(), directory_signature(&root));
        if root.is_dir() {
            estimate_session_directory(
                &root,
                &canonical_home,
                &deadline,
                &mut candidates,
                &mut directories,
                &mut boundary_warnings,
            )?;
        }
    }
    estimate_active_rollouts(
        codex_home,
        &canonical_home,
        &deadline,
        &mut candidates,
        &mut directories,
        &mut boundary_warnings,
    )?;

    ensure_estimate_deadline(&deadline)?;
    if attribution_watch_root_physical_identity(&canonical_home)? != physical_home_identity {
        return Err("Codex Home 在预扫描期间被替换，放弃本次 discovery plan".into());
    }
    let mut candidates = candidates
        .into_iter()
        .map(|(canonical_path, signature)| PreciseScanCandidate {
            canonical_path,
            signature,
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| left.canonical_path.cmp(&right.canonical_path));
    let candidate_total = candidates.len() as u64;
    let mut directory_signatures = directories.into_values().collect::<Vec<_>>();
    directory_signatures.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(PreciseScanDiscovery {
        canonical_home,
        physical_home_identity,
        source_revision,
        discovered_at,
        directory_signatures,
        candidates,
        candidate_total,
        boundary_warnings,
    })
}

fn estimate_session_directory(
    root: &Path,
    canonical_home: &Path,
    deadline: &Instant,
    candidates: &mut HashMap<PathBuf, FileSignature>,
    directories: &mut HashMap<PathBuf, DirectorySignature>,
    boundary_warnings: &mut Vec<String>,
) -> Result<(), String> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        ensure_estimate_deadline(deadline)?;
        directories.insert(directory.clone(), directory_signature(&directory));
        let entries = fs::read_dir(&directory).map_err(|error| {
            format!(
                "无法预扫描精确 token 会话目录 {}：{error}",
                directory.display()
            )
        })?;
        for entry in entries {
            ensure_estimate_deadline(deadline)?;
            let entry = entry.map_err(|error| {
                format!(
                    "无法预扫描精确 token 会话目录项 {}：{error}",
                    directory.display()
                )
            })?;
            let path = entry.path();
            let metadata = match fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };
            if metadata.file_type().is_dir() {
                pending.push(path);
                continue;
            }
            if path
                .extension()
                .is_none_or(|extension| extension != "jsonl")
            {
                continue;
            }
            let Ok(canonical) = fs::canonicalize(&path) else {
                continue;
            };
            if !canonical.starts_with(canonical_home) {
                boundary_warnings.push(format!(
                    "拒绝读取 Codex Home 外的会话文件：{} -> {}",
                    path.display(),
                    canonical.display()
                ));
                continue;
            }
            if fs::metadata(&canonical).is_ok_and(|metadata| metadata.is_file()) {
                if let Ok(signature) = file_signature(&canonical) {
                    candidates.entry(canonical).or_insert(signature);
                }
            }
        }
    }
    Ok(())
}

fn estimate_active_rollouts(
    codex_home: &Path,
    canonical_home: &Path,
    deadline: &Instant,
    candidates: &mut HashMap<PathBuf, FileSignature>,
    directories: &mut HashMap<PathBuf, DirectorySignature>,
    boundary_warnings: &mut Vec<String>,
) -> Result<(), String> {
    ensure_estimate_deadline(deadline)?;
    let database = codex_home.join("state_5.sqlite");
    if !database.is_file() {
        return Ok(());
    }
    let state_connection = sqlite::open_read_only(&database, StdDuration::from_millis(100))
        .map_err(|error| format!("无法预扫描 active rollout：{error}"))?;
    if !column_exists_checked(&state_connection, "threads", "rollout_path")? {
        return Ok(());
    }
    let archived_filter = if column_exists_checked(&state_connection, "threads", "archived")? {
        "COALESCE(archived, 0) = 0"
    } else {
        "1 = 1"
    };
    let sql = format!(
        "SELECT rollout_path FROM threads WHERE {archived_filter} AND rollout_path IS NOT NULL AND rollout_path <> ''"
    );
    let mut statement = state_connection
        .prepare(&sql)
        .map_err(|error| format!("无法准备 active rollout 预扫描：{error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法读取 active rollout 预扫描结果：{error}"))?;
    for row in rows {
        ensure_estimate_deadline(deadline)?;
        let raw = row.map_err(|error| format!("无法读取 active rollout 路径：{error}"))?;
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
            .is_none_or(|extension| extension != "jsonl")
        {
            continue;
        }
        let Ok(canonical) = fs::canonicalize(&path) else {
            boundary_warnings.push(format!(
                "无法确认 active rollout 会话文件边界：{}",
                path.display()
            ));
            continue;
        };
        if !canonical.starts_with(canonical_home) {
            boundary_warnings.push(format!(
                "拒绝读取 Codex Home 外的 active rollout 会话文件：{} -> {}",
                path.display(),
                canonical.display()
            ));
            continue;
        }
        if fs::metadata(&canonical).is_ok_and(|metadata| metadata.is_file()) {
            if let Some(parent) = canonical.parent() {
                directories.insert(parent.to_path_buf(), directory_signature(parent));
            }
            if let Ok(signature) = file_signature(&canonical) {
                candidates.entry(canonical).or_insert(signature);
            }
        }
    }
    Ok(())
}

fn ensure_estimate_deadline(deadline: &Instant) -> Result<(), String> {
    if Instant::now() >= *deadline {
        Err("精确 token 预扫描超过时间上限".into())
    } else {
        Ok(())
    }
}

fn enqueue_directory(
    connection: &Connection,
    canonical_home: &Path,
    directory: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
) -> Result<(), String> {
    let canonical = match fs::canonicalize(directory) {
        Ok(canonical) if canonical.starts_with(canonical_home) => canonical,
        Ok(canonical) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "拒绝读取 Codex Home 外的会话目录：{} -> {}",
                directory.display(),
                canonical.display()
            )));
            return Ok(());
        }
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "无法确认会话目录边界：{}（{}）",
                directory.display(),
                error
            )));
            // 解析失败多为权限类持久错误：真正被删除的目录下一轮不会再被父目录
            // 列出，墓碑只是顺延一轮。先抑制，避免把已发布统计误判为已删除。
            suppress_missing_tombstones_under(connection, directory)?;
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
    scan_completeness: &mut ExactScanCompleteness,
    mut visit: impl FnMut(
        &mut Connection,
        &Path,
        &mut Vec<LocalDataWarning>,
        &mut ExactScanCompleteness,
    ) -> Result<(), String>,
) -> Result<(), String> {
    let database = codex_home.join("state_5.sqlite");
    if !database.exists() {
        return Ok(());
    }
    let state_connection = match sqlite::open_read_only(&database, StdDuration::from_millis(100)) {
        Ok(connection) => connection,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取 active rollout 索引失败，本轮保留已有统计：{}（{}）",
                database.display(),
                error
            )));
            return Ok(());
        }
    };
    let has_rollout_path = match column_exists_checked(&state_connection, "threads", "rollout_path")
    {
        Ok(value) => value,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取 active rollout 索引结构失败，本轮保留已有统计：{}（{}）",
                database.display(),
                error
            )));
            return Ok(());
        }
    };
    if !has_rollout_path {
        return Ok(());
    }
    let archived_filter = match column_exists_checked(&state_connection, "threads", "archived") {
        Ok(true) => "COALESCE(archived, 0) = 0",
        Ok(false) => "1 = 1",
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "读取 active rollout 归档字段失败，将保守扫描全部路径：{}（{}）",
                database.display(),
                error
            )));
            "1 = 1"
        }
    };
    let sql = format!(
        "SELECT rollout_path FROM threads WHERE {archived_filter} AND rollout_path IS NOT NULL AND rollout_path <> ''"
    );
    let mut statement = match state_connection.prepare(&sql) {
        Ok(statement) => statement,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "准备 active rollout 路径枚举失败，本轮保留已有统计：{error}"
            )));
            return Ok(());
        }
    };
    let rows = match statement.query_map([], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(error) => {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "开始 active rollout 路径枚举失败，本轮保留已有统计：{error}"
            )));
            return Ok(());
        }
    };
    for row in rows {
        let raw = match row {
            Ok(raw) => raw,
            Err(error) => {
                scan_completeness.mark_incomplete();
                warnings.push(scan_warning(format!(
                    "读取 active rollout 路径项失败，本轮跳过该项：{error}"
                )));
                continue;
            }
        };
        let path = {
            let path = PathBuf::from(raw);
            if path.is_absolute() {
                path
            } else {
                codex_home.join(path)
            }
        };
        if !path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
        {
            scan_completeness.mark_incomplete();
            warnings.push(scan_warning(format!(
                "active rollout 路径不是 JSONL，本轮跳过该项：{}",
                path.display()
            )));
            continue;
        }
        if let Some(file) =
            resolve_file_within_codex_home(canonical_home, &path, "active rollout", warnings)
        {
            visit(index_connection, &file, warnings, scan_completeness)?;
        } else {
            scan_completeness.mark_incomplete();
        }
    }
    Ok(())
}

fn sync_thread_metadata(
    transaction: &Transaction<'_>,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<bool, String> {
    let previous = (
        metadata_text(transaction, "state_size")?,
        metadata_text(transaction, "state_modified_ns")?,
    );
    let stage = stage_thread_metadata(codex_home, previous, warnings)?;
    apply_thread_metadata_stage(transaction, stage)
}

fn stage_thread_metadata(
    codex_home: &Path,
    previous: (Option<String>, Option<String>),
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<ThreadMetadataStage, String> {
    let database = codex_home.join("state_5.sqlite");
    let database_exists = match fs::symlink_metadata(&database) {
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => {
            warnings.push(thread_info_warning(format!(
                "检查会话标题索引失败：{}（{}）",
                database.display(),
                error
            )));
            return Ok(ThreadMetadataStage::Failed);
        }
    };
    let signature = if database_exists {
        if !database.is_file() {
            warnings.push(thread_info_warning(format!(
                "会话标题索引路径不是普通文件：{}",
                database.display()
            )));
            return Ok(ThreadMetadataStage::Failed);
        }
        match file_signature(&database) {
            Ok(value) => Some((value.size.to_string(), value.modified_ns.to_string())),
            Err(error) => {
                warnings.push(thread_info_warning(format!(
                    "读取会话标题索引签名失败：{}（{}）",
                    database.display(),
                    error
                )));
                return Ok(ThreadMetadataStage::Failed);
            }
        }
    } else {
        None
    };
    if previous == signature.clone().unzip() {
        return Ok(ThreadMetadataStage::Unchanged);
    }

    let Some((size, modified_ns)) = signature else {
        return Ok(ThreadMetadataStage::Updated(StagedThreadMetadata {
            signature: None,
            rows: Vec::new(),
        }));
    };

    let connection = match sqlite::open_read_only(&database, StdDuration::from_secs(3)) {
        Ok(connection) => connection,
        Err(error) => {
            warnings.push(thread_info_warning(format!(
                "读取会话标题索引失败：{}（{}）",
                database.display(),
                error
            )));
            return Ok(ThreadMetadataStage::Failed);
        }
    };
    let mut statement = match connection.prepare(
        r#"
        SELECT id, title, first_user_message, preview, COALESCE(updated_at_ms, updated_at)
        FROM threads
        "#,
    ) {
        Ok(statement) => statement,
        Err(error) => {
            warnings.push(thread_info_warning(format!(
                "读取会话标题索引结构失败：{}（{}）",
                database.display(),
                error
            )));
            return Ok(ThreadMetadataStage::Failed);
        }
    };
    let rows = match statement.query_map([], |row| {
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
    }) {
        Ok(rows) => rows,
        Err(error) => {
            warnings.push(thread_info_warning(format!(
                "读取会话标题索引失败：{}（{}）",
                database.display(),
                error
            )));
            return Ok(ThreadMetadataStage::Failed);
        }
    };
    let mut staged_rows = Vec::new();
    for row in rows {
        match row {
            Ok(row) => staged_rows.push(row),
            Err(error) => {
                warnings.push(thread_info_warning(format!(
                    "读取会话标题索引失败：{}（{}）",
                    database.display(),
                    error
                )));
                return Ok(ThreadMetadataStage::Failed);
            }
        }
    }
    Ok(ThreadMetadataStage::Updated(StagedThreadMetadata {
        signature: Some((size, modified_ns)),
        rows: staged_rows,
    }))
}

fn apply_thread_metadata_stage(
    transaction: &Transaction<'_>,
    stage: ThreadMetadataStage,
) -> Result<bool, String> {
    let ThreadMetadataStage::Updated(staged) = stage else {
        return Ok(false);
    };
    transaction
        .execute("DELETE FROM session_metadata", [])
        .map_err(|error| format!("无法刷新会话标题索引：{error}"))?;
    for (session_id, title, updated_at) in staged.rows {
        transaction
            .execute(
                "INSERT OR REPLACE INTO session_metadata(session_id, title, updated_at) VALUES (?1, ?2, ?3)",
                params![session_id, title, updated_at],
            )
            .map_err(|error| format!("写入会话标题索引失败：{error}"))?;
    }
    if let Some((size, modified_ns)) = staged.signature {
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

fn publish_thread_metadata_only(
    connection: &mut Connection,
    staged: StagedThreadMetadata,
) -> Result<u64, String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始会话标题索引发布事务：{error}"))?;
    if !apply_thread_metadata_stage(&transaction, ThreadMetadataStage::Updated(staged))? {
        let revision = metadata_i64(&transaction, "revision")?.unwrap_or(0);
        transaction
            .commit()
            .map_err(|error| format!("无法结束会话标题索引发布事务：{error}"))?;
        return Ok(u64::try_from(revision).unwrap_or(0));
    }
    let revision = metadata_i64(&transaction, "revision")?
        .unwrap_or(0)
        .saturating_add(1);
    set_metadata(&transaction, "revision", &revision.to_string())?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交会话标题索引发布事务：{error}"))?;
    Ok(u64::try_from(revision).unwrap_or(0))
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
    existed_before_hint: bool,
    initialize_metadata: bool,
) -> Result<(ManagedIndexConnection, bool), String> {
    let gate = index_integrity_gate(path);
    let _gate_guard = gate.enter(path);
    // The caller's existence probe can become stale while another open is
    // waiting on this path gate. Recheck under the per-path gate, never under
    // INDEX_INTEGRITY_STATES, so a newly created database is treated as such.
    let existed_before = existing_regular_index(path)?;
    let _ = existed_before_hint;
    if !existed_before {
        let connection = open_index_connection(path, true, true)?;
        return managed_index_connection(path, connection).map(|connection| (connection, false));
    }

    let state_has_active_connection = {
        let states = index_integrity_states();
        let states = states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        states
            .get(path)
            .is_some_and(|state| state.active_connections > 0)
    };
    let signature_before_open = index_storage_signature(path).ok();
    let receipt = signature_before_open.and_then(|signature| {
        read_integrity_receipt(path)
            .filter(|receipt| receipt_storage_matches(receipt, path, signature))
    });

    match open_index_connection(path, false, initialize_metadata) {
        Ok(connection) if state_has_active_connection => {
            return managed_index_connection(path, connection)
                .map(|connection| (connection, false));
        }
        Ok(connection) => {
            let receipt_is_verified = receipt
                .as_ref()
                .is_some_and(|receipt| receipt_connection_metadata_matches(receipt, &connection));
            if receipt_is_verified {
                return managed_index_connection(path, connection)
                    .map(|connection| (connection, false));
            }
            match quick_check_index_result(&connection, Some(path)) {
                Ok(None) => {
                    return managed_index_connection(path, connection)
                        .map(|connection| (connection, false));
                }
                Ok(Some(report)) => {
                    drop(connection);
                    return Err(format!(
                        "精确 token 索引完整性检查报告损坏，已保留原索引并拒绝自动重建：{report}"
                    ));
                }
                Err(error) => {
                    drop(connection);
                    return Err(format!(
                        "精确 token 索引完整性检查暂时失败，已保留原索引并拒绝自动重建：{error}"
                    ));
                }
            }
        }
        Err(error) => Err(format!(
            "精确 token 索引打开失败，已保留原索引并拒绝自动重建：{error}"
        )),
    }
}

fn quick_check_index(connection: &Connection, path: Option<&Path>) -> Result<(), String> {
    match quick_check_index_result(connection, path)? {
        None => Ok(()),
        Some(report) => Err(format!("SQLite quick_check 报告损坏：{report}")),
    }
}

/// Returns `Ok(None)` for a clean database, `Ok(Some(report))` only when
/// SQLite completed the check and explicitly reported structural corruption,
/// and `Err` for a transient/query failure. Callers must never turn the latter
/// into destructive recovery: an interrupted WAL/checkpoint, lock, or disk I/O
/// failure is not proof that the published index is corrupt.
fn quick_check_index_result(
    connection: &Connection,
    path: Option<&Path>,
) -> Result<Option<String>, String> {
    #[cfg(test)]
    QUICK_CHECK_COUNT.fetch_add(1, Ordering::SeqCst);
    #[cfg(not(test))]
    let _ = path;
    #[cfg(test)]
    if let Some(path) = path {
        let barrier = QUICK_CHECK_BARRIER
            .get_or_init(|| Mutex::new(None))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_ref()
            .filter(|(_, paths)| paths.contains(path))
            .map(|(barrier, _)| Arc::clone(barrier));
        if let Some(barrier) = barrier {
            barrier.wait();
        }
    }
    #[cfg(test)]
    if FAIL_NEXT_QUICK_CHECK_QUERY.swap(false, Ordering::SeqCst) {
        return Err("injected transient quick_check query failure".into());
    }
    let result = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法完成 SQLite quick_check：{error}"))?;
    if result.eq_ignore_ascii_case("ok") {
        Ok(None)
    } else {
        Ok(Some(result))
    }
}

fn index_integrity_states() -> &'static Mutex<HashMap<PathBuf, IndexIntegrityState>> {
    INDEX_INTEGRITY_STATES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn index_integrity_gate(path: &Path) -> Arc<IntegrityGate> {
    let gates = INDEX_INTEGRITY_GATES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut gates = gates
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    gates.retain(|_, gate| gate.strong_count() > 0);
    if let Some(gate) = gates.get(path).and_then(Weak::upgrade) {
        return gate;
    }
    let gate = Arc::new(IntegrityGate {
        in_flight: Mutex::new(false),
        released: Condvar::new(),
    });
    gates.insert(path.to_path_buf(), Arc::downgrade(&gate));
    gate
}

impl IntegrityGate {
    fn enter(self: &Arc<Self>, path: &Path) -> IntegrityGateGuard {
        self.enter_with_release_hook(path, true)
    }

    // A sync guard is released before the managed connection closes. It must
    // not look like the close-time guard to diagnostics or tests; only the
    // close-time guard publishes that probe.
    fn enter_silent(self: &Arc<Self>, path: &Path) -> IntegrityGateGuard {
        self.enter_with_release_hook(path, false)
    }

    fn enter_with_release_hook(
        self: &Arc<Self>,
        path: &Path,
        notify_release: bool,
    ) -> IntegrityGateGuard {
        let mut in_flight = self
            .in_flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        while *in_flight {
            in_flight = self
                .released
                .wait(in_flight)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        *in_flight = true;
        drop(in_flight);
        run_integrity_gate_enter_hook_for_testing(path);
        IntegrityGateGuard {
            gate: Arc::clone(self),
            path: path.to_path_buf(),
            notify_release,
        }
    }
}

impl Drop for IntegrityGateGuard {
    fn drop(&mut self) {
        // The release probe runs before the gate becomes available to a
        // waiter. This keeps the test-only observation deterministic: the
        // close path must have already published its state decrement before
        // any new open can acquire this path gate.
        if self.notify_release {
            run_integrity_gate_release_hook_for_testing(&self.path);
        }
        let mut in_flight = self
            .gate
            .in_flight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *in_flight = false;
        self.gate.released.notify_one();
    }
}

fn index_storage_signature(path: &Path) -> Result<IndexStorageSignature, String> {
    Ok(IndexStorageSignature {
        database: file_signature(path)?,
        wal: optional_index_sidecar_signature(&sqlite_sidecar_path(path, "-wal"))?,
    })
}

fn integrity_receipt_path(path: &Path) -> PathBuf {
    let mut receipt = path.as_os_str().to_os_string();
    receipt.push(INDEX_INTEGRITY_RECEIPT_SUFFIX);
    PathBuf::from(receipt)
}

#[cfg(test)]
pub(super) fn integrity_receipt_path_for_testing(codex_home: &Path) -> Result<PathBuf, String> {
    Ok(integrity_receipt_path(&database_path(codex_home)?))
}

fn receipt_file_signature(signature: FileSignature) -> ReceiptFileSignature {
    ReceiptFileSignature {
        size: signature.size,
        modified_ns: signature.modified_ns.to_string(),
        device_id: signature.identity.device_id,
        file_id: signature.identity.file_id,
        changed_ns: signature.changed_ns.to_string(),
    }
}

fn receipt_file_signature_matches(stored: &ReceiptFileSignature, current: FileSignature) -> bool {
    stored.size == current.size
        && stored.modified_ns.parse::<u128>().ok() == Some(current.modified_ns)
        && stored.device_id == current.identity.device_id
        && stored.file_id == current.identity.file_id
        && stored.changed_ns.parse::<i128>().ok() == Some(current.changed_ns)
}

fn receipt_storage_matches(
    receipt: &IndexIntegrityReceipt,
    path: &Path,
    signature: IndexStorageSignature,
) -> bool {
    receipt.version == INDEX_INTEGRITY_RECEIPT_VERSION
        && canonical_index_path(path)
            .ok()
            .is_some_and(|canonical| receipt.canonical_index_path == canonical.to_string_lossy())
        && receipt_file_signature_matches(&receipt.database, signature.database)
        && match (&receipt.wal, signature.wal) {
            (None, None) => true,
            (Some(stored), Some(current)) => receipt_file_signature_matches(stored, current),
            // SQLite may leave a zero-byte WAL sidecar behind, or recreate an
            // empty sidecar with a new inode on the next read-only open.  An
            // empty WAL has no database state to validate; treating it as
            // absent keeps the integrity receipt reusable without running
            // quick_check on every startup.
            (Some(stored), None) => stored.size == 0,
            (None, Some(current)) => current.size == 0,
        }
}

fn receipt_connection_metadata_matches(
    receipt: &IndexIntegrityReceipt,
    connection: &Connection,
) -> bool {
    // The receipt was already matched against the pre-open signature. A
    // connection open can create a WAL sidecar, so storage is deliberately
    // checked before the open and metadata after it.
    metadata_i64(connection, "schema_version")
        .ok()
        .flatten()
        .is_some_and(|schema_version| schema_version == receipt.schema_version)
        && metadata_text(connection, "published_generation")
            .ok()
            .flatten()
            .and_then(|generation| generation.parse::<i64>().ok())
            .is_some_and(|generation| generation == receipt.published_generation)
        && receipt.parser_revision == EXACT_SESSION_PARSER_REVISION
}

fn receipt_metadata(connection: &Connection, path: &Path) -> Result<ReceiptMetadata, String> {
    let schema_version = metadata_i64(connection, "schema_version")?
        .ok_or_else(|| "精确 token 完整性收据缺少 schema 版本".to_string())?;
    let published_generation = metadata_i64(connection, "published_generation")?
        .ok_or_else(|| "精确 token 完整性收据缺少已发布代次".to_string())?;
    let canonical_index_path = canonical_index_path(path)?.to_string_lossy().into_owned();
    Ok(ReceiptMetadata {
        canonical_index_path,
        schema_version,
        parser_revision: EXACT_SESSION_PARSER_REVISION.into(),
        published_generation,
    })
}

fn read_integrity_receipt(path: &Path) -> Option<IndexIntegrityReceipt> {
    let receipt_path = integrity_receipt_path(path);
    let metadata = fs::symlink_metadata(&receipt_path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return None;
    }
    let bytes = fs::read(receipt_path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn receipt_destination_is_safe(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(format!(
            "拒绝覆盖符号链接形式的精确 token 完整性收据：{}",
            path.display()
        )),
        Ok(metadata) if !metadata.is_file() => Err(format!(
            "精确 token 完整性收据路径不是普通文件：{}",
            path.display()
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "无法检查精确 token 完整性收据路径 {}：{}",
            path.display(),
            error
        )),
    }
}

fn write_integrity_receipt_best_effort(
    path: &Path,
    metadata: ReceiptMetadata,
    signature: IndexStorageSignature,
) {
    let receipt_path = integrity_receipt_path(path);
    if receipt_destination_is_safe(&receipt_path).is_err() {
        return;
    }
    let receipt = IndexIntegrityReceipt {
        version: INDEX_INTEGRITY_RECEIPT_VERSION,
        canonical_index_path: metadata.canonical_index_path,
        database: receipt_file_signature(signature.database),
        wal: signature.wal.map(receipt_file_signature),
        schema_version: metadata.schema_version,
        parser_revision: metadata.parser_revision,
        published_generation: metadata.published_generation,
    };
    let Ok(bytes) = serde_json::to_vec(&receipt) else {
        return;
    };
    if fs::read(&receipt_path).is_ok_and(|existing| existing == bytes) {
        return;
    }
    #[cfg(test)]
    RECEIPT_WRITE_COUNT.fetch_add(1, Ordering::SeqCst);
    let _ = atomic_file::write_atomically(&receipt_path, &bytes);
}

fn canonical_index_path(path: &Path) -> Result<PathBuf, String> {
    fs::canonicalize(path).map_err(|error| {
        format!(
            "无法确认精确 token 索引规范路径 {}：{}",
            path.display(),
            error
        )
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
        Ok(_) => {
            let signature = file_signature(path)?;
            Ok((signature.size > 0).then_some(signature))
        }
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
    Ok(register_index_connection(&mut states, path, connection))
}

fn register_index_connection(
    states: &mut HashMap<PathBuf, IndexIntegrityState>,
    path: &Path,
    connection: Connection,
) -> ManagedIndexConnection {
    let active_connections = states
        .get(path)
        .map(|state| state.active_connections)
        .unwrap_or(0)
        .saturating_add(1);
    states.insert(
        path.to_path_buf(),
        IndexIntegrityState { active_connections },
    );
    ManagedIndexConnection::from_registered(connection, path.to_path_buf())
}

fn finish_index_connection(states: &mut HashMap<PathBuf, IndexIntegrityState>, path: &Path) {
    let remaining_connections = states
        .get(path)
        .map(|state| state.active_connections.saturating_sub(1))
        .unwrap_or(0);
    if remaining_connections > 0 {
        states.insert(
            path.to_path_buf(),
            IndexIntegrityState {
                active_connections: remaining_connections,
            },
        );
    } else {
        states.remove(path);
    }
}

fn invalidate_index_integrity_signature(path: &Path) {
    let states = index_integrity_states();
    let mut states = states
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    states.remove(path);
}

fn open_index_connection(
    path: &Path,
    create_if_missing: bool,
    initialize_metadata: bool,
) -> Result<Connection, String> {
    let mut flags = OpenFlags::default();
    if !create_if_missing {
        flags.remove(OpenFlags::SQLITE_OPEN_CREATE);
    }
    let connection = Connection::open_with_flags(path, flags)
        .map_err(|error| format!("无法打开精确 token 索引 {}：{}", path.display(), error))?;
    connection
        .busy_timeout(StdDuration::from_secs(30))
        .map_err(|error| format!("无法设置精确 token 索引等待时间：{error}"))?;
    let pragmas = if create_if_missing || initialize_metadata {
        "PRAGMA journal_mode = WAL;\nPRAGMA synchronous = NORMAL;\nPRAGMA temp_store = FILE;\nPRAGMA cache_size = -16384;\nPRAGMA foreign_keys = ON;"
    } else {
        // A compatible reopen must not ask SQLite to change persistent
        // journal state. The database was configured for WAL when it was
        // created; these remaining pragmas are connection-local.
        "PRAGMA synchronous = NORMAL;\nPRAGMA temp_store = FILE;\nPRAGMA cache_size = -16384;\nPRAGMA foreign_keys = ON;"
    };
    connection
        .execute_batch(pragmas)
        .map_err(|error| format!("无法初始化精确 token 索引连接：{error}"))?;
    if create_if_missing || initialize_metadata {
        #[cfg(test)]
        OPEN_DDL_COUNT.fetch_add(1, Ordering::SeqCst);
        connection
            .execute_batch(
                r#"
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                "#,
            )
            .map_err(|error| format!("无法初始化精确 token 索引元数据表：{error}"))?;
    }
    let foreign_keys_enabled = connection
        .query_row("PRAGMA foreign_keys", [], |row| row.get::<_, i64>(0))
        .map_err(|error| format!("无法确认精确 token 索引外键约束：{error}"))?;
    if foreign_keys_enabled != 1 {
        return Err("精确 token 索引外键约束未启用".into());
    }
    Ok(connection)
}

fn repair_orphaned_index_rows(connection: &mut Connection) -> Result<(), String> {
    if metadata_text(connection, ORPHAN_REPAIR_REVISION_KEY)?.as_deref()
        == Some(ORPHAN_REPAIR_REVISION)
    {
        return Ok(());
    }

    // Start read-first. A legacy database can be checked without reserving a
    // writer slot; only a positive orphan result (or the marker write) needs
    // to upgrade this deferred transaction. If another writer wins that
    // upgrade, rusqlite returns SQLITE_BUSY and the missing marker makes the
    // next open retry instead of claiming that repair completed.
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Deferred)
        .map_err(|error| format!("无法开始精确 token 孤儿行读取事务：{error}"))?;
    if orphaned_index_rows_exist(&transaction)? {
        transaction
            .execute(
                r#"
                DELETE FROM events
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = events.file_generation
                      AND files.path = events.file_path
                )
                "#,
                [],
            )
            .map_err(|error| format!("无法清理精确 token 孤儿事件：{error}"))?;
        transaction
            .execute(
                r#"
                DELETE FROM file_fingerprints
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = file_fingerprints.file_generation
                      AND files.path = file_fingerprints.file_path
                )
                "#,
                [],
            )
            .map_err(|error| format!("无法清理精确 token 孤儿去重状态：{error}"))?;
        transaction
            .execute(
                r#"
                DELETE FROM file_chunks
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = file_chunks.file_generation
                      AND files.path = file_chunks.file_path
                )
                "#,
                [],
            )
            .map_err(|error| format!("无法清理精确 token 孤儿分块状态：{error}"))?;
        if orphaned_index_rows_exist(&transaction)? {
            return Err("精确 token 孤儿行修复复核仍发现未清理的孤儿行".into());
        }
    }
    set_metadata(
        &transaction,
        ORPHAN_REPAIR_REVISION_KEY,
        ORPHAN_REPAIR_REVISION,
    )?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交精确 token 孤儿行修复标记：{error}"))
}

fn orphaned_index_rows_exist(connection: &Connection) -> Result<bool, String> {
    for (label, query) in [
        (
            "事件",
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM events
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = events.file_generation
                      AND files.path = events.file_path
                )
            )
            "#,
        ),
        (
            "去重状态",
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM file_fingerprints
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = file_fingerprints.file_generation
                      AND files.path = file_fingerprints.file_path
                )
            )
            "#,
        ),
        (
            "分块状态",
            r#"
            SELECT EXISTS(
                SELECT 1
                FROM file_chunks
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM files
                    WHERE files.generation = file_chunks.file_generation
                      AND files.path = file_chunks.file_path
                )
            )
            "#,
        ),
    ] {
        let exists = connection
            .query_row(query, [], |row| row.get::<_, i64>(0))
            .map_err(|error| format!("无法检查精确 token 孤儿{label}：{error}"))?
            != 0;
        if exists {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
pub(super) fn repair_orphaned_index_rows_for_testing(
    connection: &mut Connection,
) -> Result<(), String> {
    repair_orphaned_index_rows(connection)
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
    let transaction = connection
        .unchecked_transaction()
        .map_err(|error| format!("无法开始精确 token 字段迁移事务：{error}"))?;
    for (table, column, definition) in [
        ("files", "current_model", "TEXT"),
        (
            "files",
            "is_explicit_subagent_fork",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        ("events", "model", "TEXT"),
        // Reasoning was not present in the GitHub v0.8.3 events table. Keep
        // the legacy value NULL so an old row is never mistaken for an
        // observed zero; the current parser writes an explicit zero when the
        // source reports no reasoning output.
        ("events", "reasoning_output_tokens", "INTEGER"),
        (
            "event_enrichment_sources",
            "parser_revision",
            "TEXT NOT NULL DEFAULT ''",
        ),
        (
            "event_enrichment_sources",
            "device_id",
            "TEXT NOT NULL DEFAULT ''",
        ),
        (
            "event_enrichment_sources",
            "file_id",
            "TEXT NOT NULL DEFAULT ''",
        ),
    ] {
        let table_exists = transaction
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                params![table],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("无法检查精确 token 表 {table}：{error}"))?
            > 0;
        if !table_exists {
            continue;
        }
        if !column_exists_checked(&transaction, table, column)? {
            transaction
                .execute(
                    &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
                    [],
                )
                .map_err(|error| {
                    format!("无法原位迁移精确 token 字段 {table}.{column}：{error}")
                })?;
        }
    }
    let receipt_table_exists = transaction
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'event_enrichment_sources')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查历史字段补全 receipt 表：{error}"))?;
    if receipt_table_exists {
        transaction
            .execute(
                r#"
                UPDATE event_enrichment_sources
                SET parser_revision = ?1,
                    device_id = COALESCE((
                        SELECT files.device_id
                        FROM files
                        WHERE files.generation = event_enrichment_sources.file_generation
                          AND files.path = event_enrichment_sources.path
                    ), device_id),
                    file_id = COALESCE((
                        SELECT files.file_id
                        FROM files
                        WHERE files.generation = event_enrichment_sources.file_generation
                          AND files.path = event_enrichment_sources.path
                    ), file_id)
                WHERE revision = ?2
                  AND (parser_revision = '' OR device_id = '' OR file_id = '')
                "#,
                params![
                    STAGED_FULL_REBUILD_PARSER_REVISION,
                    EVENT_ENRICHMENT_REVISION
                ],
            )
            .map_err(|error| format!("无法补全历史字段 receipt 身份：{error}"))?;
    }
    transaction
        .commit()
        .map_err(|error| format!("无法提交精确 token 字段迁移事务：{error}"))
}

fn repair_explicit_subagent_replay_boundary(connection: &Connection) -> Result<bool, String> {
    // Keep published rows readable while the normal per-file synchronization
    // path stages and atomically publishes a corrected replacement. This
    // migration only invalidates the physical checkpoint for files whose first
    // line proves an explicit subagent fork; it never deletes token events or
    // rescans the full JSONL corpus.
    let files_table_exists = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'files'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| format!("无法检查精确 token 文件表：{error}"))?
        > 0;
    if !files_table_exists {
        return Ok(true);
    }
    // A legacy schema can already carry the current replay marker from an
    // earlier build.  The marker only proves that replay was checked for that
    // schema generation; it must not suppress the first replay pass after a
    // schema migration.  Once the current schema is durable, the marker can
    // be trusted and the open path remains a no-op.
    let schema_is_current = metadata_i64(connection, "schema_version")?
        == Some(INDEX_SCHEMA_VERSION);
    if schema_is_current
        && metadata_text(connection, "fork_replay_boundary_revision")?.as_deref()
            == Some(FORK_REPLAY_BOUNDARY_REVISION)
    {
        return Ok(true);
    }

    let mut statement = connection
        .prepare(
            r#"
            SELECT DISTINCT path
            FROM files
            WHERE deleted = 0
              AND fork_replay_active = 1
              AND is_explicit_subagent_fork = 0
            "#,
        )
        .map_err(|error| format!("无法准备子 Agent replay 兼容迁移：{error}"))?;
    let candidates = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法读取子 Agent replay 兼容候选：{error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码子 Agent replay 兼容候选：{error}"))?;
    drop(statement);

    let mut explicit_paths = Vec::new();
    let mut unresolved_candidate = false;
    for path in candidates {
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
                    changed_ns = ?1
                WHERE path = ?2 AND deleted = 0
                "#,
                params![format!("migration:{FORK_REPLAY_BOUNDARY_REVISION}"), path],
            )
            .map_err(|error| format!("无法标记子 Agent replay 定向修复：{error}"))?;
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
            -- selector by physical file identity, then reads only timestamp and
            -- tokens. Keeping those columns in one covering index avoids a full
            -- event-table scan without changing current-history semantics.
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
                device_id TEXT NOT NULL,
                file_id TEXT NOT NULL,
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

const SESSION_CATALOG_SCHEMA_COLUMNS: &[&str] = &[
    "path",
    "archived",
    "thread_id",
    "cwd",
    "source",
    "session_id",
    "forked_from_id",
    "parent_thread_id",
    "size",
    "modified_ns",
    "created_ns",
    "modified_at",
    "created_at",
    "stat_device_id",
    "stat_file_id",
    "stat_changed_ns",
    "device_id",
    "file_id",
    "changed_ns",
    "first_line_bytes",
    "first_line_sha256",
    "last_seen_generation",
];

fn session_catalog_columns(connection: &Connection) -> Result<Option<Vec<String>>, String> {
    let exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_catalog_files')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查会话目录增量索引表：{error}"))?;
    if !exists {
        return Ok(None);
    }
    let mut statement = connection
        .prepare("SELECT name FROM pragma_table_info('session_catalog_files') ORDER BY cid")
        .map_err(|error| format!("无法检查会话目录增量索引字段：{error}"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("无法读取会话目录增量索引字段：{error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码会话目录增量索引字段：{error}"))?;
    Ok(Some(columns))
}

fn validate_session_catalog_schema_version(connection: &Connection) -> Result<(), String> {
    let Some(raw_version) = metadata_text(connection, "session_catalog_schema_version")? else {
        if let Some(columns) = session_catalog_columns(connection)? {
            let expected = SESSION_CATALOG_SCHEMA_COLUMNS
                .iter()
                .map(|column| (*column).to_string())
                .collect::<Vec<_>>();
            if columns != expected {
                return Err(
                    "精确 token 会话目录缺少 schema 标记且表结构不是当前已知形状，已拒绝删除或覆盖"
                        .into(),
                );
            }
        }
        return Ok(());
    };
    let version = raw_version.parse::<i64>().map_err(|_| {
        format!("精确 token 会话目录 schema 版本未知或损坏（{raw_version}），已拒绝覆盖")
    })?;
    if version > SESSION_CATALOG_SCHEMA_VERSION {
        return Err(format!(
            "精确 token 会话目录 schema 版本 {version} 高于当前支持版本 {SESSION_CATALOG_SCHEMA_VERSION}，已拒绝覆盖"
        ));
    }
    if version < 0 {
        return Err(format!(
            "精确 token 会话目录 schema 版本 {version} 无效，已拒绝覆盖"
        ));
    }
    Ok(())
}

fn initialize_session_catalog_schema(connection: &Connection) -> Result<(), String> {
    // Keep this guard here as well as in `open`: callers/tests that initialize
    // the catalog directly must receive the same fail-closed behavior before
    // the legacy DROP/CREATE path can run.
    validate_session_catalog_schema_version(connection)?;
    let stored_version = metadata_i64(connection, "session_catalog_schema_version")?;
    if stored_version.is_none() && session_catalog_columns(connection)?.is_some() {
        connection
            .execute_batch(
                r#"
                BEGIN IMMEDIATE;
                CREATE INDEX IF NOT EXISTS session_catalog_thread_id_idx
                    ON session_catalog_files(thread_id, path);
                INSERT OR REPLACE INTO metadata(key, value)
                    VALUES ('session_catalog_schema_version', '1');
                INSERT OR IGNORE INTO metadata(key, value)
                    SELECT 'session_catalog_published_generation',
                           CAST(COALESCE(MAX(last_seen_generation), 0) AS TEXT)
                    FROM session_catalog_files;
                COMMIT;
                "#,
            )
            .map_err(|error| {
                let _ = connection.execute_batch("ROLLBACK;");
                format!("无法提交已知会话目录结构的缺失版本标记：{error}")
            })?;
        return Ok(());
    }
    if stored_version != Some(SESSION_CATALOG_SCHEMA_VERSION) {
        connection
            .execute_batch(
                r#"
                BEGIN IMMEDIATE;
                DROP TABLE IF EXISTS session_catalog_files;
                CREATE TABLE session_catalog_files (
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
                    stat_device_id TEXT NOT NULL,
                    stat_file_id TEXT NOT NULL,
                    stat_changed_ns TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    file_id TEXT NOT NULL,
                    changed_ns TEXT NOT NULL,
                    first_line_bytes INTEGER NOT NULL,
                    first_line_sha256 BLOB NOT NULL,
                    last_seen_generation INTEGER NOT NULL
                ) WITHOUT ROWID;
                CREATE INDEX session_catalog_thread_id_idx
                    ON session_catalog_files(thread_id, path);
                INSERT OR REPLACE INTO metadata(key, value)
                    VALUES ('session_catalog_schema_version', '1');
                INSERT OR REPLACE INTO metadata(key, value)
                    VALUES ('session_catalog_published_generation', '0');
                COMMIT;
                "#,
            )
            .map_err(|error| {
                let _ = connection.execute_batch("ROLLBACK;");
                format!("无法初始化会话目录增量索引结构：{error}")
            })?;
        return Ok(());
    }

    connection
        .execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS session_catalog_files (
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
                stat_device_id TEXT NOT NULL,
                stat_file_id TEXT NOT NULL,
                stat_changed_ns TEXT NOT NULL,
                device_id TEXT NOT NULL,
                file_id TEXT NOT NULL,
                changed_ns TEXT NOT NULL,
                first_line_bytes INTEGER NOT NULL,
                first_line_sha256 BLOB NOT NULL,
                last_seen_generation INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS session_catalog_thread_id_idx
                ON session_catalog_files(thread_id, path);
            "#,
        )
        .map_err(|error| format!("无法确认会话目录增量索引结构：{error}"))?;
    if metadata_i64(connection, "session_catalog_published_generation")?.is_none() {
        set_metadata(connection, "session_catalog_published_generation", "0")?;
    }
    Ok(())
}

fn load_stored_session_catalog(
    connection: &Connection,
) -> Result<HashMap<PathBuf, StoredSessionCatalogEntry>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT path, archived, thread_id, cwd, source, session_id,
                   forked_from_id, parent_thread_id, size, modified_ns,
                   created_ns, modified_at, created_at, stat_device_id,
                   stat_file_id, stat_changed_ns, device_id, file_id,
                   changed_ns, first_line_bytes, first_line_sha256,
                   last_seen_generation
            FROM session_catalog_files
            "#,
        )
        .map_err(|error| format!("无法准备会话目录索引读取：{error}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, i64>(8)?,
                row.get::<_, String>(9)?,
                row.get::<_, String>(10)?,
                row.get::<_, Option<i64>>(11)?,
                row.get::<_, Option<i64>>(12)?,
                row.get::<_, String>(13)?,
                row.get::<_, String>(14)?,
                row.get::<_, String>(15)?,
                row.get::<_, String>(16)?,
                row.get::<_, String>(17)?,
                row.get::<_, String>(18)?,
                row.get::<_, i64>(19)?,
                row.get::<_, Vec<u8>>(20)?,
                row.get::<_, i64>(21)?,
            ))
        })
        .map_err(|error| format!("无法查询会话目录索引：{error}"))?;

    let mut result = HashMap::new();
    for row in rows {
        let (
            path,
            archived,
            thread_id,
            cwd,
            source,
            session_id,
            forked_from_id,
            parent_thread_id,
            size,
            modified_ns,
            created_ns,
            modified_at,
            created_at,
            stat_device_id,
            stat_file_id,
            stat_changed_ns,
            device_id,
            file_id,
            changed_ns,
            first_line_bytes,
            first_line_sha256,
            last_seen_generation,
        ) = row.map_err(|error| format!("无法读取会话目录索引行：{error}"))?;
        let path = PathBuf::from(path);
        let size = u64::try_from(size)
            .map_err(|_| format!("会话目录索引文件大小无效：{}", path.display()))?;
        let first_line_bytes = u64::try_from(first_line_bytes)
            .map_err(|_| format!("会话目录索引首行长度无效：{}", path.display()))?;
        let first_line_sha256: [u8; 32] =
            first_line_sha256.try_into().map_err(|bytes: Vec<u8>| {
                format!(
                    "会话目录索引首行摘要长度无效：{}（{} 字节）",
                    path.display(),
                    bytes.len()
                )
            })?;
        result.insert(
            path.clone(),
            StoredSessionCatalogEntry {
                entry: IndexedSessionCatalogEntry {
                    path,
                    archived: archived != 0,
                    metadata: IndexedSessionMetadata {
                        thread_id,
                        cwd,
                        source,
                        session_id,
                        forked_from_id,
                        parent_thread_id,
                    },
                    size,
                    modified_at,
                    created_at,
                },
                modified_ns,
                created_ns,
                stat_device_id,
                stat_file_id,
                stat_changed_ns,
                device_id,
                file_id,
                changed_ns,
                first_line_bytes,
                first_line_sha256,
                last_seen_generation,
            },
        );
    }
    Ok(result)
}

fn collect_session_catalog_observations(
    codex_home: &Path,
) -> Result<Vec<SessionCatalogObservation>, String> {
    let mut observations = Vec::new();
    for (relative_root, archived) in [("sessions", false), ("archived_sessions", true)] {
        let root = codex_home.join(relative_root);
        let root_metadata = match fs::symlink_metadata(&root) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(format!(
                    "无法读取会话目录 {} 的属性：{error}",
                    root.display()
                ));
            }
        };
        reject_session_catalog_reparse_point(&root, &root_metadata)?;
        if !root_metadata.is_dir() {
            return Err(format!("会话目录不是普通目录：{}", root.display()));
        }
        let canonical_root = fs::canonicalize(&root)
            .map_err(|error| format!("无法固定会话目录 {}：{error}", root.display()))?;
        let mut pending = vec![canonical_root];
        while let Some(directory) = pending.pop() {
            let entries = fs::read_dir(&directory).map_err(|error| {
                format!("会话目录增量扫描无法读取 {}：{error}", directory.display())
            })?;
            for entry in entries {
                let entry = entry.map_err(|error| {
                    format!(
                        "会话目录增量扫描无法读取 {} 中的目录项：{error}",
                        directory.display()
                    )
                })?;
                let path = entry.path();
                let metadata = fs::symlink_metadata(&path).map_err(|error| {
                    format!(
                        "会话目录增量扫描无法读取 {} 的属性：{error}",
                        path.display()
                    )
                })?;
                reject_session_catalog_reparse_point(&path, &metadata)?;
                if metadata.is_dir() {
                    pending.push(path);
                    continue;
                }
                if !metadata.is_file()
                    || path.extension().and_then(|value| value.to_str()) != Some("jsonl")
                {
                    continue;
                }
                observations.push(session_catalog_observation(path, archived, &metadata)?);
            }
        }
    }
    observations.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(observations)
}

fn session_catalog_observation(
    path: PathBuf,
    archived: bool,
    metadata: &fs::Metadata,
) -> Result<SessionCatalogObservation, String> {
    let modified = metadata.modified().ok();
    let created = metadata.created().ok();
    let (stat_device_id, stat_file_id, stat_changed_ns) = session_catalog_stat_identity(metadata);
    Ok(SessionCatalogObservation {
        path,
        archived,
        size: metadata.len(),
        modified_ns: system_time_ns_text(modified),
        created_ns: system_time_ns_text(created),
        stat_device_id,
        stat_file_id,
        stat_changed_ns,
        modified_at: system_time_unix_seconds(modified),
        created_at: system_time_unix_seconds(created),
    })
}

fn session_catalog_observation_matches(
    stored: &StoredSessionCatalogEntry,
    observed: &SessionCatalogObservation,
) -> bool {
    stored.entry.archived == observed.archived
        && stored.entry.size == observed.size
        && stored.modified_ns == observed.modified_ns
        && stored.created_ns == observed.created_ns
        && stored.stat_device_id == observed.stat_device_id
        && stored.stat_file_id == observed.stat_file_id
        && stored.stat_changed_ns == observed.stat_changed_ns
}

fn refresh_session_catalog_entry<F>(
    observation: SessionCatalogObservation,
    previous: Option<&StoredSessionCatalogEntry>,
    generation: i64,
    parser: &mut F,
) -> Result<StoredSessionCatalogEntry, String>
where
    F: FnMut(&[u8]) -> Result<IndexedSessionMetadata, String>,
{
    let mut file = open_session_catalog_rollout(&observation.path)?;
    let before = file_signature_from_handle(&file, &observation.path)?;
    if before.size != observation.size || before.modified_ns.to_string() != observation.modified_ns
    {
        return Err(format!(
            "会话文件在索引读取前发生变化，请重试：{}",
            observation.path.display()
        ));
    }
    let mut first_line = Vec::new();
    {
        let mut reader = BufReader::new(&mut file);
        reader.read_until(b'\n', &mut first_line).map_err(|error| {
            format!(
                "读取会话文件首行失败：{}（{error}）",
                observation.path.display()
            )
        })?;
    }
    if first_line.last().copied() != Some(b'\n') {
        return Err(format!(
            "会话文件首条 session_meta 尚未形成完整行：{}",
            observation.path.display()
        ));
    }
    let after = file_signature_from_handle(&file, &observation.path)?;
    if before != after {
        return Err(format!(
            "会话文件在首行校验期间发生变化，请重试：{}",
            observation.path.display()
        ));
    }
    let path_metadata = fs::symlink_metadata(&observation.path).map_err(|error| {
        format!(
            "会话文件首行校验后无法复核路径 {}：{error}",
            observation.path.display()
        )
    })?;
    reject_session_catalog_reparse_point(&observation.path, &path_metadata)?;
    let path_observation = session_catalog_observation(
        observation.path.clone(),
        observation.archived,
        &path_metadata,
    )?;
    if !session_catalog_observation_values_match(&observation, &path_observation) {
        return Err(format!(
            "会话文件路径在首行校验期间被替换，请重试：{}",
            observation.path.display()
        ));
    }

    let first_line_sha256: [u8; 32] = Sha256::digest(&first_line).into();
    let same_physical_file = previous.is_some_and(|entry| {
        entry.device_id == before.identity.device_id.to_string()
            && entry.file_id == before.identity.file_id.to_string()
    });
    let metadata = if previous.is_some_and(|entry| {
        same_physical_file
            && observation.size >= entry.entry.size
            && entry.first_line_bytes == first_line.len() as u64
            && entry.first_line_sha256 == first_line_sha256
    }) {
        previous
            .expect("checked previous session catalog entry")
            .entry
            .metadata
            .clone()
    } else {
        let metadata = parser(&first_line).map_err(|error| {
            format!(
                "无法解析会话文件 {} 的 session_meta：{error}",
                observation.path.display()
            )
        })?;
        if metadata.thread_id.trim().is_empty() {
            return Err(format!(
                "会话文件首行缺少会话 ID：{}",
                observation.path.display()
            ));
        }
        metadata
    };

    Ok(StoredSessionCatalogEntry {
        entry: IndexedSessionCatalogEntry {
            path: observation.path,
            archived: observation.archived,
            metadata,
            size: observation.size,
            modified_at: observation.modified_at,
            created_at: observation.created_at,
        },
        modified_ns: observation.modified_ns,
        created_ns: observation.created_ns,
        stat_device_id: observation.stat_device_id,
        stat_file_id: observation.stat_file_id,
        stat_changed_ns: observation.stat_changed_ns,
        device_id: before.identity.device_id.to_string(),
        file_id: before.identity.file_id.to_string(),
        changed_ns: before.changed_ns.to_string(),
        first_line_bytes: first_line.len() as u64,
        first_line_sha256,
        last_seen_generation: generation,
    })
}

fn session_catalog_observation_values_match(
    left: &SessionCatalogObservation,
    right: &SessionCatalogObservation,
) -> bool {
    left.archived == right.archived
        && left.size == right.size
        && left.modified_ns == right.modified_ns
        && left.created_ns == right.created_ns
        && left.stat_device_id == right.stat_device_id
        && left.stat_file_id == right.stat_file_id
        && left.stat_changed_ns == right.stat_changed_ns
}

fn system_time_ns_text(value: Option<SystemTime>) -> String {
    value
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos().to_string())
        .unwrap_or_else(|| "0".into())
}

fn system_time_unix_seconds(value: Option<SystemTime>) -> Option<i64> {
    value
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
}

#[cfg(unix)]
fn session_catalog_stat_identity(metadata: &fs::Metadata) -> (String, String, String) {
    use std::os::unix::fs::MetadataExt;

    let changed_ns = i128::from(metadata.ctime())
        .saturating_mul(1_000_000_000)
        .saturating_add(i128::from(metadata.ctime_nsec()));
    (
        metadata.dev().to_string(),
        metadata.ino().to_string(),
        changed_ns.to_string(),
    )
}

#[cfg(windows)]
fn session_catalog_stat_identity(metadata: &fs::Metadata) -> (String, String, String) {
    use std::os::windows::fs::MetadataExt;

    (
        metadata.file_attributes().to_string(),
        metadata.creation_time().to_string(),
        metadata.last_write_time().to_string(),
    )
}

#[cfg(not(any(unix, windows)))]
fn session_catalog_stat_identity(metadata: &fs::Metadata) -> (String, String, String) {
    (
        "0".into(),
        system_time_ns_text(metadata.created().ok()),
        system_time_ns_text(metadata.modified().ok()),
    )
}

#[cfg(unix)]
fn open_session_catalog_rollout(path: &Path) -> Result<fs::File, String> {
    use std::os::unix::fs::OpenOptionsExt;

    fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("无法打开会话目录索引源 {}：{error}", path.display()))
}

#[cfg(windows)]
fn open_session_catalog_rollout(path: &Path) -> Result<fs::File, String> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;

    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("无法打开会话目录索引源 {}：{error}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("无法读取会话目录索引源属性：{error}"))?;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!(
            "会话目录索引拒绝 Windows 重解析点：{}",
            path.display()
        ));
    }
    if !metadata.is_file() {
        return Err(format!("会话目录索引源不是普通文件：{}", path.display()));
    }
    Ok(file)
}

#[cfg(not(any(unix, windows)))]
fn open_session_catalog_rollout(path: &Path) -> Result<fs::File, String> {
    fs::File::open(path)
        .map_err(|error| format!("无法打开会话目录索引源 {}：{error}", path.display()))
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
fn run_before_session_catalog_publish_hook_for_testing() -> Result<(), String> {
    FAIL_NEXT_SESSION_CATALOG_PUBLISH.with(|flag| {
        if flag.replace(false) {
            Err("injected interruption before session catalog publish".into())
        } else {
            Ok(())
        }
    })
}

#[cfg(not(test))]
fn run_before_session_catalog_publish_hook_for_testing() -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
pub(super) fn fail_next_session_catalog_publish_for_testing() {
    FAIL_NEXT_SESSION_CATALOG_PUBLISH.with(|flag| flag.set(true));
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

fn remove_regular_file_if_present(path: &Path, label: &str) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err(format!("拒绝删除符号链接形式的{label}：{}", path.display()))
        }
        Ok(metadata) if !metadata.is_file() => {
            Err(format!("{label}路径不是普通文件：{}", path.display()))
        }
        Ok(_) => fs::remove_file(path)
            .map_err(|error| format!("无法删除{label} {}：{error}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法检查{label} {}：{error}", path.display())),
    }
}

fn sqlite_sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

pub(super) fn database_path(codex_home: &Path) -> Result<PathBuf, String> {
    #[cfg(test)]
    {
        let canonical_home =
            fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf());
        return Ok(canonical_home
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

fn directory_signature(path: &Path) -> DirectorySignature {
    let metadata = fs::symlink_metadata(path).ok();
    let modified_ns = metadata
        .as_ref()
        .and_then(|value| value.modified().ok())
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map_or(0, |value| value.as_nanos());
    DirectorySignature {
        path: path.to_path_buf(),
        exists: metadata.is_some(),
        is_directory: metadata.as_ref().is_some_and(fs::Metadata::is_dir),
        size: metadata.as_ref().map_or(0, fs::Metadata::len),
        modified_ns,
    }
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
    let Some(value) = metadata_text(connection, key)? else {
        return Ok(None);
    };
    value.parse::<i64>().map(Some).map_err(|_| {
        format!("精确 token 索引元数据 {key} 已损坏：无法解析整数值 {value:?}，已拒绝按缺失值覆盖")
    })
}

fn event_enrichment_source_count(connection: &Connection) -> Result<u64, String> {
    let files_exist = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'files')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查历史字段补全来源表：{error}"))?;
    if !files_exist {
        return Ok(0);
    }
    connection
        .query_row(
            r#"
            WITH latest AS (
                SELECT path, MAX(generation) AS generation
                FROM files
                WHERE generation <= COALESCE(
                    (SELECT CAST(value AS INTEGER) FROM metadata
                     WHERE key = 'published_generation'),
                    0
                )
                GROUP BY path
            )
            SELECT COUNT(*)
            FROM latest
            JOIN files f
              ON f.path = latest.path
             AND f.generation = latest.generation
            WHERE f.deleted = 0
            "#,
            [],
            |row| row.get::<_, i64>(0),
        )
        .map(nonnegative_u64)
        .map_err(|error| format!("无法统计历史字段补全来源：{error}"))
}

fn event_enrichment_receipt_count(connection: &Connection) -> Result<u64, String> {
    connection
        .query_row(
            "SELECT COUNT(*) FROM event_enrichment_sources WHERE revision = ?1 AND parser_revision = ?2",
            params![
                EVENT_ENRICHMENT_REVISION,
                STAGED_FULL_REBUILD_PARSER_REVISION,
            ],
            |row| row.get::<_, i64>(0),
        )
        .map(nonnegative_u64)
        .map_err(|error| format!("无法统计已完成的历史字段补全来源：{error}"))
}

fn record_missing_event_enrichment_source(
    connection: &mut Connection,
    generation: i64,
    candidate: &EventEnrichmentCandidate,
) -> Result<(), String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始已删除历史来源补全事务：{error}"))?;
    delete_file_version_rows(&transaction, generation, &candidate.path)?;
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
            ) VALUES (?1, ?2, 1, '', 0, '0', '0', '0', '0', X'')
            "#,
            params![generation, &candidate.path],
        )
        .map_err(|error| format!("无法暂存已删除的历史 model/reasoning 来源：{error}"))?;
    transaction
        .execute(
            r#"
            INSERT INTO event_enrichment_sources(
                path,
                revision,
                parser_revision,
                device_id,
                file_id,
                file_generation,
                completed_size,
                completed_prefix_sha256
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(path) DO UPDATE SET
                revision = excluded.revision,
                parser_revision = excluded.parser_revision,
                device_id = excluded.device_id,
                file_id = excluded.file_id,
                file_generation = excluded.file_generation,
                completed_size = excluded.completed_size,
                completed_prefix_sha256 = excluded.completed_prefix_sha256
            "#,
            params![
                &candidate.path,
                EVENT_ENRICHMENT_REVISION,
                STAGED_FULL_REBUILD_PARSER_REVISION,
                candidate.signature.identity.device_id.to_string(),
                candidate.signature.identity.file_id.to_string(),
                generation,
                checked_i64(candidate.signature.size, "已删除历史字段补全来源大小")?,
                candidate.prefix_sha256.as_slice(),
            ],
        )
        .map_err(|error| format!("无法记录已删除的历史 model/reasoning 来源：{error}"))?;
    mark_dashboard_changed(&transaction)?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交已删除的历史 model/reasoning 来源：{error}"))
}

fn event_enrichment_pending_candidates(
    connection: &Connection,
) -> Result<Vec<EventEnrichmentCandidate>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                f.path,
                f.session_id,
                f.size,
                f.modified_ns,
                f.device_id,
                f.file_id,
                f.changed_ns,
                f.prefix_sha256
            FROM main.published_files f
            LEFT JOIN event_enrichment_sources receipt
              ON receipt.path = f.path
             AND receipt.revision = ?1
             AND receipt.parser_revision = ?2
             AND receipt.device_id = f.device_id
             AND receipt.file_id = f.file_id
             AND receipt.completed_size = f.size
             AND receipt.completed_prefix_sha256 = f.prefix_sha256
            WHERE receipt.path IS NULL
            ORDER BY f.path
            "#,
        )
        .map_err(|error| format!("无法准备历史 model/reasoning 补全来源：{error}"))?;
    let rows = statement
        .query_map(
            params![
                EVENT_ENRICHMENT_REVISION,
                STAGED_FULL_REBUILD_PARSER_REVISION,
            ],
            |row| {
                let size = nonnegative_u64(row.get::<_, i64>(2)?);
                let modified_ns = row.get::<_, String>(3)?.parse::<u128>().unwrap_or_default();
                let device_id = row.get::<_, String>(4)?.parse::<u64>().unwrap_or_default();
                let file_id = row.get::<_, String>(5)?.parse::<u64>().unwrap_or_default();
                let changed_ns = row.get::<_, String>(6)?.parse::<i128>().unwrap_or_default();
                let raw_prefix = row.get::<_, Vec<u8>>(7)?;
                let prefix_sha256: [u8; 32] = raw_prefix.try_into().map_err(|_| {
                    rusqlite::Error::InvalidColumnType(
                        7,
                        "prefix_sha256".into(),
                        rusqlite::types::Type::Blob,
                    )
                })?;
                Ok(EventEnrichmentCandidate {
                    path: row.get(0)?,
                    session_id: row.get(1)?,
                    signature: FileSignature {
                        size,
                        modified_ns,
                        identity: FileIdentity { device_id, file_id },
                        changed_ns,
                    },
                    prefix_sha256,
                })
            },
        )
        .map_err(|error| format!("无法读取历史 model/reasoning 补全来源：{error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码历史 model/reasoning 补全来源：{error}"))
}

fn event_enrichment_pending_candidates_for_generation(
    connection: &Connection,
    generation: i64,
) -> Result<Vec<EventEnrichmentCandidate>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                f.path,
                f.session_id,
                f.size,
                f.modified_ns,
                f.device_id,
                f.file_id,
                f.changed_ns,
                f.prefix_sha256
            FROM files f
            LEFT JOIN event_enrichment_sources receipt
              ON receipt.path = f.path
             AND receipt.revision = ?1
             AND receipt.parser_revision = ?2
             AND receipt.device_id = f.device_id
             AND receipt.file_id = f.file_id
             AND receipt.completed_size = f.size
             AND receipt.completed_prefix_sha256 = f.prefix_sha256
            WHERE f.generation = ?3
              AND f.deleted = 0
              AND receipt.path IS NULL
            ORDER BY f.path
            "#,
        )
        .map_err(|error| format!("无法准备当前补全代次来源：{error}"))?;
    let rows = statement
        .query_map(
            params![
                EVENT_ENRICHMENT_REVISION,
                STAGED_FULL_REBUILD_PARSER_REVISION,
                generation,
            ],
            |row| {
                let size = nonnegative_u64(row.get::<_, i64>(2)?);
                let modified_ns = row.get::<_, String>(3)?.parse::<u128>().unwrap_or_default();
                let device_id = row.get::<_, String>(4)?.parse::<u64>().unwrap_or_default();
                let file_id = row.get::<_, String>(5)?.parse::<u64>().unwrap_or_default();
                let changed_ns = row.get::<_, String>(6)?.parse::<i128>().unwrap_or_default();
                let raw_prefix = row.get::<_, Vec<u8>>(7)?;
                let prefix_sha256: [u8; 32] = raw_prefix.try_into().map_err(|_| {
                    rusqlite::Error::InvalidColumnType(
                        7,
                        "prefix_sha256".into(),
                        rusqlite::types::Type::Blob,
                    )
                })?;
                Ok(EventEnrichmentCandidate {
                    path: row.get(0)?,
                    session_id: row.get(1)?,
                    signature: FileSignature {
                        size,
                        modified_ns,
                        identity: FileIdentity { device_id, file_id },
                        changed_ns,
                    },
                    prefix_sha256,
                })
            },
        )
        .map_err(|error| format!("无法读取当前补全代次来源：{error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码当前补全代次来源：{error}"))
}

fn migration_markers_complete(
    connection: &Connection,
    replay_migration_complete: bool,
) -> Result<bool, String> {
    Ok(replay_migration_complete
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

fn attribution_safety_state(connection: &Connection) -> Result<AttributionSafetyState, String> {
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

fn rotate_attribution_provenance_epoch(connection: &Connection) -> Result<(), String> {
    set_metadata(
        connection,
        ATTRIBUTION_PROVENANCE_EPOCH_KEY,
        &Uuid::new_v4().to_string(),
    )
}

fn opaque_attribution_source_id(session_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"codex-token-bar-attribution-source-v1\0");
    hasher.update(session_id.as_bytes());
    format!("{:x}", hasher.finalize())
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

fn format_rfc3339_unix(timestamp: i64) -> Option<String> {
    OffsetDateTime::from_unix_timestamp(timestamp)
        .ok()
        .and_then(|value| value.format(&Rfc3339).ok())
}

fn format_rfc3339_nanos(timestamp: u128) -> Option<String> {
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

fn column_exists_checked(
    connection: &Connection,
    table: &str,
    column: &str,
) -> Result<bool, String> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| format!("无法读取 SQLite 表结构 {table}：{error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("无法枚举 SQLite 表结构 {table}：{error}"))?;
    for row in rows {
        let name = row.map_err(|error| format!("无法读取 SQLite 字段 {table}：{error}"))?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
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
