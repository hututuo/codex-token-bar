//! Injected only into disposable exact-release/candidate source archives.
//! No cfg(test), no production source edits, no installed-app data roots.
use crate::core::{app_paths, business_store_route as route, quota_history,
    usage::token_count_jsonl as token, business_store_container::{Container, StoreSpec}};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::{fs, path::{Path, PathBuf}, time::{SystemTime, UNIX_EPOCH}};
macro_rules! checked { ($v:expr) => { $v.map_err(|e| e.to_string())? }; }
macro_rules! require { ($c:expr, $m:expr) => { if !$c { return Err($m.to_string()); } }; }
const OVERRIDES: [&str; 5] = ["CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", "CODEX_TOKEN_BAR_CACHE_BASE_DIR", "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR"];

fn validate(input: &Path) -> Result<PathBuf, String> {
    require!(input.is_absolute(), "absolute disposable root required");
    let root = checked!(fs::canonicalize(input));
    let temp = checked!(fs::canonicalize(std::env::temp_dir()));
    let home = checked!(fs::canonicalize(app_paths::home_dir()));
    require!(root.starts_with(&temp) && !root.starts_with(&home) && !home.starts_with(&root), "unsafe fixture root");
    require!(checked!(fs::read_to_string(root.join(".formed-release-fixture"))).trim() == "synthetic-only-v1", "missing ownership marker");
    for key in OVERRIDES {
        let path = PathBuf::from(std::env::var_os(key).ok_or_else(|| format!("missing {key}"))?);
        require!(path.is_absolute(), "override must be absolute");
        let path = checked!(fs::canonicalize(path));
        require!(path != root && path.starts_with(&root) && path.is_dir(), "override escapes fixture root");
    }
    require!(std::env::var_os("CODEX_TOKEN_BAR_TEST_EXACT_INDEX_PATH").is_none(), "cfg(test) route not permitted");
    Ok(root)
}
fn now() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64() }
fn date(at: i64) -> String { time::OffsetDateTime::from_unix_timestamp(at).unwrap()
    .format(&time::format_description::well_known::Rfc3339).unwrap() }
fn line(at: i64, input: i64, output: i64) -> String {
    let usage=json!({"input_tokens":input,"cached_input_tokens":0,"output_tokens":output,"total_tokens":input+output});
    json!({"timestamp":date(at),"type":"event_msg","payload":{"type":"token_count","info":{
        "total_token_usage":usage,"last_token_usage":usage}}}).to_string()+"\n"
}
fn homes(root: &Path) -> Result<Vec<PathBuf>, String> {
    ["home-a", "home-b"].iter().map(|name| fs::canonicalize(root.join(name)).map_err(|e|e.to_string())).collect()
}
fn catalog_proofs(path: &Path) -> Result<Value, String> {
    let db=checked!(Container::open_existing(path));
    let mut query=checked!(db.connection().prepare("SELECT module,source_identity,logical_path FROM tb_stores ORDER BY store_id"));
    let rows=checked!(query.query_map([],|r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))));
    let mut proofs=serde_json::Map::new();
    for row in rows {
        let (module, identity, logical)=checked!(row);
        let spec=checked!(StoreSpec::new(module,identity,logical));
        proofs.insert(spec.id.clone(), checked!(serde_json::to_value(checked!(db.proof(&spec)))));
    }
    Ok(Value::Object(proofs))
}
fn start() -> Result<(), String> {
    let coordinator=crate::core::business_startup::process_coordinator();
    require!(coordinator.begin_initial(), "startup already claimed");
    let result=route::bootstrap(); coordinator.finish(result.clone()); result
}
fn b_canary() -> Result<(), String> {
    let b=crate::core::multi_client_usage::open_activity_module_connection()?;
    checked!(b.execute("INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES('formed-synthetic','formed-existing-b-row','model','fixture','1','output','codex','gpt-6.1-sol',1800000000,1800000010,12,10,120)", []));
    Ok(())
}
fn assert_b() -> Result<(), String> {
    let path=app_paths::multi_client_usage_database_path().ok_or("missing B path")?;
    let b=checked!(Connection::open_with_flags(path,rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY));
    let row:(i64,i64,i64)=checked!(b.query_row("SELECT COUNT(*),SUM(covered_seconds),SUM(weighted_output) FROM activity_speed_samples WHERE id='formed-existing-b-row'",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))));
    require!(row==(1,10,120), "old B activity history changed"); Ok(())
}
fn identity(home: &Path) -> Result<quota_history::QuotaHistoryIdentity, String> {
    quota_history::QuotaHistoryIdentity::from_canonical_parts(home,Some("sub:fixture-account"),"pro","codex").ok_or("quota identity rejected".into())
}
fn quota_spec(path:&Path) -> Result<StoreSpec,String> {
    let id=route::source_identity("quota_history_legacy",path)?;
    StoreSpec::new("quota_history_legacy",&id,format!("legacy/quota-history/{id}")).map_err(|e|e.to_string())
}

