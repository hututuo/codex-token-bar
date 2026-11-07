//! Exact's shared data shapes, durable revision literals and byte encodings.
//!
//! This module performs no storage discovery, open, restore, seal, DB query,
//! transaction or filesystem I/O. Mutable integrity state belongs to connection;
//! candidate migration state remains with the migration coordinator. Fields are
//! visible only to the existing Exact owner unless already part of its facade.
//! StageSourceValidation is an in-process proof and must never be serialized.

use super::super::fingerprint_codec;
use super::super::session_parser::{ExactSessionParserState, SourceByteRange};
use super::super::TokenUsageSummary;
use crate::models::{ActivityDay, CacheHitRankingItem, DashboardStats, LocalDataWarning,
    RecentUsagePoint, TokenCacheUsage};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// v0.9.1 is the only forward-migration baseline for v0.9.2. Earlier and future
// layouts are preserved read-only and rejected instead of being deleted.
pub(super) const INDEX_SCHEMA_VERSION: i64 = 11; // durable structural candidate contract
pub(super) const CURRENT_SCHEMA_VERSION: i64 = 14;
pub(super) const ACCOUNTING_SCHEMA_VERSION: i64 = 13;
pub(super) const GITHUB_BASE_SCHEMA_VERSION: i64 = 9;
// Bump this whenever exact-session parsing changes event or checkpoint
// semantics. The fork-boundary name remains for the main-index migration;
// private staged databases bind the broader parser revision below.
pub(super) const LEGACY_SESSION_PARSER_REVISION: &str = "explicit-subagent-delayed-context-v3";
pub(super) const LEGACY_STAGED_PARSER_REVISION: &str = "components-v1-explicit-subagent-delayed-context-v3";
pub(super) const PAGINATED_V4_PARSER_REVISION: &str = "paginated-subagent-boundary-v4";
pub(super) const PAGINATED_V4_STAGED_REVISION: &str = "components-v1-paginated-subagent-boundary-v4";
pub(super) const PAGINATED_V5_PARSER_REVISION: &str = "paginated-owned-turn-v5";
pub(super) const PAGINATED_V5_STAGED_REVISION: &str = "components-v1-paginated-owned-turn-v5";
pub(super) const PRE_COMPACTION_SESSION_PARSER_REVISION: &str = "paginated-owned-turn-v6";
pub(super) const PRE_COMPACTION_STAGED_PARSER_REVISION: &str = "components-v1-paginated-owned-turn-v6";
pub(super) const EXACT_SESSION_PARSER_REVISION: &str = "paginated-owned-turn-v7-compaction-v1";
// Compaction accounting does not change the ownership boundary rules. Keep
// the boundary receipt on v6 while the broader parser revision advances.
pub(super) const FORK_REPLAY_BOUNDARY_REVISION: &str = PRE_COMPACTION_SESSION_PARSER_REVISION;
pub(in super::super) const PARSER_REPAIR_VERIFY_KEY: &str = "parser_repair_verify_pending";
pub(in super::super) const STAGED_FULL_REBUILD_PARSER_REVISION: &str = "components-v1-paginated-owned-turn-v7-compaction-v1";
// This marker is independent from the parser/schema revisions because it
// records completion of a one-time logical repair for legacy databases that
// were written with foreign-key enforcement disabled. Keep it separate so a
// normal index open can skip the expensive orphan scans after the repair has
// been verified.
pub(in super::super) const ORPHAN_REPAIR_REVISION_KEY: &str = "orphan_repair_revision";
pub(in super::super) const ORPHAN_REPAIR_REVISION: &str = "events-fingerprints-chunks-v1";
pub(super) const EVENT_ENRICHMENT_REVISION_KEY: &str = "event_enrichment_revision";
pub(super) const PRE_COMPACTION_EVENT_ENRICHMENT_REVISION: &str = "model-reasoning-v1";
pub(super) const EVENT_ENRICHMENT_REVISION: &str = "model-reasoning-v2-compaction-v1";
pub(super) const SESSION_CATALOG_SCHEMA_VERSION: i64 = 2;
pub(super) const ATTRIBUTION_PROVENANCE_EPOCH_KEY: &str = "attribution_provenance_epoch";
pub(super) const ATTRIBUTION_LEDGER_EPOCH_KEY: &str = "attribution_ledger_epoch";
pub(super) const ATTRIBUTION_LEDGER_INTEGRITY_KEY: &str = "attribution_ledger_integrity_v1";
pub(super) const ATTRIBUTION_UNSAFE_EPOCH_KEY: &str = "attribution_unsafe_epoch";
pub(super) const ATTRIBUTION_UNSAFE_GENERATION_KEY: &str = "attribution_unsafe_generation";
pub(super) const ATTRIBUTION_UNSAFE_ID_KEY: &str = "attribution_unsafe_id";
pub(super) const ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY: &str = "attribution_current_scan_unsafe";
pub(super) const ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY: &str = "attribution_current_scan_incomplete";
pub(super) const BUILDING_ATTRIBUTION_PROVENANCE_ROTATE_KEY: &str = "building_attribution_provenance_rotate";
// `revision` covers every durable index mutation, including refreshed thread
// titles from state_5.sqlite. Dashboard numeric aggregates do not depend on
// those titles, so keep a separate lineage that only advances when event or
// attribution data changes. This prevents metadata churn from invalidating a
// multi-hundred-thousand-event dashboard cache.
pub(super) const DASHBOARD_REVISION_KEY: &str = "dashboard_revision";
pub(super) const BUILDING_DASHBOARD_CHANGED_KEY: &str = "building_dashboard_changed";
// Dashboard aggregates are disposable, derived data. Keep their version and
// publication watermarks independent from the exact-event schema/parser so an
// upgrade can rebuild them from SQLite without reopening JSONL bodies.
pub(super) const DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY: &str = "dashboard_aggregate_schema_version";
pub(super) const DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY: &str = "dashboard_aggregate_exact_generation";
pub(super) const DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY: &str =
    "dashboard_aggregate_published_generation";
