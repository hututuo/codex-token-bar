use super::accounting::{AccountingState, Components, Snapshot, COUNTED};
#[cfg(test)]
use super::TokenEvent;
use crate::models::LocalDataWarning;
use serde::Deserialize;
use serde_json::value::RawValue;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::borrow::Cow;
#[cfg(test)]
use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

const FORK_REPLAY_EXIT_GRACE: Duration = Duration::seconds(2);
const RETAINED_JSONL_LINE_BUFFER_BYTES: usize = 4 * 1024 * 1024;
pub(super) const EXACT_INDEX_CHUNK_SIZE: u64 = 4 * 1024 * 1024;
pub(super) type UsageSnapshotFingerprint = [u64; 11];
pub(super) const USAGE_SNAPSHOT_FINGERPRINT_BYTES: usize =
    std::mem::size_of::<UsageSnapshotFingerprint>();

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
    /// Reasoning output reported by the source token snapshot.  This is kept
    /// on the canonical event even though the current dashboard projections do
    /// not consume it yet; old SQLite rows remain NULL after the structural
    /// migration, while newly parsed rows always write the observed value
    /// (including an explicit zero).
    pub(super) reasoning_output_tokens: u64,
    pub(super) model: Option<String>,
    pub(super) source_offsets: ExactEventSourceOffsets,
    pub(super) token_source_offset: u64,
    pub(super) accounting_kind: i64,
    pub(super) reported_total_tokens: Option<u64>,
    pub(super) usage_fingerprint: Option<Vec<u8>>,
}

#[derive(Clone, Debug)]
struct ParsedUsage {
    input_tokens: u64,
    cached_input_tokens: u64,
    output_tokens: u64,
    reasoning_output_tokens: u64,
    total_tokens: u64,
    accounting: Snapshot,
}

#[derive(Clone, Debug)]
struct ParsedUsageLine {
    ordinal: Option<u64>,
    timestamp: OffsetDateTime,
    identity_timestamp: String,
    total: Option<ParsedUsage>,
    last: Option<ParsedUsage>,
}

#[derive(Clone, Debug)]
struct ParsedMessageLine {
    message: String,
}

#[derive(Clone, Copy, Debug)]
struct ForkSessionMetadata {
    timestamp: OffsetDateTime,
    is_explicit_subagent: bool,
}

#[derive(Deserialize)]
struct BorrowedMessageLine<'a> {
    #[serde(borrow)]
    timestamp: Cow<'a, str>,
    #[serde(borrow)]
    payload: BorrowedMessagePayload<'a>,
}

