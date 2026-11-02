//! Production Exact reconciliation profile against a synthetic, disposable home.
//!
//! The JSONL producer and the retained empty candidate namespaces are synthetic
//! workload only. The measured refresh, enrichment, publication, and summary
//! calls below are the actual Rust production entrypoints.

use super::super::*;
use crate::core::business_store_sql::SQLiteStoreNamespace;
use crate::core::{app_paths, business_store_route as route};
use rusqlite::{params, Connection as RawConnection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

const SOURCE_COUNT: usize = 4_124;
const EVENTS_PER_SOURCE: usize = 122;
const EVENT_COUNT: usize = SOURCE_COUNT * EVENTS_PER_SOURCE;
const TOKENS_PER_EVENT: u64 = 5;
const TOTAL_TOKENS: u64 = EVENT_COUNT as u64 * TOKENS_PER_EVENT;
const SEEDED_CANDIDATE_COUNT: usize = 6_250;
const EXTRA_LEGACY_CANDIDATES: usize = SEEDED_CANDIDATE_COUNT - SOURCE_COUNT;
const EVENT_MODEL: &str = "gpt-6.1-sol";
const TABLES: [&str; 4] = ["manifest", "fingerprints", "events", "chunks"];
const SOURCE_HOME_ENV: [&str; 5] = [
    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
    "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR",
    "CODEX_TOKEN_BAR_CACHE_BASE_DIR",
    "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RawMetrics {
    rows: i64,
    id_sum: i64,
    token_sum: i64,
    distinct_timestamps: i64,
    sources: i64,
    accounting_digest: [u8; 32],
}

struct SourceJob {
    job: FullRebuildJob,
}

pub(super) fn verify_scale(home: &Path) -> Result<Value, String> {
    let preparation_started = Instant::now();
    let home = prepare_isolated_home(home)?;
    let sessions = home.join("sessions");
    fs::create_dir_all(&sessions).map_err(|error| error.to_string())?;

    let source_files = write_sources(&sessions)?;
    let source_hashes = source_files
        .iter()
        .map(|path| Ok((path.clone(), sha256_file(path)?)))
        .collect::<Result<Vec<_>, String>>()?;

    // Establish the old, published dashboard through the normal production
    // refresh before seeding stale virtual candidate namespaces.
    route::bootstrap()?;
    let index_path = database_path(&home)?;
    refuse_existing_index(&index_path)?;
    let initial_started = Instant::now();
    let initial_dashboard = super::super::super::dashboard_snapshot(&home)?;
    let initial_snapshot_seconds = initial_started.elapsed().as_secs_f64();
    if !initial_dashboard.warnings.is_empty() {
        return Err(format!(
            "initial production snapshot emitted warnings: {}",
            initial_dashboard
                .warnings
                .iter()
                .map(|warning| warning.message.clone())
                .collect::<Vec<_>>()
                .join(" | ")
        ));
    }
    assert_dashboard(
        &initial_dashboard.stats,
        SOURCE_COUNT,
        EVENT_COUNT,
        TOTAL_TOKENS,
    )?;

    let mut index = ExactUsageIndex::open(&home)?;
    let generation = i64::try_from(index.published_generation()?)
        .map_err(|_| "published generation exceeds SQLite integer range")?;
    let target_generation = generation
        .checked_add(1)
        .ok_or("published generation overflow")?;
    let jobs = source_jobs(&index)?;
    if jobs.len() != SOURCE_COUNT {
        return Err(format!(
            "scale fixture expected {SOURCE_COUNT} published sources, found {}",
            jobs.len()
        ));
    }
    let before_raw = raw_metrics(&index.connection)?;
    assert_raw_metrics(before_raw)?;
    let initial_summary = index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?;
    if initial_summary.total_tokens != TOTAL_TOKENS {
        return Err(format!(
            "initial production summary mismatch: expected {TOTAL_TOKENS}, found {}",
            initial_summary.total_tokens
        ));
    }
    let initial_model_events: i64 = index
        .connection
        .query_row(
            "SELECT COUNT(*) FROM event_rows WHERE model=?1",
            [EVENT_MODEL],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if initial_model_events != EVENT_COUNT as i64 {
        return Err(format!(
            "initial producer model context mismatch: expected {EVENT_COUNT}, found {initial_model_events}"
        ));
    }

    let pool_reader = RawConnection::open_with_flags(
        route::container_path()?,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|error| error.to_string())?;
    let pool_ready: bool = pool_reader
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM tb_stores WHERE module='exact.rust.pool' AND state='ready')",
            [],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if !pool_ready {
        return Err("initial production refresh did not create the fixed Rust stage pool".into());
    }

    let seed_started = Instant::now();
    let seeded_paths = seed_empty_candidate_namespaces(&index_path, &jobs, target_generation)?;
    let seeded = candidate_catalog_metrics(&index_path)?;
    if seeded.0 != SEEDED_CANDIDATE_COUNT as i64
        || seeded.1 != (SEEDED_CANDIDATE_COUNT * TABLES.len()) as i64
    {
        return Err(format!(
            "candidate namespace seed mismatch: stores={}, objects={}",
            seeded.0, seeded.1
        ));
    }
    let initial_empty_candidate_rows = empty_candidate_table_rows(&index_path)?;
    if initial_empty_candidate_rows != 0 {
        return Err(format!(
            "synthetic building candidate tables unexpectedly contain rows: {initial_empty_candidate_rows}"
        ));
    }
    let baseline_catalog = main_catalog_metrics()?;

    // Reproduce the old disposable enrichment projection only. Raw event rows,
    // exact identities, consumption totals, and producer bytes remain intact.
    index.connection.mark_receipt_dirty();
    index
        .connection
        .execute("UPDATE event_rows SET model=NULL", [])
        .map_err(|error| format!("cannot clear synthetic event model enrichment: {error}"))?;
    index
        .connection
        .execute("DELETE FROM event_enrichment_sources", [])
        .map_err(|error| format!("cannot clear synthetic enrichment receipts: {error}"))?;
    set_metadata(
        &index.connection,
        EVENT_ENRICHMENT_REVISION_KEY,
        PRE_COMPACTION_EVENT_ENRICHMENT_REVISION,
    )?;
    let preparation_seconds = preparation_started.elapsed().as_secs_f64();
    let namespace_preparation_seconds = seed_started.elapsed().as_secs_f64();

    let backfill_started = Instant::now();
    let mut warnings = Vec::new();
    index.synchronize_event_enrichment(&home, &index_path, &mut warnings, ExactSyncMode::Full)?;
    index.sync(&home, &mut warnings)?;
    let backfill_summary = index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?;
    let backfill_seconds = backfill_started.elapsed().as_secs_f64();
    if !warnings.is_empty() {
        return Err(format!(
            "production scale backfill emitted warnings instead of proving complete enrichment: {}",
            warnings
                .iter()
                .map(|warning| warning.message.clone())
                .collect::<Vec<_>>()
                .join(" | ")
        ));
    }

    let after_raw = raw_metrics(&index.connection)?;
    assert_raw_preserved(before_raw, after_raw)?;
    let enriched_events: i64 = index
        .connection
        .query_row(
            "SELECT COUNT(*) FROM event_rows WHERE model=?1",
            [EVENT_MODEL],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    let enrichment_receipts: i64 = index
        .connection
        .query_row("SELECT COUNT(*) FROM event_enrichment_sources", [], |row| {
            row.get(0)
        })
        .map_err(|error| error.to_string())?;
    if enriched_events != EVENT_COUNT as i64 || enrichment_receipts != SOURCE_COUNT as i64 {
        return Err(format!(
            "production enrichment incomplete: modelEvents={enriched_events}, receipts={enrichment_receipts}"
        ));
    }
    if backfill_summary.total_tokens != initial_summary.total_tokens
        || backfill_summary.total_tokens != TOTAL_TOKENS
    {
        return Err(format!(
            "production summary changed across enrichment: initial={}, after={}",
            initial_summary.total_tokens, backfill_summary.total_tokens
        ));
    }

    let mut unchanged_seconds = Vec::with_capacity(20);
    for _ in 0..20 {
        let started = Instant::now();
        index.sync(&home, &mut warnings)?;
        unchanged_seconds.push(started.elapsed().as_secs_f64());
        let summary = index.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?;
        if summary.total_tokens != TOTAL_TOKENS {
            return Err("unchanged production sync changed the exact total".into());
        }
    }
    if !warnings.is_empty() {
        return Err("unchanged production sync emitted local data warnings".into());
    }
    let unchanged_p95 = percentile_95(&mut unchanged_seconds);

    drop(index);
    let final_dashboard = super::super::super::dashboard_snapshot(&home)?;
    if !final_dashboard.warnings.is_empty() {
        return Err(format!(
            "final production snapshot emitted warnings: {}",
            final_dashboard
                .warnings
                .iter()
                .map(|warning| warning.message.clone())
                .collect::<Vec<_>>()
                .join(" | ")
        ));
    }
    assert_dashboard(
        &final_dashboard.stats,
        SOURCE_COUNT,
        EVENT_COUNT,
        TOTAL_TOKENS,
    )?;
    let final_dashboard_summary =
        ExactUsageIndex::open(&home)?.summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?;
    if final_dashboard_summary.total_tokens != initial_summary.total_tokens {
        return Err(
            "final production dashboard summary differs from the initial exact total".into(),
        );
    }

    let final_catalog = main_catalog_metrics()?;
    let retained = candidate_catalog_metrics(&index_path)?;
    let final_empty_candidate_rows = empty_candidate_table_rows(&index_path)?;
    let physical_candidate_files_absent = seeded_paths
        .iter()
        .map(|path| path_is_absent(path))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .all(|absent| absent);
    if final_catalog != baseline_catalog {
        return Err(format!(
            "production backfill changed MAIN/catalog counts: before={baseline_catalog:?}, after={final_catalog:?}"
        ));
    }
    if retained != seeded {
        return Err(format!(
            "production backfill consumed or altered retained empty candidates: before={seeded:?}, after={retained:?}"
        ));
    }
    if final_empty_candidate_rows != initial_empty_candidate_rows {
        return Err(format!(
            "production refresh changed rows in empty candidate tables: before={initial_empty_candidate_rows}, after={final_empty_candidate_rows}"
        ));
    }
    if !physical_candidate_files_absent {
        return Err(
            "empty virtual candidate namespace unexpectedly created a physical database".into(),
        );
    }
    let sealed_or_receipted: i64 = candidate_sealed_or_receipted_count(&index_path)?;
    if sealed_or_receipted != 0 {
        return Err(format!(
            "empty candidate namespaces acquired a seal/import receipt: {sealed_or_receipted}"
        ));
    }

    for (path, expected) in &source_hashes {
        if sha256_file(path)? != *expected {
            return Err(format!(
                "synthetic raw source bytes changed: {}",
                path.display()
            ));
        }
    }

    let budget_passed = backfill_seconds <= 600.0 && unchanged_p95 <= 1.0;
    Ok(json!({
        "name": "exact-rust-production-scale-fixture",
        "status": "PROFILED",
        "scope": "actual Rust Exact production refresh/enrichment/summary entrypoints over synthetic input and synthetic retained candidate namespaces; not a real historical producer",
        "sourceCounts": SOURCE_COUNT,
        "events": EVENT_COUNT,
        "tokens": TOTAL_TOKENS,
        "backfillSeconds": backfill_seconds,
        "preparationSeconds": preparation_seconds,
        "initialSnapshotSeconds": initial_snapshot_seconds,
        "namespacePreparationSeconds": namespace_preparation_seconds,
        "unchangedP95": unchanged_p95,
        "unchangedSyncSamples": unchanged_seconds,
        "objects": {
            "mainUserObjectsBeforeBackfill": baseline_catalog.main_objects,
            "mainUserObjectsAfterBackfill": final_catalog.main_objects,
            "mainUserObjectDelta": final_catalog.main_objects - baseline_catalog.main_objects,
            "storeObjectCatalogBeforeBackfill": baseline_catalog.store_objects,
            "storeObjectCatalogAfterBackfill": final_catalog.store_objects,
            "storeObjectCatalogDelta": final_catalog.store_objects - baseline_catalog.store_objects,
            "seededCandidateObjects": seeded.1,
        },
        "stores": {
            "beforeBackfill": baseline_catalog.stores,
            "afterBackfill": final_catalog.stores,
            "delta": final_catalog.stores - baseline_catalog.stores,
            "seededEmptyCandidateNamespaces": seeded.0,
            "retainedEmptyCandidateNamespaces": retained.0,
            "sealedOrReceiptedCandidates": sealed_or_receipted,
            "emptyCandidateTableRows": final_empty_candidate_rows,
        },
        "correctness": {
            "initialRawRows": before_raw.rows,
            "finalRawRows": after_raw.rows,
            "preservedRawEventIdsAndTokens": before_raw == after_raw,
            "rawAccountingDigestBefore": hex(&before_raw.accounting_digest),
            "rawAccountingDigestAfter": hex(&after_raw.accounting_digest),
            "dashboardSummaryPreserved": true,
            "modelEnrichmentEvents": enriched_events,
            "enrichmentReceipts": enrichment_receipts,
            "uniqueRawEventTimestamps": after_raw.distinct_timestamps,
            "sourceBytesPreserved": true,
            "fixedPoolExistedBeforeCandidateSeed": pool_ready,
            "mainObjectAndStoreDeltasZero": final_catalog == baseline_catalog,
            "allEmptyCandidatesRetained": retained == seeded,
            "candidateTablesRemainEmpty": final_empty_candidate_rows == 0,
            "candidateSourceDigestsMatchRawSourcePaths": true,
            "candidateFilesRemainVirtual": physical_candidate_files_absent,
            "warnings": warnings.len(),
        },
        "budgetPassed": budget_passed,
        "budget": {"backfillSecondsMax": 600.0, "unchangedP95SecondsMax": 1.0},
    }))
}

fn prepare_isolated_home(input: &Path) -> Result<PathBuf, String> {
    if !input.is_absolute() {
        return Err("scale fixture home must be absolute".into());
    }
    match fs::symlink_metadata(input) {
        Ok(_) => {
            return Err(format!(
                "scale fixture refuses an existing home: {}",
                input.display()
            ))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("cannot inspect scale fixture home: {error}")),
    }
    let root = input
        .parent()
        .ok_or("scale fixture home has no external root")?;
    if !root.is_dir() {
        return Err("scale fixture parent root must already exist".into());
    }
    let root = fs::canonicalize(root).map_err(|error| error.to_string())?;
    let system_home = app_paths::home_dir();
    let system_home = fs::canonicalize(&system_home).unwrap_or(system_home);
    if root.starts_with(&system_home) || system_home.starts_with(&root) {
        return Err("scale fixture root overlaps the current user home".into());
    }
    for key in SOURCE_HOME_ENV {
        let value = std::env::var_os(key).ok_or_else(|| format!("missing path override {key}"))?;
        let path = PathBuf::from(value);
        if !path.is_absolute() || !path.starts_with(&root) {
            return Err(format!(
                "{key} must be absolute and inside scale fixture root"
            ));
        }
        let canonical =
            fs::canonicalize(&path).map_err(|error| format!("cannot resolve {key}: {error}"))?;
        if !canonical.starts_with(&root) {
            return Err(format!("{key} resolves outside scale fixture root"));
        }
    }
    let name = input
        .file_name()
        .ok_or("scale fixture home has no filename")?;
    Ok(root.join(name))
}

fn refuse_existing_index(index_path: &Path) -> Result<(), String> {
    let mut staging = index_path.as_os_str().to_os_string();
    staging.push(".staging");
    let continuity_marker = sqlite_sidecar_path(index_path, ".attribution-continuity-unsafe.json");
    let integrity_receipt = sqlite_sidecar_path(index_path, INDEX_INTEGRITY_RECEIPT_SUFFIX);
    let operation_lock = sqlite_sidecar_path(index_path, ".operation.lock");
    let mut paths = vec![
        index_path.to_path_buf(),
        PathBuf::from(staging),
        continuity_marker,
        integrity_receipt,
        operation_lock,
    ];
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut sidecar = index_path.as_os_str().to_os_string();
        sidecar.push(suffix);
        paths.push(PathBuf::from(sidecar));
    }
    for path in paths {
        match fs::symlink_metadata(&path) {
            Ok(_) => {
                return Err(format!(
                    "scale fixture refuses existing Exact index/staging path: {}",
                    path.display()
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("cannot inspect Exact target path: {error}")),
        }
    }
    let spec = route::exact_store_spec(index_path)?;
    let connection = RawConnection::open_with_flags(
        route::container_path()?,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|error| error.to_string())?;
    let exists: bool = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1 OR logical_path=?2)",
            params![spec.id, spec.logical_path],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if exists {
        return Err("scale fixture refuses an existing Exact store namespace".into());
    }
    Ok(())
}

fn write_sources(sessions: &Path) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::with_capacity(SOURCE_COUNT);
    let base_unix = 1_793_145_600_i64;
    for source_index in 0..SOURCE_COUNT {
        let session_id = format!("00000000-0000-4000-8000-{source_index:012x}");
        let path = sessions.join(format!("scale-{source_index:04}.jsonl"));
        if path.exists() {
            return Err(format!(
                "scale fixture refuses existing source: {}",
                path.display()
            ));
        }
        let file = File::options()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|error| {
                format!("cannot create synthetic source {}: {error}", path.display())
            })?;
        let mut writer = BufWriter::with_capacity(64 * 1024, file);
        let source_base = base_unix + (source_index as i64) * (EVENTS_PER_SOURCE as i64 + 2);
        write_json_line(
            &mut writer,
            &json!({
                "timestamp": rfc3339(source_base)?,
                "type": "session_meta",
                "payload": {"id": session_id},
            }),
        )?;
        write_json_line(
            &mut writer,
            &json!({
                "timestamp": rfc3339(source_base + 1)?,
                "type": "turn_context",
                "payload": {"model": EVENT_MODEL},
            }),
        )?;
        for event_index in 0..EVENTS_PER_SOURCE {
            let timestamp = source_base + 2 + event_index as i64;
            write_json_line(
                &mut writer,
                &json!({
                    "timestamp": rfc3339(timestamp)?,
                    "type": "event_msg",
                    "payload": {
                        "type": "token_count",
                        "info": {"last_token_usage": {
                            "input_tokens": 5,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                            "total_tokens": 5,
                        }},
                    },
                }),
            )?;
        }
        writer.flush().map_err(|error| error.to_string())?;
        files.push(path);
    }
    if files.len() != SOURCE_COUNT {
        return Err("synthetic source count changed while generating fixtures".into());
    }
    Ok(files)
}

