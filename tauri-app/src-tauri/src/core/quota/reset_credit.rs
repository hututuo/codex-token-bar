use crate::models::ResetCreditSummary;
use serde_json::Value;
use std::path::Path;
use std::time::Duration;

use super::auth::read_access_token;
use parser::parse_reset_credit_summary;

mod parser;

pub fn read_reset_credits(codex_home: &Path) -> Result<ResetCreditSummary, String> {
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
    Ok(parse_reset_credit_summary(&value))
}
