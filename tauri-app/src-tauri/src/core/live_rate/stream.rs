use serde::Deserialize;
use std::collections::{HashMap, HashSet};

pub(super) const WINDOW_SECONDS: f64 = 2.5;
const MINIMUM_RATE_SPAN_SECONDS: f64 = 0.4;
const COMPLETION_PAYLOAD_TOKENS_PER_SECOND: f64 = 55.0;
const MINIMUM_COMPLETION_PAYLOAD_SECONDS: f64 = 1.0;
const MAXIMUM_COMPLETION_PAYLOAD_SECONDS: f64 = 30.0;
const DISTRIBUTION_STEP_SECONDS: f64 = 0.5;
const SINGLE_SESSION_DISPLAY_CAP: f64 = 80.0;

pub(super) fn rollup_stream_rows(
    rows: &[LogRow],
    now: f64,
    selected_thread_id: Option<&str>,
) -> LiveRateRollup {
    let metrics = rows
        .iter()
        .filter_map(|row| {
            let event = stream_event(row)?;
            metric_event(event, row)
        })
        .collect::<Vec<_>>();
    rollup_metric_events(&metrics, now, selected_thread_id)
}

pub(super) fn rollup_metric_events(
    metrics: &[LiveMetricEvent],
    now: f64,
    selected_thread_id: Option<&str>,
) -> LiveRateRollup {
    let mut seen = HashSet::<String>::new();
    let mut text_by_key = HashMap::<String, String>::new();
    let mut tokens_by_key = HashMap::<String, u32>::new();
    let mut rolling_deltas = Vec::<(String, f64, u32)>::new();
    let mut latest_thread_id = None;
    let mut breakdown = LiveTokenBreakdown::default();
    let window_start = now - WINDOW_SECONDS;

    for metric in metrics {
        if let Some(selected_thread_id) = selected_thread_id {
            if metric.thread_id.as_deref() != Some(selected_thread_id) {
                continue;
            }
        }
        let fingerprint = metric.fingerprint();
        if !seen.insert(fingerprint) {
            continue;
        }

        let key = format!(
            "{}:{}:{}",
            metric.thread_id.as_deref().unwrap_or(""),
            metric.item_id,
            metric.category.key()
        );
        if !metric.category.contributes_to_live_rate() {
            let tokens = metric
                .exact_tokens
                .unwrap_or_else(|| estimate_token_count(&metric.delta, metric.category));
            breakdown.add(metric.category, tokens);
            continue;
        }
        if metric.distributed {
            let tokens = metric
                .exact_tokens
                .unwrap_or_else(|| estimate_token_count(&metric.delta, metric.category));
            breakdown.add(metric.category, tokens);
            for (time, delta_tokens) in
                distributed_deltas(tokens, metric.start_timestamp, metric.timestamp)
            {
                if delta_tokens > 0 && time >= window_start && time <= now + 0.25 {
                    rolling_deltas.push((thread_rate_key(metric), time, delta_tokens));
                }
            }
            if tokens > 0 && metric.timestamp >= window_start && metric.timestamp <= now + 0.25 {
                if let Some(thread_id) = metric.thread_id.clone() {
                    latest_thread_id = Some(thread_id);
                }
            }
            continue;
        }
        if let Some(exact_tokens) = metric.exact_tokens {
            breakdown.add(metric.category, exact_tokens);
            if exact_tokens > 0
                && metric.timestamp >= window_start
                && metric.timestamp <= now + 0.25
            {
                rolling_deltas.push((thread_rate_key(metric), metric.timestamp, exact_tokens));
                if let Some(thread_id) = metric.thread_id.clone() {
                    latest_thread_id = Some(thread_id);
                }
            }
            continue;
        }
        let text = text_by_key.entry(key.clone()).or_default();
        text.push_str(&metric.delta);

        let previous_tokens = *tokens_by_key.get(&key).unwrap_or(&0);
        let next_tokens = estimate_token_count(text, metric.category);
        tokens_by_key.insert(key, next_tokens);

        let delta_tokens = next_tokens.saturating_sub(previous_tokens);
        breakdown.add(metric.category, delta_tokens);
        if delta_tokens > 0 && metric.timestamp >= window_start && metric.timestamp <= now + 0.25 {
            rolling_deltas.push((thread_rate_key(metric), metric.timestamp, delta_tokens));
            if let Some(thread_id) = metric.thread_id.clone() {
                latest_thread_id = Some(thread_id);
            }
        }
    }

    let tokens_per_second = if selected_thread_id.is_some() {
        rolling_rate_for_entries(
            &rolling_deltas
                .iter()
                .map(|(_, time, tokens)| (*time, *tokens))
                .collect::<Vec<_>>(),
            now,
        )
        .min(SINGLE_SESSION_DISPLAY_CAP)
    } else {
        rolling_rate_by_thread(&rolling_deltas, now)
            .into_values()
            .map(|rate| rate.min(SINGLE_SESSION_DISPLAY_CAP))
            .sum()
    };
    LiveRateRollup {
        tokens_per_second,
        latest_thread_id: if tokens_per_second > 0.0 {
            latest_thread_id
        } else {
            None
        },
        breakdown,
    }
}

