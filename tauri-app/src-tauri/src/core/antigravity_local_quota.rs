//! Existing IDE/Tools cache only. No RPC, credential use, refresh command, or source writes.
use super::{
    app_paths,
    local_quota_cache::read_file,
    multi_client_product::{QuotaProviderSnapshot, QuotaProviderWindow},
};
use base64::{engine::general_purpose::STANDARD, Engine};
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::Value;
use std::{
    fs,
    path::Path,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const MAX_BYTES: usize = 512 * 1024;
static CACHE: OnceLock<Mutex<Option<(Instant, QuotaProviderSnapshot)>>> = OnceLock::new();

pub fn empty(state: &str, source: &str) -> QuotaProviderSnapshot {
    QuotaProviderSnapshot {
        client: "antigravity".into(),
        state: state.into(),
        source: source.into(),
        captured_at: None,
        windows: Vec::new(),
        notice: "未读到可用的 Antigravity 本地额度缓存。只读已有文件，不启动客户端、不发网络请求。"
            .into(),
    }
}

pub fn read_cached(interval: Duration) -> QuotaProviderSnapshot {
    let now = Instant::now();
    let mut cache = CACHE
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|p| p.into_inner());
    if let Some((checked, reading)) = cache.as_ref() {
        if super::local_quota_cache::probe_is_fresh(*checked, now, interval) {
            return reading.clone();
        }
    }
    let home = app_paths::home_dir();
    let now = OffsetDateTime::now_utc().unix_timestamp() as f64;
    let tools = home.join(".antigravity_tools");
    let value = if tools.join("accounts.json").exists() {
        read_tools(&tools, now)
    } else {
        #[cfg(target_os = "macos")]
        let root = home.join("Library/Application Support");
        #[cfg(windows)]
        let root = std::env::var_os("APPDATA")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| home.join("AppData/Roaming"));
        #[cfg(not(any(target_os = "macos", windows)))]
        let root = std::env::var_os("XDG_CONFIG_HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| home.join(".config"));
        read_state(
            &root.join("Antigravity/User/globalStorage/state.vscdb"),
            now,
        )
    };
    *cache = Some((Instant::now(), value.clone()));
    value
}

pub fn read_tools(directory: &Path, now: f64) -> QuotaProviderSnapshot {
    let source = "local-antigravity-tools";
    let read = || -> Option<QuotaProviderSnapshot> {
        let root: Value =
            serde_json::from_slice(&read_file(&directory.join("accounts.json"), MAX_BYTES)?)
                .ok()?;
        let id = root.get("current_account_id")?.as_str()?;
        if id.is_empty()
            || id.len() > 128
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return None;
        }
        let accounts = root.get("accounts")?.as_array()?;
        if accounts.len() > 1024
            || !accounts
                .iter()
                .any(|a| a.get("id").and_then(Value::as_str) == Some(id))
        {
            return None;
        }
        Some(decode_tools(
            &read_file(
                &directory.join("accounts").join(format!("{id}.json")),
                MAX_BYTES,
            )?,
            id,
            now,
        ))
    };
    read().unwrap_or_else(|| empty("unavailable", source))
}

