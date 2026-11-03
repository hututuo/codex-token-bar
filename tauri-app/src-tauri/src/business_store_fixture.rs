//! Offline production-path exercise for business container A and ledger B.
//! Built only with `business-store-fixture`; all required path overrides must
//! resolve inside the caller's disposable root. This code never changes env.

use crate::core::{
    app_paths, business_store_connection::StoreConnection,
    business_store_container::StoreSpec, business_store_route as route, live_rate, modeltrace, quota_history,
    usage::token_count_jsonl,
};
use crate::models::SpeedSample;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const ENV: [&str; 5] = [
    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
    "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR",
    "CODEX_TOKEN_BAR_CACHE_BASE_DIR",
    "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR",
];

const CONCURRENT_PROBE_MODULE: &str = "fixture_concurrent";
const CONCURRENT_PROBE_IDENTITY: &str = "fixture";
const CONCURRENT_PROBE_LOGICAL_PATH: &str = "fixture/concurrent";
const CONCURRENT_PROBE_TIMEOUT: Duration = Duration::from_millis(250);

struct ConcurrentAWriteProbe {
    path: PathBuf,
    store_id: String,
    connection: StoreConnection,
}

fn concurrent_a_write_probe_slot() -> &'static Mutex<Option<ConcurrentAWriteProbe>> {
    static PROBE: OnceLock<Mutex<Option<ConcurrentAWriteProbe>>> = OnceLock::new();
    PROBE.get_or_init(|| Mutex::new(None))
}

/// Prepare one registered fixture namespace before any parser workers start.
/// The persistent test connection is deliberately independent of parser TEMP
/// connections; worker callbacks only INSERT and never register or run DDL.
fn prepare_concurrent_a_write_probe(path: &Path) -> Result<(), String> {
    let mut slot = concurrent_a_write_probe_slot()
        .lock()
        .map_err(|_| "concurrent A write probe mutex poisoned".to_string())?;
    if let Some(probe) = slot.as_ref() {
        if probe.path.as_path() != path {
            return Err("concurrent A write probe is bound to another fixture root".into());
        }
        return Ok(());
    }

    let store = StoreSpec::new(
        CONCURRENT_PROBE_MODULE,
        CONCURRENT_PROBE_IDENTITY,
        CONCURRENT_PROBE_LOGICAL_PATH,
    )
    .map_err(|error| error.to_string())?;
    let connection = route::open_store(
        CONCURRENT_PROBE_MODULE,
        CONCURRENT_PROBE_IDENTITY,
        CONCURRENT_PROBE_LOGICAL_PATH,
        &[],
    )
    .map_err(|error| format!("prepare fixture A write probe namespace: {error}"))?;
    connection
        .busy_timeout(CONCURRENT_PROBE_TIMEOUT)
        .map_err(|error| format!("configure fixture A write probe timeout: {error}"))?;
    connection
        .execute_batch("CREATE TABLE observations(id INTEGER PRIMARY KEY AUTOINCREMENT);")
        .map_err(|error| format!("prepare fixture A write probe table: {error}"))?;
    *slot = Some(ConcurrentAWriteProbe {
        path: path.to_path_buf(),
        store_id: store.id,
        connection,
    });
    Ok(())
}

fn concurrent_a_write_probe_attempt(
) -> Result<(), (Option<rusqlite::ErrorCode>, String)> {
    let slot = concurrent_a_write_probe_slot()
        .lock()
        .map_err(|_| (None, "probe mutex poisoned".to_string()))?;
    let probe = slot
        .as_ref()
        .ok_or_else(|| (None, "probe was not prepared before parser workers".to_string()))?;
    probe
        .connection
        .execute("INSERT INTO observations DEFAULT VALUES", [])
        .map(|_| ())
        .map_err(|error| (error.sqlite_error_code(), error.to_string()))
}

// Called from the parser hook, which is also compiled into standalone release
// probes. Those probes do not opt into this fixture assertion; run_fixture
// explicitly prepares it before any parser workers start.
pub(crate) fn assert_concurrent_a_write() -> Result<(), String> {
    let enabled = concurrent_a_write_probe_slot()
        .lock()
        .map_err(|_| "concurrent A write probe mutex poisoned".to_string())?
        .is_some();
    if !enabled {
        return Ok(());
    }
    concurrent_a_write_probe_attempt().map_err(|(code, error)| {
        format!(
            "fixture concurrent A write probe failed during existing-table INSERT (SQLite {code:?}): {error}"
        )
    })
}

