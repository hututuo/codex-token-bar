use crate::models::{QuotaLimit, QuotaSnapshot, ResetCreditSummary};
use serde_json::Value;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

fn placeholder_quota() -> QuotaSnapshot {
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

pub(super) fn parse_rate_limits(result: &Value) -> Result<QuotaSnapshot, String> {
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
    let reset_at_unix = value
        .get("resetsAt")
        .and_then(number)
        .map(|seconds| seconds.round() as i64);
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
                    "secondary": { "usedPercent": 0.2, "resetsAt": 1782144492 }
                }
            }
        });

        let quota = parse_rate_limits(&result).unwrap();
        assert_eq!(quota.five_hour.label, "5h");
        assert!((quota.five_hour.used_percent - 0.25).abs() < 0.001);
        assert!((quota.seven_day.remaining_percent - 0.8).abs() < 0.001);
    }
}
