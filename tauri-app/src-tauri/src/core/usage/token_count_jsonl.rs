use crate::core::quota_history;
use crate::core::sqlite;
use crate::models::{
    AccountInfo, ActivityDay, CacheHitRankingItem, DashboardSnapshot, DashboardStats,
    LocalDataWarning, QuotaLimit, QuotaSnapshot, RecentUsagePoint, ResetCreditSummary,
};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration as StdDuration;
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

mod session_parser;
mod token_event_cache;

use token_event_cache::{
    codex_home_cache_key, file_cache_key, parse_session_file_cached, token_cache_warning,
    TokenEventCache,
};

#[cfg(test)]
use token_event_cache::{CachedCodexHome, CachedFileSignature, CachedSessionFile, CachedTokenEvent};

const RECENT_INTERVAL_SECONDS: i64 = 5 * 60;
const RECENT_POINT_COUNT: i64 = 289;

#[derive(Clone, Debug)]
struct TokenEvent {
    timestamp: OffsetDateTime,
    session_id: String,
    tokens: u64,
    input_tokens: u64,
    cached_input_tokens: u64,
}

#[derive(Default)]
struct TokenAccumulator {
    tokens: u64,
    calls: u32,
    input_tokens: u64,
    cached_input_tokens: u64,
}

impl TokenAccumulator {
    fn add(&mut self, event: &TokenEvent) {
        self.tokens = self.tokens.saturating_add(event.tokens);
        self.calls = self.calls.saturating_add(1);
        self.input_tokens = self.input_tokens.saturating_add(event.input_tokens);
        self.cached_input_tokens = self
            .cached_input_tokens
            .saturating_add(event.cached_input_tokens);
    }

    fn cache_hit_rate(&self) -> f64 {
        if self.input_tokens == 0 {
            0.0
        } else {
            self.cached_input_tokens as f64 / self.input_tokens as f64
        }
    }
}

#[derive(Clone, Debug)]
struct ThreadInfo {
    title: String,
    updated_at: Option<OffsetDateTime>,
}

pub fn dashboard_snapshot(codex_home: &Path) -> Result<DashboardSnapshot, String> {
    let sessions_root = codex_home.join("sessions");
    if !sessions_root.exists() {
        return Err(format!("{} not found", sessions_root.display()));
    }

    let mut events = Vec::new();
    let mut warnings = Vec::new();
    let session_files = jsonl_files(&sessions_root, &mut warnings);
    let mut cache = TokenEventCache::load(&mut warnings);
    let home_cache_key = codex_home_cache_key(codex_home);
    let home_cache = cache.home_cache_mut(&home_cache_key, codex_home);
    let mut seen_cache_keys = HashSet::new();
    let mut cache_changed = false;
    for file in session_files {
        let session_id = session_id_from_file(&file);
        let cache_key = file_cache_key(codex_home, &file);
        seen_cache_keys.insert(cache_key);
        events.extend(parse_session_file_cached(
            &file,
            &session_id,
            &mut home_cache.files,
            &mut cache_changed,
            codex_home,
            &mut warnings,
        ));
    }
    if home_cache.retain_seen(&seen_cache_keys) {
        cache_changed = true;
    }
    if cache_changed {
        if let Err(error) = cache.save() {
            warnings.push(token_cache_warning(error));
        }
    }

    if events.is_empty() {
        return Err(no_token_events_error(&warnings));
    }

    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let generated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    let mut activity_days = activity_days(&events, local_offset);
    if let Err(error) = quota_history::apply_activity_history(&mut activity_days) {
        warnings.push(quota_history::warning(error));
    }
    let recent_usage_24h = recent_usage(&events, local_offset);
    let stats = stats(&events, &activity_days);
    let cache_hit_ranking = cache_hit_ranking(&events, codex_home, local_offset, &mut warnings);

    Ok(DashboardSnapshot {
        generated_at,
        account: AccountInfo {
            display_name: "账户待读取".into(),
            plan_label: "计划待读取".into(),
        },
        stats,
        quota: placeholder_quota(),
        activity_days,
        recent_usage_24h,
        cache_hit_ranking,
        warnings,
    })
}

fn jsonl_scan_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "jsonl_scan".into(),
        message,
    }
}

fn thread_info_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "thread_info".into(),
        message,
    }
}

fn no_token_events_error(warnings: &[LocalDataWarning]) -> String {
    if warnings.is_empty() {
        return "No token_count events found".into();
    }
    let details = warnings
        .iter()
        .map(|warning| format!("{}: {}", warning.source, warning.message))
        .collect::<Vec<_>>()
        .join("；");
    format!("No token_count events found；{details}")
}

