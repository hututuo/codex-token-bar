use super::window_auth::require_window_label;
use flate2::read::GzDecoder;
use reqwest::header::{
    HeaderMap, HeaderValue, ACCEPT, ACCEPT_ENCODING, AUTHORIZATION, CONTENT_ENCODING,
    USER_AGENT,
};
use serde_json::{json, Value};
use std::fmt;
use std::io::Read;
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use tauri::async_runtime;

const CODEX_RADAR_FULL_ENDPOINT: &str = "https://codexradar.com/api/v1/current";
const CODEX_RADAR_HOME_ENDPOINT: &str = "https://codexradar.com/";
const CODEX_CROWD_RADAR_TABLE_ENDPOINT: &str =
    "https://codexradar.com/api/intelligence-efficiency";
const CODEX_CROWD_RADAR_TABLE_LEGACY_ENDPOINT: &str =
    "https://api.codexradar.com/api/v1/table";
const CODEX_CROWD_RADAR_LEADERBOARD_ENDPOINT: &str =
    "https://codexradar.com/data/intelligence-efficiency.json";
const CODEX_CROWD_RADAR_LEADERBOARD_LEGACY_ENDPOINT: &str =
    "https://api.codexradar.com/api/v1/leaderboard";
const CODEX_RADAR_TIMEOUT: Duration = Duration::from_secs(20);
const CODEX_RADAR_HOME_TIMEOUT: Duration = Duration::from_secs(8);
const CODEX_RADAR_HOME_MAX_BYTES: u64 = 2 * 1024 * 1024;
const CODEX_RADAR_COUNTDOWN_SUCCESS_CACHE_TTL: Duration = Duration::from_secs(30);
const CODEX_RADAR_COUNTDOWN_FAILURE_COOLDOWN: Duration = Duration::from_secs(2);
const CODEX_CROWD_RADAR_TIMEOUT: Duration = Duration::from_secs(18);
const CODEX_CROWD_RADAR_PRIMARY_TIMEOUT: Duration = Duration::from_secs(12);
const CODEX_CROWD_RADAR_LEGACY_TIMEOUT: Duration = Duration::from_secs(6);
const CODEX_CROWD_RADAR_MAX_BYTES: u64 = 8 * 1024 * 1024;
const CODEX_CROWD_RADAR_MAX_ATTEMPTS: usize = 3;
// Multiple Tauri windows mount their own JS runtime. Keep the network
// coordinator in Rust so startup cannot fan out one request per window.
const CODEX_CROWD_RADAR_SUCCESS_CACHE_TTL: Duration = Duration::from_secs(20);
const CODEX_CROWD_RADAR_FAILURE_COOLDOWN: Duration = Duration::from_secs(10);
const KEY_CIPHER: [u8; 57] = [
    94, 228, 121, 185, 168, 72, 126, 255, 5, 110, 24, 99, 74, 39, 157, 134, 100, 135, 125, 94,
    135, 210, 1, 144, 13, 46, 200, 43, 156, 101, 161, 236, 160, 80, 7, 176, 218, 251, 217,
    188, 109, 99, 36, 171, 48, 39, 199, 14, 215, 225, 47, 222, 173, 72, 143, 235, 177,
];
const KEY_MASK: [u8; 23] = [
    83, 33, 141, 11, 68, 159, 226, 23, 106, 195, 61, 136, 241, 44, 5, 185, 112, 222, 73,
    17, 166, 92, 47,
];

#[derive(Default)]
struct RadarCountdownFetchState {
    in_flight: bool,
    success: Option<RadarCountdownCachedSuccess>,
    failure: Option<RadarCountdownCachedFailure>,
}

struct RadarCountdownCachedSuccess {
    deadline: Option<String>,
    fetched_at: Instant,
}

struct RadarCountdownCachedFailure {
    message: String,
    failed_at: Instant,
}

