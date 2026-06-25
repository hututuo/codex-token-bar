use super::TokenEvent;
use crate::models::LocalDataWarning;
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;
#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

#[cfg(test)]
static SESSION_FULL_PARSE_COUNT: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug)]
struct ParsedUsage {
    input_tokens: u64,
    cached_input_tokens: u64,
    output_tokens: u64,
    total_tokens: u64,
}

#[derive(Clone, Debug)]
struct ParsedUsageLine {
    timestamp: OffsetDateTime,
    total: Option<ParsedUsage>,
    last: Option<ParsedUsage>,
}

pub(super) struct SessionParseResult {
    pub(super) events: Vec<TokenEvent>,
    pub(super) previous_total_tokens: Option<u64>,
    pub(super) consumed_size: u64,
}

pub(super) fn parse_session_file(
    file: &Path,
    session_id: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> Vec<TokenEvent> {
    parse_session_file_full_result(file, session_id, warnings).events
}

pub(super) fn parse_session_file_full_result(
    file: &Path,
    session_id: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> SessionParseResult {
    record_full_parse_for_testing();
    parse_session_file_range(file, session_id, 0, None, warnings)
}

pub(super) fn parse_session_file_range(
    file: &Path,
    session_id: &str,
    start_offset: u64,
    initial_previous_total: Option<u64>,
    warnings: &mut Vec<LocalDataWarning>,
) -> SessionParseResult {
    let handle = match fs::File::open(file) {
        Ok(handle) => handle,
        Err(error) => {
            warnings.push(jsonl_file_warning(format!(
                "读取会话文件失败：{}（{}）",
                file.display(),
                error
            )));
            return SessionParseResult {
                events: Vec::new(),
                previous_total_tokens: initial_previous_total,
                consumed_size: start_offset,
            };
        }
    };
    let mut handle = handle;
    if start_offset > 0 {
        if let Err(error) = handle.seek(SeekFrom::Start(start_offset)) {
            warnings.push(jsonl_file_warning(format!(
                "定位会话文件失败：{}（{}）",
                file.display(),
                error
            )));
            return SessionParseResult {
                events: Vec::new(),
                previous_total_tokens: initial_previous_total,
                consumed_size: start_offset,
            };
        }
    }
    let reader = BufReader::new(handle);
    let fork_replay_cutoff = if start_offset == 0 {
        fork_replay_cutoff(file)
    } else {
        None
    };
    let mut previous_total = initial_previous_total;
    let mut current_user_prompt = String::new();
    let mut assistant_fragments = Vec::<String>::new();
    let mut events = Vec::new();
    let mut consumed_size = start_offset;

    let mut reader = reader;
    loop {
        let mut line = String::new();
        let bytes_read = match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(bytes_read) => bytes_read,
            Err(error) => {
                warnings.push(jsonl_file_warning(format!(
                    "读取会话文件中断：{}（{}）",
                    file.display(),
                    error
                )));
                break;
            }
        };
        if !line.ends_with('\n') && !is_complete_json_line(&line) {
            break;
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if let Some(message) = extract_payload_message(line, "user_message") {
            current_user_prompt = message;
            assistant_fragments.clear();
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        }

        if let Some(message) = extract_payload_message(line, "agent_message") {
            assistant_fragments.push(message);
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        }

        if !line.contains("\"token_count\"") {
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        }
        let Some(usage_line) = parse_usage_line(line) else {
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        };
        if fork_replay_cutoff.is_some_and(|cutoff| usage_line.timestamp <= cutoff) {
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        }

        let total_tokens = usage_line.total.as_ref().map(|usage| usage.total_tokens);
        let last_tokens = usage_line.last.as_ref().map(|usage| usage.total_tokens);
        let delta = if let Some(total_tokens) = total_tokens {
            let delta = match previous_total {
                Some(previous_total) if total_tokens >= previous_total => {
                    total_tokens - previous_total
                }
                _ => last_tokens.unwrap_or(total_tokens),
            };
            previous_total = Some(total_tokens);
            delta
        } else {
            last_tokens.unwrap_or(0)
        };

        if delta == 0 {
            continue;
        }

        events.push(TokenEvent {
            timestamp: usage_line.timestamp,
            session_id: session_id.to_string(),
            tokens: delta,
            input_tokens: usage_line.last.as_ref().map_or(0, |usage| usage.input_tokens),
            cached_input_tokens: usage_line
                .last
                .as_ref()
                .map_or(0, |usage| usage.cached_input_tokens),
            output_tokens: usage_line.last.as_ref().map_or(0, |usage| usage.output_tokens),
            user_prompt: excerpt(&current_user_prompt, 180),
            assistant_response: excerpt(&assistant_fragments.join(" "), 220),
        });
        assistant_fragments.clear();
        consumed_size = consumed_size.saturating_add(bytes_read as u64);
    }

    SessionParseResult {
        events,
        previous_total_tokens: previous_total,
        consumed_size,
    }
}

#[cfg(test)]
pub(super) fn reset_session_full_parse_count_for_testing() {
    SESSION_FULL_PARSE_COUNT.store(0, Ordering::Relaxed);
}

#[cfg(test)]
pub(super) fn session_full_parse_count_for_testing() -> u64 {
    SESSION_FULL_PARSE_COUNT.load(Ordering::Relaxed)
}

#[cfg(test)]
fn record_full_parse_for_testing() {
    SESSION_FULL_PARSE_COUNT.fetch_add(1, Ordering::Relaxed);
}

#[cfg(not(test))]
fn record_full_parse_for_testing() {}

fn is_complete_json_line(line: &str) -> bool {
    serde_json::from_str::<Value>(line).is_ok()
}

fn extract_payload_message(line: &str, expected_type: &str) -> Option<String> {
    if !line.contains("\"payload\"") || !line.contains(expected_type) {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    let payload = value.get("payload")?;
    if payload.get("type")?.as_str()? != expected_type {
        return None;
    }
    let normalized = normalize_excerpt_text(payload.get("message")?.as_str()?);
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

fn excerpt(value: &str, limit: usize) -> String {
    let normalized = normalize_excerpt_text(value);
    if normalized.chars().count() <= limit {
        return normalized;
    }
    let mut text = normalized.chars().take(limit).collect::<String>();
    text.push('…');
    text
}

fn normalize_excerpt_text(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}

fn fork_replay_cutoff(file: &Path) -> Option<OffsetDateTime> {
    let handle = fs::File::open(file).ok()?;
    let mut reader = BufReader::new(handle);
    let mut first_line = String::new();
    if reader.read_line(&mut first_line).ok()? == 0 {
        return None;
    }
    if !first_line.contains("session_meta") || !first_line.contains("forked_from_id") {
        return None;
    }
    let value: Value = serde_json::from_str(&first_line).ok()?;
    if value.get("type")?.as_str()? != "session_meta" {
        return None;
    }
    let payload = value.get("payload")?;
    let forked_from_id = payload.get("forked_from_id")?.as_str()?.trim();
    if forked_from_id.is_empty() {
        return None;
    }
    let timestamp = value
        .get("timestamp")
        .and_then(Value::as_str)
        .or_else(|| payload.get("timestamp").and_then(Value::as_str))?;
    parse_timestamp(timestamp).map(|date| date + Duration::seconds(30))
}

fn parse_usage_line(line: &str) -> Option<ParsedUsageLine> {
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("type")?.as_str()? != "event_msg" {
        return None;
    }
    let timestamp = parse_timestamp(value.get("timestamp")?.as_str()?)?;
    let payload = value.get("payload")?;
    if payload.get("type")?.as_str()? != "token_count" {
        return None;
    }
    let info = payload.get("info")?;
    let total = parse_usage(info.get("total_token_usage"));
    let last = parse_usage(info.get("last_token_usage"));
    if total.is_none() && last.is_none() {
        return None;
    }
    Some(ParsedUsageLine {
        timestamp,
        total,
        last,
    })
}

fn parse_usage(value: Option<&Value>) -> Option<ParsedUsage> {
    let value = value?;
    Some(ParsedUsage {
        input_tokens: number_field(value, "input_tokens").unwrap_or(0),
        cached_input_tokens: number_field(value, "cached_input_tokens").unwrap_or(0),
        output_tokens: number_field(value, "output_tokens").unwrap_or(0),
        total_tokens: number_field(value, "total_tokens")?,
    })
}

fn number_field(value: &Value, key: &str) -> Option<u64> {
    let value = value.get(key)?;
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|number| u64::try_from(number).ok()))
        .or_else(|| value.as_str().and_then(|number| number.parse().ok()))
}

fn parse_timestamp(value: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value, &Rfc3339).ok()
}

fn jsonl_file_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "jsonl_file".into(),
        message,
    }
}