fn jsonl_files(root: &Path, warnings: &mut Vec<LocalDataWarning>) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_jsonl_files(root, &mut files, warnings);
    files
}

fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>, warnings: &mut Vec<LocalDataWarning>) {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) => {
            warnings.push(jsonl_scan_warning(format!(
                "读取会话目录失败：{}（{}）",
                root.display(),
                error
            )));
            return;
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                warnings.push(jsonl_scan_warning(format!(
                    "读取会话目录项失败：{}（{}）",
                    root.display(),
                    error
                )));
                continue;
            }
        };
        let path = entry.path();
        if path.is_dir() {
            collect_jsonl_files(&path, files, warnings);
        } else if path.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(path);
        }
    }
}

fn session_id_from_file(file: &Path) -> String {
    let stem = file.file_stem().and_then(|value| value.to_str()).unwrap_or_default();
    let parts: Vec<&str> = stem.split('-').collect();
    let start = parts.len().saturating_sub(5);
    parts[start..].join("-")
}

fn activity_days(events: &[TokenEvent], local_offset: UtcOffset) -> Vec<ActivityDay> {
    let today = OffsetDateTime::now_utc().to_offset(local_offset).date();
    let start = today - Duration::days(364);
    let mut grouped: HashMap<Date, TokenAccumulator> = HashMap::new();

    for event in events {
        let day = event.timestamp.to_offset(local_offset).date();
        if day >= start && day <= today {
            grouped.entry(day).or_default().add(event);
        }
    }

    (0..365)
        .map(|offset| {
            let day = start + Duration::days(offset);
            let usage = grouped.remove(&day).unwrap_or_default();
            ActivityDay {
                date: format_date(day),
                tokens: usage.tokens,
                calls: usage.calls,
                cache_hit_rate: usage.cache_hit_rate(),
                five_hour_remaining_percent: None,
                seven_day_remaining_percent: None,
            }
        })
        .collect()
}

fn recent_usage(events: &[TokenEvent], local_offset: UtcOffset) -> Vec<RecentUsagePoint> {
    let now_epoch = OffsetDateTime::now_utc().unix_timestamp();
    let end_bin = floor_to_recent_bin(now_epoch);
    let start_bin = end_bin - 24 * 60 * 60;
    let mut grouped: HashMap<i64, TokenAccumulator> = HashMap::new();

    for event in events {
        let bin_epoch = floor_to_recent_bin(event.timestamp.unix_timestamp());
        if bin_epoch < start_bin || bin_epoch > end_bin {
            continue;
        }
        grouped.entry(bin_epoch).or_default().add(event);
    }

    (0..RECENT_POINT_COUNT)
        .map(|offset| {
            let bin_epoch = start_bin + offset * RECENT_INTERVAL_SECONDS;
            let bin_time = OffsetDateTime::from_unix_timestamp(bin_epoch)
                .unwrap_or_else(|_| OffsetDateTime::now_utc());
            let usage = grouped.remove(&bin_epoch).unwrap_or_default();
            RecentUsagePoint {
                label: format_time(bin_time.to_offset(local_offset)),
                tokens: usage.tokens,
                calls: usage.calls,
                cache_hit_rate: if usage.input_tokens > 0 {
                    Some(usage.cache_hit_rate())
                } else {
                    None
                },
                five_hour_remaining_percent: None,
                seven_day_remaining_percent: None,
            }
        })
        .collect()
}

fn floor_to_recent_bin(timestamp: i64) -> i64 {
    timestamp - timestamp.rem_euclid(RECENT_INTERVAL_SECONDS)
}

fn stats(events: &[TokenEvent], days: &[ActivityDay]) -> DashboardStats {
    let total_tokens = events.iter().map(|event| event.tokens).sum();
    let peak_day_tokens = days.iter().map(|day| day.tokens).max().unwrap_or(0);
    let mut by_session: HashMap<&str, u64> = HashMap::new();
    let mut sessions = HashSet::new();

    for event in events {
        sessions.insert(event.session_id.as_str());
        *by_session.entry(event.session_id.as_str()).or_default() += event.tokens;
    }

    DashboardStats {
        total_tokens,
        peak_day_tokens,
        peak_thread_tokens: by_session.values().copied().max().unwrap_or(0),
        current_streak_days: current_streak_days(days),
        longest_streak_days: longest_streak_days(days),
        total_calls: u32::try_from(events.len()).unwrap_or(u32::MAX),
        total_threads: u32::try_from(sessions.len()).unwrap_or(u32::MAX),
    }
}

