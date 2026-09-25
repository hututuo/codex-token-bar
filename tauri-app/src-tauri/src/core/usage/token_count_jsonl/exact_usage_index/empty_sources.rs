//! A newly discovered empty file has no token facts to parse or reconcile.
//! Keep its checkpoint in bounded pending-generation transactions rather than
//! paying for a separate durable SQLite staging database for every empty file.
//! Existing sources (including truncated/relocated history) never use this lane.
use super::*;

pub(super) const BATCH_SIZE: usize = 128;

pub(super) struct EmptySourceJob {
    file: PathBuf,
    path: String,
    session_id: String,
    signature: FileSignature,
}

fn is_new_source(connection: &Connection, path: &str, session_id: &str) -> Result<bool, String> {
    connection.query_row(
        "SELECT NOT EXISTS(SELECT 1 FROM sources WHERE path=?1)
            AND (?2='' OR NOT EXISTS(SELECT 1 FROM sources WHERE session_id=?2))",
        params![path, session_id], |row| row.get(0),
    ).map_err(|error| format!("无法确认空文件是否已有历史来源：{error}"))
}

pub(super) fn queue_if_new(
    connection: &Connection,
    file: &Path,
    path: &str,
    signature: FileSignature,
    jobs: &mut Vec<EmptySourceJob>,
) -> Result<bool, String> {
    if signature.size != 0 { return Ok(false); }
    let session_id = session_id_from_file(file);
    if !is_new_source(connection, path, &session_id)? { return Ok(false); }
    jobs.push(EmptySourceJob {
        file: file.to_path_buf(), path: path.into(), session_id, signature,
    });
    Ok(true)
}

// Both queries refer to the same regular file. A renamed/replaced path is not
// evidence that the original empty observation can be published unchanged.
fn current_signature(job: &EmptySourceJob) -> Result<Option<FileSignature>, String> {
    let handle = match fs::File::open(&job.file) {
        Ok(handle) => handle,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("读取空会话文件失败：{}（{error}）", job.file.display())),
    };
    let canonical = fs::canonicalize(&job.file)
        .map_err(|error| format!("复核空文件物理路径失败：{error}"))?;
    if canonical != job.file || !handle.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err(format!("空会话文件的物理边界发生变化：{}", job.file.display()));
    }
    let opened = file_signature_from_handle(&handle, &job.file)?;
    let by_path = file_signature(&job.file)?;
    if opened != by_path {
        return Err(format!("空会话文件在元数据复核期间发生变化：{}", job.file.display()));
    }
    Ok(Some(opened))
}

pub(super) fn import_new_sources(
    connection: &mut Connection,
    generation: i64,
    jobs: &[EmptySourceJob],
    full_rebuild_jobs: &mut Vec<FullRebuildJob>,
    warnings: &mut Vec<LocalDataWarning>,
    scan_completeness: &mut ExactScanCompleteness,
    diagnostics: &mut ExactScanDiagnostics,
) -> Result<(), String> {
    // This is the proof of an empty prefix, not a hash of any source body.
    let empty_prefix: [u8; 32] = Sha256::digest([]).into();
    let accounting_state = AccountingState::fresh().encode();
    for batch in jobs.chunks(BATCH_SIZE) {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("无法开始空文件检查点批次：{error}"))?;
        ensure_active_build_generation(&transaction, generation)?;
        let mut imported = Vec::new();
        let mut deferred = Vec::new();
        for job in batch {
            let signature = match current_signature(job) {
                Ok(Some(signature)) => signature,
                Ok(None) => continue, // No historical facts have been reserved for this new source.
                Err(error) => {
                    scan_completeness.mark_incomplete();
                    warnings.push(scan_warning(error));
                    continue;
                }
            };
            let still_new = is_new_source(&transaction, &job.path, &job.session_id)?;
            let base = reserve_staging_source(&transaction, &job.path, &job.session_id)?;
            if signature != job.signature || !still_new {
                // Growth, replacement, or a newly rebound identity gets the
                // ordinary fixed-prefix parser and ledger reconciliation.
                diagnostics.source_drift |= signature != job.signature;
                deferred.push(FullRebuildJob {
                    file: job.file.clone(), path: job.path.clone(), session_id: job.session_id.clone(),
                    source_id: base.source_id, base_generation: base.generation,
                    base_resume_offset: base.resume_offset, base_prefix_sha256: base.prefix_sha256,
                    signature, event_enrichment: false, expected_published_prefix_sha256: None,
                });
                continue;
            }
            transaction.execute(
                "INSERT INTO files(generation,path,deleted,session_id,size,modified_ns,
                    prefix_sha256,source_id,append_ready,resume_offset,accounting_state)
                 VALUES (?1,?2,0,?3,0,?4,?5,?6,1,0,?7)",
                params![generation, &job.path, &job.session_id, signature.modified_ns.to_string(),
                    empty_prefix.as_slice(), base.source_id, &accounting_state],
            ).map_err(|error| format!("无法登记新空文件检查点：{error}"))?;
            record_source_observation(&transaction, &job.path, signature)?;
            imported.push(&job.file);
        }
        if !imported.is_empty() { mark_dashboard_changed(&transaction)?; }
        transaction.commit().map_err(|error| format!("无法提交空文件检查点批次：{error}"))?;
        full_rebuild_jobs.extend(deferred);
        #[cfg(test)]
        {
            EMPTY_BATCH_COMMITS.fetch_add(1, Ordering::SeqCst);
            EMPTY_SOURCE_IMPORTS.fetch_add(imported.len() as u64, Ordering::SeqCst);
        }
        // No batch is exposed as published history before finalize_generation.
        // Reuse the existing interruption boundary after the real commit.
        for file in imported { run_after_file_commit_hook_for_testing(file)?; }
    }
    Ok(())
}

#[cfg(test)]
pub(super) static STAGED_DATABASE_BUILDS: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static EMPTY_BATCH_COMMITS: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
static EMPTY_SOURCE_IMPORTS: AtomicU64 = AtomicU64::new(0);
#[cfg(test)]
pub(super) fn reset_test_counters() {
    STAGED_DATABASE_BUILDS.store(0, Ordering::SeqCst);
    EMPTY_BATCH_COMMITS.store(0, Ordering::SeqCst);
    EMPTY_SOURCE_IMPORTS.store(0, Ordering::SeqCst);
}
#[cfg(test)]
pub(super) fn test_counters() -> (u64, u64, u64) {
    (STAGED_DATABASE_BUILDS.load(Ordering::SeqCst),
     EMPTY_BATCH_COMMITS.load(Ordering::SeqCst), EMPTY_SOURCE_IMPORTS.load(Ordering::SeqCst))
}

#[cfg(test)]
mod tests;
