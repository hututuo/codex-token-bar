use crate::models::{ResetCreditDetail, ResetCreditSummary};
use serde_json::Value;
use time::format_description::well_known::Rfc3339;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

pub(super) fn parse_reset_credit_summary(value: &Value) -> ResetCreditSummary {
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
        .or_else(|| {
            Some(
                credits
                    .iter()
                    .filter(|credit| is_counted_available_credit(credit))
                    .count() as u64,
            )
        })
        .unwrap_or(0);
    let available_count = u32::try_from(available).unwrap_or(u32::MAX);
    ResetCreditSummary {
        available_count,
        status: if available_count == 0 {
            "0 张重置卡".into()
        } else {
            format!("{available_count} 张重置卡可用")
        },
        credits,
    }
}

fn parse_reset_credit_detail(value: &Value, index: usize) -> ResetCreditDetail {
    let status_raw = text_from_keys(value, &["status"]).unwrap_or_else(|| "unknown".into());
    let status = human_reset_status(&status_raw, value);
    let title = text_from_keys(value, &["title", "name", "label"])
        .unwrap_or_else(|| format!("重置卡 {}", index + 1));
    let reset_type = text_from_keys(value, &["reset_type", "resetType", "type", "kind"])
        .unwrap_or_else(|| "未提供".into());
    let granted_at = parsed_time_from_keys(
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
    let issued_at = granted_at
        .map(format_reset_credit_time)
        .unwrap_or_else(|| "未提供".into());
    let expires_at_date =
        parsed_time_from_keys(value, &["expires_at", "expiresAt", "expiration", "expires"]);
    let expires_at = expires_at_date
        .map(format_reset_credit_time)
        .unwrap_or_else(|| "未提供".into());
    let redeem_started_at = time_from_keys(
        value,
        &[
            "redeem_started_at",
            "redeemStartedAt",
            "redeem_start_at",
            "redeemStartAt",
        ],
    );
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
    let detail_note = text_from_keys(
        value,
        &[
            "description",
            "detail",
            "details",
            "note",
            "reason",
            "grant_reason",
            "grantReason",
        ],
    )
    .unwrap_or_else(|| "未提供".into());
    let profile_image_url = text_from_keys(
        value,
        &[
            "profile_image_url",
            "profileImageUrl",
            "avatar_url",
            "avatarUrl",
            "image_url",
            "imageUrl",
        ],
    )
    .unwrap_or_else(|| "未提供".into());
    let card_id = text_from_keys(
        value,
        &["id", "credit_id", "creditId", "reset_credit_id", "resetCreditId"],
    )
    .unwrap_or_else(|| "未提供".into());
    let short_id = if card_id == "未提供" {
        "未提供".into()
    } else {
        short_identifier(&card_id)
    };
    let summary = [
        format!("状态 {status}"),
        format!("类型 {reset_type}"),
        format!("到期 {expires_at}"),
        format!("关联 {associated_user}"),
        format!("说明 {detail_note}"),
    ]
    .join(" · ");

    ResetCreditDetail {
        card_id,
        title,
        status,
        summary,
        reset_type,
        issued_at,
        granted_at_unix: granted_at.map(|date| date.unix_timestamp()),
        expires_at,
        expires_at_unix: expires_at_date.map(|date| date.unix_timestamp()),
        redeem_started_at,
        redeemed_at,
        source,
        detail_note,
        associated_user,
        profile_image_url,
        short_id,
    }
}

fn human_reset_status(status: &str, value: &Value) -> String {
    if value.get("redeemed_at").is_some_and(|value| !value.is_null())
        || value.get("redeemedAt").is_some_and(|value| !value.is_null())
        || value.get("used_at").is_some_and(|value| !value.is_null())
        || value.get("usedAt").is_some_and(|value| !value.is_null())
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

fn is_counted_available_credit(credit: &ResetCreditDetail) -> bool {
    if credit.status != "可用" {
        return false;
    }
    matches!(credit.redeemed_at.as_str(), "" | "未使用" | "未提供")
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
            "profile_user_id",
            "profileUserId",
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
    parsed_time_from_keys(value, keys)
        .map(format_reset_credit_time)
        .unwrap_or_else(|| "未提供".into())
}

fn parsed_time_from_keys(value: &Value, keys: &[&str]) -> Option<OffsetDateTime> {
    keys.iter().find_map(|key| value.get(*key)).and_then(parse_time)
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

fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_i64().map(|value| value as f64))
        .or_else(|| value.as_str().and_then(|value| value.parse::<f64>().ok()))
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
                        "profile_user_id",
                        "profileUserId",
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_reset_credit_detail_into_human_fields() {
        let credit = json!({
            "title": "每周重置卡",
            "status": "available",
            "reset_type": "weekly",
            "created_at": "2026-06-12T01:00:00Z",
            "expires_at": "2026-06-20T01:00:00Z",
            "redeem_started_at": "2026-06-13T01:00:00Z",
            "source": "system_grant",
            "reason": "weekly_reset_credit",
            "profile_image_url": "https://example.com/avatar.png",
            "associatedUsers": [{ "profile_user_id": "user_123" }],
            "id": "reset-credit-abcdef123456"
        });

        let detail = parse_reset_credit_detail(&credit, 0);
        assert_eq!(detail.title, "每周重置卡");
        assert_eq!(detail.status, "可用");
        assert_eq!(detail.card_id, "reset-credit-abcdef123456");
        assert_eq!(detail.reset_type, "weekly");
        assert_eq!(detail.redeemed_at, "未使用");
        assert_eq!(detail.source, "system_grant");
        assert_eq!(detail.detail_note, "weekly_reset_credit");
        assert_eq!(detail.associated_user, "user_123");
        assert_eq!(detail.profile_image_url, "https://example.com/avatar.png");
        assert_eq!(detail.short_id, "reset-...3456");
        assert!(detail.granted_at_unix.is_some());
        assert!(detail.expires_at_unix.is_some());
        assert!(detail.issued_at.starts_with("2026-06-12 "));
        assert!(detail.expires_at.starts_with("2026-06-20 "));
        assert!(detail.redeem_started_at.starts_with("2026-06-13 "));
        assert!(detail.summary.contains("类型 weekly"));
    }

    #[test]
    fn parses_reset_credit_summary_with_available_count_fallback() {
        let summary = parse_reset_credit_summary(&json!({
            "credits": [
                { "status": "available", "id": "available-reset-card" },
                { "status": "used", "id": "used-reset-card", "redeemed_at": "2026-06-12T01:00:00Z" }
            ]
        }));

        assert_eq!(summary.available_count, 1);
        assert_eq!(summary.status, "1 张重置卡可用");
        assert_eq!(summary.credits.len(), 2);
        assert_eq!(summary.credits[0].status, "可用");
        assert_eq!(summary.credits[1].status, "已使用");
    }

    #[test]
    fn reset_credit_fallback_count_excludes_used_timestamps() {
        let summary = parse_reset_credit_summary(&json!({
            "credits": [
                { "status": "available", "id": "available-reset-card" },
                { "status": "available", "id": "used-snake", "used_at": "2026-06-12T01:00:00Z" },
                { "status": "available", "id": "used-camel", "usedAt": "2026-06-12T01:00:00Z" },
                { "status": "expired", "id": "expired-reset-card" },
                { "status": "used", "id": "used-reset-card" }
            ]
        }));

        assert_eq!(summary.available_count, 1);
        assert_eq!(summary.status, "1 张重置卡可用");
        assert_eq!(summary.credits[1].status, "已使用");
        assert_eq!(summary.credits[2].status, "已使用");
        assert_eq!(summary.credits[3].status, "已过期");
        assert_eq!(summary.credits[4].status, "已使用");
    }

    #[test]
    fn reset_credit_explicit_available_count_preserves_api_count_floor() {
        let summary = parse_reset_credit_summary(&json!({
            "available_count": 2,
            "credits": [
                { "status": "available", "id": "used-snake", "used_at": "2026-06-12T01:00:00Z" },
                { "status": "expired", "id": "expired-reset-card" }
            ]
        }));

        assert_eq!(summary.available_count, 2);
        assert_eq!(summary.status, "2 张重置卡可用");
        assert_eq!(summary.credits[0].status, "已使用");
        assert_eq!(summary.credits[1].status, "已过期");
    }
}
