use crate::models::ResetCreditSummary;
use std::path::Path;

use parser::parse_reset_credit_summary;

mod parser;

pub fn read_reset_credits(codex_home: &Path) -> Result<ResetCreditSummary, String> {
    let value = super::direct_http::fetch(&super::accounts::current_credential(codex_home)?, true)?;
    Ok(parse_reset_credit_summary(&value))
}