fn write_json_line(writer: &mut impl Write, value: &Value) -> Result<(), String> {
    serde_json::to_writer(&mut *writer, value).map_err(|error| error.to_string())?;
    writer.write_all(b"\n").map_err(|error| error.to_string())
}

fn rfc3339(unix_seconds: i64) -> Result<String, String> {
    OffsetDateTime::from_unix_timestamp(unix_seconds)
        .map_err(|error| error.to_string())?
        .format(&Rfc3339)
        .map_err(|error| error.to_string())
}

fn source_jobs(index: &ExactUsageIndex) -> Result<Vec<SourceJob>, String> {
    let mut statement = index.connection.prepare(
        "SELECT source_id,path,session_id,last_seen_generation,resume_offset,prefix_sha256,size,modified_ns \
         FROM sources WHERE deleted=0 ORDER BY path",
    ).map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<i64>>(4)?,
                row.get::<_, Vec<u8>>(5)?,
                row.get::<_, i64>(6)?,
                row.get::<_, String>(7)?,
            ))
        })
        .map_err(|error| error.to_string())?;
    let mut jobs = Vec::with_capacity(SOURCE_COUNT);
    for row in rows {
        let (source_id, path, session_id, base_generation, resume, raw_prefix, size, modified) =
            row.map_err(|error| error.to_string())?;
        let prefix: [u8; 32] = raw_prefix
            .try_into()
            .map_err(|_| format!("published source has invalid prefix digest: {path}"))?;
        let base_resume_offset = resume
            .map(u64::try_from)
            .transpose()
            .map_err(|_| format!("published source has a negative resume offset: {path}"))?;
        let modified_ns = modified
            .parse::<u128>()
            .map_err(|_| format!("published source has an invalid modification time: {path}"))?;
        jobs.push(SourceJob {
            job: FullRebuildJob {
                file: PathBuf::from(&path),
                path,
                session_id,
                source_id,
                base_generation,
                base_resume_offset,
                base_prefix_sha256: Some(prefix),
                signature: FileSignature {
                    size: size as u64,
                    modified_ns,
                    physical: None,
                },
                event_enrichment: true,
                expected_published_prefix_sha256: Some(prefix),
            },
        });
    }
    Ok(jobs)
}

