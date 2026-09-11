use super::exact_usage_index::ExactUsageIndex;
use super::{app_paths, dashboard_snapshot};
use rusqlite::{params, Connection, OptionalExtension};
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[test]
fn accounting_migration_reconciles_legacy_rows_and_is_idempotent() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = prepare_legacy_accounting_fixture();
    let index_path = super::exact_usage_index::database_path(&root).unwrap();

    let before_row_count = {
        let connection = Connection::open(&index_path).unwrap();
        connection
            .query_row("SELECT COUNT(*) FROM event_rows", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap()
    };
    assert_eq!(before_row_count, 2);

    drop(ExactUsageIndex::open(&root).unwrap());

    let first = Connection::open(&index_path).unwrap();
    assert_eq!(metadata_value(&first, "schema_version"), Some("13".into()));
    assert_eq!(
        metadata_value(&first, "accounting_revision"),
        Some("codex-components-v1".into())
    );
    assert_eq!(
        metadata_value(&first, "accounting_coverage"),
        Some("legacy-source-audit-required".into())
    );
    assert_eq!(
        event_rows(&first),
        vec![
            EventAccountingRow {
                tokens: 110,
                accounting_kind: 0,
                reported_total_tokens: None,
                legacy_tokens: Some(999),
            },
            EventAccountingRow {
                tokens: 0,
                accounting_kind: 3,
                reported_total_tokens: None,
                legacy_tokens: Some(53_707),
            },
        ]
    );
    assert_eq!(attribution_calls(&first), 1);
    assert_eq!(dashboard_calls(&first), 1);
    drop(first);

    drop(ExactUsageIndex::open(&root).unwrap());

    let second = Connection::open(&index_path).unwrap();
    assert_eq!(
        event_rows(&second),
        vec![
            EventAccountingRow {
                tokens: 110,
                accounting_kind: 0,
                reported_total_tokens: None,
                legacy_tokens: Some(999),
            },
            EventAccountingRow {
                tokens: 0,
                accounting_kind: 3,
                reported_total_tokens: None,
                legacy_tokens: Some(53_707),
            },
        ]
    );
    assert_eq!(attribution_calls(&second), 1);
    assert_eq!(dashboard_calls(&second), 1);
    assert_eq!(
        second
            .query_row("SELECT COUNT(*) FROM event_rows", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        before_row_count
    );
    drop(second);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn accounting_migration_rolls_back_event_updates_and_markers_then_retries() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = prepare_legacy_accounting_fixture();
    let index_path = super::exact_usage_index::database_path(&root).unwrap();
    let before = {
        let connection = Connection::open(&index_path).unwrap();
        event_rows(&connection)
    };

    {
        let connection = Connection::open(&index_path).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TRIGGER accounting_migration_test_abort
                BEFORE UPDATE ON event_rows
                BEGIN
                    SELECT RAISE(ABORT, 'accounting migration test failure');
                END;
                "#,
            )
            .unwrap();
    }

    let error = match ExactUsageIndex::open(&root) {
        Ok(_) => panic!("accounting migration should fail through the test trigger"),
        Err(error) => error,
    };
    assert!(
        error.contains("accounting migration test failure"),
        "unexpected migration error: {error}"
    );

    let failed = Connection::open(&index_path).unwrap();
    assert_eq!(metadata_value(&failed, "schema_version"), Some("11".into()));
    assert_eq!(metadata_value(&failed, "accounting_revision"), None);
    assert_eq!(metadata_value(&failed, "accounting_coverage"), None);
    assert_eq!(metadata_value(&failed, "accounting_structural_receipt"), None);
    assert_eq!(event_rows(&failed), before);
    drop(failed);

    let connection = Connection::open(&index_path).unwrap();
    connection
        .execute("DROP TRIGGER accounting_migration_test_abort", [])
        .unwrap();
    drop(connection);

    drop(ExactUsageIndex::open(&root).unwrap());

    let recovered = Connection::open(&index_path).unwrap();
    assert_eq!(metadata_value(&recovered, "schema_version"), Some("13".into()));
    assert_eq!(
        metadata_value(&recovered, "accounting_revision"),
        Some("codex-components-v1".into())
    );
    assert_eq!(event_rows(&recovered)[0].tokens, 110);
    assert_eq!(event_rows(&recovered)[0].legacy_tokens, Some(999));
    assert_eq!(attribution_calls(&recovered), 1);
    drop(recovered);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn dashboard_snapshot_excludes_diagnostics_from_every_numeric_surface() {
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    let root = unique_test_root();
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339).unwrap();
    write_token_count_line(&sessions.join("rollout-valid.jsonl"), &timestamp, 100, 40, 10, 7, 999);
    let valid_path = sessions.join("rollout-valid.jsonl");
    let usage_line = fs::read_to_string(&valid_path).unwrap();
    let prompt = serde_json::json!({"timestamp":timestamp,"type":"event_msg","payload":{"type":"user_message","message":"accounting regression"}});
    fs::write(&valid_path, format!("{prompt}\n{usage_line}")).unwrap();
    write_token_count_line(&sessions.join("rollout-invalid.jsonl"), &timestamp, 10, 11, 3, 1, 24);
    write_token_count_line(&sessions.join("rollout-boundary.jsonl"), &timestamp, 0, 0, 0, 0, 53_707);
    let snapshot = dashboard_snapshot(&root).unwrap();
    assert_eq!(snapshot.stats.total_tokens, 110);
    assert_eq!(snapshot.stats.total_calls, 1);
    assert_eq!(snapshot.stats.total_input_tokens, 100);
    assert_eq!(snapshot.stats.total_cached_input_tokens, 40);
    assert_eq!(snapshot.stats.total_output_tokens, 10);
    assert_eq!(snapshot.activity_days.iter().map(|d| d.calls).sum::<u32>(), 1);
    assert_eq!(snapshot.cache_usage.sessions.iter().map(|s| s.breakdown.calls).sum::<u32>(), 1);
    assert_eq!(snapshot.cache_usage.sessions.iter().map(|s| s.breakdown.input_tokens).sum::<u64>(), 100);
    let summary = super::dashboard_usage_summary(&root).unwrap();
    assert_eq!(summary.today_requests, 1);
    assert_eq!(summary.today_tokens, 110);
    let connection = Connection::open(super::exact_usage_index::database_path(&root).unwrap()).unwrap();
    assert_eq!(connection.query_row("SELECT COUNT(*) FROM event_rows", [], |r| r.get::<_, i64>(0)).unwrap(), 3);
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn partial_snapshot_fingerprints_survive_nonadjacent_replay_and_reopen() {
    use std::io::Write;
    let _test_state = app_paths::app_path_test_env_guard(&[]);
    for include_cumulative_without_reported_total in [false, true] {
        let root = unique_test_root();
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let file = sessions.join("rollout-partial-identity.jsonl");
        let line = |timestamp: &str, input: u64, output: u64| {
            let usage = serde_json::json!({"input_tokens":input,"output_tokens":output});
            let mut info = serde_json::json!({"last_token_usage":usage});
            if include_cumulative_without_reported_total {
                info["total_token_usage"] = usage;
            }
            serde_json::json!({"timestamp":timestamp,"type":"event_msg","payload":{"type":"token_count","info":info}}).to_string()
        };
        let a = line("2026-09-05T01:00:00.123456Z", 100, 10);
        let b = line("2026-09-05T01:01:00.123456Z", 20, 5);
        fs::write(&file, format!("{a}\n{b}\n{a}\n")).unwrap();
        let first = dashboard_snapshot(&root).unwrap();
        assert_eq!(first.stats.total_tokens, 135);
        assert_eq!(first.stats.total_calls, 2);
        drop(ExactUsageIndex::open(&root).unwrap());
        let distinct_a = line("2026-09-05T01:02:00.123456Z", 100, 10);
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(handle, "{a}\n{distinct_a}").unwrap();
        drop(handle);
        let resumed = dashboard_snapshot(&root).unwrap();
        assert_eq!(resumed.stats.total_tokens, 245);
        assert_eq!(resumed.stats.total_calls, 3);
        fs::remove_dir_all(root).unwrap();
    }
}

#[derive(Debug, Eq, PartialEq)]
struct EventAccountingRow {
    tokens: i64,
    accounting_kind: i64,
    reported_total_tokens: Option<i64>,
    legacy_tokens: Option<i64>,
}

fn prepare_legacy_accounting_fixture() -> PathBuf {
    let root = unique_test_root();
    let session_dir = root.join("sessions");
    fs::create_dir_all(&session_dir).unwrap();
    write_token_count_line(
        &session_dir.join("rollout-019eaaaa-bbbb-4ccc-8ddd-000000000001.jsonl"),
        "2026-09-06T01:00:00Z",
        100,
        40,
        10,
        7,
        110,
    );
    write_token_count_line(
        &session_dir.join("rollout-019eaaaa-bbbb-4ccc-8ddd-000000000002.jsonl"),
        "2026-09-06T01:05:00Z",
        1,
        0,
        0,
        0,
        53_707,
    );

    dashboard_snapshot(&root).unwrap();
    let index_path = super::exact_usage_index::database_path(&root).unwrap();
    let connection = Connection::open(index_path).unwrap();
    let ids = {
        let mut statement = connection
            .prepare("SELECT id FROM event_rows ORDER BY input_tokens DESC, id")
            .unwrap();
        statement
            .query_map([], |row| row.get::<_, i64>(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    };
    assert_eq!(ids.len(), 2);
    connection
        .execute(
            "UPDATE event_rows SET tokens = 999, reported_total_tokens = NULL WHERE id = ?1",
            params![ids[0]],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE event_rows SET tokens = 53707, input_tokens = 0, reported_total_tokens = NULL WHERE id = ?1",
            params![ids[1]],
        )
        .unwrap();
    connection
        .execute(
            "DELETE FROM metadata WHERE key IN ('accounting_revision', 'accounting_coverage', 'accounting_structural_receipt')",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE metadata SET value = '11' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    drop(connection);
    root
}

fn event_rows(connection: &Connection) -> Vec<EventAccountingRow> {
    let mut statement = connection
        .prepare(
            "SELECT tokens, accounting_kind, reported_total_tokens, legacy_tokens
             FROM event_rows ORDER BY input_tokens DESC, id",
        )
        .unwrap();
    statement
        .query_map([], |row| {
            Ok(EventAccountingRow {
                tokens: row.get(0)?,
                accounting_kind: row.get(1)?,
                reported_total_tokens: row.get(2)?,
                legacy_tokens: row.get(3)?,
            })
        })
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap()
}

fn attribution_calls(connection: &Connection) -> i64 {
    connection
        .query_row(
            "SELECT COALESCE(SUM(calls), 0) FROM attribution_source_buckets",
            [],
            |row| row.get(0),
        )
        .unwrap()
}

fn dashboard_calls(connection: &Connection) -> i64 {
    connection
        .query_row(
            "SELECT COALESCE(SUM(calls), 0) FROM dashboard_5m_current",
            [],
            |row| row.get(0),
        )
        .unwrap()
}

fn metadata_value(connection: &Connection, key: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT value FROM metadata WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .unwrap()
}

fn write_token_count_line(
    path: &Path,
    timestamp: &str,
    input: u64,
    cached: u64,
    output: u64,
    reasoning: u64,
    total: u64,
) {
    let line = serde_json::json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {
                    "input_tokens": input,
                    "cached_input_tokens": cached,
                    "output_tokens": output,
                    "reasoning_output_tokens": reasoning,
                    "total_tokens": total
                }
            }
        }
    });
    fs::write(path, format!("{line}\n")).unwrap();
}

fn unique_test_root() -> PathBuf {
    std::env::temp_dir().join(format!(
        "codex-token-bar-tauri-accounting-migration-{}",
        Uuid::new_v4()
    ))
}