struct RadarCountdownFetchCoordinator {
    state: Mutex<RadarCountdownFetchState>,
    wake: Condvar,
}

impl RadarCountdownFetchCoordinator {
    fn get_or_fetch(&self) -> Result<Option<String>, String> {
        self.get_or_fetch_with(fetch_codex_radar_window_countdown)
    }

    fn get_or_fetch_with<F>(&self, fetch: F) -> Result<Option<String>, String>
    where
        F: FnOnce() -> Result<Option<String>, String>,
    {
        self.get_or_fetch_inner(Some(fetch))
    }

    fn get_or_fetch_inner<F>(&self, mut fetch: Option<F>) -> Result<Option<String>, String>
    where
        F: FnOnce() -> Result<Option<String>, String>,
    {
        loop {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());

            if let Some(success) = state.success.as_ref() {
                if success.fetched_at.elapsed() <= CODEX_RADAR_COUNTDOWN_SUCCESS_CACHE_TTL {
                    return Ok(success.deadline.clone());
                }
            }

            if state.in_flight {
                state = self
                    .wake
                    .wait(state)
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                drop(state);
                continue;
            }

            if let Some(failure) = state.failure.as_ref() {
                if failure.failed_at.elapsed() <= CODEX_RADAR_COUNTDOWN_FAILURE_COOLDOWN {
                    return Err(failure.message.clone());
                }
            }

            state.in_flight = true;
            drop(state);

            let result = fetch
                .take()
                .expect("Radar countdown fetch closure is consumed only by the owner")();
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state.in_flight = false;
            match &result {
                Ok(deadline) => {
                    state.success = Some(RadarCountdownCachedSuccess {
                        deadline: deadline.clone(),
                        fetched_at: Instant::now(),
                    });
                    state.failure = None;
                }
                Err(message) => {
                    state.failure = Some(RadarCountdownCachedFailure {
                        message: message.clone(),
                        failed_at: Instant::now(),
                    });
                }
            }
            self.wake.notify_all();
            return result;
        }
    }
}

fn radar_countdown_fetch_coordinator() -> &'static RadarCountdownFetchCoordinator {
    static COORDINATOR: OnceLock<RadarCountdownFetchCoordinator> = OnceLock::new();
    COORDINATOR.get_or_init(|| RadarCountdownFetchCoordinator {
        state: Mutex::new(RadarCountdownFetchState::default()),
        wake: Condvar::new(),
    })
}

#[derive(Default)]
struct CrowdRadarFetchState {
    in_flight: bool,
    success: Option<CrowdRadarCachedSuccess>,
    failure: Option<CrowdRadarCachedFailure>,
}

struct CrowdRadarCachedSuccess {
    payload: Value,
    fetched_at: Instant,
}

struct CrowdRadarCachedFailure {
    message: String,
    failed_at: Instant,
}

struct CrowdRadarFetchCoordinator {
    state: Mutex<CrowdRadarFetchState>,
    wake: Condvar,
}

impl CrowdRadarFetchCoordinator {
    fn get_or_fetch(&self) -> Result<Value, String> {
        self.get_or_fetch_with(fetch_codex_crowd_radar_payload_uncached)
    }

    fn get_or_fetch_with<F>(&self, fetch: F) -> Result<Value, String>
    where
        F: FnOnce() -> Result<Value, String>,
    {
        self.get_or_fetch_inner(Some(fetch))
    }

