//! Public RadarBench reader. The captured binding describes selections, never transport URLs.
use flate2::read::GzDecoder;
use reqwest::header::CONTENT_ENCODING;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::Read;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const BINDING_ENDPOINT: &str = "https://codexradar.com/data/radar-bench-binding.json";
const SCORE_ENDPOINT: &str = "https://codexradar.com/api/radar-bench-score";
const SCHEMA: &str = "radar-bench-public-summary-v5-150-daily-graded-count";
const SCHEMA_V6: &str = "radar-bench-public-summary-v6-150-details";
fn supported_schema(value: &str) -> bool { value == SCHEMA || value == SCHEMA_V6 }
const SCORE_VERSION: &str = "radar-bench-v2-150";
const POLICY: &str = "radar-bench-v2-last3-per-task-equal-weight-150";
const MAX_BYTES: u64 = 2 * 1024 * 1024;
const MAX_SELECTIONS: usize = 128;
const PARALLELISM: usize = 6;
const OPERATION_TIMEOUT: Duration = Duration::from_secs(20);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct Selection {
    model: String,
    effort: String,
}

struct Binding {
    raw: Value,
    selections: Vec<Selection>,
}

fn string<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value.get(key).and_then(Value::as_str)
        .ok_or_else(|| format!("invalid {key}"))
}

fn safe_identifier(value: &str, max_length: usize) -> bool {
    !value.is_empty() && value.len() <= max_length
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn selection(value: &Value) -> Result<Selection, String> {
    let model = string(value, "model")?;
    let effort = string(value, "effort")?;
    if !safe_identifier(model, 128) || !safe_identifier(effort, 128) {
        return Err("unsafe model/effort selection".into());
    }
    Ok(Selection { model: model.into(), effort: effort.into() })
}

fn validate_binding(raw: Value) -> Result<Binding, String> {
    for key in ["enabled", "interface_confirmed", "production_read_verified"] {
        if raw.get(key).and_then(Value::as_bool) != Some(true) {
            return Err(format!("binding {key} is not confirmed"));
        }
    }
    if string(&raw, "score_version")? != SCORE_VERSION
        || raw.get("score_max").and_then(Value::as_f64) != Some(150.0)
    {
        return Err("unsupported binding score contract".into());
    }
    let tasks = raw.get("total_tasks").and_then(Value::as_u64).ok_or("invalid total_tasks")?;
    if !(1..=4096).contains(&tasks) {
        return Err("binding task count is outside budget".into());
    }
    let source_counts = raw.get("source_counts").and_then(Value::as_object)
        .ok_or("invalid binding source_counts")?;
    if source_counts.is_empty() {
        return Err("empty binding source_counts".into());
    }
    let mut total_sources = 0u64;
    for count in source_counts.values() {
        let count = count.as_u64().filter(|count| *count <= tasks).ok_or("invalid source task count")?;
        total_sources = total_sources.checked_add(count).ok_or("source count overflow")?;
    }
    if total_sources != tasks {
        return Err("binding source_counts disagree with total_tasks".into());
    }
    if !safe_identifier(string(&raw, "benchmark")?, 160)
        || !safe_identifier(string(&raw, "catalog_version")?, 256)
    {
        return Err("invalid binding benchmark/catalog".into());
    }
    let hash = string(&raw, "task_set_sha256")?;
    if hash.len() != 64 || !hash.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) {
        return Err("invalid binding task_set_sha256".into());
    }
    // These fields are absent in the historical binding; if supplied, they must agree.
    if let Some(schema) = raw.get("schema") {
        if !schema.as_str().is_some_and(supported_schema) {
            return Err("unsupported binding schema".into());
        }
    }
    for (key, expected) in [("scoring_policy_version", POLICY)] {
        if raw.get(key).is_some() && raw.get(key).and_then(Value::as_str) != Some(expected) {
            return Err(format!("unsupported binding {key}"));
        }
    }
    let rows = raw.get("model_efforts").and_then(Value::as_array)
        .ok_or("invalid binding model_efforts")?;
    if rows.is_empty() || rows.len() > MAX_SELECTIONS {
        return Err("binding selection count is outside budget".into());
    }
    let mut seen = HashSet::new();
    let mut selections = Vec::new();
    for row in rows {
        let item = selection(row)?;
        if !seen.insert(item.clone()) {
            return Err("duplicate binding model/effort selection".into());
        }
        selections.push(item);
    }
    let active = selection(raw.get("active_display_selection").ok_or("missing active selection")?)?;
    if !seen.contains(&active) {
        return Err("active selection is outside binding catalog".into());
    }
    Ok(Binding { raw, selections })
}

