//! Opt-in source-count pressure through production A routing.
//! The probe entry point never compiles under cfg(test); only the measurement
//! lifetime guard is unit-tested there. Shipped apps exclude this module.
use super::*;
use serde_json::{json, Value};

struct Measurement {
    started: Instant,
    last_update: Instant,
    expected_sources: u64,
    staged_jobs: u64,
    batches: u64,
    peak_stores: u64,
    peak_tables: u64,
    progress_events: u64,
    backfill_progress_events: u64,
    last_backfill_completed: u64,
    model_backfill_monotonic: bool,
    progress_error: Option<String>,
    largest_gap: f64,
    scope_timings: std::collections::BTreeMap<&'static str, ScopeTiming>,
}

#[derive(Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ScopeTiming {
    calls: u64,
    total_seconds: f64,
    maximum_seconds: f64,
}

/// Fixture-only wall scopes overlap when nested or running on different
/// workers. They identify lifecycle cost; their sum is not elapsed runtime.
#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(crate) struct ScopeGuard {
    label: &'static str,
    started: Instant,
    measurement_started: Instant,
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(crate) fn scope(label: &'static str) -> Option<ScopeGuard> {
    let measurement_started = measurement().lock().ok()?.as_ref()?.started;
    Some(ScopeGuard { label, started: Instant::now(), measurement_started })
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
impl Drop for ScopeGuard {
    fn drop(&mut self) {
        let elapsed = self.started.elapsed().as_secs_f64();
        let Ok(mut slot) = measurement().lock() else { return };
        let Some(value) = slot.as_mut() else { return };
        if value.started != self.measurement_started { return; }
        let timing = value.scope_timings.entry(self.label).or_default();
        timing.calls += 1;
        timing.total_seconds += elapsed;
        timing.maximum_seconds = timing.maximum_seconds.max(elapsed);
    }
}

fn measurement() -> &'static Mutex<Option<Measurement>> {
    static ACTIVE: OnceLock<Mutex<Option<Measurement>>> = OnceLock::new();
    ACTIVE.get_or_init(|| Mutex::new(None))
}

struct MeasurementGuard;
impl Drop for MeasurementGuard {
    fn drop(&mut self) {
        measurement().lock().unwrap_or_else(|error| error.into_inner()).take();
    }
}

pub(super) fn measurement_active() -> bool {
    measurement().lock().unwrap_or_else(|error| error.into_inner()).is_some()
}

fn begin(expected_sources: u64) -> Result<MeasurementGuard, String> {
    let mut slot = measurement().lock().map_err(|e| e.to_string())?;
    if slot.is_some() { return Err("overlapping source-count fixture measurements".into()); }
    let now = Instant::now();
    *slot = Some(Measurement { started: now, last_update: now, expected_sources,
        staged_jobs: 0, batches: 0, peak_stores: 0, peak_tables: 0,
        progress_events: 0, backfill_progress_events: 0, last_backfill_completed: 0,
        model_backfill_monotonic: true, progress_error: None, largest_gap: 0.0,
        scope_timings: std::collections::BTreeMap::new() });
    Ok(MeasurementGuard)
}

fn finish(_guard: MeasurementGuard, phase: &str) -> Result<Value, String> {
    let mut value = measurement().lock().map_err(|e| e.to_string())?.take()
        .ok_or("source-count fixture measurement was not active")?;
    value.largest_gap = value.largest_gap.max(value.last_update.elapsed().as_secs_f64());
    let report = json!({"elapsedSeconds":value.started.elapsed().as_secs_f64(),
        "stagedJobs":value.staged_jobs,"batches":value.batches,
        "peakStageStores":value.peak_stores,"peakStageTables":value.peak_tables,
        "progressEvents":value.progress_events,"backfillProgressEvents":value.backfill_progress_events,
        "lastBackfillCompleted":value.last_backfill_completed,
        "modelBackfillMonotonic":(value.backfill_progress_events > 0).then_some(value.model_backfill_monotonic),
        "modelBackfillProgressError":value.progress_error,
        "largestProgressGapSeconds":value.largest_gap,
        "runtimeScopes":value.scope_timings,
        "runtimeScopeSemantics":"Nested and parallel wall scopes overlap; totals must not be summed as elapsed runtime"});
    // Keep completed-phase measurements in stderr even when a later phase
    // fails or the harness deadline kills the process. These are observations,
    // not a substitute for the final full-profile assertions.
    eprintln!("{}", json!({"fixture":"rust-source-count", "phase":phase,
        "files":value.expected_sources, "measurement":&report}));
    Ok(report)
}