pub(super) const DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY: &str = "dashboard_aggregate_settled_through";
pub(super) const DASHBOARD_AGGREGATE_PRICING_REVISION_KEY: &str = "dashboard_aggregate_pricing_revision";
// Turn candidates are grouped by the originating user message. Cache rate is
// request-weighted across every canonical usage event in that turn. Bump this
// disposable projection version whenever that ranking contract changes so an
// older snapshot-only ranking cannot survive an upgrade.
pub(super) const DASHBOARD_AGGREGATE_SCHEMA_VERSION: i64 = 7;
pub(super) const DASHBOARD_AGGREGATE_PRICING_REVISION: &str = "raw-token-v1";

/// Selects which derived work the in-process exact owner is allowed to do.
/// Both modes use the same durable generation/checkpoint scan; Summary only
/// publishes exact events and lets a later Full owner consume the disposable
/// dashboard work from SQLite.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in super::super) enum ExactSyncMode {
    Summary,
    Full,
}

impl ExactSyncMode {
    pub(super) fn builds_dashboard_derived_data(self) -> bool {
        matches!(self, Self::Full)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(in super::super) struct AttributionSafetyState {
    pub(in super::super) provenance_epoch: String,
    pub(in super::super) generation: u64,
    pub(in super::super) unsafe_since_generation: Option<u64>,
    pub(in super::super) unsafe_id: Option<String>,
    pub(in super::super) current_scan_unsafe_cause_detected: bool,
    pub(in super::super) current_scan_incomplete: bool,
}

/// Read-only identity used to validate a persisted numeric startup envelope.
/// This deliberately does not construct `ExactUsageIndex`: startup must not
/// run schema migration, orphan repair, receipt publication, or quick_check
/// before it can show a trusted last-good snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(in super::super) struct StartupIndexIdentity {
    pub(in super::super) revision: u64,
    pub(in super::super) dashboard_revision: u64,
    pub(in super::super) published_generation: u64,
    pub(in super::super) attribution_safety: AttributionSafetyState,
}

/// Durable derived-aggregate lineage. These values already live in the exact
/// index metadata; this DTO only lets cache and UI code compare the existing
/// facts without introducing a second pending/owner state machine.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in super::super) struct DashboardAggregateIdentity {
    pub(in super::super) schema_version: Option<String>,
    pub(in super::super) pricing_revision: Option<String>,
    pub(in super::super) exact_generation: Option<u64>,
    pub(in super::super) published_generation: Option<u64>,
    #[serde(default)]
    pub(in super::super) settled_through: Option<i64>,
}

#[derive(Default)]
pub(super) struct ExactScanCompleteness {
    pub(super) incomplete_source_scan: bool,
    pub(super) block_generation_publish: bool,
}

#[derive(Default)]
pub(super) struct ExactScanDiagnostics {
    pub(super) candidate_count: u64,
    pub(super) scanned_files: u64,
    pub(super) append_scan_bytes: u64,
    pub(super) metadata_validation_bytes: u64,
    pub(super) metadata_only_files: u64,
    pub(super) full_body_bytes: u64,
    pub(super) pending_tail_bytes: u64,
    pub(super) full_rebuild_files: u64,
    pub(super) source_drift: bool,
    pub(super) published_watermark: u64,
}

impl ExactScanCompleteness {
    pub(super) fn mark_incomplete(&mut self) {
        self.incomplete_source_scan = true;
    }

