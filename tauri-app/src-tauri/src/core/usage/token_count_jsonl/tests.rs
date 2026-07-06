use super::token_event_cache::{
    codex_home_cache_key, parse_session_file_cached, CachedCodexHome, CachedFileSignature,
    CachedSessionFile, CachedTokenEvent, TokenEventCache,
};
use super::session_parser::{
    parse_session_file_full_result, reset_session_full_parse_count_for_testing,
    session_full_parse_count_for_testing,
};
use super::*;
use rusqlite::Connection;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

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
fn skips_pure_fork_replay_even_after_thirty_seconds() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaaaa-bbbb-cccc-dddd-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#,
            r#"{"timestamp":"2026-06-18T01:05:40Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300},"last_token_usage":{"total_tokens":200}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let events = parse_session_file_full_result(&file, "019eaaaa-bbbb-cccc-dddd-eeeeffffffff", &mut warnings);
    assert_eq!(events.events.iter().map(|event| event.tokens).sum::<u64>(), 0);
    assert_eq!(events.previous_total_tokens, Some(300));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn keeps_fork_replay_active_for_replayed_user_message_near_token_counts() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-copy-0000-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500},"last_token_usage":{"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:11Z","type":"event_msg","payload":{"type":"user_message","message":"父会话复制问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:12Z","type":"event_msg","payload":{"type":"agent_message","message":"父会话复制回答"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:13Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":620},"last_token_usage":{"total_tokens":120}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &file,
        "019efork-copy-0000-0000-eeeeffffffff",
        &mut warnings,
    );
    assert_eq!(parsed.events.iter().map(|event| event.tokens).sum::<u64>(), 0);
    assert_eq!(parsed.previous_total_tokens, Some(620));
    assert!(parsed.events.is_empty());
    assert!(parsed.fork_replay_active);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn counts_new_call_after_fork_replay_user_message() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-new-0000-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500},"last_token_usage":{"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:10:00Z","type":"event_msg","payload":{"type":"user_message","message":"新分支问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:10:30Z","type":"event_msg","payload":{"type":"agent_message","message":"新分支回答"}}"#,
            r#"{"timestamp":"2026-06-18T01:11:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":20,"output_tokens":30,"total_tokens":620},"last_token_usage":{"input_tokens":90,"cached_input_tokens":20,"output_tokens":30,"total_tokens":120}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 120);
    assert_eq!(snapshot.stats.total_calls, 1);

    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &file,
        "019efork-new-0000-0000-eeeeffffffff",
        &mut warnings,
    );
    assert_eq!(parsed.events[0].user_prompt, "新分支问题");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn parent_thread_without_forked_from_id_still_counts() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eparent-0000-0000-0000-count.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"parent_thread_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 42);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn active_state_rollout_counts_subagent_parent_thread_without_forked_from_id() {
    let root = temp_root();
    let active_dir = root.join("active-rollouts");
    fs::create_dir_all(&active_dir).unwrap();
    let rollout_path = active_dir.join("rollout-019esubagent-0000-0000-0000-stateonly.jsonl");
    write_lines(
        &rollout_path,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"parent_thread_id":"parent-thread","source":"subagent"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":5,"output_tokens":10,"total_tokens":60}}}}"#,
        ],
    );
    create_state_database_with_rollout_source(
        &root,
        "019esubagent-0000-0000-0000-stateonly",
        &rollout_path,
        "subagent",
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 60);
    assert_eq!(snapshot.stats.total_calls, 1);

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
fn dashboard_usage_summary_matches_dashboard_snapshot_metrics() {
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

    let dashboard = dashboard_snapshot(&root).unwrap();
    let summary = dashboard_usage_summary(&root).unwrap();
    let today = dashboard.activity_days.last().unwrap();

    assert_eq!(summary.total_tokens, dashboard.stats.total_tokens);
    assert_eq!(summary.today_tokens, today.tokens);
    assert_eq!(summary.today_requests, today.calls);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_scan_signature_changes_when_local_date_changes() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019edate-0000-0000-0000-signature.jsonl");
    write_lines(
        &file,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#],
    );
    let files = vec![file];
    let offset = UtcOffset::from_hms(8, 0, 0).unwrap();
    let before_midnight = OffsetDateTime::parse("2026-06-18T15:59:59Z", &Rfc3339).unwrap();
    let after_midnight = OffsetDateTime::parse("2026-06-18T16:00:01Z", &Rfc3339).unwrap();

    let before = dashboard_scan_signature_at(&root, &files, before_midnight, offset);
    let after = dashboard_scan_signature_at(&root, &files, after_midnight, offset);

    assert_ne!(before, after);
    assert_eq!(before.local_date, "2026-06-18");
    assert_eq!(after.local_date, "2026-06-19");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_includes_active_state_rollout_path() {
    let root = temp_root();
    fs::create_dir_all(root.join("sessions")).unwrap();
    let active_dir = root.join("active-rollouts");
    fs::create_dir_all(&active_dir).unwrap();
    let rollout_path = active_dir.join("rollout-019eactive-0000-0000-0000-stateonly.jsonl");
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &rollout_path,
        &[format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":70,"cached_input_tokens":20,"output_tokens":7,"total_tokens":77}}}}}}}}"#
        )],
    );
    create_state_database_with_rollout(&root, "019eactive-0000-0000-0000-stateonly", &rollout_path);

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 77);
    assert_eq!(snapshot.stats.total_calls, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_deduplicates_rollout_path_already_under_sessions() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let rollout_path = session_dir.join("rollout-019ededup-0000-0000-0000-samefile.jsonl");
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &rollout_path,
        &[format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":70,"cached_input_tokens":20,"output_tokens":7,"total_tokens":77}}}}}}}}"#
        )],
    );
    create_state_database_with_rollout(&root, "019ededup-0000-0000-0000-samefile", &rollout_path);

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 77);
    assert_eq!(snapshot.stats.total_calls, 1);

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
            fork_replay_active: false,
            last_skipped_fork_replay_token_at: None,
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
fn token_event_cache_ignores_previous_shard_versions() {
    let root = temp_root();
    let cache_dir = root.join("token-event-cache-shards");
    let _cache_env = TokenEventCacheEnvGuard::new(&cache_dir);
    let home = root.join("codex-home");
    fs::create_dir_all(cache_dir.join("home-a")).unwrap();
    fs::create_dir_all(&home).unwrap();
    fs::write(
        cache_dir.join("home-a").join("old.json"),
        serde_json::json!({
            "version": 4,
            "homeKey": "home-a",
            "codexHome": home.to_string_lossy(),
            "cacheKey": "sessions/old.jsonl",
            "session": cached_file_with_one_event(20),
        })
        .to_string(),
    )
    .unwrap();

    let mut warnings = Vec::new();
    let loaded = TokenEventCache::load(&mut warnings);

    assert!(warnings.is_empty());
    assert!(loaded.homes.is_empty());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_reparses_pre_grace_window_version_seven_shard() {
    let root = temp_root();
    let cache_dir = root.join("token-event-cache-shards");
    let _cache_env = TokenEventCacheEnvGuard::new(&cache_dir);
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-stale-v7-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":100,"total_tokens":500},"last_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":100,"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:10:00Z","type":"event_msg","payload":{"type":"user_message","message":"新分支问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:11:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":120,"total_tokens":620},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let signature = super::token_event_cache::file_signature(&file).unwrap();
    let home_key = codex_home_cache_key(&root);
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    fs::create_dir_all(cache_dir.join(&home_key)).unwrap();
    fs::write(
        cache_dir.join(&home_key).join("stale-v7.json"),
        serde_json::json!({
            "version": 7,
            "homeKey": home_key,
            "codexHome": root.to_string_lossy(),
            "cacheKey": cache_key,
            "session": {
                "signature": signature,
                "parsedSize": signature.size,
                "endedWithNewline": true,
                "previousTotalTokens": 620,
                "forkReplayActive": false,
                "lastSkippedForkReplayTokenAt": null,
                "events": [{
                    "timestampUnix": 1_781_716_260,
                    "tokens": 620,
                    "inputTokens": 500,
                    "cachedInputTokens": 0,
                    "outputTokens": 120
                }]
            }
        })
        .to_string(),
    )
    .unwrap();

    reset_session_full_parse_count_for_testing();
    let mut warnings = Vec::new();
    let events = load_token_events_from_files(&root, vec![file.clone()], &mut warnings);

    assert_eq!(events.iter().map(|event| event.tokens).sum::<u64>(), 120);
    assert_eq!(session_full_parse_count_for_testing(), 1);
    assert!(json_files_under(&cache_dir)
        .iter()
        .filter_map(|path| fs::read_to_string(path).ok())
        .any(|text| text.contains(r#""version":8"#) && text.contains(r#""tokens":120"#)));

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
fn usage_summary_ignores_previous_dashboard_aggregate_version() {
    let root = temp_root();
    let cache_path = root.join("token-aggregate-cache.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaggregate-stale-v8-cache.jsonl");
    write_lines(
        &file,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    let signature = dashboard_scan_signature(&root, &[file]);
    fs::write(
        &cache_path,
        serde_json::json!({
            "version": 8,
            "signature": signature,
            "snapshot": null,
            "summary": {
                "totalTokens": 999,
                "todayTokens": 999,
                "todayRequests": 9
            }
        })
        .to_string(),
    )
    .unwrap();

    let summary = usage_summary(&root).unwrap();

    assert_eq!(summary.total_tokens, 120);
    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(aggregate_cache_text().contains(r#""version":9"#));
    assert!(aggregate_cache_text().contains(r#""totalTokens":120"#));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cached_usage_summary_is_scoped_to_codex_home() {
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let home_a = root.join("codex-a");
    let home_b = root.join("codex-b");
    let session_dir_a = home_a.join("sessions");
    let session_dir_b = home_b.join("sessions");
    fs::create_dir_all(&session_dir_a).unwrap();
    fs::create_dir_all(&session_dir_b).unwrap();
    write_lines(
        &session_dir_a.join("rollout-019ehome-a-0000-0000-0000-summary.jsonl"),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    write_lines(
        &session_dir_b.join("rollout-019ehome-b-0000-0000-0000-summary.jsonl"),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":10,"total_tokens":30}}}}"#],
    );

    let snapshot_a = dashboard_snapshot(&home_a).unwrap();
    assert_eq!(snapshot_a.stats.total_tokens, 120);
    assert_eq!(
        cached_dashboard_usage_summary(&home_a)
            .expect("home A should have a trusted cached summary")
            .total_tokens,
        120
    );
    assert!(
        cached_dashboard_usage_summary(&home_b).is_none(),
        "home A aggregate must not become a trusted compact summary for home B"
    );

    let snapshot_b = dashboard_snapshot(&home_b).unwrap();

    assert_eq!(snapshot_b.stats.total_tokens, 30);
    assert_eq!(
        usage_summary_snapshot(&home_b).unwrap().total_tokens,
        30,
        "home B should use its own rebuilt precise aggregate"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn active_rollout_fork_replay_aggregate_reuse_invalidates_after_append() {
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let active_dir = root.join("active-rollouts");
    fs::create_dir_all(&active_dir).unwrap();
    let rollout_path = active_dir.join("rollout-019efork-active-0000-0000-cache.jsonl");
    write_lines(
        &rollout_path,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":100,"total_tokens":500},"last_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":100,"total_tokens":500}}}}"#,
            r#"{"timestamp":"2026-06-18T01:10:00Z","type":"event_msg","payload":{"type":"user_message","message":"新分支问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:11:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":120,"total_tokens":620},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    create_state_database_with_rollout(
        &root,
        "019efork-active-0000-0000-cache",
        &rollout_path,
    );

    let first = dashboard_snapshot(&root).unwrap();
    assert_eq!(first.stats.total_tokens, 120);
    assert_eq!(usage_summary_snapshot(&root).unwrap().total_tokens, 120);

    reset_dashboard_aggregate_build_count_for_testing();
    assert_eq!(usage_summary_snapshot(&root).unwrap().total_tokens, 120);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        0,
        "unchanged active rollout should reuse the trusted aggregate summary"
    );

    {
        let mut handle = fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:12:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":620,"cached_input_tokens":10,"output_tokens":140,"total_tokens":760}},"last_token_usage":{{"input_tokens":120,"cached_input_tokens":10,"output_tokens":20,"total_tokens":140}}}}}}}}"#
        )
        .unwrap();
    }

    assert!(
        cached_dashboard_usage_summary(&root).is_none(),
        "changed active rollout signature must invalidate the previous aggregate summary"
    );
    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 260);
    assert_eq!(usage_summary_snapshot(&root).unwrap().total_tokens, 260);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_cache_save_does_not_clobber_existing_temp_file() {
    let root = temp_root();
    let cache_path = root.join("token-aggregate-cache.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    fs::create_dir_all(&root).unwrap();
    let legacy_temp_path = cache_path.with_extension("json.tmp");
    fs::write(&legacy_temp_path, "other save").unwrap();
    let signature = dashboard_scan_signature_at(
        &root,
        &[],
        OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap(),
        UtcOffset::UTC,
    );

    store_dashboard_aggregate(
        signature,
        None,
        TokenUsageSummary {
            total_tokens: 10,
            today_tokens: 10,
            today_requests: 1,
        },
    );

    assert_eq!(
        fs::read_to_string(&legacy_temp_path).unwrap(),
        "other save",
        "aggregate cache should use a unique temp path instead of overwriting another save"
    );
    assert!(cache_path.exists());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_snapshot_cache_miss_schedules_one_background_build() {
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-0000-0000-0000-background.jsonl"),
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );

    reset_dashboard_aggregate_build_count_for_testing();
    assert!(usage_summary_snapshot(&root).is_err());
    assert!(usage_summary_snapshot(&root).is_err());
    assert!(usage_summary_snapshot(&root).is_err());

    for _ in 0..100 {
        std::thread::sleep(std::time::Duration::from_millis(20));
        if let Ok(summary) = usage_summary_snapshot(&root) {
            assert_eq!(summary.total_tokens, 120);
            assert_eq!(dashboard_aggregate_build_count_for_testing(&root), 1);
            fs::remove_dir_all(root).unwrap();
            return;
        }
    }

    panic!("usage summary background build did not finish");
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
fn token_event_cache_counts_incremental_append_after_fork_replay_ended() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-append-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"父会话复制问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120}}}}"#,
            r#"{"timestamp":"2026-06-18T01:10:00Z","type":"event_msg","payload":{"type":"user_message","message":"新分支问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:11:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":10,"output_tokens":30,"total_tokens":200},"last_token_usage":{"input_tokens":80,"cached_input_tokens":10,"output_tokens":10,"total_tokens":80}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let mut files = HashMap::new();
    let mut cache_changed = false;

    let first = parse_session_file_cached(
        &file,
        "019efork-append-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:12:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":250,"cached_input_tokens":20,"output_tokens":50,"total_tokens":300}},"last_token_usage":{{"input_tokens":70,"cached_input_tokens":10,"output_tokens":20,"total_tokens":100}}}}}}}}"#
        )
        .unwrap();
    }

    let second = parse_session_file_cached(
        &file,
        "019efork-append-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(first.iter().map(|event| event.tokens).sum::<u64>(), 80);
    assert_eq!(second.iter().map(|event| event.tokens).sum::<u64>(), 180);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_round_trips_fork_replay_state_before_incremental_append() {
    let root = temp_root();
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-roundtrip-0000-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120}}}}"#,
            r#"{"timestamp":"2026-06-18T01:00:13Z","type":"event_msg","payload":{"type":"user_message","message":"新分支问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:14Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":10,"output_tokens":30,"total_tokens":190},"last_token_usage":{"input_tokens":60,"cached_input_tokens":10,"output_tokens":10,"total_tokens":70}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let first = load_token_events_from_files(&root, vec![file.clone()], &mut warnings);
    assert_eq!(first.iter().map(|event| event.tokens).sum::<u64>(), 70);

    let mut loaded_warnings = Vec::new();
    let loaded_cache = TokenEventCache::load(&mut loaded_warnings);
    let home_key = codex_home_cache_key(&root);
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    let cached = loaded_cache
        .homes
        .get(&home_key)
        .and_then(|home| home.files.get(&cache_key))
        .expect("first parse should save a fork replay cache shard");
    assert!(!cached.fork_replay_active);
    assert_eq!(cached.previous_total_tokens, Some(190));

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":240,"cached_input_tokens":20,"output_tokens":50,"total_tokens":290}},"last_token_usage":{{"input_tokens":80,"cached_input_tokens":10,"output_tokens":20,"total_tokens":100}}}}}}}}"#
        )
        .unwrap();
    }

    let mut append_warnings = Vec::new();
    let second = load_token_events_from_files(&root, vec![file.clone()], &mut append_warnings);
    assert_eq!(second.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(second.len(), 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_save_does_not_remove_existing_in_flight_temp_directory() {
    let root = temp_root();
    let cache_dir = root.join("event-cache");
    let _event_cache_env = TokenEventCacheEnvGuard::new(&cache_dir);
    let legacy_temp_dir = cache_dir.with_extension("tmp");
    fs::create_dir_all(&legacy_temp_dir).unwrap();
    let marker = legacy_temp_dir.join("other-save-marker");
    fs::write(&marker, "do not remove").unwrap();

    let mut cache = TokenEventCache::default();
    let home = root.join("codex-home");
    fs::create_dir_all(&home).unwrap();
    let home_key = codex_home_cache_key(&home);
    cache
        .home_cache_mut(&home_key, &home)
        .files
        .insert("sessions/a.jsonl".into(), cached_file_with_one_event(10));

    cache.save().unwrap();

    assert!(
        marker.exists(),
        "cache save must use a unique temp path instead of deleting another in-flight temp dir"
    );
    assert!(!json_files_under(&cache_dir).is_empty());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_reparses_legacy_entries_without_parsed_size() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019elegacy-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
    );
    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            r#"{{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170}},"last_token_usage":{{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}}}}}"#
        )
        .unwrap();
    }

    let full_signature = super::token_event_cache::file_signature(&file).unwrap();
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    let mut files = HashMap::new();
    files.insert(
        cache_key,
        CachedSessionFile {
            signature: full_signature,
            parsed_size: 0,
            ended_with_newline: true,
            previous_total_tokens: None,
            fork_replay_active: false,
            last_skipped_fork_replay_token_at: None,
            events: vec![CachedTokenEvent {
                timestamp_unix: 1_781_715_600,
                tokens: 120,
                input_tokens: 100,
                cached_input_tokens: 20,
                output_tokens: 20,
            }],
        },
    );

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
    assert_eq!(session_full_parse_count_for_testing(), 1);
    assert!(cache_changed);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_reads_tail_when_signature_matches_but_parsed_size_lags() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019elagging-0000-0000-0000-cache.jsonl");
    let first_line = r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let second_line = r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170},"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#;
    write_lines(&file, &[first_line, second_line]);

    let full_signature = super::token_event_cache::file_signature(&file).unwrap();
    let parsed_size = (first_line.len() + 1) as u64;
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    let first_timestamp =
        OffsetDateTime::parse("2026-06-18T01:00:00Z", &Rfc3339).unwrap().unix_timestamp();
    let mut files = HashMap::new();
    files.insert(
        cache_key.clone(),
        CachedSessionFile {
            signature: full_signature,
            parsed_size,
            ended_with_newline: true,
            previous_total_tokens: Some(120),
            fork_replay_active: false,
            last_skipped_fork_replay_token_at: None,
            events: vec![CachedTokenEvent {
                timestamp_unix: first_timestamp,
                tokens: 120,
                input_tokens: 100,
                cached_input_tokens: 20,
                output_tokens: 20,
            }],
        },
    );

    let mut warnings = Vec::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();
    let events = parse_session_file_cached(
        &file,
        "019elagging-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(events.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(session_full_parse_count_for_testing(), 0);
    assert!(cache_changed);
    let updated = files.get(&cache_key).unwrap();
    assert_eq!(updated.parsed_size, fs::metadata(&file).unwrap().len());
    assert_eq!(updated.events.len(), 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_advances_offset_past_zero_delta_lines() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019ezero-0000-0000-0000-cache.jsonl");
    let first_line = r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let zero_line = r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":0}}}}"#;
    let second_line = r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170},"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#;
    write_lines(&file, &[first_line, zero_line]);

    let mut warnings = Vec::new();
    let mut files = HashMap::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();
    let first = parse_session_file_cached(
        &file,
        "019ezero-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );
    assert_eq!(first.iter().map(|event| event.tokens).sum::<u64>(), 120);
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    let parsed_size_after_zero = files.get(&cache_key).unwrap().parsed_size;
    assert_eq!(parsed_size_after_zero, fs::metadata(&file).unwrap().len());

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(handle, "{second_line}").unwrap();
    }
    let second = parse_session_file_cached(
        &file,
        "019ezero-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(second.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(session_full_parse_count_for_testing(), 1);
    assert_eq!(files.get(&cache_key).unwrap().events.len(), 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_reparses_implausible_cached_event_even_when_signature_matches() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eimplausible-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
            r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170},"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#,
        ],
    );
    let signature = super::token_event_cache::file_signature(&file).unwrap();
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    let first_timestamp =
        OffsetDateTime::parse("2026-06-18T01:00:00Z", &Rfc3339).unwrap().unix_timestamp();
    let mut files = HashMap::new();
    files.insert(
        cache_key,
        CachedSessionFile {
            signature,
            parsed_size: fs::metadata(&file).unwrap().len(),
            ended_with_newline: true,
            previous_total_tokens: Some(170),
            fork_replay_active: false,
            last_skipped_fork_replay_token_at: None,
            events: vec![CachedTokenEvent {
                timestamp_unix: first_timestamp,
                tokens: 605_109_263,
                input_tokens: 155_979,
                cached_input_tokens: 141_184,
                output_tokens: 806,
            }],
        },
    );

    let mut warnings = Vec::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();
    let events = parse_session_file_cached(
        &file,
        "019eimplausible-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(events.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(session_full_parse_count_for_testing(), 1);
    assert!(cache_changed);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_reparses_when_incremental_range_overlaps_cached_events() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eoverlap-0000-0000-0000-cache.jsonl");
    let first_line = r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let second_line = r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"cached_input_tokens":40,"output_tokens":30,"total_tokens":170},"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#;
    write_lines(&file, &[first_line]);
    let first_signature = super::token_event_cache::file_signature(&file).unwrap();
    let first_size = first_signature.size;
    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(handle, "{second_line}").unwrap();
    }
    let cache_key = super::token_event_cache::file_cache_key(&root, &file);
    let first_timestamp =
        OffsetDateTime::parse("2026-06-18T01:00:00Z", &Rfc3339).unwrap().unix_timestamp();
    let second_timestamp =
        OffsetDateTime::parse("2026-06-18T01:05:00Z", &Rfc3339).unwrap().unix_timestamp();
    let mut files = HashMap::new();
    files.insert(
        cache_key,
        CachedSessionFile {
            signature: first_signature,
            parsed_size: first_size,
            ended_with_newline: true,
            previous_total_tokens: Some(120),
            fork_replay_active: false,
            last_skipped_fork_replay_token_at: None,
            events: vec![
                CachedTokenEvent {
                    timestamp_unix: first_timestamp,
                    tokens: 120,
                    input_tokens: 100,
                    cached_input_tokens: 20,
                    output_tokens: 20,
                },
                CachedTokenEvent {
                    timestamp_unix: second_timestamp,
                    tokens: 50,
                    input_tokens: 40,
                    cached_input_tokens: 20,
                    output_tokens: 10,
                },
            ],
        },
    );

    let mut warnings = Vec::new();
    let mut cache_changed = false;
    reset_session_full_parse_count_for_testing();
    let events = parse_session_file_cached(
        &file,
        "019eoverlap-0000-0000-0000-cache",
        &mut files,
        &mut cache_changed,
        &root,
        &mut warnings,
    );

    assert_eq!(events.iter().map(|event| event.tokens).sum::<u64>(), 170);
    assert_eq!(session_full_parse_count_for_testing(), 1);
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

fn create_state_database_with_rollout(root: &Path, thread_id: &str, rollout_path: &Path) {
    create_state_database_with_rollout_source(root, thread_id, rollout_path, "user");
}

fn create_state_database_with_rollout_source(
    root: &Path,
    thread_id: &str,
    rollout_path: &Path,
    thread_source: &str,
) {
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
                rollout_path TEXT,
                updated_at INTEGER NOT NULL,
                updated_at_ms INTEGER,
                archived INTEGER DEFAULT 0,
                thread_source TEXT DEFAULT 'user'
            );
            "#,
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO threads (id, title, first_user_message, preview, rollout_path, updated_at, updated_at_ms, archived, thread_source) VALUES (?1, '活跃会话', '', '', ?2, 1781715600, 1781715600000, 0, ?3);",
            rusqlite::params![thread_id, rollout_path.to_string_lossy(), thread_source],
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
        fork_replay_active: false,
        last_skipped_fork_replay_token_at: None,
        events: vec![CachedTokenEvent {
            timestamp_unix: 1_781_715_600,
            tokens,
            input_tokens: tokens,
            cached_input_tokens: tokens / 2,
            output_tokens: 0,
        }],
    }
}