pub fn run(input: &Path, phase: &str) -> Result<Value,String> {
    let root=validate(input)?;
    let a=route::container_path()?;
    let marker=PathBuf::from(format!("{}.initialized",a.display()));
    let quota=app_paths::quota_history_database_path().ok_or("missing quota path")?;
    let state=root.join("formed-state.json");
    if phase=="committed" || phase=="interrupted" {
        require!(!a.exists() && !marker.exists() && !quota.exists() && !state.exists(), "refusing existing state");
        let at=now();
        for (name,scale) in [("home-a",1),("home-b",2)] {
            let home=root.join(name); checked!(fs::create_dir_all(home.join("sessions")));
            let text="{\"type\":\"session_meta\",\"payload\":{\"id\":\"019ff8b9-09e7-75c1-b9a5-14fe7b60065a\"}}\n{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6.1-sol\"}}\n".to_string()+&line(at as i64-60,120*scale,35*scale);
            checked!(fs::write(home.join("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl"),text));
        }
        let homes=homes(&root)?;
        seed_quota(&quota,&homes[0],at-1200.0,"formed-legacy")?;
        if phase=="committed" {
            start()?;
            for (home, expected) in homes.iter().zip([155_u64,310]) {
                require!(token::dashboard_snapshot(home)?.stats.total_tokens==expected,"released code failed to form exact history");
            }
            quota_history::record_bundle(&identity(&homes[0])?, &quota_bundle(at))?;
            b_canary()?;
        } else {
            // The exact released importer commits a real partial A partition.
            // Stop before bootstrap activation, without altering any app code.
            let spec=quota_spec(&quota)?;
            drop(route::open_store_during_bootstrap(&spec.module,&spec.source_identity,&spec.logical_path,&[quota.clone()])?);
            require!(!marker.exists(),"partial import unexpectedly activated A");
        }
        let report=json!({"schemaVersion":1,"phase":phase,"producerVersion":env!("CARGO_PKG_VERSION"),
            "cfgTest":cfg!(test),"proofs":catalog_proofs(&a)?,"legacyQuota":quota,
            "formedExact":phase=="committed","formedB":phase=="committed"});
        checked!(fs::write(&state,checked!(serde_json::to_vec_pretty(&report))));
        // A real committed WAL survives abrupt termination without destructors.
        let db=checked!(Connection::open(&a));
        checked!(db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; BEGIN IMMEDIATE; INSERT INTO tb_container_meta(key,value) VALUES('formed_release_crash','committed-before-exit'); COMMIT;"));
        std::process::exit(86);
    }
    require!(phase=="resume" || phase=="reopen", "unknown phase");
    let old:Value=checked!(serde_json::from_slice(&checked!(fs::read(&state))));
    require!(old["cfgTest"]==false,"old state used cfg(test)");
    let committed=old["formedExact"]==true;
    if phase=="resume" {
        require!(PathBuf::from(format!("{}-wal",a.display())).is_file(),"missing abrupt-exit WAL");
        require!(marker.exists()==committed,"old activation state does not match scenario");
    }
    start()?;
    let raw=checked!(Connection::open_with_flags(&a,rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY));
    let canary:String=checked!(raw.query_row("SELECT value FROM tb_container_meta WHERE key='formed_release_crash'",[],|r|r.get(0)));
    require!(canary=="committed-before-exit","committed A WAL row lost"); drop(raw);
    let homes=homes(&root)?;
    if phase=="resume" {
        let current=catalog_proofs(&a)?;
        let quota_id=quota_spec(&quota)?.id;
        for (id,proof) in old["proofs"].as_object().ok_or("missing released typed proofs")? {
            if !committed && id==&quota_id { continue; } // source legitimately grew during interrupted activation
            require!(current.get(id)==Some(proof),format!("released namespace {id} changed before its owner opened"));
        }
        // Validate every old typed quota field, schema, rowid and sequence,
        // including the late committed WAL observation in the interrupted case.
        let expected=checked!(Container::snapshot_proof_path(&quota));
        let imported=checked!(Container::open_existing(&a));
        require!(checked!(imported.proof(&quota_spec(&quota)?))==expected,"frozen quota proof differs after recovery");
        drop(imported);
        for (home,expected) in homes.iter().zip([155_u64,310]) {
            require!(token::dashboard_snapshot(home)?.stats.total_tokens==expected,"released exact history not usable");
        }
        let history=quota_history::history_bundle_for(&identity(&homes[0])?,&quota_bundle(now()),30,true)?;
        require!(!history.recent_7d.is_empty(),"retained quota history not readable");
        let extra=homes[0].join("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065b.jsonl");
        checked!(fs::write(&extra,line(now() as i64-5,5,2)));
        for _ in 0..2 {
            require!(token::dashboard_snapshot(&homes[0])?.stats.total_tokens==162,"increment missing or duplicated");
        }
        checked!(fs::rename(homes[0].join("sessions"),root.join("preserved-synthetic-rollouts")));
        checked!(fs::create_dir(homes[0].join("sessions")));
    }
    require!(token::dashboard_snapshot(&homes[0])?.stats.total_tokens==162,"missing raw source erased recorded history");
    require!(token::dashboard_snapshot(&homes[1])?.stats.total_tokens==310,"home identities mixed");
    if old["formedB"]==true { assert_b()?; }
    route::bootstrap()?;
    Ok(json!({"status":"PASS","phase":phase,"producerVersion":old["producerVersion"],"candidateVersion":env!("CARGO_PKG_VERSION"),
        "cfgTest":cfg!(test),"scenario":old["phase"],"totals":[162,310],"oldTypedProofsPreserved":true,
        "oldBPreserved":old["formedB"],"crashWALPreserved":true,"rawDisappearanceRetainsHistory":true}))
}

fn seed_quota(path: &Path, home: &Path, at: f64, source: &str) -> Result<(), String> {
    parent(path)?;
    let c = checked!(Connection::open(path));
    checked!(c.execute_batch("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at REAL NOT NULL,account_key TEXT NOT NULL,plan_type TEXT,limit_name TEXT,account_name TEXT,source TEXT,five_hour_used_percent INTEGER,five_hour_resets_at REAL,five_hour_cycle_generation INTEGER,five_hour_reset_anchor INTEGER NOT NULL DEFAULT 0,seven_day_used_percent INTEGER,seven_day_resets_at REAL,seven_day_cycle_generation INTEGER,seven_day_reset_anchor INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,identity_version INTEGER,home_identity TEXT,stable_account_key TEXT,identity_plan_type TEXT,identity_limit_id TEXT);"));
    checked!(c.execute("INSERT INTO quota_snapshots(created_at,account_key,plan_type,limit_name,account_name,source,five_hour_used_percent,five_hour_resets_at,five_hour_cycle_generation,seven_day_used_percent,seven_day_resets_at,seven_day_cycle_generation,status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id) VALUES(?1,'sub:fixture-account','pro','codex','Fixture','swift',20,?2,1,30,?3,1,'ok',1,?4,'sub:fixture-account','Pro','codex')",params![at,at+10000.0,at+200000.0,home.to_string_lossy().as_ref()]));
    checked!(c.execute("UPDATE quota_snapshots SET source=?1", [source]));
    if source == "tauri" {
        // Published databases and interrupted upgrades may lack all four
        // derived cycle columns. The production reader must not ALTER them.
        checked!(c.execute_batch("ALTER TABLE quota_snapshots DROP COLUMN five_hour_cycle_generation;
            ALTER TABLE quota_snapshots DROP COLUMN five_hour_reset_anchor;
            ALTER TABLE quota_snapshots DROP COLUMN seven_day_cycle_generation;
            ALTER TABLE quota_snapshots DROP COLUMN seven_day_reset_anchor;"));
    }
    Ok(())
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

fn parent(path:&Path)->Result<(),String>{fs::create_dir_all(path.parent().ok_or("missing parent")?).map_err(|e|e.to_string())}