fn seed_empty_candidate_namespaces(
    index_path: &Path,
    jobs: &[SourceJob],
    target_generation: i64,
) -> Result<Vec<PathBuf>, String> {
    if jobs.len() != SOURCE_COUNT {
        return Err("candidate seed requires the complete synthetic source set".into());
    }
    let container_path = route::container_path()?;
    let mut raw = RawConnection::open_with_flags(
        &container_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
    )
    .map_err(|error| error.to_string())?;
    raw.busy_timeout(Duration::from_secs(30))
        .map_err(|error| error.to_string())?;
    let transaction = raw.transaction().map_err(|error| error.to_string())?;
    let schema = staging_schema_sql(false);
    let schema_statements = schema
        .split(';')
        .map(str::trim)
        .filter(|statement| !statement.is_empty())
        .collect::<Vec<_>>();
    if schema_statements.len() != TABLES.len() {
        return Err(format!(
            "staging_schema_sql(false) table count changed: expected {}, found {}",
            TABLES.len(),
            schema_statements.len()
        ));
    }

    let mut inserted = 0usize;
    let mut paths = Vec::with_capacity(SEEDED_CANDIDATE_COUNT);
    for (job_index, source) in jobs.iter().enumerate() {
        let path = legacy_candidate_path(index_path, &source.job, job_index, target_generation)?;
        seed_candidate_path(&transaction, &path)?;
        paths.push(path);
        inserted += 1;
        if inserted > SEEDED_CANDIDATE_COUNT {
            return Err("candidate seed exceeded its fixed namespace budget".into());
        }
        if job_index < EXTRA_LEGACY_CANDIDATES {
            let secondary = legacy_candidate_path(
                index_path,
                &source.job,
                job_index + SOURCE_COUNT,
                target_generation,
            )?;
            seed_candidate_path(&transaction, &secondary)?;
            paths.push(secondary);
            inserted += 1;
        }
    }
    if inserted != SEEDED_CANDIDATE_COUNT {
        return Err(format!(
            "candidate seed count mismatch: expected {SEEDED_CANDIDATE_COUNT}, found {inserted}"
        ));
    }
    transaction.commit().map_err(|error| error.to_string())?;
    Ok(paths)
}

