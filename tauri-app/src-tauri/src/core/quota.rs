use crate::core::quota_history;
use crate::models::{
    AccountInfo, AccountQuotaBundle, QuotaLimit, QuotaSnapshot, ResetCreditSummary,
};
use auth::read_local_account_name;
use codex_binary::find_codex_binary;
use reset_credit::read_reset_credits;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{mpsc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

const SUCCESS_CACHE_TTL: Duration = Duration::from_secs(180);
const FAILURE_CACHE_TTL: Duration = Duration::from_secs(15);

mod auth;
mod codex_binary;
mod reset_credit;

static QUOTA_READ_CACHE: OnceLock<Mutex<Option<QuotaCacheEntry>>> = OnceLock::new();

#[derive(Clone)]
struct QuotaCacheEntry {
    codex_home: std::path::PathBuf,
    result: Result<AccountQuotaBundle, String>,
    cached_at: Instant,
}

pub fn read_account_quota(codex_home: &Path, force_refresh: bool) -> Result<AccountQuotaBundle, String> {
    let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(None));
    let mut guard = cache.lock().map_err(|error| error.to_string())?;
    if !force_refresh {
        if let Some(entry) = guard.as_ref() {
            if entry.codex_home == codex_home && entry.cached_at.elapsed() <= cache_ttl(&entry.result) {
                return match &entry.result {
                    Ok(bundle) => {
                        let mut cached = bundle.clone();
                        match quota_history::recent_history_24h() {
                            Ok(history) => cached.quota_history_24h = history,
                            Err(error) => cached.warnings.push(quota_history::warning(error)),
                        }
                        Ok(cached)
                    }
                    Err(error) => Err(error.clone()),
                };
            }
        }
    }

    let result = read_account_quota_uncached(codex_home);
    *guard = Some(QuotaCacheEntry {
        codex_home: codex_home.to_path_buf(),
        cached_at: Instant::now(),
        result: result.clone(),
    });
    result
}

fn cache_ttl(result: &Result<AccountQuotaBundle, String>) -> Duration {
    if result
        .as_ref()
        .is_ok_and(|bundle| quota_available(&bundle.quota))
    {
        SUCCESS_CACHE_TTL
    } else {
        FAILURE_CACHE_TTL
    }
}

fn quota_available(quota: &QuotaSnapshot) -> bool {
    quota.five_hour.resets_at_unix.is_some() || quota.seven_day.resets_at_unix.is_some()
}

fn read_account_quota_uncached(codex_home: &Path) -> Result<AccountQuotaBundle, String> {
    let mut bundle = match read_rate_limits() {
        Ok(mut quota) => {
            quota.reset_credit = read_reset_credits(codex_home).unwrap_or_else(|_| ResetCreditSummary {
                available_count: 0,
                status: "重置卡获取失败".into(),
                credits: Vec::new(),
            });
            let mut bundle = AccountQuotaBundle {
                account: account_info(codex_home, Some(&quota)),
                quota,
                quota_history_24h: Vec::new(),
                warnings: Vec::new(),
            };
            if let Err(error) = quota_history::record_bundle(&bundle) {
                bundle.warnings.push(quota_history::warning(error));
            }
            match quota_history::recent_history_24h() {
                Ok(history) => bundle.quota_history_24h = history,
                Err(error) => bundle.warnings.push(quota_history::warning(error)),
            }
            bundle
        }
        Err(error) => return Err(format!("额度读取失败：{error}")),
    };

    if bundle.quota.reset_credit.status == "重置卡待读取" {
        bundle.quota.reset_credit =
            read_reset_credits(codex_home).unwrap_or_else(|_| ResetCreditSummary {
                available_count: 0,
                status: "重置卡获取失败".into(),
                credits: Vec::new(),
            });
    }

    Ok(bundle)
}

pub fn placeholder_quota() -> QuotaSnapshot {
    QuotaSnapshot {
        five_hour: QuotaLimit {
            label: "5h".into(),
            remaining_percent: 0.0,
            used_percent: 0.0,
            resets_at: "待读取".into(),
            resets_at_unix: None,
        },
        seven_day: QuotaLimit {
            label: "7d".into(),
            remaining_percent: 0.0,
            used_percent: 0.0,
            resets_at: "待读取".into(),
            resets_at_unix: None,
        },
        reset_credit: ResetCreditSummary {
            available_count: 0,
            status: "重置卡待读取".into(),
            credits: Vec::new(),
        },
        pace_label: "额度待读取".into(),
    }
}

pub fn account_info(codex_home: &Path, quota: Option<&QuotaSnapshot>) -> AccountInfo {
    AccountInfo {
        display_name: read_local_account_name(codex_home).unwrap_or_else(|| "Codex Token Bar".into()),
        plan_label: quota
            .and_then(plan_label_from_quota)
            .unwrap_or_else(|| "Pro".into()),
    }
}

