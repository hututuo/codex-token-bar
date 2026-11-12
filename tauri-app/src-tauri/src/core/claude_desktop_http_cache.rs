//! Offline Chromium Simple Cache v5 /usage responses; no browser or HTTP requests.
use super::{
    local_quota_cache::{crc32, read_file},
    multi_client_usage::{ClaudeLocalQuotaSnapshot, ClaudeLocalQuotaWindow},
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, io::Read, path::Path};
use time::{
    format_description::well_known::{Rfc2822, Rfc3339},
    OffsetDateTime,
};

const MAX_ENTRY: usize = 2 * 1024 * 1024;
const MAX_BODY: usize = 65_536;
// Streaming responses use a 2 MiB window; the decoded JSON remains capped at 64 KiB.
const MAX_WINDOW_LOG: u32 = 21;
const ENTRY_MAGIC: u64 = 0xfcfb6d1ba7725c30;
const EOF_MAGIC: u64 = 0xf4fa6f45970d41d8;
const SOURCE: &str = "local-desktop-http-cache";

fn integer(bytes: &[u8], offset: usize, count: usize) -> Option<u64> {
    let slice = bytes.get(offset..offset.checked_add(count)?)?;
    Some(
        slice
            .iter()
            .enumerate()
            .fold(0, |n, (i, b)| n | (*b as u64) << (i * 8)),
    )
}
fn usage_key(bytes: &[u8]) -> Option<&[u8]> {
    if integer(bytes, 0, 8)? != ENTRY_MAGIC || integer(bytes, 8, 4)? != 5 {
        return None;
    }
    let length = integer(bytes, 12, 4)? as usize;
    if length == 0 || length > 1024 {
        return None;
    }
    let key = bytes.get(24..24 + length)?;
    let text = std::str::from_utf8(key).ok()?;
    let mut pieces = text.splitn(3, '/');
    for _ in 0..2 {
        let prefix = pieces.next()?;
        if prefix.is_empty() || !prefix.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
    }
    let url = pieces.next()?;
    if url.bytes().any(|b| b <= b' ' || b == 0x7f || b == b'#') {
        return None;
    }
    let path = url.split_once('?').map_or(url, |(path, _)| path);
    let organization = path
        .strip_prefix("https://claude.ai/api/organizations/")?
        .strip_suffix("/usage")?;
    if organization.len() != 36
        || !organization
            .bytes()
            .all(|b| b.is_ascii_hexdigit() || b == b'-')
    {
        return None;
    }
    Some(key)
}

pub fn read(directory: &Path, now: f64) -> Option<ClaudeLocalQuotaSnapshot> {
    let mut latest: Option<ClaudeLocalQuotaSnapshot> = None;
    for (index, entry) in fs::read_dir(directory).ok()?.enumerate() {
        if index >= 20_000 {
            return None;
        }
        let Ok(entry) = entry else {
            return None;
        };
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.len() != 18
            || !name.ends_with("_0")
            || !name.as_bytes()[..16].iter().all(u8::is_ascii_hexdigit)
        {
            continue;
        }
        if !entry.file_type().ok()?.is_file() {
            continue;
        }
        let mut header = Vec::new();
        let Ok(file) = fs::File::open(entry.path()) else {
            continue;
        };
        if file.take(2048).read_to_end(&mut header).is_err() || usage_key(&header).is_none() {
            continue;
        }
        let Some(bytes) = read_file(&entry.path(), MAX_ENTRY) else {
            continue;
        };
        let Some(reading) = decode(&bytes, now) else {
            continue;
        };
        if latest
            .as_ref()
            .map_or(true, |old| reading.captured_at > old.captured_at)
        {
            latest = Some(reading);
        }
    }
    latest
}

pub fn select(
    history: ClaudeLocalQuotaSnapshot,
    cache: Option<ClaudeLocalQuotaSnapshot>,
) -> ClaudeLocalQuotaSnapshot {
    let timestamp = |value: &ClaudeLocalQuotaSnapshot| {
        value
            .captured_at
            .as_deref()
            .and_then(|s| OffsetDateTime::parse(s, &Rfc3339).ok())
            .map(|d| d.unix_timestamp_nanos())
    };
    match cache {
        Some(cache) if timestamp(&cache) >= timestamp(&history) => cache,
        _ => history,
    }
}

