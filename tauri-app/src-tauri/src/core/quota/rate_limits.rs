use crate::models::{QuotaLimit, QuotaSnapshot, ResetCreditSummary};
use serde_json::Value;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

pub(super) fn placeholder_quota() -> QuotaSnapshot {
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

pub(super) struct ParsedRateLimits {
    pub quota: QuotaSnapshot,
    pub plan_label: Option<String>,
}

#[cfg(test)]
pub(super) fn parse_rate_limits(result: &Value) -> Result<QuotaSnapshot, String> {
    Ok(parse_rate_limits_with_plan(result)?.quota)
}

pub(super) fn parse_rate_limits_with_plan(result: &Value) -> Result<ParsedRateLimits, String> {
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
    let five_hour = codex
        .five_hour
        .clone()
        .unwrap_or_else(|| placeholder_quota().five_hour);
    let seven_day = codex
        .seven_day
        .clone()
        .unwrap_or_else(|| placeholder_quota().seven_day);

    Ok(ParsedRateLimits {
        plan_label: parse_plan_label(result),
        quota: QuotaSnapshot {
            pace_label: pace_label(&seven_day),
            five_hour,
            seven_day,
            reset_credit: ResetCreditSummary {
                available_count: 0,
                status: "重置卡待读取".into(),
                credits: Vec::new(),
            },
        },
    })
}

pub(super) fn parse_plan_label(result: &Value) -> Option<String> {
    plan_label_from_object(result).or_else(|| {
        result
            .get("rateLimitsByLimitId")
            .and_then(Value::as_object)
            .and_then(|object| {
                object
                    .get("codex")
                    .or_else(|| object.values().next())
                    .and_then(plan_label_from_object)
            })
            .or_else(|| result.get("rateLimits").and_then(plan_label_from_object))
    })
}

fn plan_label_from_object(value: &Value) -> Option<String> {
    [
        "planLabel",
        "plan_label",
        "planName",
        "plan_name",
        "tier",
        "planType",
        "plan_type",
        "accountPlan",
        "account_plan",
        "subscriptionPlan",
        "subscription_plan",
    ]
    .into_iter()
    .filter_map(|key| value.get(key).and_then(Value::as_str))
    .filter_map(format_plan_label)
    .next()
}

fn format_plan_label(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let normalized = trimmed
        .to_ascii_lowercase()
        .replace([' ', '-', '_'], "");
    match normalized.as_str() {
        "plus" | "chatgptplus" => Some("Plus".into()),
        "pro" | "chatgptpro" => Some("Pro".into()),
        "team" | "teams" | "business" => Some("Team".into()),
        "enterprise" => Some("Enterprise".into()),
        "free" => Some("Free".into()),
        "unknown" | "none" | "null" => None,
        _ => Some(trimmed.to_string()),
    }
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
    let used_percent = value.get("usedPercent")?;
    let used = normalized_percent(used_percent, uses_percent_scale(value, used_percent))?;
    let reset_at_unix = value
        .get("resetsAt")
        .and_then(normalized_unix_timestamp_seconds);
    let reset_at =
        reset_at_unix.and_then(|seconds| OffsetDateTime::from_unix_timestamp(seconds).ok());
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

fn uses_percent_scale(window: &Value, used_percent: &Value) -> bool {
    window.get("windowDurationMins").is_some()
        || number(used_percent).is_some_and(|raw| raw > 1.0)
}

fn normalized_percent(value: &Value, percent_scale: bool) -> Option<f64> {
    let raw = number(value)?;
    if percent_scale {
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

fn normalized_unix_timestamp_seconds(value: &Value) -> Option<i64> {
    let raw = number(value)?;
    let seconds = if raw.abs() > 10_000_000_000.0 {
        raw / 1000.0
    } else {
        raw
    };
    Some(seconds.round() as i64)
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
    let expected = expected_remaining_from_reset_unix(seven_day.resets_at_unix, 7 * 24 * 60);
    let Some(expected) = expected else {
        return "额度已更新".into();
    };
    let remaining = (seven_day.remaining_percent * 100.0).round() as i32;
    let delta = remaining - expected;
    let hours_left = hours_until(seven_day.resets_at_unix);

    if hours_left.is_some_and(|hours| hours <= 24.0) && delta >= 8 {
        return format!("最后一天，可以冲（多 {delta}%）");
    }
    if delta <= -20 {
        format!("用得太快，先省着（低 {}%）", delta.abs())
    } else if delta <= -10 {
        format!("用得偏快，慢一点（低 {}%）", delta.abs())
    } else if delta < -3 {
        format!("略快，贴线用（低 {}%）", delta.abs())
    } else if delta >= 20 {
        format!("余量很足，使劲蹬（多 {delta}%）")
    } else if delta >= 8 {
        format!("节奏很好，可以冲（多 {delta}%）")
    } else if delta > 3 {
        format!("略有余量（多 {delta}%）")
    } else if delta < 0 {
        format!("贴近均速，稍快 {}%", delta.abs())
    } else {
        "正好贴着均速线".into()
    }
}

fn expected_remaining_from_reset_unix(reset_unix: Option<i64>, duration_minutes: i64) -> Option<i32> {
    let reset_unix = reset_unix?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let remaining_minutes = ((reset_unix - now).max(0) / 60).min(duration_minutes) as f64;
    let expected = remaining_minutes / duration_minutes as f64 * 100.0;
    Some(expected.round() as i32)
}

fn hours_until(reset_unix: Option<i64>) -> Option<f64> {
    let reset_unix = reset_unix?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    Some(((reset_unix - now).max(0) as f64) / 3600.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_rate_limits_by_limit_id() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "limitName": "Codex",
                    "planType": "pro",
                    "primary": { "usedPercent": 25, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 20, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert_eq!(quota.five_hour.label, "5h");
        assert!((quota.five_hour.used_percent - 0.25).abs() < 0.001);
        assert!((quota.seven_day.remaining_percent - 0.8).abs() < 0.001);
    }

    #[test]
    fn parses_plan_label_from_account_rate_limit_payload() {
        let plus = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "planType": "plus",
                    "primary": { "usedPercent": 25, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 20, "resetsAt": 1782144492 }
                }
            }
        });
        let pro = json!({ "rateLimits": { "tier": "pro" } });
        let team = json!({ "plan_label": "Team" });
        let unknown = json!({ "rateLimitsByLimitId": { "codex": { "planType": "unknown" } } });

        assert_eq!(parse_plan_label(&plus), Some("Plus".into()));
        assert_eq!(parse_plan_label(&pro), Some("Pro".into()));
        assert_eq!(parse_plan_label(&team), Some("Team".into()));
        assert_eq!(parse_plan_label(&unknown), None);
    }

    #[test]
    fn keeps_second_reset_timestamp_as_unix_seconds() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 25, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 20, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert_eq!(quota.five_hour.resets_at_unix, Some(1781715600));
        assert_eq!(quota.seven_day.resets_at_unix, Some(1782144492));
    }

    #[test]
    fn normalizes_millisecond_reset_timestamp_to_unix_seconds() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 25, "resetsAt": 1781715600000_i64 },
                    "secondary": { "usedPercent": 20, "resetsAt": 1782144492000_i64 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert_eq!(quota.five_hour.resets_at_unix, Some(1781715600));
        assert_eq!(quota.seven_day.resets_at_unix, Some(1782144492));
    }

    #[test]
    fn mixed_fractional_primary_and_percent_secondary_use_independent_scales() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 0.25, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert!((quota.five_hour.used_percent - 0.25).abs() < 0.001);
        assert!((quota.seven_day.used_percent - 0.20).abs() < 0.001);
    }

    #[test]
    fn mixed_percent_primary_and_fractional_secondary_use_independent_scales() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 0.2, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert!((quota.five_hour.used_percent - 0.25).abs() < 0.001);
        assert!((quota.seven_day.used_percent - 0.20).abs() < 0.001);
    }

    #[test]
    fn parses_one_percent_as_percent_not_full_usage() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 1, "windowDurationMins": 300, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 50, "windowDurationMins": 10080, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert!((quota.five_hour.used_percent - 0.01).abs() < 0.001);
        assert!((quota.five_hour.remaining_percent - 0.99).abs() < 0.001);
        assert!((quota.seven_day.used_percent - 0.50).abs() < 0.001);
    }

    #[test]
    fn parses_seven_day_one_percent_as_percent_not_full_usage() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 1, "windowDurationMins": 10080, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert!((quota.five_hour.used_percent - 0.10).abs() < 0.001);
        assert!((quota.seven_day.used_percent - 0.01).abs() < 0.001);
        assert!((quota.seven_day.remaining_percent - 0.99).abs() < 0.001);
    }

    #[test]
    fn preserves_legacy_fractional_percent_scale() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 1.0, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 0.2, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert!((quota.five_hour.used_percent - 1.0).abs() < 0.001);
        assert!((quota.five_hour.remaining_percent - 0.0).abs() < 0.001);
        assert!((quota.seven_day.used_percent - 0.20).abs() < 0.001);
    }

    #[test]
    fn pace_label_warns_when_seven_day_usage_is_too_fast() {
        let seven_day = QuotaLimit {
            label: "7d".into(),
            remaining_percent: 0.70,
            used_percent: 0.30,
            resets_at: "7d".into(),
            resets_at_unix: Some(OffsetDateTime::now_utc().unix_timestamp() + 7 * 24 * 60 * 60),
        };

        assert!(pace_label(&seven_day).starts_with("用得太快，先省着"));
    }

    #[test]
    fn pace_label_encourages_when_seven_day_has_extra_room() {
        let seven_day = QuotaLimit {
            label: "7d".into(),
            remaining_percent: 1.0,
            used_percent: 0.0,
            resets_at: "7d".into(),
            resets_at_unix: Some(OffsetDateTime::now_utc().unix_timestamp() + 5 * 24 * 60 * 60),
        };

        assert!(pace_label(&seven_day).starts_with("余量很足，使劲蹬"));
    }
}
