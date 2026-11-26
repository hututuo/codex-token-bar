use super::*;
use std::io::Write;

const FOUR_MIB: usize = 4 * 1024 * 1024;
const SIXTEEN_MIB: usize = 16 * 1024 * 1024;
const FIXTURE_SESSION: &str = "anonymous-boundary-session";
const FIXTURE_MODEL: &str = "claude-sonnet-4-5";
const FIXTURE_TIMESTAMP_MS: i64 = 1_792_491_609_125;

fn classification_header(client: &str) -> Vec<u8> {
    let entrypoint = if client == "claudeDesktop" {
        "claude-desktop-boundary-test"
    } else {
        "claude-code-boundary-test"
    };
    format!("{{\"type\":\"system\",\"entrypoint\":\"{entrypoint}\"}}\n").into_bytes()
}

/// Sizes include the terminating LF. Usage deliberately follows all content.
fn claude_record(
    byte_count: usize,
    client: &str,
    structured_content: bool,
    id: &str,
    has_usage: bool,
) -> Vec<u8> {
    let entrypoint = if client == "claudeDesktop" {
        "claude-desktop-boundary-test"
    } else {
        "claude-code-boundary-test"
    };
    let mut prefix = format!(
        "{{\"type\":\"assistant\",\"entrypoint\":\"{entrypoint}\",\"sessionId\":\"{FIXTURE_SESSION}\",\"timestamp\":\"2026-10-20T10:20:09.125Z\",\"message\":{{\"id\":{},\"model\":\"{FIXTURE_MODEL}\",\"content\":",
        serde_json::to_string(id).unwrap()
    );
    prefix.push_str(if structured_content {
        "[{\"type\":\"text\",\"text\":\""
    } else {
        "\""
    });
    let mut suffix = if structured_content {
        "\"},{\"type\":\"tool_use\",\"id\":\"anonymous-tool\",\"name\":\"bounded_fixture\",\"input\":{\"argument\":\"synthetic\"}}]".to_string()
    } else {
        "\"".to_string()
    };
    if has_usage {
        suffix.push_str(
            r#","usage":{"input_tokens":1234,"output_tokens":57,"cache_read_input_tokens":89,"cache_creation_input_tokens":144,"cache_creation":{"ephemeral_5m_input_tokens":55,"ephemeral_1h_input_tokens":89},"output_tokens_details":{"thinking_tokens":13}}"#,
        );
    }
    suffix.push_str("}}\n");
    let content_bytes = byte_count
        .checked_sub(prefix.len() + suffix.len())
        .expect("fixture must have room for JSON framing");
    let mut bytes = Vec::with_capacity(byte_count);
    bytes.extend_from_slice(prefix.as_bytes());
    bytes.resize(bytes.len() + content_bytes, b'x');
    bytes.extend_from_slice(suffix.as_bytes());
    assert_eq!(bytes.len(), byte_count);
    assert_eq!(bytes.last(), Some(&b'\n'));
    assert_eq!(bytes.iter().filter(|byte| **byte == b'\n').count(), 1);
    bytes
}

fn append_bytes(path: &Path, bytes: &[u8]) {
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    file.write_all(bytes).unwrap();
    file.flush().unwrap();
}

fn open_fixture_ledger(path: &Path) -> Connection {
    let connection = Connection::open(path).unwrap();
    ensure_schema(&connection, path).unwrap();
    connection
}

fn small_oracle(path: &Path, client: &str, structured: bool, id: &str) -> UsageEvent {
    let events = parse_claude(
        &claude_record(2048, client, structured, id, true),
        path,
        client,
    );
    assert_eq!(events.len(), 1);
    let event = events.into_iter().next().unwrap();
    assert_eq!(event.client, client);
    assert_eq!(event.session_id, FIXTURE_SESSION);
    assert_eq!(event.model, FIXTURE_MODEL);
    assert_eq!(event.timestamp_ms, FIXTURE_TIMESTAMP_MS);
    assert_eq!(event.input_tokens, 1_467);
    assert_eq!(event.output_tokens, 57);
    assert_eq!(event.cache_read_tokens, Some(89));
    assert_eq!(event.cache_write_tokens, Some(144));
    assert_eq!(event.cache_write_5m_tokens, Some(55));
    assert_eq!(event.cache_write_1h_tokens, Some(89));
    assert_eq!(event.reasoning_tokens, Some(13));
    assert_eq!(event.quality, "recorded");
    assert_eq!(
        event.event_id,
        format!(
            "v1:{}:id:{}",
            hex_digest(FIXTURE_SESSION.as_bytes()),
            hex_digest(id.as_bytes())
        )
    );
    event
}