fn legacy_candidate_path(
    index_path: &Path,
    job: &FullRebuildJob,
    ordinal: usize,
    target_generation: i64,
) -> Result<PathBuf, String> {
    let source_digest = super::super::staging_database_digest(&job.path);
    let contract = Sha256::digest(
        format!(
            "exact-candidate-v2-empty-building-fixture-v1:{}:{}:{}:{}",
            job.source_id, target_generation, ordinal, job.session_id
        )
        .as_bytes(),
    );
    let contract = hex(&contract);
    let mut staging = index_path.as_os_str().to_os_string();
    staging.push(".staging");
    let path =
        PathBuf::from(staging).join(format!("{source_digest}.candidate-v2-{contract}.sqlite3"));
    let spec = route::exact_store_spec(&path)?;
    if spec.module != "exact"
        || !spec.logical_path.starts_with("exact/staging/")
        || spec.logical_path.rsplit('/').next() != path.file_name().and_then(|name| name.to_str())
    {
        return Err("candidate-v2 address did not resolve to the expected Exact namespace".into());
    }
    Ok(path)
}

fn seed_candidate_path(connection: &RawConnection, path: &Path) -> Result<(), String> {
    if !path_is_absent(path)? {
        return Err(format!(
            "refusing existing physical candidate: {}",
            path.display()
        ));
    }
    let spec = route::exact_store_spec(path)?;
    let exists: bool = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1 OR logical_path=?2 OR namespace_prefix=?3)",
            params![spec.id, spec.logical_path, spec.prefix],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if exists {
        return Err(format!(
            "refusing existing candidate namespace: {}",
            spec.logical_path
        ));
    }

    let mut namespace = SQLiteStoreNamespace::new(spec.prefix.clone(), TABLES.map(str::to_owned));
    connection
        .execute(
            "INSERT INTO tb_stores(store_id,module,source_identity,logical_path,namespace_prefix,state) \
             VALUES(?1,?2,?3,?4,?5,'ready')",
            params![spec.id, spec.module, spec.source_identity, spec.logical_path, spec.prefix],
        )
        .map_err(|error| error.to_string())?;
    for (position, statement) in staging_schema_sql(false)
        .split(';')
        .map(str::trim)
        .filter(|statement| !statement.is_empty())
        .enumerate()
    {
        let name = TABLES
            .get(position)
            .ok_or("staging schema contains an unexpected table")?;
        let bound = namespace
            .bind(statement)
            .map_err(|error| format!("candidate table SQL binding failed: {error:?}"))?;
        connection
            .execute_batch(&bound)
            .map_err(|error| format!("cannot create empty candidate table {name}: {error}"))?;
        connection
            .execute(
                "INSERT INTO tb_store_objects(store_id,name,type,original_sql) VALUES(?1,?2,'table',?3)",
                params![spec.id, name, statement],
            )
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn path_is_absent(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(format!(
            "cannot inspect candidate path {}: {error}",
            path.display()
        )),
    }
}

