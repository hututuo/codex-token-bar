use crate::models::ResetCreditSummary;
use std::path::Path;

use parser::parse_reset_credit_summary;

mod parser;

pub fn read_reset_credits(codex_home: &Path) -> Result<ResetCreditSummary, String> {
    let value = super::read_account_limits_once(codex_home, super::RESET_CREDIT_TIMEOUT)?;
    parse_embedded_reset_credits(&value)
}

pub(super) fn parse_embedded_reset_credits(value: &serde_json::Value) -> Result<ResetCreditSummary, String> {
    let credits = value.get("rateLimitResetCredits").filter(|value| value.is_object())
        .ok_or_else(|| "Codex 未提供重置卡数据（account/rateLimits/read: rateLimitResetCredits unavailable）".to_string())?;
    Ok(parse_reset_credit_summary(credits))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn official_rpc_count_is_preserved_without_card_details() {
        let summary = parse_embedded_reset_credits(&json!({
            "rateLimitResetCredits": {"availableCount": 4, "credits": null}
        })).unwrap();
        assert_eq!(summary.available_count, 4);
        assert!(summary.credits.is_empty());
    }

    #[test]
    fn missing_or_null_cards_are_unavailable_not_zero() {
        assert!(parse_embedded_reset_credits(&json!({})).is_err());
        assert!(parse_embedded_reset_credits(&json!({"rateLimitResetCredits": null})).is_err());
        assert_eq!(parse_embedded_reset_credits(&json!({
            "rateLimitResetCredits": {"availableCount": 0, "credits": []}
        })).unwrap().available_count, 0);
    }
}
