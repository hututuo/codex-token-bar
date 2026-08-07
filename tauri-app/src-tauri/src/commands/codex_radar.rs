use super::window_auth::require_window_label;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, USER_AGENT};
use serde_json::{json, Value};
use std::fmt;
use std::io::Read;
use std::thread;
use std::time::{Duration, Instant};
use tauri::async_runtime;

const CODEX_RADAR_FULL_ENDPOINT: &str = "https://codexradar.com/api/v1/current";
const CODEX_CROWD_RADAR_TABLE_ENDPOINT: &str =
    "https://codexradar.com/api/intelligence-efficiency";
const CODEX_CROWD_RADAR_TABLE_LEGACY_ENDPOINT: &str =
    "https://api.codexradar.com/api/v1/table";
const CODEX_CROWD_RADAR_LEADERBOARD_ENDPOINT: &str =
    "https://codexradar.com/data/intelligence-efficiency.json";
const CODEX_CROWD_RADAR_LEADERBOARD_LEGACY_ENDPOINT: &str =
    "https://api.codexradar.com/api/v1/leaderboard";
const CODEX_RADAR_TIMEOUT: Duration = Duration::from_secs(20);
const CODEX_CROWD_RADAR_TIMEOUT: Duration = Duration::from_secs(18);
const CODEX_CROWD_RADAR_PRIMARY_TIMEOUT: Duration = Duration::from_secs(12);
const CODEX_CROWD_RADAR_LEGACY_TIMEOUT: Duration = Duration::from_secs(6);
const CODEX_CROWD_RADAR_MAX_BYTES: u64 = 8 * 1024 * 1024;
const CODEX_CROWD_RADAR_MAX_ATTEMPTS: usize = 2;
const CODEX_CROWD_RADAR_RETRY_DELAY: Duration = Duration::from_millis(200);
const KEY_CIPHER: [u8; 57] = [
    94, 228, 121, 185, 168, 72, 126, 255, 5, 110, 24, 99, 74, 39, 157, 134, 100, 135, 125, 94,
    135, 210, 1, 144, 13, 46, 200, 43, 156, 101, 161, 236, 160, 80, 7, 176, 218, 251, 217,
    188, 109, 99, 36, 171, 48, 39, 199, 14, 215, 225, 47, 222, 173, 72, 143, 235, 177,
];
const KEY_MASK: [u8; 23] = [
    83, 33, 141, 11, 68, 159, 226, 23, 106, 195, 61, 136, 241, 44, 5, 185, 112, 222, 73,
    17, 166, 92, 47,
];

#[tauri::command]
pub async fn read_codex_radar_full_snapshot(
    window: tauri::WebviewWindow,
) -> Result<Value, String> {
    require_window_label(&window, "read_codex_radar_full_snapshot")?;
    async_runtime::spawn_blocking(fetch_codex_radar_full_snapshot)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn read_codex_crowd_radar_payload(
    window: tauri::WebviewWindow,
) -> Result<Value, String> {
    require_window_label(&window, "read_codex_crowd_radar_payload")?;
    async_runtime::spawn_blocking(fetch_codex_crowd_radar_payload)
        .await
        .map_err(|error| error.to_string())?
}

fn fetch_codex_radar_full_snapshot() -> Result<Value, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(CODEX_RADAR_TIMEOUT)
        .no_gzip()
        .build()
        .map_err(|error| format!("Codex Radar detail client failed: {error}"))?;

    let response = client
        .get(CODEX_RADAR_FULL_ENDPOINT)
        .headers(full_detail_headers()?)
        .send()
        .map_err(|error| format!("Codex Radar detail fetch failed: {error}"))?;

    if !response.status().is_success() {
        return Err(format!("Codex Radar detail HTTP {}", response.status()));
    }

    response
        .json::<Value>()
        .map_err(|error| format!("Codex Radar detail parse failed: {error}"))
}

