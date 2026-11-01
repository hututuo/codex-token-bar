//! Synthetic legacy backfill through production container routing. Bound SQL
//! work with VM-step budgets, rather than machine-dependent time assertions.
use super::super::*;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};

static MAX_RAW_STEPS: AtomicU64 = AtomicU64::new(0);
static MAX_COUNT_STEPS: AtomicU64 = AtomicU64::new(0);
static LEGACY_COUNT_CALLS: AtomicU64 = AtomicU64::new(0);

pub(super) fn record_lookup(kind: &str, statement: &rusqlite::Statement<'_>) -> Result<(), String> {
    let steps = statement.get_status(rusqlite::StatementStatus::VmStep) as u64;
    let maximum = if kind == "raw-location" {
        &MAX_RAW_STEPS
    } else {
        LEGACY_COUNT_CALLS.fetch_add(1, Ordering::Relaxed);
        &MAX_COUNT_STEPS
    };
    maximum.fetch_max(steps, Ordering::Relaxed);
    if steps > 512 {
        return Err(format!(
            "legacy backfill {kind} lookup used {steps} VM steps; indexed lookup budget exceeded"
        ));
    }
    Ok(())
}

pub(super) fn verify(home: &Path) -> Result<serde_json::Value, String> {
    const ROWS: u64 = 4096;
    macro_rules! sql {
        ($value:expr) => {
            $value.map_err(|error| error.to_string())?
        };
    }
    macro_rules! need {
        ($value:expr, $message:expr) => {
            if !$value {
                return Err($message.into());
            }
        };
    }
    sql!(fs::create_dir_all(home.join("sessions")));
    let file = home.join("sessions/legacy-backfill.jsonl");
    need!(
        !file.exists(),
        "legacy performance fixture refuses an existing source"
    );
    let mut data = String::new();
    for i in 0..ROWS {
        let timestamp = sql!(OffsetDateTime::from_unix_timestamp(
            1_793_145_600 + i as i64
        ));
        let timestamp = sql!(timestamp.format(&time::format_description::well_known::Rfc3339));
        data.push_str(
            &json!({"timestamp": timestamp, "type": "event_msg", "payload": {
                "type": "token_count", "info": {"last_token_usage": {
                    "input_tokens":3,"cached_input_tokens":0,"output_tokens":2,"total_tokens":5
                }}
            }})
            .to_string(),
        );
        data.push('\n');
    }
    sql!(fs::write(&file, data));
    let home = sql!(fs::canonicalize(home));
    let expected = ROWS * 5;
    need!(
        super::super::super::dashboard_snapshot(&home)?
            .stats
            .total_tokens
            == expected,
        "legacy performance fixture initial usage mismatch"
    );
    let index_path = database_path(&home)?;
    let mut index = ExactUsageIndex::open(&home)?;
    index.connection.mark_receipt_dirty();
    let source: i64 = sql!(index.connection.query_row(
        "SELECT source_id FROM sources WHERE deleted=0",
        [],
        |row| row.get(0)
    ));
    let before: (i64, i64, i64) = sql!(index.connection.query_row(
        "SELECT COUNT(*),SUM(id),SUM(tokens) FROM event_rows WHERE source_id=?1",
        params![source],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))
    ));
    need!(
        before.0 == ROWS as i64,
        "legacy performance fixture event count mismatch"
    );
    // Reproduce older migrated rows without inventing or deleting consumption.
    sql!(index.connection.execute(
        "UPDATE usage_ledger_bindings SET fingerprint=NULL,raw_offset=NULL WHERE source_id=?1",
        params![source]
    ));
    sql!(index.connection.execute(
        "UPDATE event_rows SET token_source_offset=NULL WHERE source_id=?1",
        params![source]
    ));
    set_metadata(
        &index.connection,
        EVENT_ENRICHMENT_REVISION_KEY,
        PRE_COMPACTION_EVENT_ENRICHMENT_REVISION,
    )?;
    MAX_RAW_STEPS.store(0, Ordering::Relaxed);
    MAX_COUNT_STEPS.store(0, Ordering::Relaxed);
    LEGACY_COUNT_CALLS.store(0, Ordering::Relaxed);
    let started = std::time::Instant::now();
    index.synchronize_event_enrichment(&home, &index_path, &mut Vec::new(), ExactSyncMode::Full)?;
    let elapsed = started.elapsed().as_millis();
    let after: (i64, i64, i64) = sql!(index.connection.query_row(
        "SELECT COUNT(*),SUM(id),SUM(tokens) FROM event_rows WHERE source_id=?1",
        params![source],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))
    ));
    need!(
        after == before,
        "legacy backfill changed event identities or numeric usage"
    );
    need!(
        LEGACY_COUNT_CALLS.load(Ordering::Relaxed) >= ROWS,
        "fixture did not exercise every legacy uniqueness lookup"
    );
    let unbound: i64 = sql!(index.connection.query_row(
        "SELECT COUNT(*) FROM usage_ledger_bindings WHERE source_id=?1 AND (fingerprint IS NULL OR raw_offset IS NULL)",
        params![source], |row| row.get(0)));
    need!(
        unbound == 0,
        "legacy backfill did not restore verified raw bindings"
    );
    index.sync(&home, &mut Vec::new())?;
    need!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)?
            .total_tokens
            == expected,
        "legacy backfill replay lost or double-counted usage"
    );
    Ok(
        json!({"name":"legacy-backfill-indexed-reconciliation","status":"PASS",
        "legacyRows":ROWS,"tokensAfterReplay":expected,"preservedEventIds":true,
        "legacyCountCalls":LEGACY_COUNT_CALLS.load(Ordering::Relaxed),
        "rawLookupMaxVmSteps":MAX_RAW_STEPS.load(Ordering::Relaxed),
        "identityCountMaxVmSteps":MAX_COUNT_STEPS.load(Ordering::Relaxed),
        "backfillElapsedMs":elapsed}),
    )
}
