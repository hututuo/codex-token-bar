//! Authoritative scans, append checkpoints and staged-source ingestion.
//!
//! Discovery supplies hints only; the opened source and existing prefix proofs
//! define the accepted boundary. SqliteEventSink binds the pending ledger;
//! StagingEventSink writes a private artifact. They are intentionally distinct.
//!
//! Import validates and mounts the same restored pool snapshot, then commits
//! only pending associations. The root finalize_generation is the sole owner
//! of consumption receipts and final publication. Reclaim requests before that
//! commit can be no-ops. stage_pool owns its state/locks/codec and stays separate.
//! All production handles retain the Connection/Transaction binding contract;
//! private TEMP builders keep their original unbound scratch connection.

use super::connection::{Connection, Transaction, existing_regular_index,
    open_read_only_index, quick_check_staged, invalidate_index_integrity_signature};
#[cfg(not(test))]
use super::connection::open_exact_business_store;
use super::contracts::{FileSignature, PhysicalFileStamp, ExactScanCompleteness,
    ExactScanDiagnostics, ExactSyncMode, IndexedFileCheckpoint, FullRebuildJob,
    StagingSourceBase, StagedFullRebuild, StageSourceValidation, StageStoreSignature,
    StagedFullRebuildResult, StagedFullRebuildError, StageManifest, EventEnrichmentCandidate,
    checked_i64, checked_optional_i64, nonnegative_u64, source_range_from_columns,
    canonicalize_legacy_fingerprint, sqlite_sidecar_path, CURRENT_SCHEMA_VERSION,
    STAGED_FULL_REBUILD_PARSER_REVISION, EXACT_SESSION_PARSER_REVISION,
    LEGACY_STAGED_PARSER_REVISION, LEGACY_SESSION_PARSER_REVISION,
    PAGINATED_V4_STAGED_REVISION, PAGINATED_V4_PARSER_REVISION,
    PAGINATED_V5_STAGED_REVISION, PAGINATED_V5_PARSER_REVISION,
    PRE_COMPACTION_STAGED_PARSER_REVISION, PRE_COMPACTION_SESSION_PARSER_REVISION,
    PRE_COMPACTION_EVENT_ENRICHMENT_REVISION, EVENT_ENRICHMENT_REVISION};
use super::store_metadata::{metadata_i64, metadata_text, set_metadata,
    column_exists_checked, table_exists_checked};
use super::sources::{file_signature, file_signature_from_handle, lightweight_file_signature,
    record_source_observation, is_history_repair_workspace};
use super::projections::{mark_dashboard_changed, refresh_dashboard_file_aggregates,
    update_dashboard_append_aggregates};
use super::{empty_sources, ledger, representations, runtime_recovery, stage_pool,
    ensure_active_build_generation, delete_file_version_rows, relative_display_path,
    scan_warning, run_after_prefix_scan_hook_for_testing, run_after_file_commit_hook_for_testing,
    run_before_staging_open_hook_for_testing};
use super::super::accounting::AccountingState;
use super::super::fingerprint_codec;
use super::super::rollout_source::{self, RolloutReader, SourceHandle};
use super::super::session_files::session_id_from_file;
use super::super::session_parser::{ExactSessionEventSink, UsageSnapshotFingerprint,
    ExactTokenEvent, ExactSessionParserState, ExactChunkHash, EXACT_INDEX_CHUNK_SIZE,
    stream_session_file_exact_from, stream_session_file_exact_with_progress};
use crate::models::LocalDataWarning;
use fs2::available_space;
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration as StdDuration;
use time::OffsetDateTime;
use uuid::Uuid;
#[cfg(test)]
use super::{FULL_SCAN_BYTES, APPEND_SCAN_BYTES, METADATA_VALIDATION_BYTES,
    STAGE_ACTIVE_WORKERS, STAGE_PEAK_WORKERS, STAGE_DELAY_MILLISECONDS, PREFIX_REHASH_COUNT};

const PARALLEL_HEAVY_FILE_BYTES: u64 = 512 * 1024 * 1024;
const STAGING_MAX_WORKERS: usize = 4;
const STAGING_MAX_READY_ARTIFACTS: usize = 8;
const STAGING_MAX_READY_BYTES: u64 = 512 * 1024 * 1024;
pub(super) const STAGING_MIN_FREE_RESERVE_BYTES: u64 = 64 * 1024 * 1024;
pub(super) const STAGING_MANIFEST_SCHEMA_VERSION: i64 = 3;
const STAGING_MANIFEST_INTEGRITY: &str = "sqlite-quick-check-v1";
/// Writes through the caller's indexed append transaction and records ledger
/// bindings/corrections. Do not merge with the private artifact sink below.
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
        let encoded = encode_fingerprint(fingerprint)?;
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
                    assistant_response_end, accounting_kind, reported_total_tokens, token_source_offset
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
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
                    event.accounting_kind,
                    checked_optional_i64(event.reported_total_tokens, "reported total")?,
                    checked_i64(event.token_source_offset, "token byte offset")?,
                ],
            )
            .map_err(|error| format!("无法写入精确 token 事件索引：{error}"))?;
        ledger::record_append(self.transaction,self.file_path,self.ordinal,event)?;
        Ok(())
    }

    fn upsert_compaction_event(&mut self, event: &ExactTokenEvent) -> Result<bool, String> {
        match ledger::upsert_compaction_event(self.transaction, self.file_path, event)? {
            ledger::CompactionEventDisposition::Insert => {
                self.insert_event(event)?;
                Ok(true)
            }
            ledger::CompactionEventDisposition::Existing
            | ledger::CompactionEventDisposition::Corrected => Ok(false),
        }
    }
}

/// Writes only private stage events/fingerprints; it has no final ledger binding
/// authority. Compaction corrections here are local to that staged event set.
struct StagingEventSink<'transaction> {
    transaction: &'transaction Transaction<'transaction>,
    ordinal: u64,
}

impl ExactSessionEventSink for StagingEventSink<'_> {
    fn insert_fingerprint(
        &mut self,
        fingerprint: &UsageSnapshotFingerprint,
    ) -> Result<bool, String> {
        let encoded = encode_fingerprint(fingerprint)?;
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
                    assistant_response_end, accounting_kind, reported_total_tokens, token_source_offset, usage_fingerprint
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
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
                    event.accounting_kind,
                    checked_optional_i64(event.reported_total_tokens, "reported total")?,
                    checked_i64(event.token_source_offset, "token byte offset")?,
                    event.usage_fingerprint,
                ],
            )
            .map(|_| ())
            .map_err(|error| format!("无法写入精确 token 暂存事件：{error}"))
    }

    fn upsert_compaction_event(&mut self, event: &ExactTokenEvent) -> Result<bool, String> {
        if let Some(fingerprint) = event.usage_fingerprint.as_deref() {
            let existing_ordinal: Option<i64> = self.transaction.query_row(
                "SELECT ordinal FROM events WHERE usage_fingerprint=?1 ORDER BY ordinal LIMIT 1",
                params![fingerprint],
                |row| row.get(0),
            ).optional().map_err(|error| format!("无法查找暂存 compaction 响应：{error}"))?;
            if let Some(ordinal) = existing_ordinal {
                self.transaction.execute(
                    "UPDATE events SET timestamp=?1,tokens=?2,input_tokens=?3,cached_input_tokens=?4,output_tokens=?5,reasoning_output_tokens=?6,model=COALESCE(model,?7),accounting_kind=?8,reported_total_tokens=?9,token_source_offset=?10 WHERE ordinal=?11",
                    params![event.timestamp.unix_timestamp(), checked_i64(event.tokens,"暂存 compaction token")?, checked_i64(event.input_tokens,"暂存 compaction input")?, checked_i64(event.cached_input_tokens,"暂存 compaction cached input")?, checked_i64(event.output_tokens,"暂存 compaction output")?, checked_i64(event.reasoning_output_tokens,"暂存 compaction reasoning")?, event.model, event.accounting_kind, checked_optional_i64(event.reported_total_tokens,"暂存 compaction reported total")?, checked_i64(event.token_source_offset,"暂存 compaction offset")?, ordinal],
                ).map_err(|error| format!("无法修正暂存 compaction 响应：{error}"))?;
                return Ok(false);
            }
        }
        self.insert_event(event)?;
        Ok(true)
    }
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

fn encode_fingerprint(fingerprint: &UsageSnapshotFingerprint) -> Result<Vec<u8>, String> {
    fingerprint_codec::encode(fingerprint)
        .map_err(|error| format!("无法编码精确 token 去重指纹：{error}"))
}

