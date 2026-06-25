use super::token_event_cache::{
    codex_home_cache_key, parse_session_file_cached, CachedCodexHome, CachedFileSignature,
    CachedSessionFile, CachedTokenEvent, TokenEventCache,
};
use super::session_parser::{
    reset_session_full_parse_count_for_testing, session_full_parse_count_for_testing,
};
use super::*;
use rusqlite::Connection;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[test]
fn parses_token_count_totals_as_deltas() {
    let root = temp_root();
    let session_dir = root.join("sessions").join("2026").join("06").join("18");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    let first_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(10))
        .format(&Rfc3339)
        .unwrap();
    let second_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(5))
        .format(&Rfc3339)
        .unwrap();
    let first_line = format!(
        r#"{{"timestamp":"{first_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"total_tokens":13}},"last_token_usage":{{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"total_tokens":13}}}}}}}}"#
    );
    let second_line = format!(
        r#"{{"timestamp":"{second_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":20,"cached_input_tokens":5,"output_tokens":8,"total_tokens":28}},"last_token_usage":{{"input_tokens":10,"cached_input_tokens":3,"output_tokens":5,"total_tokens":15}}}}}}}}"#
    );
    write_lines(
        &file,
        &[first_line, second_line],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 28);
    assert_eq!(snapshot.stats.total_calls, 2);
    assert_eq!(snapshot.stats.total_threads, 1);
    assert!(snapshot.activity_days.iter().any(|day| day.tokens == 28));
    assert_eq!(snapshot.recent_usage_24h.len(), 289);
    assert_eq!(snapshot.recent_usage_7d.len(), 168);
    assert_eq!(snapshot.recent_usage_30d.len(), 120);
    assert_eq!(
        snapshot
            .recent_usage_7d
            .iter()
            .map(|point| point.input_tokens)
            .sum::<u64>(),
        20
    );
    assert_eq!(
        snapshot
            .recent_usage_7d
            .iter()
            .map(|point| point.cached_input_tokens)
            .sum::<u64>(),
        5
    );
    assert_eq!(
        snapshot
            .recent_usage_7d
            .iter()
            .map(|point| point.output_tokens)
            .sum::<u64>(),
        8
    );
    assert!(snapshot
        .recent_usage_7d
        .windows(2)
        .all(|window| window[1].start_unix - window[0].start_unix == 60 * 60));
    assert!(snapshot
        .recent_usage_30d
        .windows(2)
        .all(|window| window[1].start_unix - window[0].start_unix == 6 * 60 * 60));

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
fn usage_summary_counts_today_from_token_events_not_thread_updated_at() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let now = OffsetDateTime::now_utc();
    let yesterday = now - time::Duration::days(1);
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            &format!(
                r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":1000}}}}}}}}"#,
                yesterday.format(&Rfc3339).unwrap()
            ),
            &format!(
                r#"{{"timestamp":"{}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":40}}}}}}}}"#,
                now.format(&Rfc3339).unwrap()
            ),
        ],
    );

    let summary = usage_summary(&root).unwrap();
    assert_eq!(summary.total_tokens, 1040);
    assert_eq!(summary.today_tokens, 40);
    assert_eq!(summary.today_requests, 1);

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
fn exposes_cache_usage_sessions_and_turns_with_message_excerpts() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eturn-0000-0000-0000-000000000003";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"第一轮问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:20Z","type":"event_msg","payload":{"type":"agent_message","message":"第一轮回答"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
            r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"user_message","message":"第二轮问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:05:20Z","type":"event_msg","payload":{"type":"agent_message","message":"第二轮回答"}}"#,
            r#"{"timestamp":"2026-06-18T01:06:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1300,"cached_input_tokens":600,"output_tokens":80,"total_tokens":1380}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.cache_usage.sessions.len(), 1);
    assert_eq!(snapshot.cache_usage.sessions[0].breakdown.calls, 2);
    assert_eq!(snapshot.cache_usage.turns.len(), 2);
    let second_turn = snapshot
        .cache_usage
        .turns
        .iter()
        .find(|turn| turn.turn_index_in_session == 2)
        .unwrap();
    assert_eq!(second_turn.user_prompt, "第二轮问题");
    assert_eq!(second_turn.assistant_response, "第二轮回答");
    assert_eq!(second_turn.breakdown.input_tokens, 1300);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_reuses_cached_aggregate_when_session_signatures_are_unchanged() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eaaaa-bbbb-cccc-dddd-incremental";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    reset_dashboard_aggregate_build_count_for_testing();

    let first = dashboard_snapshot(&root).unwrap();
    let build_count_after_first_load = dashboard_aggregate_build_count_for_testing(&root);
    let second = dashboard_snapshot(&root).unwrap();

    assert_eq!(first.stats.total_tokens, 120);
    assert_eq!(second.stats.total_tokens, 120);
    assert!(build_count_after_first_load >= 1);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        build_count_after_first_load
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_cache_ignores_state_database_churn() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eaaaa-bbbb-cccc-dddd-state-churn";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    create_state_database(&root, session_id, "019ehigh-0000-0000-0000-state-churn2");
    reset_dashboard_aggregate_build_count_for_testing();

    let first = dashboard_snapshot(&root).unwrap();
    let build_count_after_first_load = dashboard_aggregate_build_count_for_testing(&root);
    {
        let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
        connection
            .execute(
                "UPDATE threads SET title = '重命名后的标题', updated_at = updated_at + 1, updated_at_ms = updated_at_ms + 1000 WHERE id = ?1;",
                [session_id],
            )
            .unwrap();
    }
    let second = dashboard_snapshot(&root).unwrap();

    assert_eq!(first.stats.total_tokens, 120);
    assert_eq!(second.stats.total_tokens, 120);
    assert!(build_count_after_first_load >= 1);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        build_count_after_first_load
    );

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
            parsed_size: 128,
            ended_with_newline: true,
            previous_total_tokens: Some(42),
            events: vec![CachedTokenEvent {
                timestamp_unix: 1_781_715_600,
                tokens: 42,
                input_tokens: 40,
                cached_input_tokens: 30,
                output_tokens: 2,
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
fn token_event_cache_persists_sessions_as_sharded_files() {
    let root = temp_root();
    let cache_dir = root.join("token-event-cache-shards");
    let _cache_env = TokenEventCacheEnvGuard::new(&cache_dir);
    let mut cache = TokenEventCache::default();
    let home_a = root.join("codex-a");
    let home_b = root.join("codex-b");
    fs::create_dir_all(&home_a).unwrap();
    fs::create_dir_all(&home_b).unwrap();

    let key_a = codex_home_cache_key(&home_a);
    let key_b = codex_home_cache_key(&home_b);
    cache
        .home_cache_mut(&key_a, &home_a)
        .files
        .insert("sessions/a.jsonl".into(), cached_file_with_one_event(10));
    cache
        .home_cache_mut(&key_b, &home_b)
        .files
        .insert("sessions/b.jsonl".into(), cached_file_with_one_event(20));

    cache.save().unwrap();

    let shard_files = json_files_under(&cache_dir);
    assert_eq!(shard_files.len(), 2);
    assert!(shard_files.iter().all(|path| path.starts_with(&cache_dir)));
    assert!(shard_files.iter().all(|path| {
        path.file_name()
            .and_then(|value| value.to_str())
            .is_some_and(|name| name.ends_with(".json") && name != "token-events-cache-v2.json")
    }));

    let mut warnings = Vec::new();
    let loaded = TokenEventCache::load(&mut warnings);
    assert!(warnings.is_empty());
    assert_eq!(loaded.homes.get(&key_a).unwrap().files.len(), 1);
    assert_eq!(loaded.homes.get(&key_b).unwrap().files.len(), 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_removes_deleted_session_shards() {
    let root = temp_root();
    let cache_dir = root.join("token-event-cache-shards");
    let _cache_env = TokenEventCacheEnvGuard::new(&cache_dir);
    let home = root.join("codex-home");
    fs::create_dir_all(&home).unwrap();
    let home_key = codex_home_cache_key(&home);
    let mut cache = TokenEventCache::default();
    {
        let home_cache = cache.home_cache_mut(&home_key, &home);
        home_cache
            .files
            .insert("sessions/a.jsonl".into(), cached_file_with_one_event(10));
        home_cache
            .files
            .insert("sessions/b.jsonl".into(), cached_file_with_one_event(20));
    }
    cache.save().unwrap();
    assert_eq!(json_files_under(&cache_dir).len(), 2);

    let mut seen = HashSet::new();
    seen.insert("sessions/a.jsonl".into());
    assert!(cache.home_cache_mut(&home_key, &home).retain_seen(&seen));
    cache.save().unwrap();

    let shard_files = json_files_under(&cache_dir);
    assert_eq!(shard_files.len(), 1);
    let shard_text = fs::read_to_string(&shard_files[0]).unwrap();
    assert!(shard_text.contains("sessions/a.jsonl"));
    assert!(!shard_text.contains("sessions/b.jsonl"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_cache_does_not_persist_conversation_text() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let secret_question = "不要写进缓存的问题";
    let secret_answer = "不要写进缓存的回答";
    let user_line = format!(
        r#"{{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{{"type":"user_message","message":"{secret_question}"}}}}"#
    );
    let assistant_line = format!(
        r#"{{"timestamp":"2026-06-18T01:00:20Z","type":"event_msg","payload":{{"type":"agent_message","message":"{secret_answer}"}}}}"#
    );
    write_lines(
        &session_dir.join("rollout-019esecret-0000-0000-0000-cachetext.jsonl"),
        &[
            user_line.as_str(),
            assistant_line.as_str(),
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.cache_usage.turns[0].user_prompt, secret_question);
    let cache_text = app_paths::token_aggregate_cache_path()
        .and_then(|path| fs::read_to_string(path).ok())
        .unwrap_or_default();
    assert!(!cache_text.contains(secret_question));
    assert!(!cache_text.contains(secret_answer));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_does_not_poison_dashboard_aggregate_cache() {
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-0000-0000-0000-cache.jsonl"),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );

    let summary = usage_summary(&root).unwrap();
    assert_eq!(summary.total_tokens, 120);
    assert!(!aggregate_cache_text().contains(r#""snapshot":null"#));

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(aggregate_cache_text().contains(r#""snapshot":{"#));

    reset_dashboard_aggregate_build_count_for_testing();
    let summary_after_restart = usage_summary(&root).unwrap();
    assert_eq!(summary_after_restart.total_tokens, 120);
    assert!(aggregate_cache_text().contains(r#""snapshot":{"#));
    assert!(!aggregate_cache_text().contains(r#""snapshot":null"#));

    fs::remove_dir_all(root).unwrap();
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

#[test]
fn token_event_cache_reads_only_appended_session_bytes() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );

    let mut warnings = Vec::new();
    let mut files = HashMap::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();

    let first = parse_session_file_cached(
        &file,
        "019eappend-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );
    let full_parses_after_first = session_full_parse_count_for_testing();

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170}},"last_token_usage":{{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }

    let second = parse_session_file_cached(
        &file,
        "019eappend-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(first.iter().map(|event| event.tokens).sum::<u64>(), 120);
    assert_eq!(second.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(full_parses_after_first, 1);
    assert_eq!(session_full_parse_count_for_testing(), full_parses_after_first);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_migrates_legacy_entries_without_full_reparse() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019elegacy-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    let original_signature = super::token_event_cache::file_signature(&file).unwrap();
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    let mut files = HashMap::new();
    files.insert(
        cache_key,
        CachedSessionFile {
            signature: original_signature,
            parsed_size: 0,
            ended_with_newline: true,
            previous_total_tokens: None,
            events: vec![CachedTokenEvent {
                timestamp_unix: 1_781_715_600,
                tokens: 120,
                input_tokens: 100,
                cached_input_tokens: 20,
                output_tokens: 20,
            }],
        },
    );

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170}},"last_token_usage":{{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }

    let mut warnings = Vec::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();
    let events = parse_session_file_cached(
        &file,
        "019elegacy-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(events.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(session_full_parse_count_for_testing(), 0);
    assert!(cache_changed);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_keeps_incomplete_appended_line_unconsumed() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019epartial-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );

    let mut warnings = Vec::new();
    let mut files = HashMap::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();
    let _ = parse_session_file_cached(
        &file,
        "019epartial-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        write!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":140,"cached_input_tokens":40"#
        )
        .unwrap();
    }
    let unchanged = parse_session_file_cached(
        &file,
        "019epartial-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );
    assert_eq!(unchanged.iter().map(|event| event.tokens).sum::<u64>(), 120);

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            r#","output_tokens":30,"total_tokens":170}},"last_token_usage":{{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }
    let completed = parse_session_file_cached(
        &file,
        "019epartial-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(completed.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(session_full_parse_count_for_testing(), 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_reparses_truncated_session_file() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019etruncate-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
            r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170},"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let mut files = HashMap::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();
    let first = parse_session_file_cached(
        &file,
        "019etruncate-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );
    write_lines(
        &file,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":20,"total_tokens":90}}}}"#],
    );
    let second = parse_session_file_cached(
        &file,
        "019etruncate-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(first.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(second.iter().map(|event| event.tokens).sum::<u64>(), 90);
    assert_eq!(session_full_parse_count_for_testing(), 2);

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

fn write_lines<S: AsRef<str>>(path: &Path, lines: &[S]) {
    let mut file = fs::File::create(path).unwrap();
    for line in lines {
        writeln!(file, "{}", line.as_ref()).unwrap();
    }
}

struct AggregateCacheEnvGuard;

impl AggregateCacheEnvGuard {
    fn new(path: PathBuf) -> Self {
        reset_dashboard_aggregate_build_count_for_testing();
        let _ = fs::remove_file(&path);
        std::env::set_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH", path);
        Self
    }
}

impl Drop for AggregateCacheEnvGuard {
    fn drop(&mut self) {
        std::env::remove_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH");
        reset_dashboard_aggregate_build_count_for_testing();
    }
}

struct TokenEventCacheEnvGuard;

impl TokenEventCacheEnvGuard {
    fn new(path: &Path) -> Self {
        let _ = fs::remove_dir_all(path);
        std::env::set_var("CODEX_TOKEN_BAR_EVENT_CACHE_DIR", path);
        Self
    }
}

impl Drop for TokenEventCacheEnvGuard {
    fn drop(&mut self) {
        std::env::remove_var("CODEX_TOKEN_BAR_EVENT_CACHE_DIR");
    }
}

fn aggregate_cache_text() -> String {
    app_paths::token_aggregate_cache_path()
        .and_then(|path| fs::read_to_string(path).ok())
        .unwrap_or_default()
}

fn json_files_under(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_json_files(root, &mut files);
    files.sort();
    files
}

fn collect_json_files(root: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_json_files(&path, files);
        } else if path.extension().is_some_and(|extension| extension == "json") {
            files.push(path);
        }
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
        parsed_size: tokens,
        ended_with_newline: true,
        previous_total_tokens: Some(tokens),
        events: vec![CachedTokenEvent {
            timestamp_unix: 1_781_715_600,
            tokens,
            input_tokens: tokens,
            cached_input_tokens: tokens / 2,
            output_tokens: 0,
        }],
    }
}