fn concurrent_probe_counts(path: &Path) -> Result<(i64, i64, i64), String> {
    let slot = concurrent_a_write_probe_slot()
        .lock()
        .map_err(|_| "concurrent A write probe mutex poisoned".to_string())?;
    let probe = slot
        .as_ref()
        .ok_or("concurrent A write probe was not prepared")?;
    if probe.path.as_path() != path {
        return Err("concurrent A write probe is bound to another fixture root".into());
    }
    let database = Connection::open(path).map_err(|error| error.to_string())?;
    let stores = database
        .query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    let objects = database
        .query_row(
            "SELECT COUNT(*) FROM tb_store_objects WHERE store_id=?1",
            [&probe.store_id],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    let observations = probe
        .connection
        .query_row("SELECT COUNT(*) FROM observations", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    Ok((stores, objects, observations))
}

fn concurrent_a_write_probe_fixture(path: &Path) -> Result<Value, String> {
    prepare_concurrent_a_write_probe(path)?;

    // A blocked write is a real negative control: the same independent probe
    // connection must report SQLite's lock error while another connection
    // holds A, then succeed as soon as the writer rolls back.
    assert_concurrent_a_write()?;
    let before_blocked = concurrent_probe_counts(path)?;
    let blocker = Connection::open(path).map_err(|error| error.to_string())?;
    blocker
        .busy_timeout(CONCURRENT_PROBE_TIMEOUT)
        .map_err(|error| error.to_string())?;
    blocker
        .execute_batch("BEGIN IMMEDIATE")
        .map_err(|error| format!("negative-control A writer could not acquire lock: {error}"))?;
    let blocked = concurrent_a_write_probe_attempt();
    let rollback = blocker.execute_batch("ROLLBACK");
    drop(blocker);
    rollback.map_err(|error| format!("negative-control A writer rollback failed: {error}"))?;
    let (blocked_code, blocked_message) = blocked
        .err()
        .ok_or("concurrent A write probe unexpectedly succeeded under BEGIN IMMEDIATE")?;
    if !matches!(
        blocked_code,
        Some(rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked)
    ) {
        return Err(format!(
            "negative control returned unexpected SQLite code {blocked_code:?}: {blocked_message}"
        ));
    }
    assert_concurrent_a_write()?;
    let after_rollback = concurrent_probe_counts(path)?;
    if after_rollback.2 != before_blocked.2 + 1 {
        return Err("probe did not resume writing after negative-control rollback".into());
    }

    let before_parallel = concurrent_probe_counts(path)?;
    let parallel_results = std::thread::scope(|scope| {
        let workers = (0..4)
            .map(|_| scope.spawn(concurrent_a_write_probe_attempt))
            .collect::<Vec<_>>();
        workers
            .into_iter()
            .map(|worker| {
                worker
                    .join()
                    .map_err(|_| "concurrent probe worker panicked".to_string())?
                    .map_err(|(code, error)| {
                        format!("parallel existing-table INSERT failed (SQLite {code:?}): {error}")
                    })
            })
            .collect::<Result<Vec<_>, String>>()
    });
    parallel_results?;
    let after_parallel = concurrent_probe_counts(path)?;
    if before_parallel.0 != after_parallel.0 || before_parallel.1 != after_parallel.1 {
        return Err("parallel probes changed the A catalog or repeated namespace DDL".into());
    }
    if after_parallel.2 != before_parallel.2 + 4 {
        return Err("parallel probes did not all leave an observations row".into());
    }
    Ok(json!({
        "name":"concurrent-a-write-probe",
        "status":"PASS",
        "timeoutMilliseconds":CONCURRENT_PROBE_TIMEOUT.as_millis(),
        "serializedProbeConnection":true,
        "negativeControl":{
            "heldByBeginImmediate":true,
            "sqliteCode":format!("{blocked_code:?}"),
            "writeResumedAfterRollback":true,
        },
        "parallelProbeRows":4,
        "catalogStable":true,
    }))
}

fn close_concurrent_a_write_probe(path: &Path) -> Result<(), String> {
    let mut slot = concurrent_a_write_probe_slot()
        .lock()
        .map_err(|_| "concurrent A write probe mutex poisoned".to_string())?;
    if let Some(probe) = slot.as_ref() {
        if probe.path.as_path() != path {
            return Err("concurrent A write probe is bound to another fixture root".into());
        }
    }
    slot.take();
    Ok(())
}
macro_rules! ok {
    ($e:expr) => {
        $e.map_err(|e| e.to_string())?
    };
}
macro_rules! need {
    ($c:expr, $m:expr) => {
        if !$c {
            return Err($m.into());
        }
    };
}

pub fn run_fixture(input: &Path) -> Result<Value, String> {
    let root = validate_root(input)?;
    let p = Paths::resolve(&root)?;
    for file in [
        &p.a,
        &p.marker,
        &p.b,
        &p.quota,
        &p.shared_quota,
        &p.modeltrace,
    ] {
        need!(
            !file.exists(),
            format!("refusing existing fixture DB: {}", file.display())
        );
    }
    for dir in [&p.exact_root, &p.old_exact_root] {
        if dir.exists() {
            need!(
                fs::read_dir(dir)
                    .map_err(|e| e.to_string())?
                    .next()
                    .is_none(),
                format!("refusing non-empty exact directory: {}", dir.display())
            );
        }
    }
    let now = now();
    let h1 = root.join("codex-home-one");
    let h2 = root.join("codex-home-two");
    for h in [&h1, &h2] {
        ok!(fs::create_dir_all(h.join("sessions")));
    }
    let h1 = ok!(fs::canonicalize(h1));
    let h2 = ok!(fs::canonicalize(h2));
    need!(
        p.quota != p.shared_quota,
        "fixture requires distinct legacy quota paths"
    );
    seed_quota(&p.quota, &h1, now - 1200.0, false)?;
    seed_quota(&p.shared_quota, &h1, now - 900.0, true)?;
    seed_modeltrace(&p.modeltrace)?;
    let scope = live_rate::LiveRateSourceScope::new(
        h1.to_string_lossy().into_owned(),
        h1.to_string_lossy().into_owned(),
    );
    let body = body_path(&scope, &p.performance)?;
    need!(
        !body.exists(),
        format!("refusing existing BodySpeed DB: {}", body.display())
    );
    let old_sample = sample("fixture-legacy-body", now - 45.0, 48, 4.0);
    seed_body(&body, &old_sample)?;
    let sources = [&p.quota, &p.shared_quota, &p.modeltrace, &body];
    let digests = sources
        .iter()
        .map(|f| Ok((f.to_path_buf(), digest(f)?)))
        .collect::<Result<Vec<_>, String>>()?;

    let startup = crate::core::business_startup::process_coordinator();
    need!(startup.begin_initial(), "fixture startup already claimed");
    need!(
        route::open_registered_store_read_only(
            "fixture_readonly", "fixture", "fixture/public-read-only",
            std::time::Duration::from_millis(25),
        ).is_err() && !p.a.exists(),
        "public read-only route bypassed startup readiness or created A"
    );
    let prepared = route::bootstrap();
    startup.finish(prepared.clone());
    prepared?;
    need!(
        p.a.is_file() && p.marker.is_file() && p.a != p.b,
        "bootstrap did not initialize distinct A and B"
    );
    let mut checks = vec![json!({"name":"bootstrap","status":"PASS"})];
    checks.push(concurrent_a_write_probe_fixture(&p.a)?);
    let observations_before_exact = concurrent_probe_counts(&p.a)?.2;
    checks.push(public_read_only_fixture(&p)?);

    let qi = quota_history::QuotaHistoryIdentity::from_canonical_parts(
        &h1,
        Some("sub:fixture-account"),
        "pro",
        "codex",
    )
    .ok_or("quota fixture identity rejected")?;
    let bundle = quota_bundle(now);
    quota_history::record_bundle(&qi, &bundle)?;
    let history = quota_history::history_bundle_for(&qi, &bundle, 30, true)?;
    let id = route::source_identity("quota_history", &h1)?;
    let a = route::open_store(
        "quota_history",
        &id,
        &format!("quota-history/home/{id}"),
        &[],
    )?;
    let active: i64 = ok!(a.query_row("SELECT COUNT(*) FROM quota_snapshots", [], |r| r.get(0)));
    drop(a);
    let imported = sources[..2]
        .iter()
        .map(|f| quota_facts(f))
        .collect::<Result<Vec<_>, _>>()?;
    need!(
        active > 0 && imported == [1, 2],
        "quota legacy typed facts or active write missing"
    );
    quota_history::verify_legacy_runtime_fixture(&qi)?;
    checks.push(json!({"name":"quota","status":"PASS","activeRows":active,"legacyFacts":imported,"historyPoints":history.recent_7d.len()}));

    let mid = route::source_identity("modeltrace", &h1)?;
    let scope = "fixture:modeltrace-scope";
    let old = modeltrace::store::history(&p.modeltrace, &mid, scope)?;
    need!(
        old.iter().any(|r| r.id == "fixture-legacy-modeltrace-run"),
        "legacy ModelTrace run missing"
    );
    let run = run("fixture-active-modeltrace-run", now as i64);
    modeltrace::store::save(&p.modeltrace, &mid, scope, &run)?;
    let runs = modeltrace::store::history(&p.modeltrace, &mid, scope)?;
    need!(
        runs.iter().any(|r| r.id == "fixture-legacy-modeltrace-run")
            && runs.iter().any(|r| r.id == "fixture-active-modeltrace-run"),
        "ModelTrace legacy or active row missing"
    );
    checks.push(json!({"name":"modeltrace","status":"PASS","runs":runs.len()}));

    let store = live_rate::BodySpeedTrendStore::open(&body).map_err(|e| e.to_string())?;
    need!(
        store
            .read_samples(now, 30)
            .map_err(|e| e.to_string())?
            .iter()
            .any(|s| s.id == old_sample.id),
        "legacy BodySpeed sample missing"
    );
    let new_sample = sample("fixture-active-body", now - 15.0, 72, 6.0);
    need!(
        store
            .ingest(std::slice::from_ref(&new_sample), now, 30)
            .map_err(|e| e.to_string())?
            == 1,
        "BodySpeed active write missing"
    );
    let samples = store.read_samples(now, 30).map_err(|e| e.to_string())?;
    let trend = store.read(now, 1).map_err(|e| e.to_string())?;
    need!(
        samples.iter().any(|s| s.id == old_sample.id)
            && samples.iter().any(|s| s.id == new_sample.id)
            && trend.iter().map(|p| p.sample_count).sum::<i64>() >= 2,
        "BodySpeed detail or weighted trend missing"
    );
    checks.push(json!({"name":"body-speed","status":"PASS","samples":samples.len(),"trendPoints":trend.len()}));
    // The later missing-container check renames A. Windows must not still
    // have the BodySpeed connection open when that check parks the file.
    drop(store);

    let b = crate::core::multi_client_usage::open_activity_module_connection()?;
    ok!(b.execute("INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES(?1,?2,'model','fixture','1','output','codex','gpt-6.1-sol',?3,?4,12,10,120)", params!["fixture-b", "fixture-b-activity", now - 10.0, now]));
    let b_rows: i64 = ok!(b.query_row(
        "SELECT COUNT(*) FROM activity_speed_samples WHERE id='fixture-b-activity'",
        [],
        |r| r.get(0)
    ));
    need!(b_rows == 1, "B activity write missing");
    checks.push(json!({"name":"ledger-b","status":"PASS","rows":b_rows}));
    drop(b);

    checks.push(exact_fixture(&h1, &h2, &p)?);
    let observations_after_exact = concurrent_probe_counts(&p.a)?.2;
    let exact_probe_writes = observations_after_exact.saturating_sub(observations_before_exact);
    need!(
        exact_probe_writes > 0,
        "Exact scans did not invoke the explicitly enabled concurrent A write probe"
    );
    checks.push(json!({
        "name":"exact-concurrent-a-write-observed",
        "status":"PASS",
        "probeWrites":exact_probe_writes,
    }));
    checks.push(token_count_jsonl::verify_runtime_recovery_fixture(&root.join("runtime-home"))?);
    checks.push(token_count_jsonl::verify_backfill_performance_fixture(&root.join("legacy-backfill-home"))?);
    checks.push(pool_process_crash_fixture(&root)?);
    if std::env::var("TOKENBAR_NATIVE_SCALE").as_deref() == Ok("1") {
        checks.push(token_count_jsonl::verify_native_scale_fixture(&root.join("native-scale-home"))?);
    }
    checks.push(published_recovery_read_fixture(&h1, &p)?);
    for (f, before) in &digests {
        need!(
            digest(f)? == *before,
            format!("legacy source changed: {}", f.display())
        );
    }
    checks.push(json!({"name":"legacy-source-preservation","status":"PASS","count":digests.len()}));
    let count = store_count(&p.a)?;
    route::bootstrap()?;
    need!(
        store_count(&p.a)? == count,
        "bootstrap rerun changed A store catalog"
    );
    close_concurrent_a_write_probe(&p.a)?;
    park_a_and_test(&p)?;
    checks.push(json!({"name":"rerun-and-fail-closed","status":"PASS","storeCount":count}));
    Ok(json!({"status":"PASS","root":root,"containerA":p.a,"clientB":p.b,"checks":checks}))
}

pub fn run_pool_crash_probe(input: &Path, point: &str, resume: bool) -> Result<Value,String> {
    let root=validate_root(input)?;
    let p=Paths::resolve(&root)?;
    need!(fs::read(root.join(".tokenbar-pool-crash-fixture")).map_err(|e|e.to_string())?==b"tokenbar-pool-crash-fixture-v1\n", "unowned crash root");
    if !resume {need!(!p.a.exists(),"crash producer refuses an existing A");}
    else {need!(p.a.is_file(),"crash resume refuses a missing A");}
    let startup=crate::core::business_startup::process_coordinator();
    need!(startup.begin_initial(),"crash process already has a startup owner");
    let result=route::bootstrap();startup.finish(result.clone());result?;
    let mut report=token_count_jsonl::run_pool_crash_step(&root,point,resume)?;
    for _ in 0..3 {route::bootstrap()?;}
    report["repeatedStartupChecks"]=json!(3);
    Ok(report)
}

fn pool_process_crash_fixture(root:&Path) -> Result<Value,String> {
    let phases=["initialize-before-commit","chunk-committed","seal-before-commit","seal-committed",
        "publication-before-commit","publication-committed","cleanup-before-commit","cleanup-committed"];
    let mut reports=Vec::new();
    for phase in phases {
        let case=root.join(format!("pool-crash-{}",uuid::Uuid::new_v4()));
        fs::create_dir(&case).map_err(|e|e.to_string())?;
        fs::write(case.join(".tokenbar-pool-crash-fixture"),b"tokenbar-pool-crash-fixture-v1\n").map_err(|e|e.to_string())?;
        let case=fs::canonicalize(case).map_err(|e|e.to_string())?;
        run_pool_process(&case,phase,false,0)?;
        let mut reopens=Vec::new();
        for attempt in 0..3 {reopens.push(run_pool_process(&case,phase,true,attempt)?);}
        reports.push(json!({"phase":phase,"forcedExit":86,"resumes":reopens}));
    }
    Ok(json!({"name":"pool-process-crash-recovery","status":"PASS","phases":reports,
        "scope":"actual production storage bootstrap, fixed pool and same-A publication bridge; disposable numeric fixtures; not UI/parser acceptance"}))
}

fn run_pool_process(root:&Path, point:&str, resume:bool, attempt:usize) -> Result<Value,String> {
    use std::process::{Command,Stdio};
    use std::time::{Duration,Instant};
    let mode=if resume{"--pool-crash-resume"}else{"--pool-crash-child"};
    let output=root.join(format!("{}-{attempt}.log",if resume{"resume"}else{"crash"}));
    let log=fs::OpenOptions::new().write(true).create_new(true).open(&output).map_err(|e|e.to_string())?;
    let error_path=output.with_extension("stderr.log");
    let error_log=fs::OpenOptions::new().write(true).create_new(true).open(&error_path).map_err(|e|e.to_string())?;
    let mut command=Command::new(std::env::current_exe().map_err(|e|e.to_string())?);
    command.arg(root).arg(mode).arg(point).env_clear()
        .stdout(Stdio::from(log)).stderr(Stdio::from(error_log));
    for (key,value) in std::env::vars_os() {
        if ["PATH","HOME","USERPROFILE","APPDATA","LOCALAPPDATA","TMPDIR","TEMP","TMP","SystemRoot","SYSTEMROOT","WINDIR","LD_LIBRARY_PATH","DYLD_LIBRARY_PATH","DYLD_FRAMEWORK_PATH","GITHUB_ACTIONS","RUNNER_TEMP"].iter().any(|allowed|key==*allowed) {
            command.env(key,value);
        }
    }
    for (key,folder) in ENV.iter().zip(["tauri-support","tauri-cache","shared-support","shared-cache","legacy-usage"]) {command.env(key,root.join(folder));}
    if !resume {command.env("TOKENBAR_POOL_CRASH_ROOT",root).env("TOKENBAR_POOL_CRASH_POINT",point);}
    let mut child=command.spawn().map_err(|e|e.to_string())?;
    let started=Instant::now();
    let status=loop {
        if let Some(status)=child.try_wait().map_err(|e|e.to_string())? {break status;}
        if started.elapsed()>Duration::from_secs(60) {let _=child.kill();let _=child.wait();return Err(format!("own pool crash process timed out: {point}"));}
        std::thread::sleep(Duration::from_millis(20));
    };
    let text=fs::read_to_string(&output).map_err(|e|e.to_string())?;
    let errors=fs::read_to_string(&error_path).map_err(|e|e.to_string())?;
    if !resume {
        need!(status.code()==Some(86),format!("fault was not reached {point}: {text} {errors}"));
        return Ok(json!({"forcedExit":86}));
    }
    need!(status.success(),format!("pool recovery failed {point}: {text} {errors}"));
    let value:Value=serde_json::from_str(&text).map_err(|e|format!("pool recovery report: {e}: {text}"))?;
    need!(value["status"]=="PASS" && value["publishedTokens"]==134 && value["publicationReceipts"]==1,"pool recovery report did not prove preserved accounting");
    Ok(value)
}

fn published_recovery_read_fixture(home: &Path, paths: &Paths) -> Result<Value, String> {
    let original = token_count_jsonl::dashboard_snapshot(home)?;
    let original_catalog = token_count_jsonl::session_catalog_snapshot(home, |line| {
        Ok(token_count_jsonl::IndexedSessionMetadata {
            thread_id: format!("published-fixture-{:x}", Sha256::digest(line)),
            cwd: "/fixture".into(), source: "cli".into(), session_id: None,
            forked_from_id: None, parent_thread_id: None,
        })
    })?;
    need!(!original_catalog.entries.is_empty(), "published catalog fixture did not seed any metadata");
    let published = route::open_store("fixture_readable", "fixture", "fixture/readable", &[])?;
    published.execute_batch("CREATE TABLE facts(id INTEGER PRIMARY KEY,amount INTEGER); INSERT INTO facts VALUES(1,123),(2,789)").map_err(|error| error.to_string())?;
    drop(published);
    let pending = route::open_store("fixture_pending", "fixture", "fixture/pending", &[])?;
    pending.execute_batch("CREATE TABLE facts(id INTEGER PRIMARY KEY,amount INTEGER); INSERT INTO facts VALUES(1,456)").map_err(|error| error.to_string())?;
    drop(pending);
    let pending = crate::core::business_store_container::StoreSpec::new("fixture_pending", "fixture", "fixture/pending").map_err(|error| error.to_string())?;
    let raw = Connection::open(&paths.a).map_err(|error| error.to_string())?;
    let key = format!("migration_pending_store_v1:{}", pending.id);
    raw.execute("INSERT INTO tb_container_meta VALUES(?1,?2)", params![key, json!({"version":2,"sources":[],"snapshots":[],"bootstrap":false,"replace_uncommitted":false}).to_string()]).map_err(|error| error.to_string())?;
    drop(raw);
    let before = crate::core::business_store_container::Container::snapshot_digest_path(&paths.a).map_err(|error| error.to_string())?;
    route::admit_published_reads()?;
    let coordinator = crate::core::business_startup::process_coordinator();
    coordinator.finish_with_published_reads(Err("fixture follow-up import deferred".into()), true);
    need!(route::open_store("fixture_readable", "fixture", "fixture/readable", &[]).is_err(), "read-only recovery admitted a writer");
    let reader = route::open_registered_store_read_only("fixture_readable", "fixture", "fixture/readable", std::time::Duration::from_secs(2))?.ok_or("published owner disappeared")?;
    let mut statement = reader.prepare("SELECT amount FROM facts ORDER BY id").map_err(|error| error.to_string())?;
    let amounts = statement.query_map([], |row| row.get::<_,i64>(0)).map_err(|error| error.to_string())?.collect::<Result<Vec<_>,_>>().map_err(|error| error.to_string())?;
    need!(amounts == vec![123,789], "published owner lost old or post-upgrade facts");
    drop(statement); drop(reader);
    need!(route::open_registered_store_read_only("fixture_pending", "fixture", "fixture/pending", std::time::Duration::from_secs(2)).is_err(), "unfinished owner leaked through published reads");
    need!(route::open_registered_store_read_only("fixture_readable", "unknown", "fixture/missing", std::time::Duration::from_secs(2))?.is_none(), "read-only lookup created a missing owner");
    coordinator.begin_retry()?;
    need!(coordinator.ensure_ready().is_err() && coordinator.ensure_readable().is_ok(), "retry revoked published reads or enabled writers");
    let catalog = token_count_jsonl::session_catalog_snapshot(home, |_| {
        Err("published catalog must never invoke a raw parser".into())
    })?;
    let original_paths = original_catalog.entries.iter().map(|entry| &entry.path).collect::<Vec<_>>();
    let published_paths = catalog.entries.iter().map(|entry| &entry.path).collect::<Vec<_>>();
    need!(published_paths == original_paths, "paused owner hid the previously published session catalog");
    need!(!catalog.warnings.is_empty(), "published-only catalog fabricated destructive-action verification");

    let mut parked = Vec::new();
    for name in ["sessions", "archived_sessions"] {
        let source = home.join(name);
        if source.exists() {
            let retained = home.join(format!("fixture-retained-{name}"));
            fs::rename(&source, &retained).map_err(|error| error.to_string())?;
            parked.push((source,retained));
        }
    }
    let read = (|| {
        let compact = token_count_jsonl::refreshed_usage_summary_snapshot_with_interval(home, Some(0))?.ok_or("no published summary")?;
        let full = token_count_jsonl::dashboard_snapshot(home)?;
        need!(compact.total_tokens == original.stats.total_tokens && full.stats.total_tokens == original.stats.total_tokens, "published full or compact read changed totals without sources");
        need!(!full.precise_recent_usage_fresh && full.precise_observer_epoch.is_none(), "read-only recovery fabricated fresh coverage");
        need!(full.settled_through == original.settled_through, "read-only recovery advanced the chart watermark");
        Ok::<_, String>(full.stats.total_tokens)
    })();
    for (source,retained) in parked { fs::rename(retained, source).map_err(|error| error.to_string())?; }
    let tokens = read?;
    let after = crate::core::business_store_container::Container::snapshot_digest_path(&paths.a).map_err(|error| error.to_string())?;
    need!(after == before, "published recovery read mutated A");
    // Only this disposable failure journal is removed; no product cleanup or
    // source replacement is being simulated by declaring startup Ready.
    Connection::open(&paths.a).map_err(|error| error.to_string())?.execute("DELETE FROM tb_container_meta WHERE key=?1", [key]).map_err(|error| error.to_string())?;
    coordinator.finish(Ok(()));
    Ok(json!({"name":"published-recovery-reads","status":"PASS","oldAndNewFacts":amounts,"tokensWithoutRawSessions":tokens,"aUnchanged":true,"retryReadOnly":true,"publishedCatalogEntries":catalog.entries.len(),"catalogParserCalled":false,"catalogActionsVerified":false}))
}

struct Paths {
    a: PathBuf,
    marker: PathBuf,
    b: PathBuf,
    quota: PathBuf,
    shared_quota: PathBuf,
    modeltrace: PathBuf,
    performance: PathBuf,
    exact_root: PathBuf,
    old_exact_root: PathBuf,
}
impl Paths {
    fn resolve(root: &Path) -> Result<Self, String> {
        let get = |p: Option<PathBuf>, s: &str| p.ok_or_else(|| s.to_owned());
        let quota = get(
            app_paths::quota_history_database_path(),
            "quota path unavailable",
        )?;
        let shared_quota = get(
            app_paths::legacy_shared_quota_history_database_path(),
            "shared quota path unavailable",
        )?;
        let modeltrace = get(
            app_paths::modeltrace_database_path(),
            "ModelTrace path unavailable",
        )?;
        let performance = get(
            app_paths::performance_trace_log_path(),
            "performance path unavailable",
        )?;
        let exact_root = get(app_paths::usage_history_dir(), "Exact path unavailable")?;
        let old_exact_root = get(
            app_paths::tauri_usage_cache_dir(),
            "legacy Exact path unavailable",
        )?
        .join("exact-token-index");
        let b = get(
            app_paths::multi_client_usage_database_path(),
            "B path unavailable",
        )?;
        let a = route::container_path()?;
        let marker = PathBuf::from(format!("{}.initialized", a.display()));
        for f in [
            &quota,
            &shared_quota,
            &modeltrace,
            &performance,
            &exact_root,
            &old_exact_root,
            &b,
            &a,
            &marker,
        ] {
            need!(
                f.starts_with(root),
                format!("path escaped fixture root: {}", f.display())
            );
        }
        Ok(Self {
            a,
            marker,
            b,
            quota,
            shared_quota,
            modeltrace,
            performance,
            exact_root,
            old_exact_root,
        })
    }
}

fn validate_root(input: &Path) -> Result<PathBuf, String> {
    need!(input.is_absolute(), "fixture root must be absolute");
    let home = app_paths::home_dir();
    let home = fs::canonicalize(&home).unwrap_or(home);
    let mut ancestor = input;
    while !ancestor.exists() {
        ancestor = ancestor
            .parent()
            .ok_or("fixture root has no existing ancestor")?;
    }
    let c = ok!(fs::canonicalize(ancestor));
    need!(
        !c.starts_with(&home) && !home.starts_with(&c),
        "fixture root overlaps current home"
    );
    ok!(fs::create_dir_all(input));
    let root = ok!(fs::canonicalize(input));
    need!(
        !root.starts_with(&home) && !home.starts_with(&root),
        "fixture root overlaps current home"
    );
    for key in ENV {
        let value = std::env::var_os(key).ok_or_else(|| format!("missing path override {key}"))?;
        let p = PathBuf::from(value);
        need!(
            p.is_absolute() && p.starts_with(&root),
            format!("{key} must be absolute and inside fixture root")
        );
        ok!(fs::create_dir_all(&p));
        need!(
            ok!(fs::canonicalize(p)).starts_with(&root),
            format!("{key} resolves outside fixture root")
        );
    }
    Ok(root)
}

fn public_read_only_fixture(paths: &Paths) -> Result<Value, String> {
    let writer = route::open_store(
        "fixture_readonly", "fixture", "fixture/public-read-only", &[],
    )?;
    ok!(writer.execute_batch("CREATE TABLE observations(value INTEGER); INSERT INTO observations VALUES(41);"));
    let catalog = ok!(Connection::open_with_flags(
        &paths.a, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ));
    let before: i64 = ok!(catalog.query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row.get(0)));
    ok!(writer.execute_batch("BEGIN IMMEDIATE; UPDATE observations SET value=42;"));
    let checked = (|| -> Result<(), String> {
        let reader = route::open_registered_store_read_only(
            "fixture_readonly", "fixture", "fixture/public-read-only",
            std::time::Duration::from_millis(25),
        )?.ok_or("public read-only route lost its registered namespace")?;
        let value: i64 = ok!(reader.query_row("SELECT value FROM observations", [], |row| row.get(0)));
        need!(value == 41, "read-only route exposed the publisher's uncommitted value");
        let error = reader.execute("INSERT INTO observations VALUES(99)", [])
            .err().ok_or("public read-only route allowed a main-database write")?;
        need!(error.sqlite_error_code() == Some(rusqlite::ErrorCode::ReadOnly),
            "read-only fixture did not reach SQLite write enforcement");
        need!(route::open_registered_store_read_only(
            "fixture_readonly", "unknown-home", "fixture/public-read-only",
            std::time::Duration::from_millis(25),
        )?.is_none(), "public read-only route created an unknown namespace");
        let after: i64 = ok!(catalog.query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row.get(0)));
        need!(after == before, "public read-only route registered an unknown partition");
        Ok(())
    })();
    let rollback = writer.execute_batch("ROLLBACK;");
    checked?;
    ok!(rollback);
    need!(ok!(writer.query_row("SELECT value FROM observations", [], |row| row.get::<_, i64>(0))) == 41,
        "read-only fixture changed its committed source");
    Ok(json!({"name":"public-read-only-routing","status":"PASS",
        "startupReadRefused":true,"concurrentPublisherRead":true,
        "uncommittedValueHidden":true,"mainWriteRefused":true,
        "unknownPartitionNotRegistered":true}))
}