    fn get_or_fetch_inner<F>(&self, mut fetch: Option<F>) -> Result<Value, String>
    where
        F: FnOnce() -> Result<Value, String>,
    {
        loop {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());

            if let Some(success) = state.success.as_ref() {
                if success.fetched_at.elapsed() <= CODEX_CROWD_RADAR_SUCCESS_CACHE_TTL {
                    return Ok(success.payload.clone());
                }
            }

            if state.in_flight {
                state = self
                    .wake
                    .wait(state)
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                drop(state);
                continue;
            }

            if let Some(failure) = state.failure.as_ref() {
                if failure.failed_at.elapsed() <= CODEX_CROWD_RADAR_FAILURE_COOLDOWN {
                    return Err(failure.message.clone());
                }
            }

            state.in_flight = true;
            drop(state);

            let result = fetch
                .take()
                .expect("Crowd Radar fetch closure is consumed only by the owner")();
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state.in_flight = false;
            match &result {
                Ok(payload) => {
                    state.success = Some(CrowdRadarCachedSuccess {
                        payload: payload.clone(),
                        fetched_at: Instant::now(),
                    });
                    state.failure = None;
                }
                Err(message) => {
                    state.failure = Some(CrowdRadarCachedFailure {
                        message: message.clone(),
                        failed_at: Instant::now(),
                    });
                }
            }
            self.wake.notify_all();
            return result;
        }
    }
}

fn crowd_radar_fetch_coordinator() -> &'static CrowdRadarFetchCoordinator {
    static COORDINATOR: OnceLock<CrowdRadarFetchCoordinator> = OnceLock::new();
    COORDINATOR.get_or_init(|| CrowdRadarFetchCoordinator {
        state: Mutex::new(CrowdRadarFetchState::default()),
        wake: Condvar::new(),
    })
}

#[tauri::command]
pub async fn read_codex_radar_full_snapshot(
    window: tauri::WebviewWindow,
) -> Result<Value, String> {
    require_window_label(&window, "read_codex_radar_full_snapshot")?;
    async_runtime::spawn_blocking(fetch_codex_radar_full_snapshot)
        .await
        .map_err(|error| error.to_string())?
}

/// Reads the expected end of the currently open speed window from the Radar
/// homepage announcement. The public JSON intentionally leaves `closed_at`
/// empty while the page clock still exposes this supplemental deadline.
#[tauri::command]
pub async fn read_codex_radar_window_countdown(
    window: tauri::WebviewWindow,
) -> Result<Option<String>, String> {
    require_window_label(&window, "read_codex_radar_window_countdown")?;
    async_runtime::spawn_blocking(|| radar_countdown_fetch_coordinator().get_or_fetch())
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn read_codex_crowd_radar_payload(
    window: tauri::WebviewWindow,
) -> Result<Value, String> {
    require_window_label(&window, "read_codex_crowd_radar_payload")?;
    async_runtime::spawn_blocking(|| crowd_radar_fetch_coordinator().get_or_fetch())
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

fn fetch_codex_radar_window_countdown() -> Result<Option<String>, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(CODEX_RADAR_HOME_TIMEOUT)
        .no_gzip()
        .build()
        .map_err(|error| format!("Codex Radar homepage client failed: {error}"))?;

    let response = client
        .get(CODEX_RADAR_HOME_ENDPOINT)
        .headers(public_html_headers())
        .send()
        .map_err(|error| format!("Codex Radar homepage fetch failed: {error}"))?;

    if !response.status().is_success() {
        return Err(format!("Codex Radar homepage HTTP {}", response.status()));
    }

    let mut body = String::new();
    response
        .take(CODEX_RADAR_HOME_MAX_BYTES + 1)
        .read_to_string(&mut body)
        .map_err(|error| format!("Codex Radar homepage read failed: {error}"))?;
    if body.len() as u64 > CODEX_RADAR_HOME_MAX_BYTES {
        return Err("Codex Radar homepage is too large".into());
    }

    Ok(parse_window_countdown_deadline(&body))
}

fn parse_window_countdown_deadline(html: &str) -> Option<String> {
    let mut search_from = 0;
    while let Some(relative_marker) = html[search_from..].find("data-speed-window") {
        let marker_start = search_from + relative_marker;
        let Some(section_start) = html[..marker_start].rfind("<section") else {
            search_from = marker_start.saturating_add("data-speed-window".len());
            continue;
        };
        let Some(relative_opening_end) = html[marker_start..].find('>') else {
            break;
        };
        let opening_end = marker_start + relative_opening_end;
        let opening = &html[section_start..=opening_end];
        if html_attribute_value(opening, "data-speed-window") != Some("open") {
            search_from = opening_end.saturating_add(1);
            continue;
        }

        let section_end = html[opening_end.saturating_add(1)..]
            .find("</section")
            .map(|offset| opening_end.saturating_add(1) + offset)
            .unwrap_or(html.len());
        let section = &html[opening_end.saturating_add(1)..section_end];
        if let Some(deadline) = html_attribute_value(section, "data-window-closes-at") {
            return Some(deadline.to_owned());
        }
        search_from = section_end.saturating_add(1);
    }
    None
}

fn html_attribute_value<'a>(html: &'a str, attribute: &str) -> Option<&'a str> {
    let marker = format!("{attribute}=");
    let start = html.find(&marker)? + marker.len();
    let remainder = &html[start..];
    let quote = remainder.as_bytes().first().copied()?;
    if quote != b'"' && quote != b'\'' {
        return None;
    }
    let value = &remainder[1..];
    let end = value.find(quote as char)?;
    Some(value[..end].trim())
}