fn validate_summary(raw: &Value, binding: &Binding, selected: &Selection) -> Result<(), String> {
    if !supported_schema(string(raw, "schema")?) || string(raw, "score_version")? != SCORE_VERSION
        || string(raw, "scoring_policy_version")? != POLICY
        || raw.get("score_max").and_then(Value::as_f64) != Some(150.0)
    {
        return Err("unsupported summary score contract".into());
    }
    if selection(raw)? != *selected {
        return Err("summary model/effort does not match request".into());
    }
    for key in ["benchmark", "catalog_version", "task_set_sha256"] {
        if raw.get(key) != binding.raw.get(key) {
            return Err(format!("summary {key} does not match binding"));
        }
    }
    if raw.get("source_counts") != binding.raw.get("source_counts") {
        return Err("summary source_counts do not match binding".into());
    }
    let required = raw.get("required_tasks").and_then(Value::as_u64).ok_or("invalid required_tasks")?;
    let coverage = raw.get("coverage").and_then(Value::as_u64).ok_or("invalid coverage")?;
    let graded = raw.get("graded_runs_count").and_then(Value::as_u64).ok_or("invalid graded_runs_count")?;
    if Some(required) != binding.raw.get("total_tasks").and_then(Value::as_u64)
        || coverage > required || graded < coverage
    {
        return Err("invalid summary coverage/graded counts".into());
    }
    let score = raw.get("score").ok_or("missing score field")?;
    let expected_status = if coverage == 0 { "missing_current_result" }
        else if coverage == required { "complete" } else { "provisional" };
    if string(raw, "score_status")? != expected_status {
        return Err("summary score_status disagrees with coverage".into());
    }
    if coverage == 0 {
        if !score.is_null() { return Err("uncovered summary must have null score".into()); }
    } else if !score.as_f64().is_some_and(|score| score.is_finite() && (0.0..=150.0).contains(&score)) {
        return Err("summary score is outside 0..150".into());
    }
    Ok(())
}

fn remaining_timeout(deadline: Instant) -> Result<Duration, String> {
    deadline.checked_duration_since(Instant::now()).filter(|duration| !duration.is_zero())
        .map(|duration| duration.min(REQUEST_TIMEOUT))
        .ok_or_else(|| "RadarBench operation deadline exceeded".into())
}

fn score_url(selected: &Selection) -> String {
    let mut url = reqwest::Url::parse(SCORE_ENDPOINT).expect("fixed RadarBench URL");
    url.query_pairs_mut().append_pair("model", &selected.model)
        .append_pair("effort", &selected.effort).append_pair("view", "summary")
        .append_pair("selection", "user-selected-v1");
    url.to_string()
}

/// The injectable transport must honor the supplied request timeout, including response body reads.
fn fetch_with<F>(fetch: F, budget: Duration) -> Result<Value, String>
where F: Fn(&str, Duration) -> Result<Value, String> + Sync {
    let deadline = Instant::now() + budget;
    let binding = validate_binding(fetch(BINDING_ENDPOINT, remaining_timeout(deadline)?)?)?;
    remaining_timeout(deadline)?;
    let next = AtomicUsize::new(0);
    let results = Mutex::new(Vec::new());
    std::thread::scope(|scope| {
        for _ in 0..PARALLELISM.min(binding.selections.len()) {
            let fetch = &fetch;
            let binding = &binding;
            let next = &next;
            let results = &results;
            scope.spawn(move || loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(selected) = binding.selections.get(index) else { break; };
                let result = remaining_timeout(deadline).and_then(|timeout| {
                    let value = fetch(&score_url(selected), timeout)?;
                    remaining_timeout(deadline)?;
                    validate_summary(&value, binding, selected)?;
                    Ok(value)
                });
                results.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push((index, result));
            });
        }
    });
    let mut results = results.into_inner().unwrap_or_else(|poisoned| poisoned.into_inner());
    results.sort_by_key(|(index, _)| *index);
    let mut summaries = Vec::new();
    let mut errors = Vec::new();
    for (index, result) in results {
        match result {
            Ok(value) => summaries.push(value),
            Err(message) => {
                let selected = &binding.selections[index];
                errors.push(format!("{}/{}: {message}", selected.model, selected.effort));
            }
        }
    }
    if summaries.is_empty() {
        return Err(format!("RadarBench summaries failed: {}", errors.join("; ")));
    }
    let observed_at = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|error| format!("RadarBench timestamp failed: {error}"))?;
    Ok(json!({ "benchmarkSource": "radar-bench", "benchBinding": binding.raw,
        "benchSummaries": summaries, "benchErrors": errors, "observedAt": observed_at }))
}