fn seed_quota(path: &Path, home: &Path, at: f64, legacy: bool) -> Result<(), String> {
    parent(path)?;
    let plan = quota_history::QuotaHistoryIdentity::from_canonical_parts(home,
        Some("sub:fixture-account"), "pro", "codex")
        .ok_or("legacy quota fixture identity rejected")?.attribution_identity().plan;
    let c = ok!(Connection::open(path));
    ok!(c.execute_batch("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at REAL NOT NULL,account_key TEXT NOT NULL,plan_type TEXT,limit_name TEXT,account_name TEXT,source TEXT,five_hour_used_percent INTEGER,five_hour_resets_at REAL,five_hour_cycle_generation INTEGER,five_hour_reset_anchor INTEGER NOT NULL DEFAULT 0,seven_day_used_percent INTEGER,seven_day_resets_at REAL,seven_day_cycle_generation INTEGER,seven_day_reset_anchor INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,identity_version INTEGER,home_identity TEXT,stable_account_key TEXT,identity_plan_type TEXT,identity_limit_id TEXT);"));
    ok!(c.execute("INSERT INTO quota_snapshots(created_at,account_key,plan_type,limit_name,account_name,source,five_hour_used_percent,five_hour_resets_at,five_hour_cycle_generation,seven_day_used_percent,seven_day_resets_at,seven_day_cycle_generation,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id) VALUES(?1,'sub:fixture-account','pro','codex','Fixture','tauri',20,?2,1,30,?3,1,'ok',1,?4,'sub:fixture-account',?5,'codex')",params![at,at+10000.0,at+200000.0,home.to_string_lossy().as_ref(),plan]));
    if legacy {
        // One duplicate of the other legacy store, one unclaimed row and one
        // different identity. The source file and its old shape stay immutable
        // when the production legacy readers are exercised below.
        ok!(c.execute("INSERT INTO quota_snapshots(created_at,account_key,plan_type,limit_name,account_name,source,five_hour_used_percent,five_hour_resets_at,five_hour_cycle_generation,seven_day_used_percent,seven_day_resets_at,seven_day_cycle_generation,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id) SELECT created_at-300,account_key,plan_type,limit_name,account_name,source,five_hour_used_percent,five_hour_resets_at-300,five_hour_cycle_generation,seven_day_used_percent,seven_day_resets_at-300,seven_day_cycle_generation,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id FROM quota_snapshots", []));
        ok!(c.execute_batch("INSERT INTO quota_snapshots(created_at,account_key,source,status) VALUES(1,'fixture-unclaimed','tauri','ok'); INSERT INTO quota_snapshots(created_at,account_key,source,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id) SELECT created_at+1,'fixture-other','tauri','ok',identity_version,home_identity,'sub:fixture-other',identity_plan_type,identity_limit_id FROM quota_snapshots WHERE id=1;"));
        for column in ["five_hour_cycle_generation", "five_hour_reset_anchor", "seven_day_cycle_generation", "seven_day_reset_anchor"] {
            ok!(c.execute_batch(&format!("ALTER TABLE quota_snapshots DROP COLUMN {column}")));
        }
    }
    Ok(())
}

