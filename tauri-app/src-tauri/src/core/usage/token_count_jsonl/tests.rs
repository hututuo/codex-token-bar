use super::session_parser::{parse_session_file_full_result, EXACT_INDEX_CHUNK_SIZE};
use super::*;
use rusqlite::Connection;
use std::fs;
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration as StdDuration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[test]
fn exact_index_deduplicates_a_replay_after_more_than_4096_unique_snapshots() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eexact-dedupe-0000-0000-0000-index.jsonl");
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    for tokens in 1_u64..=4_097 {
        let line = serde_json::json!({
            "timestamp": "2026-07-20T01:00:00Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": tokens,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                        "total_tokens": tokens
                    },
                    "last_token_usage": {
                        "input_tokens": tokens,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                        "total_tokens": tokens
                    }
                }
            }
        });
        writeln!(handle, "{line}").unwrap();
    }
    let replay = serde_json::json!({
        "timestamp": "2026-07-21T01:00:00Z",
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": 1,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 1
                },
                "last_token_usage": {
                    "input_tokens": 1,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 1
                }
            }
        }
    });
    writeln!(handle, "{replay}").unwrap();
    handle.flush().unwrap();

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, (1_u64..=4_097).sum::<u64>());
    assert_eq!(snapshot.stats.total_calls, 4_097);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_parses_a_valid_jsonl_line_larger_than_the_old_16_mib_limit() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eline-unbounded-0000-0000-0000-index.jsonl");
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    handle.write_all(br#"{"padding":""#).unwrap();
    let chunk = vec![b'x'; 1024 * 1024];
    for _ in 0..17 {
        handle.write_all(&chunk).unwrap();
    }
    handle
        .write_all(
            br#"","timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        )
        .unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert_eq!(snapshot.stats.total_calls, 1);
    assert!(!snapshot
        .warnings
        .iter()
        .any(|warning| warning.source == "usage_precision"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rebuilds_changed_files_and_removes_deleted_files() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let changed_file = session_dir.join("rollout-019eexact-change-0000-0000-0000-index.jsonl");
    let deleted_file = session_dir.join("rollout-019eexact-delete-0000-0000-0000-index.jsonl");
    write_lines(
        &changed_file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &deleted_file,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );

    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 150);
    assert_eq!(initial.stats.total_calls, 2);
    assert_eq!(initial.stats.total_threads, 2);

    write_lines(
        &changed_file,
        &[
            r#"{"timestamp":"2026-07-20T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":15,"total_tokens":75}}}}"#,
        ],
    );
    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 105);
    assert_eq!(rebuilt.stats.total_calls, 2);
    assert_eq!(rebuilt.stats.total_threads, 2);

    fs::remove_file(&deleted_file).unwrap();
    let after_delete = dashboard_snapshot(&root).unwrap();
    assert_eq!(after_delete.stats.total_tokens, 75);
    assert_eq!(after_delete.stats.total_calls, 1);
    assert_eq!(after_delete.stats.total_threads, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_prunes_superseded_file_versions_on_the_next_streaming_scan() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eversion-gc-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101,"cached_input_tokens":20,"output_tokens":20,"total_tokens":121}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 121);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM files", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        2
    );
    drop(connection);

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 121);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM files", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1,
        "obsolete file generations must not accumulate without bound"
    );
    drop(connection);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_scans_more_than_20_000_session_files_without_truncation() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    for index in 0..20_000 {
        fs::File::create(session_dir.join(format!("empty-{index:05}.jsonl"))).unwrap();
    }
    write_lines(
        &session_dir.join("rollout-019efile-count-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let summary = usage_summary(&root).unwrap();

    assert_eq!(summary.total_tokens, 120);
    assert_eq!(summary.today_requests, 0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_retries_an_incomplete_tail_after_the_jsonl_line_is_completed() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019epartial-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        write!(
            handle,
            "{}",
            r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40"#
        )
        .unwrap();
    }

    let incomplete = dashboard_snapshot(&root).unwrap();
    assert_eq!(incomplete.stats.total_tokens, 120);
    assert_eq!(incomplete.stats.total_calls, 1);

    {
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(
            handle,
            "{}",
            r#","cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#
        )
        .unwrap();
    }
    let completed = dashboard_snapshot(&root).unwrap();
    assert_eq!(completed.stats.total_tokens, 170);
    assert_eq!(completed.stats.total_calls, 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_commits_the_scan_start_prefix_while_the_active_file_appends() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_prefix_rehash_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-prefix-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let expected_file = fs::canonicalize(&file).unwrap();
    ExactUsageIndex::set_after_prefix_scan_hook_for_testing(move |scanned_file| {
        assert_eq!(scanned_file, expected_file);
        let mut handle = fs::OpenOptions::new()
            .append(true)
            .open(scanned_file)
            .unwrap();
        writeln!(
            handle,
            "{}",
            r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10,"total_tokens":50}}}}"#
        )
        .unwrap();
        handle.flush().unwrap();
    });

    let old_timepoint = dashboard_snapshot(&root).unwrap();
    assert_eq!(old_timepoint.stats.total_tokens, 120);
    assert_eq!(old_timepoint.stats.total_calls, 1);
    assert_eq!(
        ExactUsageIndex::prefix_rehash_count_for_testing(),
        1,
        "an active append must still revalidate the complete scan-start prefix"
    );

    let after_append = dashboard_snapshot(&root).unwrap();
    assert_eq!(after_append.stats.total_tokens, 170);
    assert_eq!(after_append.stats.total_calls, 2);
    assert_eq!(
        ExactUsageIndex::prefix_rehash_count_for_testing(),
        1,
        "a stable follow-up scan must not rehash an unchanged file"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_append_scan_reads_only_the_tail_chunk_and_new_suffix() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eappend-bytes-0000-0000-0000-exact.jsonl");
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    handle.write_all(br#"{"padding":""#).unwrap();
    let padding = vec![b'x'; 1024 * 1024];
    for _ in 0..12 {
        handle.write_all(&padding).unwrap();
    }
    handle.write_all(b"\"}\n").unwrap();
    handle
        .write_all(
            br#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        )
        .unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);
    let initial_size = fs::metadata(&file).unwrap().len();

    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let (cold_bytes, append_bytes_before) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(cold_bytes, initial_size);
    assert_eq!(append_bytes_before, 0);

    let appended = br#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#;
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    handle.write_all(appended).unwrap();
    handle.write_all(b"\n").unwrap();
    handle.flush().unwrap();
    drop(handle);

    let refreshed = dashboard_snapshot(&root).unwrap();
    assert_eq!(refreshed.stats.total_tokens, 150);
    assert_eq!(refreshed.stats.total_calls, 2);
    let (full_bytes_after, append_bytes_after) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(
        full_bytes_after, cold_bytes,
        "a pure append must not trigger another complete source parse"
    );
    assert!(
        append_bytes_after <= EXACT_INDEX_CHUNK_SIZE + appended.len() as u64 + 1,
        "append parser read {append_bytes_after} bytes instead of one tail chunk plus the suffix"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rolling_audit_falls_back_to_full_rebuild_after_middle_rewrite_and_append() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaudit-rewrite-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    writeln!(handle, "{original}").unwrap();
    handle.write_all(br#"{"padding":""#).unwrap();
    let padding = vec![b'z'; 1024 * 1024];
    for _ in 0..9 {
        handle.write_all(&padding).unwrap();
    }
    handle.write_all(b"\"}\n").unwrap();
    handle.flush().unwrap();
    drop(handle);
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    let before = fs::read_to_string(&file).unwrap();
    let rewritten = before.replacen("\"total_tokens\":120", "\"total_tokens\":121", 1);
    assert_eq!(before.len(), rewritten.len());
    fs::write(&file, rewritten).unwrap();
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(
        handle,
        "{}",
        r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#
    )
    .unwrap();
    handle.flush().unwrap();
    drop(handle);
    ExactUsageIndex::reset_scan_bytes_for_testing();

    let refreshed = dashboard_snapshot(&root).unwrap();

    assert_eq!(refreshed.stats.total_tokens, 151);
    assert_eq!(refreshed.stats.total_calls, 2);
    let (full_bytes, append_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(full_bytes, fs::metadata(&file).unwrap().len());
    assert_eq!(
        append_bytes, 0,
        "the rolling audit must reject the append checkpoint before suffix parsing"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_stable_cold_scan_does_not_read_the_complete_prefix_twice() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_prefix_rehash_count_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019estable-prefix-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert_eq!(
        ExactUsageIndex::prefix_rehash_count_for_testing(),
        0,
        "stable files should trust the hash produced by the parsing pass"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_parallel_stages_large_cold_files() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let padding = vec![b'p'; EXACT_INDEX_CHUNK_SIZE as usize];
    let mut expected_total = 0_u64;
    for index in 0_u64..4 {
        let file = session_dir.join(format!(
            "rollout-019eparallel-{index:04}-0000-0000-exact.jsonl"
        ));
        let mut handle = std::io::BufWriter::new(fs::File::create(file).unwrap());
        handle.write_all(br#"{"padding":""#).unwrap();
        handle.write_all(&padding).unwrap();
        handle.write_all(b"\"}\n").unwrap();
        let total = 120 + index;
        expected_total += total;
        writeln!(
            handle,
            "{}",
            serde_json::json!({
                "timestamp": "2026-07-20T01:00:00Z",
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "last_token_usage": {
                            "input_tokens": 100 + index,
                            "cached_input_tokens": 20,
                            "output_tokens": 20,
                            "total_tokens": total
                        }
                    }
                }
            })
        )
        .unwrap();
        handle.flush().unwrap();
    }
    ExactUsageIndex::reset_stage_concurrency_for_testing(75);

    let mut index = ExactUsageIndex::open(&root).unwrap();
    index.sync(&root, &mut Vec::new()).unwrap();

    assert!(
        ExactUsageIndex::stage_peak_concurrency_for_testing() >= 2,
        "large cold files must be parsed by more than one staging worker"
    );
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        expected_total
    );
    drop(index);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_reuses_private_staging_after_an_interrupted_import() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    ExactUsageIndex::reset_scan_bytes_for_testing();
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    let mut staging_path = index_path.as_os_str().to_os_string();
    staging_path.push(".staging");
    let staging_path = PathBuf::from(staging_path);
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019estage-recovery-0000-0000-exact.jsonl");
    let secret_question = "SECRET_STAGING_PROMPT_MUST_NOT_PERSIST_314159";
    let secret_answer = "SECRET_STAGING_ANSWER_MUST_NOT_PERSIST_271828";
    let mut handle = std::io::BufWriter::new(fs::File::create(&file).unwrap());
    writeln!(
        handle,
        r#"{{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{{"type":"user_message","message":"{secret_question}"}}}}"#
    )
    .unwrap();
    writeln!(
        handle,
        r#"{{"timestamp":"2026-07-20T01:00:20Z","type":"event_msg","payload":{{"type":"agent_message","message":"{secret_answer}"}}}}"#
    )
    .unwrap();
    handle.write_all(br#"{"padding":""#).unwrap();
    handle
        .write_all(&vec![b's'; EXACT_INDEX_CHUNK_SIZE as usize])
        .unwrap();
    handle.write_all(b"\"}\n").unwrap();
    writeln!(
        handle,
        "{}",
        serde_json::json!({
            "timestamp": "2026-07-20T01:01:00Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 20,
                        "total_tokens": 120
                    }
                }
            }
        })
    )
    .unwrap();
    handle.flush().unwrap();
    drop(handle);

    ExactUsageIndex::fail_after_staging_once_for_testing();
    let mut interrupted = ExactUsageIndex::open(&root).unwrap();
    let error = interrupted.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("injected interruption"), "{error}");
    drop(interrupted);

    let mut inspected_stage = false;
    for entry in fs::read_dir(&staging_path).unwrap() {
        let path = entry.unwrap().path();
        if !path.is_file() {
            continue;
        }
        inspected_stage = true;
        let bytes = fs::read(path).unwrap();
        assert!(!bytes
            .windows(secret_question.len())
            .any(|window| window == secret_question.as_bytes()));
        assert!(!bytes
            .windows(secret_answer.len())
            .any(|window| window == secret_answer.as_bytes()));
    }
    assert!(
        inspected_stage,
        "the interrupted build must leave a durable stage"
    );

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let mut resumed = ExactUsageIndex::open(&root).unwrap();
    resumed.sync(&root, &mut Vec::new()).unwrap();

    assert_eq!(
        ExactUsageIndex::scan_bytes_for_testing().0,
        0,
        "the retry must reuse the complete stage instead of rereading the source"
    );
    assert_eq!(
        resumed
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    assert!(
        !staging_path.exists(),
        "successful publication must remove stale staging databases"
    );
    drop(resumed);
    fs::remove_dir_all(root).unwrap();
}

#[test]
#[ignore = "set CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST=1 for the local full-history scan"]
fn live_exact_index_cold_and_warm_scans_when_explicitly_enabled() {
    assert_eq!(
        std::env::var("CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST").as_deref(),
        Ok("1"),
        "set CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST=1"
    );
    let root = PathBuf::from(
        std::env::var("CODEX_TOKEN_BAR_LIVE_CODEX_HOME")
            .expect("CODEX_TOKEN_BAR_LIVE_CODEX_HOME must point to the frozen snapshot"),
    );
    assert!(root.join("sessions").is_dir(), "{}", root.display());
    let _test_state = app_paths::app_path_test_env_guard(&[]);

    let cold_started = Instant::now();
    let mut cold_index = ExactUsageIndex::open(&root).unwrap();
    let cold_revision = cold_index.sync(&root, &mut Vec::new()).unwrap();
    let cold = cold_index
        .dashboard_data(
            &root,
            OffsetDateTime::now_utc(),
            UtcOffset::UTC,
            &mut Vec::new(),
        )
        .unwrap();
    let cold_elapsed = cold_started.elapsed();
    println!(
        "LIVE_EXACT_INDEX_COLD_RESULT elapsed_seconds={:.3} revision={} total_tokens={} total_calls={} total_threads={}",
        cold_elapsed.as_secs_f64(),
        cold_revision,
        cold.stats.total_tokens,
        cold.stats.total_calls,
        cold.stats.total_threads
    );
    drop(cold_index);

    let warm_started = Instant::now();
    let mut warm_index = ExactUsageIndex::open(&root).unwrap();
    let warm_revision = warm_index.sync(&root, &mut Vec::new()).unwrap();
    let warm = warm_index
        .dashboard_data(
            &root,
            OffsetDateTime::now_utc(),
            UtcOffset::UTC,
            &mut Vec::new(),
        )
        .unwrap();
    let warm_elapsed = warm_started.elapsed();
    assert_eq!(warm_revision, cold_revision);
    assert_eq!(warm.stats.total_tokens, cold.stats.total_tokens);
    assert_eq!(warm.stats.total_calls, cold.stats.total_calls);
    assert_eq!(warm.stats.total_threads, cold.stats.total_threads);
    println!(
        "LIVE_EXACT_INDEX_WARM_RESULT elapsed_seconds={:.3} revision={} total_tokens={} total_calls={} total_threads={}",
        warm_elapsed.as_secs_f64(),
        warm_revision,
        warm.stats.total_tokens,
        warm.stats.total_calls,
        warm.stats.total_threads
    );
}

#[test]
fn exact_index_migrates_v4_without_discarding_published_events() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019emigrate-v4-0000-0000-0000-exact.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let before = ExactUsageIndex::open(&root).unwrap();
    let revision = before.revision().unwrap();
    drop(before);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '4' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE files SET append_ready = 0, resume_offset = NULL",
            [],
        )
        .unwrap();
    connection.execute("DROP TABLE file_chunks", []).unwrap();
    connection
        .execute("DROP TABLE file_fingerprints", [])
        .unwrap();
    drop(connection);

    let migrated = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(migrated.revision().unwrap(), revision);
    assert_eq!(
        migrated
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    drop(migrated);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "5"
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM events", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    drop(connection);

    ExactUsageIndex::reset_scan_bytes_for_testing();
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(
        handle,
        "{}",
        r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#
    )
    .unwrap();
    handle.flush().unwrap();
    drop(handle);
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 150);
    let (full_bytes, append_bytes) = ExactUsageIndex::scan_bytes_for_testing();
    assert_eq!(full_bytes, fs::metadata(&file).unwrap().len());
    assert_eq!(append_bytes, 0);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_cold_scan_resumes_committed_files_without_publishing_partial_totals() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019eresume-a-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    write_lines(
        &session_dir.join("rollout-019eresume-b-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );

    let committed_path = Arc::new(Mutex::new(None::<PathBuf>));
    let committed_path_for_hook = Arc::clone(&committed_path);
    ExactUsageIndex::set_after_file_commit_hook_for_testing(move |path| {
        *committed_path_for_hook.lock().unwrap() = Some(path.to_path_buf());
        Err("injected interruption after durable file commit".into())
    });
    let mut index = ExactUsageIndex::open(&root).unwrap();
    let initial_revision = index.revision().unwrap();
    let error = index.sync(&root, &mut Vec::new()).unwrap_err();
    assert!(error.contains("injected interruption"), "{error}");
    drop(index);

    let connection = Connection::open(&index_path).unwrap();
    let building_generation = connection
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM metadata WHERE key = 'building_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM files WHERE generation = ?1 AND deleted = 0",
                [building_generation],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1,
        "the completed file must be durable before the full generation publishes"
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM published_events", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0,
        "cold-start readers must not see staged event rows"
    );
    drop(connection);

    let index = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(index.revision().unwrap(), initial_revision);
    assert!(index.is_empty().unwrap());
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        0
    );
    drop(index);
    assert!(cached_dashboard_usage_summary(&root).is_none());

    let resumed_parse = Arc::new(Mutex::new(None::<PathBuf>));
    let resumed_parse_for_hook = Arc::clone(&resumed_parse);
    ExactUsageIndex::set_after_prefix_scan_hook_for_testing(move |path| {
        *resumed_parse_for_hook.lock().unwrap() = Some(path.to_path_buf());
    });
    let mut resumed = ExactUsageIndex::open(&root).unwrap();
    let completed_revision = resumed.sync(&root, &mut Vec::new()).unwrap();
    assert!(completed_revision > initial_revision);
    assert_eq!(
        resumed
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        150
    );
    assert!(resumed_parse.lock().unwrap().is_some());
    assert!(committed_path.lock().unwrap().is_some());
    assert_ne!(
        resumed_parse.lock().unwrap().as_ref(),
        committed_path.lock().unwrap().as_ref(),
        "resume must skip the file whose current signature was already committed"
    );
    let connection = Connection::open(&index_path).unwrap();
    assert!(connection
        .query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM metadata WHERE key = 'building_generation')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .unwrap());
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM published_files", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        2
    );
    drop(connection);
    drop(resumed);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_interrupted_refresh_keeps_the_previous_complete_revision_and_aggregate() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let original_file = session_dir.join("rollout-019epublished-a-0000-0000-0000-exact.jsonl");
    write_lines(
        &original_file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);
    let published_revision = ExactUsageIndex::open(&root).unwrap().revision().unwrap();

    write_lines(
        &original_file,
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101,"cached_input_tokens":20,"output_tokens":20,"total_tokens":121}}}}"#,
        ],
    );
    write_lines(
        &session_dir.join("rollout-019epublished-b-0000-0000-0000-exact.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#,
        ],
    );
    ExactUsageIndex::set_after_file_commit_hook_for_testing(|_| {
        Err("injected interruption with a published generation".into())
    });
    let mut interrupted = ExactUsageIndex::open(&root).unwrap();
    assert!(interrupted.sync(&root, &mut Vec::new()).is_err());
    assert_eq!(interrupted.revision().unwrap(), published_revision);
    assert_eq!(
        interrupted
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120,
        "staged rows must never pollute the prior published total"
    );
    assert_eq!(
        cached_dashboard_usage_summary(&root).unwrap().total_tokens,
        120,
        "the UI-facing aggregate must remain on the last complete revision"
    );

    let completed_revision = interrupted.sync(&root, &mut Vec::new()).unwrap();
    assert!(completed_revision > published_revision);
    assert_eq!(
        interrupted
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        151
    );
    drop(interrupted);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_rolls_back_when_the_scanned_prefix_is_rewritten() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019erewrite-prefix-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let appended = r#"{"timestamp":"2026-07-20T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":5,"total_tokens":30}}}}"#;
    write_lines(&file, &[original]);
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    let before_revision = ExactUsageIndex::open(&root).unwrap().revision().unwrap();

    write_lines(&file, &[original, appended]);
    ExactUsageIndex::set_after_prefix_scan_hook_for_testing(|scanned_file| {
        let before = fs::read_to_string(scanned_file).unwrap();
        let after = before.replacen("\"total_tokens\":30", "\"total_tokens\":31", 1);
        assert_eq!(before.len(), after.len());
        fs::write(scanned_file, after).unwrap();
    });

    let error = dashboard_snapshot(&root).unwrap_err();
    assert!(error.contains("非追加变化"), "{error}");
    assert!(error.contains("既有字节被改写"), "{error}");
    let index = ExactUsageIndex::open(&root).unwrap();
    assert_eq!(index.revision().unwrap(), before_revision);
    assert_eq!(
        index
            .summary(OffsetDateTime::now_utc(), UtcOffset::UTC)
            .unwrap()
            .total_tokens,
        120
    );
    drop(index);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_detects_an_equal_length_rewrite_after_mtime_is_restored() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019ectime-rewrite-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let rewritten = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101,"cached_input_tokens":20,"output_tokens":20,"total_tokens":121}}}}"#;
    assert_eq!(original.len(), rewritten.len());
    write_lines(&file, &[original]);
    let initial = dashboard_snapshot(&root).unwrap();
    assert_eq!(initial.stats.total_tokens, 120);
    let original_modified = fs::metadata(&file).unwrap().modified().unwrap();

    write_lines(&file, &[rewritten]);
    fs::File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(original_modified))
        .unwrap();
    assert_eq!(
        fs::metadata(&file).unwrap().modified().unwrap(),
        original_modified
    );

    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 121);
    assert_eq!(rebuilt.stats.total_calls, 1);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_quick_check_recovers_a_corrupt_database_by_rebuilding() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_path = root
        .join(".codex-token-bar-test-cache")
        .join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019ecorrupt-index-0000-0000-0000-exact.jsonl");
    let original = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#;
    let rewritten = r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101,"cached_input_tokens":20,"output_tokens":20,"total_tokens":121}}}}"#;
    write_lines(&file, &[original]);
    assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens, 120);

    write_lines(&file, &[rewritten]);
    let index_size = fs::metadata(&index_path).unwrap().len();
    let mut index_file = fs::OpenOptions::new()
        .write(true)
        .open(&index_path)
        .unwrap();
    index_file.seek(SeekFrom::Start(100)).unwrap();
    index_file.write_all(&[0]).unwrap();
    index_file.flush().unwrap();
    drop(index_file);
    assert_eq!(fs::metadata(&index_path).unwrap().len(), index_size);

    let rebuilt = dashboard_snapshot(&root).unwrap();
    assert_eq!(rebuilt.stats.total_tokens, 121);
    let connection = Connection::open(&index_path).unwrap();
    assert_eq!(
        connection
            .query_row("PRAGMA quick_check(1)", [], |row| row.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "5"
    );
    drop(connection);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn exact_index_replaces_plaintext_v1_storage_and_keeps_only_source_offsets() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let session_dir = root.join("sessions");
    let index_dir = root.join(".codex-token-bar-test-cache");
    let index_path = index_dir.join("exact-token-index.sqlite3");
    fs::create_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&index_dir).unwrap();

    let secret_question = "SECRET_PROMPT_EXACT_INDEX_MUST_NOT_PERSIST_7E2B";
    let secret_answer = "SECRET_ANSWER_EXACT_INDEX_MUST_NOT_PERSIST_91FC";
    {
        let legacy = Connection::open(&index_path).unwrap();
        legacy
            .execute_batch(
                r#"
                PRAGMA journal_mode = WAL;
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO metadata(key, value) VALUES ('schema_version', '1');
                CREATE TABLE legacy_events (
                    user_prompt TEXT NOT NULL,
                    assistant_response TEXT NOT NULL
                );
                "#,
            )
            .unwrap();
        legacy
            .execute(
                "INSERT INTO legacy_events(user_prompt, assistant_response) VALUES (?1, ?2)",
                rusqlite::params![secret_question, secret_answer],
            )
            .unwrap();
    }

    let user_line = format!(
        r#"{{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{{"type":"user_message","message":"{secret_question}"}}}}"#
    );
    let assistant_line = format!(
        r#"{{"timestamp":"2026-07-20T01:00:20Z","type":"event_msg","payload":{{"type":"agent_message","message":"{secret_answer}"}}}}"#
    );
    write_lines(
        &session_dir.join("rollout-019eprivacy-0000-0000-0000-offsets.jsonl"),
        &[
            user_line.as_str(),
            assistant_line.as_str(),
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":50,"total_tokens":1250}}}}"#,
        ],
    );

    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.cache_usage.turns[0].user_prompt, secret_question);
    assert_eq!(
        snapshot.cache_usage.turns[0].assistant_response,
        secret_answer
    );

    let connection = Connection::open(&index_path).unwrap();
    let columns = connection
        .prepare("PRAGMA table_info(events)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(!columns.iter().any(|column| column == "user_prompt"));
    assert!(!columns.iter().any(|column| column == "assistant_response"));
    assert!(columns.iter().any(|column| column == "user_prompt_start"));
    assert!(columns
        .iter()
        .any(|column| column == "assistant_response_end"));
    connection
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            INSERT OR REPLACE INTO metadata(key, value) VALUES ('privacy_test_probe', '1');
            "#,
        )
        .unwrap();

    for path in [
        index_path.clone(),
        PathBuf::from(format!("{}-wal", index_path.display())),
        PathBuf::from(format!("{}-shm", index_path.display())),
    ] {
        let bytes = fs::read(&path)
            .unwrap_or_else(|error| panic!("failed to scan {}: {error}", path.display()));
        assert!(
            !bytes
                .windows(secret_question.len())
                .any(|window| window == secret_question.as_bytes()),
            "{} retained the prompt plaintext",
            path.display()
        );
        assert!(
            !bytes
                .windows(secret_answer.len())
                .any(|window| window == secret_answer.as_bytes()),
            "{} retained the answer plaintext",
            path.display()
        );
    }
    drop(connection);

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn exact_index_rejects_a_session_symlink_that_escapes_selected_codex_home() {
    use std::os::unix::fs::symlink;

    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let outside_root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&outside_root).unwrap();
    write_lines(
        &session_dir.join("rollout-019eboundary-valid-0000-0000-0000-home.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let outside_file = outside_root.join("rollout-019eboundary-outside.jsonl");
    write_lines(
        &outside_file,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":99,"total_tokens":999}}}}"#,
        ],
    );
    symlink(&outside_file, session_dir.join("escaped-session.jsonl")).unwrap();

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(snapshot.warnings.iter().any(|warning| {
        warning.source == "jsonl_scan" && warning.message.contains("Codex Home 外")
    }));

    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside_root).unwrap();
}