fn raw_metrics(connection: &Connection) -> Result<RawMetrics, String> {
    connection
        .query_row(
            "SELECT COUNT(*),COALESCE(SUM(id),0),COALESCE(SUM(tokens),0),COUNT(DISTINCT timestamp) \
             FROM event_rows",
            [],
            |row| {
                Ok(RawMetrics {
                    rows: row.get(0)?,
                    id_sum: row.get(1)?,
                    token_sum: row.get(2)?,
                    distinct_timestamps: row.get(3)?,
                    sources: 0,
                    accounting_digest: [0; 32],
                })
            },
        )
        .map_err(|error| error.to_string())
        .and_then(|mut metrics| {
            metrics.sources = connection
                .query_row("SELECT COUNT(*) FROM published_files", [], |row| row.get(0))
                .map_err(|error| error.to_string())?;
            let columns = {
                let mut info = connection.prepare("PRAGMA table_info(event_rows)").map_err(|e|e.to_string())?;
                let values = info.query_map([],|row|row.get::<_,String>(1)).map_err(|e|e.to_string())?
                    .collect::<rusqlite::Result<Vec<_>>>().map_err(|e|e.to_string())?;
                values.into_iter().filter(|name|name!="model").collect::<Vec<_>>()
            };
            if columns.is_empty() {return Err("published raw accounting schema missing".into());}
            let mut digest = Sha256::new();
            for name in &columns {digest.update((name.len() as u64).to_be_bytes());digest.update(name.as_bytes());}
            let quoted=columns.iter().map(|name|format!("\"{}\"",name.replace('"',"\"\""))).collect::<Vec<_>>().join(",");
            let mut statement=connection.prepare(&format!("SELECT {quoted} FROM event_rows ORDER BY id")).map_err(|e|e.to_string())?;
            let mut rows=statement.query([]).map_err(|e|e.to_string())?;
            while let Some(row)=rows.next().map_err(|e|e.to_string())? {
                let encoded=super::super::stage_row_codec::encode_row(row).map_err(|e|e.to_string())?;
                digest.update((encoded.len() as u64).to_be_bytes());digest.update(encoded);
            }
            metrics.accounting_digest=digest.finalize().into();
            Ok(metrics)
        })
}