fn seed_modeltrace(path: &Path) -> Result<(), String> {
    parent(path)?;
    let c = ok!(Connection::open(path));
    ok!(c.execute_batch("CREATE TABLE modeltrace_runs(scope TEXT NOT NULL,id TEXT PRIMARY KEY,started_at INTEGER NOT NULL,payload TEXT NOT NULL);CREATE INDEX modeltrace_scope_time ON modeltrace_runs(scope,started_at DESC);CREATE TABLE modeltrace_settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL);"));
    let r = run("fixture-legacy-modeltrace-run", now() as i64 - 300);
    ok!(c.execute(
        "INSERT INTO modeltrace_runs(scope,id,started_at,payload) VALUES(?1,?2,?3,?4)",
        params![
            "fixture:modeltrace-scope",
            r.id,
            r.started_at,
            ok!(serde_json::to_string(&r))
        ]
    ));
    Ok(())
}

fn seed_body(path: &Path, s: &SpeedSample) -> Result<(), String> {
    parent(path)?;
    let c = ok!(Connection::open(path));
    ok!(c.execute_batch("CREATE TABLE speed_trend_meta(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL) WITHOUT ROWID;INSERT INTO speed_trend_meta VALUES('schema_version','1'),('body_retention_days','30');CREATE TABLE speed_samples(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,model TEXT NOT NULL,included INTEGER NOT NULL,payload_json TEXT NOT NULL) WITHOUT ROWID;CREATE INDEX speed_samples_ended_model ON speed_samples(ended_at,model);CREATE INDEX speed_samples_model_ended ON speed_samples(model,ended_at);CREATE TABLE speed_sample_ids(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL,bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,trend_eligible INTEGER NOT NULL) WITHOUT ROWID;CREATE INDEX speed_sample_ids_ended ON speed_sample_ids(ended_at);CREATE TABLE speed_5m(bucket_start INTEGER NOT NULL,model TEXT NOT NULL,output_tokens INTEGER NOT NULL,duration_seconds REAL NOT NULL,sample_count INTEGER NOT NULL,PRIMARY KEY(bucket_start,model)) WITHOUT ROWID;"));
    let model = s.model.as_deref().unwrap_or("unknown");
    let bucket = (s.ended_at / 300.0).floor() as i64 * 300;
    ok!(c.execute(
        "INSERT INTO speed_samples VALUES(?1,?2,?3,1,?4)",
        params![s.id, s.ended_at, model, ok!(serde_json::to_string(s))]
    ));
    ok!(c.execute(
        "INSERT INTO speed_sample_ids VALUES(?1,?2,?3,?4,?5,?6,1)",
        params![
            s.id,
            s.ended_at,
            bucket,
            model,
            i64::from(s.output_tokens),
            s.duration_seconds
        ]
    ));
    ok!(c.execute(
        "INSERT INTO speed_5m VALUES(?1,?2,?3,?4,1)",
        params![
            bucket,
            model,
            i64::from(s.output_tokens),
            s.duration_seconds
        ]
    ));
    Ok(())
}

