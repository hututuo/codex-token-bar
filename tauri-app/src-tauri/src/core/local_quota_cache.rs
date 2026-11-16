//! Provider-owned files only: no HTTP client, credentials, process launch, or business DB open.
use std::{
    fs,
    io::Read,
    path::Path,
    time::{Duration, Instant},
};

/// Stable history identity, without storing an organization ID in the ledger.
pub fn scoped_source(source: &str, organization: Option<&str>) -> String {
    use sha2::{Digest, Sha256};
    let Some(org) = organization.map(str::trim).filter(|v| !v.is_empty()
        && v.len() <= 256 && !v.chars().any(char::is_control)) else { return source.into(); };
    let digest = Sha256::digest(format!("claude-org:v1:{}", org.to_lowercase()).as_bytes());
    format!("{source}@scope:{digest:x}")
}

pub fn base_source(source: &str) -> &str {
    match source.split_once("@scope:") {
        Some((base, digest)) if digest.len() == 64 && digest.bytes().all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v)) => base,
        _ => source,
    }
}

/// Use the existing main-page quota setting for every offline provider cache.
pub fn probe_interval() -> Duration {
    let milliseconds = crate::platform::read_app_settings()
        .map(|settings| settings.quota_refresh_interval_ms)
        .unwrap_or_else(|_| {
            crate::models::AppSettingsSnapshot::default().quota_refresh_interval_ms
        });
    Duration::from_millis(milliseconds)
}

pub fn automatic_probe_interval() -> Duration {
    // The scheduled tick uses the same short reuse policy as the main quota.
    // Passive usage reads still retain the full configured interval.
    super::quota::success_freshness_for_cadence_ms(probe_interval().as_millis() as u64)
}

pub fn probe_is_fresh(checked: Instant, now: Instant, interval: Duration) -> bool {
    now.saturating_duration_since(checked) < interval
}

pub fn read_file(path: &Path, limit: usize) -> Option<Vec<u8>> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > limit as u64 {
        return None;
    }
    let mut bytes = Vec::new();
    fs::File::open(path)
        .ok()?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() <= limit).then_some(bytes)
}

pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= *byte as u32;
        for _ in 0..8 {
            crc = (crc >> 1) ^ if crc & 1 == 0 { 0 } else { 0xedb88320 };
        }
    }
    !crc
}
