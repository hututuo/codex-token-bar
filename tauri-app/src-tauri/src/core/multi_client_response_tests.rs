use super::*;

const BOUNDARY: i64 = 1_800_000_000;

fn fixtures() -> Value {
    serde_json::from_str(include_str!(
        "../../../../Tests/SharedFixtures/claude-response-deduplication.json"
    ))
    .unwrap()
}

fn event(row: &Value) -> UsageEvent {
    let session = row[1].as_str().unwrap();
    let kind = row[2].as_str().unwrap();
    let identity = if kind == "malformed" {
        format!("id:{}", "z".repeat(64))
    } else {
        format!("{kind}:{}", hex_digest(row[3].as_str().unwrap().as_bytes()))
    };
    UsageEvent {
        client: row[0].as_str().unwrap().into(),
        session_id: session.into(),
        event_id: format!("v1:{}:{identity}", hex_digest(session.as_bytes())),
        model: row[4].as_str().unwrap().into(),
        timestamp_ms: row[5].as_i64().unwrap() * 1000,
        input_tokens: row[6].as_u64().unwrap(),
        output_tokens: row[7].as_u64().unwrap(),
        cache_read_tokens: row[8].as_u64(),
        cache_write_tokens: row[9].as_u64(),
        reasoning_tokens: row[10].as_u64(),
        cache_write_5m_tokens: row[11].as_u64(),
        cache_write_1h_tokens: row[12].as_u64(),
        quality: if kind == "fallback" {
            "fallback_identity"
        } else {
            "recorded"
        }
        .into(),
    }
}

fn physical_state(connection: &Connection) -> Vec<String> {
    let mut result = Vec::new();
    for query in [
        "SELECT json_array(client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,payload) FROM client_usage_events ORDER BY client,event_id",
        "SELECT json_array(revision,client,event_id,captured_at,payload) FROM client_usage_revisions ORDER BY revision",
        "SELECT json_array(client,source_key,offset,size,modified,identity) FROM client_file_checkpoints ORDER BY client,source_key",
        "SELECT COALESCE(sql,'') FROM sqlite_master ORDER BY name",
    ] {
        result.extend(connection.prepare(query).unwrap().query_map([], |row| row.get::<_, String>(0)).unwrap().map(Result::unwrap));
    }
    result.push(read_schema_version(connection).unwrap().to_string());
    result
}

