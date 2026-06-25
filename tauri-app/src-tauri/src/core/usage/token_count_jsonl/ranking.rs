use super::{aggregates::TokenAccumulator, TokenEvent};
use crate::core::sqlite;
use crate::models::{
    CacheHitRankingItem, LocalDataWarning, SessionCacheUsage, TokenCacheBreakdown,
    TokenCacheUsage, TurnCacheUsage,
};
use std::collections::HashMap;
use std::path::Path;
use std::time::Duration as StdDuration;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

#[derive(Clone, Debug)]
struct ThreadInfo {
    title: String,
    updated_at: Option<OffsetDateTime>,
}

pub(super) fn cache_hit_ranking(
    events: &[TokenEvent],
    codex_home: &Path,
    local_offset: UtcOffset,
    warnings: &mut Vec<LocalDataWarning>,
) -> Vec<CacheHitRankingItem> {
    let minimum_input_tokens = 1_000;
    let mut by_session: HashMap<&str, TokenAccumulator> = HashMap::new();
    let mut last_seen: HashMap<&str, OffsetDateTime> = HashMap::new();

    for event in events {
        by_session.entry(event.session_id.as_str()).or_default().add(event);
        last_seen
            .entry(event.session_id.as_str())
            .and_modify(|timestamp| {
                if event.timestamp > *timestamp {
                    *timestamp = event.timestamp;
                }
            })
            .or_insert(event.timestamp);
    }

    let rows: Vec<_> = by_session
        .into_iter()
        .filter(|(_, usage)| usage.calls > 1 && usage.input_tokens >= minimum_input_tokens)
        .map(|(session_id, usage)| (session_id.to_string(), usage))
        .collect();

    if rows.is_empty() {
        return Vec::new();
    }

    let thread_info = read_thread_info(codex_home, warnings);
    let mut rows: Vec<_> = rows
        .into_iter()
        .map(|(session_id, usage)| {
            let info = thread_info.get(&session_id);
            let updated_at = info
                .and_then(|value| value.updated_at)
                .or_else(|| last_seen.get(session_id.as_str()).copied());
            let title = info
                .map(|value| value.title.clone())
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| fallback_session_title(&session_id));
            let uncached = usage.input_tokens.saturating_sub(usage.cached_input_tokens);
            (session_id, usage, title, updated_at, uncached)
        })
        .collect();

    rows.sort_by(|left, right| {
        let left_rate = left.1.cache_hit_rate();
        let right_rate = right.1.cache_hit_rate();
        left_rate
            .partial_cmp(&right_rate)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| right.4.cmp(&left.4))
            .then_with(|| left.2.cmp(&right.2))
    });

    rows.into_iter()
        .take(10)
        .enumerate()
        .map(|(index, (_, usage, title, updated_at, _))| CacheHitRankingItem {
            rank: u32::try_from(index + 1).unwrap_or(u32::MAX),
            title,
            subtitle: session_ranking_subtitle(&usage, updated_at, local_offset),
            hit_rate: usage.cache_hit_rate(),
            input_tokens: usage.input_tokens,
            cached_tokens: usage.cached_input_tokens,
        })
        .collect()
}

pub(super) fn cache_usage(
    events: &[TokenEvent],
    codex_home: &Path,
    _local_offset: UtcOffset,
    warnings: &mut Vec<LocalDataWarning>,
) -> TokenCacheUsage {
    let thread_info = read_thread_info(codex_home, warnings);
    let mut by_session: HashMap<&str, TokenAccumulator> = HashMap::new();
    let mut last_seen: HashMap<&str, OffsetDateTime> = HashMap::new();

    for event in events {
        by_session.entry(event.session_id.as_str()).or_default().add(event);
        last_seen
            .entry(event.session_id.as_str())
            .and_modify(|timestamp| {
                if event.timestamp > *timestamp {
                    *timestamp = event.timestamp;
                }
            })
            .or_insert(event.timestamp);
    }

    let mut sessions = by_session
        .into_iter()
        .map(|(session_id, usage)| {
            let info = thread_info.get(session_id);
            let updated_at = info
                .and_then(|value| value.updated_at)
                .or_else(|| last_seen.get(session_id).copied());
            SessionCacheUsage {
                id: session_id.to_string(),
                title: info
                    .map(|value| value.title.clone())
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| fallback_session_title(session_id)),
                last_updated: updated_at.and_then(format_rfc3339),
                breakdown: breakdown_from_accumulator(&usage),
            }
        })
        .collect::<Vec<_>>();
    sessions.sort_by(|left, right| {
        right
            .last_updated
            .cmp(&left.last_updated)
            .then_with(|| right.breakdown.total_tokens.cmp(&left.breakdown.total_tokens))
    });

    let mut ordered_events = events.iter().enumerate().collect::<Vec<_>>();
    ordered_events.sort_by(|left, right| {
        left.1
            .timestamp
            .cmp(&right.1.timestamp)
            .then_with(|| left.0.cmp(&right.0))
    });
    let mut turn_index_by_session: HashMap<&str, u32> = HashMap::new();
    let mut turns = ordered_events
        .into_iter()
        .map(|(index, event)| {
            let turn_index = turn_index_by_session
                .entry(event.session_id.as_str())
                .and_modify(|value| *value = value.saturating_add(1))
                .or_insert(1);
            let info = thread_info.get(event.session_id.as_str());
            TurnCacheUsage {
                id: format!("{}-{}-{index}", event.session_id, event.timestamp.unix_timestamp()),
                session_id: event.session_id.clone(),
                session_title: info
                    .map(|value| value.title.clone())
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| fallback_session_title(&event.session_id)),
                timestamp: format_rfc3339(event.timestamp).unwrap_or_default(),
                turn_index_in_session: *turn_index,
                user_prompt: event.user_prompt.clone(),
                assistant_response: event.assistant_response.clone(),
                breakdown: breakdown_from_event(event),
            }
        })
        .collect::<Vec<_>>();
    turns.sort_by(|left, right| right.timestamp.cmp(&left.timestamp));

    TokenCacheUsage { sessions, turns }
}

