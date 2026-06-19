use crate::core::quota_history;
use crate::models::{
    AccountInfo, DashboardSnapshot, LocalDataWarning, QuotaLimit, QuotaSnapshot,
    ResetCreditSummary,
};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

mod aggregates;
mod ranking;
mod session_parser;
mod token_event_cache;

use aggregates::{activity_days, recent_usage, stats};
use ranking::cache_hit_ranking;
use token_event_cache::{
    codex_home_cache_key, file_cache_key, parse_session_file_cached, token_cache_warning,
    TokenEventCache,
};

#[cfg(test)]
use token_event_cache::{CachedCodexHome, CachedFileSignature, CachedSessionFile, CachedTokenEvent};

#[derive(Clone, Debug)]
struct TokenEvent {
    timestamp: OffsetDateTime,
    session_id: String,
    tokens: u64,
    input_tokens: u64,
    cached_input_tokens: u64,
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
    use std::collections::HashMap;
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
