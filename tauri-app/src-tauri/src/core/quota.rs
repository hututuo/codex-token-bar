use crate::core::quota_history;
use crate::models::{
    AccountInfo, AccountQuotaBundle, QuotaLimit, QuotaSnapshot, ResetCreditDetail,
    ResetCreditSummary,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

pub fn read_account_quota(codex_home: &Path) -> Result<AccountQuotaBundle, String> {
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
            };
            quota_history::record_bundle(&bundle);
            bundle.quota_history_24h = quota_history::recent_history_24h();
            bundle
        }
        Err(error) => {
            let mut bundle = placeholder_bundle(codex_home);
            bundle.quota.pace_label = format!("额度读取失败：{error}");
            bundle.quota_history_24h = quota_history::recent_history_24h();
            bundle
        }
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

pub fn placeholder_bundle(codex_home: &Path) -> AccountQuotaBundle {
    let quota = placeholder_quota();
    AccountQuotaBundle {
        account: account_info(codex_home, Some(&quota)),
        quota,
        quota_history_24h: quota_history::recent_history_24h(),
    }
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

fn read_reset_credits(codex_home: &Path) -> Result<ResetCreditSummary, String> {
    let token = read_access_token(codex_home).ok_or_else(|| "未找到 access token".to_string())?;
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(8))
        .no_gzip()
        .build()
        .map_err(|error| error.to_string())?;
    let response = client
        .get("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        .bearer_auth(token)
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::USER_AGENT, "CodexTokenBar")
        .send()
        .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    let value = response.json::<Value>().map_err(|error| error.to_string())?;
    let credits = value
        .get("credits")
        .and_then(Value::as_array)
        .map(|credits| {
            credits
                .iter()
                .enumerate()
                .map(|(index, credit)| parse_reset_credit_detail(credit, index))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let available = value
        .get("available_count")
        .and_then(|value| value.as_u64())
        .or_else(|| Some(credits.iter().filter(|credit| credit.status == "可用").count() as u64))
        .unwrap_or(0);
    let available_count = u32::try_from(available).unwrap_or(u32::MAX);
    Ok(ResetCreditSummary {
        available_count,
        status: if available_count == 0 {
            "0 张重置卡".into()
        } else {
            format!("{available_count} 张重置卡可用")
        },
        credits,
    })
}

fn parse_reset_credit_detail(value: &Value, index: usize) -> ResetCreditDetail {
    let status_raw = text_from_keys(value, &["status"]).unwrap_or_else(|| "unknown".into());
    let status = human_reset_status(&status_raw, value);
    let issued_at = time_from_keys(
        value,
        &[
            "issued_at",
            "issuedAt",
            "created_at",
            "createdAt",
            "granted_at",
            "grantedAt",
        ],
    );
    let expires_at = time_from_keys(value, &["expires_at", "expiresAt", "expiration", "expires"]);
    let redeemed_at = {
        let value = time_from_keys(value, &["redeemed_at", "redeemedAt", "used_at", "usedAt"]);
        if value == "未提供" && status != "已使用" {
            "未使用".into()
        } else {
            value
        }
    };
    let source = text_from_keys(value, &["source", "grant_source", "grantSource", "origin", "reason"])
        .unwrap_or_else(|| "未提供".into());
    let associated_user = associated_user_label(value).unwrap_or_else(|| "未提供".into());
    let short_id = text_from_keys(
        value,
        &["id", "credit_id", "creditId", "reset_credit_id", "resetCreditId"],
    )
    .map(|id| short_identifier(&id))
    .unwrap_or_else(|| "未提供".into());
    let summary = [
        format!("状态 {status}"),
        format!("到期 {expires_at}"),
        format!("关联 {associated_user}"),
    ]
    .join(" · ");

    ResetCreditDetail {
        title: format!("重置卡 {}", index + 1),
        status,
        summary,
        issued_at,
        expires_at,
        redeemed_at,
        source,
        associated_user,
        short_id,
    }
}

fn human_reset_status(status: &str, value: &Value) -> String {
    if value.get("redeemed_at").is_some_and(|value| !value.is_null())
        || value.get("redeemedAt").is_some_and(|value| !value.is_null())
    {
        return "已使用".into();
    }

    match status {
        "available" | "active" | "unused" => "可用".into(),
        "redeemed" | "used" | "consumed" => "已使用".into(),
        "expired" => "已过期".into(),
        "pending" => "待生效".into(),
        other if other.trim().is_empty() => "未知".into(),
        other => other.to_string(),
    }
}

fn associated_user_label(value: &Value) -> Option<String> {
    text_from_keys(
        value,
        &[
            "user_name",
            "userName",
            "user_email",
            "userEmail",
            "email",
            "user_id",
            "userId",
            "account_id",
            "accountId",
        ],
    )
    .or_else(|| {
        value.get("user").and_then(|user| {
            text_from_keys(user, &["name", "email", "id", "user_id", "userId"])
        })
    })
    .or_else(|| {
        ["associated_users", "associatedUsers", "users", "accounts"]
            .iter()
            .find_map(|key| labels_from_array(value.get(*key)?))
    })
}

fn time_from_keys(value: &Value, keys: &[&str]) -> String {
    keys.iter()
        .find_map(|key| value.get(*key))
        .and_then(parse_time)
        .map(format_reset_credit_time)
        .unwrap_or_else(|| "未提供".into())
}

fn parse_time(value: &Value) -> Option<OffsetDateTime> {
    if value.is_null() {
        return None;
    }

    if let Some(number) = number(value) {
        let seconds = if number > 10_000_000_000.0 {
            number / 1000.0
        } else {
            number
        };
        return OffsetDateTime::from_unix_timestamp(seconds.round() as i64).ok();
    }

    let text = value.as_str()?.trim();
    if text.is_empty() {
        return None;
    }
    OffsetDateTime::parse(text, &Rfc3339).ok()
}

fn format_reset_credit_time(date: OffsetDateTime) -> String {
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    date.to_offset(local_offset)
        .format(format_description!("[year]-[month]-[day] [hour]:[minute]"))
        .unwrap_or_else(|_| "未提供".into())
}

fn text_from_keys(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key))
        .and_then(text_from_value)
        .filter(|text| !text.is_empty())
}