    pub(super) fn block_publish(&mut self) {
        self.incomplete_source_scan = true;
        self.block_generation_publish = true;
    }
}

pub(in super::super) struct ExactDashboardData {
    pub(in super::super) summary: TokenUsageSummary,
    pub(in super::super) stats: DashboardStats,
    pub(in super::super) activity_days: Vec<ActivityDay>,
    pub(in super::super) recent_usage_24h: Vec<RecentUsagePoint>,
    pub(in super::super) recent_usage_7d: Vec<RecentUsagePoint>,
    pub(in super::super) recent_usage_30d: Vec<RecentUsagePoint>,
    pub(in super::super) cache_hit_ranking: Vec<CacheHitRankingItem>,
    pub(in super::super) cache_usage: TokenCacheUsage,
    pub(in super::super) settled_through: i64,
    pub(in super::super) published: Option<PublishedDashboardReadMetadata>,
}

pub(in super::super) struct PublishedDashboardReadMetadata {
    pub(in super::super) revision: u64,
    pub(in super::super) aggregate: DashboardAggregateIdentity,
    pub(in super::super) attribution: AttributionSafetyState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct FileSignature {
    pub(super) size: u64,
    pub(super) modified_ns: u128,
    pub(super) physical: Option<PhysicalFileStamp>,
}

// A change detector, never a ledger/source identity. Reading this uses only
// filesystem metadata; unchanged JSONL bodies are neither opened for parsing
// nor hashed. Old indexes acquire this optional baseline on their next sync.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct PhysicalFileStamp { pub(super) volume: u64, pub(super) file_id: u64, pub(super) changed_ns: i128 }

impl PhysicalFileStamp {
    pub(super) fn encode(self) -> String { format!("{}:{}:{}", self.volume, self.file_id, self.changed_ns) }
    pub(super) fn decode(value: &str) -> Option<Self> {
        let mut parts = value.split(':');
        let stamp = Self { volume: parts.next()?.parse().ok()?, file_id: parts.next()?.parse().ok()?,
            changed_ns: parts.next()?.parse().ok()? };
        if parts.next().is_some() { None } else { Some(stamp) }
    }
}

#[derive(Clone, Debug)]
pub(super) struct IndexedFileCheckpoint {
    pub(super) generation: i64,
    pub(super) size: u64,
    pub(super) resume_offset: u64,
    pub(super) parser_state: ExactSessionParserState,
    pub(super) audit_chunk_index: u64,
}

#[derive(Clone, Debug)]
pub(super) struct FullRebuildJob {
    pub(super) file: PathBuf,
    pub(super) path: String,
    pub(super) session_id: String,
    pub(super) source_id: i64,
    pub(super) base_generation: i64,
    pub(super) base_resume_offset: Option<u64>,
    pub(super) base_prefix_sha256: Option<[u8; 32]>,
    pub(super) signature: FileSignature,
    pub(super) event_enrichment: bool,
    pub(super) expected_published_prefix_sha256: Option<[u8; 32]>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct StagingSourceBase {
    pub(super) source_id: i64,
    pub(super) generation: i64,
    pub(super) resume_offset: Option<u64>,
    pub(super) prefix_sha256: Option<[u8; 32]>,
}

#[derive(Clone, Debug)]
pub(super) struct EventEnrichmentCandidate {
    pub(super) path: String,
    pub(super) session_id: String,
    pub(super) signature: FileSignature,
    pub(super) prefix_sha256: [u8; 32],
}

#[derive(Clone, Debug)]
pub(super) struct StagedFullRebuild {
    pub(super) job: FullRebuildJob,
    pub(super) committed_signature: FileSignature,
    pub(super) database_path: PathBuf,
    pub(super) artifact_id: String,
    pub(super) actual_bytes: u64,
    pub(super) prefix_sha256: [u8; 32],
    pub(super) resume_offset: u64,
    pub(super) parser_state: ExactSessionParserState,
    pub(super) event_count: u64,
    pub(super) source_validation: Option<StageSourceValidation>,
}

/// Short-lived proof from this owner, bound to the sealed stage and source.
/// Never serialized; recovered stages must first perform a real EOF proof.
#[derive(Clone, Debug)]
pub(super) struct StageSourceValidation {
    pub(super) source: FileSignature,
    pub(super) prefix_sha256: [u8; 32],
    pub(super) artifact_id: String,
    pub(super) stage: StageStoreSignature,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct StageStoreSignature {
    pub(super) size: u64,
    pub(super) modified_ns: u128,
    pub(super) digest: String,
}

pub(super) struct StagedFullRebuildResult {
    pub(super) order: usize,
    pub(super) result: Result<StagedFullRebuild, StagedFullRebuildError>,
    pub(super) warnings: Vec<LocalDataWarning>,
}

pub(super) enum StagedFullRebuildError {
    IncompleteSource(String),
    Fatal(String),
}

impl From<String> for StagedFullRebuildError {
    fn from(error: String) -> Self {
        Self::Fatal(error)
    }
}

pub(super) struct StageManifest {
    pub(super) schema_version: i64,
    pub(super) staging_mode: Option<String>,
    pub(super) source_id: Option<i64>,
    pub(super) base_generation: Option<i64>,
    pub(super) base_resume_offset: Option<i64>,
    pub(super) base_prefix_sha256: Option<Vec<u8>>,
    pub(super) fingerprint_codec_version: Option<i64>,
    pub(super) path: String,
    pub(super) session_id: String,
    pub(super) migration_revision: String,
    pub(super) parser_revision: String,
    pub(super) target_building_generation: i64,
    pub(super) artifact_id: String,
    pub(super) actual_bytes: i64,
    pub(super) integrity: String,
    pub(super) size: i64,
    pub(super) modified_ns: String,
    pub(super) prefix_sha256: Vec<u8>,
    pub(super) resume_offset: i64,
    pub(super) previous_total_tokens: Option<i64>,
    pub(super) fork_replay_started_ns: Option<String>,
    pub(super) fork_replay_active: bool,
    pub(super) is_explicit_subagent_fork: bool,
    pub(super) last_skipped_fork_replay_token_ns: Option<String>,
    pub(super) current_model: Option<String>,
    pub(super) current_user_prompt_start: Option<i64>,
    pub(super) current_user_prompt_end: Option<i64>,
    pub(super) assistant_response_start: Option<i64>,
    pub(super) assistant_response_end: Option<i64>,
    pub(super) event_count: i64,
    pub(super) fingerprint_count: i64,
    pub(super) chunk_count: i64,
    pub(super) accounting_state: Option<String>,
}

impl FileSignature {
    pub(super) fn matches_stored(self, size: u64, modified_ns: &str) -> bool {
        size == self.size && modified_ns.parse::<u128>().ok() == Some(self.modified_ns)
    }