pub(super) fn stage_full_rebuilds(
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

pub(super) fn staging_job_batches(jobs: &[FullRebuildJob]) -> Vec<Vec<FullRebuildJob>> {
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
pub(in super::super) fn staging_batch_shape_for_testing(sizes: &[u64]) -> Vec<Vec<u64>> {
    let jobs = sizes
        .iter()
        .enumerate()
        .map(|(index, size)| FullRebuildJob {
            file: PathBuf::from(format!("/tmp/staging-batch-{index}.jsonl")),
            path: format!("/tmp/staging-batch-{index}.jsonl"),
            session_id: format!("staging-batch-{index}"),
            source_id: i64::try_from(index).unwrap_or(0).saturating_add(1),
            base_generation: 0,
            base_resume_offset: None,
            base_prefix_sha256: None,
            signature: FileSignature {
                size: *size,
                modified_ns: 0,
                physical: None,
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

pub(super) fn ensure_staging_capacity(index_path: &Path, estimated_bytes: u64) -> Result<(), String> {
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

pub(super) fn stage_or_reuse_full_rebuild(
    job: &FullRebuildJob,
    index_path: &Path,
    target_generation: i64,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<StagedFullRebuild, StagedFullRebuildError> {
    let primary_path = staging_database_path(index_path, &job.path);
    let existing_paths = staging_database_paths(index_path, &job.path)?;
    let mut blocked = false;
    let mut preserved_other_request = false;
    for database_path in &existing_paths {
        if !existing_regular_index(database_path)? {
            continue;
        }
        if superseded_compaction_private_stage(database_path, job)? {
            preserve_private_stage_family(database_path)?;
            continue;
        }
        if restartable_private_stage(database_path, job)? {
            preserve_private_stage_family(database_path)?;
            continue;
        }
        if let Some(staged) = reusable_staged_full_rebuild(database_path, job, target_generation)? {
            return Ok(staged);
        }
        if runtime_recovery::valid_for_earlier_request(database_path, job, target_generation)? {
            // A validated completed artifact is evidence for its own bound,
            // not corruption and not permission to overwrite that artifact.
            preserved_other_request = true;
            continue;
        }
        blocked = true;
    }
    let database_path = if preserved_other_request {
        runtime_recovery::candidate_path(index_path, job, target_generation)
    } else {
        primary_path.clone()
    };
    if blocked || existing_regular_index(&database_path)? {
        return Err(StagedFullRebuildError::Fatal(format!(
            "精确 token 现有暂存未通过内容与 checkpoint 验证，已保留暂存和上一代统计；需要修复后重试：{}", database_path.display()
        )));
    }
    // Also preserve sidecars left by interruption between family renames.
    preserve_private_stage_family(&database_path)?;
    build_staged_full_rebuild(job, database_path, index_path, target_generation, codex_home, warnings)
}

fn build_staged_full_rebuild(
    job: &FullRebuildJob,
    database_path: PathBuf,
    index_path: &Path,
    target_generation: i64,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<StagedFullRebuild, StagedFullRebuildError> {
    let _activity = StageActivityGuard::begin();
    #[cfg(test)]
    empty_sources::STAGED_DATABASE_BUILDS.fetch_add(1, Ordering::SeqCst);
    run_before_staging_open_hook_for_testing(&job.file);
    let mut handle = RolloutReader::open(&job.file).map_err(|error| {
        StagedFullRebuildError::IncompleteSource(format!(
            "读取精确 token 暂存源文件失败：{}（{}）",
            job.file.display(),
            error
        ))
    })?;
    let current_signature = file_signature_from_handle(&handle, &job.file)
        .map_err(StagedFullRebuildError::IncompleteSource)?;
    if current_signature.size < job.signature.size {
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
    #[cfg(test)]
    let mut stage = open_staging_connection(&database_path)?;
    #[cfg(not(test))]
    let mut stage = Connection::unbound(rusqlite::Connection::open("").map_err(|e|e.to_string())?);
    initialize_staging_schema(&stage)?;
    let staging_behavior = if cfg!(test) {
        TransactionBehavior::Immediate
    } else {
        // The parser writes only to TEMP tables. A deferred transaction keeps
        // the shared A container available to quota and other module writers.
        TransactionBehavior::Deferred
    };
    let transaction = stage
        .transaction_with_behavior(staging_behavior)
        .map_err(|error| format!("无法开始精确 token 单文件暂存事务：{error}"))?;
    let mut sink = StagingEventSink {
        transaction: &transaction,
        ordinal: 0,
    };
    let source_progress = super::precise_source_read_progress(codex_home);
    let parsed = stream_session_file_exact_with_progress(
        &job.file,
        &mut handle,
        committed_signature.size,
        &job.session_id,
        &mut sink,
        warnings,
        source_progress.as_ref().map(|callback| callback as &dyn Fn(u64, u64)),
    )
    .map_err(StagedFullRebuildError::IncompleteSource)?;
    let event_count = sink.ordinal;
    drop(sink);
    #[cfg(feature = "business-store-fixture")]
    crate::business_store_fixture::assert_concurrent_a_write()?;
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
                manifest_schema_version,
                staging_mode,
                source_id,
                base_generation,
                base_resume_offset,
                base_prefix_sha256,
                fingerprint_codec_version,
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
                chunk_count, accounting_state, physical_stamp
            ) VALUES (0, ?1, 'full', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 0, '', ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31)
            "#,
            params![
                STAGING_MANIFEST_SCHEMA_VERSION,
                job.source_id,
                job.base_generation,
                checked_optional_i64(job.base_resume_offset, "暂存基础续扫位置")?,
                job.base_prefix_sha256
                    .as_ref()
                    .map(|value| value.as_slice()),
                i64::from(fingerprint_codec::FINGERPRINT_VERSION),
                &job.path,
                &job.session_id,
                migration_revision,
                STAGED_FULL_REBUILD_PARSER_REVISION,
                target_generation,
                &artifact_id,
                checked_i64(committed_signature.size, "暂存会话文件大小")?,
                committed_signature.modified_ns.to_string(),
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
                state.accounting_state.as_ref().map(AccountingState::encode),
                committed_signature.physical.map(PhysicalFileStamp::encode),
            ],
        )
        .map_err(|error| format!("无法完成精确 token 单文件暂存清单：{error}"))?;
    transaction
        .commit()
        .map_err(|error| format!("无法耐久提交精确 token 单文件暂存：{error}"))?;
    quick_check_staged(&stage)?;

    #[cfg(test)]
    let actual_bytes = {
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
    actual_bytes
    };

    #[cfg(not(test))]
    let (database_path, actual_bytes) = {
        stage.execute("UPDATE manifest SET complete=1,actual_bytes=0,integrity=?1 WHERE complete=0 AND artifact_id=?2",params![STAGING_MANIFEST_INTEGRITY,artifact_id]).map_err(|e|e.to_string())?;
        let raw=stage.unbound_connection().map_err(|e|e.to_string())?;
        let actual_bytes=stage_pool::Pool::footprint(raw)?;
        stage.execute("UPDATE manifest SET actual_bytes=?1 WHERE complete=1 AND artifact_id=?2",params![checked_i64(actual_bytes,"暂存实际大小")?,artifact_id]).map_err(|e|e.to_string())?;
        let pool=stage_pool::Pool::current()?;
        #[cfg(feature = "business-store-fixture")]
        let lookup_opens = crate::core::business_store_container::fixture_existing_open_count();
        let target=pool.existing_exact_store_spec(index_path)?;
        #[cfg(feature = "business-store-fixture")]
        stage_pool::fixture_assert_held_lookup(lookup_opens, false)?;
        // All numeric identity fields are decimal strings; no JSON number can
        // round a timestamp/Int64 or change the typed payload codec.
        let contract=serde_json::to_vec(&serde_json::json!([
            job.source_id.to_string(),job.base_generation.to_string(),job.base_resume_offset.map(|v|v.to_string()),
            job.base_prefix_sha256.map(|v|format!("{v:x?}")),target_generation.to_string(),migration_revision,
            STAGED_FULL_REBUILD_PARSER_REVISION,committed_signature.size.to_string(),committed_signature.modified_ns.to_string(),
            committed_signature.physical.map(PhysicalFileStamp::encode),format!("{:x?}",parsed.prefix_sha256)
        ])).map_err(|e|e.to_string())?;
        let pooled=pool.job(&target,&job.path,&contract)?;
        pool.persist(&pooled,raw)?;
        (pooled.path,actual_bytes)
    };

    let stage_signature = staged_store_signature(&database_path)?;
    Ok(StagedFullRebuild {
        source_validation: Some(StageSourceValidation { source: committed_signature,
            prefix_sha256: parsed.prefix_sha256, artifact_id: artifact_id.clone(), stage: stage_signature }),
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

#[cfg(all(windows, test))]
struct StagingDatabaseSyncHandle {
    file: fs::File,
}

#[cfg(not(all(windows, test)))]
struct StagingDatabaseSyncHandle;

fn prepare_staging_database_sync(path: &Path) -> Result<StagingDatabaseSyncHandle, String> {
    #[cfg(all(windows, test))]
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
            .map_err(|error| {
                format!(
                    "无法打开精确 token 暂存耐久句柄 {}：{error}",
                    path.display()
                )
            })
    }

    #[cfg(not(all(windows, test)))]
    {
        let _ = path;
        Ok(StagingDatabaseSyncHandle)
    }
}

fn sync_staging_database(path: &Path, handle: &StagingDatabaseSyncHandle) -> Result<(), String> {
    #[cfg(all(windows, test))]
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

    #[cfg(all(not(windows), test))]
    {
        let _ = handle;
        fs::OpenOptions::new()
            .read(true)
            .open(path)
            .and_then(|file| file.sync_all())
            .map_err(|error| format!("无法同步精确 token 暂存文件：{error}"))
    }

    #[cfg(not(test))]
    {
        let _ = handle;
        crate::core::business_store_route::seal_exact_store(path)
    }
}

/// Effectful observation: pool lookup checks the existing seal; a legacy store
/// lacking an observation can be sealed here. Never treat this as plain stat.
fn staged_store_signature(path: &Path) -> Result<StageStoreSignature, String> {
    #[cfg(not(test))]
    if stage_pool::is_path(path) {
        let pool=stage_pool::Pool::current()?;
        let job=pool.lookup(path)?.ok_or("暂存job不存在")?;
        let seal=pool.seal(&job)?.ok_or("暂存job尚未封存")?;
        return Ok(StageStoreSignature{size:seal.bytes,modified_ns:(seal.time*1_000_000_000.0).round() as u128,digest:seal.digest});
    }
    #[cfg(not(test))]
    {
        if crate::core::business_store_route::exact_store_observation(path)?.is_none() {
            crate::core::business_store_route::seal_exact_store(path)?;
        }
        let (size, _, digest, sealed_at) = crate::core::business_store_route::exact_store_observation(path)?
            .ok_or_else(|| "精确 token 暂存分区缺少封存证明".to_string())?;
        let modified_ns = (sealed_at * 1_000_000_000.0).round();
        if !modified_ns.is_finite() || modified_ns < 0.0 {
            return Err("精确 token 暂存封存时间无效".into());
        }
        return Ok(StageStoreSignature {
            size,
            modified_ns: modified_ns as u128,
            digest,
        });
    }
    #[cfg(test)]
    {
        let signature = file_signature(path)?;
        Ok(StageStoreSignature {
            size: signature.size,
            modified_ns: signature.modified_ns,
            digest: signature.physical.map_or_else(String::new, PhysicalFileStamp::encode),
        })
    }
}

fn staged_store_size(path: &Path) -> Result<u64, String> {
    staged_store_signature(path).map(|signature| signature.size)
}

pub(super) fn open_staging_connection(path: &Path) -> Result<Connection, String> {
    #[cfg(test)]
    let connection = Connection::open(path).map_err(|error| {
        format!(
            "无法打开精确 token 单文件暂存 {}：{}",
            path.display(),
            error
        )
    })?;
    #[cfg(not(test))]
    let connection = open_exact_business_store(path)?;
    connection
        .busy_timeout(StdDuration::from_secs(30))
        .map_err(|error| format!("无法设置精确 token 暂存等待时间：{error}"))?;
    #[cfg(test)]
    let staging_pragmas = "PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA temp_store = FILE; PRAGMA cache_size = -4096;";
    #[cfg(not(test))]
    let staging_pragmas = "PRAGMA synchronous = FULL; PRAGMA temp_store = FILE; PRAGMA cache_size = -4096;";
    connection
        .execute_batch(
            staging_pragmas,
        )
        .map_err(|error| format!("无法配置精确 token 单文件暂存：{error}"))?;
    Ok(connection)
}

fn initialize_staging_schema(connection: &Connection) -> Result<(), String> {
    #[cfg(not(test))]
    if connection.is_bound() {
        return Err("新Exact任务不得创建逐源暂存namespace".into());
    }
    connection
        .execute_batch(&staging_schema_sql(false))
        .map_err(|error| format!("无法初始化精确 token 单文件暂存结构：{error}"))
}

pub(super) fn staging_schema_sql(temporary: bool) -> String {
    let create_table = if temporary { "TEMP TABLE" } else { "TABLE" };
    format!(
        r#"
            CREATE {create_table} manifest (
                complete INTEGER PRIMARY KEY CHECK(complete IN (0, 1)),
                manifest_schema_version INTEGER NOT NULL,
                staging_mode TEXT NOT NULL CHECK(staging_mode IN ('full', 'delta')),
                source_id INTEGER NOT NULL,
                base_generation INTEGER NOT NULL,
                base_resume_offset INTEGER,
                base_prefix_sha256 BLOB,
                fingerprint_codec_version INTEGER NOT NULL,
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
                chunk_count INTEGER NOT NULL,
                accounting_state TEXT,
                physical_stamp TEXT
            ) WITHOUT ROWID;

            CREATE {create_table} fingerprints (
                fingerprint BLOB PRIMARY KEY
            ) WITHOUT ROWID;

            CREATE {create_table} events (
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
                assistant_response_end INTEGER,
                accounting_kind INTEGER NOT NULL DEFAULT 0, reported_total_tokens INTEGER, token_source_offset INTEGER, usage_fingerprint BLOB
            ) WITHOUT ROWID;

            CREATE {create_table} chunks (
                chunk_index INTEGER PRIMARY KEY,
                byte_count INTEGER NOT NULL,
                sha256 BLOB NOT NULL
            ) WITHOUT ROWID;
            "#
    )
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
        let stage = open_read_only_index(database_path, StdDuration::from_secs(1))
            .map_err(|error| format!("无法只读打开精确 token 单文件暂存：{error}"))?;
        validated_staged_full_rebuild(&stage, database_path, job, target_generation, None)
    })();
    match reusable {
        Ok(Some(staged)) => Ok(Some(staged)),
        Ok(None) => Ok(None),
        Err(error) => Err(error),
    }
}

/// Validates the supplied stage handle and original manifest/checkpoint proof.
/// This can read source bytes and staged_store_signature may seal a legacy
/// namespace. Import must mount the very pool snapshot validated by this call.
pub(super) fn validated_staged_full_rebuild(
    connection: &Connection,
    database_path: &Path,
    job: &FullRebuildJob,
    target_generation: i64,
    proof: Option<&StageSourceValidation>,
) -> Result<Option<StagedFullRebuild>, String> {
    quick_check_staged(connection)?;
    let manifest_schema_version =
        if column_exists_checked(connection, "manifest", "manifest_schema_version")? {
            connection
                .query_row(
                    "SELECT manifest_schema_version FROM manifest LIMIT 1",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .optional()
                .map_err(|error| format!("无法读取精确 token 暂存 schema：{error}"))?
                .unwrap_or(STAGING_MANIFEST_SCHEMA_VERSION)
        } else {
            1
        };
    if manifest_schema_version > STAGING_MANIFEST_SCHEMA_VERSION {
        return Err(format!(
            "精确 token 暂存 schema {manifest_schema_version} 高于当前支持版本 {STAGING_MANIFEST_SCHEMA_VERSION}，已保留原暂存"
        ));
    }
    if !matches!(
        manifest_schema_version,
        1 | 2 | STAGING_MANIFEST_SCHEMA_VERSION
    ) {
        return Ok(None);
    }
    let accounting_column = if column_exists_checked(connection,"manifest","accounting_state")? { "accounting_state" } else { "NULL" };
    let physical_stamp = if column_exists_checked(connection, "manifest", "physical_stamp")? {
        connection.query_row("SELECT physical_stamp FROM manifest WHERE complete=1 LIMIT 1", [],
            |row| row.get::<_, Option<String>>(0)).optional().map_err(|error| error.to_string())?.flatten()
    } else { None };
    let manifest = connection
        .query_row(
            &format!(r#"
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
                chunk_count, {accounting_column}
            FROM manifest
            WHERE complete = 1
            LIMIT 1
            "#),
            [],
            |row| {
                Ok(StageManifest {
                    schema_version: manifest_schema_version,
                    staging_mode: None,
                    source_id: None,
                    base_generation: None,
                    base_resume_offset: None,
                    base_prefix_sha256: None,
                    fingerprint_codec_version: None,
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
                    prefix_sha256: row.get(10)?,
                    resume_offset: row.get(11)?,
                    previous_total_tokens: row.get(12)?,
                    fork_replay_started_ns: row.get(13)?,
                    fork_replay_active: row.get(14)?,
                    is_explicit_subagent_fork: row.get(15)?,
                    last_skipped_fork_replay_token_ns: row.get(16)?,
                    current_model: row.get(17)?,
                    current_user_prompt_start: row.get(18)?,
                    current_user_prompt_end: row.get(19)?,
                    assistant_response_start: row.get(20)?,
                    assistant_response_end: row.get(21)?,
                    event_count: row.get(22)?,
                    fingerprint_count: row.get(23)?,
                    chunk_count: row.get(24)?,
                    accounting_state: row.get(25)?,
                })
            },
        )
        .optional()
        .map_err(|error| format!("无法读取精确 token 单文件暂存清单：{error}"))?;
    let Some(manifest) = manifest else {
        return Ok(None);
    };
    let mut manifest = manifest;
    if manifest_schema_version == STAGING_MANIFEST_SCHEMA_VERSION {
        let v3 = connection
            .query_row(
                r#"
                SELECT staging_mode, source_id, base_generation,
                       base_resume_offset, base_prefix_sha256,
                       fingerprint_codec_version
                FROM manifest
                WHERE complete = 1
                LIMIT 1
                "#,
                [],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, Option<Vec<u8>>>(4)?,
                        row.get::<_, i64>(5)?,
                    ))
                },
            )
            .map_err(|error| format!("无法读取精确 token v3 暂存证明：{error}"))?;
        manifest.staging_mode = Some(v3.0);
        manifest.source_id = Some(v3.1);
        manifest.base_generation = Some(v3.2);
        manifest.base_resume_offset = v3.3;
        manifest.base_prefix_sha256 = v3.4;
        manifest.fingerprint_codec_version = Some(v3.5);
    }
    let expected_migration_revision = if job.event_enrichment {
        EVENT_ENRICHMENT_REVISION
    } else {
        "exact-source-rebuild-v1"
    };
    let manifest_signature = match (
        u64::try_from(manifest.size),
        manifest.modified_ns.parse::<u128>(),
    ) {
        (Ok(size), Ok(modified_ns)) => FileSignature { size, modified_ns,
            physical: physical_stamp.as_deref().and_then(PhysicalFileStamp::decode) },
        _ => return Ok(None),
    };
    if [LEGACY_STAGED_PARSER_REVISION, LEGACY_SESSION_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION, PAGINATED_V4_PARSER_REVISION, PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION].contains(&manifest.parser_revision.as_str())
        && super::session_parser::paginated_subagent_boundary(&mut RolloutReader::open(&job.file).map_err(|e| e.to_string())?)?.is_some() {
        return Ok(None);
    }
    let artifact_bytes = staged_store_size(database_path)?;
    if manifest.path != job.path
        || manifest.session_id != job.session_id
        || manifest.migration_revision != expected_migration_revision
        || ![STAGED_FULL_REBUILD_PARSER_REVISION, EXACT_SESSION_PARSER_REVISION, LEGACY_STAGED_PARSER_REVISION, LEGACY_SESSION_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION, PAGINATED_V4_PARSER_REVISION, PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION].contains(&manifest.parser_revision.as_str())
        || manifest.target_building_generation != target_generation
        || manifest.artifact_id.trim().is_empty()
        || manifest.integrity != STAGING_MANIFEST_INTEGRITY
        || manifest.actual_bytes < 0
        || nonnegative_u64(manifest.actual_bytes) != artifact_bytes
        || !matches!(
            manifest.schema_version,
            1 | 2 | STAGING_MANIFEST_SCHEMA_VERSION
        )
        || manifest_signature.size < job.signature.size
        || (job.event_enrichment
            && job.expected_published_prefix_sha256.is_some()
            && !manifest_signature.matches_stored(job.signature.size, &job.signature.modified_ns.to_string()))
        || manifest.size < 0
        || manifest.resume_offset < 0
        || nonnegative_u64(manifest.resume_offset) > manifest_signature.size
        || manifest.event_count < 0
        || manifest.fingerprint_count < 0
        || manifest.chunk_count < 0
    {
        return Ok(None);
    }
    if manifest_schema_version == STAGING_MANIFEST_SCHEMA_VERSION {
        let expected_base_resume_offset = job
            .base_resume_offset
            .map(|value| checked_i64(value, "暂存基础续扫位置"))
            .transpose()?;
        let expected_base_prefix = job
            .base_prefix_sha256
            .as_ref()
            .map(|value| value.as_slice());
        if manifest.staging_mode.as_deref() != Some("full")
            || manifest.source_id != Some(job.source_id)
            || manifest.base_generation != Some(job.base_generation)
            || manifest.base_resume_offset != expected_base_resume_offset
            || manifest.base_prefix_sha256.as_deref() != expected_base_prefix
            || manifest.fingerprint_codec_version
                != Some(i64::from(fingerprint_codec::FINGERPRINT_VERSION))
        {
            return Ok(None);
        }
    }
    let prefix_sha256: [u8; 32] = match manifest.prefix_sha256.as_slice().try_into() {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    let stage_signature = staged_store_signature(database_path)?;
    let known = (manifest_signature.size, manifest_signature.modified_ns.to_string(),
        manifest_signature.physical.map(|stamp| stamp.encode()));
    let reusable_proof = proof.is_some_and(|proof| proof.source == manifest_signature
        && proof.source.physical.is_some() && proof.prefix_sha256 == prefix_sha256
        && proof.artifact_id == manifest.artifact_id && proof.stage == stage_signature
        && lightweight_file_signature(&job.file, Some(&known)).ok().flatten() == Some(manifest_signature));
    if !reusable_proof {
        let mut source_handle = match RolloutReader::open(&job.file) {
            Ok(handle) => handle,
            Err(_) => return Ok(None),
        };
        if validate_same_file_prefix(&job.file, &mut source_handle, manifest_signature, prefix_sha256).is_err() {
            return Ok(None);
        }
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
            SELECT EXISTS(SELECT 1 FROM chunks WHERE length(sha256) <> 32)
            "#,
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法验证精确 token 暂存哈希形状：{error}"))?;
    let mut fingerprint_statement = connection
        .prepare("SELECT fingerprint FROM fingerprints")
        .map_err(|error| format!("无法准备精确 token 暂存指纹验证：{error}"))?;
    let mut fingerprint_rows = fingerprint_statement
        .query([])
        .map_err(|error| format!("无法读取精确 token 暂存指纹：{error}"))?;
    let mut malformed_fingerprint = false;
    while let Some(row) = fingerprint_rows
        .next()
        .map_err(|error| format!("无法遍历精确 token 暂存指纹：{error}"))?
    {
        let value = row
            .get_ref(0)
            .map_err(|error| format!("无法解码精确 token 暂存指纹列：{error}"))?;
        let valid = match value {
            rusqlite::types::ValueRef::Blob(bytes) => {
                if manifest_schema_version == STAGING_MANIFEST_SCHEMA_VERSION {
                    fingerprint_codec::decode(bytes).is_ok()
                } else {
                    fingerprint_codec::decode_legacy_fixed_width(bytes).is_ok()
                        || fingerprint_codec::decode(bytes).is_ok()
                }
            }
            rusqlite::types::ValueRef::Text(bytes)
                if manifest_schema_version < STAGING_MANIFEST_SCHEMA_VERSION =>
            {
                std::str::from_utf8(bytes)
                    .ok()
                    .is_some_and(|value| fingerprint_codec::decode_legacy_text(value).is_ok())
            }
            _ => false,
        };
        if !valid {
            malformed_fingerprint = true;
            break;
        }
    }
    drop(fingerprint_rows);
    drop(fingerprint_statement);
    let expected_chunks = manifest_signature
        .size
        .checked_sub(1)
        .map_or(0, |offset| offset / EXACT_INDEX_CHUNK_SIZE + 1);
    if event_count != manifest.event_count
        || fingerprint_count != manifest.fingerprint_count
        || chunk_count != manifest.chunk_count
        || nonnegative_u64(chunk_count) != expected_chunks
        || malformed_hashes
        || malformed_fingerprint
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
        source_validation: Some(StageSourceValidation { source: manifest_signature,
            prefix_sha256, artifact_id: manifest.artifact_id.clone(), stage: stage_signature }),
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
            accounting_state: if [STAGED_FULL_REBUILD_PARSER_REVISION, LEGACY_STAGED_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION, PAGINATED_V5_STAGED_REVISION].contains(&manifest.parser_revision.as_str()) { AccountingState::decode(manifest.accounting_state)? } else { None },
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

/// The pool path restores once, validates that handle, checks its seal identity,
/// then mounts that same immutable work image. The IMMEDIATE import commits
/// pending associations only; consumption belongs to root finalize_generation.
/// Preserve the legacy/test attach branches and import-before-detach errors.
pub(super) fn import_staged_full_rebuild(
    connection: &mut Connection,
    generation: i64,
    staged: &StagedFullRebuild,
    mode: ExactSyncMode,
) -> Result<(), String> {
    #[cfg(all(feature = "business-store-fixture", not(test)))]
    let restores_before_import = stage_pool::fixture_restore_count();
    #[cfg(not(test))]
    let private_stage_signature = if stage_pool::is_path(&staged.database_path) {
        Some(staged_store_signature(&staged.database_path)?)
    } else { None };
    // Validate and mount the SAME immutable work snapshot. Reopening the pool
    // here used to decode, materialize and hash every row a second time, and
    // the second copy was not the snapshot just checked by the validator.
    let stage = open_read_only_index(&staged.database_path, StdDuration::from_secs(1))
        .map_err(|error| format!("无法只读打开待导入的精确 token 暂存：{error}"))?;
    let validated = validated_staged_full_rebuild(&stage, &staged.database_path, &staged.job,
        generation, staged.source_validation.as_ref())?
        .ok_or_else(|| "精确 token 单文件暂存在导入前失效".to_string())?;
    if validated.artifact_id != staged.artifact_id || validated.actual_bytes != staged.actual_bytes
    {
        return Err("精确 token 单文件暂存清单在导入前发生变化".into());
    }
    #[cfg(not(test))]
    let legacy_digest = if stage_pool::is_path(&staged.database_path) { None }
        else { Some(stage_pool::Pool::current()?.legacy_digest(&staged.database_path)?) };
    #[cfg(not(test))]
    if stage_pool::is_path(&staged.database_path) {
        let expected = private_stage_signature.as_ref().ok_or("导入暂存快照缺少封存身份")?;
        if validated.source_validation.as_ref().map(|proof| &proof.stage) != Some(expected)
            || &staged_store_signature(&staged.database_path)? != expected {
            return Err("精确 token 单文件暂存封存在核验后发生变化".into());
        }
        let pool = stage_pool::Pool::current()?;
        let job = pool.lookup(&staged.database_path)?.ok_or("挂载的暂存job不存在")?;
        connection.mount_exact_stage_rows(&job.owner, "exact_stage_import", stage.unbound_connection().map_err(|error|error.to_string())?)?;
        #[cfg(feature = "business-store-fixture")]
        if stage_pool::fixture_restore_count().saturating_sub(restores_before_import) != 1 {
            return Err("production fixture: import must use exactly the private snapshot it validated".into());
        }
    } else {
        attach_stage_alias(connection, "exact_stage_import", &staged.database_path)?;
    }
    #[cfg(test)]
    {
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
    }

    let import_result = (|| {
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始精确 token 暂存导入事务：{error}"))?;
        ensure_active_build_generation(&transaction, generation)?;
        let durable_source_id = transaction
            .query_row(
                "SELECT source_id FROM sources WHERE path = ?1",
                params![&validated.job.path],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("无法确认精确 token 暂存稳定来源编号：{error}"))?;
        if durable_source_id != validated.job.source_id {
            return Err("精确 token 暂存稳定来源编号与活动索引不一致".into());
        }
        let pending_snapshot = ledger::snapshot_pending_import(
            &transaction, durable_source_id, generation)?;
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
                    prefix_sha256,
                    source_id
                ) VALUES (?1, ?2, 0, ?3, ?4, ?5, ?6, ?7)
                "#,
                params![
                    generation,
                    &validated.job.path,
                    &validated.job.session_id,
                    checked_i64(validated.job.signature.size, "导入会话文件大小")?,
                    validated.job.signature.modified_ns.to_string(),
                    validated.prefix_sha256.as_slice(),
                    validated.job.source_id,
                ],
            )
            .map_err(|error| format!("无法登记待导入的精确 token 会话：{error}"))?;
        {
            let mut fingerprints = transaction
                .prepare("SELECT fingerprint FROM exact_stage_import.fingerprints")
                .map_err(|error| format!("无法准备导入精确 token 去重状态：{error}"))?;
            let mut rows = fingerprints
                .query([])
                .map_err(|error| format!("无法读取待导入精确 token 去重状态：{error}"))?;
            let mut insert = transaction
                .prepare(
                    "INSERT OR IGNORE INTO file_fingerprints(file_generation, file_path, fingerprint) VALUES (?1, ?2, ?3)",
                )
                .map_err(|error| format!("无法准备写入精确 token 去重状态：{error}"))?;
            while let Some(row) = rows
                .next()
                .map_err(|error| format!("无法遍历待导入精确 token 去重状态：{error}"))?
            {
                let encoded = canonicalize_legacy_fingerprint(
                    row.get_ref(0)
                        .map_err(|error| format!("无法读取待导入精确 token 指纹：{error}"))?,
                )?;
                insert
                    .execute(params![generation, &validated.job.path, encoded])
                    .map_err(|error| format!("无法导入精确 token 去重状态：{error}"))?;
            }
        }
        let legacy_accounting = validated.parser_state.accounting_state.is_none();
        if legacy_accounting { set_metadata(&transaction,"accounting_coverage","legacy-source-audit-required")?; }
        let valid_components = "input_tokens>=0 AND output_tokens>=0 AND cached_input_tokens BETWEEN 0 AND input_tokens AND COALESCE(reasoning_output_tokens,0) BETWEEN 0 AND output_tokens AND input_tokens<=9223372036854775807-output_tokens AND (input_tokens>0 OR output_tokens>0)";
        let token_expression = if legacy_accounting { format!("CASE WHEN {valid_components} THEN input_tokens+output_tokens ELSE 0 END") } else { "tokens".into() };
        let metadata_expressions = if legacy_accounting { format!("CASE WHEN {valid_components} THEN 0 ELSE 3 END, NULL, NULL, tokens") } else { "accounting_kind, reported_total_tokens, token_source_offset, NULL".into() };
        transaction
            .execute(
                &format!(r#"
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
                    assistant_response_end, accounting_kind, reported_total_tokens, token_source_offset, legacy_tokens
                )
                SELECT
                    ?1,
                    ?2,
                    ordinal,
                    timestamp,
                    ?3,
                    {token_expression},
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    model,
                    user_prompt_start,
                    user_prompt_end,
                    assistant_response_start,
                    assistant_response_end, {metadata_expressions}
                FROM exact_stage_import.events
                ORDER BY ordinal
                "#),
                params![generation, &validated.job.path, &validated.job.session_id],
            )
            .map_err(|error| format!("无法批量导入精确 token 暂存事件：{error}"))?;
        let imported_events = transaction
            .query_row(
                "SELECT COUNT(*) FROM events WHERE file_generation = ?1 AND file_path = ?2",
                params![generation, &validated.job.path],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("无法复核精确 token 暂存事件导入数量：{error}"))?;
        let imported_events = u64::try_from(imported_events)
            .map_err(|_| "精确 token 暂存事件导入数量超出支持范围".to_string())?;
        if imported_events != validated.event_count {
            return Err(format!(
                "精确 token 暂存事件导入数量不一致：预期 {}，实际 {}",
                validated.event_count, imported_events
            ));
        }
        ledger::reconcile_full(&transaction, &validated)?;
        ledger::verify_pending_import(&transaction, durable_source_id, pending_snapshot)?;
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
            let recorded = transaction
                .execute(
                    r#"
                    INSERT INTO pending_enrichment(
                        source_id, revision, parser_revision, completed_size,
                        completed_prefix_sha256
                    )
                    SELECT ?1, ?2, ?3, ?5, ?6
                    WHERE EXISTS(
                        SELECT 1 FROM pending_sources p
                        WHERE p.source_id = ?1 AND p.target_generation = ?4
                          AND p.mode <> 'tombstone'
                    )
                    ON CONFLICT(source_id) DO UPDATE SET
                        revision = excluded.revision,
                        parser_revision = excluded.parser_revision,
                        completed_size = excluded.completed_size,
                        completed_prefix_sha256 = excluded.completed_prefix_sha256
                    "#,
                    params![
                        validated.job.source_id,
                        EVENT_ENRICHMENT_REVISION,
                        STAGED_FULL_REBUILD_PARSER_REVISION,
                        generation,
                        checked_i64(validated.committed_signature.size, "历史字段补全来源大小")?,
                        validated.prefix_sha256.as_slice(),
                    ],
                )
                .map_err(|error| format!("无法保存历史 model/reasoning 补全检查点：{error}"))?;
            if recorded != 1 {
                return Err(
                    "历史 model/reasoning 补全来源没有匹配的 building 记录，已停止导入".into(),
                );
            }
        }
        mark_dashboard_changed(&transaction)?;
        #[cfg(not(test))]
        if stage_pool::is_path(&staged.database_path) {
            let pool=stage_pool::Pool::current()?;
            let job=pool.lookup(&staged.database_path)?.ok_or("待导入暂存job缺失")?;
            let seal=pool.seal(&job)?.ok_or("待导入暂存job未封存")?;
            transaction.mark_exact_stage_pending(&job.owner,&job.id,&seal.digest,generation)?;
        }
        #[cfg(not(test))]
        if let Some(digest) = &legacy_digest {
            transaction.mark_exact_legacy_stage_pending(&staged.database_path,digest,generation)?;
        }
        transaction
            .commit()
            .map_err(|error| format!("无法提交精确 token 单文件暂存导入：{error}"))
    })();

    #[cfg(not(test))]
    let detach_result = detach_stage_alias(connection,"exact_stage_import",&staged.database_path);
    #[cfg(test)]
    let detach_result = connection
        .execute_batch("DETACH DATABASE exact_stage_import")
        .map_err(|error| format!("无法卸载已导入的精确 token 暂存：{error}"));
    match (import_result, detach_result) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

#[cfg(not(test))]
pub(super) fn attach_stage_alias(connection: &Connection, alias: &str, path: &Path) -> Result<(), String> {
    if !stage_pool::is_path(path) {
        return crate::core::business_store_route::attach_exact_store_alias(connection,alias,path);
    }
    let pool=stage_pool::Pool::current()?;
    let job=pool.lookup(path)?.ok_or("挂载的暂存job不存在")?;
    let source=pool.restore(&job)?;
    connection.mount_exact_stage_rows(&job.owner,alias,&source)
}

#[cfg(not(test))]
pub(super) fn detach_stage_alias(connection: &Connection, alias: &str, path: &Path) -> Result<(), String> {
    if stage_pool::is_path(path) {
        connection.unmount_exact_stage_rows(alias).map_err(|e|e.to_string())
    } else {
        crate::core::business_store_route::detach_exact_store_alias(connection,alias)
    }
}

fn ensure_staging_directory(index_path: &Path) -> Result<(), String> {
    #[cfg(not(test))]
    {
        let _ = index_path;
        stage_pool::Pool::current()?;
        return Ok(());
    }
    #[cfg(test)]
    {
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
}

pub(super) fn remove_staging_directory(index_path: &Path) -> Result<(), String> {
    #[cfg(not(test))]
    {
        let _ = index_path;
        return Ok(());
    }
    #[cfg(test)]
    {
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
        Ok(_) => {
            let mut entries = fs::read_dir(&directory).map_err(|error| {
                format!(
                    "无法检查精确 token 暂存目录内容 {}：{}",
                    directory.display(),
                    error
                )
            })?;
            if entries.next().is_some() {
                return Ok(());
            }
            fs::remove_dir(&directory).map_err(|error| {
                format!(
                    "无法移除已清空的精确 token 暂存目录 {}：{}",
                    directory.display(),
                    error
                )
            })
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "无法检查精确 token 暂存目录 {}：{}",
            directory.display(),
            error
        )),
    }
    }
}

pub(super) fn staging_directory(index_path: &Path) -> PathBuf {
    let mut value = index_path.as_os_str().to_os_string();
    value.push(".staging");
    PathBuf::from(value)
}

pub(super) fn staging_database_path(index_path: &Path, source_path: &str) -> PathBuf {
    let digest = staging_database_digest(source_path);
    staging_directory(index_path).join(format!("{digest}.sqlite3"))
}

pub(super) fn staging_database_paths(index_path: &Path, source_path: &str) -> Result<Vec<PathBuf>, String> {
    let directory = staging_directory(index_path);
    let primary = staging_database_path(index_path, source_path);
    let digest = staging_database_digest(source_path);
    let candidate_prefix = format!("{digest}.candidate-");
    let mut paths = vec![primary.clone()];
    #[cfg(not(test))]
    let pool=stage_pool::Pool::current()?;
    #[cfg(all(feature = "business-store-fixture", not(test)))]
    let lookup_opens = crate::core::business_store_container::fixture_existing_open_count();
    #[cfg(not(test))]
    let pooled=pool.candidates(&pool.existing_exact_store_spec(index_path)?,source_path)?;
    #[cfg(all(feature = "business-store-fixture", not(test)))]
    stage_pool::fixture_assert_held_lookup(lookup_opens, true)?;
    #[cfg(not(test))]
    paths.extend(pool.legacy_candidates(index_path, &digest)?);
    let entries = match fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            paths.sort();
            paths.dedup();
            paths.sort_by_key(|path| (path != &primary, path.clone()));
            #[cfg(not(test))]
            { paths.splice(0..0,pooled); }
            return Ok(paths);
        }
        Err(error) => {
            return Err(format!(
                "无法枚举精确 token 暂存目录 {}：{error}",
                directory.display()
            ))
        }
    };
    paths.extend(entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
                return false;
            };
            path == &primary || (name.starts_with(&candidate_prefix) && name.ends_with(".sqlite3"))
        })
        .filter(|path| path != &primary));
    paths.sort();
    paths.dedup();
    paths.sort_by_key(|path| {
        if path == &primary {
            (0, String::new())
        } else {
            (1, path.to_string_lossy().into_owned())
        }
    });
    #[cfg(not(test))]
    { paths.splice(0..0,pooled); }
    Ok(paths)
}

pub(super) fn staging_database_digest(source_path: &str) -> String {
    Sha256::digest(source_path.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

/// Resets connection-local scan/dedup queues on the supplied handle. It must
/// remain on the root scan connection and must not begin or commit publication.
pub(super) fn prepare_scan_temp_tables(connection: &Connection) -> Result<(), String> {
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

#[allow(clippy::too_many_arguments)]
pub(super) fn process_scan_file_with_progress(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    full_rebuild_jobs: &mut Vec<FullRebuildJob>,
    empty_source_jobs: &mut Vec<empty_sources::EmptySourceJob>,
    scanned_files: &mut u64,
    scanned_paths: &mut HashSet<PathBuf>,
    scan_total: Option<u64>,
    diagnostics: &mut ExactScanDiagnostics,
    expected_signature: Option<FileSignature>,
    mode: ExactSyncMode,
) -> Result<(), String> {
    let canonical = rollout_source::canonical_logical_path(file).unwrap_or_else(|_| rollout_source::logical_path(file));
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
        empty_source_jobs,
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

/// Write-capable identity reservation: may rebind a unique missing session path,
/// insert a generation-0 source, or fill an unknown session ID. It borrows the
/// supplied connection/transaction; the name does not imply a pure allocation.
pub(super) fn reserve_staging_source(
    connection: &Connection,
    path: &str,
    session_id: &str,
) -> Result<StagingSourceBase, String> {
    let read = |connection: &Connection| {
        connection
            .query_row(
                r#"
                SELECT source_id, session_id, last_seen_generation,
                       resume_offset, prefix_sha256
                FROM sources
                WHERE path = ?1
                "#,
                params![path],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, Vec<u8>>(4)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| format!("无法读取精确 token 稳定来源编号：{error}"))
    };

    let mut stored = read(connection)?;
    // Archiving changes a path, not the owner of already observed usage. Only
    // rebind a unique missing source; a still-present duplicate or an ambiguous
    // legacy identity must never silently merge two histories.
    if stored.is_none() && !session_id.is_empty() {
        let candidates: Vec<(i64,String)> = connection.prepare(
            "SELECT source_id,path FROM sources WHERE session_id=?1"
        ).map_err(|e|e.to_string())?.query_map(params![session_id],|r|Ok((r.get(0)?,r.get(1)?)))
            .map_err(|e|e.to_string())?.collect::<Result<_,_>>().map_err(|e|e.to_string())?;
        if candidates.len()==1 {
            let (source,old_path)=&candidates[0];
            if rollout_source::metadata(Path::new(old_path)).is_err_and(|e|e.kind()==std::io::ErrorKind::NotFound) {
                connection.execute("UPDATE sources SET path=?2 WHERE source_id=?1",params![source,path]).map_err(|e|e.to_string())?;
                stored=read(connection)?;
            }
        }
    }
    if stored.is_none() {
        connection
            .execute(
                r#"
                INSERT INTO sources(
                    source_id, path, session_id, deleted, last_seen_generation
                )
                SELECT COALESCE(MAX(source_id), 0) + 1, ?1, ?2, 1, 0
                FROM sources
                "#,
                params![path, session_id],
            )
            .map_err(|error| format!("无法预留精确 token 稳定来源编号：{error}"))?;
        stored = read(connection)?;
    }
    let Some((source_id, stored_session_id, generation, resume_offset, prefix)) = stored else {
        return Err("精确 token 稳定来源编号预留后仍不可见".into());
    };
    if !stored_session_id.is_empty() && stored_session_id != session_id {
        return Err(format!(
            "同一会话文件路径的 session ID 已变化，已保留上一份可信索引：{path}"
        ));
    }
    if stored_session_id.is_empty() && !session_id.is_empty() {
        connection
            .execute(
                "UPDATE sources SET session_id = ?2 WHERE source_id = ?1 AND session_id = ''",
                params![source_id, session_id],
            )
            .map_err(|error| format!("无法绑定精确 token 稳定来源会话：{error}"))?;
    }
    let resume_offset = match resume_offset {
        Some(value) => Some(
            u64::try_from(value)
                .map_err(|_| "精确 token 稳定来源 checkpoint 为负数".to_string())?,
        ),
        None => None,
    };
    let prefix_sha256 = if prefix.is_empty() {
        None
    } else {
        Some(
            prefix
                .as_slice()
                .try_into()
                .map_err(|_| "精确 token 稳定来源前缀证明长度无效".to_string())?,
        )
    };
    Ok(StagingSourceBase {
        source_id,
        generation,
        resume_offset,
        prefix_sha256,
    })
}

pub(super) fn process_session_file(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    diagnostics: &mut ExactScanDiagnostics,
    expected_signature: Option<FileSignature>,
    mode: ExactSyncMode,
    empty_source_jobs: &mut Vec<empty_sources::EmptySourceJob>,
) -> Result<Option<FullRebuildJob>, String> {
    if is_history_repair_workspace(file) { return Ok(None); }
    let canonical = rollout_source::canonical_logical_path(file).unwrap_or_else(|_| rollout_source::logical_path(file));
    let path = canonical.to_string_lossy().into_owned();

    if let Some(stored) = representations::complete_observation(connection, &path)? {
        if let Ok(Some(signature)) = lightweight_file_signature(file, Some(&stored)) {
            if rollout_source::physical_path(file).is_ok_and(|physical| rollout_source::is_compressed(&physical))
                && signature.matches_stored(stored.0, &stored.1)
                && signature.matches_physical(stored.2.as_deref())
            {
                if expected_signature.is_some_and(|expected| expected != signature) {
                    diagnostics.source_drift = true;
                }
                connection.execute("INSERT OR IGNORE INTO exact_seen_files(path) VALUES (?1)", params![&path])
                    .map_err(|error| format!("无法记录稳定压缩来源：{error}"))?;
                return Ok(None);
            }
        }
    }

    // 单个文件不可读（权限/锁定/iCloud 占位）属持久性错误：整轮报错会让 building
    // 滞留、后台无限重试且 dashboard 永不刷新。删除已经明确发生时不写入
    // exact_seen_files，让本轮正式发布安全登记删除墓碑；其他不可读错误仍抑制
    // 墓碑，保留旧统计待自愈。
    let mut handle = match RolloutReader::open(file) {
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
    // An unindexed zero-byte source has neither parser output nor historical
    // facts to stage. Defer ONLY these new sources to bounded main-index
    // transactions; existing/truncated sources still use ledger reconciliation.
    if empty_sources::queue_if_new(connection, &canonical, &path, signature, empty_source_jobs)? {
        return Ok(None);
    }
    prune_obsolete_file_versions(connection, &path)?;
    let previous_signature = connection
        .query_row(
            r#"
            SELECT f.generation, f.deleted, f.size, f.modified_ns, o.physical_stamp
            FROM files f LEFT JOIN source_observations o
              ON o.path=f.path AND o.size=f.size AND o.modified_ns=f.modified_ns
            WHERE f.path = ?1 AND f.generation <= ?2
            ORDER BY f.generation DESC
            LIMIT 1
            "#,
            params![&path, generation],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, bool>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()
        .map_err(|error| format!("无法读取会话文件索引签名：{error}"))?;
    if representations::reuse_complete(connection, &path, &handle, signature, generation)? {
        return Ok(None);
    }
    let source_missing: bool=connection.query_row("SELECT EXISTS(SELECT 1 FROM usage_ledger_sources l JOIN sources s USING(source_id) WHERE s.path=?1 AND l.missing=1 AND NOT EXISTS(SELECT 1 FROM pending_sources p WHERE p.source_id=s.source_id AND p.mode<>'tombstone'))",params![&path],|r|r.get(0)).map_err(|e|e.to_string())?;
    let unchanged = !source_missing && previous_signature
        .as_ref()
        .is_some_and(|(_, deleted, size, modified_ns, physical)| {
            !deleted && signature.matches_stored(nonnegative_u64(*size), modified_ns)
                && (physical.is_none() || signature.matches_physical(physical.as_deref()))
                && (!handle.compressed() || physical.is_some())
        });
    if unchanged {
        if previous_signature.as_ref().is_some_and(|(_, _, _, _, physical)| physical.is_none()) {
            // Metadata-only adoption of an old index. Do not cold-hash all
            // historical files just to populate a newly introduced detector.
            record_source_observation(connection, &path, signature)?;
        }
        return Ok(None);
    }

    if let Some(checkpoint) = if source_missing { None } else { indexed_file_checkpoint(connection, &path, generation)? } {
        let latest_generation = previous_signature
            .as_ref()
            .map(|(generation, ..)| *generation);
        if signature.size == checkpoint.size
            && latest_generation == Some(checkpoint.generation)
            && revalidate_metadata_only_file(
                connection,
                generation,
                file,
                &path,
                &mut handle,
                signature,
                &checkpoint,
                diagnostics,
            )?
        {
            return Ok(None);
        }
        if signature.size > checkpoint.size
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

    // Full scans reconcile against the retained numeric ledger. A raw rewrite
    // alone no longer revokes attribution provenance.

    let session_id = session_id_from_file(file);
    let staging_base = reserve_staging_source(connection, &path, &session_id)?;

    // All nonempty or previously indexed rebuilds use the private-staging pool. The
    // workers never write the main index; imports remain deterministic and
    // single-writer, while small files can finally make use of the available
    // parser lanes instead of serializing on the scan thread.
    drop(handle);
    Ok(Some(FullRebuildJob {
        file: canonical,
        path,
        session_id,
        source_id: staging_base.source_id,
        base_generation: staging_base.generation,
        base_resume_offset: staging_base.resume_offset,
        base_prefix_sha256: staging_base.prefix_sha256,
        signature,
        event_enrichment: false,
        expected_published_prefix_sha256: None,
    }))
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
                audit_chunk_index, accounting_state
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
                let resume_offset = nonnegative_u64(row.get::<_, i64>(2)?);
                let previous_total_tokens = row.get::<_, Option<i64>>(3)?.map(nonnegative_u64);
                let fork_replay_started_at = parse_timestamp_ns(row.get::<_, Option<String>>(4)?);
                let fork_replay_active = row.get::<_, bool>(5)?;
                let is_explicit_subagent_fork = row.get::<_, bool>(6)?;
                let last_skipped_fork_replay_token_at =
                    parse_timestamp_ns(row.get::<_, Option<String>>(7)?);
                let current_model = row.get::<_, Option<String>>(8)?;
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
                    resume_offset,
                    parser_state: ExactSessionParserState {
                        accounting_state: row.get::<_, Option<String>>(14)?.map(|v| serde_json::from_str(&v)).transpose().map_err(|e| rusqlite::Error::FromSqlConversionFailure(14, rusqlite::types::Type::Text, Box::new(e)))?,
                        previous_total_tokens,
                        fork_replay_started_at,
                        fork_replay_active,
                        is_explicit_subagent_fork,
                        last_skipped_fork_replay_token_at,
                        current_model,
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
/// Owns the original IMMEDIATE append transaction. A same-generation resume
/// must not copy/delete its checkpoint. Every Ok(false) after begin relies on
/// Transaction::drop to roll back copied or partially parsed rows.
fn append_session_file(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
    file: &Path,
    path: &str,
    handle: &mut impl SourceHandle,
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
    let parse_result = stream_session_file_exact_from(
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
    );
    #[cfg(test)]
    APPEND_SCAN_BYTES.fetch_add(
        signature.size.saturating_sub(hashing_start_offset),
        Ordering::SeqCst,
    );
    diagnostics.append_scan_bytes = diagnostics
        .append_scan_bytes
        .saturating_add(signature.size.saturating_sub(hashing_start_offset));
    drop(sink);
    let parsed = match parse_result {
        Ok(parsed) => parsed,
        Err(error) => {
            // Only failed parsing needs an extra boundary check. Successful
            // appends already validate the old tail with the streaming hash.
            let mut boundaries = vec![checkpoint.resume_offset.saturating_sub(1) / EXACT_INDEX_CHUNK_SIZE];
            if let Some(tail) = tail_chunk_index { boundaries.push(tail); }
            boundaries.sort_unstable();
            boundaries.dedup();
            for index in boundaries {
                if checkpoint.size == 0 { break; }
                let Some(stored) = stored_file_chunk(&transaction, checkpoint.generation, path, index)? else {
                    return Ok(false);
                };
                if hash_file_chunk(handle, file, index, stored.byte_count)? != stored {
                    return Ok(false); // Transaction drop rolls back partial append rows.
                }
            }
            return Err(error);
        }
    };
    diagnostics.pending_tail_bytes = diagnostics
        .pending_tail_bytes
        .saturating_add(signature.size.saturating_sub(parsed.resume_offset));
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

/// Stages only the source checkpoint for an append. Published events,
/// fingerprints, chunks and aggregates remain in the current layer and are
/// projected into the building generation by schema-11 views. This keeps the
/// durable write volume proportional to the suffix instead of the file's
/// complete history.
fn copy_append_checkpoint_rows(
    transaction: &Transaction<'_>,
    generation: i64,
    checkpoint_generation: i64,
    path: &str,
    _mode: ExactSyncMode,
) -> Result<bool, String> {
    let copied = transaction
        .execute(
            r#"
            INSERT INTO pending_sources(
                source_id, target_generation, mode, deleted, size,
                modified_ns, prefix_sha256, append_ready, resume_offset,
                previous_total_tokens, fork_replay_started_ns,
                fork_replay_active, is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns, current_model,
                current_user_prompt_start, current_user_prompt_end,
                assistant_response_start, assistant_response_end,
                audit_chunk_index, accounting_state
            )
            SELECT
                source_id, ?1, 'delta', 0, size, modified_ns,
                prefix_sha256, append_ready, resume_offset,
                previous_total_tokens, fork_replay_started_ns,
                fork_replay_active, is_explicit_subagent_fork,
                last_skipped_fork_replay_token_ns, current_model,
                current_user_prompt_start, current_user_prompt_end,
                assistant_response_start, assistant_response_end,
                audit_chunk_index, accounting_state
            FROM sources
            WHERE last_seen_generation = ?2 AND path = ?3 AND deleted = 0
            ON CONFLICT(source_id) DO UPDATE SET
                target_generation = excluded.target_generation,
                mode = 'delta', deleted = 0, size = excluded.size,
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
                audit_chunk_index = excluded.audit_chunk_index, accounting_state = excluded.accounting_state
            "#,
            params![generation, checkpoint_generation, path],
        )
        .map_err(|error| format!("无法登记会话文件追加 delta：{error}"))?;
    if copied != 1 {
        return Ok(false);
    }
    Ok(true)
}

#[allow(clippy::too_many_arguments)]
/// The name describes the accepted change, not the work: reads content chunks,
/// validates the source boundary and commits observations in its own IMMEDIATE
/// transaction while retaining numeric revision/aggregate semantics.
fn revalidate_metadata_only_file(
    connection: &mut Connection,
    generation: i64,
    file: &Path,
    path: &str,
    handle: &mut impl SourceHandle,
    signature: FileSignature,
    checkpoint: &IndexedFileCheckpoint,
    diagnostics: &mut ExactScanDiagnostics,
) -> Result<bool, String> {
    if signature.size != checkpoint.size {
        return Ok(false);
    }

    let chunk_count = signature
        .size
        .checked_sub(1)
        .map_or(0, |offset| offset / EXACT_INDEX_CHUNK_SIZE + 1);
    let mut verification_order = Vec::with_capacity(usize::try_from(chunk_count).unwrap_or(0));
    if rollout_source::physical_path(file).is_ok_and(|physical| rollout_source::is_compressed(&physical)) {
        verification_order.extend(0..chunk_count);
    } else {
        if chunk_count > 0 { verification_order.push(0); }
        if chunk_count > 1 { verification_order.push(chunk_count - 1); }
        if chunk_count > 2 { verification_order.extend(1..chunk_count - 1); }
    }

    let mut verified_bytes = 0_u64;
    for chunk_index in verification_order {
        let expected_bytes = signature
            .size
            .saturating_sub(chunk_index.saturating_mul(EXACT_INDEX_CHUNK_SIZE))
            .min(EXACT_INDEX_CHUNK_SIZE);
        let Some(stored) = stored_file_chunk(connection, checkpoint.generation, path, chunk_index)?
        else {
            return Ok(false);
        };
        if stored.byte_count != expected_bytes {
            return Ok(false);
        }
        let current = hash_file_chunk(handle, file, chunk_index, stored.byte_count)?;
        verified_bytes = verified_bytes.saturating_add(stored.byte_count);
        if current != stored {
            return Ok(false);
        }
    }

    handle.validate_decoded_end(signature.size).map_err(|error| {
        format!("会话文件元数据复核的压缩终点校验失败：{}（{error}）", file.display())
    })?;
    let handle_after = file_signature_from_handle(handle, file)?;
    let path_after = file_signature(file)?;
    if handle_after != signature || path_after != signature {
        return Err(format!(
            "会话文件在元数据复核期间继续变化，将在下一次刷新重试：{}",
            file.display()
        ));
    }

    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始会话文件元数据复核事务：{error}"))?;
    ensure_active_build_generation(&transaction, generation)?;
    let size = checked_i64(signature.size, "会话文件大小")?;
    let modified_ns = signature.modified_ns.to_string();
    let updated = if checkpoint.generation == generation {
        transaction
            .execute(
                r#"
                UPDATE pending_sources
                SET modified_ns = ?3
                WHERE target_generation = ?1
                  AND source_id = (SELECT source_id FROM sources WHERE path = ?2)
                  AND deleted = 0
                  AND size = ?4
                "#,
                params![generation, path, &modified_ns, size],
            )
            .map_err(|error| format!("无法保存暂存会话文件内容复核结果：{error}"))?
    } else {
        // A metadata-only difference has now been proven byte-for-byte
        // content-identical. It is safe to accept only the mtime on the stable
        // published source without creating a new semantic generation. This
        // keeps numeric lastGood, revision, and aggregate lineage unchanged.
        transaction
            .execute(
                r#"
                UPDATE sources
                SET modified_ns = ?3
                WHERE path = ?2
                  AND last_seen_generation = ?1
                  AND deleted = 0
                  AND size = ?4
                  AND NOT EXISTS(
                      SELECT 1 FROM pending_sources p
                      WHERE p.source_id = sources.source_id
                  )
                "#,
                params![checkpoint.generation, path, &modified_ns, size],
            )
            .map_err(|error| format!("无法保存已发布会话文件内容复核结果：{error}"))?
    };
    if updated != 1 {
        return Err(format!(
            "会话文件内容复核完成但检查点已变化，将在下一次刷新重试：{}",
            file.display()
        ));
    }
    record_source_observation(&transaction, path, signature)?;
    transaction
        .commit()
        .map_err(|error| format!("无法提交会话文件内容复核结果：{error}"))?;

    diagnostics.metadata_validation_bytes = diagnostics
        .metadata_validation_bytes
        .saturating_add(verified_bytes);
    diagnostics.metadata_only_files = diagnostics.metadata_only_files.saturating_add(1);
    #[cfg(test)]
    METADATA_VALIDATION_BYTES.fetch_add(verified_bytes, Ordering::SeqCst);
    Ok(true)
}

/// A publication guard with writes: a confirmed missing source opens its own
/// IMMEDIATE transaction to retain complete pending history as unavailable.
/// Otherwise probes source chunks; never substitutes a new final publisher.
pub(super) fn validate_building_generation_commit_scope(
    connection: &mut Connection,
    generation: i64,
    codex_home: &Path,
) -> Result<(), String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT path, size, audit_chunk_index
            FROM files
            WHERE generation = ?1 AND deleted = 0
            ORDER BY path
            "#,
        )
        .map_err(|error| format!("无法准备精确 token 发布前内容复核：{error}"))?;
    let committed_files = statement
        .query_map(params![generation], |row| {
            Ok((
                row.get::<_, String>(0)?,
                nonnegative_u64(row.get::<_, i64>(1)?),
                nonnegative_u64(row.get::<_, i64>(2)?),
            ))
        })
        .map_err(|error| format!("无法读取精确 token 发布前复核范围：{error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码精确 token 发布前复核范围：{error}"))?;
    drop(statement);

    for (path, committed_size, audit_chunk_index) in committed_files {
        let file = Path::new(&path);
        let mut handle = match RolloutReader::open(file) {
            Ok(handle) => handle,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound
                && rollout_source::confirmed_missing_reference(file, codex_home) => {
                // This building generation has already been imported and
                // accepted. Losing both raw representations cannot revoke its
                // durable history. Preserve it through the ordinary publisher
                // using database continuity, while revoking excerpt access.
                let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)
                    .map_err(|error| format!("无法开始缺失原文的发布连续性校验：{error}"))?;
                ensure_active_build_generation(&transaction, generation)?;
                let source: i64 = transaction.query_row(
                    "SELECT p.source_id FROM pending_sources p JOIN sources s USING(source_id) \
                     WHERE s.path=?1 AND p.target_generation=?2 AND p.deleted=0 \
                       AND p.size=?3 AND p.audit_chunk_index=?4",
                    params![path, generation, checked_i64(committed_size, "待发布来源大小")?,
                        checked_i64(audit_chunk_index, "待发布来源内容块")?], |row| row.get(0))
                    .map_err(|error| format!("缺失原文的已提交检查点已变化，保留原库：{error}"))?;
                if !ledger::retain_pending_when_source_missing(&transaction, source, generation)? {
                    return Err(format!("缺失原文没有完整的待发布历史，保留原库：{}", file.display()));
                }
                mark_dashboard_changed(&transaction)?;
                transaction.commit().map_err(|error| format!("无法提交缺失原文的历史连续性证明：{error}"))?;
                continue;
            }
            Err(error) => return Err(format!(
                "会话文件在发布前已不可读，本轮结果不会发布：{}（{}）", file.display(), error)),
        };
        let current = file_signature_from_handle(&handle, file)?;
        if current.size < committed_size {
            return Err(format!(
                "会话文件在发布前被截断，本轮结果不会发布：{}",
                file.display()
            ));
        }
        let chunk_count = committed_size
            .checked_sub(1)
            .map_or(0, |offset| offset / EXACT_INDEX_CHUNK_SIZE + 1);
        if chunk_count == 0 {
            if current.size == committed_size {
                handle.validate_decoded_end(committed_size).map_err(|error| {
                    format!("发布前压缩终点校验失败：{}（{error}）", file.display())
                })?;
            }
            continue;
        }
        let mut probe_indices = vec![0, chunk_count - 1, audit_chunk_index % chunk_count];
        probe_indices.sort_unstable();
        probe_indices.dedup();
        for chunk_index in probe_indices {
            let Some(stored) = stored_file_chunk(connection, generation, &path, chunk_index)?
            else {
                return Err(format!(
                    "会话文件发布前缺少内容块校验值，本轮结果不会发布：{}",
                    file.display()
                ));
            };
            let current_chunk =
                hash_file_chunk(&mut handle, file, stored.index, stored.byte_count)?;
            if current_chunk != stored {
                return Err(format!(
                    "会话文件在发布前发生内容变化，本轮结果不会发布：{}",
                    file.display()
                ));
            }
        }
        // Sorted probes end at the last logical chunk; consume the frame
        // trailer without starting a second full decode pass.
        if current.size == committed_size {
            handle.validate_decoded_end(committed_size).map_err(|error| {
                format!("发布前压缩终点校验失败：{}（{error}）", file.display())
            })?;
        }
    }
    Ok(())
}

fn audit_checkpoint_chunk(
    connection: &Connection,
    handle: &mut impl SourceHandle,
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

pub(super) fn hash_file_chunk(
    handle: &mut impl SourceHandle,
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
    handle: &mut impl SourceHandle,
    start_signature: FileSignature,
    chunk_hashes: &[ExactChunkHash],
) -> Result<(), String> {
    // Take(logical_size) can finish before a trailing zero-output frame.
    // Plain source handles deliberately allow a newer appended suffix.
    handle.validate_decoded_end(start_signature.size).map_err(|error| {
        format!("追加扫描的压缩终点校验失败：{}（{error}）", path.display())
    })?;
    let handle_after = file_signature_from_handle(handle, path)?;
    let path_after = file_signature(path)?;
    validate_prefix_bounds(start_signature, handle_after, path_after)?;
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
    let mut path_handle = RolloutReader::open(path).map_err(|error| {
        format!(
            "无法重开会话文件以复核追加边界：{}（{}）",
            path.display(),
            error
        )
    })?;
    let path_tail = hash_file_chunk(&mut path_handle, path, tail_index, prefix_byte_count)?;
    if current_tail.sha256 != scanned_tail.sha256
        || current_tail.byte_count != scanned_tail.byte_count
        || path_tail.sha256 != scanned_tail.sha256
        || path_tail.byte_count != scanned_tail.byte_count
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
                append_ready = 1,
                resume_offset = ?5,
                previous_total_tokens = ?6,
                fork_replay_started_ns = ?7,
                fork_replay_active = ?8,
                is_explicit_subagent_fork = ?9,
                last_skipped_fork_replay_token_ns = ?10,
                current_model = ?11,
                current_user_prompt_start = ?12,
                current_user_prompt_end = ?13,
                assistant_response_start = ?14,
                assistant_response_end = ?15,
                audit_chunk_index = ?16, accounting_state = ?17
            WHERE generation = ?1 AND path = ?2
            "#,
            params![
                generation,
                path,
                checked_i64(signature.size, "会话文件大小")?,
                signature.modified_ns.to_string(),
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
                state.accounting_state.as_ref().map(AccountingState::encode),
            ],
        )
        .map_err(|error| format!("无法保存会话文件追加检查点：{error}"))?;
    record_source_observation(transaction, path, signature)?;
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

pub(super) fn prune_obsolete_file_versions(connection: &Connection, path: &str) -> Result<(), String> {
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

/// Historical removal name: production invalidates receipt state and requests
/// pool reclaim, which is a no-op without a matching committed consumption
/// receipt. Legacy namespaces stay for the bounded receipt-aware sweeper.
/// Even a no-op can acquire the pool handle and a short write transaction;
/// this is not a pure availability check or permission to consume a stage.
/// Test-only physical deletion keeps its original separate behavior.
pub(super) fn remove_staging_database_storage(path: &Path) -> Result<(), String> {
    #[cfg(not(test))]
    {
        invalidate_index_integrity_signature(path);
        if stage_pool::is_path(path) {
            let pool=stage_pool::Pool::current()?;
            if let Some(job)=pool.lookup(path)? { pool.reclaim(&job)?; }
        }
        // Old namespaces remain recovery evidence until their final-generation
        // receipt is verified by the bounded legacy sweeper. Never drop one
        // from the earlier per-file BUILDING transaction.
        return Ok(());
    }
    #[cfg(test)]
    {
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
                    "拒绝删除符号链接形式的精确 token 暂存：{}",
                    candidate.display()
                ));
            }
            Ok(metadata) if !metadata.is_file() => {
                return Err(format!(
                    "精确 token 暂存路径不是普通文件：{}",
                    candidate.display()
                ));
            }
            Ok(_) => existing.push(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "无法检查精确 token 暂存 {}：{}",
                    candidate.display(),
                    error
                ));
            }
        }
    }
    for candidate in existing {
        fs::remove_file(&candidate).map_err(|error| {
            format!("无法移除精确 token 暂存 {}：{}", candidate.display(), error)
        })?;
    }
    Ok(())
    }
}

fn validate_same_file_prefix(
    path: &Path,
    handle: &mut impl SourceHandle,
    start_signature: FileSignature,
    scanned_hash: [u8; 32],
) -> Result<(), String> {
    handle.validate_decoded_end(start_signature.size)
        .map_err(|e|format!("会话压缩内容结尾校验失败：{}（{e}）",path.display()))?;
    let handle_before = file_signature_from_handle(handle, path)?;
    let path_before = file_signature(path)?;
    validate_prefix_bounds(start_signature, handle_before, path_before)?;

    if handle_before == start_signature && path_before == start_signature {
        return Ok(());
    }

    let current_hash = hash_file_prefix(handle, start_signature.size, path)?;
    let mut path_handle = RolloutReader::open(path).map_err(|error| {
        format!(
            "无法重开会话文件以复核已扫描前缀：{}（{}）",
            path.display(),
            error
        )
    })?;
    let path_hash = hash_file_prefix(&mut path_handle, start_signature.size, path)?;

    let handle_after = file_signature_from_handle(handle, path)?;
    let path_after = file_signature(path)?;
    validate_prefix_bounds(start_signature, handle_after, path_after)?;
    if current_hash != scanned_hash || path_hash != scanned_hash {
        return Err("扫描起点内的既有字节被改写".into());
    }
    Ok(())
}

fn validate_prefix_bounds(
    start: FileSignature,
    handle: FileSignature,
    path: FileSignature,
) -> Result<(), String> {
    if handle.size < start.size || path.size < start.size {
        return Err("文件已截断到扫描起点之前".into());
    }
    Ok(())
}

pub(super) fn hash_file_prefix(
    handle: &mut impl SourceHandle,
    prefix_size: u64,
    path: &Path,
) -> Result<[u8; 32], String> {
    crate::core::shared_source_io::with_uncached_reads(|| hash_physical_file_prefix(handle,prefix_size,path))
}

fn hash_physical_file_prefix(handle: &mut impl SourceHandle, prefix_size:u64, path:&Path)->Result<[u8;32],String> {
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

pub(super) fn event_enrichment_source_count(connection: &Connection) -> Result<u64, String> {
    connection
        .query_row("SELECT COUNT(*) FROM published_files", [], |row| {
            row.get::<_, i64>(0)
        })
        .map(nonnegative_u64)
        .map_err(|error| format!("无法统计历史字段补全来源：{error}"))
}

pub(super) fn event_enrichment_receipt_count(connection: &Connection) -> Result<u64, String> {
    let missing = if table_exists_checked(connection, "usage_ledger_sources")? {
        "OR EXISTS(SELECT 1 FROM usage_ledger_sources l JOIN sources s USING(source_id) \
            WHERE s.path=f.path AND l.missing=1) \
         OR EXISTS(SELECT 1 FROM usage_ledger_pending_missing m JOIN sources s USING(source_id) \
            WHERE s.path=f.path)"
    } else { "" };
    connection
        .query_row(
            &format!("SELECT COUNT(*) FROM main.published_files f WHERE EXISTS( \
                SELECT 1 FROM event_enrichment_sources receipt WHERE receipt.path=f.path \
                  AND receipt.revision=?1 AND receipt.parser_revision=?2 \
                  AND receipt.completed_size=f.size AND receipt.completed_prefix_sha256=f.prefix_sha256) \
                {missing}"),
            params![
                EVENT_ENRICHMENT_REVISION,
                STAGED_FULL_REBUILD_PARSER_REVISION,
            ],
            |row| row.get::<_, i64>(0),
        )
        .map(nonnegative_u64)
        .map_err(|error| format!("无法按已发布范围统计已完成的历史字段补全来源：{error}"))
}

pub(super) fn event_enrichment_pending_candidates(
    connection: &Connection,
) -> Result<Vec<EventEnrichmentCandidate>, String> {
    let available = if table_exists_checked(connection,"usage_ledger_sources")? {
        "AND NOT EXISTS(SELECT 1 FROM usage_ledger_sources l JOIN sources s USING(source_id) WHERE s.path=f.path AND l.missing=1) AND NOT EXISTS(SELECT 1 FROM usage_ledger_pending_missing m JOIN sources s USING(source_id) WHERE s.path=f.path)"
    } else { "" };
    let mut statement = connection
        .prepare(
            &format!(r#"
            SELECT
                f.path,
                f.session_id,
                f.size,
                f.modified_ns,
                f.prefix_sha256
            FROM main.published_files f
            LEFT JOIN event_enrichment_sources receipt
             ON receipt.path = f.path
             AND receipt.revision = ?1
             AND receipt.parser_revision = ?2
             AND receipt.completed_size = f.size
             AND receipt.completed_prefix_sha256 = f.prefix_sha256
            WHERE receipt.path IS NULL
            {available}
            ORDER BY f.path
            "#),
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
                let raw_prefix = row.get::<_, Vec<u8>>(4)?;
                let prefix_sha256: [u8; 32] = raw_prefix.try_into().map_err(|_| {
                    rusqlite::Error::InvalidColumnType(
                        4,
                        "prefix_sha256".into(),
                        rusqlite::types::Type::Blob,
                    )
                })?;
                Ok(EventEnrichmentCandidate {
                    path: row.get(0)?,
                    session_id: row.get(1)?,
                    signature: FileSignature { size, modified_ns, physical: None },
                    prefix_sha256,
                })
            },
        )
        .map_err(|error| format!("无法读取历史 model/reasoning 补全来源：{error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码历史 model/reasoning 补全来源：{error}"))
}

pub(super) fn event_enrichment_pending_candidates_for_generation(
    connection: &Connection,
    generation: i64,
) -> Result<Vec<EventEnrichmentCandidate>, String> {
    let available = if table_exists_checked(connection,"usage_ledger_sources")? {
        "AND NOT EXISTS(SELECT 1 FROM usage_ledger_sources l JOIN sources s USING(source_id) WHERE s.path=f.path AND l.missing=1) AND NOT EXISTS(SELECT 1 FROM usage_ledger_pending_missing m JOIN sources s USING(source_id) WHERE s.path=f.path)"
    } else { "" };
    let mut statement = connection
        .prepare(
            &format!(r#"
            SELECT
                f.path,
                f.session_id,
                f.size,
                f.modified_ns,
                f.prefix_sha256
            FROM files f
            LEFT JOIN event_enrichment_sources receipt
             ON receipt.path = f.path
             AND receipt.revision = ?1
             AND receipt.parser_revision = ?2
             AND receipt.completed_size = f.size
             AND receipt.completed_prefix_sha256 = f.prefix_sha256
            WHERE f.generation = ?3
              AND f.deleted = 0
              AND receipt.path IS NULL
            {available}
            ORDER BY f.path
            "#),
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
                let raw_prefix = row.get::<_, Vec<u8>>(4)?;
                let prefix_sha256: [u8; 32] = raw_prefix.try_into().map_err(|_| {
                    rusqlite::Error::InvalidColumnType(
                        4,
                        "prefix_sha256".into(),
                        rusqlite::types::Type::Blob,
                    )
                })?;
                Ok(EventEnrichmentCandidate {
                    path: row.get(0)?,
                    session_id: row.get(1)?,
                    signature: FileSignature { size, modified_ns, physical: None },
                    prefix_sha256,
                })
            },
        )
        .map_err(|error| format!("无法读取当前补全代次来源：{error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("无法解码当前补全代次来源：{error}"))
}

/// Predicate with I/O: its open may restore a pool image or admit a legacy
/// namespace, and old-parser checks may read the original rollout source.
fn restartable_private_stage(path: &Path, job: &FullRebuildJob) -> Result<bool, String> {
    let c = open_read_only_index(path, StdDuration::from_secs(1)).map_err(|e| e.to_string())?;
    if quick_check_staged(&c).is_err() { return Ok(false); }
    for column in ["manifest_schema_version", "parser_revision", "complete"] {
        if !column_exists_checked(&c, "manifest", column)? { return Ok(false); }
    }
    let rows: i64 = c.query_row("SELECT COUNT(*) FROM manifest", [], |r| r.get(0)).map_err(|e| e.to_string())?;
    if rows == 0 {
        if !column_exists_checked(&c, "manifest", "staging_mode")? || !column_exists_checked(&c, "manifest", "accounting_state")? { return Ok(false); }
        for table in ["events", "fingerprints", "chunks"] {
            let count: i64 = c.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0)).map_err(|e| e.to_string())?;
            if count != 0 { return Ok(false); }
        }
        return Ok(true);
    }
    if rows != 1 { return Ok(false); }
    let (schema, parser, source, complete): (i64, String, String, i64) = c.query_row(
        "SELECT manifest_schema_version, parser_revision, path, complete FROM manifest", [],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).map_err(|e| e.to_string())?;
    if ![1, 2, STAGING_MANIFEST_SCHEMA_VERSION].contains(&schema) || source != job.path { return Ok(false); }
    if complete == 0 && parser == STAGED_FULL_REBUILD_PARSER_REVISION { return Ok(true); }
    if [LEGACY_STAGED_PARSER_REVISION, LEGACY_SESSION_PARSER_REVISION, PAGINATED_V4_STAGED_REVISION, PAGINATED_V4_PARSER_REVISION, PAGINATED_V5_PARSER_REVISION, PAGINATED_V5_STAGED_REVISION].contains(&parser.as_str()) {
        return super::session_parser::paginated_subagent_boundary(&mut RolloutReader::open(&job.file).map_err(|e| e.to_string())?).map(|b| b.is_some());
    }
    Ok(false)
}

/// A completed stage from the old event-enrichment/parser contract cannot be
/// reused for compaction reconciliation. Keep it as private recovery evidence
/// and let the current parser build a fresh stage from the same source.
fn superseded_compaction_private_stage(path: &Path, job: &FullRebuildJob) -> Result<bool, String> {
    if !job.event_enrichment || !existing_regular_index(path)? {
        return Ok(false);
    }
    let connection = open_read_only_index(path, StdDuration::from_secs(1))
        .map_err(|error| format!("无法只读检查旧 compaction 暂存：{error}"))?;
    quick_check_staged(&connection)?;
    for column in ["manifest_schema_version", "parser_revision", "migration_revision", "path"] {
        if !column_exists_checked(&connection, "manifest", column)? {
            return Ok(false);
        }
    }
    let manifest: Option<(i64, String, String, String)> = connection.query_row(
        "SELECT manifest_schema_version,parser_revision,migration_revision,path FROM manifest LIMIT 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    ).optional().map_err(|error| format!("无法读取旧 compaction 暂存证明：{error}"))?;
    let Some((schema, parser_revision, migration_revision, source_path)) = manifest else {
        return Ok(false);
    };
    let known_old_parser = [
        PRE_COMPACTION_STAGED_PARSER_REVISION,
        PRE_COMPACTION_SESSION_PARSER_REVISION,
        PAGINATED_V5_STAGED_REVISION,
        PAGINATED_V5_PARSER_REVISION,
        PAGINATED_V4_STAGED_REVISION,
        PAGINATED_V4_PARSER_REVISION,
        LEGACY_STAGED_PARSER_REVISION,
        LEGACY_SESSION_PARSER_REVISION,
    ].contains(&parser_revision.as_str());
    let known_old_migration = migration_revision == PRE_COMPACTION_EVENT_ENRICHMENT_REVISION
        || migration_revision == "exact-source-rebuild-v1";
    Ok(matches!(schema, 1 | 2 | STAGING_MANIFEST_SCHEMA_VERSION)
        && known_old_parser
        && known_old_migration
        && source_path == job.path)
}

/// Preserve private recovery artifacts outside the active staging enumeration.
/// Never discard an original session or the last published index.
fn preserve_private_stage_family(path: &Path) -> Result<(), String> {
    #[cfg(not(test))]
    {
        if !existing_regular_index(path)? {
            return Ok(());
        }
        let mut preserved_name = path.as_os_str().to_os_string();
        preserved_name.push(format!(".preserved.{}", Uuid::new_v4()));
        let preserved = PathBuf::from(preserved_name);
        crate::core::business_store_route::clone_exact_store(path, &preserved)?;
        crate::core::business_store_route::remove_exact_store(path)?;
        return Ok(());
    }
    #[cfg(test)]
    {
    let members: Vec<PathBuf> = ["", "-journal", "-wal", "-shm"].iter()
        .map(|suffix| PathBuf::from(format!("{}{suffix}", path.display())))
        .filter(|p| p.exists()).collect();
    if members.is_empty() { return Ok(()); }
    let destination = path.parent().ok_or("暂存路径无父目录")?.join("preserved").join(Uuid::new_v4().to_string());
    fs::create_dir_all(&destination).map_err(|e| e.to_string())?;
    for source in members {
        fs::rename(&source, destination.join(source.file_name().ok_or("暂存路径无文件名")?)).map_err(|e| e.to_string())?;
    }
    Ok(())
    }
}