fn distributed_deltas(tokens: u32, start_timestamp: Option<f64>, ending_at: f64) -> Vec<(f64, u32)> {
    if tokens == 0 {
        return Vec::new();
    }
    let estimated_duration = (f64::from(tokens) / COMPLETION_PAYLOAD_TOKENS_PER_SECOND)
        .clamp(MINIMUM_COMPLETION_PAYLOAD_SECONDS, MAXIMUM_COMPLETION_PAYLOAD_SECONDS);
    let start = start_timestamp
        .map(|start| start.min(ending_at))
        .unwrap_or(ending_at - estimated_duration);
    let duration = (ending_at - start).max(estimated_duration).max(0.25);
    let chunk_count = tokens
        .min((duration / DISTRIBUTION_STEP_SECONDS).ceil().max(1.0) as u32)
        .max(1);
    let mut emitted = 0_u32;
    let mut deltas = Vec::new();
    for index in 1..=chunk_count {
        let cumulative = ((f64::from(tokens) * f64::from(index) / f64::from(chunk_count)).round()
            as u32)
            .min(tokens);
        let chunk_tokens = cumulative.saturating_sub(emitted);
        emitted = cumulative;
        if chunk_tokens == 0 {
            continue;
        }
        let ratio = f64::from(index) / f64::from(chunk_count);
        deltas.push((start + duration * ratio, chunk_tokens));
    }
    deltas
}

fn stream_event(row: &LogRow) -> Option<ResponseStreamEvent> {
    let marker = match row.target.as_str() {
        "codex_api::sse::responses" => "SSE event: ",
        "codex_api::endpoint::responses_websocket" => "websocket event: ",
        "log" => "Received message ",
        _ => return None,
    };
    let (_, json_text) = row.feedback_log_body.split_once(marker)?;
    serde_json::from_str(json_text).ok()
}

fn metric_event(event: ResponseStreamEvent, row: &LogRow) -> Option<LiveMetricEvent> {
    let delta = event.delta?;
    if delta.is_empty() {
        return None;
    }

    let category = match event.event_type.as_str() {
        "response.output_text.delta" => LiveTokenCategory::VisibleText,
        "response.function_call_arguments.delta" | "response.custom_tool_call_input.delta" => {
            let item_name = event.item.as_ref().and_then(|item| item.name.as_deref());
            if item_name == Some("apply_patch") {
                LiveTokenCategory::PatchInput
            } else {
                LiveTokenCategory::ToolArguments
            }
        }
        _ => return None,
    };

    let item_id = event
        .item_id
        .or_else(|| event.item.as_ref().and_then(|item| item.id.clone()))
        .unwrap_or_else(|| "unknown".into());

    let dedupe_key = event
        .sequence_number
        .is_none()
        .then(|| format!("row:{}:{}:{}", row.id, event.event_type, delta));

    Some(LiveMetricEvent {
        event_type: event.event_type,
        timestamp: row.timestamp(),
        thread_id: row.thread_id.clone(),
        item_id,
        sequence_number: event.sequence_number,
        category,
        delta,
        exact_tokens: None,
        start_timestamp: None,
        distributed: matches!(
            category,
            LiveTokenCategory::ToolArguments | LiveTokenCategory::PatchInput
        ),
        dedupe_key,
    })
}

