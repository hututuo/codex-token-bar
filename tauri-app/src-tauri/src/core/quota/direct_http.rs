use super::{accounts::Credential, rate_limits::{parse_rate_limits_with_plan, ParsedRateLimits}};
use serde_json::{json, Value};
use std::io::Read;
use std::time::Duration;

pub(super) fn fetch(credential: &Credential, reset: bool) -> Result<Value, String> {
    let endpoint = if reset { "rate-limit-reset-credits" } else { "usage" };
    let client = reqwest::blocking::Client::builder().timeout(Duration::from_secs(20))
        .connect_timeout(Duration::from_secs(8)).redirect(reqwest::redirect::Policy::none())
        .build().map_err(|error| format!("额度网络客户端初始化失败：{}", network_cause(error)))?;
    // Fixed official origin. Never send ChatGPT credentials to a configured model provider.
    let response = client.get(format!("https://chatgpt.com/backend-api/wham/{endpoint}"))
        .bearer_auth(&credential.access_token).header("Chatgpt-Account-Id", &credential.account_id)
        .header("Accept", "application/json").header("User-Agent", "CodexTokenBar")
        .send().map_err(|error| format!("{}（wham/{endpoint}）：{}",
            if error.is_timeout() { "额度请求超时" } else { "额度网络连接失败" }, network_cause(error)))?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}（wham/{endpoint}，Content-Type={}）", response.status().as_u16(),
            response.headers().get(reqwest::header::CONTENT_TYPE).and_then(|value| value.to_str().ok()).unwrap_or("未提供").chars().take(128).collect::<String>()));
    }
    let mut body = vec![];
    response.take(1_048_577).read_to_end(&mut body).map_err(|error| format!("额度响应读取失败（wham/{endpoint}）：{error}"))?;
    if body.len() > 1_048_576 { return Err("额度响应过大".into()); }
    serde_json::from_slice(&body).map_err(|error| format!("额度响应解析失败（wham/{endpoint}，{}字节，行{}列{}，类别{:?}）", body.len(), error.line(), error.column(), error.classify()))
}

fn network_cause(error: reqwest::Error) -> String {
    use std::error::Error;
    // Strip the request URL and never include headers, credentials or response bodies.
    let error = error.without_url();
    let mut causes = vec![error.to_string()];
    let mut source = error.source();
    for _ in 0..5 {
        let Some(cause) = source else { break; };
        causes.push(cause.to_string());
        source = cause.source();
    }
    causes.join(" -> ").chars().take(2048).collect()
}

pub(super) fn normalize(raw: &Value, now: i64) -> Value {
    fn window(raw: &Value, now: i64) -> Value {
        if !raw.is_object() { return Value::Null; }
        let reset = raw.get("reset_at").cloned().or_else(|| raw["reset_after_seconds"].as_i64().and_then(|s| now.checked_add(s)).map(Value::from));
        json!({"usedPercent": raw["used_percent"],
            "windowDurationMins": raw["limit_window_seconds"].as_f64().map(|v| v / 60.0).unwrap_or(0.0),
            "resetsAt": reset})
    }
    let card = |rate: &Value, id: &str, name: &Value| json!({
        "limitId": id, "limitName": name, "planType": raw["plan_type"],
        "primary": window(&rate["primary_window"], now),
        "secondary": window(&rate["secondary_window"], now),
        "ordinaryUsageAllowed": rate["allowed"]
    });
    let mut limits = serde_json::Map::new();
    if raw["rate_limit"].is_object() { limits.insert("codex".into(), card(&raw["rate_limit"], "codex", &Value::Null)); }
    if let Some(additional) = raw["additional_rate_limits"].as_array() {
        for entry in additional {
            if let Some(id) = entry["metered_feature"].as_str().filter(|id| !id.is_empty()) {
                if entry["rate_limit"].is_object() && !limits.contains_key(id) {
                    limits.insert(id.into(), card(&entry["rate_limit"], id, &entry["limit_name"]));
                }
            }
        }
    }
    json!({"rateLimitsByLimitId": limits, "planType": raw["plan_type"]})
}

pub(super) fn read(credential: &Credential) -> Result<ParsedRateLimits, String> {
    parse_rate_limits_with_plan(&normalize(&fetch(credential, false)?, time::OffsetDateTime::now_utc().unix_timestamp()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn wham_percent_scale_and_relative_reset_are_preserved() {
        let raw = json!({"rate_limit":{"allowed":true,"primary_window":{"used_percent":1,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1800086400}}});
        let parsed = parse_rate_limits_with_plan(&normalize(&raw, 1800000000)).unwrap();
        assert_eq!(parsed.quota.five_hour.used_percent, Some(0.01));
        assert_eq!(parsed.quota.five_hour.resets_at_unix, Some(1800000060));
        assert_eq!(parsed.quota.seven_day.used_percent, Some(0.4));
    }
    #[test] fn missing_ordinary_windows_do_not_borrow_reserve() {
        let raw = json!({"rate_limit":{"allowed":false},"additional_rate_limits":[{"metered_feature":"base_model_inference","limit_name":"gpt-reserve","rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}]});
        let parsed = parse_rate_limits_with_plan(&normalize(&raw, 1800000000)).unwrap();
        assert_eq!(parsed.quota.five_hour.used_percent, None);
        assert_eq!(parsed.quota.seven_day.used_percent, None);
        assert_eq!(parsed.quota.reserve_windows[0].remaining_percent, Some(0.75));
    }
}
