use super::{aggregates::TokenAccumulator, TokenEvent};
use crate::core::sqlite;
use crate::models::{CacheHitRankingItem, LocalDataWarning};
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

fn format_month_day_time(date: OffsetDateTime) -> String {
    date.format(format_description!("[month]/[day] [hour]:[minute]"))
        .unwrap_or_else(|_| "未知时间".into())
}