fn assert_events(connection: &Connection, expected: &[UsageEvent]) {
    let actual: Vec<Value> = connection
        .prepare(
            "SELECT json_array(client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,json(payload)) FROM client_usage_events ORDER BY client,event_id",
        )
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .map(|row| serde_json::from_str(&row.unwrap()).unwrap())
        .collect();
    let mut events = expected.to_vec();
    events.sort_by(|left, right| {
        (&left.client, &left.event_id).cmp(&(&right.client, &right.event_id))
    });
    let actual_revisions: Vec<Value> = connection
        .prepare(
            "SELECT json_array(client,event_id,json(payload)) FROM client_usage_revisions ORDER BY client,event_id,revision",
        )
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .map(|row| serde_json::from_str(&row.unwrap()).unwrap())
        .collect();
    let expected_revisions: Vec<Value> = events
        .iter()
        .map(|event| {
            serde_json::json!([
                event.client,
                event.event_id,
                serde_json::from_str::<Value>(&event_payload(event).unwrap()).unwrap()
            ])
        })
        .collect();
    assert_eq!(actual_revisions, expected_revisions);
    let expected: Vec<Value> = events
        .iter()
        .map(|event| {
            serde_json::json!([
                event.client,
                event.event_id,
                event.session_id,
                event.model,
                event.timestamp_ms as f64 / 1000.0,
                event.input_tokens,
                event.output_tokens,
                event.cache_read_tokens,
                event.cache_write_tokens,
                event.reasoning_tokens,
                serde_json::from_str::<Value>(&event_payload(event).unwrap()).unwrap()
            ])
        })
        .collect();
    assert_eq!(actual, expected);
}

/// Includes revision payloads/timestamps and every checkpoint field, not just counts.
fn ledger_state(connection: &Connection) -> Vec<Vec<String>> {
    [
        "SELECT json_array(client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,payload) FROM client_usage_events ORDER BY client,event_id",
        "SELECT json_array(revision,client,event_id,captured_at,payload) FROM client_usage_revisions ORDER BY revision",
        "SELECT json_array(client,source_key,offset,size,modified,identity) FROM client_file_checkpoints ORDER BY client,source_key",
    ]
    .into_iter()
    .map(|sql| {
        connection
            .prepare(sql)
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    })
    .collect()
}

fn assert_checkpoint(connection: &Connection, client: &str, path: &Path, offset: usize, size: usize) {
    let checkpoint = read_checkpoint(connection, client, &path.to_string_lossy())
        .unwrap()
        .unwrap();
    assert_eq!(checkpoint.offset, offset as u64);
    assert_eq!(checkpoint.size, size as u64);
    assert_eq!(
        checkpoint.modified,
        modified_ns(&fs::metadata(path).unwrap()) as f64 / 1_000_000_000.0
    );
    let mut prefix = Vec::new();
    fs::File::open(path)
        .unwrap()
        .take(offset.min(4096) as u64)
        .read_to_end(&mut prefix)
        .unwrap();
    assert_eq!(
        checkpoint.fingerprint,
        Some(format!(
            "claude-cache-lifetimes-v1|{}:{}",
            prefix.len(),
            hex_digest(&prefix)
        ))
    );
}

fn assert_idempotent_and_replay(connection: &mut Connection, client: &str, path: &Path) {
    let before = ledger_state(connection);
    scan_transcript_file(connection, client, path).unwrap();
    assert_eq!(ledger_state(connection), before, "idempotent rescan");
    connection
        .execute(
            "DELETE FROM client_file_checkpoints WHERE client=?1 AND source_key=?2",
            params![client, path.to_string_lossy().as_ref()],
        )
        .unwrap();
    let size = fs::metadata(path).unwrap().len();
    for _ in 0..4 {
        scan_transcript_file(connection, client, path).unwrap();
        if read_checkpoint(connection, client, &path.to_string_lossy())
            .unwrap()
            .is_some_and(|checkpoint| checkpoint.offset == size)
        {
            assert_eq!(ledger_state(connection), before, "checkpoint replay");
            return;
        }
    }
    panic!("bounded replay did not reach the complete transcript");
}