fn fetch_codex_crowd_radar_payload() -> Result<Value, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(CODEX_CROWD_RADAR_TIMEOUT)
        .no_gzip()
        .build()
        .map_err(|error| format!("Crowd Radar client failed: {error}"))?;
    let table_sources = [
        (
            "site",
            CODEX_CROWD_RADAR_TABLE_ENDPOINT,
            CODEX_CROWD_RADAR_PRIMARY_TIMEOUT,
        ),
        (
            "legacy-api",
            CODEX_CROWD_RADAR_TABLE_LEGACY_ENDPOINT,
            CODEX_CROWD_RADAR_LEGACY_TIMEOUT,
        ),
    ];
    let leaderboard_sources = [
        (
            "published",
            CODEX_CROWD_RADAR_LEADERBOARD_ENDPOINT,
            CODEX_CROWD_RADAR_PRIMARY_TIMEOUT,
        ),
        (
            "legacy-api",
            CODEX_CROWD_RADAR_LEADERBOARD_LEGACY_ENDPOINT,
            CODEX_CROWD_RADAR_LEGACY_TIMEOUT,
        ),
    ];
    let (table, leaderboard) = std::thread::scope(|scope| {
        let table_request = scope.spawn(|| {
            fetch_public_json_from_sources(&client, "table", &table_sources)
        });
        let leaderboard_request = scope.spawn(|| {
            fetch_public_json_from_sources(&client, "leaderboard", &leaderboard_sources)
        });
        (
            table_request
                .join()
                .unwrap_or_else(|_| Err("Crowd Radar table worker panicked".into())),
            leaderboard_request
                .join()
                .unwrap_or_else(|_| Err("Crowd Radar leaderboard worker panicked".into())),
        )
    });
    combine_crowd_radar_payload(table, leaderboard)
}

fn fetch_public_json_from_sources(
    client: &reqwest::blocking::Client,
    label: &str,
    sources: &[(&str, &str, Duration)],
) -> Result<FetchedPublicJson, String> {
    let mut errors = Vec::new();
    for (source_index, (source, endpoint, timeout)) in sources.iter().enumerate() {
        match fetch_public_json(client, endpoint, &format!("{label}/{source}"), *timeout) {
            Ok(mut fetched) => {
                let provenance = fetched
                    .provenance
                    .as_object_mut()
                    .expect("source provenance is always an object");
                provenance.insert("source".into(), Value::String((*source).into()));
                provenance.insert("endpoint".into(), Value::String((*endpoint).into()));
                provenance.insert("fallbackUsed".into(), Value::Bool(source_index > 0));
                provenance.insert(
                    "sourceFailures".into(),
                    Value::Array(errors.iter().cloned().map(Value::String).collect()),
                );
                return Ok(fetched);
            }
            Err(error) => errors.push(error),
        }
    }
    Err(format!(
        "Crowd Radar {label} sources failed: {}",
        errors.join("; ")
    ))
}