fn assert_raw_metrics(metrics: RawMetrics) -> Result<(), String> {
    if metrics.rows != EVENT_COUNT as i64
        || metrics.id_sum <= 0
        || metrics.token_sum != TOTAL_TOKENS as i64
        || metrics.distinct_timestamps != EVENT_COUNT as i64
        || metrics.sources != SOURCE_COUNT as i64
    {
        return Err(format!(
            "initial published raw row totals mismatch: {metrics:?}"
        ));
    }
    Ok(())
}

fn assert_raw_preserved(before: RawMetrics, after: RawMetrics) -> Result<(), String> {
    if before != after {
        return Err(format!(
            "raw event identity or numeric totals changed: before={before:?}, after={after:?}"
        ));
    }
    assert_raw_metrics(after)
}

fn assert_dashboard(
    stats: &crate::models::DashboardStats,
    sources: usize,
    events: usize,
    tokens: u64,
) -> Result<(), String> {
    if stats.total_tokens != tokens
        || stats.total_calls != events as u32
        || stats.total_threads != sources as u32
    {
        return Err(format!(
            "production dashboard totals mismatch: expected sources={sources}, events={events}, tokens={tokens}; found sources={}, calls={}, tokens={}",
            stats.total_threads, stats.total_calls, stats.total_tokens
        ));
    }
    Ok(())
}