fn fetch_codex_crowd_radar_payload_uncached() -> Result<Value, String> {
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

#[cfg(test)]
fn fetch_codex_crowd_radar_payload() -> Result<Value, String> {
    crowd_radar_fetch_coordinator().get_or_fetch()
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
                if !public_payload_has_signal(&fetched.value, label) {
                    errors.push(format!(
                        "Crowd Radar {label} endpoint {endpoint}: unsupported payload shape"
                    ));
                    continue;
                }
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
                    cache_fresh.map(Value::Bool).unwrap_or(Value::Null),
                );
                provenance.insert(
                    "stale".into(),
                    cache_fresh
                        .map(|fresh| Value::Bool(!fresh))
                        .unwrap_or(Value::Null),
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
                let retry_delay = crowd_radar_retry_delay(attempt);
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining <= retry_delay {
                    break;
                }
                thread::sleep(retry_delay);
            }
        }
    }
    Err(format!(
        "Crowd Radar {label} endpoint {endpoint} failed after {} attempt(s): {}",
        errors.len(),
        errors.join("; ")
    ))
}

fn crowd_radar_retry_delay(attempt: usize) -> Duration {
    match attempt {
        1 => Duration::from_millis(250),
        2 => Duration::from_millis(750),
        _ => Duration::ZERO,
    }
}

