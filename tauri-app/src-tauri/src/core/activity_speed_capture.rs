//! Bounded activity-only persistence. No transcript, credentials or network.
use super::activity_speed_store::{self as store, ActivitySpeedFilter, ActivitySpeedSample};
use std::{collections::BTreeMap, sync::{Mutex, OnceLock, mpsc::{sync_channel, SyncSender}}};
use sha2::{Digest, Sha256};

static DISPLAY_MODE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn set_mode(mode:&str){DISPLAY_MODE.store(mode=="agentSpeed",std::sync::atomic::Ordering::Relaxed);}
pub(crate) fn mode()->&'static str{if DISPLAY_MODE.load(std::sync::atomic::Ordering::Relaxed){"agentSpeed"}else{"bar"}}

#[derive(Clone)]
struct Previous { time: f64, rates: Vec<(String,f64)> }
static PREVIOUS: OnceLock<Mutex<BTreeMap<String,Previous>>> = OnceLock::new();
static WRITER: OnceLock<SyncSender<Vec<ActivitySpeedSample>>> = OnceLock::new();
static ACTIVE_SOURCES: OnceLock<Mutex<BTreeMap<String,String>>> = OnceLock::new();

/// No raw paths are persisted in the activity index. Paths are already resolved
/// by source selection; normalization here is lexical, with no per-tick IO.
pub(crate) fn root_identity(root: &str) -> String {
    #[cfg(windows)]
    let normalized = root.replace('/', "\\").trim_end_matches('\\').to_lowercase();
    #[cfg(not(windows))]
    let normalized = root.trim_end_matches('/').to_string();
    format!("root-{:x}", Sha256::digest(normalized.as_bytes()))
}

pub(crate) fn record(client: &str, source: &str, mode: &str, rates: Vec<(String,f64)>, now: f64, available: bool) {
    // Unit-test monitors must never initialize a writer under a real user profile.
    if cfg!(test) { return; }
    if !now.is_finite() || now < 0.0 || !matches!(mode,"bar"|"agentSpeed") { return; }
    ACTIVE_SOURCES.get_or_init(Default::default).lock().unwrap_or_else(|p|p.into_inner())
        .insert(client.to_string(),source.to_string());
    let key=format!("{client}|{source}|{mode}");
    let mut values=PREVIOUS.get_or_init(Default::default).lock().unwrap_or_else(|p|p.into_inner());
    if !available { values.remove(&key); return; }
    let prefix=format!("{client}|");
    values.retain(|other,_| !other.starts_with(&prefix) || other.ends_with(&format!("|{mode}")));
    if values.get(&key).is_some_and(|v| now-v.time < 1.0) { return; }
    let old=values.insert(key.clone(),Previous{time:now,rates});
    if values.len()>128 { values.retain(|_,v| now-v.time<=60.0); }
    drop(values);
    let Some(old)=old else{return};
    let elapsed=now-old.time;
    if elapsed<=0.0 || elapsed>3.0 {return;}
    let batch:Vec<_>=old.rates.into_iter().filter(|(_,v)|v.is_finite()&&*v>0.0).map(|(model,rate)| {
        let id=format!("{:x}",Sha256::digest(format!("{key}|{model}|{}|{now}",old.time).as_bytes()));
        ActivitySpeedSample{id,source_identity:source.into(),display_mode:mode.into(),estimator_id:if client=="codex"&&mode=="bar"{"tokenbar"}else{"agent-speed"}.into(),estimator_version:"1".into(),metric_kind:"output-activity".into(),client:client.into(),model:if model.trim().is_empty(){"unknown".into()}else{model},started_at:old.time,ended_at:now,output_rate:rate,covered_seconds:elapsed}
    }).collect();
    if batch.is_empty(){return;}
    let sender=WRITER.get_or_init(|| {
        let (tx,rx)=sync_channel::<Vec<ActivitySpeedSample>>(256);
        let _ = std::thread::Builder::new().name("activity-speed-store".into()).spawn(move|| {
            let mut connection=None;
            while let Ok(batch)=rx.recv() {
                if connection.is_none(){connection=super::multi_client_usage::open_activity_module_connection().ok();}
                let Some(ref mut db)=connection else{continue};
                let now=batch.last().map(|s|s.ended_at).unwrap_or(0.0);
                if let Err(error)=store::add_samples(db,&batch,now){
                    eprintln!("activity speed write unavailable: {error}");
                }
            }
        }).map_err(|_|eprintln!("activity speed writer unavailable"));tx
    });
    if sender.try_send(batch).is_err(){eprintln!("activity speed coverage incomplete: bounded queue full");}
}

pub(crate) fn query(now:f64)->Result<serde_json::Value,String>{
    let active=ACTIVE_SOURCES.get_or_init(Default::default).lock().unwrap_or_else(|p|p.into_inner()).clone();
    if active.is_empty(){return Ok(serde_json::json!({"series":[]}));}
    let db=super::multi_client_usage::open_activity_module_connection()?;
    let mut series=Vec::new();
    for source in active.values().collect::<std::collections::BTreeSet<_>>() {
        let filter=ActivitySpeedFilter{source_identity:Some(source.clone()),display_mode:Some(mode().into()),trend_since:Some((now-2100.0).max(0.0)),..Default::default()};
        let result=store::query(&db,now,&filter,8).map_err(|e|e.to_string())?;
        series.extend(result.series.into_iter().filter(|row|active.get(&row.dimensions.client)==Some(&row.dimensions.source_identity)));
    }
    Ok(serde_json::json!({"series":series}))
}