#[test]
fn exact_index_rejects_an_absolute_state_rollout_outside_selected_codex_home() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let outside_root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&outside_root).unwrap();
    write_lines(
        &session_dir.join("rollout-019estate-valid-0000-0000-0000-home.jsonl"),
        &[
            r#"{"timestamp":"2026-07-20T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let outside_file = outside_root.join("rollout-019estate-outside.jsonl");
    write_lines(
        &outside_file,
        &[
            r#"{"timestamp":"2026-07-20T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":99,"total_tokens":999}}}}"#,
        ],
    );
    create_state_database_with_rollout(
        &root,
        "019estate-outside-0000-0000-0000-rollout",
        &outside_file,
    );

    let snapshot = dashboard_snapshot(&root).unwrap();

    assert_eq!(snapshot.stats.total_tokens, 120);
    assert!(snapshot.warnings.iter().any(|warning| {
        warning.source == "jsonl_scan" && warning.message.contains("Codex Home 外")
    }));

    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside_root).unwrap();
}

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
fn interleaved_cumulative_streams_use_unique_last_usage_snapshots() {
    let root = temp_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019finterleaved-0000-0000-eeeeffffffff.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-07-22T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718279305,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718279305},"last_token_usage":{"input_tokens":157910,"cached_input_tokens":0,"output_tokens":0,"total_tokens":157910}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2583955090,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2583955090},"last_token_usage":{"input_tokens":113621,"cached_input_tokens":0,"output_tokens":0,"total_tokens":113621}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:20Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718279305,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718279305},"last_token_usage":{"input_tokens":157910,"cached_input_tokens":0,"output_tokens":0,"total_tokens":157910}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:30Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2584078056,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2584078056},"last_token_usage":{"input_tokens":122966,"cached_input_tokens":0,"output_tokens":0,"total_tokens":122966}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:40Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718437623,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718437623},"last_token_usage":{"input_tokens":158318,"cached_input_tokens":0,"output_tokens":0,"total_tokens":158318}}}}"#,
            r#"{"timestamp":"2026-07-22T01:00:50Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2718437623,"cached_input_tokens":0,"output_tokens":0,"total_tokens":2718437623},"last_token_usage":{"input_tokens":77777,"cached_input_tokens":0,"output_tokens":0,"total_tokens":77777}}}}"#,
        ],
    );

    let mut warnings = Vec::new();
    let parsed = parse_session_file_full_result(
        &file,
        "019finterleaved-0000-0000-eeeeffffffff",
        &mut warnings,
    );

    assert_eq!(parsed.events.len(), 5);
    assert_eq!(
        parsed.events.iter().map(|event| event.tokens).sum::<u64>(),
        630_592
    );
    assert_eq!(
        parsed
            .events
            .iter()
            .map(|event| event.input_tokens)
            .sum::<u64>(),
        630_592
    );
    assert_eq!(parsed.previous_total_tokens, Some(2_718_437_623));

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
    fs::create_dir_all(&root).unwrap();
    let offset = UtcOffset::from_hms(8, 0, 0).unwrap();
    let before_midnight = OffsetDateTime::parse("2026-06-18T15:59:59Z", &Rfc3339).unwrap();
    let after_midnight = OffsetDateTime::parse("2026-06-18T16:00:01Z", &Rfc3339).unwrap();

    let before = dashboard_scan_signature_at(&root, 42, before_midnight, offset);
    let after = dashboard_scan_signature_at(&root, 42, after_midnight, offset);

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
            r#"{"timestamp":"2026-06-18T01:05:00Z","type":"event_msg","payload":{"type":"user_message","message":"第二轮\n问题"}}"#,
            r#"{"timestamp":"2026-06-18T01:05:20Z","type":"event_msg","payload":{"type":"agent_message","message":"第二轮回答\t补充"}}"#,
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
    assert_eq!(second_turn.user_prompt, "第二轮 问题");
    assert_eq!(second_turn.assistant_response, "第二轮回答 补充");
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
fn dashboard_snapshot_refreshes_after_thread_metadata_changes() {
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
        build_count_after_first_load + 1
    );

    fs::remove_dir_all(root).unwrap();
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
fn dashboard_aggregate_persists_a_compact_startup_snapshot_then_rebuilds_full_details() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("dashboard-aggregate.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
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
    assert_eq!(json["version"], 16);
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
fn usage_summary_rejects_v11_and_reuses_rebuilt_v16_dashboard_aggregate() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let cache_path = root.join("token-aggregate-cache.json");
    let _cache_env = AggregateCacheEnvGuard::new(cache_path.clone());
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    let file = session_dir.join("rollout-019eaggregate-stale-v11-cache.jsonl");
    write_lines(
        &file,
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );
    let signature = dashboard_index_signature(&root, 0);
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
    assert!(aggregate_cache_text().contains(r#""version":16"#));
    assert!(aggregate_cache_text().contains(r#""totalTokens":120"#));

    reset_dashboard_aggregate_build_count_for_testing();
    let reused = usage_summary(&root).unwrap();
    assert_eq!(reused.total_tokens, 120);
    assert_eq!(
        dashboard_aggregate_build_count_for_testing(&root),
        0,
        "current v16 aggregate should be reused after memory state is cleared"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cached_usage_summary_is_scoped_to_codex_home() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
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
    let signature = dashboard_scan_signature_at(&root, 0, now, offset);
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
            assert_eq!(
                dashboard_aggregate_build_count_for_testing(&root),
                0,
                "compact summary refresh must not rebuild the full dashboard aggregate"
            );
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
        0,
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
    let mut first_signature = dashboard_scan_signature_at(&root, 0, now, UtcOffset::UTC);
    first_signature.index_revision = 100;
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
    active_signature.index_revision = 110;
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
fn usage_summary_snapshot_cache_miss_schedules_one_lightweight_background_refresh() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = temp_root();
    let _cache_env = AggregateCacheEnvGuard::new(root.join("token-aggregate-cache.json"));
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_lines(
        &session_dir.join("rollout-019esummary-0000-0000-0000-background.jsonl"),
        &[
            r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#,
        ],
    );

    reset_dashboard_aggregate_build_count_for_testing();
    let _ = usage_summary_snapshot(&root);
    let _ = usage_summary_snapshot(&root);
    let _ = usage_summary_snapshot(&root);

    for _ in 0..100 {
        std::thread::sleep(std::time::Duration::from_millis(20));
        if let Ok(summary) = usage_summary_snapshot(&root) {
            assert_eq!(summary.total_tokens, 120);
            assert_eq!(
                dashboard_aggregate_build_count_for_testing(&root),
                0,
                "compact summary refresh must not build rankings, charts, or excerpts"
            );
            wait_for_usage_summary_refreshes_for_testing();
            fs::remove_dir_all(root).unwrap();
            return;
        }
    }

    panic!("usage summary background build did not finish");
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

fn aggregate_cache_text() -> String {
    app_paths::token_aggregate_cache_path()
        .and_then(|path| fs::read_to_string(path).ok())
        .unwrap_or_default()
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