pub(super) fn progress(phase: &str, completed: u64, total: Option<u64>) {
    let Ok(mut slot) = measurement().lock() else { return };
    let Some(value) = slot.as_mut() else { return };
    value.largest_gap = value.largest_gap.max(value.last_update.elapsed().as_secs_f64());
    value.last_update = Instant::now();
    value.progress_events += 1;
    if phase == "backfillingModel" {
        let valid = completed >= value.last_backfill_completed
            && completed <= value.expected_sources && total == Some(value.expected_sources);
        if !valid && value.progress_error.is_none() {
            value.progress_error = Some(format!("completed {} -> {completed}, total {total:?}, expected {}",
                value.last_backfill_completed, value.expected_sources));
        }
        value.model_backfill_monotonic &= valid;
        value.last_backfill_completed = completed;
        value.backfill_progress_events += 1;
    }
}

fn stage_catalog_counts() -> Result<(u64, u64), String> {
    let raw = sqlite::open_read_only(&crate::core::business_store_route::container_path()?,
        StdDuration::from_secs(3)).map_err(|e| e.to_string())?;
    raw.query_row(
        "WITH stages AS (SELECT s.store_id,s.namespace_prefix FROM tb_stores s WHERE s.module='exact' \
         AND EXISTS(SELECT 1 FROM sqlite_master m WHERE m.type='table' AND m.name=s.namespace_prefix||'manifest')) \
         SELECT (SELECT COUNT(*) FROM stages), \
         (SELECT COUNT(*) FROM sqlite_master m JOIN stages s ON substr(m.name,1,length(s.namespace_prefix))=s.namespace_prefix WHERE m.type='table')",
        [], |row| Ok((row.get::<_, u64>(0)?, row.get::<_, u64>(1)?)),
    ).map_err(|e| e.to_string())
}

/// Called after every worker in a real batch has returned its durable stage,
/// before the publisher can import or remove any member of that batch.
pub(super) fn ready_batch(count: usize) -> Result<(), String> {
    if measurement().lock().map_err(|e| e.to_string())?.is_none() { return Ok(()); }
    let (stores, tables) = stage_catalog_counts()?;
    let mut slot = measurement().lock().map_err(|e| e.to_string())?;
    let value = slot.as_mut().ok_or("source-count fixture stopped inside a staging batch")?;
    value.staged_jobs += count as u64;
    value.batches += 1;
    value.peak_stores = value.peak_stores.max(stores);
    value.peak_tables = value.peak_tables.max(tables);
    if stores != count as u64 || tables != 4 * count as u64 {
        return Err(format!("ready stage catalog differs from its actual batch: {count} jobs, {stores} stores, {tables} tables"));
    }
    if stores > STAGING_MAX_WORKERS.min(STAGING_MAX_READY_ARTIFACTS) as u64 {
        return Err("production A staging schema exceeded the bounded batch contract".into());
    }
    Ok(())
}

fn numeric_rows_digest(index: &ExactUsageIndex) -> Result<(String, u64), String> {
    let mut statement = index.connection.prepare(
        "SELECT id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,\
         user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,accounting_kind,\
         reported_total_tokens,token_source_offset,legacy_tokens FROM event_rows ORDER BY source_id,ordinal,id",
    ).map_err(|e| e.to_string())?;
    let mut rows = statement.query([]).map_err(|e| e.to_string())?;
    let mut digest = Sha256::new();
    let mut count = 0;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        count += 1;
        for column in 0..17 {
            let value = row.get_ref(column).map_err(|e| e.to_string())?;
            match value {
                rusqlite::types::ValueRef::Null => digest.update([0]),
                rusqlite::types::ValueRef::Integer(value) => { digest.update([1]); digest.update(value.to_be_bytes()); }
                rusqlite::types::ValueRef::Real(value) => { digest.update([2]); digest.update(value.to_bits().to_be_bytes()); }
                rusqlite::types::ValueRef::Text(bytes) | rusqlite::types::ValueRef::Blob(bytes) => {
                    digest.update([if matches!(value, rusqlite::types::ValueRef::Text(_)) { 3 } else { 4 }]);
                    digest.update((bytes.len() as u64).to_be_bytes()); digest.update(bytes);
                }
            }
        }
    }
    Ok((format!("{:x}", digest.finalize()), count))
}

