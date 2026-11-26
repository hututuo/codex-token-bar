//! Cloud-only injection into the actual production module in both revisions.
//! No extracted implementation, substitute aggregate, or private input is used.
use super::*;
use std::ffi::{c_void, CStr};
use std::time::Instant as Clock;

const PREFIX: &str = "MULTI_CLIENT_AGGREGATE_BENCHMARK ";

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Witness {
    statements: u64,
    profiles: u64,
    canonical_statements: u64,
    staging_creates: u64,
    staged_reads: u64,
    vm_steps: u64,
}

unsafe extern "C" fn trace(
    kind: u32,
    context: *mut c_void,
    statement: *mut c_void,
    _: *mut c_void,
) -> i32 {
    // SQLite owns the statement. The boxed counter outlives trace registration;
    // the test uses one connection on one thread and never panics in this FFI.
    let witness = &mut *(context as *mut Witness);
    let statement = statement as *mut rusqlite::ffi::sqlite3_stmt;
    if kind == rusqlite::ffi::SQLITE_TRACE_STMT as u32 {
        witness.statements += 1;
        let sql = rusqlite::ffi::sqlite3_sql(statement);
        if !sql.is_null() {
            let bytes = CStr::from_ptr(sql).to_bytes();
            let contains = |needle: &[u8]| bytes.windows(needle.len()).any(|part| part == needle);
            witness.canonical_statements +=
                u64::from(contains(b"client_usage_observations AS MATERIALIZED"));
            witness.staging_creates +=
                u64::from(contains(b"CREATE TEMP TABLE ctb_aggregate_usage AS"));
            witness.staged_reads += u64::from(contains(b"FROM temp.ctb_aggregate_usage"));
        }
    } else if kind == rusqlite::ffi::SQLITE_TRACE_PROFILE as u32 {
        witness.profiles += 1;
        witness.vm_steps += rusqlite::ffi::sqlite3_stmt_status(
            statement,
            rusqlite::ffi::SQLITE_STMTSTATUS_VM_STEP,
            0,
        )
        .max(0) as u64;
    }
    0
}

fn output(read: MultiClientAggregateRead) -> Value {
    serde_json::json!({
        "summaries": read.arrays.summaries,
        "todaySummaries": read.arrays.today_summaries,
        "sevenDaySummaries": read.arrays.seven_day_summaries,
        "trendBuckets": read.arrays.trend_buckets,
        "dailyBuckets": read.arrays.daily_buckets,
        "updatedAt": read.updated_at,
    })
}

fn clear_caches(cache: &Mutex<MultiClientAggregateCache>) {
    *cache.lock().unwrap() = Default::default();
    *MULTI_CLIENT_PRICE_CACHE
        .get_or_init(Default::default)
        .lock()
        .unwrap() = Default::default();
    *MULTI_CLIENT_SCOPED_SUMMARY_CACHE
        .get_or_init(Default::default)
        .lock()
        .unwrap() = Default::default();
}

#[cfg(unix)]
fn usage() -> (f64, f64, i64) {
    unsafe {
        let mut value: libc::rusage = std::mem::zeroed();
        assert_eq!(libc::getrusage(libc::RUSAGE_SELF, &mut value), 0);
        let milliseconds =
            |time: libc::timeval| time.tv_sec as f64 * 1_000.0 + time.tv_usec as f64 / 1_000.0;
        let peak = value.ru_maxrss as i64;
        #[cfg(target_os = "macos")]
        let bytes = peak;
        #[cfg(not(target_os = "macos"))]
        let bytes = peak * 1_024;
        (
            milliseconds(value.ru_utime),
            milliseconds(value.ru_stime),
            bytes,
        )
    }
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("missing {name}"))
}
fn number(name: &str) -> usize {
    env(name).parse().unwrap()
}

