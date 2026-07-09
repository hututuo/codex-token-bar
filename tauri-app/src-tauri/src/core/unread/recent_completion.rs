use super::session_files::{
    contains_subagent_text, jsonl_files, session_meta_payload, value_contains_subagent,
};
use crate::models::UnreadSummary;
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const RECENT_COMPLETION_LOOKBACK_SECONDS: f64 = 30.0;
const RECENT_COMPLETION_FILE_LIMIT: usize = 64;
const RECENT_COMPLETION_TAIL_BYTE_LIMIT: u64 = 4 * 1024 * 1024;

pub(super) fn recent_completion_summary(
    codex_home: &Path,
    acknowledged_markers: &HashSet<String>,
) -> UnreadSummary {
    let count = count_recent_completed_user_tasks(codex_home, acknowledged_markers);
    let active = count > 0;
    UnreadSummary {
        active,
        count: count as u32,
        label: if active {
            "刚有任务完成".into()
        } else {
            "暂无未读完成会话".into()
        },
        detail: if active {
            format!(
                "Codex 未读状态不可用，按最近 {} 秒内完成的 {} 个会话兜底。",
                RECENT_COMPLETION_LOOKBACK_SECONDS as u32,
                count
            )
        } else {
            format!(
                "Codex 未读状态不可用，最近 {} 秒没有可见会话完成。",
                RECENT_COMPLETION_LOOKBACK_SECONDS as u32
            )
        },
        source: "recent_task_complete".into(),
    }
}

pub(super) fn recent_completion_markers(codex_home: &Path) -> HashSet<String> {
    let now = current_time_seconds();
    recent_session_files(&codex_home.join("sessions"), now)
        .into_iter()
        .flat_map(|file| recent_completed_user_task_markers(&file, now))
        .collect()
}

fn count_recent_completed_user_tasks(
    codex_home: &Path,
    acknowledged_markers: &HashSet<String>,
) -> usize {
    let now = current_time_seconds();
    recent_session_files(&codex_home.join("sessions"), now)
        .into_iter()
        .filter(|file| {
            recent_completed_user_task_markers(file, now)
                .into_iter()
                .any(|marker| !acknowledged_markers.contains(&marker))
        })
        .count()
}

fn recent_session_files(root: &Path, now: f64) -> Vec<PathBuf> {
    let cutoff = now - RECENT_COMPLETION_LOOKBACK_SECONDS;
    let mut files = Vec::<(PathBuf, f64)>::new();
    for file in jsonl_files(root) {
        let modified_at = fs::metadata(&file)
            .ok()
            .and_then(|metadata| metadata.modified().ok())
            .and_then(system_time_seconds)
            .unwrap_or(0.0);
        if modified_at >= cutoff {
            files.push((file, modified_at));
        }
    }
    files.sort_by(|left, right| right.1.total_cmp(&left.1));
    files
        .into_iter()
        .take(RECENT_COMPLETION_FILE_LIMIT)
        .map(|(file, _)| file)
        .collect()
}

fn recent_completed_user_task_markers(file: &Path, now: f64) -> Vec<String> {
    let Some(payload) = session_meta_payload(file) else {
        return Vec::new();
    };
    let Some(thread_id) = payload.get("id").and_then(Value::as_str) else {
        return Vec::new();
    };
    let thread_source = payload
        .get("thread_source")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if contains_subagent_text(thread_source) || value_contains_subagent(payload.get("source")) {
        return Vec::new();
    }

    let cutoff = now - RECENT_COMPLETION_LOOKBACK_SECONDS;
    tail_lines(file)
        .into_iter()
        .filter_map(|line| recent_task_complete_marker(&line, thread_id))
        .filter_map(|(timestamp, marker)| (timestamp >= cutoff).then_some(marker))
        .collect()
}

fn tail_lines(file: &Path) -> Vec<String> {
    let Ok(mut handle) = fs::File::open(file) else {
        return Vec::new();
    };
    let size = handle.metadata().map(|metadata| metadata.len()).unwrap_or(0);
    let start = size.saturating_sub(RECENT_COMPLETION_TAIL_BYTE_LIMIT);
    if handle.seek(SeekFrom::Start(start)).is_err() {
        return Vec::new();
    }
    let mut data = Vec::new();
    if handle.read_to_end(&mut data).is_err() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&data);
    let mut lines = text.lines();
    if start > 0 {
        let _ = lines.next();
    }
    lines.map(str::to_string).collect()
}

fn recent_task_complete_marker(line: &str, thread_id: &str) -> Option<(f64, String)> {
    if !line.contains("event_msg") || !line.contains("task_complete") {
        return None;
    }
    let object: Value = serde_json::from_str(line).ok()?;
    if object.get("type")?.as_str()? != "event_msg" {
        return None;
    }
    let payload = object.get("payload")?;
    if payload.get("type")?.as_str()? != "task_complete" {
        return None;
    }
    let timestamp = number(payload.get("completed_at"))
        .or_else(|| parse_timestamp(object.get("timestamp")?.as_str()?))?;
    let turn = payload
        .get("turn_id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| format!("{timestamp:.3}"));
    Some((timestamp, format!("{thread_id}:{turn}")))
}

fn number(value: Option<&Value>) -> Option<f64> {
    match value {
        Some(Value::Number(number)) => number.as_f64(),
        Some(Value::String(text)) => text.parse::<f64>().ok(),
        _ => None,
    }
}

fn parse_timestamp(value: &str) -> Option<f64> {
    OffsetDateTime::parse(value, &Rfc3339)
        .ok()
        .map(|date| date.unix_timestamp() as f64 + f64::from(date.nanosecond()) / 1_000_000_000.0)
}

pub(super) fn current_time_seconds() -> f64 {
    system_time_seconds(SystemTime::now()).unwrap_or(0.0)
}

fn system_time_seconds(value: SystemTime) -> Option<f64> {
    value
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs_f64())
}

#[cfg(test)]
pub(super) fn lookback_seconds() -> f64 {
    RECENT_COMPLETION_LOOKBACK_SECONDS
}