#[test]
fn claude_jsonl_record_size_matrix_preserves_usage_and_exact_checkpoints() {
    for client in ["claudeCode", "claudeDesktop"] {
        for structured in [false, true] {
            for record_bytes in [
                64 * 1024,
                1024 * 1024,
                FOUR_MIB,
                FOUR_MIB + 1,
                SIXTEEN_MIB,
            ] {
                let directory = tempfile::tempdir().unwrap();
                let database = directory.path().join("usage.sqlite");
                let transcript = directory.path().join("anonymous.jsonl");
                let mut connection = open_fixture_ledger(&database);
                // Preserve the existing file classifier: Desktop needs a complete short header.
                let header = if client == "claudeDesktop" {
                    classification_header(client)
                } else {
                    Vec::new()
                };
                fs::write(&transcript, &header).unwrap();
                if !header.is_empty() {
                    scan_transcript_file(&mut connection, client, &transcript).unwrap();
                }
                let record = claude_record(record_bytes, client, structured, "large-message", true);
                let successor = claude_record(2048, client, !structured, "successor-message", true);
                append_bytes(&transcript, &record);
                append_bytes(&transcript, &successor);
                let large = small_oracle(&transcript, client, structured, "large-message");
                let successor_event =
                    small_oracle(&transcript, client, !structured, "successor-message");
                let size = header.len() + record.len() + successor.len();

                scan_transcript_file(&mut connection, client, &transcript).unwrap();
                if record_bytes < FOUR_MIB {
                    assert_events(&connection, &[large.clone(), successor_event.clone()]);
                    assert_checkpoint(&connection, client, &transcript, size, size);
                } else {
                    assert_events(&connection, &[large.clone()]);
                    assert_checkpoint(
                        &connection,
                        client,
                        &transcript,
                        header.len() + record.len(),
                        size,
                    );
                    scan_transcript_file(&mut connection, client, &transcript).unwrap();
                }
                assert_events(&connection, &[large, successor_event]);
                assert_checkpoint(&connection, client, &transcript, size, size);
                assert_idempotent_and_replay(&mut connection, client, &transcript);
            }
        }
    }
}

#[test]
fn claude_jsonl_incomplete_append_waits_through_reopen_until_line_feed() {
    for client in ["claudeCode", "claudeDesktop"] {
        for structured in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let database = directory.path().join("usage.sqlite");
            let transcript = directory.path().join("anonymous.jsonl");
            let mut connection = open_fixture_ledger(&database);
            let header = if client == "claudeDesktop" {
                classification_header(client)
            } else {
                Vec::new()
            };
            fs::write(&transcript, &header).unwrap();
            if !header.is_empty() {
                scan_transcript_file(&mut connection, client, &transcript).unwrap();
            }
            let before = ledger_state(&connection);
            let record =
                claude_record(FOUR_MIB + 4096, client, structured, "appended-message", true);
            let first_append = FOUR_MIB + 17;
            append_bytes(&transcript, &record[..first_append]);
            for _ in 0..2 {
                scan_transcript_file(&mut connection, client, &transcript).unwrap();
                assert_eq!(ledger_state(&connection), before, "partial JSON must wait");
                drop(connection);
                connection = Connection::open(&database).unwrap();
            }
            append_bytes(&transcript, &record[first_append..record.len() - 1]);
            for _ in 0..2 {
                scan_transcript_file(&mut connection, client, &transcript).unwrap();
                assert_eq!(
                    ledger_state(&connection),
                    before,
                    "complete JSON without LF must wait"
                );
                drop(connection);
                connection = Connection::open(&database).unwrap();
            }
            let successor = claude_record(2048, client, false, "after-append-message", true);
            append_bytes(&transcript, b"\n");
            append_bytes(&transcript, &successor);
            let size = header.len() + record.len() + successor.len();
            let large = small_oracle(&transcript, client, structured, "appended-message");
            scan_transcript_file(&mut connection, client, &transcript).unwrap();
            assert_events(&connection, &[large.clone()]);
            assert_checkpoint(
                &connection,
                client,
                &transcript,
                header.len() + record.len(),
                size,
            );
            scan_transcript_file(&mut connection, client, &transcript).unwrap();
            assert_events(
                &connection,
                &[
                    large,
                    small_oracle(&transcript, client, false, "after-append-message"),
                ],
            );
            assert_checkpoint(&connection, client, &transcript, size, size);
            assert_idempotent_and_replay(&mut connection, client, &transcript);
        }
    }
}

#[test]
fn claude_jsonl_sixteen_mib_limit_preserves_absent_and_committed_ledgers() {
    for client in ["claudeCode", "claudeDesktop"] {
        for committed in [false, true] {
            for terminated in [false, true] {
                let directory = tempfile::tempdir().unwrap();
                let database = directory.path().join("usage.sqlite");
                let transcript = directory.path().join("anonymous.jsonl");
                let mut connection = open_fixture_ledger(&database);
                fs::write(&transcript, []).unwrap();
                if committed {
                    append_bytes(&transcript, &classification_header(client));
                    append_bytes(
                        &transcript,
                        &claude_record(2048, client, false, "committed-message", true),
                    );
                    scan_transcript_file(&mut connection, client, &transcript).unwrap();
                    assert_events(
                        &connection,
                        &[small_oracle(&transcript, client, false, "committed-message")],
                    );
                } else {
                    assert!(read_checkpoint(&connection, client, &transcript.to_string_lossy())
                        .unwrap()
                        .is_none());
                }
                let before = ledger_state(&connection);
                // LF is byte 16 MiB + 1, or is absent with exactly 16 MiB held.
                let record =
                    claude_record(SIXTEEN_MIB + 1, client, true, "oversized-message", true);
                append_bytes(
                    &transcript,
                    if terminated {
                        &record
                    } else {
                        &record[..record.len() - 1]
                    },
                );
                for _ in 0..2 {
                    assert!(scan_transcript_file(&mut connection, client, &transcript).is_err());
                    assert_eq!(
                        ledger_state(&connection),
                        before,
                        "failed scan must preserve the complete ledger"
                    );
                    drop(connection);
                    connection = Connection::open(&database).unwrap();
                }
            }
        }
    }
}

