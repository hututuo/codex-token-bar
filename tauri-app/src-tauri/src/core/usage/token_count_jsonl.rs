use crate::core::quota_history;
use crate::models::{
    AccountInfo, DashboardSnapshot, LocalDataWarning, QuotaLimit, QuotaSnapshot,
    ResetCreditSummary,
};
use std::path::Path;
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

mod aggregates;
mod event_loader;
mod ranking;
mod session_files;
mod session_parser;
#[cfg(test)]
mod tests;
mod token_event_cache;

use aggregates::{activity_days, recent_usage, stats};
use event_loader::load_token_events;
use ranking::cache_hit_ranking;

#[derive(Clone, Debug)]
struct TokenEvent {
    timestamp: OffsetDateTime,
    session_id: String,
    tokens: u64,
    input_tokens: u64,
    cached_input_tokens: u64,
}

pub fn dashboard_snapshot(codex_home: &Path) -> Result<DashboardSnapshot, String> {
    let sessions_root = codex_home.join("sessions");
    if !sessions_root.exists() {
        return Err(format!("{} not found", sessions_root.display()));
    }

    let mut events = Vec::new();
    let mut warnings = Vec::new();
    events.extend(load_token_events(codex_home, &sessions_root, &mut warnings));

    if events.is_empty() {
        return Err(no_token_events_error(&warnings));
    }

    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let generated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    let mut activity_days = activity_days(&events, local_offset);
    if let Err(error) = quota_history::apply_activity_history(&mut activity_days) {
        warnings.push(quota_history::warning(error));
    }
    let recent_usage_24h = recent_usage(&events, local_offset);
    let stats = stats(&events, &activity_days);
    let cache_hit_ranking = cache_hit_ranking(&events, codex_home, local_offset, &mut warnings);

    Ok(DashboardSnapshot {
        generated_at,
        account: AccountInfo {
            display_name: "账户待读取".into(),
            plan_label: "计划待读取".into(),
        },
        stats,
        quota: placeholder_quota(),
        activity_days,
        recent_usage_24h,
        cache_hit_ranking,
        warnings,
    })
}

fn no_token_events_error(warnings: &[LocalDataWarning]) -> String {
    if warnings.is_empty() {
        return "No token_count events found".into();
    }
    let details = warnings
        .iter()
        .map(|warning| format!("{}: {}", warning.source, warning.message))
        .collect::<Vec<_>>()
        .join("；");
    format!("No token_count events found；{details}")
}

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