fn plan_label_from_quota(quota: &QuotaSnapshot) -> Option<String> {
    if quota.five_hour.resets_at != "待读取" || quota.seven_day.resets_at != "待读取" {
        Some("Pro".into())
    } else {
        None
    }
}

fn read_rate_limits() -> Result<QuotaSnapshot, String> {
    let codex = find_codex_binary().ok_or_else(|| "未找到 Codex".to_string())?;
    let mut child = Command::new(codex)
        .args(["app-server", "--listen", "stdio://"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("启动 Codex 失败：{error}"))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Codex stdout 不可用".to_string())?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "Codex stdin 不可用".to_string())?;
    let stderr = child.stderr.take();
    let (sender, receiver) = mpsc::channel();

    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                let _ = sender.send(value);
            }
        }
    });

    let cleanup = |child: &mut std::process::Child| {
        let _ = child.kill();
        let _ = child.wait();
    };

    write_json_line(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "codex-token-bar-tauri",
                    "title": "Codex Token Bar",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": false,
                    "requestAttestation": false
                }
            }
        }),
    )?;

    let deadline = Instant::now() + Duration::from_secs(8);
    let mut read_sent = false;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let Ok(message) = receiver.recv_timeout(remaining.min(Duration::from_millis(500))) else {
            continue;
        };

        if message.get("id").and_then(Value::as_i64) == Some(1)
            && message.get("result").is_some()
            && !read_sent
        {
            write_json_line(&mut stdin, &json!({"jsonrpc": "2.0", "method": "initialized"}))?;
            write_json_line(
                &mut stdin,
                &json!({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"}),
            )?;
            read_sent = true;
            continue;
        }

        if message.get("id").and_then(Value::as_i64) == Some(2) {
            cleanup(&mut child);
            if let Some(error) = message
                .get("error")
                .and_then(|value| value.get("message"))
                .and_then(Value::as_str)
            {
                return Err(error.to_string());
            }
            let result = message
                .get("result")
                .ok_or_else(|| "额度响应为空".to_string())?;
            return parse_rate_limits(result);
        }
    }

    cleanup(&mut child);
    if let Some(mut stderr) = stderr {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut text);
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            return Err(trimmed.to_string());
        }
    }
    Err("额度读取超时".into())
}

fn write_json_line(stdin: &mut std::process::ChildStdin, value: &Value) -> Result<(), String> {
    serde_json::to_writer(&mut *stdin, value).map_err(|error| error.to_string())?;
    stdin.write_all(b"\n").map_err(|error| error.to_string())
}