fn source_digest(files: &[PathBuf]) -> Result<String, String> {
    let mut digest = Sha256::new();
    for file in files {
        let bytes = fs::read(file).map_err(|e| e.to_string())?;
        digest.update((bytes.len() as u64).to_be_bytes()); digest.update(bytes);
    }
    Ok(format!("{:x}", digest.finalize()))
}

#[cfg(not(test))]
fn verify_source_facts(index: &ExactUsageIndex, count: u64) -> Result<(), String> {
    let mut statement = index.connection.prepare(
        "SELECT s.session_id,e.tokens,e.input_tokens,e.cached_input_tokens,e.output_tokens,e.reasoning_output_tokens \
         FROM event_rows e JOIN sources s ON s.source_id=e.source_id",
    ).map_err(|error| error.to_string())?;
    let mut rows = statement.query([]).map_err(|error| error.to_string())?;
    let mut observed = HashSet::new();
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let session: String = row.get(0).map_err(|error| error.to_string())?;
        let number = session.strip_prefix("019f0000-0000-4000-8000-")
            .and_then(|value| u64::from_str_radix(value, 16).ok())
            .filter(|number| *number < count)
            .ok_or("cold history belongs to an unexpected source identity")?;
        let expected = [120 + number, 100 + number, 20, 20, 5];
        if !observed.insert(number) {
            return Err("cold history duplicated a source and omitted another source".into());
        }
        for (column, expected) in expected.into_iter().enumerate() {
            let actual: u64 = row.get(column + 1).map_err(|error| error.to_string())?;
            if actual != expected {
                return Err(format!("cold source {session} accounting column {column} differs: {actual} != {expected}"));
            }
        }
    }
    if observed.len() as u64 != count { return Err("cold history omitted a source's accounting facts".into()); }
    Ok(())
}

