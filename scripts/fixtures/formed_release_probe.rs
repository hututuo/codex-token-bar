//! Injected only into disposable exact-release/candidate source archives.
//! No cfg(test), no production source edits, no installed-app data roots.
use crate::core::{app_paths, business_store_route as route, multi_client_usage as multi, quota_history,
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
fn b_canary() -> Result<Connection, String> {
    let b=multi::open_activity_module_connection()?;
    checked!(b.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;"));
    checked!(b.execute("INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES('formed-synthetic','formed-existing-b-row','model','fixture','1','output','codex','gpt-6.1-sol',1800000000,1800000010,12,10,120)", []));
    Ok(b)
}
fn assert_b() -> Result<(), String> {
    let path=app_paths::multi_client_usage_database_path().ok_or("missing B path")?;
    let b=checked!(Connection::open_with_flags(path,rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY));
    let row:(i64,f64,f64)=checked!(b.query_row("SELECT COUNT(*),SUM(covered_seconds),SUM(weighted_output) FROM activity_speed_samples WHERE id='formed-existing-b-row'",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))));
    require!(row==(1,10.0,120.0), "old B activity history changed"); Ok(())
}
fn b_real(value: f64) -> Value {
    // Preserve every binary64 bit. A decimal JSON roundtrip can change one ULP
    // before candidate admission even when SQLite itself was never modified.
    json!({"realBits": format!("{:016x}", value.to_bits())})
}
fn assert_b_real_codec() -> Result<(), String> {
    // The actual failing mtime and its adjacent binary64 value must survive
    // the same native evidence serialization without becoming equal.
    let bits = 0x41dac229a4112628_u64;
    let first = b_real(f64::from_bits(bits));
    let adjacent = b_real(f64::from_bits(bits + 1));
    require!(first == json!({"realBits":"41dac229a4112628"})
        && adjacent == json!({"realBits":"41dac229a4112629"}) && first != adjacent,
        "B REAL evidence collapsed adjacent binary64 values");
    for proof in [first, adjacent] {
        let encoded = checked!(serde_json::to_vec(&proof));
        require!(checked!(serde_json::from_slice::<Value>(&encoded)) == proof,
            "B REAL evidence changed during native JSON roundtrip");
    }
    Ok(())
}
fn b_rows(connection: &Connection, sql: &str, width: usize) -> Result<Value, String> {
    let mut statement=checked!(connection.prepare(sql));
    let rows=checked!(statement.query_map([], |row| {
        (0..width).map(|column| Ok(match row.get_ref(column)? {
            rusqlite::types::ValueRef::Null => Value::Null,
            rusqlite::types::ValueRef::Integer(value) => json!(value),
            rusqlite::types::ValueRef::Real(value) => b_real(value),
            rusqlite::types::ValueRef::Text(value) => json!(String::from_utf8_lossy(value)),
            rusqlite::types::ValueRef::Blob(value) => json!({"blob":value}),
        })).collect::<rusqlite::Result<Vec<Value>>>()
    }));
    let values=checked!(rows.collect::<rusqlite::Result<Vec<_>>>());
    Ok(json!(values))
}
fn b_read_connection() -> Result<Connection, String> {
    let path=app_paths::multi_client_usage_database_path().ok_or("missing B path")?;
    Ok(checked!(Connection::open_with_flags(path,rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)))
}
fn b_frozen() -> Result<Value, String> {
    let b=b_read_connection()?;
    Ok(json!({
        "version":checked!(b.query_row("PRAGMA user_version",[],|row|row.get::<_,i64>(0))),
        "schema":b_rows(&b,"SELECT type,name,tbl_name,sql FROM sqlite_master WHERE tbl_name IN ('client_usage_events','client_usage_revisions','client_file_checkpoints','multi_usage_metadata') AND name NOT LIKE 'sqlite_%' ORDER BY type,name",4)?,
        "events":b_rows(&b,"SELECT rowid,client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,payload FROM client_usage_events ORDER BY client,event_id",12)?,
        "revisions":b_rows(&b,"SELECT revision,client,event_id,captured_at,payload FROM client_usage_revisions ORDER BY revision",5)?,
        "sequence":b_rows(&b,"SELECT name,seq FROM sqlite_sequence WHERE name='client_usage_revisions'",2)?,
        // A successful refresh is allowed to update its timestamp, but no old metadata may disappear.
        "metadata":b_rows(&b,"SELECT key,value FROM multi_usage_metadata WHERE key<>'updated_at_ms' ORDER BY key",2)?,
    }))
}
fn b_checkpoint() -> Result<Value, String> {
    b_rows(&b_read_connection()?,"SELECT client,source_key,offset,size,modified,identity FROM client_file_checkpoints ORDER BY client,source_key",6)
}
fn assert_b_summary(snapshot: &multi::MultiClientUsageSnapshot) -> Result<(), String> {
    let rows:Vec<_>=snapshot.summaries.iter().filter(|row|row.client=="claudeCode").collect();
    require!(rows.len()==1,"B production snapshot lost or split the synthetic model");
    let row=rows[0];
    require!(row.model=="claude-sonnet-4-5" && (row.input_tokens,row.output_tokens,row.requests)==(21,11,2),
        "B production snapshot changed released token/request totals");
    Ok(())
}
fn seed_b_ledger(root: &Path, at: f64) -> Result<(), String> {
    let directory=root.join("b-transcripts"); checked!(fs::create_dir(&directory));
    let mut transcript=String::new();
    for recorded in [true,false] {
        let mut message=json!({"model":"claude-sonnet-4-5","usage":if recorded {
            json!({"input_tokens":11,"output_tokens":7,"cache_read_input_tokens":3,"cache_creation_input_tokens":2,"output_tokens_details":{"thinking_tokens":1}})
        } else { json!({"input_tokens":5,"output_tokens":4}) }});
        if recorded { message["id"]=json!("formed-b-recorded-message"); }
        transcript.push_str(&json!({"type":"assistant","entrypoint":"cli","sessionId":"formed-b-session",
            "timestamp":date(at as i64-60),"message":message}).to_string());
        transcript.push('\n');
    }
    checked!(fs::write(directory.join("formed.jsonl"),&transcript));
    checked!(fs::write(root.join("b-source-original.jsonl"),&transcript));
    let mut preferences=multi::default_preferences();
    for preference in &mut preferences {
        preference.enabled=preference.client=="claudeCode";
        if preference.enabled { preference.path=directory.to_string_lossy().into_owned(); }
    }
    multi::save_multi_client_usage_preferences(preferences)?;
    assert_b_summary(&multi::refresh_multi_client_usage()?)?;
    assert_b_summary(&multi::read_multi_client_usage_snapshot()?)?;
    let frozen=b_frozen()?;
    require!(frozen["events"].as_array().is_some_and(|rows|rows.len()==2)
        && frozen["revisions"].as_array().is_some_and(|rows|rows.len()==2),"released producer did not create two B events/revisions");
    require!(frozen["events"].as_array().unwrap().iter().any(|row|
        row[11].as_str().is_some_and(|payload|payload.contains("\"quality\":\"fallback_identity\""))),
        "released B fixture did not exercise its legacy fallback payload");
    Ok(())
}
fn exercise_candidate_b(root: &Path, old: &Value, phase: &str) -> Result<Value, String> {
    let frozen=&old["bLedger"]["frozen"];
    require!(&b_frozen()?==frozen,"released B rows/schema changed before candidate ledger admission");
    let initial_checkpoint=b_checkpoint()?;
    if phase=="resume" {
        require!(initial_checkpoint==old["bLedger"]["checkpoint"],"released B checkpoint changed before candidate admission");
    }
    // This real candidate entrypoint runs strict schema admission, then the public reader
    // exercises production aggregates before either forced transcript rescan.
    drop(multi::open_activity_module_connection()?);
    assert_b_summary(&multi::read_multi_client_usage_snapshot()?)?;
    require!(&b_frozen()?==frozen && b_checkpoint()?==initial_checkpoint,"candidate B open/read changed retained ledger data");
    let original=checked!(fs::read_to_string(root.join("b-source-original.jsonl")));
    require!(old["bLedger"]["transcript"].as_str()==Some(original.as_str()),"released transcript original changed");
    let mut revision_counts=Vec::new();
    for pass in 1..=2 {
        let before=b_checkpoint()?;
        // Different leading blank lines change the prefix fingerprint, forcing a full
        // real rescan on both passes without changing any event's semantic content.
        let replay="\n".repeat(pass)+&original;
        checked!(fs::write(root.join("b-transcripts/formed.jsonl"),&replay));
        assert_b_summary(&multi::refresh_multi_client_usage()?)?;
        assert_b_summary(&multi::read_multi_client_usage_snapshot()?)?;
        let current=b_frozen()?;
        require!(&current==frozen,"B replay changed original rows, payload bytes, revision history or schema");
        let checkpoint=b_checkpoint()?;
        let rows=checkpoint.as_array().ok_or("invalid B checkpoint proof")?;
        require!(rows.len()==1 && rows[0][0]=="claudeCode" && rows[0][1]==initial_checkpoint[0][1]
            && rows[0][2].as_u64()==Some(replay.len() as u64) && rows[0][3].as_u64()==Some(replay.len() as u64)
            && rows[0][5]!=before[0][5],"B replay did not commit its changed source fingerprint and complete offset");
        revision_counts.push(current["revisions"].as_array().ok_or("missing B revisions")?.len());
        assert_b()?;
    }
    Ok(json!({"producerLanguage":"rust","candidateActivityOpen":true,"candidateSnapshotRead":true,
        "eventCount":2,"revisionCountBefore":2,"replayPasses":2,"replayRevisionCounts":revision_counts,
        "checkpointAdvances":[true,true],"originalPayloadsPreserved":true,"schemaPreserved":true,
        "activityPreserved":true,"initialCheckpointPreserved":if phase=="resume" {json!(true)} else {Value::Null}}))
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
    assert_b_real_codec()?;
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
        let (b_ledger,_retained_b)=if phase=="committed" {
            start()?;
            for (home, expected) in homes.iter().zip([155_u64,310]) {
                require!(token::dashboard_snapshot(home)?.stats.total_tokens==expected,"released code failed to form exact history");
            }
            quota_history::record_bundle(&identity(&homes[0])?, &quota_bundle(at))?;
            seed_b_ledger(&root,at)?;
            // Keep the released B connection alive until exit(86), retaining its
            // genuinely committed activity WAL beside the committed A WAL.
            let retained=b_canary()?;
            (json!({"frozen":b_frozen()?,"checkpoint":b_checkpoint()?,
                "transcript":checked!(fs::read_to_string(root.join("b-source-original.jsonl")))}),Some(retained))
        } else {
            // The exact released importer commits a real partial A partition.
            // Stop before bootstrap activation, without altering any app code.
            let spec=quota_spec(&quota)?;
            drop(route::open_store_during_bootstrap(&spec.module,&spec.source_identity,&spec.logical_path,&[quota.clone()])?);
            require!(!marker.exists(),"partial import unexpectedly activated A");
            (Value::Null,None)
        };
        let report=json!({"schemaVersion":1,"phase":phase,"producerVersion":env!("CARGO_PKG_VERSION"),
            "cfgTest":cfg!(test),"proofs":catalog_proofs(&a)?,"legacyQuota":quota,
            "legacyB":app_paths::multi_client_usage_database_path(),"bLedger":b_ledger,
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
        // This public snapshot API exists in every pinned release. Its pair
        // hashes typed rows, rowids, sqlite_sequence, canonical schema and the
        // module version. Do not inject newer production APIs into old code.
        let expected=checked!(Container::snapshot_digest_path(&quota));
        let imported=checked!(Container::open_existing(&a));
        let actual=checked!(imported.proof(&quota_spec(&quota)?));
        require!(format!("{}:{}",actual.schema_digest,actual.rows_digest)==expected,
            "frozen quota typed-content or schema digest differs after recovery");
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
    let b_ledger_proof=if old["formedB"]==true {
        assert_b()?;
        exercise_candidate_b(&root,&old,phase)?
    } else { Value::Null };
    route::bootstrap()?;
    Ok(json!({"status":"PASS","phase":phase,"producerVersion":old["producerVersion"],"candidateVersion":env!("CARGO_PKG_VERSION"),
        "cfgTest":cfg!(test),"scenario":old["phase"],"totals":[162,310],"oldTypedProofsPreserved":true,
        "oldBPreserved":old["formedB"],"bLedgerProof":b_ledger_proof,
        "crashWALPreserved":true,"rawDisappearanceRetainsHistory":true}))
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