pub fn decode_tools(bytes: &[u8], selected_id: &str, now: f64) -> QuotaProviderSnapshot {
    let source = "local-antigravity-tools";
    let parse = || -> Option<QuotaProviderSnapshot> {
        if bytes.len() > MAX_BYTES {
            return None;
        }
        let root: Value = serde_json::from_slice(bytes).ok()?;
        if root.get("id")?.as_str()? != selected_id
            || root.get("disabled").and_then(Value::as_bool) == Some(true)
        {
            return None;
        }
        let quota = root.get("quota")?;
        if quota.get("is_forbidden").and_then(Value::as_bool) == Some(true) {
            return None;
        }
        let captured = quota.get("last_updated")?.as_f64()?;
        if !captured.is_finite() || captured <= 0.0 || captured > now + 60.0 {
            return None;
        }
        let models = quota.get("models")?.as_array()?;
        if models.len() > 128 {
            return None;
        }
        let mut seen = std::collections::HashSet::new();
        let windows: Vec<_> = models
            .iter()
            .filter_map(|model| {
                let id = model.get("name")?.as_str()?;
                if !valid_label(id) || !seen.insert(id) {
                    return None;
                }
                let remaining = model.get("percentage")?.as_f64()?;
                if !remaining.is_finite() || !(0.0..=100.0).contains(&remaining) {
                    return None;
                }
                let label = model
                    .get("display_name")
                    .and_then(Value::as_str)
                    .filter(|s| valid_label(s))
                    .unwrap_or(id);
                let reset = model
                    .get("reset_time")
                    .and_then(Value::as_str)
                    .and_then(|s| OffsetDateTime::parse(s, &Rfc3339).ok());
                Some(QuotaProviderWindow {
                    id: Some(id.into()),
                    label: label.into(),
                    used_percent: Some(100.0 - remaining),
                    resets_at: reset.and_then(|d| d.format(&Rfc3339).ok()),
                })
            })
            .collect();
        let stale = now - captured > 1200.0
            || windows.iter().any(|w| {
                w.resets_at
                    .as_ref()
                    .and_then(|s| OffsetDateTime::parse(s, &Rfc3339).ok())
                    .map_or(true, |d| d.unix_timestamp() as f64 <= now)
            });
        Some(QuotaProviderSnapshot { client: "antigravity".into(), state: if windows.is_empty() { "unavailable" } else if stale { "stale" } else { "available" }.into(),
            source: source.into(), captured_at: OffsetDateTime::from_unix_timestamp(captured as i64).ok().and_then(|d| d.format(&Rfc3339).ok()), windows,
            notice: format!("Antigravity Tools 所选账号的本地采样；未验证与当前 Antigravity 账号一致。逐模型展示，不合计余额。{}", if stale { "采样已过期，不作为当前余额。" } else { "" }) })
    };
    parse().unwrap_or_else(|| empty("unavailable", source))
}

pub fn read_state(path: &Path, now: f64) -> QuotaProviderSnapshot {
    let source = "local-antigravity-state";
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return empty("notConnected", source);
    };
    if !metadata.is_file() {
        return empty("unavailable", source);
    }
    let read = || -> Result<Option<String>, rusqlite::Error> {
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(Duration::from_millis(250))?;
        connection.query_row("SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.userStatus' AND length(CAST(value AS BLOB)) <= 524288 LIMIT 1", [], |row| row.get(0)).optional()
    };
    match read() {
        Ok(Some(value)) => decode_state(value.as_bytes(), now),
        Ok(None) => empty("notConnected", source),
        Err(_) => empty("unavailable", source),
    }
}