#[derive(Deserialize)]
struct BorrowedMessagePayload<'a> {
    #[serde(rename = "type", borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    message: &'a RawValue,
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

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct ExactSessionParserState {
    pub(super) previous_total_tokens: Option<u64>,
    pub(super) fork_replay_started_at: Option<OffsetDateTime>,
    pub(super) fork_replay_active: bool,
    pub(super) is_explicit_subagent_fork: bool,
    pub(super) last_skipped_fork_replay_token_at: Option<OffsetDateTime>,
    pub(super) current_user_prompt: Option<SourceByteRange>,
    pub(super) assistant_response: Option<SourceByteRange>,
    pub(super) current_model: Option<String>,
    pub(super) accounting_state: Option<AccountingState>,
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

    let paginated_metadata = paginated_subagent_metadata(handle)?;
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
    let mut is_explicit_subagent_fork = initial_state.is_explicit_subagent_fork;
    let mut last_skipped_fork_replay_token_at = initial_state.last_skipped_fork_replay_token_at;
    let mut previous_total = initial_state.previous_total_tokens;
    let mut accounting = initial_state.accounting_state.unwrap_or_else(|| {
        if parsing_start_offset == 0 { AccountingState::fresh() } else { AccountingState::default() }
    });
    let mut current_user_prompt = initial_state.current_user_prompt;
    let mut assistant_response = initial_state.assistant_response;
    let mut current_model = initial_state.current_model;
    #[cfg(test)]
    let mut event_count = 0_u64;
    let mut source_offset = parsing_start_offset;
    let mut resume_offset = parsing_start_offset;

    loop {
        reset_line_buffer(&mut line_bytes);
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
        // A writer may be between bytes of the final UTF-8 character. Retain
        // the line-start checkpoint and retry only that unfinished tail later.
        if !line_ended_with_newline && std::str::from_utf8(&line_bytes).is_err_and(|error| error.error_len().is_none()) {
            break;
        }
        let line = std::str::from_utf8(&line_bytes).map_err(|error| {
            let message = format!("会话 JSONL 不是 UTF-8：{}（文件字节 {}：{}）", file.display(), line_start + error.valid_up_to() as u64, error);
            warnings.push(jsonl_file_warning(message.clone()));
            message
        })?;
        if !line_ended_with_newline && !is_complete_json_line(line) {
            break;
        }
        resume_offset = source_offset;
        let line = line.trim_end_matches(['\r', '\n']);

        observe_paginated_own_turn(line, paginated_metadata.as_ref(), &mut accounting);
        if paginated_metadata.is_some() && accounting.paginated_own_start_ordinal.is_some() {
            fork_replay_active = false;
        }
        if fork_replay_started_at.is_none() {
            if let Some(metadata) = forked_session_replay_metadata(line) {
                fork_replay_started_at = Some(metadata.timestamp);
                fork_replay_active = true;
                is_explicit_subagent_fork = metadata.is_explicit_subagent;
            }
        }
        if let Some(turn_context) = parse_turn_context(line) {
            current_model = Some(turn_context.model);
            // A forked rollout also contains every inherited turn_context.
            // Only a context beyond the replay grace window belongs to the
            // child; exiting at the first inherited context duplicates the
            // complete parent history once per subagent.
            if is_explicit_subagent_fork
                && fork_replay_active
                && turn_context
                    .timestamp
                    .zip(last_skipped_fork_replay_token_at.or(fork_replay_started_at))
                    .is_some_and(|(timestamp, reference)| {
                        timestamp - reference > FORK_REPLAY_EXIT_GRACE
                    })
            {
                fork_replay_active = false;
            }
            continue;
        }
        if let Some(timestamp) = parse_payload_message_marker(line, "user_message") {
            if fork_replay_active {
                let replay_reference = last_skipped_fork_replay_token_at.or(fork_replay_started_at);
                if replay_reference
                    .is_some_and(|reference| timestamp - reference > FORK_REPLAY_EXIT_GRACE)
                {
                    fork_replay_active = false;
                }
            }
            current_user_prompt = Some(line_range);
            assistant_response = None;
            continue;
        }
        if parse_payload_message_marker(line, "agent_message").is_some() {
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

        let total_tokens = usage_line.total.as_ref().and_then(|u| u.accounting.reported_total);
        if let Some(total_tokens) = total_tokens {
            previous_total = Some(previous_total.map_or(total_tokens, |p| p.max(total_tokens)));
        }
        let signature = format!("{}|{}|{}",
            usage_line.total.as_ref().map_or("missing", |u| u.accounting.signature.as_str()),
            usage_line.last.as_ref().map_or("missing", |u| u.accounting.signature.as_str()),
            usage_line.identity_timestamp);
        let adjacent_duplicate = accounting.last_snapshot.as_ref() == Some(&signature);
        let fingerprint = usage_snapshot_fingerprint(&usage_line);
        let is_new_snapshot = match fingerprint.as_ref() {
            Some(fingerprint) => sink.insert_fingerprint(fingerprint)?,
            None => true,
        };
        if adjacent_duplicate { continue; }
        let mut next_accounting = accounting.clone();
        let measured = next_accounting.observe(
            usage_line.last.as_ref().map(|u| &u.accounting),
            usage_line.total.as_ref().map(|u| &u.accounting));
        next_accounting.last_snapshot = Some(signature);
        if !is_new_snapshot { continue; }
        accounting = next_accounting;
        let inherited = match paginated_metadata.as_ref().filter(|m| !m.is_main_fork || accounting.paginated_own_start_ordinal.is_some()).map(|m| m.ordinal.min(accounting.paginated_own_start_ordinal.unwrap_or(m.ordinal))) {
            Some(boundary) => usage_line.ordinal.ok_or_else(|| format!("分页会话 token 记录缺少有效 ordinal：{}", file.display()))? < boundary,
            None => fork_replay_active,
        };
        if inherited {
            last_skipped_fork_replay_token_at = Some(usage_line.timestamp);
            continue;
        }
        let Some(measured) = measured else { continue; };
        let delta = measured.tokens();
        sink.insert_event(&ExactTokenEvent {
            usage_fingerprint: fingerprint.as_ref().map(super::fingerprint_codec::encode).transpose().map_err(|e|e.to_string())?,
            timestamp: usage_line.timestamp,
            session_id: session_id.to_string(),
            tokens: delta,
            input_tokens: measured.components.input,
            cached_input_tokens: measured.components.cached,
            output_tokens: measured.components.output,
            reasoning_output_tokens: measured.components.reasoning,
            token_source_offset: line_start,
            accounting_kind: measured.kind,
            reported_total_tokens: usage_line.last.as_ref().and_then(|u| u.accounting.reported_total)
                .or_else(|| usage_line.total.as_ref().and_then(|u| u.accounting.reported_total)),
            model: current_model.clone(),
            source_offsets: ExactEventSourceOffsets {
                user_prompt: current_user_prompt,
                assistant_response,
            },
        })?;
        #[cfg(test)]
        {
            event_count = event_count.saturating_add(1);
        }
        if measured.kind == COUNTED { assistant_response = None; }
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
            is_explicit_subagent_fork,
            last_skipped_fork_replay_token_at,
            current_user_prompt,
            assistant_response,
            current_model,
            accounting_state: Some(accounting),
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

pub(super) struct MessageLinkScan {
    pub links: Vec<(u64, SourceByteRange, Option<SourceByteRange>)>,
    pub chunks: Vec<ExactChunkHash>,
    pub prompt: Option<SourceByteRange>,
    pub assistant: Option<SourceByteRange>,
}

/// Marker-only pass: never invokes the accounting parser or admits events.
pub(super) fn scan_message_links(file: &Path, size: u64, offsets: &std::collections::HashSet<u64>) -> Result<MessageLinkScan, String> {
    let mut handle = fs::File::open(file).map_err(|e| e.to_string())?;
    let metadata = paginated_subagent_metadata(&mut handle)?;
    let mut ownership = AccountingState::fresh();
    let mut fork: Option<ForkSessionMetadata> = None;
    let mut replay = false;
    let mut last_replay_token: Option<OffsetDateTime> = None;
    #[derive(Deserialize)]
    struct OrdinalEnvelope { ordinal: Option<u64> }
    let mut reader = BufReader::new(PrefixHashingReader::new(handle.take(size), 0, None));
    let mut bytes = Vec::new();
    let mut offset = 0u64;
    let mut prompt = None;
    let mut assistant: Option<SourceByteRange> = None;
    let mut links = Vec::new();
    loop {
        reset_line_buffer(&mut bytes);
        let count = reader.read_until(b'\n', &mut bytes).map_err(|e| e.to_string())?;
        if count == 0 { break; }
        let start = offset;
        offset += count as u64;
        let range = SourceByteRange { start, end: offset };
        let line = std::str::from_utf8(&bytes).map_err(|e| e.to_string())?;
        if bytes.last() != Some(&b'\n') && !is_complete_json_line(line) { break; }
        observe_paginated_own_turn(line, metadata.as_ref(), &mut ownership);
        if fork.is_none() {
            if let Some(value) = forked_session_replay_metadata(line) { fork = Some(value); replay = true; }
        }
        if ownership.paginated_own_start_ordinal.is_some() { replay = false; }
        if replay && fork.as_ref().is_some_and(|f| f.is_explicit_subagent) {
            if let Some(context) = parse_turn_context(line) {
                if context.timestamp.zip(last_replay_token.or_else(||fork.as_ref().map(|f|f.timestamp)))
                    .is_some_and(|(timestamp,reference)|timestamp-reference>FORK_REPLAY_EXIT_GRACE) { replay = false; }
            }
        }
        if let Some(metadata) = metadata.as_ref().filter(|m|!m.is_main_fork || ownership.paginated_own_start_ordinal.is_some()) {
            let boundary = metadata.ordinal.min(ownership.paginated_own_start_ordinal.unwrap_or(metadata.ordinal));
            if !serde_json::from_str::<OrdinalEnvelope>(line).ok().and_then(|r|r.ordinal).is_some_and(|o|o>=boundary) { continue; }
        }
        if let Some(timestamp) = parse_payload_message_marker(line, "user_message") {
            if replay {
                if !last_replay_token.or_else(||fork.as_ref().map(|f|f.timestamp)).is_some_and(|reference|timestamp-reference>FORK_REPLAY_EXIT_GRACE) { continue; }
                replay = false;
            }
            prompt = Some(range);
            assistant = None;
        } else if parse_payload_message_marker(line, "agent_message").is_some() {
            if replay { continue; }
            assistant = Some(SourceByteRange { start: assistant.map_or(start, |a| a.start), end: offset });
        } else if replay {
            if line.contains("\"token_count\"") {
                last_replay_token = serde_json::from_str::<Value>(line).ok().and_then(|v|v.get("timestamp").and_then(Value::as_str).and_then(parse_timestamp));
            }
        } else if offsets.contains(&start) {
            if let Some(prompt) = prompt { links.push((start, prompt, assistant)); }
        }
    }
    if offset != size { return Err("补全轮次时源文件长度变化".into()); }
    let (_, chunks, _) = reader.into_inner().finish();
    Ok(MessageLinkScan { links, chunks, prompt, assistant })
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
        reset_line_buffer(&mut line_bytes);
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
        .filter(|event| event.accounting_kind == COUNTED)
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

// 与 Swift UsageSnapshotFingerprint（CodexUsageAnalyzerModels.swift）同为 11 字段、
// 同字段顺序：仅 reasoning 不同的两条 snapshot 两端必须一致地判为不同事件。
fn usage_snapshot_fingerprint(usage_line: &ParsedUsageLine) -> Option<UsageSnapshotFingerprint> {
    let full = usage_line.total.as_ref().is_some_and(|t| t.accounting.has_input_and_output
        && t.accounting.reported_total.is_some() && !t.accounting.invalid_number)
        && !usage_line.last.as_ref().is_some_and(|l| !l.accounting.has_input_and_output
            || l.accounting.reported_total.is_none() || l.accounting.invalid_number);
    if !full {
        let identity = format!("codex-partial-snapshot-v1|{}|{}|{}",
            usage_line.total.as_ref().map_or("missing", |u| u.accounting.signature.as_str()),
            usage_line.last.as_ref().map_or("missing", |u| u.accounting.signature.as_str()),
            usage_line.identity_timestamp);
        let digest = Sha256::digest(identity.as_bytes());
        let words = digest.chunks_exact(4).map(|bytes| u32::from_be_bytes(bytes.try_into().unwrap()) as u64).collect::<Vec<_>>();
        // Reserved no-last/nonzero-lastTokens identity: a full numeric
        // snapshot without last always has five trailing zero values.
        return Some([words[0], words[1], words[2], words[3], words[4], 0,
            words[5], words[6], words[7], 0, 1]);
    }
    let total = usage_line.total.as_ref()?;
    let mut fingerprint = [0; 11];
    fingerprint[..5].copy_from_slice(&[
        total.input_tokens,
        total.cached_input_tokens,
        total.output_tokens,
        total.reasoning_output_tokens,
        total.total_tokens,
    ]);
    if let Some(last) = usage_line.last.as_ref() {
        fingerprint[5] = 1;
        fingerprint[6..].copy_from_slice(&[
            last.input_tokens,
            last.cached_input_tokens,
            last.output_tokens,
            last.reasoning_output_tokens,
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
    if let Some((_, message)) = response_message(line, expected_type) {
        return Some(ParsedMessageLine { message: excerpt(&message, excerpt_limit) });
    }
    let value = borrowed_payload_message(line, expected_type)?;
    let message: Cow<'_, str> = serde_json::from_str(value.payload.message.get()).ok()?;
    let normalized = excerpt(message.as_ref(), excerpt_limit);
    if normalized.is_empty() {
        None
    } else {
        parse_timestamp(value.timestamp.as_ref())?;
        Some(ParsedMessageLine {
            message: normalized,
        })
    }
}

fn parse_payload_message_marker(line: &str, expected_type: &str) -> Option<OffsetDateTime> {
    if let Some((timestamp, _)) = response_message(line, expected_type) {
        return Some(timestamp);
    }
    let value = borrowed_payload_message(line, expected_type)?;
    raw_json_string_has_non_whitespace(value.payload.message)
        .then(|| parse_timestamp(value.timestamp.as_ref()))
        .flatten()
}

fn response_message(line: &str, expected_type: &str) -> Option<(OffsetDateTime, String)> {
    let role = if expected_type == "user_message" { "user" } else { "assistant" };
    if !line.contains("\"response_item\"") || !line.contains("\"message\"") || !line.contains(&format!("\"{role}\"")) { return None; }
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("type")?.as_str()? != "response_item" { return None; }
    let payload = value.get("payload")?;
    if payload.get("type")?.as_str()? != "message" || payload.get("role")?.as_str()? != role { return None; }
    let content = payload.get("content")?.as_array()?;
    let message = content.iter().filter_map(|part| {
        matches!(part.get("type")?.as_str()?, "input_text" | "output_text" | "text")
            .then(|| part.get("text").and_then(Value::as_str)).flatten()
    }).collect::<Vec<_>>().join("\n");
    if message.trim().is_empty() && !(role == "user" && content.iter().any(|p| p.get("type").and_then(Value::as_str) == Some("input_image"))) { return None; }
    Some((parse_timestamp(value.get("timestamp")?.as_str()?)?, message))
}

struct ParsedTurnContext {
    model: String,
    timestamp: Option<OffsetDateTime>,
}

fn parse_turn_context(line: &str) -> Option<ParsedTurnContext> {
    if !line.contains("\"turn_context\"") || !line.contains("\"model\"") {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("type")?.as_str()? != "turn_context" {
        return None;
    }
    let model = value.get("payload")?.get("model")?.as_str()?.trim();
    (!model.is_empty()).then(|| ParsedTurnContext {
        model: model.to_string(),
        timestamp: value
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_timestamp),
    })
}

fn borrowed_payload_message<'a>(
    line: &'a str,
    expected_type: &str,
) -> Option<BorrowedMessageLine<'a>> {
    if !line.contains("\"payload\"") || !line.contains(expected_type) {
        return None;
    }
    let value: BorrowedMessageLine<'_> = serde_json::from_str(line).ok()?;
    (value.payload.kind == expected_type).then_some(value)
}

fn raw_json_string_has_non_whitespace(value: &RawValue) -> bool {
    let encoded = value.get().as_bytes();
    if encoded.len() < 2 || encoded.first() != Some(&b'"') || encoded.last() != Some(&b'"') {
        return false;
    }
    let mut index = 1_usize;
    let end = encoded.len() - 1;
    while index < end {
        if encoded[index] != b'\\' {
            let segment_start = index;
            while index < end && encoded[index] != b'\\' {
                index += 1;
            }
            let Ok(segment) = std::str::from_utf8(&encoded[segment_start..index]) else {
                return false;
            };
            if segment.chars().any(|character| !character.is_whitespace()) {
                return true;
            }
            continue;
        }
        index += 1;
        let Some(escaped) = encoded.get(index).copied() else {
            return false;
        };
        index += 1;
        let character = match escaped {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{0008}',
            b'f' => '\u{000C}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => {
                let Some((first, next_index)) = decode_json_u16(encoded, index, end) else {
                    return false;
                };
                index = next_index;
                let scalar = if (0xD800..=0xDBFF).contains(&first) {
                    if encoded.get(index..index + 2) != Some(&[b'\\', b'u']) {
                        return false;
                    }
                    let Some((second, next_index)) = decode_json_u16(encoded, index + 2, end)
                    else {
                        return false;
                    };
                    if !(0xDC00..=0xDFFF).contains(&second) {
                        return false;
                    }
                    index = next_index;
                    0x1_0000 + ((u32::from(first) - 0xD800) << 10) + (u32::from(second) - 0xDC00)
                } else if (0xDC00..=0xDFFF).contains(&first) {
                    return false;
                } else {
                    u32::from(first)
                };
                let Some(character) = char::from_u32(scalar) else {
                    return false;
                };
                character
            }
            _ => return false,
        };
        if !character.is_whitespace() {
            return true;
        }
    }
    false
}

fn decode_json_u16(encoded: &[u8], start: usize, end: usize) -> Option<(u16, usize)> {
    let next = start.checked_add(4)?;
    if next > end {
        return None;
    }
    let digits = std::str::from_utf8(&encoded[start..next]).ok()?;
    Some((u16::from_str_radix(digits, 16).ok()?, next))
}

fn reset_line_buffer(buffer: &mut Vec<u8>) {
    if buffer.capacity() > RETAINED_JSONL_LINE_BUFFER_BYTES {
        *buffer = Vec::new();
    } else {
        buffer.clear();
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

fn forked_session_replay_metadata(line: &str) -> Option<ForkSessionMetadata> {
    if !line.contains("session_meta") || !line.contains("forked_from_id") {
        return None;
    }
    let Some(value) = serde_json::from_str::<Value>(line).ok() else {
        return None;
    };
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return None;
    }
    let Some(payload) = value.get("payload") else {
        return None;
    };
    let timestamp = value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_timestamp)
        .or_else(|| {
            payload
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(parse_timestamp)
        })?;
    let forked_from_id = payload
        .get("forked_from_id")
        .and_then(Value::as_str)
        .is_some_and(|forked_from_id| !forked_from_id.trim().is_empty());
    if !forked_from_id {
        return None;
    }

    let has_thread_spawn = payload
        .get("source")
        .and_then(|source| source.get("subagent"))
        .and_then(|subagent| subagent.get("thread_spawn"))
        .is_some();
    let nonempty_string = |key: &str| {
        payload
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
    };
    let explicit_thread_source = payload
        .get("thread_source")
        .and_then(Value::as_str)
        .is_some_and(|value| value.trim() == "subagent");
    Some(ForkSessionMetadata {
        timestamp,
        is_explicit_subagent: has_thread_spawn
            || explicit_thread_source
            || nonempty_string("agent_role")
            || nonempty_string("agent_path"),
    })
}

pub(super) enum ExplicitSubagentSessionFileProbe {
    Explicit,
    NonExplicit,
    Unresolved,
}

const EXPLICIT_SUBAGENT_FIRST_LINE_LIMIT: usize = 256 * 1024;

pub(super) fn probe_explicit_subagent_session_file(
    path: &Path,
) -> ExplicitSubagentSessionFileProbe {
    let Ok(file) = fs::File::open(path) else {
        return ExplicitSubagentSessionFileProbe::Unresolved;
    };
    let mut reader = BufReader::new(file);
    let mut first_line = Vec::new();
    loop {
        let Ok(chunk) = reader.fill_buf() else {
            return ExplicitSubagentSessionFileProbe::Unresolved;
        };
        if chunk.is_empty() {
            return ExplicitSubagentSessionFileProbe::Unresolved;
        }
        if let Some(newline) = chunk.iter().position(|byte| *byte == b'\n') {
            if first_line.len().saturating_add(newline) > EXPLICIT_SUBAGENT_FIRST_LINE_LIMIT {
                return ExplicitSubagentSessionFileProbe::Unresolved;
            }
            first_line.extend_from_slice(&chunk[..newline]);
            reader.consume(newline + 1);
            break;
        }
        if first_line.len().saturating_add(chunk.len()) > EXPLICIT_SUBAGENT_FIRST_LINE_LIMIT {
            return ExplicitSubagentSessionFileProbe::Unresolved;
        }
        let chunk_len = chunk.len();
        first_line.extend_from_slice(chunk);
        reader.consume(chunk_len);
    }

    let Ok(value) = serde_json::from_slice::<Value>(&first_line) else {
        return ExplicitSubagentSessionFileProbe::Unresolved;
    };
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return ExplicitSubagentSessionFileProbe::NonExplicit;
    }
    let Some(payload) = value.get("payload").and_then(Value::as_object) else {
        return ExplicitSubagentSessionFileProbe::Unresolved;
    };
    let forked_from_id = payload
        .get("forked_from_id")
        .and_then(Value::as_str)
        .is_some_and(|forked_from_id| !forked_from_id.trim().is_empty());
    if !forked_from_id {
        return ExplicitSubagentSessionFileProbe::NonExplicit;
    }
    let has_thread_spawn = payload
        .get("source")
        .and_then(|source| source.get("subagent"))
        .and_then(|subagent| subagent.get("thread_spawn"))
        .is_some();
    let explicit_thread_source = payload
        .get("thread_source")
        .and_then(Value::as_str)
        .is_some_and(|value| value.trim() == "subagent");
    let nonempty_string = |key: &str| {
        payload
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
    };
    if has_thread_spawn
        || explicit_thread_source
        || nonempty_string("agent_role")
        || nonempty_string("agent_path")
    {
        ExplicitSubagentSessionFileProbe::Explicit
    } else {
        ExplicitSubagentSessionFileProbe::NonExplicit
    }
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
        ordinal: value.get("ordinal").and_then(Value::as_u64),
        timestamp,
        identity_timestamp: value.get("timestamp")?.as_str()?.to_owned(),
        total,
        last,
    })
}

fn parse_usage(value: Option<&Value>) -> Option<ParsedUsage> {
    let value = value?.as_object()?;
    let keys = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"];
    if !keys.iter().any(|k| value.contains_key(*k)) { return None; }
    let values = keys.map(|k| value.get(k).and_then(|v| {
        v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse::<u64>().ok()))
            .filter(|n| *n <= i64::MAX as u64)
    }));
    let components = Components { input: values[0].unwrap_or(0), cached: values[1].unwrap_or(0),
        output: values[2].unwrap_or(0), reasoning: values[3].unwrap_or(0) };
    let invalid_number = keys.iter().zip(values).any(|(k, v)| value.contains_key(*k) && v.is_none());
    let signature = keys.iter().zip(values).map(|(k, v)| v.map(|n| n.to_string())
        .unwrap_or_else(|| if value.contains_key(*k) { "invalid" } else { "missing" }.into()))
        .collect::<Vec<_>>().join(":");
    Some(ParsedUsage {
        input_tokens: components.input, cached_input_tokens: components.cached,
        output_tokens: components.output, reasoning_output_tokens: components.reasoning,
        total_tokens: values[4].unwrap_or_else(|| if components.valid() { components.total() } else { 0 }),
        accounting: Snapshot { components, reported_total: values[4],
            has_input_and_output: values[0].is_some() && values[2].is_some(), invalid_number, signature },
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

#[cfg(test)]
mod tests {
    #[test]
    fn non_integer_json_spellings_match_swift_diagnostic_policy() {
        for spelling in ["1.0", "1e3", "-0", "\"-0\"", "1.5"] {
            let raw = format!(r#"{{"timestamp":"2026-09-05T01:00:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":{spelling},"output_tokens":1}}}}}}}}"#);
            let line = super::parse_usage_line(&raw).unwrap();
            let mut state = super::AccountingState::fresh();
            let event = state.observe(line.last.as_ref().map(|u| &u.accounting), None).unwrap();
            assert_eq!(event.kind, super::super::accounting::INVALID, "{spelling}");
            assert_eq!(event.tokens(), 0, "{spelling}");
        }
    }
    #[test]
    fn partial_snapshot_identity_matches_swift_reserved_codec_vector() {
        let line = super::parse_usage_line(r#"{"timestamp":"2026-09-05T01:00:00.123456Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#).unwrap();
        let values = super::usage_snapshot_fingerprint(&line).unwrap();
        assert_eq!(values, [3055952699,2187296764,1175716159,614398934,4030878752,0,1501025032,3640361036,3087568809,0,1]);
        let encoded = crate::core::usage::token_count_jsonl::fingerprint_codec::encode(&values).unwrap();
        assert_eq!(crate::core::usage::token_count_jsonl::fingerprint_codec::decode(&encoded).unwrap(), values);
    }
    use super::{parse_payload_message_marker, parse_turn_context};

    #[test]
    fn message_link_scan_does_not_use_inherited_subagent_prompts() {
        let file=std::env::temp_dir().join(format!("message-links-{}.jsonl",uuid::Uuid::new_v4()));
        let lines=[
            r#"{"timestamp":"2026-09-01T00:00:00Z","type":"session_meta","payload":{"history_mode":"paginated","subagent_history_start_ordinal":3,"thread_source":"subagent"}}"#,
            r#"{"ordinal":1,"timestamp":"2026-09-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"父任务问题"}]}}"#,
            r#"{"ordinal":4,"timestamp":"2026-09-01T00:00:04Z","type":"event_msg","payload":{"type":"token_count"}}"#,
            r#"{"ordinal":5,"timestamp":"2026-09-01T00:00:05Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"子任务问题"}]}}"#,
            r#"{"ordinal":6,"timestamp":"2026-09-01T00:00:06Z","type":"event_msg","payload":{"type":"token_count"}}"#,
        ];
        let data=lines.join("\n")+"\n";
        std::fs::write(&file,&data).unwrap();
        let first=lines[..2].iter().map(|l|l.len() as u64+1).sum();
        let second=lines[..4].iter().map(|l|l.len() as u64+1).sum();
        let scan=super::scan_message_links(&file,data.len() as u64,&[first,second].into_iter().collect()).unwrap();
        assert_eq!(scan.links.len(),1);
        assert_eq!(scan.links[0].0,second);
        std::fs::remove_file(file).unwrap();
    }

    #[test]
    fn borrowed_message_marker_checks_escaped_content_without_materializing_the_message() {
        let whitespace = r#"{"timestamp":"2026-07-24T01:00:00Z","payload":{"type":"user_message","message":" \n\t\u3000"}}"#;
        let content = r#"{"timestamp":"2026-07-24T01:00:00Z","payload":{"type":"user_message","message":"\uD83D\uDE80"}}"#;

        assert!(parse_payload_message_marker(whitespace, "user_message").is_none());
        assert!(parse_payload_message_marker(content, "user_message").is_some());
        assert!(parse_payload_message_marker(content, "agent_message").is_none());
    }

    #[test]
    fn turn_context_model_is_read_from_the_authoritative_payload() {
        let line = r#"{"timestamp":"2026-07-24T01:00:03Z","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#;
        let wrong_type = r#"{"type":"event_msg","payload":{"model":"gpt-5.6-sol"}}"#;

        let parsed = parse_turn_context(line).expect("turn context");
        assert_eq!(parsed.model, "gpt-5.6-terra");
        assert!(parsed.timestamp.is_some());
        assert!(parse_turn_context(wrong_type).is_none());
    }
}

/// Read the declared boundary from the same open source on every parse,
/// including append resumes. This adds no new persisted checkpoint fields.
pub(super) fn paginated_subagent_boundary(handle: &mut fs::File) -> Result<Option<u64>, String> {
    paginated_subagent_metadata(handle).map(|m| m.map(|m| m.ordinal))
}

struct PaginatedSubagentMetadata {
    ordinal: u64,
    child_created_milliseconds: Option<u64>,
    is_main_fork: bool,
}

fn uuid_milliseconds(value: &str) -> Option<u64> {
    let id = uuid::Uuid::parse_str(value).ok()?;
    (id.get_version_num() == 7).then_some((id.as_u128() >> 80) as u64)
}

fn paginated_subagent_metadata(handle: &mut fs::File) -> Result<Option<PaginatedSubagentMetadata>, String> {
    let position = handle.stream_position().map_err(|e| e.to_string())?;
    let result = (|| {
        handle.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        let mut first = Vec::new();
        BufReader::new((&mut *handle).take(8 * 1024 * 1024)).read_until(b'\n', &mut first).map_err(|e| e.to_string())?;
        let Ok(value) = serde_json::from_slice::<Value>(&first) else { return Ok(None); };
        if value.get("type").and_then(Value::as_str) != Some("session_meta") { return Ok(None); }
        let Some(payload) = value.get("payload") else { return Ok(None); };
        if payload.get("history_mode").and_then(Value::as_str) != Some("paginated") { return Ok(None); }
        match payload.get("subagent_history_start_ordinal") {
            None | Some(Value::Null) => {
                let fork = payload.get("forked_from_id").and_then(Value::as_str).is_some_and(|s| !s.is_empty());
                Ok(fork.then(|| PaginatedSubagentMetadata { ordinal: u64::MAX,
                    child_created_milliseconds: payload.get("id").and_then(Value::as_str).and_then(uuid_milliseconds), is_main_fork: true }))
            },
            Some(value) => {
                let ordinal = value.as_u64().ok_or_else(|| "分页子 Agent 历史边界无效".to_string())?;
                let explicit = payload.get("thread_source").and_then(Value::as_str) == Some("subagent")
                    || payload.get("source").and_then(|s| s.get("subagent")).is_some();
                let child_created_milliseconds = if explicit {
                    payload.get("id").and_then(Value::as_str).and_then(uuid_milliseconds)
                } else { None };
                Ok(Some(PaginatedSubagentMetadata { ordinal, child_created_milliseconds, is_main_fork: false }))
            },
        }
    })();
    handle.seek(SeekFrom::Start(position)).map_err(|e| e.to_string())?;
    result
}

// Envelope timestamps are flattened by some history migrations. Only a
// matching task_started / turn_context identity born after the child can
// override an over-wide inherited prefix; never infer ownership from usage.
fn synthetic_rollout_turn(value: &str) -> bool {
    value.strip_prefix("rollout-").is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) && s.parse::<u64>().is_ok())
}

fn observe_paginated_own_turn(line: &str, metadata: Option<&PaginatedSubagentMetadata>, state: &mut AccountingState) {
    let Some(metadata) = metadata else { return; };
    let Some(created) = metadata.child_created_milliseconds else { return; };
    if state.paginated_own_start_ordinal.is_some()
        || (!line.contains("\"task_started\"") && !line.contains("\"turn_context\"")) { return; }
    let Ok(root) = serde_json::from_str::<Value>(line) else { return; };
    let Some(ordinal) = root.get("ordinal").and_then(Value::as_u64).filter(|o| *o < metadata.ordinal) else { return; };
    let Some(payload) = root.get("payload") else { return; };
    if root.get("type").and_then(Value::as_str) == Some("event_msg")
        && payload.get("type").and_then(Value::as_str) == Some("task_started") {
        let turn = payload.get("turn_id").and_then(Value::as_str);
        if state.paginated_pending_is_context == Some(true)
            && state.paginated_pending_turn_ordinal.is_some_and(|o| o < ordinal)
            && turn.is_some_and(|id| state.paginated_pending_turn_id.as_deref() == Some(id) || synthetic_rollout_turn(id)) {
            state.paginated_own_start_ordinal = Some(ordinal);
            state.paginated_pending_turn_id = None;
            state.paginated_pending_turn_ordinal = None;
            state.paginated_pending_is_context = None;
            return;
        }
        state.paginated_pending_turn_id = None;
        state.paginated_pending_turn_ordinal = None;
        state.paginated_pending_is_context = None;
        if let Some(turn) = turn.filter(|id| uuid_milliseconds(id).is_some_and(|born| born >= created) || synthetic_rollout_turn(id)) {
            state.paginated_pending_turn_id = Some(turn.to_owned());
            state.paginated_pending_turn_ordinal = Some(ordinal);
        }
    } else if root.get("type").and_then(Value::as_str) == Some("turn_context") {
        let Some(turn) = payload.get("turn_id").and_then(Value::as_str)
            .filter(|id| uuid_milliseconds(id).is_some_and(|born| born >= created)) else { return; };
        if state.paginated_pending_is_context != Some(true)
            && state.paginated_pending_turn_id.as_deref().is_some_and(|pending| pending == turn || synthetic_rollout_turn(pending))
            && state.paginated_pending_turn_ordinal.is_some_and(|o| o < ordinal) {
            state.paginated_own_start_ordinal = state.paginated_pending_turn_ordinal;
            state.paginated_pending_turn_id = None;
            state.paginated_pending_turn_ordinal = None;
            state.paginated_pending_is_context = None;
        } else if state.paginated_pending_turn_id.is_none() {
            // Context-first migration: wait for task start so a restored
            // cumulative snapshot between context and start remains a baseline.
            state.paginated_pending_turn_id = Some(turn.to_owned());
            state.paginated_pending_turn_ordinal = Some(ordinal);
            state.paginated_pending_is_context = Some(true);
        }
    }
}

#[test]
fn paginated_synthetic_start_requires_a_child_context_and_not_an_inherited_one() {
    let child = "019ff8b9-09e7-75c1-b9a5-14fe7b60065a";
    let own = "019ff8b9-0ace-7c02-9f89-4358b15cceda";
    let parent = "019ff8b8-0000-7000-8000-000000000000";
    let metadata = PaginatedSubagentMetadata { is_main_fork: false, ordinal: 100, child_created_milliseconds: uuid_milliseconds(child) };
    let mut state = AccountingState::fresh();
    let start = r#"{"ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"rollout-4"}}"#;
    observe_paginated_own_turn(start,Some(&metadata),&mut state);
    for (id, expected) in [(parent,None),(own,Some(1))] {
        let context=serde_json::json!({"ordinal":2,"type":"turn_context","payload":{"turn_id":id,"model":"gpt-5.6-sol"}}).to_string();
        observe_paginated_own_turn(&context,Some(&metadata),&mut state);
        assert_eq!(state.paginated_own_start_ordinal,expected);
    }
    let mut context_first = AccountingState::fresh();
    let context=serde_json::json!({"ordinal":3,"type":"turn_context","payload":{"turn_id":own}}).to_string();
    observe_paginated_own_turn(&context,Some(&metadata),&mut context_first);
    assert_eq!(context_first.paginated_own_start_ordinal,None);
    observe_paginated_own_turn(&start.replace("\"ordinal\":1", "\"ordinal\":5"),Some(&metadata),&mut context_first);
    assert_eq!(context_first.paginated_own_start_ordinal,Some(5));
    let old = r#"{"previous":null,"unreflected":{"input":0,"cached":0,"output":0,"reasoning":0},"can_start_from_zero":true,"counter_reset":false,"last_snapshot":null}"#;
    assert!(AccountingState::decode(Some(old.to_owned())).unwrap().unwrap().paginated_own_start_ordinal.is_none());
}