fn read_bounded<R: Read>(reader: R, max_bytes: u64) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    reader.take(max_bytes + 1).read_to_end(&mut bytes)
        .map_err(|error| format!("body failed: {error}"))?;
    if bytes.len() as u64 > max_bytes { return Err("payload is too large".into()); }
    Ok(bytes)
}

fn read_body<R: Read>(reader: R, encoding: &str, max_bytes: u64) -> Result<Vec<u8>, String> {
    // Bound the wire body first so gzip cannot hide an excessive encoded stream.
    let bytes = read_bounded(reader, max_bytes)?;
    if encoding.eq_ignore_ascii_case("gzip") {
        read_bounded(GzDecoder::new(bytes.as_slice()), max_bytes)
    } else if encoding.is_empty() || encoding.eq_ignore_ascii_case("identity") {
        Ok(bytes)
    } else {
        Err(format!("unsupported content encoding: {encoding}"))
    }
}

fn fetch_json(client: &reqwest::blocking::Client, endpoint: &str, timeout: Duration) -> Result<Value, String> {
    let response = client.get(endpoint).timeout(timeout).headers(super::public_json_headers())
        .send().map_err(|error| format!("fetch failed: {error}"))?;
    if !response.status().is_success() { return Err(format!("HTTP {}", response.status())); }
    if response.content_length().is_some_and(|length| length > MAX_BYTES) {
        return Err("payload is too large".into());
    }
    let encoding = response.headers().get(CONTENT_ENCODING).map(|header| header.to_str())
        .transpose().map_err(|_| "invalid content encoding")?.unwrap_or("").trim().to_owned();
    let bytes = read_body(response, &encoding, MAX_BYTES)?;
    serde_json::from_slice(&bytes).map_err(|error| format!("parse failed: {error}"))
}

