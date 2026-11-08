//! Diagnostics have no business-store dependency. Fixed-schema events only;
//! the collector never opens SQLite, imports sources, or follows repair routes.
mod journal;
mod collect;
mod files;
mod privacy;
pub(crate) use journal::{record, flush};
pub(crate) use collect::{cli, export, Configuration};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all="camelCase")]
pub(crate) enum Area { Startup, Updater, Installer, Migration, Index, Refresh, BackendProgress, UiProgress, Storage, Frontend, Shutdown }
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all="camelCase")]
pub(crate) enum Phase { Started, Progress, Ready, Failed, Waiting, Checking, Available, Downloading, Downloaded,
    Verifying, Replacing, Launched, Confirmed, Cancelled, Preparing, Importing, Activating, Retained, Completed,
    Copied, Migrated, Validated, Switching, Switched, Retiring }

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Event {
    schema: u32, session: String, sequence: u64, at: u64, area: Area, phase: Phase,
    version: String, build: String, metrics: BTreeMap<String,i64>,
    #[serde(skip_serializing_if="Option::is_none")] attempt: Option<String>,
    #[serde(rename="targetVersion",skip_serializing_if="Option::is_none")] target_version: Option<String>,
    #[serde(rename="targetBuild",skip_serializing_if="Option::is_none")] target_build: Option<String>,
}
fn version(value: &str) -> String {
    if !value.is_empty() && value.len()<=32 && value.bytes().all(|b|b.is_ascii_digit()||b==b'.')
        && value.split('.').all(|p|!p.is_empty()&&p.len()<=10) {value.into()}else{"unknown".into()}
}
fn allowed_metric(key: &str) -> bool {
    matches!(key,"completed"|"total"|"elapsed_ms"|"code"|"retry"|"generation"|"published_generation"|"schema_version"|
        "files"|"pending"|"available"|"unavailable"|"staged"|"consumed"|"numeric_ready"|"detail_ready"|"sequence"|"pid"|"bytes"|"dropped"|"backend_at"|"ui_at"|"stage_code")
}
impl Event {
    fn new(session:&str, sequence:u64, area:Area, phase:Phase, metrics:&[(&str,i64)]) -> Self {
        Self {schema:1,session:session.into(),sequence,at:now_ms(),area,phase,version:version(env!("CARGO_PKG_VERSION")),build:"unknown".into(),
            metrics:metrics.iter().filter(|(k,_)|allowed_metric(k)).map(|(k,v)|(k.to_string(),*v)).collect(),
            attempt:None,target_version:None,target_build:None}
    }
    fn sanitized(bytes:&[u8])->Option<Self> {
        if bytes.len()>8192{return None}
        let mut event:Self=serde_json::from_slice(bytes).ok()?;
        if event.schema!=1{return None}
        event.session=uuid::Uuid::parse_str(&event.session).ok()?.to_string();
        event.version=version(&event.version);event.build=version(&event.build);
        event.metrics.retain(|k,_|allowed_metric(k));
        event.attempt=event.attempt.and_then(|s|uuid::Uuid::parse_str(&s).ok().map(|u|u.to_string()));
        event.target_version=event.target_version.map(|v|version(&v));event.target_build=event.target_build.map(|v|version(&v));
        Some(event)
    }
}
fn now_ms()->u64 {std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis().min(u64::MAX as u128) as u64}

#[cfg(test)] mod tests;