fn parse_rate_limits(result: &Value) -> Result<QuotaSnapshot, String> {
    let by_limit = result
        .get("rateLimitsByLimitId")
        .and_then(Value::as_object)
        .map(|object| {
            object
                .iter()
                .filter_map(|(id, value)| parse_limit_card(value, id))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let fallback_card = result
        .get("rateLimits")
        .and_then(|value| parse_limit_card(value, "codex"));
    let cards = if by_limit.is_empty() {
        fallback_card.into_iter().collect::<Vec<_>>()
    } else {
        by_limit
    };

    let codex = cards
        .iter()
        .find(|card| card.id == "codex")
        .or_else(|| cards.first())
        .ok_or_else(|| "额度暂无数据".to_string())?;
    let five_hour = codex.five_hour.clone().unwrap_or_else(|| placeholder_quota().five_hour);
    let seven_day = codex.seven_day.clone().unwrap_or_else(|| placeholder_quota().seven_day);

    Ok(QuotaSnapshot {
        pace_label: pace_label(&seven_day),
        five_hour,
        seven_day,
        reset_credit: ResetCreditSummary {
            available_count: 0,
            status: "重置卡待读取".into(),
            credits: Vec::new(),
        },
    })
}

#[derive(Clone, Debug)]
struct ParsedLimitCard {
    id: String,
    five_hour: Option<QuotaLimit>,
    seven_day: Option<QuotaLimit>,
}

fn parse_limit_card(value: &Value, fallback_id: &str) -> Option<ParsedLimitCard> {
    let id = value
        .get("limitId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback_id)
        .to_string();
    let five_hour = parse_window(value.get("primary"), "5h");
    let seven_day = parse_window(value.get("secondary"), "7d");
    if five_hour.is_none() && seven_day.is_none() {
        return None;
    }
    Some(ParsedLimitCard {
        id,
        five_hour,
        seven_day,
    })
}

fn parse_window(value: Option<&Value>, label: &str) -> Option<QuotaLimit> {
    let value = value?;
    let used = normalized_percent(value.get("usedPercent")?)?;
    let reset_at_unix = value.get("resetsAt").and_then(number).map(|seconds| seconds.round() as i64);
    let reset_at = reset_at_unix.and_then(|seconds| OffsetDateTime::from_unix_timestamp(seconds).ok());
    Some(QuotaLimit {
        label: label.into(),
        remaining_percent: (1.0 - used).clamp(0.0, 1.0),
        used_percent: used.clamp(0.0, 1.0),
        resets_at: reset_at
            .map(|date| compact_reset_text(date, label))
            .unwrap_or_else(|| "--:--".into()),
        resets_at_unix: reset_at_unix,
    })
}

fn normalized_percent(value: &Value) -> Option<f64> {
    let raw = number(value)?;
    if raw > 1.0 {
        Some(raw / 100.0)
    } else {
        Some(raw)
    }
}

fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_i64().map(|value| value as f64))
        .or_else(|| value.as_str().and_then(|value| value.parse::<f64>().ok()))
}

fn compact_reset_text(date: OffsetDateTime, label: &str) -> String {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let local = date.to_offset(local_offset);
    if label == "5h" {
        return format_time(local);
    }

    let now = OffsetDateTime::now_utc().to_offset(local_offset).date();
    if local.date() == now {
        return format_time(local);
    }
    local
        .format(format_description!("[month]/[day]"))
        .unwrap_or_else(|_| "--/--".into())
}

fn format_time(date: OffsetDateTime) -> String {
    date.format(format_description!("[hour]:[minute]"))
        .unwrap_or_else(|_| "--:--".into())
}

fn pace_label(seven_day: &QuotaLimit) -> String {
    let expected = expected_remaining_from_reset(&seven_day.resets_at, "7d");
    let Some(expected) = expected else {
        return "额度已更新".into();
    };
    let remaining = (seven_day.remaining_percent * 100.0).round() as i32;
    let delta = remaining - expected;
    if delta <= -20 {
        format!("使劲蹬，低 {}%", delta.abs())
    } else if delta < -5 {
        format!("慢一点，低 {}%", delta.abs())
    } else if delta >= 20 {
        format!("余量充足，多 {delta}%")
    } else if delta > 0 {
        format!("节奏稳，多 {delta}%")
    } else if delta < 0 {
        format!("贴线偏快，低 {}%", delta.abs())
    } else {
        "正好贴线".into()
    }
}

fn expected_remaining_from_reset(reset_text: &str, label: &str) -> Option<i32> {
    let duration_minutes = match label {
        "5h" => 300.0,
        "7d" => 10_080.0,
        _ => return None,
    };
    if reset_text == "待读取" || reset_text == "--:--" {
        return None;
    }
    // The compact 7d reset label may omit the time, so the pace label is a best-effort hint.
    if label == "7d" && !reset_text.contains(':') {
        return None;
    }
    let parts = reset_text.split(':').collect::<Vec<_>>();
    if parts.len() != 2 {
        return None;
    }
    let hour = parts[0].parse::<i64>().ok()?;
    let minute = parts[1].parse::<i64>().ok()?;
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let now = OffsetDateTime::now_utc().to_offset(local_offset);
    let reset_today = now
        .date()
        .with_hms(hour as u8, minute as u8, 0)
        .ok()?
        .assume_offset(local_offset);
    let reset = if reset_today < now {
        reset_today + time::Duration::days(1)
    } else {
        reset_today
    };
    let remaining_minutes = (reset - now).whole_minutes().max(0) as f64;
    let elapsed = ((duration_minutes - remaining_minutes) / duration_minutes).clamp(0.0, 1.0);
    Some((100.0 - elapsed * 100.0).round() as i32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rate_limits_by_limit_id() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "limitName": "Codex",
                    "planType": "pro",
                    "primary": { "usedPercent": 25, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 0.2, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert_eq!(quota.five_hour.label, "5h");
        assert!((quota.five_hour.used_percent - 0.25).abs() < 0.001);
        assert!((quota.seven_day.remaining_percent - 0.8).abs() < 0.001);
    }

    #[test]
    fn quota_cache_uses_short_ttl_for_failures() {
        let failure = Err("network unavailable".to_string());
        assert_eq!(cache_ttl(&failure), FAILURE_CACHE_TTL);

        let quota = parse_rate_limits(&json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "limitName": "Codex",
                    "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 0.4, "resetsAt": 1782144492 }
                }
            }
        }))
        .unwrap();
        let success = Ok(AccountQuotaBundle {
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota,
            quota_history_24h: Vec::new(),
            warnings: Vec::new(),
        });
        assert_eq!(cache_ttl(&success), SUCCESS_CACHE_TTL);
    }

}