pub(super) fn fetch_payload() -> Result<Value, String> {
    let client = reqwest::blocking::Client::builder().timeout(REQUEST_TIMEOUT).no_gzip()
        // Refuse all redirects; neither binding metadata nor a server redirect can change host.
        .redirect(reqwest::redirect::Policy::none()).build()
        .map_err(|error| format!("RadarBench client failed: {error}"))?;
    fetch_with(|endpoint, timeout| fetch_json(&client, endpoint, timeout), OPERATION_TIMEOUT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    const BINDING: &str = include_str!("../../../../Tests/Fixtures/RadarBench/binding-v5.json");
    const SUMMARY: &str = include_str!("../../../../Tests/Fixtures/RadarBench/summary-v5.json");

    fn binding() -> Value { serde_json::from_str(BINDING).unwrap() }
    fn summary(selected: &Selection) -> Value {
        let mut value: Value = serde_json::from_str(SUMMARY).unwrap();
        value["model"] = json!(selected.model);
        value["effort"] = json!(selected.effort);
        value
    }
    fn selected(endpoint: &str) -> Selection {
        let url = reqwest::Url::parse(endpoint).unwrap();
        let params = url.query_pairs().collect::<std::collections::HashMap<_, _>>();
        assert_eq!(params.get("view").map(|value| value.as_ref()), Some("summary"));
        assert_eq!(params.get("selection").map(|value| value.as_ref()), Some("user-selected-v1"));
        Selection { model: params["model"].to_string(), effort: params["effort"].to_string() }
    }

    #[test]
    fn captured_binding_supports_dynamic_ultra_and_ignores_transport_metadata() {
        let mut raw = binding();
        assert_eq!(raw["model_efforts"].as_array().unwrap().len(), 34);
        raw["transport_origin"] = json!("http://127.0.0.1:1234");
        raw["endpoint_path"] = json!("/private");
        raw["model_efforts"].as_array_mut().unwrap().push(json!({ "model": "future-family-1", "effort": "ultra" }));
        let validated = validate_binding(raw).unwrap();
        assert_eq!(validated.selections.len(), 35);
        assert!(validated.selections.iter().any(|row| row.effort == "ultra"));
        assert!(score_url(&validated.selections[0]).starts_with(SCORE_ENDPOINT));
        assert!(!super::super::public_json_headers().contains_key(reqwest::header::AUTHORIZATION));
    }

    #[test]
    fn binding_rejects_unconfirmed_unsafe_and_overbudget_catalog_before_fanout() {
        for key in ["enabled", "interface_confirmed", "production_read_verified"] {
            let calls = AtomicUsize::new(0);
            let mut raw = binding(); raw[key] = json!(false);
            assert!(fetch_with(|_, _| { calls.fetch_add(1, Ordering::Relaxed); Ok(raw.clone()) }, OPERATION_TIMEOUT).is_err());
            assert_eq!(calls.load(Ordering::Relaxed), 1);
        }
        let mut raw = binding(); raw["model_efforts"][0]["effort"] = json!("high&token=private");
        assert!(validate_binding(raw).is_err());
        let mut raw = binding(); raw["model_efforts"] = json!(vec![raw["model_efforts"][0].clone(); MAX_SELECTIONS + 1]);
        assert!(validate_binding(raw).is_err());
        let mut raw = binding(); raw["score_max"] = json!(100);
        assert!(validate_binding(raw).is_err());
        let mut raw = binding();
        let duplicate = raw["model_efforts"][0].clone();
        raw["model_efforts"].as_array_mut().unwrap().push(duplicate);
        assert!(validate_binding(raw).is_err());
        let mut raw = binding(); raw["source_counts"]["deepswe"] = json!(14);
        assert!(validate_binding(raw).is_err());
        let mut raw = binding(); raw["total_tasks"] = json!(4097);
        assert!(validate_binding(raw).is_err());
        let mut raw = binding();
        raw["task_set_sha256"] = json!(raw["task_set_sha256"].as_str().unwrap().to_ascii_uppercase());
        assert!(validate_binding(raw).is_err());
        let mut raw = binding(); raw["source_counts"]["deepswe"] = json!(u64::MAX);
        assert!(validate_binding(raw).is_err());
        let mut raw = binding(); raw["model_efforts"][0]["model"] = json!("-leading-punctuation");
        assert!(validate_binding(raw).is_err());
    }

    #[test]
    fn summary_validates_identity_contract_and_independent_counts() {
        let binding = validate_binding(binding()).unwrap();
        let selected = &binding.selections[0];
        let mut value = summary(selected);
        value["graded_runs_count"] = json!(189);
        value["score"] = json!(0);
        validate_summary(&value, &binding, selected).unwrap();
        for key in ["schema", "score_version", "scoring_policy_version", "benchmark", "catalog_version", "task_set_sha256", "model", "effort"] {
            let mut invalid = value.clone(); invalid[key] = json!("wrong");
            assert!(validate_summary(&invalid, &binding, selected).is_err(), "{key}");
        }
        for (key, invalid) in [("score", json!(151)), ("score", Value::Null), ("coverage", json!(65)), ("graded_runs_count", json!(0)), ("required_tasks", json!(63))] {
            let mut invalid_value = value.clone(); invalid_value[key] = invalid;
            assert!(validate_summary(&invalid_value, &binding, selected).is_err(), "{key}");
        }
        let mut invalid_sources = value.clone(); invalid_sources["source_counts"]["deepswe"] = json!(14);
        assert!(validate_summary(&invalid_sources, &binding, selected).is_err());
        value["coverage"] = json!(0); value["score"] = Value::Null;
        value["graded_runs_count"] = json!(0); value["score_status"] = json!("missing_current_result");
        validate_summary(&value, &binding, selected).unwrap();
    }

    #[test]
    fn captured_v6_details_preserve_score_contract_and_reject_future_policy() {
        let mut raw = binding();
        raw["schema"] = json!(SCHEMA_V6);
        let binding = validate_binding(raw).unwrap();
        let mut value: Value = serde_json::from_str(include_str!("../../../../Tests/Fixtures/RadarBench/summary-v6.json")).unwrap();
        let selected = selection(&value).unwrap();
        validate_summary(&value, &binding, &selected).unwrap();
        assert_eq!(value["graded_runs_count"], json!(116));
        value["scoring_policy_version"] = json!("future-policy");
        assert!(validate_summary(&value, &binding, &selected).is_err());
    }

    #[test]
    fn partial_failure_succeeds_and_all_failure_returns_error() {
        let result = fetch_with(|endpoint, timeout| {
            assert!(timeout <= REQUEST_TIMEOUT);
            if endpoint == BINDING_ENDPOINT { return Ok(binding()); }
            let selected = selected(endpoint);
            if selected.effort == "ultra" { Err("unavailable".into()) } else { Ok(summary(&selected)) }
        }, OPERATION_TIMEOUT).unwrap();
        assert_eq!(result["benchmarkSource"], "radar-bench");
        assert_eq!(result["benchSummaries"].as_array().unwrap().len(), 30);
        assert_eq!(result["benchErrors"].as_array().unwrap().len(), 4);
        assert!(time::OffsetDateTime::parse(result["observedAt"].as_str().unwrap(), &time::format_description::well_known::Rfc3339).is_ok());
        assert!(fetch_with(|endpoint, _| if endpoint == BINDING_ENDPOINT { Ok(binding()) } else { Err("unavailable".into()) }, OPERATION_TIMEOUT).is_err());
    }

    #[test]
    fn all_null_summaries_are_successful() {
        let result = fetch_with(|endpoint, _| {
            if endpoint == BINDING_ENDPOINT { return Ok(binding()); }
            let mut value = summary(&selected(endpoint));
            value["score"] = Value::Null; value["coverage"] = json!(0);
            value["graded_runs_count"] = json!(0); value["score_status"] = json!("missing_current_result");
            Ok(value)
        }, OPERATION_TIMEOUT).unwrap();
        assert_eq!(result["benchSummaries"].as_array().unwrap().len(), 34);
        assert!(result["benchErrors"].as_array().unwrap().is_empty());
    }

    #[test]
    fn wire_and_decompressed_body_limits_fail_explicitly() {
        assert_eq!(read_body(&b"1234"[..], "", 4).unwrap(), b"1234");
        assert!(read_body(&b"12345"[..], "", 4).unwrap_err().contains("too large"));
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        encoder.write_all(&vec![b'a'; 4096]).unwrap();
        let gzip = encoder.finish().unwrap();
        assert!(read_body(gzip.as_slice(), "gzip", 1024).unwrap_err().contains("too large"));
        assert!(read_body(gzip.as_slice(), "gzip", 4).unwrap_err().contains("too large"));
        assert!(read_body(&b"{}"[..], "br", 1024).is_err());
        assert!(read_body(&b"bad gzip"[..], "gzip", 1024).is_err());
    }

    #[test]
    fn concurrency_and_operation_budget_bound_requests() {
        let active = AtomicUsize::new(0);
        let peak = AtomicUsize::new(0);
        let calls = AtomicUsize::new(0);
        let budget = Duration::from_millis(80);
        let started = Instant::now();
        let result = fetch_with(|endpoint, timeout| {
            assert!(timeout <= budget && timeout <= REQUEST_TIMEOUT);
            if endpoint == BINDING_ENDPOINT { return Ok(binding()); }
            let count = active.fetch_add(1, Ordering::SeqCst) + 1;
            peak.fetch_max(count, Ordering::SeqCst);
            calls.fetch_add(1, Ordering::Relaxed);
            std::thread::sleep(timeout);
            active.fetch_sub(1, Ordering::SeqCst);
            Err("timed out".into())
        }, budget);
        assert!(result.is_err());
        assert!(peak.load(Ordering::SeqCst) <= PARALLELISM);
        assert!(calls.load(Ordering::Relaxed) <= PARALLELISM);
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