fn thread_rate_key(metric: &LiveMetricEvent) -> String {
    if let Some(thread_id) = metric.thread_id.as_deref().filter(|value| !value.is_empty()) {
        return format!("thread:{thread_id}");
    }
    if metric.item_id != "unknown" && !metric.item_id.is_empty() {
        return format!("unknown-item:{}", metric.item_id);
    }
    if let Some(sequence_number) = metric.sequence_number {
        return format!("unknown-seq:{}:{sequence_number}", metric.event_type);
    }
    format!("unknown-event:{}:{:.3}", metric.event_type, metric.timestamp)
}

fn rolling_rate_by_thread(
    rolling_deltas: &[(String, f64, u32)],
    now: f64,
) -> HashMap<String, f64> {
    let mut grouped = HashMap::<String, Vec<(f64, u32)>>::new();
    for (thread_id, time, tokens) in rolling_deltas {
        grouped
            .entry(thread_id.clone())
            .or_default()
            .push((*time, *tokens));
    }
    grouped
        .into_iter()
        .map(|(thread_id, entries)| (thread_id, rolling_rate_for_entries(&entries, now)))
        .collect()
}

fn rolling_rate_for_entries(rolling_deltas: &[(f64, u32)], now: f64) -> f64 {
    let visible: Vec<(f64, u32)> = rolling_deltas
        .iter()
        .copied()
        .filter(|(time, _)| *time <= now && now - *time <= WINDOW_SECONDS)
        .collect();
    let Some((first_time, _)) = visible.first() else {
        return 0.0;
    };
    let span = (now - first_time)
        .min(WINDOW_SECONDS)
        .max(MINIMUM_RATE_SPAN_SECONDS);
    let tokens: u32 = visible.iter().map(|(_, tokens)| *tokens).sum();
    f64::from(tokens) / span
}

fn estimate_token_count(text: &str, category: LiveTokenCategory) -> u32 {
    let mut tokens = 0.0;
    let mut ascii_run = 0_u32;
    let ascii_divisor = if category == LiveTokenCategory::VisibleText {
        4.2
    } else {
        3.0
    };

    fn flush_ascii(tokens: &mut f64, ascii_run: &mut u32, divisor: f64) {
        if *ascii_run > 0 {
            *tokens += (f64::from(*ascii_run) / divisor).max(1.0);
            *ascii_run = 0;
        }
    }

    for character in text.chars() {
        if character.is_ascii() && !character.is_ascii_whitespace() {
            ascii_run += 1;
        } else {
            flush_ascii(&mut tokens, &mut ascii_run, ascii_divisor);
            if !character.is_whitespace() {
                tokens += non_ascii_token_weight(character, category);
            }
        }
    }
    flush_ascii(&mut tokens, &mut ascii_run, ascii_divisor);

    tokens.round() as u32
}

fn non_ascii_token_weight(character: char, category: LiveTokenCategory) -> f64 {
    if is_cjk(character) {
        return if category == LiveTokenCategory::VisibleText {
            0.58
        } else {
            0.8
        };
    }
    if !character.is_alphanumeric() {
        return if category == LiveTokenCategory::VisibleText {
            0.35
        } else {
            0.7
        };
    }
    if category == LiveTokenCategory::VisibleText {
        0.8
    } else {
        1.0
    }
}

fn is_cjk(character: char) -> bool {
    matches!(
        character as u32,
        0x3400..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2EBEF
    )
}

#[derive(Debug)]
pub(super) struct LogRow {
    pub(super) id: i64,
    pub(super) thread_id: Option<String>,
    pub(super) ts: i64,
    pub(super) ts_nanos: i64,
    pub(super) target: String,
    pub(super) feedback_log_body: String,
}

