//! Offline production-path exercise for business container A and ledger B.
//! Built only with `business-store-fixture`; all required path overrides must
//! resolve inside the caller's disposable root. This code never changes env.

use crate::core::{
    app_paths, business_store_route as route, live_rate, modeltrace, quota_history,
    usage::token_count_jsonl,
};
use crate::models::SpeedSample;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const ENV: [&str; 5] = [
    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
    "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR",
    "CODEX_TOKEN_BAR_CACHE_BASE_DIR",
    "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR",
];

// Called only by the explicitly enabled offline fixture binary, after the
// producer has written TEMP rows but before it commits its parsing transaction.
pub(crate) fn assert_concurrent_a_write() -> Result<(), String> {
    let connection = route::open_store("fixture_concurrent", "fixture", "fixture/concurrent", &[])?;
    connection
        .busy_timeout(std::time::Duration::from_millis(250))
        .map_err(|e| e.to_string())?;
    connection.execute_batch("CREATE TABLE IF NOT EXISTS observations(id INTEGER PRIMARY KEY); INSERT INTO observations DEFAULT VALUES;")
        .map_err(|e| format!("producer held A writer lock during TEMP parsing: {e}"))
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
    seed_quota(&p.quota, &h1, now - 1200.0)?;
    seed_quota(&p.shared_quota, &h1, now - 900.0)?;
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

    route::bootstrap()?;
    need!(
        p.a.is_file() && p.marker.is_file() && p.a != p.b,
        "bootstrap did not initialize distinct A and B"
    );
    let mut checks = vec![json!({"name":"bootstrap","status":"PASS"})];

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
        active > 0 && imported == [1, 1],
        "quota legacy typed facts or active write missing"
    );
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

    let b = crate::core::multi_client_usage::open_activity_module_connection()?;
    ok!(b.execute("INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES(?1,?2,'model','fixture','1','output','codex','gpt-6.1-sol',?3,?4,12,10,120)", params!["fixture-b", "fixture-b-activity", now - 10.0, now]));
    let b_rows: i64 = ok!(b.query_row(
        "SELECT COUNT(*) FROM activity_speed_samples WHERE id='fixture-b-activity'",
        [],
        |r| r.get(0)
    ));
    need!(b_rows == 1, "B activity write missing");
    checks.push(json!({"name":"ledger-b","status":"PASS","rows":b_rows}));

    checks.push(exact_fixture(&h1, &h2, &p)?);
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
    park_a_and_test(&p)?;
    checks.push(json!({"name":"rerun-and-fail-closed","status":"PASS","storeCount":count}));
    Ok(json!({"status":"PASS","root":root,"containerA":p.a,"clientB":p.b,"checks":checks}))
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

fn seed_quota(path: &Path, home: &Path, at: f64) -> Result<(), String> {
    parent(path)?;
    let c = ok!(Connection::open(path));
    ok!(c.execute_batch("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at REAL NOT NULL,account_key TEXT NOT NULL,plan_type TEXT,limit_name TEXT,account_name TEXT,source TEXT,five_hour_used_percent INTEGER,five_hour_resets_at REAL,five_hour_cycle_generation INTEGER,five_hour_reset_anchor INTEGER NOT NULL DEFAULT 0,seven_day_used_percent INTEGER,seven_day_resets_at REAL,seven_day_cycle_generation INTEGER,seven_day_reset_anchor INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,identity_version INTEGER,home_identity TEXT,stable_account_key TEXT,identity_plan_type TEXT,identity_limit_id TEXT);"));
    ok!(c.execute("INSERT INTO quota_snapshots(created_at,account_key,plan_type,limit_name,account_name,source,five_hour_used_percent,five_hour_resets_at,five_hour_cycle_generation,seven_day_used_percent,seven_day_resets_at,seven_day_cycle_generation,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id) VALUES(?1,'sub:fixture-account','pro','codex','Fixture','swift',20,?2,1,30,?3,1,'ok',1,?4,'sub:fixture-account','pro','codex')",params![at,at+10000.0,at+200000.0,home.to_string_lossy().as_ref()]));
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
    let a = p.a.with_extension("fixture-parked");
    let m = p.marker.with_extension("fixture-parked");
    need!(!a.exists() && !m.exists(), "A parking path already exists");
    ok!(fs::rename(&p.a, &a));
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