fn fetch_public_json(
    client: &reqwest::blocking::Client,
    endpoint: &str,
    label: &str,
    timeout: Duration,
) -> Result<FetchedPublicJson, String> {
    let deadline = Instant::now() + timeout;
    let mut errors = Vec::new();
    for attempt in 1..=CODEX_CROWD_RADAR_MAX_ATTEMPTS {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match fetch_public_json_once(client, endpoint, remaining) {
            Ok(mut fetched) => {
                let cache_fresh = cache_freshness(&fetched.provenance);
                let provenance = fetched
                    .provenance
                    .as_object_mut()
                    .expect("source provenance is always an object");
                provenance.insert("attempts".into(), json!(attempt));
                provenance.insert(
                    "fresh".into(),
                    Value::Bool(cache_fresh.unwrap_or(true)),
                );
                provenance.insert(
                    "stale".into(),
                    Value::Bool(cache_fresh.map(|fresh| !fresh).unwrap_or(false)),
                );
                provenance.insert(
                    "freshnessBasis".into(),
                    Value::String(
                        if cache_fresh.is_some() {
                            "network_observation_cache_headers"
                        } else {
                            "network_observation"
                        }
                        .into(),
                    ),
                );
                provenance.insert(
                    "attemptErrors".into(),
                    Value::Array(errors.iter().cloned().map(Value::String).collect()),
                );
                return Ok(fetched);
            }
            Err(error) => {
                let formatted = format!(
                    "Crowd Radar {label} endpoint {endpoint} attempt {attempt}: {error}"
                );
                errors.push(formatted);
                if !error.retryable || attempt >= CODEX_CROWD_RADAR_MAX_ATTEMPTS {
                    break;
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining <= CODEX_CROWD_RADAR_RETRY_DELAY {
                    break;
                }
                thread::sleep(CODEX_CROWD_RADAR_RETRY_DELAY);
            }
        }
    }
    Err(format!(
        "Crowd Radar {label} endpoint {endpoint} failed after {} attempt(s): {}",
        errors.len(),
        errors.join("; ")
    ))
}

#[derive(Debug)]
struct FetchedPublicJson {
    value: Value,
    provenance: Value,
}

#[derive(Debug)]
struct PublicJsonFailure {
    message: String,
    retryable: bool,
}

impl fmt::Display for PublicJsonFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

fn fetch_public_json_once(
    client: &reqwest::blocking::Client,
    endpoint: &str,
    timeout: Duration,
) -> Result<FetchedPublicJson, PublicJsonFailure> {
    let response = client
        .get(endpoint)
        .timeout(timeout)
        .headers(public_json_headers())
        .send()
        .map_err(|error| PublicJsonFailure {
            message: format!("fetch failed: {error}"),
            retryable: error.is_connect() || error.is_timeout() || error.is_request(),
        })?;
    if !response.status().is_success() {
        let status = response.status();
        return Err(PublicJsonFailure {
            message: format!("HTTP {status}"),
            retryable: status.is_server_error()
                || matches!(status.as_u16(), 408 | 425 | 429),
        });
    }
    if response
        .content_length()
        .is_some_and(|length| length > CODEX_CROWD_RADAR_MAX_BYTES)
    {
        return Err(PublicJsonFailure {
            message: "payload is too large".into(),
            retryable: false,
        });
    }
    let provenance = response_cache_provenance(response.headers());
    // chunked 响应没有 content-length，上面的预检拦不住；必须边读边限长，
    // 否则恶意/故障服务端可在超时窗口内灌进无上限的内存。多取 1 字节用于
    // 区分"恰好达上限"与"超限"。
    let mut body = Vec::new();
    response
        .take(CODEX_CROWD_RADAR_MAX_BYTES + 1)
        .read_to_end(&mut body)
        .map_err(|error| PublicJsonFailure {
            message: format!("body failed: {error}"),
            retryable: true,
        })?;
    if body.is_empty() {
        return Err(PublicJsonFailure {
            message: "returned empty data".into(),
            retryable: false,
        });
    }
    if body.len() as u64 > CODEX_CROWD_RADAR_MAX_BYTES {
        return Err(PublicJsonFailure {
            message: "payload is too large".into(),
            retryable: false,
        });
    }
    let value = serde_json::from_slice(&body).map_err(|error| PublicJsonFailure {
        message: format!("parse failed: {error}"),
        retryable: false,
    })?;
    Ok(FetchedPublicJson { value, provenance })
}

fn response_cache_provenance(headers: &HeaderMap) -> Value {
    let header_text = |name: &str| {
        headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned)
    };
    let server_age = header_text("age").and_then(|value| value.parse::<u64>().ok());
    json!({
        "serverDate": header_text("date"),
        "lastModified": header_text("last-modified"),
        "etag": header_text("etag"),
        "cacheControl": header_text("cache-control"),
        "cacheStatus": header_text("cf-cache-status"),
        "serverAgeSeconds": server_age,
        "codexCache": header_text("x-codex-cache"),
        "codexCacheAgeSeconds": header_text("x-codex-cache-age")
            .and_then(|value| value.parse::<u64>().ok()),
        "codexFetchedAt": header_text("x-codex-fetched-at"),
    })
}

fn cache_freshness(provenance: &Value) -> Option<bool> {
    let object = provenance.as_object()?;
    let cache_control = object.get("cacheControl")?.as_str()?;
    let max_age = cache_control.split(',').find_map(|directive| {
        let (name, value) = directive.trim().split_once('=')?;
        name.trim().eq_ignore_ascii_case("max-age")
            .then(|| value.trim().parse::<u64>().ok())
            .flatten()
    })?;
    let server_age = object
        .get("serverAgeSeconds")
        .and_then(Value::as_u64)
        .into_iter()
        .chain(
            object
                .get("codexCacheAgeSeconds")
                .and_then(Value::as_u64),
        )
        .max()?;
    Some(server_age <= max_age)
}

