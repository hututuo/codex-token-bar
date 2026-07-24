#[cfg(test)]
use super::TokenEvent;
use crate::models::LocalDataWarning;
use serde_json::Value;
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

const FORK_REPLAY_EXIT_GRACE: Duration = Duration::seconds(2);
pub(super) const EXACT_INDEX_CHUNK_SIZE: u64 = 4 * 1024 * 1024;
pub(super) type UsageSnapshotFingerprint = [u64; 9];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct SourceByteRange {
    pub(super) start: u64,
    pub(super) end: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct ExactEventSourceOffsets {
    pub(super) user_prompt: Option<SourceByteRange>,
    pub(super) assistant_response: Option<SourceByteRange>,
}

#[derive(Clone, Debug)]
pub(super) struct ExactTokenEvent {
    pub(super) timestamp: OffsetDateTime,
    pub(super) session_id: String,
    pub(super) tokens: u64,
    pub(super) input_tokens: u64,
    pub(super) cached_input_tokens: u64,
    pub(super) output_tokens: u64,
    pub(super) source_offsets: ExactEventSourceOffsets,
}

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

#[cfg(test)]
pub(super) struct SessionParseResult {
    pub(super) events: Vec<TokenEvent>,
    pub(super) previous_total_tokens: Option<u64>,
    pub(super) fork_replay_active: bool,
}

#[derive(Clone, Debug)]
pub(super) struct ExactSessionParseResult {
    pub(super) prefix_sha256: [u8; 32],
    pub(super) bytes_read: u64,
    pub(super) resume_offset: u64,
    pub(super) state: ExactSessionParserState,
    pub(super) chunk_hashes: Vec<ExactChunkHash>,
    pub(super) validation_chunk_hash: Option<ExactChunkHash>,
    #[cfg(test)]
    pub(super) event_count: u64,
    #[cfg(test)]
    pub(super) previous_total_tokens: Option<u64>,
    #[cfg(test)]
    pub(super) fork_replay_active: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct ExactSessionParserState {
    pub(super) previous_total_tokens: Option<u64>,
    pub(super) fork_replay_started_at: Option<OffsetDateTime>,
    pub(super) fork_replay_active: bool,
    pub(super) last_skipped_fork_replay_token_at: Option<OffsetDateTime>,
    pub(super) current_user_prompt: Option<SourceByteRange>,
    pub(super) assistant_response: Option<SourceByteRange>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ExactChunkHash {
    pub(super) index: u64,
    pub(super) byte_count: u64,
    pub(super) sha256: [u8; 32],
}

pub(super) trait ExactSessionEventSink {
    fn insert_fingerprint(
        &mut self,
        fingerprint: &UsageSnapshotFingerprint,
    ) -> Result<bool, String>;

    fn insert_event(&mut self, event: &ExactTokenEvent) -> Result<(), String>;
}

pub(super) fn stream_session_file_exact(
    file: &Path,
    handle: &mut fs::File,
    prefix_size: u64,
    session_id: &str,
    sink: &mut impl ExactSessionEventSink,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<ExactSessionParseResult, String> {
    stream_session_file_exact_from(
        file,
        handle,
        0,
        0,
        prefix_size,
        None,
        ExactSessionParserState::default(),
        session_id,
        sink,
        warnings,
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn stream_session_file_exact_from(
    file: &Path,
    handle: &mut fs::File,
    hashing_start_offset: u64,
    parsing_start_offset: u64,
    prefix_size: u64,
    validation_boundary: Option<u64>,
    initial_state: ExactSessionParserState,
    session_id: &str,
    sink: &mut impl ExactSessionEventSink,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<ExactSessionParseResult, String> {
    if hashing_start_offset > parsing_start_offset || parsing_start_offset > prefix_size {
        return Err(format!(
            "会话 JSONL 续扫边界无效：{}（hash={}，parse={}，end={}）",
            file.display(),
            hashing_start_offset,
            parsing_start_offset,
            prefix_size
        ));
    }
    if validation_boundary
        .is_some_and(|boundary| boundary < hashing_start_offset || boundary > prefix_size)
    {
        return Err(format!("会话 JSONL 校验边界无效：{}", file.display()));
    }

    handle
        .seek(SeekFrom::Start(hashing_start_offset))
        .map_err(|error| {
            let message = format!("定位会话文件失败：{}（{}）", file.display(), error);
            warnings.push(jsonl_file_warning(message.clone()));
            message
        })?;
    let byte_count = prefix_size.saturating_sub(hashing_start_offset);
    let mut hashing_reader = PrefixHashingReader::new(
        handle.take(byte_count),
        hashing_start_offset,
        validation_boundary,
    );
    let mut skipped = parsing_start_offset.saturating_sub(hashing_start_offset);
    let mut skip_buffer = [0_u8; 64 * 1024];
    while skipped > 0 {
        let requested =
            usize::try_from(skipped.min(skip_buffer.len() as u64)).unwrap_or(skip_buffer.len());
        let bytes_read = hashing_reader
            .read(&mut skip_buffer[..requested])
            .map_err(|error| {
                let message = format!("读取会话文件续扫前缀失败：{}（{}）", file.display(), error);
                warnings.push(jsonl_file_warning(message.clone()));
                message
            })?;
        if bytes_read == 0 {
            let message = format!("会话文件在续扫边界之前缩短：{}", file.display());
            warnings.push(jsonl_file_warning(message.clone()));
            return Err(message);
        }
        skipped = skipped.saturating_sub(bytes_read as u64);
    }

    let mut reader = BufReader::new(hashing_reader);
    let mut line_bytes = Vec::new();
    let mut fork_replay_started_at = initial_state.fork_replay_started_at;
    let mut fork_replay_active = initial_state.fork_replay_active;
    let mut last_skipped_fork_replay_token_at = initial_state.last_skipped_fork_replay_token_at;
    let mut previous_total = initial_state.previous_total_tokens;
    let mut current_user_prompt = initial_state.current_user_prompt;
    let mut assistant_response = initial_state.assistant_response;
    #[cfg(test)]
    let mut event_count = 0_u64;
    let mut source_offset = parsing_start_offset;
    let mut resume_offset = parsing_start_offset;

    loop {
        line_bytes.clear();
        let line_start = source_offset;
        let bytes_read = reader.read_until(b'\n', &mut line_bytes).map_err(|error| {
            let message = format!("读取会话文件中断：{}（{}）", file.display(), error);
            warnings.push(jsonl_file_warning(message.clone()));
            message
        })?;
        if bytes_read == 0 {
            break;
        }
        source_offset = source_offset.saturating_add(bytes_read as u64);
        let line_range = SourceByteRange {
            start: line_start,
            end: source_offset,
        };

        let line_ended_with_newline = line_bytes.last().is_some_and(|byte| *byte == b'\n');
        let line = std::str::from_utf8(&line_bytes).map_err(|error| {
            let message = format!("会话 JSONL 不是 UTF-8：{}（{}）", file.display(), error);
            warnings.push(jsonl_file_warning(message.clone()));
            message
        })?;
        if !line_ended_with_newline && !is_complete_json_line(line) {
            break;
        }
        resume_offset = source_offset;
        let line = line.trim_end_matches(['\r', '\n']);

        if fork_replay_started_at.is_none() {
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
            current_user_prompt = Some(line_range);
            assistant_response = None;
            continue;
        }
        if parse_payload_message_line(line, "agent_message", 220).is_some() {
            assistant_response = Some(match assistant_response {
                Some(existing) => SourceByteRange {
                    start: existing.start,
                    end: line_range.end,
                },
                None => line_range,
            });
            continue;
        }
        if !line.contains("\"token_count\"") {
            continue;
        }
        let Some(usage_line) = parse_usage_line(line) else {
            continue;
        };

        let total_tokens = usage_line.total.as_ref().map(|usage| usage.total_tokens);
        let previous_high_water = previous_total;
        if let Some(total_tokens) = total_tokens {
            previous_total = Some(
                previous_total.map_or(total_tokens, |previous: u64| previous.max(total_tokens)),
            );
        }
        let is_new_snapshot = match usage_snapshot_fingerprint(&usage_line) {
            Some(fingerprint) => sink.insert_fingerprint(&fingerprint)?,
            None => true,
        };
        if fork_replay_active {
            last_skipped_fork_replay_token_at = Some(usage_line.timestamp);
            continue;
        }
        if !is_new_snapshot {
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
        if delta == 0 {
            continue;
        }

        sink.insert_event(&ExactTokenEvent {
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
            source_offsets: ExactEventSourceOffsets {
                user_prompt: current_user_prompt,
                assistant_response,
            },
        })?;
        #[cfg(test)]
        {
            event_count = event_count.saturating_add(1);
        }
        assistant_response = None;
    }

    let hashing_reader = reader.into_inner();
    let range_bytes_read = hashing_reader.bytes_read;
    let (prefix_sha256, chunk_hashes, validation_chunk_hash) = hashing_reader.finish();
    let bytes_read = hashing_start_offset.saturating_add(range_bytes_read);
    if bytes_read != prefix_size {
        let message = format!(
            "会话文件在固定前缀扫描期间缩短：{}（预期 {} 字节，实际读取 {} 字节）",
            file.display(),
            prefix_size,
            bytes_read
        );
        warnings.push(jsonl_file_warning(message.clone()));
        return Err(message);
    }

    Ok(ExactSessionParseResult {
        prefix_sha256,
        bytes_read,
        resume_offset,
        state: ExactSessionParserState {
            previous_total_tokens: previous_total,
            fork_replay_started_at,
            fork_replay_active,
            last_skipped_fork_replay_token_at,
            current_user_prompt,
            assistant_response,
        },
        chunk_hashes,
        validation_chunk_hash,
        #[cfg(test)]
        event_count,
        #[cfg(test)]
        previous_total_tokens: previous_total,
        #[cfg(test)]
        fork_replay_active,
    })
}

struct PrefixHashingReader<R> {
    inner: R,
    hasher: Sha256,
    bytes_read: u64,
    absolute_offset: u64,
    chunk_index: u64,
    chunk_byte_count: u64,
    chunk_hasher: Sha256,
    chunk_hashes: Vec<ExactChunkHash>,
    validation_boundary: Option<u64>,
    validation_chunk_hash: Option<ExactChunkHash>,
}

impl<R> PrefixHashingReader<R> {
    fn new(inner: R, absolute_offset: u64, validation_boundary: Option<u64>) -> Self {
        debug_assert_eq!(absolute_offset % EXACT_INDEX_CHUNK_SIZE, 0);
        Self {
            inner,
            hasher: Sha256::new(),
            bytes_read: 0,
            absolute_offset,
            chunk_index: absolute_offset / EXACT_INDEX_CHUNK_SIZE,
            chunk_byte_count: 0,
            chunk_hasher: Sha256::new(),
            chunk_hashes: Vec::new(),
            validation_boundary,
            validation_chunk_hash: None,
        }
    }

    fn finish(mut self) -> ([u8; 32], Vec<ExactChunkHash>, Option<ExactChunkHash>) {
        if self.chunk_byte_count > 0 {
            self.finish_chunk();
        }
        (
            self.hasher.finalize().into(),
            self.chunk_hashes,
            self.validation_chunk_hash,
        )
    }

    fn finish_chunk(&mut self) {
        if self.chunk_byte_count == 0 {
            return;
        }
        let hash = ExactChunkHash {
            index: self.chunk_index,
            byte_count: self.chunk_byte_count,
            sha256: self.chunk_hasher.clone().finalize().into(),
        };
        self.chunk_hashes.push(hash);
        self.chunk_index = self.chunk_index.saturating_add(1);
        self.chunk_byte_count = 0;
        self.chunk_hasher = Sha256::new();
    }

    fn capture_validation_hash(&mut self) {
        let Some(boundary) = self.validation_boundary else {
            return;
        };
        if self.absolute_offset != boundary || self.validation_chunk_hash.is_some() || boundary == 0
        {
            return;
        }
        if self.chunk_byte_count == 0 {
            self.validation_chunk_hash = self.chunk_hashes.last().copied();
        } else {
            self.validation_chunk_hash = Some(ExactChunkHash {
                index: self.chunk_index,
                byte_count: self.chunk_byte_count,
                sha256: self.chunk_hasher.clone().finalize().into(),
            });
        }
    }
}

impl<R: Read> Read for PrefixHashingReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let bytes_read = self.inner.read(buffer)?;
        self.hasher.update(&buffer[..bytes_read]);
        self.bytes_read = self.bytes_read.saturating_add(bytes_read as u64);
        let mut consumed = 0_usize;
        while consumed < bytes_read {
            let chunk_remaining = EXACT_INDEX_CHUNK_SIZE.saturating_sub(self.chunk_byte_count);
            let validation_remaining = self
                .validation_boundary
                .filter(|boundary| *boundary > self.absolute_offset)
                .map(|boundary| boundary.saturating_sub(self.absolute_offset))
                .unwrap_or(u64::MAX);
            let take = usize::try_from(
                ((bytes_read - consumed) as u64)
                    .min(chunk_remaining)
                    .min(validation_remaining),
            )
            .unwrap_or(bytes_read - consumed);
            if take == 0 {
                self.capture_validation_hash();
                continue;
            }
            self.chunk_hasher.update(&buffer[consumed..consumed + take]);
            self.chunk_byte_count = self.chunk_byte_count.saturating_add(take as u64);
            self.absolute_offset = self.absolute_offset.saturating_add(take as u64);
            consumed += take;
            if self.chunk_byte_count == EXACT_INDEX_CHUNK_SIZE {
                self.finish_chunk();
            }
            self.capture_validation_hash();
        }
        Ok(bytes_read)
    }
}

pub(super) fn read_event_excerpts(
    file: &Path,
    source_offsets: ExactEventSourceOffsets,
) -> Result<(String, String), String> {
    let user_prompt = match source_offsets.user_prompt {
        Some(range) => {
            let mut latest = String::new();
            visit_source_range_lines(file, range, |line| {
                if let Some(message) = parse_payload_message_line(line, "user_message", 180) {
                    latest = message.message;
                }
            })?;
            latest
        }
        None => String::new(),
    };
    let assistant_response = match source_offsets.assistant_response {
        Some(range) => {
            let mut combined = String::new();
            visit_source_range_lines(file, range, |line| {
                if let Some(message) = parse_payload_message_line(line, "agent_message", 220) {
                    append_excerpt(&mut combined, &message.message, 220);
                }
            })?;
            combined
        }
        None => String::new(),
    };
    Ok((user_prompt, assistant_response))
}

fn visit_source_range_lines(
    file: &Path,
    range: SourceByteRange,
    mut visit: impl FnMut(&str),
) -> Result<(), String> {
    let byte_count = range
        .end
        .checked_sub(range.start)
        .ok_or_else(|| format!("会话摘录字节区间无效：{}", file.display()))?;
    let mut handle = fs::File::open(file)
        .map_err(|error| format!("打开会话摘录源文件失败：{}（{}）", file.display(), error))?;
    handle
        .seek(SeekFrom::Start(range.start))
        .map_err(|error| format!("定位会话摘录源文件失败：{}（{}）", file.display(), error))?;
    let mut reader = BufReader::new(handle.take(byte_count));
    let mut line_bytes = Vec::new();
    let mut consumed = 0_u64;
    loop {
        line_bytes.clear();
        let bytes_read = reader
            .read_until(b'\n', &mut line_bytes)
            .map_err(|error| format!("读取会话摘录失败：{}（{}）", file.display(), error))?;
        if bytes_read == 0 {
            break;
        }
        consumed = consumed.saturating_add(bytes_read as u64);
        let line = std::str::from_utf8(&line_bytes)
            .map_err(|error| format!("会话摘录不是 UTF-8：{}（{}）", file.display(), error))?
            .trim_end_matches(['\r', '\n']);
        visit(line);
    }
    if consumed != byte_count {
        return Err(format!(
            "会话摘录源文件已变化：{}（预期 {} 字节，读取 {} 字节）",
            file.display(),
            byte_count,
            consumed
        ));
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn parse_session_file_full_result(
    file: &Path,
    session_id: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> SessionParseResult {
    let mut sink = TestExactSessionSink::default();
    let mut handle = match fs::File::open(file) {
        Ok(handle) => handle,
        Err(error) => {
            warnings.push(jsonl_file_warning(format!(
                "读取会话文件失败：{}（{}）",
                file.display(),
                error
            )));
            return SessionParseResult {
                events: Vec::new(),
                previous_total_tokens: None,
                fork_replay_active: false,
            };
        }
    };
    let prefix_size = handle
        .metadata()
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let parsed = match stream_session_file_exact(
        file,
        &mut handle,
        prefix_size,
        session_id,
        &mut sink,
        warnings,
    ) {
        Ok(parsed) => parsed,
        Err(_) => {
            return SessionParseResult {
                events: Vec::new(),
                previous_total_tokens: None,
                fork_replay_active: false,
            };
        }
    };
    debug_assert_eq!(parsed.event_count as usize, sink.events.len());
    let events = sink
        .events
        .into_iter()
        .map(|event| {
            let (user_prompt, assistant_response) =
                read_event_excerpts(file, event.source_offsets).unwrap_or_default();
            TokenEvent {
                timestamp: event.timestamp,
                session_id: event.session_id,
                tokens: event.tokens,
                input_tokens: event.input_tokens,
                cached_input_tokens: event.cached_input_tokens,
                output_tokens: event.output_tokens,
                user_prompt,
                assistant_response,
            }
        })
        .collect();
    SessionParseResult {
        events,
        previous_total_tokens: parsed.previous_total_tokens,
        fork_replay_active: parsed.fork_replay_active,
    }
}

#[cfg(test)]
#[derive(Default)]
struct TestExactSessionSink {
    fingerprints: HashSet<UsageSnapshotFingerprint>,
    events: Vec<ExactTokenEvent>,
}

#[cfg(test)]
impl ExactSessionEventSink for TestExactSessionSink {
    fn insert_fingerprint(
        &mut self,
        fingerprint: &UsageSnapshotFingerprint,
    ) -> Result<bool, String> {
        Ok(self.fingerprints.insert(*fingerprint))
    }

    fn insert_event(&mut self, event: &ExactTokenEvent) -> Result<(), String> {
        self.events.push(event.clone());
        Ok(())
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

fn is_complete_json_line(line: &str) -> bool {
    serde_json::from_str::<Value>(line).is_ok()
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
