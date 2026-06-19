use crate::core::unread;
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption, LocalDataWarning};
use rusqlite::Result;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use logs::read_recent_log_rows;
pub use monitor::LiveRateMonitorService;
use state::{read_thread_options_result, read_thread_title, read_usage_summary, UsageSummary};
use stream::{rollup_stream_rows, LiveRateRollup};

const LOOKBACK_SECONDS: f64 = 8.0;
const MAX_TOKENS_PER_SECOND: f64 = 200.0;

mod stream;
mod state;
mod logs;
mod monitor;

pub fn read_snapshot(codex_home: &Path, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
    match try_read_snapshot(codex_home, selected_thread_id) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            let warnings = vec![live_rate_warning(format!(
                "读取实时输出流失败：{}（{}）",
                codex_home.join("logs_2.sqlite").display(),
                error
            ))];
            idle_snapshot_with_warnings(codex_home, selected_thread_id, warnings)
        }
    }
}

pub fn try_read_snapshot(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
) -> Result<LiveRateSnapshot> {
    read_snapshot_result(codex_home, selected_thread_id)
}

pub fn try_read_thread_options(codex_home: &Path) -> Result<Vec<LiveThreadOption>> {
    read_thread_options_result(codex_home, 18)
}

fn idle_snapshot_with_warnings(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
    mut warnings: Vec<LocalDataWarning>,
) -> LiveRateSnapshot {
    let summary = read_usage_summary_or_default(codex_home, &mut warnings);
    let selected_thread_title = selected_thread_id
        .and_then(|thread_id| read_thread_title_or_warn(codex_home, thread_id, &mut warnings))
        .unwrap_or_else(|| "选择会话查看单会话速率".into());
    LiveRateSnapshot {
        scope_label: "全会话".into(),
        thread_title: "等待任意会话输出".into(),
        selected_thread_id: selected_thread_id.map(ToOwned::to_owned),
        selected_thread_title,
        selected_tokens_per_second: 0.0,
        tokens_per_second: 0.0,
        total_tokens_today: summary.today_tokens,
        requests_today: summary.today_requests,
        max_tokens_per_second: MAX_TOKENS_PER_SECOND,
        precise_enabled: false,
        warnings,
    }
}

fn read_snapshot_result(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
) -> Result<LiveRateSnapshot> {
    let mut warnings = Vec::new();
    let now = current_time_seconds();
    let rows = read_recent_log_rows(codex_home, now - LOOKBACK_SECONDS)?;
    let rollup = rollup_stream_rows(&rows, now, None);
    let selected_rollup = selected_thread_id
        .map(|thread_id| rollup_stream_rows(&rows, now, Some(thread_id)))
        .unwrap_or_else(|| LiveRateRollup {
            tokens_per_second: 0.0,
            latest_thread_id: None,
        });
    let summary = read_usage_summary_or_default(codex_home, &mut warnings);
    let thread_title = rollup
        .latest_thread_id
        .as_deref()
        .and_then(|thread_id| read_thread_title_or_warn(codex_home, thread_id, &mut warnings))
        .unwrap_or_else(|| "等待任意会话输出".into());
    let selected_thread_title = selected_thread_id
        .and_then(|thread_id| read_thread_title_or_warn(codex_home, thread_id, &mut warnings))
        .unwrap_or_else(|| "选择会话查看单会话速率".into());

    Ok(LiveRateSnapshot {
        scope_label: "全会话".into(),
        thread_title,
        selected_thread_id: selected_thread_id.map(ToOwned::to_owned),
        selected_thread_title,
        selected_tokens_per_second: selected_rollup.tokens_per_second,
        tokens_per_second: rollup.tokens_per_second,
        total_tokens_today: summary.today_tokens,
        requests_today: summary.today_requests,
        max_tokens_per_second: MAX_TOKENS_PER_SECOND,
        precise_enabled: false,
        warnings,
    })
}

pub fn read_floating_snapshot_from_live(
    codex_home: &Path,
    live: &LiveRateSnapshot,
) -> FloatingPanelSnapshot {
    let mut warnings = Vec::new();
    let summary = read_usage_summary_or_default(codex_home, &mut warnings);
    let unread_summary = unread::read_unread_summary(codex_home);
    FloatingPanelSnapshot {
        tokens_per_second: live.tokens_per_second,
        trend_label: if live.tokens_per_second > 0.05 {
            "输出中".into()
        } else {
            "待输出".into()
        },
        total_tokens_label: format!("总 {}", compact_tokens(summary.total_tokens)),
        today_tokens_label: format!("今 {}", compact_tokens(live.total_tokens_today)),
        requests_label: format!("次 {}", live.requests_today),
        five_hour_label: "5h 待读取".into(),
        seven_day_label: "7d 待读取".into(),
        unread: unread_summary.active,
        unread_summary,
    }
}

fn live_rate_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "live_rate_stream".into(),
        message,
    }
}

fn live_rate_summary_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "live_rate_summary".into(),
        message,
    }
}

fn live_rate_thread_title_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "live_rate_thread_title".into(),
        message,
    }
}

fn read_usage_summary_or_default(
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> UsageSummary {
    match read_usage_summary(codex_home) {
        Ok(summary) => summary,
        Err(error) => {
            warnings.push(live_rate_summary_warning(format!(
                "读取实时速率汇总失败：{}（{}）",
                codex_home.join("state_5.sqlite").display(),
                error
            )));
            UsageSummary::default()
        }
    }
}

fn read_thread_title_or_warn(
    codex_home: &Path,
    thread_id: &str,
    warnings: &mut Vec<LocalDataWarning>,
) -> Option<String> {
    match read_thread_title(codex_home, thread_id) {
        Ok(title) => title,
        Err(error) => {
            warnings.push(live_rate_thread_title_warning(format!(
                "读取实时速率会话标题失败：{}（{}）",
                thread_id,
                error
            )));
            None
        }
    }
}

fn current_time_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0)
}

fn compact_tokens(value: u64) -> String {
    if value >= 100_000_000 {
        format!("{:.1}亿", value as f64 / 100_000_000.0)
    } else if value >= 10_000 {
        format!("{:.1}万", value as f64 / 10_000.0)
    } else {
        value.to_string()
    }
}

#[cfg(test)]
#[path = "live_rate_tests.rs"]
mod live_rate_tests;