#[test]
fn shared_response_fixtures_conserve_all_consumers_without_rewriting_history() {
    for fixture in fixtures()["cases"].as_array().unwrap() {
        let name = fixture["name"].as_str().unwrap();
        let expected = fixture["expected"].as_array().unwrap();
        for reversed in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("usage.sqlite");
            let mut writer = Connection::open(&path).unwrap();
            ensure_schema(&writer, &path).unwrap();
            let mut events: Vec<_> = fixture["observations"]
                .as_array()
                .unwrap()
                .iter()
                .map(event)
                .collect();
            if reversed {
                events.reverse();
            }
            persist_source_update(
                &mut writer,
                "claudeDesktop",
                "fixture",
                42,
                84,
                123,
                "unchanged",
                events.clone(),
            )
            .unwrap();
            let before = physical_state(&writer);
            let reader = open_read_only(&path).unwrap();
            let actual: Vec<Value> = reader.prepare(&effective_usage_query(
                "SELECT json_array(client,model,CAST(timestamp AS INTEGER),input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,cache_write_5m_tokens,cache_write_1h_tokens) FROM effective_client_usage_events ORDER BY client,model,timestamp,event_id"
            )).unwrap().query_map([], |row| row.get::<_, String>(0)).unwrap()
                .map(|row| serde_json::from_str(&row.unwrap()).unwrap()).collect();
            let expected_rows: Vec<Value> = expected
                .iter()
                .map(|row| Value::Array(row.as_array().unwrap()[..10].to_vec()))
                .collect();
            assert_eq!(actual, expected_rows, "{name}");

            let cache = Mutex::new(MultiClientAggregateCache::default());
            let result =
                read_cached_multi_client_aggregates(&reader, &path, BOUNDARY + 10, &cache).unwrap();
            let total_input: u64 = expected.iter().map(|row| row[3].as_u64().unwrap()).sum();
            let total_output: u64 = expected.iter().map(|row| row[4].as_u64().unwrap()).sum();
            let total_cost: i64 = expected.iter().filter_map(|row| row[10].as_i64()).sum();
            let summaries = &result.arrays.summaries;
            assert_eq!(
                summaries.iter().map(|r| r.requests).sum::<u64>(),
                expected.len() as u64,
                "{name}"
            );
            assert_eq!(
                summaries.iter().map(|r| r.input_tokens).sum::<u64>(),
                total_input,
                "{name}"
            );
            assert_eq!(
                summaries.iter().map(|r| r.output_tokens).sum::<u64>(),
                total_output,
                "{name}"
            );
            for summary in summaries {
                let rows: Vec<_> = expected
                    .iter()
                    .filter(|r| {
                        r[0].as_str() == Some(summary.client.as_str())
                            && r[1].as_str() == Some(summary.model.as_str())
                    })
                    .collect();
                let priced: Vec<_> = rows.iter().filter_map(|r| r[10].as_i64()).collect();
                assert_eq!(summary.requests, rows.len() as u64, "{name}");
                assert_eq!(
                    summary.unpriced_requests,
                    (rows.len() - priced.len()) as u64,
                    "{name}"
                );
                assert_eq!(
                    summary.cache_read_complete,
                    rows.iter().all(|r| !r[5].is_null()),
                    "{name}"
                );
                assert_eq!(
                    summary.api_cost_usd,
                    (!priced.is_empty()).then(|| priced.iter().sum::<i64>() as f64 / 1_000_000.0),
                    "{name}"
                );
            }
            for (start, end) in [(BOUNDARY - 10, BOUNDARY), (BOUNDARY, BOUNDARY + 10)] {
                let expected_count = expected
                    .iter()
                    .filter(|r| {
                        let t = r[2].as_i64().unwrap();
                        t >= start && t < end
                    })
                    .count();
                let prices = read_range_api_price_aggregates(&reader, start, Some(end)).unwrap();
                let rows = read_summary_rows_range_with_prices(
                    &reader,
                    Some(&prices),
                    Some(start),
                    Some(end),
                )
                .unwrap();
                assert_eq!(
                    rows.iter().map(|r| r.requests).sum::<u64>(),
                    expected_count as u64,
                    "{name}"
                );
            }
            let trend = &result.arrays.trend_buckets;
            assert_eq!(
                trend.iter().map(|r| r.requests).sum::<u64>(),
                expected.len() as u64,
                "{name}"
            );
            assert_eq!(
                trend.iter().map(|r| r.input_tokens).sum::<u64>(),
                total_input,
                "{name}"
            );
            assert_eq!(
                trend
                    .iter()
                    .filter_map(|r| r.api_cost_micro_usd)
                    .sum::<i64>(),
                total_cost,
                "{name}"
            );
            assert_eq!(
                trend.iter().map(|r| r.unpriced_requests).sum::<u64>(),
                summaries.iter().map(|r| r.unpriced_requests).sum::<u64>(),
                "{name}"
            );
            assert_eq!(
                result
                    .arrays
                    .daily_buckets
                    .iter()
                    .map(|r| r.requests)
                    .sum::<u64>(),
                expected.len() as u64,
                "{name}"
            );
            assert_eq!(
                result
                    .arrays
                    .daily_buckets
                    .iter()
                    .map(|r| r.input_tokens)
                    .sum::<u64>(),
                total_input,
                "{name}"
            );
            for client in ["claudeCode", "claudeDesktop", "antigravity"] {
                let expected_client: Vec<_> = expected
                    .iter()
                    .filter(|r| r[0].as_str() == Some(client))
                    .collect();
                let client_input: u64 =
                    expected_client.iter().map(|r| r[3].as_u64().unwrap()).sum();
                let rankings = read_multi_client_cache_rankings_at(&path, client, 500).unwrap();
                assert_eq!(
                    rankings.matching_request_count,
                    expected_client.len() as u64,
                    "{name}"
                );
                assert_eq!(
                    rankings
                        .requests
                        .iter()
                        .map(|r| r.input_tokens)
                        .sum::<u64>(),
                    client_input,
                    "{name}"
                );
                assert_eq!(
                    rankings.sessions.iter().map(|r| r.requests).sum::<u64>(),
                    expected_client.len() as u64,
                    "{name}"
                );
                assert_eq!(
                    rankings
                        .sessions
                        .iter()
                        .map(|r| r.input_tokens)
                        .sum::<u64>(),
                    client_input,
                    "{name}"
                );
                for request in rankings.requests {
                    assert!(
                        events.iter().any(|e| e.client == request.client
                            && e.event_id == request.event_id
                            && e.session_id == request.session_id),
                        "{name}"
                    );
                    assert!(
                        rankings
                            .sessions
                            .iter()
                            .any(|s| s.session_id == request.session_id
                                && s.model_ids.contains(&request.model)),
                        "{name}"
                    );
                }
            }
            assert_eq!(
                physical_state(&writer),
                before,
                "Read mutated historical records: {name}"
            );
        }
    }
}

