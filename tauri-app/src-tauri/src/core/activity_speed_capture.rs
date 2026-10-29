//! Tracks active sources for legacy activity-speed reads. New activity-speed
//! samples are intentionally kept in frontend memory and are not persisted.
use super::activity_speed_store::{self as store, ActivitySpeedFilter};
use std::{collections::BTreeMap, sync::{Mutex, OnceLock}};
use sha2::{Digest, Sha256};

static DISPLAY_MODE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn set_mode(mode:&str){DISPLAY_MODE.store(mode=="agentSpeed",std::sync::atomic::Ordering::Relaxed);}
pub(crate) fn mode()->&'static str{if DISPLAY_MODE.load(std::sync::atomic::Ordering::Relaxed){"agentSpeed"}else{"bar"}}

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

pub(crate) fn record(client: &str, source: &str, mode: &str, _rates: Vec<(String,f64)>, now: f64, _available: bool) {
    if !now.is_finite() || now < 0.0 || !matches!(mode,"bar"|"agentSpeed") { return; }
    register_active_source(
        &mut ACTIVE_SOURCES.get_or_init(Default::default).lock().unwrap_or_else(|p|p.into_inner()),
        client,
        source,
    );
}

fn register_active_source(active: &mut BTreeMap<String,String>, client: &str, source: &str) {
    active.insert(client.to_string(), source.to_string());
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

/// Scoped raw-sample half-minute history for the Agent Speed chart. This stays on
/// the existing activity database and applies the active-source fence independently
/// of the selected speed-strip display mode.
pub(crate) fn activity_history(now:f64, window_seconds:u64)->Result<serde_json::Value,String>{
    if !matches!(window_seconds,1_800|86_400){return Err("unsupported_activity_history_window".into());}
    let active=ACTIVE_SOURCES.get_or_init(Default::default).lock().unwrap_or_else(|p|p.into_inner()).clone();
    if active.is_empty(){
        let current=ACTIVE_SOURCES.get_or_init(Default::default).lock().unwrap_or_else(|p|p.into_inner()).clone();
        ensure_same_active_sources(&active,&current)?;
        return Ok(serde_json::json!({"series":[]}));
    }
    let db=super::multi_client_usage::open_activity_module_connection()?;
    let mut series=Vec::new();
    for source in active.values().collect::<std::collections::BTreeSet<_>>() {
        let filter=ActivitySpeedFilter{source_identity:Some(source.clone()),display_mode:Some("agentSpeed".into()),..Default::default()};
        let result=store::activity_history(&db,now,&filter,window_seconds).map_err(|e|e.to_string())?;
        series.extend(result.series.into_iter().filter(|row|active.get(&row.dimensions.client)==Some(&row.dimensions.source_identity)));
    }
    let current=ACTIVE_SOURCES.get_or_init(Default::default).lock().unwrap_or_else(|p|p.into_inner()).clone();
    ensure_same_active_sources(&active,&current)?;
    Ok(serde_json::json!({"series":series}))
}

fn ensure_same_active_sources(
    expected:&BTreeMap<String,String>,
    current:&BTreeMap<String,String>,
)->Result<(),String>{
    if expected==current { Ok(()) } else { Err("source_changed".into()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activity_capture_tracks_source_without_persisting_supplied_rates() {
        record("codex", "source-a", "bar", vec![("model".into(), 88.0)], 10.0, true);
        // This is the complete recording action: rate payloads do not enter a
        // queue or database writer. Active-source state remains for legacy reads.
        assert_eq!(
            ACTIVE_SOURCES.get().unwrap().lock().unwrap().get("codex").map(String::as_str),
            Some("source-a"),
        );
    }

    #[test]
    fn activity_history_rejects_a_changed_active_source_snapshot() {
        let expected = BTreeMap::from([("codex".into(), "source-a".into())]);
        let unchanged = expected.clone();
        let changed = BTreeMap::from([("codex".into(), "source-b".into())]);
        assert!(ensure_same_active_sources(&expected, &unchanged).is_ok());
        assert_eq!(ensure_same_active_sources(&expected, &changed).unwrap_err(), "source_changed");
    }
}
