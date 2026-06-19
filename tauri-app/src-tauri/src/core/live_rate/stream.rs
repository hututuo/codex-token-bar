use serde::Deserialize;
use std::collections::{HashMap, HashSet};

const WINDOW_SECONDS: f64 = 2.5;
const MINIMUM_RATE_SPAN_SECONDS: f64 = 0.4;

pub(super) fn rollup_stream_rows(
    rows: &[LogRow],
    now: f64,
    selected_thread_id: Option<&str>,
) -> LiveRateRollup {
    let mut seen = HashSet::<String>::new();
    let mut text_by_key = HashMap::<String, String>::new();
    let mut tokens_by_key = HashMap::<String, u32>::new();
    let mut rolling_deltas = Vec::<(f64, u32)>::new();
    let mut latest_thread_id = None;
    let window_start = now - WINDOW_SECONDS;

    for row in rows {
        let Some(event) = stream_event(row) else {
            continue;
        };
        let Some(metric) = metric_event(event, row) else {
            continue;
        };
        if let Some(selected_thread_id) = selected_thread_id {
            if metric.thread_id.as_deref() != Some(selected_thread_id) {
                continue;
            }
        }
        let fingerprint = metric.fingerprint(row);
        if !seen.insert(fingerprint) {
            continue;
        }

        let key = format!(
            "{}:{}:{}",
            metric.thread_id.as_deref().unwrap_or(""),
            metric.item_id,
            metric.category.key()
        );
        let text = text_by_key.entry(key.clone()).or_default();
        text.push_str(&metric.delta);

        let previous_tokens = *tokens_by_key.get(&key).unwrap_or(&0);
        let next_tokens = estimate_token_count(text, metric.category);
        tokens_by_key.insert(key, next_tokens);

        let delta_tokens = next_tokens.saturating_sub(previous_tokens);
        if delta_tokens > 0 && metric.timestamp >= window_start && metric.timestamp <= now + 0.25 {
            rolling_deltas.push((metric.timestamp, delta_tokens));
            if let Some(thread_id) = metric.thread_id {
                latest_thread_id = Some(thread_id);
            }
        }
    }

    let tokens_per_second = rolling_rate(&rolling_deltas, now);
    LiveRateRollup {
        tokens_per_second,
        latest_thread_id: if tokens_per_second > 0.0 {
            latest_thread_id
        } else {
            None
        },
    }
}

fn stream_event(row: &LogRow) -> Option<ResponseStreamEvent> {
    let marker = match row.target.as_str() {
        "codex_api::sse::responses" => "SSE event: ",
        "codex_api::endpoint::responses_websocket" => "websocket event: ",
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

    Some(LiveMetricEvent {
        event_type: event.event_type,
        timestamp: row.timestamp(),
        thread_id: row.thread_id.clone(),
        item_id,
        sequence_number: event.sequence_number,
        category,
        delta,
    })
}

fn rolling_rate(rolling_deltas: &[(f64, u32)], now: f64) -> f64 {
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
enum LiveTokenCategory {
    VisibleText,
    ToolArguments,
    PatchInput,
}

impl LiveTokenCategory {
    fn key(self) -> &'static str {
        match self {
            LiveTokenCategory::VisibleText => "visibleText",
            LiveTokenCategory::ToolArguments => "toolArguments",
            LiveTokenCategory::PatchInput => "patchInput",
        }
    }
}

#[derive(Debug)]
struct LiveMetricEvent {
    event_type: String,
    timestamp: f64,
    thread_id: Option<String>,
    item_id: String,
    sequence_number: Option<i64>,
    category: LiveTokenCategory,
    delta: String,
}

impl LiveMetricEvent {
    fn fingerprint(&self, row: &LogRow) -> String {
        if let Some(sequence_number) = self.sequence_number {
            format!(
                "{}:{}:{}:{}",
                self.event_type, self.item_id, sequence_number, self.delta
            )
        } else {
            format!("row:{}:{}:{}", row.id, self.event_type, self.delta)
        }
    }
}

pub(super) struct LiveRateRollup {
    pub(super) tokens_per_second: f64,
    pub(super) latest_thread_id: Option<String>,
}