fn cache_hit_ranking(
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

fn read_thread_info(codex_home: &Path, warnings: &mut Vec<LocalDataWarning>) -> HashMap<String, ThreadInfo> {
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

fn current_streak_days(days: &[ActivityDay]) -> u32 {
    let mut streak = 0;
    for day in days.iter().rev() {
        if day.tokens > 0 {
            streak += 1;
        } else if streak > 0 {
            break;
        }
    }
    streak
}

fn longest_streak_days(days: &[ActivityDay]) -> u32 {
    let mut best = 0;
    let mut current = 0;
    for day in days {
        if day.tokens > 0 {
            current += 1;
            best = best.max(current);
        } else {
            current = 0;
        }
    }
    best
}

fn format_date(date: Date) -> String {
    date.format(format_description!("[year]-[month]-[day]"))
        .unwrap_or_else(|_| "1970-01-01".into())
}

fn format_time(date: OffsetDateTime) -> String {
    date.format(format_description!("[hour]:[minute]"))
        .unwrap_or_else(|_| "00:00".into())
}

fn format_month_day_time(date: OffsetDateTime) -> String {
    date.format(format_description!("[month]/[day] [hour]:[minute]"))
        .unwrap_or_else(|_| "未知时间".into())
}

fn placeholder_quota() -> QuotaSnapshot {
    QuotaSnapshot {
        five_hour: QuotaLimit {
            label: "5h".into(),
            remaining_percent: 0.0,
            used_percent: 0.0,
            resets_at: "待读取".into(),
            resets_at_unix: None,
        },
        seven_day: QuotaLimit {
            label: "7d".into(),
            remaining_percent: 0.0,
            used_percent: 0.0,
            resets_at: "待读取".into(),
            resets_at_unix: None,
        },
        reset_credit: ResetCreditSummary {
            available_count: 0,
            status: "重置卡待读取".into(),
            credits: Vec::new(),
        },
        pace_label: "额度待读取".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn parses_token_count_totals_as_deltas() {
        let root = temp_root();
        let session_dir = root.join("sessions").join("2026").join("06").join("18");
        fs::create_dir_all(&session_dir).unwrap();
        let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
        write_lines(
            &file,
            &[
                r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"total_tokens":13},"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"total_tokens":13}}}}"#,
                r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":8,"total_tokens":28},"last_token_usage":{"input_tokens":10,"cached_input_tokens":3,"output_tokens":5,"total_tokens":15}}}}"#,
            ],
        );

        let snapshot = dashboard_snapshot(&root).unwrap();
        assert_eq!(snapshot.stats.total_tokens, 28);
        assert_eq!(snapshot.stats.total_calls, 2);
        assert_eq!(snapshot.stats.total_threads, 1);
        assert!(snapshot.activity_days.iter().any(|day| day.tokens == 28));
        assert_eq!(snapshot.recent_usage_24h.len(), 289);

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn skips_fork_replay_window() {
        let root = temp_root();
        let session_dir = root.join("sessions");
        fs::create_dir_all(&session_dir).unwrap();
        let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
        write_lines(
            &file,
            &[
                r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
                r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#,
                r#"{"timestamp":"2026-06-18T01:00:40Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":20}}}}"#,
            ],
        );

        let snapshot = dashboard_snapshot(&root).unwrap();
        assert_eq!(snapshot.stats.total_tokens, 20);

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn ranks_sessions_by_low_cache_hit_rate_with_thread_titles() {
        let root = temp_root();
        let session_dir = root.join("sessions");
        fs::create_dir_all(&session_dir).unwrap();
        let low_id = "019elow0-0000-0000-0000-000000000001";
        let high_id = "019ehigh-0000-0000-0000-000000000002";
        write_lines(
            &session_dir.join(format!("rollout-{low_id}.jsonl")),
            &[
                r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":300,"output_tokens":50,"total_tokens":1250}}}}"#,
                r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":40,"total_tokens":1040}}}}"#,
            ],
        );
        write_lines(
            &session_dir.join(format!("rollout-{high_id}.jsonl")),
            &[
                r#"{"timestamp":"2026-06-18T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1100,"output_tokens":50,"total_tokens":1250}}}}"#,
                r#"{"timestamp":"2026-06-18T02:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":40,"total_tokens":1040}}}}"#,
            ],
        );
        create_state_database(&root, low_id, high_id);

        let snapshot = dashboard_snapshot(&root).unwrap();
        assert_eq!(snapshot.cache_hit_ranking.len(), 2);
        assert_eq!(snapshot.cache_hit_ranking[0].rank, 1);
        assert_eq!(snapshot.cache_hit_ranking[0].title, "低命中会话");
        assert_eq!(snapshot.cache_hit_ranking[0].input_tokens, 2_200);
        assert_eq!(snapshot.cache_hit_ranking[0].cached_tokens, 500);
        assert!(snapshot.cache_hit_ranking[0].hit_rate < snapshot.cache_hit_ranking[1].hit_rate);
        assert!(snapshot.cache_hit_ranking[0].subtitle.contains("2 轮"));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn token_event_cache_serializes_only_usage_summary() {
        let mut cache = TokenEventCache::default();
        cache.homes.insert(
            "home-a".into(),
            CachedCodexHome {
                codex_home: "/tmp/codex-a".into(),
                files: HashMap::new(),
            },
        );
        cache.homes.get_mut("home-a").unwrap().files.insert(
            "/tmp/session.jsonl".into(),
            CachedSessionFile {
                signature: CachedFileSignature {
                    size: 128,
                    modified_millis: 1_781_715_600_000,
                },
                events: vec![CachedTokenEvent {
                    timestamp_unix: 1_781_715_600,
                    tokens: 42,
                    input_tokens: 40,
                    cached_input_tokens: 30,
                }],
            },
        );

        let serialized = serde_json::to_string(&cache).unwrap();
        assert!(serialized.contains("cachedInputTokens"));
        assert!(!serialized.contains("userPrompt"));
        assert!(!serialized.contains("assistantResponse"));
        assert!(!serialized.contains("用户问题"));
        assert!(!serialized.contains("模型回答"));
    }

    #[test]
    fn token_event_cache_partitions_entries_by_codex_home() {
        let root = temp_root();
        let home_a = root.join("codex-a");
        let home_b = root.join("codex-b");
        fs::create_dir_all(&home_a).unwrap();
        fs::create_dir_all(&home_b).unwrap();

        let key_a = codex_home_cache_key(&home_a);
        let key_b = codex_home_cache_key(&home_b);
        let mut cache = TokenEventCache::default();

        cache
            .home_cache_mut(&key_a, &home_a)
            .files
            .insert("sessions/a.jsonl".into(), cached_file_with_one_event(10));
        cache
            .home_cache_mut(&key_b, &home_b)
            .files
            .insert("sessions/b.jsonl".into(), cached_file_with_one_event(20));

        let mut seen = HashSet::new();
        seen.insert("sessions/a.jsonl".into());
        assert!(!cache.home_cache_mut(&key_a, &home_a).retain_seen(&seen));

        assert_eq!(cache.homes.get(&key_a).unwrap().files.len(), 1);
        assert_eq!(cache.homes.get(&key_b).unwrap().files.len(), 1);
        assert!(cache
            .homes
            .get(&key_b)
            .unwrap()
            .files
            .contains_key("sessions/b.jsonl"));

        fs::remove_dir_all(root).unwrap();
    }

    fn temp_root() -> PathBuf {
        let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "codex-token-bar-tauri-jsonl-{}-{}-{}",
            std::process::id(),
            sequence,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn write_lines(path: &Path, lines: &[&str]) {
        let mut file = fs::File::create(path).unwrap();
        for line in lines {
            writeln!(file, "{line}").unwrap();
        }
    }

    fn create_state_database(root: &Path, low_id: &str, high_id: &str) {
        let db_path = root.join("state_5.sqlite");
        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    first_user_message TEXT,
                    preview TEXT,
                    updated_at INTEGER NOT NULL,
                    updated_at_ms INTEGER
                );
                "#,
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO threads (id, title, first_user_message, preview, updated_at, updated_at_ms) VALUES (?1, '低命中会话', '', '', 1781715600, 1781715600000);",
                [low_id],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO threads (id, title, first_user_message, preview, updated_at, updated_at_ms) VALUES (?1, '高命中会话', '', '', 1781719200, 1781719200000);",
                [high_id],
            )
            .unwrap();
    }

    fn cached_file_with_one_event(tokens: u64) -> CachedSessionFile {
        CachedSessionFile {
            signature: CachedFileSignature {
                size: tokens,
                modified_millis: 1_781_715_600_000,
            },
            events: vec![CachedTokenEvent {
                timestamp_unix: 1_781_715_600,
                tokens,
                input_tokens: tokens,
                cached_input_tokens: tokens / 2,
            }],
        }
    }
}