fn public_payload_has_signal(value: &Value, label: &str) -> bool {
    let signal_keys: &[&str] = match label {
        "table" => &["combos", "tasks", "cells", "baseline_generated_at"],
        "leaderboard" => &["points", "models", "rankings", "model_stats"],
        _ => &[],
    };
    fn contains_signal(value: &Value, signal_keys: &[&str], depth: usize) -> bool {
        let Some(object) = value.as_object() else { return false };
        if object.keys().any(|key| {
            let canonical = key
                .chars()
                .filter(|character| character.is_alphanumeric())
                .flat_map(char::to_lowercase)
                .collect::<String>();
            signal_keys.iter().any(|signal| {
                let signal_canonical = signal
                    .chars()
                    .filter(|character| character.is_alphanumeric())
                    .flat_map(char::to_lowercase)
                    .collect::<String>();
                canonical == signal_canonical
            })
        }) {
            return true;
        }
        if depth >= 4 { return false }
        ["data", "result", "snapshot", "payload", "response", "body"]
            .iter()
            .filter_map(|wrapper| object.get(*wrapper))
            .any(|nested| contains_signal(nested, signal_keys, depth + 1))
    }
    contains_signal(value, signal_keys, 0)
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
    // 否则恶意/故障服务端可在超时窗口内灌进无上限的内存。服务端的公开榜单
    // 会返回 gzip，先在解压流上限长，再解析 JSON，避免启动期传输被无压缩大包
    // 和压缩炸弹拖垮。
    let body = read_public_json_body(response)?;
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

fn read_public_json_body(response: reqwest::blocking::Response) -> Result<Vec<u8>, PublicJsonFailure> {
    let encoding = response
        .headers()
        .get(CONTENT_ENCODING)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .unwrap_or("")
        .to_owned();
    let limited_response = response.take(CODEX_CROWD_RADAR_MAX_BYTES + 1);
    let mut body = Vec::new();
    if encoding.eq_ignore_ascii_case("gzip") {
        let decoder = GzDecoder::new(limited_response);
        decoder
            .take(CODEX_CROWD_RADAR_MAX_BYTES + 1)
            .read_to_end(&mut body)
            .map_err(|error| PublicJsonFailure {
                message: format!("body failed: {error}"),
                retryable: true,
            })?;
    } else if encoding.is_empty() || encoding.eq_ignore_ascii_case("identity") {
        limited_response
            .take(CODEX_CROWD_RADAR_MAX_BYTES + 1)
            .read_to_end(&mut body)
            .map_err(|error| PublicJsonFailure {
                message: format!("body failed: {error}"),
                retryable: true,
            })?;
    } else {
        return Err(PublicJsonFailure {
            message: format!("unsupported content encoding: {encoding}"),
            retryable: false,
        });
    }
    Ok(body)
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
    headers.insert(ACCEPT_ENCODING, HeaderValue::from_static("gzip"));
    headers.insert(USER_AGENT, HeaderValue::from_static("CodexTokenBar"));
    headers
}

fn public_html_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, HeaderValue::from_static("text/html"));
    headers.insert(ACCEPT_ENCODING, HeaderValue::from_static("identity"));
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

    fn spawn_gzip_http_response(body: &str) -> (String, std::thread::JoinHandle<()>) {
        use flate2::{write::GzEncoder, Compression};
        use std::io::Write;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("addr");
        let body = body.as_bytes().to_vec();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = [0_u8; 4096];
            let _ = stream.read(&mut request);
            let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
            encoder.write_all(&body).expect("gzip body");
            let compressed = encoder.finish().expect("finish gzip");
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                compressed.len()
            );
            stream.write_all(response.as_bytes()).expect("headers");
            stream.write_all(&compressed).expect("body");
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
    fn radar_countdown_fetch_coordinator_shares_one_deadline_across_webviews() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::{Arc, Barrier};

        let coordinator = Arc::new(RadarCountdownFetchCoordinator {
            state: Mutex::new(RadarCountdownFetchState::default()),
            wake: Condvar::new(),
        });
        let calls = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(8));
        let handles = (0..8)
            .map(|_| {
                let coordinator = Arc::clone(&coordinator);
                let calls = Arc::clone(&calls);
                let start = Arc::clone(&start);
                std::thread::spawn(move || {
                    start.wait();
                    coordinator.get_or_fetch_with(|| {
                        calls.fetch_add(1, Ordering::SeqCst);
                        thread::sleep(Duration::from_millis(40));
                        Ok(Some("2026-08-24T05:00:00+08:00".to_string()))
                    })
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            assert_eq!(
                handle.join().expect("countdown single-flight worker"),
                Ok(Some("2026-08-24T05:00:00+08:00".to_string()))
            );
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let cached = coordinator
            .get_or_fetch_with(|| {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(Some("should not replace cached deadline".to_string()))
            })
            .expect("cached countdown deadline");
        assert_eq!(cached.as_deref(), Some("2026-08-24T05:00:00+08:00"));
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let empty_coordinator = RadarCountdownFetchCoordinator {
            state: Mutex::new(RadarCountdownFetchState::default()),
            wake: Condvar::new(),
        };
        let empty_calls = AtomicUsize::new(0);
        assert_eq!(
            empty_coordinator.get_or_fetch_with(|| {
                empty_calls.fetch_add(1, Ordering::SeqCst);
                Ok(None)
            }),
            Ok(None)
        );
        assert_eq!(
            empty_coordinator.get_or_fetch_with(|| {
                empty_calls.fetch_add(1, Ordering::SeqCst);
                Ok(Some("unexpected".to_string()))
            }),
            Ok(None)
        );
        assert_eq!(empty_calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn crowd_radar_fetch_coordinator_single_flights_and_cools_down_failures() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::{Arc, Barrier};

        let coordinator = Arc::new(CrowdRadarFetchCoordinator {
            state: Mutex::new(CrowdRadarFetchState::default()),
            wake: Condvar::new(),
        });
        let calls = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(8));
        let handles = (0..8)
            .map(|_| {
                let coordinator = Arc::clone(&coordinator);
                let calls = Arc::clone(&calls);
                let start = Arc::clone(&start);
                std::thread::spawn(move || {
                    start.wait();
                    coordinator.get_or_fetch_with(|| {
                        calls.fetch_add(1, Ordering::SeqCst);
                        thread::sleep(Duration::from_millis(40));
                        Ok(json!({"ok": true}))
                    })
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            assert_eq!(
                handle.join().expect("single-flight worker"),
                Ok(json!({"ok": true}))
            );
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let failure_coordinator = CrowdRadarFetchCoordinator {
            state: Mutex::new(CrowdRadarFetchState::default()),
            wake: Condvar::new(),
        };
        let failures = Arc::new(AtomicUsize::new(0));
        let first_error = failure_coordinator
            .get_or_fetch_with(|| {
                failures.fetch_add(1, Ordering::SeqCst);
                Err("temporary network failure".into())
            })
            .expect_err("failure should be returned");
        let second_error = failure_coordinator
            .get_or_fetch_with(|| {
                failures.fetch_add(1, Ordering::SeqCst);
                Err("should be cooled down".into())
            })
            .expect_err("failure cooldown should be returned");
        assert_eq!(first_error, "temporary network failure");
        assert_eq!(second_error, "temporary network failure");
        assert_eq!(failures.load(Ordering::SeqCst), 1);
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
        assert_eq!(
            headers
                .get(ACCEPT_ENCODING)
                .and_then(|value| value.to_str().ok()),
            Some("gzip")
        );
    }

    #[test]
    fn radar_homepage_parser_reads_open_window_deadline() {
        let html = r#"
            <section class="site-announcement site-announcement-reset"
                     data-speed-window='open'>
              <div data-window-closes-at="2026-08-24T05:00:00+08:00"></div>
            </section>
        "#;
        assert_eq!(
            parse_window_countdown_deadline(html).as_deref(),
            Some("2026-08-24T05:00:00+08:00")
        );
    }

    #[test]
    fn radar_homepage_parser_fails_closed_without_open_announcement() {
        let html = r#"
            <section data-speed-window="closed">
              <div data-window-closes-at="2026-08-24T05:00:00+08:00"></div>
            </section>
        "#;
        assert_eq!(parse_window_countdown_deadline(html), None);
    }

    #[test]
    fn crowd_radar_decodes_gzip_public_responses_before_size_and_json_checks() {
        let (endpoint, server) = spawn_gzip_http_response(
            r#"{"points":[{"model":"gpt-5.6-luna","graded":3,"passed":2}]}"#,
        );
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .no_gzip()
            .build()
            .expect("client");
        let fetched = fetch_public_json(
            &client,
            &endpoint,
            "leaderboard",
            Duration::from_secs(2),
        )
        .expect("gzip response");
        assert_eq!(
            fetched
                .value
                .pointer("/points/0/model")
                .and_then(Value::as_str),
            Some("gpt-5.6-luna")
        );
        server.join().expect("server");
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
    fn crowd_radar_recognizes_current_official_table_and_published_points_shapes() {
        assert!(public_payload_has_signal(
            &json!({"schema": 1, "combos": [], "tasks": [], "cells": {}}),
            "table"
        ));
        assert!(public_payload_has_signal(
            &json!({"schema": 2, "source_updated_at": "2026-08-08T04:50:48+08:00", "points": []}),
            "leaderboard"
        ));
        assert!(!public_payload_has_signal(&json!({"ok": true}), "leaderboard"));
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
            Some(3)
        );
        assert_eq!(
            fetched
                .provenance
                .get("attemptErrors")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(2)
        );
        assert_eq!(
            fetched.provenance.get("fresh").and_then(Value::as_bool),
            None
        );
        assert_eq!(
            fetched.provenance.get("stale").and_then(Value::as_bool),
            None
        );
        server.join().expect("server");
    }

    #[test]
    fn crowd_radar_skips_an_http_success_with_an_unrecognized_shape() {
        let (primary_url, primary_server) = spawn_http_response("200 OK", r#"{"ok":true}"#);
        let (fallback_url, fallback_server) =
            spawn_http_response("200 OK", r#"{"points":[{"model":"gpt-5.6-sol"}]}"#);
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .no_gzip()
            .build()
            .expect("client");
        let sources = [
            ("site", primary_url.as_str(), Duration::from_secs(2)),
            ("published", fallback_url.as_str(), Duration::from_secs(2)),
        ];

        let fetched = fetch_public_json_from_sources(&client, "leaderboard", &sources)
            .expect("schema fallback");
        assert_eq!(
            fetched
                .value
                .pointer("/points/0/model")
                .and_then(Value::as_str),
            Some("gpt-5.6-sol")
        );
        assert_eq!(fetched.provenance.get("source").and_then(Value::as_str), Some("published"));
        assert_eq!(
            fetched
                .provenance
                .get("sourceFailures")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(1)
        );
        primary_server.join().expect("primary server");
        fallback_server.join().expect("fallback server");
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
    fn crowd_radar_all_sources_failed_error_keeps_each_source_diagnostic() {
        let (table_site, table_site_server) = spawn_http_response("503 Service Unavailable", "{}");
        let (table_legacy, table_legacy_server) =
            spawn_http_response("503 Service Unavailable", "{}");
        let (leaderboard_site, leaderboard_site_server) =
            spawn_http_response("503 Service Unavailable", "{}");
        let (leaderboard_legacy, leaderboard_legacy_server) =
            spawn_http_response("503 Service Unavailable", "{}");
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .no_gzip()
            .build()
            .expect("client");
        let table = fetch_public_json_from_sources(
            &client,
            "table",
            &[
                ("site", table_site.as_str(), Duration::from_secs(2)),
                ("legacy-api", table_legacy.as_str(), Duration::from_secs(2)),
            ],
        )
        .expect_err("table should fail");
        let leaderboard = fetch_public_json_from_sources(
            &client,
            "leaderboard",
            &[
                ("published", leaderboard_site.as_str(), Duration::from_secs(2)),
                ("legacy-api", leaderboard_legacy.as_str(), Duration::from_secs(2)),
            ],
        )
        .expect_err("leaderboard should fail");
        let error = combine_crowd_radar_payload(Err(table), Err(leaderboard))
            .expect_err("both source groups should fail");
        assert!(error.contains("table/site"), "{error}");
        assert!(error.contains("table/legacy-api"), "{error}");
        assert!(error.contains("leaderboard/published"), "{error}");
        assert!(error.contains("leaderboard/legacy-api"), "{error}");
        table_site_server.join().expect("table site server");
        table_legacy_server.join().expect("table legacy server");
        leaderboard_site_server.join().expect("leaderboard site server");
        leaderboard_legacy_server.join().expect("leaderboard legacy server");
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
                .and_then(|value| {
                    value
                        .as_i64()
                        .or_else(|| value.as_f64().map(|number| number as i64))
                })
                .unwrap_or_default();
            has_score && samples > 0
        }));
    }
}