pub(super) fn sanitize_cache_usage_for_persistence(mut usage: TokenCacheUsage) -> TokenCacheUsage {
    for turn in &mut usage.turns {
        turn.user_prompt.clear();
        turn.assistant_response.clear();
    }
    usage
}

fn thread_info_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "thread_info".into(),
        message,
    }
}

fn read_thread_info(
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> HashMap<String, ThreadInfo> {
    let db_path = codex_home.join("state_5.sqlite");
    let connection = match sqlite::open_read_only(&db_path, StdDuration::from_secs(3)) {
        Ok(connection) => connection,
        Err(error) => {
            warnings.push(thread_info_warning(format!(
                "读取会话标题索引失败：{}（{}）",
                db_path.display(),
                error
            )));
            return HashMap::new();
        }
    };

    let mut statement = match connection.prepare(
        r#"
        SELECT id, title, first_user_message, preview, COALESCE(updated_at_ms, updated_at)
        FROM threads;
        "#,
    ) {
        Ok(statement) => statement,
        Err(error) => {
            warnings.push(thread_info_warning(format!(
                "读取会话标题索引结构失败：{}（{}）",
                db_path.display(),
                error
            )));
            return HashMap::new();
        }
    };

    let rows = match statement.query_map([], |row| {
        let id: String = row.get(0)?;
        let title: Option<String> = row.get(1)?;
        let first_user_message: Option<String> = row.get(2)?;
        let preview: Option<String> = row.get(3)?;
        let updated_at: Option<i64> = row.get(4)?;
        Ok((
            id,
            ThreadInfo {
                title: first_non_empty([title, first_user_message, preview])
                    .unwrap_or_else(|| "Untitled".into()),
                updated_at: updated_at.and_then(parse_thread_timestamp),
            },
        ))
    }) {
        Ok(rows) => rows,
        Err(error) => {
            warnings.push(thread_info_warning(format!(
                "读取会话标题索引数据失败：{}（{}）",
                db_path.display(),
                error
            )));
            return HashMap::new();
        }
    };

    rows.filter_map(Result::ok).collect()
}

fn first_non_empty(values: [Option<String>; 3]) -> Option<String> {
    values
        .into_iter()
        .filter_map(|value| {
            let trimmed = value?.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        })
        .next()
}

fn parse_thread_timestamp(value: i64) -> Option<OffsetDateTime> {
    let seconds = if value > 10_000_000_000 {
        value / 1000
    } else {
        value
    };
    OffsetDateTime::from_unix_timestamp(seconds).ok()
}

fn fallback_session_title(session_id: &str) -> String {
    let short_id = session_id.chars().take(8).collect::<String>();
    if short_id.is_empty() {
        "未知会话".into()
    } else {
        format!("会话 {short_id}")
    }
}

fn session_ranking_subtitle(
    usage: &TokenAccumulator,
    updated_at: Option<OffsetDateTime>,
    local_offset: UtcOffset,
) -> String {
    let time = updated_at
        .map(|timestamp| format_month_day_time(timestamp.to_offset(local_offset)))
        .unwrap_or_else(|| "未知时间".into());
    format!("{} 轮 · {}", usage.calls, time)
}

fn breakdown_from_accumulator(usage: &TokenAccumulator) -> TokenCacheBreakdown {
    TokenCacheBreakdown {
        input_tokens: usage.input_tokens,
        cached_input_tokens: usage.cached_input_tokens.min(usage.input_tokens),
        output_tokens: usage.output_tokens,
        total_tokens: usage.tokens,
        calls: usage.calls,
    }
}

fn breakdown_from_event(event: &TokenEvent) -> TokenCacheBreakdown {
    TokenCacheBreakdown {
        input_tokens: event.input_tokens,
        cached_input_tokens: event.cached_input_tokens.min(event.input_tokens),
        output_tokens: event.output_tokens,
        total_tokens: event.tokens,
        calls: 1,
    }
}

fn format_rfc3339(date: OffsetDateTime) -> Option<String> {
    date.format(&time::format_description::well_known::Rfc3339)
        .ok()
}

fn format_month_day_time(date: OffsetDateTime) -> String {
    date.format(format_description!("[month]/[day] [hour]:[minute]"))
        .unwrap_or_else(|_| "未知时间".into())
}