fn combine_crowd_radar_payload(
    table: Result<FetchedPublicJson, String>,
    leaderboard: Result<FetchedPublicJson, String>,
) -> Result<Value, String> {
    let (table_value, table_provenance, table_error) = split_result(table);
    let (leaderboard_value, leaderboard_provenance, leaderboard_error) = split_result(leaderboard);
    if table_value.is_none() && leaderboard_value.is_none() {
        return Err(format!(
            "Crowd Radar endpoints failed: table={}; leaderboard={}",
            table_error.as_deref().unwrap_or("unknown"),
            leaderboard_error.as_deref().unwrap_or("unknown")
        ));
    }
    Ok(json!({
        "observedAt": time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| "unknown".into()),
        "table": table_value,
        "leaderboard": leaderboard_value,
        "tableError": table_error,
        "leaderboardError": leaderboard_error,
        "tableProvenance": table_provenance,
        "leaderboardProvenance": leaderboard_provenance,
    }))
}

fn split_result(
    result: Result<FetchedPublicJson, String>,
) -> (Option<Value>, Option<Value>, Option<String>) {
    match result {
        Ok(fetched) => (Some(fetched.value), Some(fetched.provenance), None),
        Err(error) => (None, None, Some(error)),
    }
}

fn full_detail_headers() -> Result<HeaderMap, String> {
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    headers.insert(USER_AGENT, HeaderValue::from_static("CodexTokenBar"));
    headers.insert(AUTHORIZATION, authorization_header_value()?);
    Ok(headers)
}

fn public_json_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    headers.insert(USER_AGENT, HeaderValue::from_static("CodexTokenBar"));
    headers
}

fn authorization_header_value() -> Result<HeaderValue, String> {
    let key = decode_key()?;
    HeaderValue::from_str(&format!("Bearer {key}"))
        .map_err(|error| format!("Codex Radar detail authorization header failed: {error}"))
}

