use super::window_auth::require_window_label;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, USER_AGENT};
use serde_json::Value;
use std::time::Duration;
use tauri::async_runtime;

const CODEX_RADAR_FULL_ENDPOINT: &str = "https://codexradar.com/api/v1/current";
const CODEX_RADAR_TIMEOUT: Duration = Duration::from_secs(20);
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

fn full_detail_headers() -> Result<HeaderMap, String> {
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    headers.insert(USER_AGENT, HeaderValue::from_static("CodexTokenBar"));
    headers.insert(AUTHORIZATION, authorization_header_value()?);
    Ok(headers)
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
}