#[test]
fn claude_jsonl_usage_free_large_record_advances_without_fabricating_usage() {
    for client in ["claudeCode", "claudeDesktop"] {
        for structured in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let database = directory.path().join("usage.sqlite");
            let transcript = directory.path().join("anonymous.jsonl");
            let mut connection = open_fixture_ledger(&database);
            let header = if client == "claudeDesktop" {
                classification_header(client)
            } else {
                Vec::new()
            };
            fs::write(&transcript, &header).unwrap();
            if !header.is_empty() {
                scan_transcript_file(&mut connection, client, &transcript).unwrap();
            }
            assert!(parse_claude(
                &claude_record(2048, client, structured, "usage-free-message", false),
                &transcript,
                client,
            )
            .is_empty());
            let record =
                claude_record(FOUR_MIB + 1, client, structured, "usage-free-message", false);
            let successor = claude_record(2048, client, false, "after-usage-free-message", true);
            append_bytes(&transcript, &record);
            append_bytes(&transcript, &successor);
            let size = header.len() + record.len() + successor.len();
            scan_transcript_file(&mut connection, client, &transcript).unwrap();
            assert_events(&connection, &[]);
            assert!(
                ledger_state(&connection)[1].is_empty(),
                "no fabricated revision"
            );
            assert_checkpoint(
                &connection,
                client,
                &transcript,
                header.len() + record.len(),
                size,
            );
            scan_transcript_file(&mut connection, client, &transcript).unwrap();
            assert_events(
                &connection,
                &[small_oracle(
                    &transcript,
                    client,
                    false,
                    "after-usage-free-message",
                )],
            );
            assert_checkpoint(&connection, client, &transcript, size, size);
            assert_idempotent_and_replay(&mut connection, client, &transcript);
        }
    }
}

#[test]
fn claude_jsonl_keeps_normal_batch_boundary_when_prefix_has_line_feed() {
    for client in ["claudeCode", "claudeDesktop"] {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("usage.sqlite");
        let transcript = directory.path().join("anonymous.jsonl");
        let mut connection = open_fixture_ledger(&database);
        let first = claude_record(2048, client, false, "first-message", true);
        let large = claude_record(FOUR_MIB + 1, client, true, "large-message", true);
        let last = claude_record(2048, client, false, "last-message", true);
        fs::write(&transcript, &first).unwrap();
        append_bytes(&transcript, &large);
        append_bytes(&transcript, &last);
        let size = first.len() + large.len() + last.len();
        let mut expected = vec![small_oracle(&transcript, client, false, "first-message")];
        scan_transcript_file(&mut connection, client, &transcript).unwrap();
        assert_events(&connection, &expected);
        assert_checkpoint(&connection, client, &transcript, first.len(), size);
        expected.push(small_oracle(&transcript, client, true, "large-message"));
        scan_transcript_file(&mut connection, client, &transcript).unwrap();
        assert_events(&connection, &expected);
        assert_checkpoint(
            &connection,
            client,
            &transcript,
            first.len() + large.len(),
            size,
        );
        expected.push(small_oracle(&transcript, client, false, "last-message"));
        scan_transcript_file(&mut connection, client, &transcript).unwrap();
        assert_events(&connection, &expected);
        assert_checkpoint(&connection, client, &transcript, size, size);
        assert_idempotent_and_replay(&mut connection, client, &transcript);
    }
}

#[test]
fn non_claude_jsonl_keeps_its_four_mib_record_rejection() {
    for client in ["gemini", "deepseek"] {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("usage.sqlite");
        let transcript = directory.path().join("anonymous.jsonl");
        let mut connection = open_fixture_ledger(&database);
        let record =
            claude_record(FOUR_MIB + 1, "claudeCode", false, "ignored-message", false);
        fs::write(&transcript, &record).unwrap();
        let before = ledger_state(&connection);
        assert!(scan_transcript_file(&mut connection, client, &transcript).is_err());
        assert_eq!(ledger_state(&connection), before);
        assert!(read_checkpoint(&connection, client, &transcript.to_string_lossy())
            .unwrap()
            .is_none());
    }
}
