use super::TokenEvent;
use crate::models::LocalDataWarning;
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;
#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

const FORK_REPLAY_EXIT_GRACE: Duration = Duration::seconds(2);
pub(super) const RECENT_USAGE_FINGERPRINT_LIMIT: usize = 4_096;
pub(super) type UsageSnapshotFingerprint = [u64; 9];

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

#[derive(Clone, Debug)]
struct ParsedMessageLine {
    timestamp: OffsetDateTime,
    message: String,
}

pub(super) struct SessionParseResult {
    pub(super) events: Vec<TokenEvent>,
    pub(super) limit_exceeded: Option<String>,
    pub(super) previous_total_tokens: Option<u64>,
    pub(super) consumed_size: u64,
    pub(super) ended_with_newline: bool,
    pub(super) fork_replay_active: bool,
    pub(super) last_skipped_fork_replay_token_at: Option<OffsetDateTime>,
    pub(super) recent_usage_fingerprints: Vec<UsageSnapshotFingerprint>,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct ForkReplayState {
    pub(super) active: bool,
    pub(super) last_skipped_token_at: Option<OffsetDateTime>,
}

pub(super) fn parse_session_file_full_result(
    file: &Path,
    session_id: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> SessionParseResult {
    parse_session_file_full_result_limited(
        file,
        session_id,
        u64::MAX,
        usize::MAX,
        usize::MAX,
        warnings,
    )
}

pub(super) fn parse_session_file_full_result_limited(
    file: &Path,
    session_id: &str,
    source_read_limit: u64,
    line_limit: usize,
    event_limit: usize,
    warnings: &mut Vec<LocalDataWarning>,
) -> SessionParseResult {
    record_full_parse_for_testing();
    parse_session_file_range_limited(
        file,
        session_id,
        0,
        None,
        None,
        None,
        source_read_limit,
        line_limit,
        event_limit,
        warnings,
    )
}

pub(super) fn parse_session_file_range_limited(
    file: &Path,
    session_id: &str,
    start_offset: u64,
    initial_previous_total: Option<u64>,
    initial_fork_replay_state: Option<ForkReplayState>,
    initial_recent_usage_fingerprints: Option<&[UsageSnapshotFingerprint]>,
    source_read_limit: u64,
    line_limit: usize,
    event_limit: usize,
    warnings: &mut Vec<LocalDataWarning>,
) -> SessionParseResult {
    let handle = match fs::File::open(file) {
        Ok(handle) => handle,
        Err(error) => {
            let message = format!(
                "读取会话文件失败：{}（{}）",
                file.display(),
                error
            );
            warnings.push(jsonl_file_warning(message.clone()));
            return SessionParseResult {
                events: Vec::new(),
                limit_exceeded: Some(message),
                previous_total_tokens: initial_previous_total,
                consumed_size: start_offset,
                ended_with_newline: true,
                fork_replay_active: false,
                last_skipped_fork_replay_token_at: None,
                recent_usage_fingerprints: initial_recent_usage_fingerprints
                    .unwrap_or_default()
                    .to_vec(),
            };
        }
    };
    let mut handle = handle;
    if start_offset > 0 {
        if let Err(error) = handle.seek(SeekFrom::Start(start_offset)) {
            let message = format!(
                "定位会话文件失败：{}（{}）",
                file.display(),
                error
            );
            warnings.push(jsonl_file_warning(message.clone()));
            return SessionParseResult {
                events: Vec::new(),
                limit_exceeded: Some(message),
                previous_total_tokens: initial_previous_total,
                consumed_size: start_offset,
                ended_with_newline: true,
                fork_replay_active: false,
                last_skipped_fork_replay_token_at: None,
                recent_usage_fingerprints: initial_recent_usage_fingerprints
                    .unwrap_or_default()
                    .to_vec(),
            };
        }
    }
    let reader = BufReader::new(handle.take(source_read_limit));
    let mut fork_replay_started_at = None;
    let mut fork_replay_active = initial_fork_replay_state
        .map(|state: ForkReplayState| state.active)
        .unwrap_or(false);
    let mut last_skipped_fork_replay_token_at =
        initial_fork_replay_state.and_then(|state: ForkReplayState| state.last_skipped_token_at);
    let mut previous_total = initial_previous_total;
    let mut recent_usage_fingerprints =
        RecentUsageFingerprintBuffer::new(initial_recent_usage_fingerprints.unwrap_or_default());
    let mut current_user_prompt = String::new();
    let mut assistant_excerpt = String::new();
    let mut events = Vec::new();
    let mut consumed_size = start_offset;
    let mut ended_with_newline = true;
    let mut limit_exceeded = None;

    let mut reader = reader;
    let mut line_bytes = Vec::new();
    loop {
        let bytes_read = match read_bounded_line(&mut reader, &mut line_bytes, line_limit) {
            Ok(0) => break,
            Ok(bytes_read) => bytes_read,
            Err(BoundedLineReadError::TooLong) => {
                let message = format!(
                    "会话 JSONL 单行超过 {} MiB：{}",
                    line_limit / 1024 / 1024,
                    file.display()
                );
                warnings.push(jsonl_file_warning(message.clone()));
                limit_exceeded = Some(message);
                break;
            }
            Err(BoundedLineReadError::Io(error)) => {
                let message = format!(
                    "读取会话文件中断：{}（{}）",
                    file.display(),
                    error
                );
                warnings.push(jsonl_file_warning(message.clone()));
                limit_exceeded = Some(message);
                break;
            }
        };
        let line_ended_with_newline = line_bytes.last().is_some_and(|byte| *byte == b'\n');
        let line = match std::str::from_utf8(&line_bytes) {
            Ok(line) => line,
            Err(error) => {
                let message = format!(
                    "会话 JSONL 不是 UTF-8：{}（{}）",
                    file.display(),
                    error
                );
                warnings.push(jsonl_file_warning(message.clone()));
                limit_exceeded = Some(message);
                break;
            }
        };
        if !line_ended_with_newline && !is_complete_json_line(&line) {
            ended_with_newline = false;
            break;
        }
        ended_with_newline = line_ended_with_newline;
        let line = line.trim_end_matches(['\r', '\n']);
        if start_offset == 0 && fork_replay_started_at.is_none() {
            if let Some(timestamp) = forked_session_replay_started_at_line(line) {
                fork_replay_started_at = Some(timestamp);
                fork_replay_active = true;
            }
        }
        if let Some(message_line) = parse_payload_message_line(line, "user_message", 180) {
            if fork_replay_active {
                let replay_reference = last_skipped_fork_replay_token_at.or(fork_replay_started_at);
                if replay_reference.is_some_and(|reference| {
                    message_line.timestamp - reference > FORK_REPLAY_EXIT_GRACE
                }) {
                    fork_replay_active = false;
                }
            }
            current_user_prompt = message_line.message;
            assistant_excerpt.clear();
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        }

        if let Some(message_line) = parse_payload_message_line(line, "agent_message", 220) {
            append_excerpt(&mut assistant_excerpt, &message_line.message, 220);
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
        let total_tokens = usage_line.total.as_ref().map(|usage| usage.total_tokens);
        let previous_high_water = previous_total;
        // Forks/subagents can interleave several cumulative counters in one JSONL. Keeping the
        // high-water mark prevents a lower stream from creating a false jump when a higher one
        // appears again.
        if let Some(total_tokens) = total_tokens {
            previous_total =
                Some(previous_total.map_or(total_tokens, |previous| previous.max(total_tokens)));
        }
        // Timestamp is deliberately excluded so a replayed copy remains a duplicate even when
        // Codex emits it at a later time.
        let is_new_snapshot = usage_snapshot_fingerprint(&usage_line).map_or(true, |fingerprint| {
            recent_usage_fingerprints.insert_if_new(fingerprint)
        });
        if fork_replay_active {
            last_skipped_fork_replay_token_at = Some(usage_line.timestamp);
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        }

        if !is_new_snapshot {
            consumed_size = consumed_size.saturating_add(bytes_read as u64);
            continue;
        }

        let last_tokens = usage_line.last.as_ref().map(|usage| usage.total_tokens);
        let delta = if last_tokens.is_some_and(|tokens| tokens > 0) {
            last_tokens.unwrap_or_default()
        } else if let Some(total_tokens) = total_tokens {
            previous_high_water.map_or(total_tokens, |previous| {
                total_tokens.saturating_sub(previous)
            })
        } else {
            0
        };

        consumed_size = consumed_size.saturating_add(bytes_read as u64);
        if delta == 0 {
            continue;
        }

        if events.len() >= event_limit {
            let message = format!(
                "会话 token 事件超过本次刷新安全上限（{} 条）：{}",
                event_limit,
                file.display()
            );
            warnings.push(jsonl_file_warning(message.clone()));
            limit_exceeded = Some(message);
            break;
        }
        events.push(TokenEvent {
            timestamp: usage_line.timestamp,
            session_id: session_id.to_string(),
            tokens: delta,
            input_tokens: usage_line
                .last
                .as_ref()
                .map_or(0, |usage| usage.input_tokens),
            cached_input_tokens: usage_line
                .last
                .as_ref()
                .map_or(0, |usage| usage.cached_input_tokens),
            output_tokens: usage_line
                .last
                .as_ref()
                .map_or(0, |usage| usage.output_tokens),
            user_prompt: current_user_prompt.clone(),
            assistant_response: assistant_excerpt.clone(),
        });
        assistant_excerpt.clear();
    }

    SessionParseResult {
        events,
        limit_exceeded,
        previous_total_tokens: previous_total,
        consumed_size,
        ended_with_newline,
        fork_replay_active,
        last_skipped_fork_replay_token_at,
        recent_usage_fingerprints: recent_usage_fingerprints.ordered_values(),
    }
}

struct RecentUsageFingerprintBuffer {
    values: Vec<UsageSnapshotFingerprint>,
    next_replacement_index: usize,
    seen: HashSet<UsageSnapshotFingerprint>,
}

impl RecentUsageFingerprintBuffer {
    fn new(initial_values: &[UsageSnapshotFingerprint]) -> Self {
        let mut buffer = Self {
            values: Vec::new(),
            next_replacement_index: 0,
            seen: HashSet::new(),
        };
        for fingerprint in initial_values
            .iter()
            .rev()
            .take(RECENT_USAGE_FINGERPRINT_LIMIT)
            .rev()
        {
            buffer.insert_if_new(*fingerprint);
        }
        buffer
    }

    fn insert_if_new(&mut self, fingerprint: UsageSnapshotFingerprint) -> bool {
        if !self.seen.insert(fingerprint) {
            return false;
        }
        if self.values.len() < RECENT_USAGE_FINGERPRINT_LIMIT {
            self.values.push(fingerprint);
        } else {
            self.seen.remove(&self.values[self.next_replacement_index]);
            self.values[self.next_replacement_index] = fingerprint;
            self.next_replacement_index =
                (self.next_replacement_index + 1) % RECENT_USAGE_FINGERPRINT_LIMIT;
        }
        true
    }

    fn ordered_values(self) -> Vec<UsageSnapshotFingerprint> {
        if self.values.len() < RECENT_USAGE_FINGERPRINT_LIMIT || self.next_replacement_index == 0 {
            return self.values;
        }
        self.values[self.next_replacement_index..]
            .iter()
            .chain(self.values[..self.next_replacement_index].iter())
            .copied()
            .collect()
    }
}

fn usage_snapshot_fingerprint(usage_line: &ParsedUsageLine) -> Option<UsageSnapshotFingerprint> {
    let total = usage_line.total.as_ref()?;
    let mut fingerprint = [0; 9];
    fingerprint[..4].copy_from_slice(&[
        total.input_tokens,
        total.cached_input_tokens,
        total.output_tokens,
        total.total_tokens,
    ]);
    if let Some(last) = usage_line.last.as_ref() {
        fingerprint[4] = 1;
        fingerprint[5..].copy_from_slice(&[
            last.input_tokens,
            last.cached_input_tokens,
            last.output_tokens,
            last.total_tokens,
        ]);
    }
    Some(fingerprint)
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

enum BoundedLineReadError {
    Io(std::io::Error),
    TooLong,
}

fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    line: &mut Vec<u8>,
    limit: usize,
) -> Result<usize, BoundedLineReadError> {
    line.clear();
    loop {
        let available = reader.fill_buf().map_err(BoundedLineReadError::Io)?;
        if available.is_empty() {
            return Ok(line.len());
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(available.len(), |index| index.saturating_add(1));
        if line.len().saturating_add(consumed) > limit {
            return Err(BoundedLineReadError::TooLong);
        }
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if newline.is_some() {
            return Ok(line.len());
        }
    }
}

fn parse_payload_message_line(
    line: &str,
    expected_type: &str,
    excerpt_limit: usize,
) -> Option<ParsedMessageLine> {
    if !line.contains("\"payload\"") || !line.contains(expected_type) {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    let timestamp = parse_timestamp(value.get("timestamp")?.as_str()?)?;
    let payload = value.get("payload")?;
    if payload.get("type")?.as_str()? != expected_type {
        return None;
    }
    let normalized = excerpt(payload.get("message")?.as_str()?, excerpt_limit);
    if normalized.is_empty() {
        None
    } else {
        Some(ParsedMessageLine {
            timestamp,
            message: normalized,
        })
    }
}

fn excerpt(value: &str, limit: usize) -> String {
    let mut text = String::new();
    let mut pending_space = false;
    let mut count = 0;
    for character in value.chars() {
        if character.is_whitespace() {
            pending_space = !text.is_empty();
            continue;
        }
        if count >= limit {
            text.push('…');
            break;
        }
        if pending_space {
            text.push(' ');
            pending_space = false;
        }
        text.push(character);
        count = count.saturating_add(1);
    }
    text
}

fn append_excerpt(target: &mut String, next: &str, limit: usize) {
    if target.is_empty() {
        *target = excerpt(next, limit);
        return;
    }
    if target.chars().count() >= limit {
        return;
    }
    let remaining = limit.saturating_sub(target.chars().count());
    let suffix = excerpt(next, remaining);
    if suffix.is_empty() {
        return;
    }
    target.push(' ');
    target.push_str(&suffix);
}

fn forked_session_replay_started_at_line(line: &str) -> Option<OffsetDateTime> {
    if !line.contains("session_meta") || !line.contains("forked_from_id") {
        return None;
    }
    let Some(value) = serde_json::from_str::<Value>(line).ok() else {
        return None;
    };
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return None;
    }
    let timestamp = parse_timestamp(value.get("timestamp")?.as_str()?)?;
    let Some(payload) = value.get("payload") else {
        return None;
    };
    payload
        .get("forked_from_id")
        .and_then(Value::as_str)
        .is_some_and(|forked_from_id| !forked_from_id.trim().is_empty())
        .then_some(timestamp)
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