impl LogRow {
    fn timestamp(&self) -> f64 {
        self.ts as f64 + self.ts_nanos as f64 / 1_000_000_000.0
    }
}

#[derive(Debug, Deserialize)]
struct ResponseStreamEvent {
    #[serde(rename = "type")]
    event_type: String,
    delta: Option<String>,
    #[serde(rename = "item_id")]
    item_id: Option<String>,
    #[serde(rename = "sequence_number")]
    sequence_number: Option<i64>,
    item: Option<ResponseStreamItem>,
}

#[derive(Debug, Deserialize)]
struct ResponseStreamItem {
    id: Option<String>,
    name: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum LiveTokenCategory {
    VisibleText,
    ToolArguments,
    PatchInput,
    PatchApplied,
    ToolOutput,
    Reasoning,
}

impl LiveTokenCategory {
    pub(super) fn key(self) -> &'static str {
        match self {
            LiveTokenCategory::VisibleText => "visibleText",
            LiveTokenCategory::ToolArguments => "toolArguments",
            LiveTokenCategory::PatchInput => "patchInput",
            LiveTokenCategory::PatchApplied => "patchApplied",
            LiveTokenCategory::ToolOutput => "toolOutput",
            LiveTokenCategory::Reasoning => "reasoning",
        }
    }

    pub(super) fn contributes_to_live_rate(self) -> bool {
        matches!(
            self,
            LiveTokenCategory::VisibleText
                | LiveTokenCategory::ToolArguments
                | LiveTokenCategory::PatchInput
        )
    }
}

#[derive(Clone, Debug)]
pub(super) struct LiveMetricEvent {
    pub(super) event_type: String,
    pub(super) timestamp: f64,
    pub(super) thread_id: Option<String>,
    pub(super) item_id: String,
    pub(super) sequence_number: Option<i64>,
    pub(super) category: LiveTokenCategory,
    pub(super) delta: String,
    pub(super) exact_tokens: Option<u32>,
    pub(super) start_timestamp: Option<f64>,
    pub(super) distributed: bool,
    pub(super) dedupe_key: Option<String>,
}

impl LiveMetricEvent {
    pub(super) fn fingerprint(&self) -> String {
        if let Some(key) = &self.dedupe_key {
            return key.clone();
        }
        if let Some(sequence_number) = self.sequence_number {
            format!(
                "{}:{}:{}:{}",
                self.event_type, self.item_id, sequence_number, self.delta
            )
        } else {
            format!(
                "{}:{}:{:.6}:{}",
                self.event_type, self.item_id, self.timestamp, self.delta
            )
        }
    }
}

pub(super) struct LiveRateRollup {
    pub(super) tokens_per_second: f64,
    pub(super) latest_thread_id: Option<String>,
    pub(super) breakdown: LiveTokenBreakdown,
}

impl Default for LiveRateRollup {
    fn default() -> Self {
        Self {
            tokens_per_second: 0.0,
            latest_thread_id: None,
            breakdown: LiveTokenBreakdown::default(),
        }
    }
}

#[derive(Default)]
pub(super) struct LiveTokenBreakdown {
    pub(super) visible_text: u32,
    pub(super) tool_arguments: u32,
    pub(super) patch_input: u32,
    pub(super) patch_applied: u32,
    pub(super) tool_output: u32,
    pub(super) reasoning: u32,
}

impl LiveTokenBreakdown {
    pub(super) fn observed_total(&self) -> u32 {
        self.visible_text
            + self.tool_arguments
            + self.patch_input
            + self.patch_applied
            + self.tool_output
            + self.reasoning
    }

    fn add(&mut self, category: LiveTokenCategory, tokens: u32) {
        match category {
            LiveTokenCategory::VisibleText => self.visible_text += tokens,
            LiveTokenCategory::ToolArguments => self.tool_arguments += tokens,
            LiveTokenCategory::PatchInput => self.patch_input += tokens,
            LiveTokenCategory::PatchApplied => self.patch_applied += tokens,
            LiveTokenCategory::ToolOutput => self.tool_output += tokens,
            LiveTokenCategory::Reasoning => self.reasoning += tokens,
        }
    }
}