    pub(super) fn matches_physical(self, stored: Option<&str>) -> bool {
        match self.physical {
            Some(observed) => stored.and_then(PhysicalFileStamp::decode) == Some(observed),
            None => true, // Only for platforms without a physical metadata API.
        }
    }
}

pub(super) fn canonicalize_legacy_fingerprint(
    value: rusqlite::types::ValueRef<'_>,
) -> Result<Vec<u8>, String> {
    let values = match value {
        rusqlite::types::ValueRef::Blob(bytes) => {
            if let Ok(values) = fingerprint_codec::decode(bytes) {
                values
            } else {
                fingerprint_codec::decode_legacy_fixed_width(bytes)
                    .map_err(|error| format!("旧精确 token BLOB 指纹无法转换：{error}"))?
            }
        }
        rusqlite::types::ValueRef::Text(bytes) => {
            let text = std::str::from_utf8(bytes)
                .map_err(|error| format!("旧精确 token 文本指纹不是 UTF-8：{error}"))?;
            fingerprint_codec::decode_legacy_text(text)
                .map_err(|error| format!("旧精确 token 文本指纹无法转换：{error}"))?
        }
        _ => return Err("旧精确 token 指纹既不是 BLOB 也不是 TEXT".into()),
    };
    fingerprint_codec::encode(&values)
        .map_err(|error| format!("旧精确 token 指纹无法编码为 schema 11：{error}"))
}

pub(super) fn sqlite_sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

pub(super) fn checked_i64(value: u64, label: &str) -> Result<i64, String> {
    i64::try_from(value).map_err(|_| format!("{label}超出 SQLite 精确整数范围"))
}

pub(super) fn checked_optional_i64(value: Option<u64>, label: &str) -> Result<Option<i64>, String> {
    value.map(|value| checked_i64(value, label)).transpose()
}

pub(super) const SESSION_CATALOG_SCHEMA_COLUMNS: &[&str] = &[
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
    "first_line_bytes",
    "first_line_sha256",
    "last_seen_generation",
];

pub(super) fn source_range_from_columns(start: Option<i64>, end: Option<i64>) -> Option<SourceByteRange> {
    let start = u64::try_from(start?).ok()?;
    let end = u64::try_from(end?).ok()?;
    (end >= start).then_some(SourceByteRange { start, end })
}


pub(super) const FIVE_MINUTE_INTERVAL_SECONDS: i64 = 5 * 60;
pub(super) const AGGREGATE_BOUNDARY_GRACE_SECONDS: i64 = 15;

pub(super) fn nonnegative_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

pub(super) fn saturating_u32(value: i64) -> u32 {
    if value <= 0 {
        0
    } else {
        u32::try_from(value).unwrap_or(u32::MAX)
    }
}