fn labels_from_array(value: &Value) -> Option<String> {
    let labels = value
        .as_array()?
        .iter()
        .filter_map(|item| {
            text_from_value(item).or_else(|| {
                text_from_keys(
                    item,
                    &[
                        "name",
                        "email",
                        "id",
                        "user_id",
                        "userId",
                        "account_id",
                        "accountId",
                    ],
                )
            })
        })
        .collect::<Vec<_>>();
    if labels.is_empty() {
        None
    } else {
        Some(labels.join("、"))
    }
}

fn text_from_value(value: &Value) -> Option<String> {
    if let Some(text) = value.as_str() {
        return Some(text.trim().to_string());
    }
    if let Some(number) = value.as_i64() {
        return Some(number.to_string());
    }
    if let Some(number) = value.as_u64() {
        return Some(number.to_string());
    }
    if let Some(flag) = value.as_bool() {
        return Some(if flag { "是" } else { "否" }.into());
    }
    None
}

fn short_identifier(id: &str) -> String {
    let trimmed = id.trim();
    if trimmed.chars().count() <= 10 {
        return trimmed.to_string();
    }
    let start = trimmed.chars().take(6).collect::<String>();
    let end = trimmed
        .chars()
        .rev()
        .take(4)
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    format!("{start}...{end}")
}

fn read_access_token(codex_home: &Path) -> Option<String> {
    let auth = read_auth_json(codex_home)?;
    let token = auth
        .get("tokens")
        .and_then(|tokens| tokens.get("access_token"))
        .and_then(Value::as_str)?
        .trim()
        .to_string();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

fn read_local_account_name(codex_home: &Path) -> Option<String> {
    let auth = read_auth_json(codex_home)?;
    let token = auth
        .get("tokens")
        .and_then(|tokens| tokens.get("id_token"))
        .and_then(Value::as_str)?;
    let payload = decode_jwt_payload(token)?;
    ["name", "nickname", "preferred_username", "email"]
        .iter()
        .filter_map(|key| payload.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(str::to_string)
}

fn read_auth_json(codex_home: &Path) -> Option<Value> {
    let data = std::fs::read(codex_home.join("auth.json")).ok()?;
    serde_json::from_slice(&data).ok()
}

fn decode_jwt_payload(token: &str) -> Option<BTreeMap<String, Value>> {
    let payload = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn find_codex_binary() -> Option<String> {
    let mut candidates = vec![
        "/Applications/Codex.app/Contents/Resources/codex".to_string(),
        format!(
            "{}/Applications/Codex.app/Contents/Resources/codex",
            std::env::var("HOME").unwrap_or_default()
        ),
        "/opt/homebrew/bin/codex".into(),
        "/usr/local/bin/codex".into(),
    ];
    if cfg!(target_os = "windows") {
        candidates.push("codex.exe".into());
    } else {
        candidates.push("codex".into());
    }

    candidates.into_iter().find(|candidate| {
        if candidate.contains('/') || candidate.contains('\\') {
            Path::new(candidate).is_file()
        } else {
            command_exists(candidate)
        }
    })
}

fn command_exists(command: &str) -> bool {
    let Some(paths) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&paths).any(|path| path.join(command).is_file())
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
    fn parses_reset_credit_detail_into_human_fields() {
        let credit = json!({
            "status": "available",
            "created_at": "2026-06-12T01:00:00Z",
            "expires_at": "2026-06-20T01:00:00Z",
            "source": "system_grant",
            "associatedUsers": [{ "email": "local-account@codex.local" }],
            "id": "reset-credit-abcdef123456"
        });

        let detail = parse_reset_credit_detail(&credit, 0);
        assert_eq!(detail.title, "重置卡 1");
        assert_eq!(detail.status, "可用");
        assert_eq!(detail.redeemed_at, "未使用");
        assert_eq!(detail.source, "system_grant");
        assert_eq!(detail.associated_user, "local-account@codex.local");
        assert_eq!(detail.short_id, "reset-...3456");
        assert!(detail.issued_at.starts_with("2026-06-12 "));
        assert!(detail.expires_at.starts_with("2026-06-20 "));
    }

    #[test]
    fn decodes_account_name_from_auth_jwt() {
        let payload =
            URL_SAFE_NO_PAD.encode(r#"{"name":"本地用户","email":"local-account@codex.local"}"#);
        let decoded = decode_jwt_payload(&format!("header.{payload}.signature")).unwrap();
        assert_eq!(decoded.get("name").and_then(Value::as_str), Some("本地用户"));
    }
}