fn candidate_catalog_metrics(index_path: &Path) -> Result<(i64, i64), String> {
    let connection = RawConnection::open_with_flags(
        route::container_path()?,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|error| error.to_string())?;
    let family = route::source_identity("exact", index_path)?;
    let lower = format!("exact/staging/{family}/");
    let upper = format!("exact/staging/{family}0");
    connection
        .query_row(
            "SELECT COUNT(*),(SELECT COUNT(*) FROM tb_store_objects o JOIN tb_stores s USING(store_id) \
             WHERE s.module='exact' AND s.logical_path>=?1 AND s.logical_path<?2) \
             FROM tb_stores WHERE module='exact' AND state='ready' AND logical_path>=?1 AND logical_path<?2",
            params![lower, upper],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|error| error.to_string())
}

fn empty_candidate_table_rows(index_path: &Path) -> Result<i64, String> {
    let connection = RawConnection::open_with_flags(
        route::container_path()?,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|error| error.to_string())?;
    let family = route::source_identity("exact", index_path)?;
    let lower = format!("exact/staging/{family}/");
    let upper = format!("exact/staging/{family}0");
    let prefixes = {
        let mut statement = connection
            .prepare(
                "SELECT namespace_prefix FROM tb_stores WHERE module='exact' AND state='ready' \
                 AND logical_path>=?1 AND logical_path<?2 ORDER BY logical_path",
            )
            .map_err(|error| error.to_string())?;
        let values = statement
            .query_map(params![lower, upper], |row| row.get::<_, String>(0))
            .map_err(|error| error.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())?;
        values
    };
    let mut nonempty = 0_i64;
    for prefix in prefixes {
        if prefix.len() != 66
            || !prefix.starts_with('s')
            || !prefix.ends_with('_')
            || !prefix[1..65]
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err("candidate namespace has an invalid physical prefix".into());
        }
        let sql = format!(
            "SELECT (SELECT COUNT(*) FROM \"{prefix}manifest\") + \
             (SELECT COUNT(*) FROM \"{prefix}fingerprints\") + \
             (SELECT COUNT(*) FROM \"{prefix}events\") + \
             (SELECT COUNT(*) FROM \"{prefix}chunks\")"
        );
        let rows: i64 = connection
            .query_row(&sql, [], |row| row.get(0))
            .map_err(|error| error.to_string())?;
        nonempty += rows;
    }
    Ok(nonempty)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CatalogMetrics {
    main_objects: i64,
    stores: i64,
    store_objects: i64,
}

