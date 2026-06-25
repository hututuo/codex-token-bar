use super::TokenEvent;
use crate::models::LocalDataWarning;
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

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

pub(super) fn parse_session_file(
    file: &Path,
    session_id: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> Vec<TokenEvent> {
    let handle = match fs::File::open(file) {
        Ok(handle) => handle,
        Err(error) => {
            warnings.push(jsonl_file_warning(format!(
                "读取会话文件失败：{}（{}）",
                file.display(),
                error
            )));
            return Vec::new();
        }
    };
    let reader = BufReader::new(handle);
    let fork_replay_cutoff = fork_replay_cutoff(file);
    let mut previous_total = None;
    let mut current_user_prompt = String::new();
    let mut assistant_fragments = Vec::<String>::new();
    let mut events = Vec::new();

    for line in reader.lines() {
        let line = match line {
            Ok(line) => line,
            Err(error) => {
                warnings.push(jsonl_file_warning(format!(
                    "读取会话文件中断：{}（{}）",
                    file.display(),
                    error
                )));
                break;
            }
        };
        if let Some(message) = extract_payload_message(&line, "user_message") {
            current_user_prompt = message;
            assistant_fragments.clear();
            continue;
        }

        if let Some(message) = extract_payload_message(&line, "agent_message") {
            assistant_fragments.push(message);
            continue;
        }

        if !line.contains("\"token_count\"") {
            continue;
        }
        let Some(usage_line) = parse_usage_line(&line) else {
            continue;
        };
        if fork_replay_cutoff.is_some_and(|cutoff| usage_line.timestamp <= cutoff) {
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
    }

    events
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