pub fn decode(bytes: &[u8], now: f64) -> Option<ClaudeLocalQuotaSnapshot> {
    if bytes.len() > MAX_ENTRY {
        return None;
    }
    let key = usage_key(bytes)?;
    let footer = bytes.len().checked_sub(24)?;
    if integer(bytes, footer, 8)? != EOF_MAGIC || integer(bytes, footer + 8, 4)? != 3 {
        return None;
    }
    let length = integer(bytes, footer + 16, 8)? as usize;
    if length > 65_536 {
        return None;
    }
    let metadata_end = footer.checked_sub(32)?;
    let metadata_start = metadata_end.checked_sub(length)?;
    let body_end = metadata_start.checked_sub(24)?;
    let body = bytes.get(24 + key.len()..body_end)?;
    let metadata = bytes.get(metadata_start..metadata_end)?;
    if bytes.get(metadata_end..footer)? != &Sha256::digest(key)[..]
        || integer(bytes, body_end, 8)? != EOF_MAGIC
        || integer(bytes, body_end + 8, 4)? != 1
        || integer(bytes, body_end + 16, 8)? != 0
        || integer(bytes, footer + 12, 4)? != crc32(metadata) as u64
        || integer(bytes, body_end + 12, 4)? != crc32(body) as u64
    {
        return None;
    }
    let marker = b"HTTP/1.1 200\0";
    let start = metadata.windows(marker.len()).position(|w| w == marker)?;
    let end = metadata[start..].windows(2).position(|w| w == [0, 0])? + start;
    let text = std::str::from_utf8(&metadata[start..end]).ok()?;
    let header = |name: &str| {
        text.split('\0')
            .skip(1)
            .filter_map(|line| line.split_once(':'))
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.trim())
    };
    if !header("content-type")?
        .to_ascii_lowercase()
        .starts_with("application/json")
    {
        return None;
    }
    let captured = OffsetDateTime::parse(header("date")?, &Rfc2822).ok()?;
    if !now.is_finite() || captured.unix_timestamp() as f64 > now + 60.0 {
        return None;
    }
    let mut result = ClaudeLocalQuotaSnapshot {
        source: Some(SOURCE.into()),
        state: "invalid".into(),
        captured_at: captured.format(&Rfc3339).ok(),
        five_hour: None,
        seven_day: None,
    };
    let decoded = match header("content-encoding")
        .unwrap_or("identity")
        .to_ascii_lowercase()
        .as_str()
    {
        "identity" if body.len() <= MAX_BODY => Some(body.to_vec()),
        "zstd" => decompress(body),
        _ => None,
    };
    let Some(root) = decoded.and_then(|data| serde_json::from_slice::<Value>(&data).ok()) else {
        return Some(result);
    };
    if !root.is_object() {
        return Some(result);
    }
    let window = |key: &str| -> Option<ClaudeLocalQuotaWindow> {
        let value = root.get(key)?;
        let used = value.get("utilization")?.as_f64()?;
        if !used.is_finite() || !(0.0..=100.0).contains(&used) {
            return None;
        }
        let reset = OffsetDateTime::parse(value.get("resets_at")?.as_str()?, &Rfc3339).ok()?;
        Some(ClaudeLocalQuotaWindow {
            used_percent: used,
            resets_at: reset.format(&Rfc3339).ok(),
        })
    };
    // Preserve the last sample across idle time and reset boundaries. The UI
    // labels passed resets as awaiting an update and never guesses new usage.
    result.five_hour = window("five_hour");
    result.seven_day = window("seven_day");
    result.state = if result.five_hour.is_some() || result.seven_day.is_some() {
        "available"
    } else {
        "missing"
    }.into();
    Some(result)
}

fn decompress(bytes: &[u8]) -> Option<Vec<u8>> {
    if zstd::zstd_safe::find_frame_compressed_size(bytes).ok()? != bytes.len() {
        return None;
    }
    let mut decoder = zstd::stream::read::Decoder::new(bytes).ok()?.single_frame();
    decoder.window_log_max(MAX_WINDOW_LOG).ok()?;
    let mut decoded = Vec::new();
    decoder
        .take(MAX_BODY as u64 + 1)
        .read_to_end(&mut decoded)
        .ok()?;
    (decoded.len() <= MAX_BODY).then_some(decoded)
}