fn decode_key() -> Result<String, String> {
    let plain: Vec<u8> = KEY_CIPHER
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let mask = KEY_MASK[(index * 7 + 13) % KEY_MASK.len()];
            value ^ mask ^ (((index * 31 + 17) & 0xff) as u8)
        })
        .collect();
    String::from_utf8(plain).map_err(|error| format!("Codex Radar detail key decode failed: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::AUTHORIZATION;

    fn spawn_http_response(status: &str, body: &str) -> (String, std::thread::JoinHandle<()>) {
        use std::io::Write;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("addr");
        let status = status.to_owned();
        let body = body.to_owned();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = [0_u8; 4096];
            let _ = stream.read(&mut request);
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("response");
        });
        (format!("http://{address}"), server)
    }

    fn spawn_http_sequence(
        responses: Vec<Option<(&str, &str)>>,
    ) -> (String, std::thread::JoinHandle<()>) {
        use std::io::Write;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("addr");
        let responses: Vec<Option<(String, String)>> = responses
            .into_iter()
            .map(|response| response.map(|(status, body)| (status.to_owned(), body.to_owned())))
            .collect();
        let server = std::thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().expect("accept");
                let mut request = [0_u8; 4096];
                let _ = stream.read(&mut request);
                let Some((status, body)) = response else {
                    continue;
                };
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).expect("response");
            }
        });
        (format!("http://{address}"), server)
    }

    fn fetched(value: Value) -> FetchedPublicJson {
        FetchedPublicJson {
            value,
            provenance: json!({"fresh": true, "stale": false}),
        }
    }

    #[test]
    fn full_detail_endpoint_uses_authenticated_api_path() {
        assert_eq!(
            CODEX_RADAR_FULL_ENDPOINT,
            "https://codexradar.com/api/v1/current"
        );
    }

    #[test]
    fn full_detail_headers_attach_authorization_without_exposing_plain_key() {
        let headers = full_detail_headers().expect("headers");
        let header = headers
            .get(AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .expect("authorization header");

        assert!(header.starts_with("Bearer crr_live_"));
        assert!(header.len() > "Bearer crr_live_".len() + 12);
        assert_eq!(
            headers.get(ACCEPT).and_then(|value| value.to_str().ok()),
            Some("application/json")
        );
    }

    #[test]
    fn crowd_radar_public_headers_never_attach_authorization() {
        let headers = public_json_headers();
        assert!(!headers.contains_key(AUTHORIZATION));
        assert_eq!(
            headers.get(ACCEPT).and_then(|value| value.to_str().ok()),
            Some("application/json")
        );
    }

    #[test]
    fn crowd_radar_prefers_responsive_site_sources_and_keeps_legacy_api_fallbacks() {
        assert_eq!(
            CODEX_CROWD_RADAR_TABLE_ENDPOINT,
            "https://codexradar.com/api/intelligence-efficiency"
        );
        assert_eq!(
            CODEX_CROWD_RADAR_LEADERBOARD_ENDPOINT,
            "https://codexradar.com/data/intelligence-efficiency.json"
        );
        assert_eq!(
            CODEX_CROWD_RADAR_TABLE_LEGACY_ENDPOINT,
            "https://api.codexradar.com/api/v1/table"
        );
        assert_eq!(
            CODEX_CROWD_RADAR_LEADERBOARD_LEGACY_ENDPOINT,
            "https://api.codexradar.com/api/v1/leaderboard"
        );
    }

    #[test]
    fn crowd_radar_source_chain_uses_the_next_source_after_failure() {
        let (primary_url, primary_server) = spawn_http_response("503 Service Unavailable", "{}");
        let (fallback_url, fallback_server) =
            spawn_http_response("200 OK", r#"{"points":[{"model":"gpt-5.6-sol"}]}"#);
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .no_gzip()
            .build()
            .expect("client");
        let sources = [
            ("primary", primary_url.as_str(), Duration::from_secs(2)),
            ("fallback", fallback_url.as_str(), Duration::from_secs(2)),
        ];

        let payload = fetch_public_json_from_sources(&client, "leaderboard", &sources)
            .expect("fallback source");
        assert_eq!(
            payload
                .value
                .pointer("/points/0/model")
                .and_then(Value::as_str),
            Some("gpt-5.6-sol")
        );
        primary_server.join().expect("primary server");
        fallback_server.join().expect("fallback server");
    }

    #[test]
    fn crowd_radar_retries_a_transient_http_failure_within_the_source_budget() {
        let (endpoint, server) = spawn_http_sequence(vec![
            Some(("503 Service Unavailable", "{}")),
            Some(("200 OK", r#"{"points":[{"model":"gpt-5.6-sol"}]}"#)),
        ]);
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .no_gzip()
            .build()
            .expect("client");
        let sources = [("site", endpoint.as_str(), Duration::from_secs(2))];

        let fetched = fetch_public_json_from_sources(&client, "leaderboard", &sources)
            .expect("transient failure retry");
        assert_eq!(
            fetched
                .value
                .pointer("/points/0/model")
                .and_then(Value::as_str),
            Some("gpt-5.6-sol")
        );
        assert_eq!(
            fetched.provenance.get("attempts").and_then(Value::as_u64),
            Some(2)
        );
        assert_eq!(
            fetched
                .provenance
                .get("attemptErrors")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(1)
        );
        assert_eq!(
            fetched.provenance.get("fresh").and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(
            fetched.provenance.get("stale").and_then(Value::as_bool),
            Some(false)
        );
        server.join().expect("server");
    }

    #[test]
    fn crowd_radar_does_not_retry_a_schema_or_parse_failure() {
        let (endpoint, server) = spawn_http_response("200 OK", "not-json");
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .no_gzip()
            .build()
            .expect("client");
        let sources = [("site", endpoint.as_str(), Duration::from_secs(2))];

        let error = fetch_public_json_from_sources(&client, "table", &sources)
            .expect_err("invalid JSON must fail closed");
        assert!(error.contains("after 1 attempt"), "{error}");
        assert!(error.contains("parse failed"), "{error}");
        server.join().expect("server");
    }

    #[test]
    fn crowd_radar_timeout_keeps_the_transport_error_visible() {
        use std::io::Write;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("addr");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = [0_u8; 4096];
            let _ = stream.read(&mut request);
            let _ = stream.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n",
            );
            std::thread::sleep(Duration::from_millis(150));
        });
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(1))
            .no_gzip()
            .build()
            .expect("client");
        let endpoint = format!("http://{address}");
        let sources = [("site", endpoint.as_str(), Duration::from_millis(30))];

        let error = fetch_public_json_from_sources(&client, "table", &sources)
            .expect_err("body timeout must fail closed");
        assert!(error.contains("after"), "{error}");
        assert!(error.contains("attempt"), "{error}");
        assert!(error.contains("body failed") || error.contains("fetch failed"), "{error}");
        server.join().expect("server");
    }

    #[test]
    fn crowd_radar_marks_server_cache_beyond_max_age_as_stale() {
        let mut headers = HeaderMap::new();
        headers.insert("cache-control", HeaderValue::from_static("public, max-age=30"));
        headers.insert("age", HeaderValue::from_static("31"));
        let provenance = response_cache_provenance(&headers);
        assert_eq!(cache_freshness(&provenance), Some(false));

        headers.insert("age", HeaderValue::from_static("30"));
        let provenance = response_cache_provenance(&headers);
        assert_eq!(cache_freshness(&provenance), Some(true));
    }

    #[test]
    fn crowd_radar_oversized_chunked_body_is_rejected_while_streaming() {
        use std::io::Write;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("addr");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = [0_u8; 4096];
            let _ = stream.read(&mut request);
            let _ = stream.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n",
            );
            // 每块 64 KiB、共 9 MiB，越过 8 MiB 上限；客户端应中途放弃，
            // 写端出现断管属预期，忽略错误退出即可。
            let chunk = vec![b'a'; 64 * 1024];
            let header = format!("{:x}\r\n", chunk.len());
            for _ in 0..144 {
                if stream.write_all(header.as_bytes()).is_err()
                    || stream.write_all(&chunk).is_err()
                    || stream.write_all(b"\r\n").is_err()
                {
                    return;
                }
            }
            let _ = stream.write_all(b"0\r\n\r\n");
        });

        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(30))
            .no_gzip()
            .build()
            .expect("client");
        let error = fetch_public_json(
            &client,
            &format!("http://{address}/table"),
            "table",
            Duration::from_secs(30),
        )
        .expect_err("chunked 无 content-length 的超限响应必须在流式阶段被拒绝");
        assert!(error.contains("payload is too large"), "{error}");
        let _ = server.join();
    }

    #[test]
    fn crowd_radar_payload_keeps_a_healthy_endpoint_when_the_other_fails() {
        let payload = combine_crowd_radar_payload(
            Err("table unavailable".into()),
            Ok(fetched(json!({"models": [{"model": "gpt-5.6-sol"}]}))),
        )
        .expect("partial payload");
        assert!(payload.get("table").is_some_and(Value::is_null));
        assert_eq!(
            payload.pointer("/leaderboard/models/0/model").and_then(Value::as_str),
            Some("gpt-5.6-sol")
        );
        assert_eq!(
            payload.get("tableError").and_then(Value::as_str),
            Some("table unavailable")
        );
        assert_eq!(
            payload
                .pointer("/leaderboardProvenance/fresh")
                .and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(
            payload
                .pointer("/leaderboardProvenance/stale")
                .and_then(Value::as_bool),
            Some(false)
        );
    }

    #[test]
    fn crowd_radar_payload_fails_only_when_both_endpoints_fail() {
        let error = combine_crowd_radar_payload(
            Err("table unavailable".into()),
            Err("leaderboard unavailable".into()),
        )
        .expect_err("both endpoints must fail");
        assert!(error.contains("table unavailable"));
        assert!(error.contains("leaderboard unavailable"));
    }

    #[test]
    #[ignore = "requires the live public Crowd Radar endpoints"]
    fn live_crowd_radar_payload_contains_rankable_models() {
        let payload = fetch_codex_crowd_radar_payload().expect("live Crowd Radar payload");
        let models = payload
            .pointer("/leaderboard/models")
            .and_then(Value::as_array)
            .or_else(|| payload.pointer("/leaderboard/points").and_then(Value::as_array))
            .expect("leaderboard models or published points");
        assert!(models.len() >= 3);
        assert!(models.iter().any(|model| {
            let has_score = model.get("pass_rate").and_then(Value::as_f64).is_some()
                || model.get("iq").and_then(Value::as_f64).is_some();
            let samples = model
                .get("graded")
                .or_else(|| model.get("valid_tasks"))
                .and_then(Value::as_i64)
                .unwrap_or_default();
            has_score && samples > 0
        }));
    }
}