#[test]
fn future_copied_response_invalidates_caches_without_adding_a_request() {
    let fixture = fixtures();
    let events: Vec<_> = fixture["cases"][0]["observations"]
        .as_array()
        .unwrap()
        .iter()
        .map(event)
        .collect();
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("usage.sqlite");
    let mut writer = Connection::open(&path).unwrap();
    ensure_schema(&writer, &path).unwrap();
    persist_source_update(
        &mut writer,
        "claudeDesktop",
        "fixture",
        42,
        84,
        123,
        "unchanged",
        events.clone(),
    )
    .unwrap();
    let cache = Mutex::new(MultiClientAggregateCache::default());
    let first = read_cached_multi_client_aggregates(&writer, &path, BOUNDARY + 10, &cache).unwrap();
    assert_eq!(first.arrays.summaries[0].api_cost_usd, Some(0.247));
    let old_payloads: Vec<String> = writer
        .prepare("SELECT payload FROM client_usage_events")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    let mut update = events[0].clone();
    update.session_id = "later-copy".into();
    update.event_id = format!(
        "v1:{}:id:{}",
        hex_digest(update.session_id.as_bytes()),
        hex_digest(b"message-1")
    );
    update.output_tokens = 1100;
    persist_source_update(
        &mut writer,
        "claudeDesktop",
        "fixture",
        84,
        84,
        123,
        "unchanged",
        vec![update.clone()],
    )
    .unwrap();
    let next = read_cached_multi_client_aggregates(&writer, &path, BOUNDARY + 10, &cache).unwrap();
    for rows in [
        &next.arrays.summaries,
        &next.arrays.today_summaries,
        &next.arrays.seven_day_summaries,
    ] {
        assert_eq!(rows[0].requests, 1);
        assert_eq!(rows[0].output_tokens, 1100);
        assert_eq!(rows[0].api_cost_usd, Some(0.249));
    }
    persist_source_update(
        &mut writer,
        "claudeDesktop",
        "fixture",
        84,
        84,
        123,
        "unchanged",
        vec![update],
    )
    .unwrap();
    let current_payloads: Vec<String> = writer
        .prepare("SELECT payload FROM client_usage_events")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert!(old_payloads.iter().all(|p| current_payloads.contains(p)));
    assert_eq!(current_payloads.len(), 3);
    assert_eq!(
        writer
            .query_row("SELECT COUNT(*) FROM client_usage_revisions", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        3
    );
}

#[test]
fn real_parser_copies_count_once_across_local_midnight() {
    let midnight =
        crate::core::localtime::local_day_bounds(crate::core::localtime::local_date_at(BOUNDARY))
            .unwrap()
            .0;
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("usage.sqlite");
    let mut writer = Connection::open(&path).unwrap();
    ensure_schema(&writer, &path).unwrap();
    for (session, at) in [("original", midnight - 1), ("fork", midnight + 1)] {
        let object = serde_json::json!({"type":"assistant","sessionId":session,"entrypoint":"claude-desktop",
            "timestamp": format_timestamp_seconds(at as f64).unwrap(), "message":{"id":"same-provider-message","model":"claude-opus-5-5",
                "usage":{"input_tokens":20000,"output_tokens":1000,"cache_read_input_tokens":10000,"cache_creation_input_tokens":20000}}});
        let events = parse_claude(
            &serde_json::to_vec(&object).unwrap(),
            Path::new("fixture.jsonl"),
            "claudeDesktop",
        );
        assert_eq!(events.len(), 1);
        persist_source_update(
            &mut writer,
            "claudeDesktop",
            session,
            42,
            42,
            123,
            "fixture",
            events,
        )
        .unwrap();
    }
    let clients = vec!["claudeDesktop".into()];
    assert!(
        read_day_summaries_on(&writer, midnight - 86400, midnight, &clients)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        read_day_summaries_on(&writer, midnight, midnight + 86400, &clients).unwrap()[0].requests,
        1
    );
    let days = read_daily_buckets(&writer, midnight + 10).unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(days[0].start_unix, midnight);
    assert_eq!(days[0].input_tokens, 50000);
}