#[cfg(not(test))]
pub(super) fn verify(home: &Path, count: u64) -> Result<Value, String> {
    macro_rules! need { ($test:expr, $error:expr) => { if !$test { return Err($error.into()); } }; }
    need!((9..=8192).contains(&count), "source count must be in 9...8192");
    let sessions = home.join("sessions");
    need!(!sessions.exists(), "source-count fixture refuses an existing session root");
    fs::create_dir_all(&sessions).map_err(|e| e.to_string())?;
    let home = fs::canonicalize(home).map_err(|e| e.to_string())?;
    let mut files = Vec::with_capacity(count as usize);
    for number in 0..count {
        let id = format!("019f0000-0000-4000-8000-{number:012x}");
        let file = sessions.join(format!("rollout-{id}.jsonl"));
        let lines = [
            json!({"type":"session_meta","payload":{"id":id}}),
            json!({"type":"turn_context","payload":{"model":"gpt-5"}}),
            json!({"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count",
                "info":{"last_token_usage":{"input_tokens":100+number,"cached_input_tokens":20,
                    "output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120+number}}}}),
        ];
        let mut bytes = String::new();
        for line in lines { bytes.push_str(&line.to_string()); bytes.push('\n'); }
        fs::write(&file, bytes).map_err(|e| e.to_string())?;
        files.push(file);
    }
    let original_sources = source_digest(&files)?;
    let injected_writes_before = crate::business_store_fixture::concurrent_a_write_count();
    let expected_tokens = 120 * count + count * (count - 1) / 2;
    let started = Instant::now();
    let cold_measurement = begin(count)?;
    let cold_snapshot = super::super::dashboard_snapshot(&home)?;
    let cold = finish(cold_measurement, "cold")?;
    need!(cold_snapshot.stats.total_tokens == expected_tokens, "cold source-count history differs from input facts");
    need!(cold["stagedJobs"] == count, "cold probe did not parse every distinct source exactly once");
    need!(stage_catalog_counts()? == (0, 0), "cold scan left unpublished stage namespaces in A");
    let mut index = ExactUsageIndex::open(&home)?;
    let (before, events) = numeric_rows_digest(&index)?;
    need!(events == count, "cold probe did not publish one event per source");
    verify_source_facts(&index, count)?;
    let source_count: u64 = index.connection.query_row("SELECT COUNT(*) FROM sources WHERE deleted=0", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;
    need!(source_count == count, "cold probe did not retain every separate source identity");
    index.connection.mark_receipt_dirty();
    index.connection.execute_batch("DELETE FROM event_enrichment_sources; UPDATE event_rows SET model=NULL;")
        .map_err(|e| e.to_string())?;
    set_metadata(&index.connection, EVENT_ENRICHMENT_REVISION_KEY, PRE_COMPACTION_EVENT_ENRICHMENT_REVISION)?;
    let mut warnings = Vec::new();
    let backfill_measurement = begin(count)?;
    // Use the complete application sync owner: it performs enrichment first,
    // then finishes ordinary checkpoint/message-link publication in that same
    // operation. Timing only the private enrichment method would omit that work.
    index.sync(&home, &mut warnings)?;
    let backfill = finish(backfill_measurement, "backfill")?;
    need!(warnings.is_empty(), format!("source-count backfill emitted warnings: {warnings:?}"));
    need!(backfill["stagedJobs"] == count, "backfill probe skipped sources or reparsed a source");
    need!(backfill["modelBackfillMonotonic"] == true && backfill["lastBackfillCompleted"] == count,
        format!("actual backfill progress regressed or did not reach every source: {backfill}"));
    let (after, after_events) = numeric_rows_digest(&index)?;
    need!(before == after && after_events == count, "backfill changed typed numeric history or event identities");
    let models: u64 = index.connection.query_row("SELECT COUNT(*) FROM event_rows WHERE model='gpt-5'", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;
    need!(models == count && !index.migration_pending(), "backfill did not complete the actual model migration");
    need!(stage_catalog_counts()? == (0, 0), "backfill retained new stage namespaces after publication");
    let revision = index.revision()?;
    let warm_measurement = begin(count)?;
    index.sync(&home, &mut warnings)?;
    let warm = finish(warm_measurement, "warm")?;
    need!(warm["stagedJobs"] == 0 && index.revision()? == revision,
        format!("warm refresh reparsed or republished unchanged sources: before revision {revision}, after {}, metrics {warm}", index.revision()?));
    need!(index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?.total_tokens == expected_tokens,
        "warm replay lost or double-counted history");
    need!(numeric_rows_digest(&index)? == (before.clone(), count),
        "warm refresh changed typed numeric history or event identities");
    need!(source_digest(&files)? == original_sources, "production scan modified original rollouts");
    let injected_writes = crate::business_store_fixture::concurrent_a_write_count() - injected_writes_before;
    need!(injected_writes == 0, "scale timing included the default fixture's artificial concurrent-writer injection");
    Ok(json!({"status":"PASS","files":count,"events":events,"tokens":expected_tokens,
        "cfgTest":false,"nativeProductionRoutes":true,"cold":cold,"backfill":backfill,"warm":warm,
        "concurrentWriterProbeEnabled":false,"concurrentWriteAssertions":injected_writes,
        "sourceFactsVerified":true,"sourceBytesUnchanged":true,"sourceBytesDigest":original_sources,
        "numericRowsDigestBefore":before,"numericRowsDigestAfter":after,
        "modelsRestored":models,"stageStoresAfter":0,"totalSeconds":started.elapsed().as_secs_f64()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn injected_writer_suppression_ends_after_error_or_panic() {
        let failed = (|| -> Result<(), String> {
            let _guard = begin(13)?;
            assert!(measurement_active());
            Err("fixture returned an error".into())
        })();
        assert!(failed.is_err());
        assert!(!measurement_active());

        let panicked = std::panic::catch_unwind(|| {
            let _guard = begin(13).unwrap();
            assert!(measurement_active());
            panic!("fixture unwound during a phase");
        });
        assert!(panicked.is_err());
        assert!(!measurement_active());

        let retried = finish(begin(13).unwrap(), "retry").unwrap();
        assert!(retried["modelBackfillMonotonic"].is_null(),
            "a phase without model observations cannot claim a monotonicity proof");
        assert!(!measurement_active());
    }
}