#[test]
#[cfg(unix)]
fn production_aggregate_pair() {
    assert_eq!(
        env("GITHUB_ACTIONS"),
        "true",
        "native benchmark is cloud-only"
    );
    assert_eq!(env("TZ"), "UTC");
    assert_eq!(env("CTB_AGGREGATE_SYNTHETIC"), "schema2-v1");
    let path = PathBuf::from(env("CTB_AGGREGATE_DATABASE"));
    let source = env("CTB_AGGREGATE_SOURCE");
    let phase = env("CTB_AGGREGATE_PHASE");
    assert!(phase == "cold" || phase == "cache-hit");
    let iterations = number("CTB_AGGREGATE_ITERATIONS");
    assert!((1..=1_000).contains(&iterations));
    let now: i64 = env("CTB_AGGREGATE_NOW").parse().unwrap();
    assert_eq!(
        crate::core::localtime::local_offset_at(now).whole_seconds(),
        0
    );
    let before_fixture = usage().2;
    let connection = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        2
    );
    let physical_rows: i64 = connection
        .query_row("SELECT COUNT(*) FROM client_usage_events", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        physical_rows as usize,
        number("CTB_AGGREGATE_PHYSICAL_ROWS")
    );
    let fixture_bytes = std::fs::read(&path).unwrap();
    let fixture_sha = hex_digest(&fixture_bytes);
    assert_eq!(fixture_sha, env("CTB_AGGREGATE_DATABASE_SHA256"));
    drop(fixture_bytes);
    let cache = Mutex::new(MultiClientAggregateCache::default());
    clear_caches(&cache);
    // Prime bundled price parsing outside both phases. Application aggregate,
    // scoped and price-tally caches are then reset for every cold iteration.
    let _ = bundled_api_price_catalog();
    let expected =
        output(read_cached_multi_client_aggregates(&connection, &path, now, &cache).unwrap());
    assert!(!expected["summaries"].as_array().unwrap().is_empty());
    if phase == "cold" {
        clear_caches(&cache);
    }
    let hits_before = cache.lock().unwrap().hits;
    let before_loop = usage().2;
    let mut wall = 0.0;
    let mut user = 0.0;
    let mut system = 0.0;
    let mut checksums = Vec::new();
    for _ in 0..iterations {
        if phase == "cold" {
            clear_caches(&cache);
        }
        let start_cpu = usage();
        let start = Clock::now();
        let read = read_cached_multi_client_aggregates(&connection, &path, now, &cache).unwrap();
        wall += start.elapsed().as_secs_f64() * 1_000.0;
        let end_cpu = usage();
        user += end_cpu.0 - start_cpu.0;
        system += end_cpu.1 - start_cpu.1;
        // Full serialization, exact comparison, hashing and destruction of
        // the result are deliberately outside the production-call timer.
        let value = output(read);
        assert_eq!(
            expected, value,
            "repeat changed complete aggregate semantics"
        );
        checksums.push(hex_digest(
            serde_json::to_string(&value).unwrap().as_bytes(),
        ));
    }
    let after_loop = usage().2;
    let hits_after = cache.lock().unwrap().hits;
    let hit_delta = hits_after - hits_before;
    assert_eq!(
        hit_delta,
        if phase == "cache-hit" {
            iterations as u64
        } else {
            0
        }
    );

    // A separate, untimed execution witness avoids inflating baseline timings
    // merely because it executes more statements than the staged candidate.
    if phase == "cold" {
        clear_caches(&cache);
    }
    let mut witness = Box::<Witness>::default();
    unsafe {
        assert_eq!(
            rusqlite::ffi::sqlite3_trace_v2(
                connection.handle(),
                (rusqlite::ffi::SQLITE_TRACE_STMT | rusqlite::ffi::SQLITE_TRACE_PROFILE) as u32,
                Some(trace),
                (&mut *witness as *mut Witness).cast()
            ),
            rusqlite::ffi::SQLITE_OK
        );
    }
    let witnessed = read_cached_multi_client_aggregates(&connection, &path, now, &cache);
    unsafe {
        assert_eq!(
            rusqlite::ffi::sqlite3_trace_v2(connection.handle(), 0, None, std::ptr::null_mut()),
            rusqlite::ffi::SQLITE_OK
        );
    }
    assert_eq!(expected, output(witnessed.unwrap()));
    assert!(witness.profiles > 0 && witness.vm_steps > 0);

    // A real revision-key invalidation must observe a controlled data change.
    // Only this process's disposable synthetic copy is writable.
    let mut writer = Connection::open(&path).unwrap();
    let transaction = writer.transaction().unwrap();
    assert_eq!(transaction.execute("UPDATE client_usage_events SET output_tokens=output_tokens+77,payload=json_set(payload,'$.outputTokens',output_tokens+77) WHERE client='deepseek' AND event_id='synthetic-2'", []).unwrap(), 1);
    transaction.execute("INSERT INTO client_usage_revisions(client,event_id,captured_at,payload) SELECT client,event_id,?1,payload FROM client_usage_events WHERE client='deepseek' AND event_id='synthetic-2'", [now as f64]).unwrap();
    transaction
        .execute(
            "UPDATE multi_usage_metadata SET value=?1 WHERE key='updated_at_ms'",
            [(now * 1_000 + 1).to_string()],
        )
        .unwrap();
    transaction.commit().unwrap();
    drop(writer);
    let changed =
        output(read_cached_multi_client_aggregates(&connection, &path, now, &cache).unwrap());
    assert_ne!(
        expected, changed,
        "aggregate ignored the controlled revision"
    );
    let total_output = |value: &Value| {
        value["summaries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["outputTokens"].as_u64().unwrap())
            .sum::<u64>()
    };
    assert_eq!(total_output(&changed), total_output(&expected) + 77);
    // Keep original full semantics and mutation semantics; no fields are
    // deleted, rounded, or normalized to make a pair agree.
    let output_json = serde_json::to_string(&expected).unwrap();
    let record = serde_json::json!({
        "schemaVersion": 1, "source": source, "trial": number("CTB_AGGREGATE_TRIAL"),
        "fixtureSha256": hex_digest(include_bytes!("multi_client_aggregate_benchmark.rs")),
        "productionSourceSha256": hex_digest(include_bytes!("multi_client_usage.rs")),
        "sqlSha256": hex_digest(EFFECTIVE_USAGE_EVENTS_SQL.as_bytes()),
        "pricesSha256": hex_digest(BUNDLED_PRICE_TABLE.as_bytes()),
        "logicalRows": number("CTB_AGGREGATE_LOGICAL_ROWS"), "physicalRows": physical_rows,
        "databaseSha256": fixture_sha, "phase": phase, "iterations": iterations,
        "productionEntryPoint": "read_cached_multi_client_aggregates",
        "cacheHitDelta": hit_delta, "checksums": checksums, "witness": witness,
        "measurement": {"wallMilliseconds": wall, "userMilliseconds": user,
            "systemMilliseconds": system, "cpuMilliseconds": user + system,
            "processPeakRSSBytesBeforeFixture": before_fixture,
            "processPeakRSSBytesBeforeLoop": before_loop,
            "processPeakRSSBytesAfterLoop": after_loop},
        "outputJSON": output_json,
        "output": expected, "afterMutation": changed,
    });
    println!("{PREFIX}{}", serde_json::to_string(&record).unwrap());
}
