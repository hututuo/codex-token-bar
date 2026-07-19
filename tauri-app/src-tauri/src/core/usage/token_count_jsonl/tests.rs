use super::session_parser::{
    parse_session_file_full_result, reset_session_full_parse_count_for_testing,
    session_full_parse_count_for_testing,
};
use super::token_event_cache::{
    codex_home_cache_key, parse_session_file_cached, CachedCodexHome, CachedFileSignature,
    CachedSessionFile, CachedTokenEvent, TokenEventCache,
};
use super::*;
use rusqlite::Connection;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration as StdDuration, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[test]
fn parses_token_count_totals_as_deltas() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    write_lines(&file, &[first_line, second_line]);

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 28);
    assert_eq!(snapshot.stats.total_calls, 2);
    assert_eq!(snapshot.stats.total_threads, 1);
    assert!(snapshot.activity_days.iter().any(|day| day.tokens == 28));
    assert_eq!(snapshot.recent_usage_24h.len(), 30 * 24 * 12);
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
fn recent_usage_24h_series_keeps_thirty_days_of_five_minute_history() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019erecent-history-0000-0000-000000000001.jsonl");
    let older_timestamp = (OffsetDateTime::now_utc() - time::Duration::days(2))
        .format(&Rfc3339)
        .unwrap();
    let recent_timestamp = (OffsetDateTime::now_utc() - time::Duration::minutes(5))
        .format(&Rfc3339)
        .unwrap();
    write_lines(
        &file,
        &[
            format!(
                r#"{{"timestamp":"{older_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":10,"output_tokens":20,"total_tokens":120}}}}}}}}"#
            ),
            format!(
                r#"{{"timestamp":"{recent_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":200,"cached_input_tokens":20,"output_tokens":30,"total_tokens":230}}}}}}}}"#
            ),
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.recent_usage_24h.len(), 30 * 24 * 12);
    assert!(snapshot
        .recent_usage_24h
        .iter()
        .any(|point| point.tokens == 120));
    assert!(snapshot
        .recent_usage_24h
        .iter()
        .any(|point| point.tokens == 230));
    assert!(snapshot
        .recent_usage_24h
        .windows(2)
        .all(|window| window[1].start_unix - window[0].start_unix == 5 * 60));

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
    let events = parse_session_file_full_result(
        &file,
        "019eaaaa-bbbb-cccc-dddd-eeeeffffffff",
        &mut warnings,
    );
    assert_eq!(
        events.events.iter().map(|event| event.tokens).sum::<u64>(),
        0
    );
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
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        0
    );
    assert_eq!(parsed.previous_total_tokens, Some(620));
    assert!(parsed.events.is_empty());
    assert!(parsed.fork_replay_active);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn fork_replay_with_multiple_session_meta_skips_dense_replayed_history_until_later_prompt() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019efork-dense-replay-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-09T10:57:40.602Z","type":"session_meta","payload":{"id":"019efork-dense-replay-0000-eeeeffffffff","forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-07-09T10:57:40.603Z","type":"session_meta","payload":{"id":"019efork-dense-replay-0000-eeeeffffffff","forked_from_id":"parent"}}"#,
            r#"{"timestamp":"2026-07-09T10:57:40.603Z","type":"event_msg","payload":{"type":"user_message","message":"你去看下 finderpeek 项目文件夹，你来接手开发"}}"#,
            r#"{"timestamp":"2026-07-09T10:57:40.604Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":315509847,"cached_input_tokens":295499520,"output_tokens":1303586,"total_tokens":316813433},"last_token_usage":{"input_tokens":207117,"cached_input_tokens":191360,"output_tokens":88,"total_tokens":207205}}}}"#,
            r#"{"timestamp":"2026-07-09T10:57:42.921Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":316572989,"cached_input_tokens":296540800,"output_tokens":1306838,"total_tokens":317879827},"last_token_usage":{"input_tokens":221820,"cached_input_tokens":210304,"output_tokens":2428,"total_tokens":224248}}}}"#,
            r#"{"timestamp":"2026-07-09T10:58:08.319Z","type":"event_msg","payload":{"type":"user_message","message":"请对当前项目做一轮业务逻辑与核心技术债审查"}}"#,
            r#"{"timestamp":"2026-07-09T10:58:17.090Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":316601495,"cached_input_tokens":296540800,"output_tokens":1306838,"total_tokens":317908333},"last_token_usage":{"input_tokens":28506,"cached_input_tokens":0,"output_tokens":0,"total_tokens":28506}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 28_506);
    assert_eq!(snapshot.stats.total_calls, 1);

    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &file,
        "019efork-dense-replay-0000-eeeeffffffff",
        &mut warnings,
    );
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        28_506
    );
    assert_eq!(parsed.previous_total_tokens, Some(317_908_333));
    assert_eq!(
        parsed.events[0].user_prompt,
        "请对当前项目做一轮业务逻辑与核心技术债审查"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn counts_new_call_after_fork_replay_user_message() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let parsed =
        parse_session_file_full_result(&file, "019efork-new-0000-0000-eeeeffffffff", &mut warnings);
    assert_eq!(parsed.events[0].user_prompt, "新分支问题");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn parent_thread_without_forked_from_id_still_counts() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120}}}}"#,
        ],
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
fn cache_usage_keeps_latest_candidates_beyond_low_hit_cutoff() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let base_time = OffsetDateTime::now_utc() - time::Duration::days(10);

    for index in 0..45 {
        let session_id = format!("019elowlatest-{index:04}-0000-0000-000000000001");
        let first_timestamp = (base_time + time::Duration::minutes(i64::from(index * 2)))
            .format(&Rfc3339)
            .unwrap();
        let second_timestamp = (base_time + time::Duration::minutes(i64::from(index * 2 + 1)))
            .format(&Rfc3339)
            .unwrap();
        write_lines(
            &session_dir.join(format!("rollout-{session_id}.jsonl")),
            &[
                format!(
                    r#"{{"timestamp":"{first_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":0,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
                ),
                format!(
                    r#"{{"timestamp":"{second_timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":0,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
                ),
            ],
        );
    }

    let latest_id = "019elatest-high-0000-0000-000000000099";
    let first_latest = (OffsetDateTime::now_utc() - time::Duration::minutes(2))
        .format(&Rfc3339)
        .unwrap();
    let second_latest = (OffsetDateTime::now_utc() - time::Duration::minutes(1))
        .format(&Rfc3339)
        .unwrap();
    write_lines(
        &session_dir.join(format!("rollout-{latest_id}.jsonl")),
        &[
            format!(
                r#"{{"timestamp":"{first_latest}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":1390,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
            ),
            format!(
                r#"{{"timestamp":"{second_latest}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1400,"cached_input_tokens":1390,"output_tokens":50,"total_tokens":1450}}}}}}}}"#
            ),
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert!(snapshot
        .cache_usage
        .sessions
        .iter()
        .any(|session| session.id == latest_id));
    assert!(snapshot
        .cache_usage
        .turns
        .iter()
        .any(|turn| turn.session_id == latest_id && turn.turn_index_in_session == 2));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_reuses_cached_aggregate_when_session_signatures_are_unchanged() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eaaaa-bbbb-cccc-dddd-incremental";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let session_id = "019eaaaa-bbbb-cccc-dddd-state-churn";
    write_lines(
        &session_dir.join(format!("rollout-{session_id}.jsonl")),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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

#[cfg(any(unix, windows))]
#[test]
fn token_event_cache_cross_process_lock_is_non_blocking_when_busy() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let first = TokenEventCache::acquire_io_lock().unwrap().unwrap();
    let started = std::time::Instant::now();
    let second = TokenEventCache::acquire_io_lock();

    assert!(second.is_err());
    assert!(started.elapsed() < StdDuration::from_secs(1));
    drop(first);
    assert!(TokenEventCache::acquire_io_lock().unwrap().is_some());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_ignores_previous_shard_versions() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
fn token_event_cache_updates_only_dirty_shards_without_replacing_the_directory() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let marker = cache_dir.join("directory-owner-marker");
    fs::write(&marker, b"must survive incremental save").unwrap();
    let before = json_files_under(&cache_dir)
        .into_iter()
        .map(|path| (path.clone(), fs::read(path).unwrap()))
        .collect::<HashMap<_, _>>();

    cache
        .home_cache_mut(&home_key, &home)
        .files
        .insert("sessions/a.jsonl".into(), cached_file_with_one_event(30));
    let dirty = HashSet::from([(home_key.clone(), "sessions/a.jsonl".to_string())]);
    cache.save_changes(&dirty, &HashSet::new()).unwrap();

    let throttled = json_files_under(&cache_dir)
        .into_iter()
        .map(|path| (path.clone(), fs::read(path).unwrap()))
        .collect::<HashMap<_, _>>();
    assert_eq!(
        before, throttled,
        "a fresh active shard must wait for its checkpoint"
    );
    for path in json_files_under(&cache_dir) {
        age_file(&path, StdDuration::from_secs(16 * 60));
    }
    cache.save_changes(&dirty, &HashSet::new()).unwrap();

    assert_eq!(fs::read(&marker).unwrap(), b"must survive incremental save");
    let after = json_files_under(&cache_dir)
        .into_iter()
        .map(|path| (path.clone(), fs::read(path).unwrap()))
        .collect::<HashMap<_, _>>();
    assert_eq!(before.len(), after.len());
    assert_eq!(
        before
            .values()
            .filter(|bytes| after.values().any(|other| other == *bytes))
            .count(),
        1,
        "exactly one untouched shard should remain byte-identical"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn token_event_cache_adapts_checkpoint_interval_to_bound_large_shard_writes() {
    assert_eq!(
        super::token_event_cache::shard_checkpoint_interval(1024 * 1024),
        StdDuration::from_secs(15 * 60)
    );
    assert_eq!(
        super::token_event_cache::shard_checkpoint_interval(16 * 1024 * 1024),
        StdDuration::from_secs(90 * 60)
    );
    assert_eq!(
        super::token_event_cache::shard_checkpoint_interval(256 * 1024 * 1024),
        StdDuration::from_secs(24 * 60 * 60)
    );
}

#[test]
fn dashboard_aggregate_cache_does_not_persist_conversation_text() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
fn dashboard_aggregate_persists_a_bounded_startup_snapshot_then_rebuilds_full_details() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eslim-aggregate.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"prompt"}}"#,
            r#"{"timestamp":"2026-06-18T01:00:20Z","type":"event_msg","payload":{"type":"agent_message","message":"answer"}}"#,
            r#"{"timestamp":"2026-06-18T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
        ],
    );

    let full = dashboard_snapshot(&root).unwrap();
    assert!(!full.recent_usage_24h.is_empty());
    assert!(!full.cache_usage.turns.is_empty());
    let persisted = fs::read(&cache_path).unwrap();
    assert!(
        persisted.len() < 512 * 1024,
        "slim aggregate was {} bytes",
        persisted.len()
    );
    let json: serde_json::Value = serde_json::from_slice(&persisted).unwrap();
    assert_eq!(json["version"], 13);
    assert_eq!(
        json["snapshot"]["recentUsage24h"].as_array().unwrap().len(),
        0
    );
    assert_eq!(
        json["snapshot"]["cacheHitRanking"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        json["snapshot"]["cacheUsage"]["sessions"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        json["snapshot"]["cacheUsage"]["turns"]
            .as_array()
            .unwrap()
            .len(),
        0
    );

    reset_dashboard_aggregate_build_count_for_testing();
    let startup = cached_dashboard_snapshot_for_startup(&root).unwrap();
    assert!(startup.recent_usage_24h.is_empty());
    assert!(startup.cache_usage.turns.is_empty());
    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert!(!rebuilt.recent_usage_24h.is_empty());
    assert!(!rebuilt.cache_usage.turns.is_empty());
    assert_eq!(dashboard_aggregate_build_count_for_testing(&root), 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_does_not_poison_dashboard_aggregate_cache() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-0000-0000-0000-cache.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
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
fn usage_summary_rejects_v11_and_reuses_rebuilt_v13_dashboard_aggregate() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("token-aggregate-cache.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaggregate-stale-v11-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let signature = dashboard_scan_signature(&root, &[file]);
    fs::write(
        &cache_path,
        serde_json::json!({
            "version": 11,
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
    assert!(aggregate_cache_text().contains(r#""version":13"#));
    assert!(aggregate_cache_text().contains(r#""totalTokens":120"#));

    reset_dashboard_aggregate_build_count_for_testing();
    let reused = usage_summary(&root).unwrap();
    assert_eq!(reused.total_tokens, 120);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        0,
        "current v13 aggregate should be reused after memory state is cleared"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cached_usage_summary_is_scoped_to_codex_home() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &session_dir_b.join("rollout-019ehome-b-0000-0000-0000-summary.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":10,"total_tokens":30}}}}"#,
        ],
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
fn cached_usage_summary_scope_rejects_date_and_offset_changes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let now = OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap();
    let offset = UtcOffset::from_hms(8, 0, 0).unwrap();
    let signature = dashboard_scan_signature_at(&root, &[], now, offset);
    store_dashboard_aggregate(
        signature,
        None,
        TokenUsageSummary {
            total_tokens: 120,
            today_tokens: 120,
            today_requests: 1,
        },
    );

    assert_eq!(
        cached_dashboard_usage_summary_at(&root, now, offset)
            .expect("matching lightweight scope should reuse the trusted summary")
            .total_tokens,
        120
    );
    assert!(
        cached_dashboard_usage_summary_at(&root, now + time::Duration::days(1), offset,).is_none()
    );
    assert!(
        cached_dashboard_usage_summary_at(&root, now, UtcOffset::from_hms(9, 0, 0).unwrap(),)
            .is_none()
    );
    assert!(cached_dashboard_usage_summary_at(&root.join("other-home"), now, offset).is_none());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn active_rollout_fork_replay_aggregate_reuse_invalidates_after_append() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    create_state_database_with_rollout(&root, "019efork-active-0000-0000-cache", &rollout_path);

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

    assert_eq!(
        cached_dashboard_usage_summary(&root)
            .expect("same-scope append should retain the last trusted summary")
            .total_tokens,
        120
    );
    assert_eq!(
        usage_summary_snapshot(&root).unwrap().total_tokens,
        120,
        "signature drift should return stale-safe trusted totals while scheduling one rebuild"
    );

    for _ in 0..100 {
        std::thread::sleep(std::time::Duration::from_millis(20));
        if usage_summary_snapshot(&root).is_ok_and(|summary| summary.total_tokens == 260) {
            assert_eq!(dashboard_aggregate_build_count_for_testing(&root), 1);
            fs::remove_dir_all(root).unwrap();
            return;
        }
    }

    panic!("stale-safe usage summary background refresh did not finish");
}

#[test]
fn dashboard_aggregate_cache_save_does_not_clobber_existing_temp_file() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
        signature.clone(),
        None,
        TokenUsageSummary {
            total_tokens: 10,
            today_tokens: 10,
            today_requests: 1,
        },
    );
    age_file(&cache_path, StdDuration::from_secs(16 * 60));
    let second_warning = store_dashboard_aggregate(
        signature,
        None,
        TokenUsageSummary {
            total_tokens: 20,
            today_tokens: 20,
            today_requests: 2,
        },
    );
    assert!(second_warning.is_none(), "{second_warning:?}");

    assert_eq!(
        fs::read_to_string(&legacy_temp_path).unwrap(),
        "other save",
        "aggregate cache should use a unique temp path instead of overwriting another save"
    );
    assert!(cache_path.exists());
    assert_eq!(
        load_persistent_dashboard_aggregate()
            .unwrap()
            .summary
            .total_tokens,
        20
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_checkpoints_active_signature_changes_at_most_every_fifteen_minutes() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    fs::create_dir_all(&root).unwrap();
    let now = OffsetDateTime::from_unix_timestamp(1_781_715_600).unwrap();
    let mut first_signature = dashboard_scan_signature_at(&root, &[], now, UtcOffset::UTC);
    first_signature.session_files.push(SessionFileSignature {
        cache_key: "active.jsonl".into(),
        signature: CachedFileSignature {
            size: 100,
            modified_millis: 1,
        },
    });
    store_dashboard_aggregate(
        first_signature.clone(),
        None,
        TokenUsageSummary {
            total_tokens: 100,
            today_tokens: 100,
            today_requests: 1,
        },
    );
    let initial = fs::read(&cache_path).unwrap();
    let mut next_day_signature = first_signature.clone();
    next_day_signature.local_date = "2026-06-19".into();
    assert!(aggregate_checkpoint_due(
        &cache_path,
        &next_day_signature,
        SystemTime::now()
    ));

    let mut active_signature = first_signature;
    active_signature.session_files[0].signature.size = 110;
    active_signature.session_files[0].signature.modified_millis = 2;
    age_file(&cache_path, StdDuration::from_secs(30));
    store_dashboard_aggregate(
        active_signature.clone(),
        None,
        TokenUsageSummary {
            total_tokens: 110,
            today_tokens: 110,
            today_requests: 2,
        },
    );
    assert_eq!(fs::read(&cache_path).unwrap(), initial);
    assert_eq!(
        cached_dashboard_aggregate(&active_signature)
            .unwrap()
            .summary
            .total_tokens,
        110,
        "memory must update immediately while the startup checkpoint is throttled"
    );

    age_file(&cache_path, StdDuration::from_secs(16 * 60));
    store_dashboard_aggregate(
        active_signature,
        None,
        TokenUsageSummary {
            total_tokens: 120,
            today_tokens: 120,
            today_requests: 3,
        },
    );
    assert_ne!(fs::read(&cache_path).unwrap(), initial);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_aggregate_cache_skips_an_identical_payload() {
    let root = temp_root();
    let path = root.join("dashboard-aggregate.json");
    fs::create_dir_all(&root).unwrap();
    fs::write(&path, b"same aggregate").unwrap();
    let mut writes = 0;

    super::write_aggregate_if_changed(&path, b"same aggregate", |_, _| {
        writes += 1;
        Ok(())
    })
    .unwrap();
    assert_eq!(writes, 0);

    super::write_aggregate_if_changed(&path, b"changed aggregate", |_, _| {
        writes += 1;
        Ok(())
    })
    .unwrap();
    assert_eq!(writes, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn aggregate_persistence_failure_keeps_memory_snapshot_with_one_warning() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let blocked_parent = root.join("blocked-parent");
    fs::create_dir_all(&root).unwrap();
    fs::write(&blocked_parent, b"not a directory").unwrap();
    let _cache_env = AggregateCacheEnvGuard::new(blocked_parent.join("dashboard-aggregate.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &session_dir.join("rollout-019eaggregate-persistence-warning.jsonl"),
        &[&format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}}}}}"#
        )],
    );

    let first = dashboard_snapshot(&root).unwrap();
    let second = dashboard_snapshot(&root).unwrap();
    for snapshot in [first, second] {
        assert_eq!(snapshot.stats.total_tokens, 120);
        assert_eq!(
            snapshot
                .warnings
                .iter()
                .filter(|warning| warning.source == "usage-cache-persistence")
                .count(),
            1
        );
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn marker_failure_warning_is_deduplicated_for_fresh_and_cached_snapshots() {
    let root = temp_root();
    let blocked_support = root.join("blocked-support");
    fs::create_dir_all(&root).unwrap();
    fs::write(&blocked_support, b"not a directory").unwrap();
    let _state = cache_lifecycle::usage_cache_test_state_guard(&[(
        "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
        blocked_support.clone(),
    )]);
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let timestamp = OffsetDateTime::now_utc().format(&Rfc3339).unwrap();
    write_lines(
        &session_dir.join("rollout-019emarker-warning-fresh-cached.jsonl"),
        &[&format!(
            r#"{{"timestamp":"{timestamp}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"total_tokens":42}}}}}}}}"#
        )],
    );

    let fresh = dashboard_snapshot(&root).unwrap();
    let cached = dashboard_snapshot(&root).unwrap();
    for snapshot in [fresh, cached] {
        assert_eq!(
            snapshot
                .warnings
                .iter()
                .filter(|warning| warning.source == "usage-cache-marker-persistence")
                .count(),
            1
        );
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn usage_summary_snapshot_cache_miss_schedules_one_background_build() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let _event_cache_env = TokenEventCacheEnvGuard::new(&root.join("event-cache"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-0000-0000-0000-background.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
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
    assert_eq!(
        session_full_parse_count_for_testing(),
        full_parses_after_first
    );

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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019elegacy-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let first_timestamp = OffsetDateTime::parse("2026-06-18T01:00:00Z", &Rfc3339)
        .unwrap()
        .unix_timestamp();
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let first_timestamp = OffsetDateTime::parse("2026-06-18T01:00:00Z", &Rfc3339)
        .unwrap()
        .unix_timestamp();
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
    let first_timestamp = OffsetDateTime::parse("2026-06-18T01:00:00Z", &Rfc3339)
        .unwrap()
        .unix_timestamp();
    let second_timestamp = OffsetDateTime::parse("2026-06-18T01:05:00Z", &Rfc3339)
        .unwrap()
        .unix_timestamp();
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019epartial-0000-0000-0000-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
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
    let _test_state = app_paths::app_path_test_env_guard(&[]);
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
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":20,"total_tokens":90}}}}"#,
        ],
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

fn age_file(path: &Path, age: StdDuration) {
    let file = fs::OpenOptions::new().write(true).open(path).unwrap();
    let times = fs::FileTimes::new().set_modified(SystemTime::now() - age);
    file.set_times(times).unwrap();
}

struct AggregateCacheEnvGuard {
    original: Option<std::ffi::OsString>,
}

impl AggregateCacheEnvGuard {
    fn new(path: PathBuf) -> Self {
        reset_dashboard_aggregate_build_count_for_testing();
        let _ = fs::remove_file(&path);
        let original = std::env::var_os("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH");
        std::env::set_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH", path);
        Self { original }
    }
}

impl Drop for AggregateCacheEnvGuard {
    fn drop(&mut self) {
        match &self.original {
            Some(value) => std::env::set_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH", value),
            None => std::env::remove_var("CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH"),
        }
        reset_dashboard_aggregate_build_count_for_testing();
    }
}

struct TokenEventCacheEnvGuard {
    original: Option<std::ffi::OsString>,
}

impl TokenEventCacheEnvGuard {
    fn new(path: &Path) -> Self {
        let _ = fs::remove_dir_all(path);
        let original = std::env::var_os("CODEX_TOKEN_BAR_EVENT_CACHE_DIR");
        std::env::set_var("CODEX_TOKEN_BAR_EVENT_CACHE_DIR", path);
        Self { original }
    }
}

impl Drop for TokenEventCacheEnvGuard {
    fn drop(&mut self) {
        match &self.original {
            Some(value) => std::env::set_var("CODEX_TOKEN_BAR_EVENT_CACHE_DIR", value),
            None => std::env::remove_var("CODEX_TOKEN_BAR_EVENT_CACHE_DIR"),
        }
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
        } else if path
            .extension()
            .is_some_and(|extension| extension == "json")
        {
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