fn exact_fixture(h1: &Path, h2: &Path, p: &Paths) -> Result<Value, String> {
    let session = h1.join("sessions/first.jsonl");
    write_session(&session, "2026-10-28T00:00:00Z", 120)?;
    need!(
        token_count_jsonl::dashboard_snapshot(h1)?
            .stats
            .total_tokens
            == 120,
        "Exact Home one initial index mismatch"
    );
    let index = exact_path(&p.exact_root, h1)?;
    let store = route::exact_store_spec(&index)?;
    route::export_store_to_path(&store.source_identity, "exact", &store.logical_path, &index)?;
    let source_digest = digest(&index)?;
    need!(
        route::remove_exact_store(&index)?,
        "Exact namespace was not removed for legacy import test"
    );
    token_count_jsonl::bootstrap_legacy_exact_indexes()?;
    let receipt: bool = ok!(ok!(Connection::open(&p.a)).query_row(
        "SELECT EXISTS(SELECT 1 FROM tb_legacy_inputs WHERE source_path=?1 AND module='exact' AND retired=0)",
        [index.to_string_lossy().as_ref()], |r| r.get(0)));
    need!(
        route::exact_store_exists(&index)? && receipt,
        "Exact legacy import or active receipt missing"
    );
    need!(
        digest(&index)? == source_digest
            && token_count_jsonl::dashboard_snapshot(h1)?
                .stats
                .total_tokens
                == 120,
        "Exact legacy facts changed"
    );
    let next = h1.join("sessions/second.jsonl");
    write_session(&next, "2026-10-28T00:01:00Z", 55)?;
    let next = ok!(fs::canonicalize(next));
    let stage = stage_path(&index, &next)?;
    seed_stage(&stage)?;
    let before = stage_objects(&p.a)?;
    need!(before > 0, "Exact stage namespace missing");
    need!(
        token_count_jsonl::dashboard_snapshot(h1)?
            .stats
            .total_tokens
            == 175,
        "Exact interrupted-stage recovery mismatch"
    );
    need!(
        !route::exact_store_exists(&stage)? && stage_objects(&p.a)? >= before,
        "Exact stage recovery artifact not retained"
    );
    let other = h2.join("sessions/other.jsonl");
    write_session(&other, "2026-10-28T00:02:00Z", 240)?;
    let snap = token_count_jsonl::dashboard_snapshot(h2)?;
    let second = exact_path(&p.exact_root, h2)?;
    need!(
        snap.stats.total_tokens == 240
            && index != second
            && route::exact_store_exists(&index)?
            && route::exact_store_exists(&second)?,
        "Exact Home partition collision"
    );
    need!(
        token_count_jsonl::dashboard_snapshot(h1)?
            .stats
            .total_tokens
            == 175,
        "Exact facts crossed Home partitions"
    );
    Ok(
        json!({"name":"exact-import-stage-and-home-scope","status":"PASS","homeOneTokens":175,"homeTwoTokens":240,"stageObjectsBefore":before,"stageObjectsAfter":stage_objects(&p.a)?}),
    )
}