fn main_catalog_metrics() -> Result<CatalogMetrics, String> {
    let connection = RawConnection::open_with_flags(
        route::container_path()?,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|error| error.to_string())?;
    let main_objects = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    let stores = connection
        .query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    let store_objects = connection
        .query_row("SELECT COUNT(*) FROM tb_store_objects", [], |row| {
            row.get(0)
        })
        .map_err(|error| error.to_string())?;
    Ok(CatalogMetrics {
        main_objects,
        stores,
        store_objects,
    })
}

fn candidate_sealed_or_receipted_count(index_path: &Path) -> Result<i64, String> {
    let connection = RawConnection::open_with_flags(
        route::container_path()?,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|error| error.to_string())?;
    let family = route::source_identity("exact", index_path)?;
    let lower = format!("exact/staging/{family}/");
    let upper = format!("exact/staging/{family}0");
    connection
        .query_row(
            "SELECT COUNT(*) FROM tb_stores s WHERE s.module='exact' AND s.logical_path>=?1 AND s.logical_path<?2 \
             AND (s.state!='ready' OR EXISTS(SELECT 1 FROM tb_store_seals z WHERE z.store_id=s.store_id) \
               OR EXISTS(SELECT 1 FROM tb_store_imports i WHERE i.store_id=s.store_id))",
            params![lower, upper],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn percentile_95(samples: &mut [f64]) -> f64 {
    samples.sort_by(f64::total_cmp);
    let index = samples
        .len()
        .saturating_mul(95)
        .div_ceil(100)
        .saturating_sub(1);
    samples.get(index).copied().unwrap_or_default()
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|error| error.to_string())?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|error| error.to_string())?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex(&digest.finalize()))
}
