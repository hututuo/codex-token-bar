use crate::commands::local_source;
use crate::core::dashboard::DashboardDataSource;
use crate::core::startup_trace;
use crate::core::usage::cache_lifecycle::{self, UsageCacheStatus};
use crate::core::usage::token_count_jsonl::{self, TokenUsageSummary};
use crate::models::{
    AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, PlatformCapabilities,
};
use crate::platform;
use std::time::Instant;
use tauri::async_runtime;

async fn run_blocking_command<T, F>(work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub fn get_codex_home() -> Result<CodexHomeStatus, String> {
    startup_trace::mark("command get_codex_home start");
    let result = platform::default_codex_home_status();
    startup_trace::mark("command get_codex_home end");
    Ok(result)
}

#[tauri::command]
pub fn set_codex_home(path: String) -> Result<CodexHomeStatus, String> {
    platform::save_codex_home(&path)
}

#[tauri::command]
pub fn reset_codex_home() -> Result<CodexHomeStatus, String> {
    platform::reset_codex_home()
}

#[tauri::command]
pub fn read_platform_capabilities() -> Result<PlatformCapabilities, String> {
    startup_trace::mark("command read_platform_capabilities start");
    let result = platform::platform_capabilities();
    startup_trace::mark("command read_platform_capabilities end");
    Ok(result)
}

#[tauri::command]
pub async fn read_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    startup_trace::mark("command read_dashboard_snapshot start");
    let started = Instant::now();
    let result = run_blocking_command(|| local_source().read_dashboard_snapshot()).await;
    startup_trace::mark_performance(format!(
        "read_dashboard_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    startup_trace::mark("command read_dashboard_snapshot end");
    result
}

#[tauri::command]
pub async fn read_precise_dashboard_snapshot() -> Result<DashboardSnapshot, String> {
    let started = Instant::now();
    let result = run_blocking_command(|| local_source().read_precise_dashboard_snapshot()).await;
    startup_trace::mark_performance(format!(
        "read_precise_dashboard_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn read_usage_summary_snapshot() -> Result<TokenUsageSummary, String> {
    let started = Instant::now();
    let codex_home = platform::default_codex_home();
    let result = run_blocking_command(move || {
        token_count_jsonl::usage_summary_snapshot(&codex_home)
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_usage_summary_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub fn read_usage_cache_status() -> UsageCacheStatus {
    cache_lifecycle::usage_cache_status()
}

#[tauri::command]
pub async fn read_account_quota(force_refresh: Option<bool>) -> Result<AccountQuotaBundle, String> {
    startup_trace::mark_once("command read_account_quota start");
    let started = Instant::now();
    let forced = force_refresh.unwrap_or(false);
    let result = run_blocking_command(move || {
        local_source().read_account_quota(forced)
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_account_quota force={} {}ms {}",
        forced,
        started.elapsed().as_millis(),
        account_quota_result_status(&result)
    ));
    startup_trace::mark_once("command read_account_quota end");
    result
}

fn result_status<T>(result: &Result<T, String>) -> &'static str {
    if result.is_ok() {
        "ok"
    } else {
        "error"
    }
}

fn account_quota_result_status(result: &Result<AccountQuotaBundle, String>) -> String {
    match result {
        Err(error) => format!("error {}", compact_trace_text(error)),
        Ok(bundle) => {
            let quota_available = bundle.quota.five_hour.resets_at_unix.is_some()
                || bundle.quota.seven_day.resets_at_unix.is_some();
            let status = if quota_available {
                "quota_success"
            } else {
                "quota_placeholder"
            };
            if bundle.warnings.is_empty() && bundle.diagnostics.is_empty() {
                status.to_string()
            } else {
                let warnings = bundle
                    .warnings
                    .iter()
                    .map(|warning| {
                        format!(
                            "{}:{}",
                            warning.source,
                            compact_trace_text(&warning.message)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("|");
                let diagnostics = bundle
                    .diagnostics
                    .iter()
                    .map(|diagnostic| {
                        format!(
                            "{}:{}:{}",
                            diagnostic.source,
                            diagnostic.category,
                            compact_trace_text(
                                diagnostic
                                    .raw_cause
                                    .as_deref()
                                    .unwrap_or(&diagnostic.message)
                            )
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("|");
                match (warnings.is_empty(), diagnostics.is_empty()) {
                    (false, false) => format!("{status} warnings=[{warnings}] diagnostics=[{diagnostics}]"),
                    (false, true) => format!("{status} warnings=[{warnings}]"),
                    (true, false) => format!("{status} diagnostics=[{diagnostics}]"),
                    (true, true) => status.to_string(),
                }
            }
        }
    }
}

fn compact_trace_text(text: &str) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= 1200 {
        compact
    } else {
        let mut truncated = compact.chars().take(1200).collect::<String>();
        truncated.push('…');
        truncated
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{
        AccountInfo, AccountQuotaBundle, QuotaLimit, QuotaSnapshot, ResetCreditSummary,
    };

    #[test]
    fn account_quota_trace_status_distinguishes_placeholder_bundle_from_real_quota() {
        let mut quota = placeholder_quota_for_test();
        quota.pace_label = "额度读取失败".into();
        let placeholder = Ok(AccountQuotaBundle {
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota,
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: vec![],
            diagnostics: Vec::new(),
        });

        assert_eq!(account_quota_result_status(&placeholder), "quota_placeholder");
    }

    #[test]
    fn account_quota_trace_keeps_full_retry_diagnostics() {
        let long_warning = format!(
            "额度读取失败：网络连接失败：{}",
            "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)；".repeat(8)
        );
        let placeholder = Ok(AccountQuotaBundle {
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota: placeholder_quota_for_test(),
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: vec![crate::models::LocalDataWarning {
                source: "account_quota".into(),
                message: long_warning,
            }],
            diagnostics: vec![crate::models::QuotaDiagnostic {
                source: "account_quota".into(),
                category: "network_send_fetch".into(),
                severity: "warning".into(),
                message: "网络连接失败".into(),
                raw_cause: Some("failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)；".repeat(8)),
                underlying_category: None,
                attempts: Some(3),
                http_status: None,
                retryable: true,
                occurred_at: "2026-07-06T00:00:00Z".into(),
                stale_data_displayed: false,
            }],
        });

        let status = account_quota_result_status(&placeholder);
        assert!(status.contains("quota_placeholder warnings=[account_quota:"));
        assert!(status.contains("diagnostics=[account_quota:network_send_fetch:"));
        assert!(status.contains("backend-api/wham/usage"));
        assert!(!status.contains('…'));
    }

    fn placeholder_quota_for_test() -> QuotaSnapshot {
        QuotaSnapshot {
            five_hour: QuotaLimit {
                label: "5h".into(),
                used_percent: 0.0,
                remaining_percent: 0.0,
                resets_at: "待读取".into(),
                resets_at_unix: None,
            },
            seven_day: QuotaLimit {
                label: "7d".into(),
                used_percent: 0.0,
                remaining_percent: 0.0,
                resets_at: "待读取".into(),
                resets_at_unix: None,
            },
            pace_label: "待读取".into(),
            reset_credit: ResetCreditSummary {
                available_count: 0,
                status: "重置卡待读取".into(),
                credits: Vec::new(),
            },
        }
    }
}