fn seed_stage(path: &Path) -> Result<(), String> {
    let s = route::exact_store_spec(path)?;
    let c = route::open_store("exact", &s.source_identity, &s.logical_path, &[])?;
    ok!(c.execute_batch("CREATE TABLE manifest(manifest_schema_version INTEGER NOT NULL,parser_revision TEXT NOT NULL,complete INTEGER NOT NULL,staging_mode TEXT NOT NULL,accounting_state TEXT);CREATE TABLE events(ordinal INTEGER PRIMARY KEY);CREATE TABLE fingerprints(fingerprint BLOB PRIMARY KEY);CREATE TABLE chunks(chunk_index INTEGER PRIMARY KEY);"));
    Ok(())
}
fn stage_objects(path: &Path) -> Result<i64, String> {
    ok!(Connection::open(path))
    .query_row("SELECT COUNT(*) FROM sqlite_master o JOIN tb_stores s ON substr(o.name,1,length(s.namespace_prefix))=s.namespace_prefix WHERE s.module='exact' AND substr(o.name,length(s.namespace_prefix)+1)='manifest' AND o.type='table'",[],|r|r.get(0)).map_err(|e|e.to_string())
}
fn park_a_and_test(p: &Paths) -> Result<(), String> {
    token_count_jsonl::with_staging_quiesced_for_container_maintenance(||park_a_with_idle_owners(p))
}
fn park_a_with_idle_owners(p:&Paths)->Result<(),String> {
    let a = p.a.with_extension("fixture-parked");
    let m = p.marker.with_extension("fixture-parked");
    need!(!a.exists() && !m.exists(), "A parking path already exists");
    fs::rename(&p.a, &a).map_err(|e|format!("park A after owner quiescence: {e}"))?;
    if let Err(e) = fs::rename(&p.marker, &m) {
        let _ = fs::rename(&a, &p.a);
        return Err(e.to_string());
    }
    let opened = route::open_store(
        "fixture_probe",
        "missing-a-probe",
        "fixture/missing-a-probe",
        &[],
    );
    let ra = fs::rename(&a, &p.a);
    let rm = fs::rename(&m, &p.marker);
    ok!(ra);
    ok!(rm);
    need!(opened.is_err(), "open_store recreated missing A");
    route::bootstrap()
}