pub fn decode_state(bytes: &[u8], now: f64) -> QuotaProviderSnapshot {
    let source = "local-antigravity-state";
    let parse = || -> Option<Vec<QuotaProviderWindow>> {
        if bytes.len() > MAX_BYTES {
            return None;
        }
        let outer = STANDARD.decode(bytes).ok()?;
        let envelope = fields(&outer)?;
        let entry = fields(data(&envelope, 1)?)?;
        let wrapped = fields(data(&entry, 2)?)?;
        let status = STANDARD.decode(data(&wrapped, 1)?).ok()?;
        let user = fields(&status)?;
        let configs = fields(data(&user, 33)?)?;
        let mut windows = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for field in configs.iter().filter(|f| f.tag == 1) {
            if windows.len() >= 128 {
                return None;
            }
            let one = || -> Option<QuotaProviderWindow> {
                let model = fields(field.bytes?)?;
                let label = std::str::from_utf8(data(&model, 1)?).ok()?;
                if !valid_label(label) {
                    return None;
                }
                let ids = fields(data(&model, 2)?)?;
                let id = ids.iter().find(|f| f.tag == 1)?.integer?;
                let quota = fields(data(&model, 15)?)?;
                let remaining = match quota.iter().find(|f| f.tag == 1) {
                    Some(field) => field.float?,
                    None => 0.0,
                };
                if !remaining.is_finite() || !(0.0..=1.0).contains(&remaining) {
                    return None;
                }
                let reset = data(&quota, 2)
                    .and_then(fields)
                    .and_then(|f| f.iter().find(|f| f.tag == 1)?.integer)
                    .and_then(|epoch| i64::try_from(epoch).ok())
                    .and_then(|epoch| OffsetDateTime::from_unix_timestamp(epoch).ok());
                Some(QuotaProviderWindow {
                    id: Some(format!("model-{id}")),
                    label: label.into(),
                    used_percent: Some((1.0 - remaining as f64) * 100.0),
                    resets_at: reset.and_then(|d| d.format(&Rfc3339).ok()),
                })
            };
            if let Some(window) = one() {
                if seen.insert(window.id.clone()) {
                    windows.push(window);
                }
            }
        }
        Some(windows)
    };
    let Some(windows) = parse() else {
        return empty("unavailable", source);
    };
    let stale = windows.iter().any(|w| {
        w.resets_at
            .as_ref()
            .and_then(|s| OffsetDateTime::parse(s, &Rfc3339).ok())
            .is_some_and(|d| d.unix_timestamp() as f64 <= now)
    });
    QuotaProviderSnapshot { client: "antigravity".into(), state: if windows.is_empty() { "unavailable" } else if stale { "stale" } else { "cached" }.into(),
        source: source.into(), captured_at: None, windows,
        notice: "Antigravity IDE 本地模型额度缓存；未验证当前账号。此格式没有采样时间，数据库修改时间不代表额度刷新，不能作为实时余额。".into() }
}

fn valid_label(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control)
}
#[derive(Default)]
struct Field<'a> {
    tag: u64,
    bytes: Option<&'a [u8]>,
    integer: Option<u64>,
    float: Option<f32>,
}
fn data<'a>(fields: &[Field<'a>], tag: u64) -> Option<&'a [u8]> {
    fields.iter().find(|f| f.tag == tag)?.bytes
}
fn fields(bytes: &[u8]) -> Option<Vec<Field<'_>>> {
    if bytes.len() > MAX_BYTES {
        return None;
    }
    let mut offset = 0;
    let mut result = Vec::new();
    fn varint(bytes: &[u8], offset: &mut usize) -> Option<u64> {
        let mut value = 0;
        for shift in (0..=63).step_by(7) {
            let byte = *bytes.get(*offset)?;
            *offset += 1;
            if shift == 63 && byte > 1 {
                return None;
            }
            value |= ((byte & 127) as u64) << shift;
            if byte & 128 == 0 {
                return Some(value);
            }
        }
        None
    }
    while offset < bytes.len() {
        let tag = varint(bytes, &mut offset)?;
        if tag >> 3 == 0 || tag >> 3 > 0x1fffffff || result.len() >= 2048 {
            return None;
        }
        let mut field = Field {
            tag: tag >> 3,
            ..Default::default()
        };
        match tag & 7 {
            0 => field.integer = Some(varint(bytes, &mut offset)?),
            2 => {
                let size = usize::try_from(varint(bytes, &mut offset)?).ok()?;
                field.bytes = Some(bytes.get(offset..offset.checked_add(size)?)?);
                offset += size;
            }
            5 => {
                field.float = Some(f32::from_le_bytes(
                    bytes.get(offset..offset + 4)?.try_into().ok()?,
                ));
                offset += 4;
            }
            1 => {
                bytes.get(offset..offset + 8)?;
                offset += 8;
            }
            _ => return None,
        }
        result.push(field);
    }
    Some(result)
}