fn quota_facts(path: &Path) -> Result<i64, String> {
    let id = route::source_identity("quota_history_legacy", path)?;
    let logical = format!("legacy/quota-history/{id}");
    let c = route::open_store("quota_history_legacy", &id, &logical, &[path.to_path_buf()])?;
    c.query_row(
        "SELECT COUNT(*) FROM quota_snapshots WHERE account_key='sub:fixture-account' AND five_hour_used_percent=20 AND seven_day_used_percent=30",
        [],
        |r| r.get(0),
    )
    .map_err(|e| e.to_string())
}
fn store_count(path: &Path) -> Result<i64, String> {
    ok!(Connection::open(path))
        .query_row("SELECT COUNT(*) FROM tb_stores", [], |r| r.get(0))
        .map_err(|e| e.to_string())
}
fn run(id: &str, at: i64) -> modeltrace::Run {
    modeltrace::Run {
        id: id.into(),
        model: "gpt-6.1-sol".into(),
        effort: "low".into(),
        started_at: at,
        completed_at: Some(at + 10),
        status: "completed".into(),
        attempts: 1,
        valid_samples: 0,
        message: None,
        attribution: None,
        samples: vec![],
    }
}
fn sample(id: &str, end: f64, tokens: u32, duration: f64) -> SpeedSample {
    SpeedSample {
        id: id.into(),
        thread_id: "fixture-thread".into(),
        turn_id: "fixture-turn".into(),
        item_id: id.into(),
        model: Some("gpt-4o".into()),
        started_at: end - duration,
        ended_at: end,
        output_tokens: tokens,
        output_characters: u64::from(tokens),
        output_bytes: u64::from(tokens),
        chunk_count: 4,
        duration_seconds: duration,
        tokens_per_second: f64::from(tokens) / duration,
        confidence: "medium".into(),
        network_warning: None,
        source: "fixture".into(),
        measurement_kind: Some("completed_body".into()),
        tokenizer: Some("o200k_base".into()),
        body_phase: Some("final_answer".into()),
        quality_reason: None,
    }
}
fn quota_bundle(now: f64) -> crate::models::AccountQuotaBundle {
    let date = |at: i64| {
        time::OffsetDateTime::from_unix_timestamp(at)
            .unwrap_or(time::OffsetDateTime::UNIX_EPOCH)
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_default()
    };
    crate::models::AccountQuotaBundle {
        updated_at: date(now as i64),
        attribution_identity: None,
        account: crate::models::AccountInfo {
            display_name: "Fixture Account".into(),
            plan_label: "pro".into(),
        },
        quota: crate::models::QuotaSnapshot {
            five_hour: crate::models::QuotaLimit {
                label: "5h".into(),
                availability: crate::models::QuotaAvailability::Measured,
                remaining_percent: Some(65.0),
                used_percent: Some(35.0),
                resets_at: date(now as i64 + 10000),
                resets_at_unix: Some(now as i64 + 10000),
                cycle_id: Some("fixture-5h".into()),
            },
            seven_day: crate::models::QuotaLimit {
                label: "7d".into(),
                availability: crate::models::QuotaAvailability::Measured,
                remaining_percent: Some(70.0),
                used_percent: Some(30.0),
                resets_at: date(now as i64 + 200000),
                resets_at_unix: Some(now as i64 + 200000),
                cycle_id: Some("fixture-7d".into()),
            },
            reserve_windows: vec![],
            reset_credit: crate::models::ResetCreditSummary {
                available_count: 0,
                status: "fixture".into(),
                credits: vec![],
            },
            pace_label: "fixture".into(),
        },
        quota_history_daily: vec![],
        quota_history_24h: vec![],
        quota_history_7d: vec![],
        quota_history_30d: vec![],
        warnings: vec![],
        diagnostics: vec![],
    }
}
fn body_path(s: &live_rate::LiveRateSourceScope, log: &Path) -> Result<PathBuf, String> {
    let x = format!("{}\n{}", s.canonical_home_key, s.physical_home_key);
    let h = x.bytes().fold(0xcbf29ce484222325_u64, |mut h, b| {
        h ^= u64::from(b);
        h.wrapping_mul(0x100000001b3)
    });
    Ok(log
        .parent()
        .ok_or("performance path has no parent")?
        .join(format!("body-speed-{h:016x}.sqlite")))
}
fn exact_path(root: &Path, h: &Path) -> Result<PathBuf, String> {
    let h = fs::canonicalize(h).map_err(|e| e.to_string())?;
    let hash = h
        .to_string_lossy()
        .bytes()
        .fold(0xcbf29ce484222325_u64, |mut x, b| {
            x ^= u64::from(b);
            x.wrapping_mul(0x100000001b3)
        });
    Ok(root.join(format!("{hash:016x}.sqlite3")))
}
fn stage_path(index: &Path, source: &Path) -> Result<PathBuf, String> {
    let s = source.to_str().ok_or("non-UTF8 source")?;
    let hash = Sha256::digest(s.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    Ok(PathBuf::from(format!(
        "{}.staging/{hash}.sqlite3",
        index.display()
    )))
}
fn write_session(path: &Path, timestamp: &str, tokens: i64) -> Result<(), String> {
    parent(path)?;
    let row = json!({"timestamp":timestamp,"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":tokens,"cached_input_tokens":0,"output_tokens":0,"total_tokens":tokens}}}});
    ok!(fs::write(path, format!("{row}\n")));
    Ok(())
}
fn parent(path: &Path) -> Result<(), String> {
    if let Some(p) = path.parent() {
        ok!(fs::create_dir_all(p));
    }
    Ok(())
}
fn digest(path: &Path) -> Result<String, String> {
    let b = fs::read(path).map_err(|e| e.to_string())?;
    Ok(Sha256::digest(b)
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect())
}
fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
