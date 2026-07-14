use crate::core::usage::token_count_jsonl;
#[cfg(test)]
use crate::core::{app_paths, unread};
use crate::models::{
    FloatingPanelSnapshot, LiveRateSnapshot, LiveThreadOption, LocalDataWarning, UnreadSummary,
};
use logs::read_recent_log_rows;
pub use monitor::LiveRateMonitorService;
use rusqlite::Result;
use rollout::{read_rollout_metrics, sync_rollout_offsets_to_current};
use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;
#[cfg(test)]
use std::sync::{Mutex, OnceLock};
#[cfg(test)]
use std::time::{Duration, Instant};
use std::time::{SystemTime, UNIX_EPOCH};
use state::{read_thread_options_result, read_thread_title, UsageSummary};
use stream::{rollup_metric_events, rollup_stream_rows};

const LOOKBACK_SECONDS: f64 = 8.0;
const MAX_TOKENS_PER_SECOND: f64 = 200.0;
#[cfg(test)]
const UNREAD_SUMMARY_TTL: Duration = Duration::from_secs(3);
#[cfg(test)]
static UNREAD_SUMMARY_CACHE: OnceLock<Mutex<Option<CachedUnreadSummary>>> = OnceLock::new();

#[cfg(test)]
#[derive(Clone)]
struct CachedUnreadSummary {
    codex_home: PathBuf,
    summary: UnreadSummary,
    refreshed_at: Instant,
    signature: UnreadStoreSignature,
}

#[cfg(test)]
#[derive(Clone, Debug, Eq, PartialEq)]
struct UnreadStoreSignature {
    unread_state: StoreFileSignature,
    state_database: StoreFileSignature,
    acknowledgement: StoreFileSignature,
}

#[cfg(test)]
#[derive(Clone, Debug, Eq, PartialEq)]
struct StoreFileSignature {
    exists: bool,
    len: u64,
    modified_at: Option<SystemTime>,
}

mod logs;
mod monitor;
mod rollout;
mod state;
mod stream;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct LiveRateSourceScope {
    pub canonical_home_key: String,
    pub physical_home_key: String,
}

impl LiveRateSourceScope {
    pub fn new(canonical_home_key: impl Into<String>, physical_home_key: impl Into<String>) -> Self {
        Self {
            canonical_home_key: canonical_home_key.into(),
            physical_home_key: physical_home_key.into(),
        }
    }

    fn legacy(codex_home: &Path) -> Self {
        let key = codex_home.to_string_lossy().into_owned();
        Self::new(key.clone(), key)
    }
}

#[cfg(test)]
pub fn read_snapshot(codex_home: &Path, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
    let unread_summary = read_unread_summary_cached(codex_home);
    read_snapshot_with_unread(codex_home, selected_thread_id, unread_summary)
}

pub fn read_snapshot_with_unread(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
    unread_summary: UnreadSummary,
) -> LiveRateSnapshot {
    read_snapshot_with_unread_scoped(
        codex_home,
        &LiveRateSourceScope::legacy(codex_home),
        selected_thread_id,
        unread_summary,
    )
}

pub(crate) fn read_snapshot_with_unread_scoped(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    selected_thread_id: Option<&str>,
    unread_summary: UnreadSummary,
) -> LiveRateSnapshot {
    match read_snapshot_result(codex_home, source_scope, selected_thread_id) {
        Ok(mut snapshot) => {
            snapshot.unread_summary = unread_summary;
            snapshot
        }
        Err(error) => {
            let warnings = vec![live_rate_warning(format!(
                "读取实时输出流失败：{}（{}）",
                codex_home.join("logs_2.sqlite").display(),
                error
            ))];
            idle_snapshot_with_warnings(codex_home, selected_thread_id, unread_summary, warnings)
        }
    }
}

pub fn try_read_snapshot(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
) -> Result<LiveRateSnapshot> {
    read_snapshot_result(
        codex_home,
        &LiveRateSourceScope::legacy(codex_home),
        selected_thread_id,
    )
}

pub fn try_read_thread_options(codex_home: &Path) -> Result<Vec<LiveThreadOption>> {
    read_thread_options_result(codex_home, 18)
}

fn idle_snapshot_with_warnings(
    codex_home: &Path,
    selected_thread_id: Option<&str>,
    unread_summary: UnreadSummary,
    mut warnings: Vec<LocalDataWarning>,
) -> LiveRateSnapshot {
    let summary = read_precise_usage_summary_or_fallback(codex_home, &mut warnings);
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
        total_tokens: summary.total_tokens,
        total_tokens_today: summary.today_tokens,
        requests_today: summary.today_requests,
        max_tokens_per_second: MAX_TOKENS_PER_SECOND,
        precise_enabled: false,
        unread_summary,
        warnings,
    }
}

fn read_snapshot_result(
    codex_home: &Path,
    source_scope: &LiveRateSourceScope,
    selected_thread_id: Option<&str>,
) -> Result<LiveRateSnapshot> {
    let mut warnings = Vec::new();
    let now = current_time_seconds();
    let rows = match read_recent_log_rows(codex_home, now - LOOKBACK_SECONDS) {
        Ok(rows) => rows,
        Err(error) => {
            warnings.push(live_rate_warning(format!(
                "读取旧版实时输出流失败，已尝试新版 rollout：{}（{}）",
                codex_home.join("logs_2.sqlite").display(),
                error
            )));
            Vec::new()
        }
    };
    let stream_rollup = rollup_stream_rows(&rows, now, None);
    let stream_selected_rollup = selected_thread_id
        .map(|thread_id| rollup_stream_rows(&rows, now, Some(thread_id)))
        .unwrap_or_default();
    let (rollup, selected_rollup) = if stream_rollup.tokens_per_second <= 0.0 {
        let metrics = match read_rollout_metrics(codex_home, source_scope, now) {
            Ok(metrics) => metrics,
            Err(error) => {
                warnings.push(live_rate_warning(format!(
                    "读取新版 rollout 会话索引失败：{}（{}）",
                    codex_home.join("state_5.sqlite").display(),
                    error
                )));
                Vec::new()
            }
        };
        let rollup = rollup_metric_events(&metrics, now, None);
        let selected_rollup = selected_thread_id
            .map(|thread_id| rollup_metric_events(&metrics, now, Some(thread_id)))
            .unwrap_or_default();
        (rollup, selected_rollup)
    } else {
        sync_rollout_offsets_to_current(codex_home, source_scope);
        (stream_rollup, stream_selected_rollup)
    };
    let summary = read_precise_usage_summary_or_fallback(codex_home, &mut warnings);
    let _observed_live_source_tokens = rollup.breakdown.observed_total();
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
        total_tokens: summary.total_tokens,
        total_tokens_today: summary.today_tokens,
        requests_today: summary.today_requests,
        max_tokens_per_second: MAX_TOKENS_PER_SECOND,
        precise_enabled: false,
        unread_summary: empty_unread_summary(),
        warnings,
    })
}

fn empty_unread_summary() -> UnreadSummary {
    UnreadSummary {
        active: false,
        count: 0,
        label: "暂无未读完成会话".into(),
        detail: "未读状态由来源作用域调用方注入。".into(),
        source: "unread_not_loaded".into(),
    }
}

pub fn read_floating_snapshot_from_live(
    codex_home: &Path,
    live: &LiveRateSnapshot,
) -> FloatingPanelSnapshot {
    let summary = token_count_jsonl::cached_dashboard_usage_summary(codex_home);
    FloatingPanelSnapshot {
        tokens_per_second: live.tokens_per_second,
        max_tokens_per_second: live.max_tokens_per_second,
        trend_label: String::new(),
        total_tokens_label: summary
            .as_ref()
            .map(|summary| format!("总 {}", compact_tokens(summary.total_tokens)))
            .unwrap_or_else(|| "总 待读取".into()),
        today_tokens_label: summary
            .as_ref()
            .map(|summary| format!("今 {}", compact_tokens(summary.today_tokens)))
            .unwrap_or_else(|| "今 待读取".into()),
        requests_label: summary
            .as_ref()
            .map(|summary| format!("次 {}", summary.today_requests))
            .unwrap_or_else(|| "次 待读取".into()),
        five_hour_label: "5h 待读取".into(),
        seven_day_label: "7d 待读取".into(),
        unread: live.unread_summary.active,
        unread_summary: live.unread_summary.clone(),
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

fn read_precise_usage_summary_or_fallback(
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> UsageSummary {
    if let Some(summary) = token_count_jsonl::cached_dashboard_usage_summary(codex_home) {
        return UsageSummary {
            total_tokens: summary.total_tokens,
            today_tokens: summary.today_tokens,
            today_requests: summary.today_requests,
        };
    }

    warnings.push(live_rate_summary_warning(
        "精确 token 缓存尚未就绪，已忽略 state_5.sqlite 的重复线程口径".into(),
    ));
    UsageSummary::default()
}

#[cfg(test)]
fn read_unread_summary_cached(codex_home: &Path) -> UnreadSummary {
    let now = Instant::now();
    let signature = unread_store_signature(codex_home);
    let cache = UNREAD_SUMMARY_CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(guard) = cache.lock() {
        if let Some(cached) = guard.as_ref() {
            if cached.codex_home == codex_home
                && cached.signature == signature
                && signature.unread_state.exists
            {
                return cached.summary.clone();
            }
            if cached.codex_home == codex_home
                && cached.signature == signature
                && now.duration_since(cached.refreshed_at) <= UNREAD_SUMMARY_TTL
            {
                return cached.summary.clone();
            }
        }
    }

    let summary = unread::read_unread_summary(codex_home);
    if let Ok(mut guard) = cache.lock() {
        *guard = Some(CachedUnreadSummary {
            codex_home: codex_home.to_path_buf(),
            summary: summary.clone(),
            refreshed_at: now,
            signature,
        });
    }
    summary
}

#[cfg(test)]
fn unread_store_signature(codex_home: &Path) -> UnreadStoreSignature {
    UnreadStoreSignature {
        unread_state: store_file_signature(&codex_home.join(".codex-global-state.json")),
        state_database: state_database_signature(codex_home),
        acknowledgement: app_paths::unread_acknowledgement_path()
            .map(|path| store_file_signature(&path))
            .unwrap_or(StoreFileSignature {
                exists: false,
                len: 0,
                modified_at: None,
            }),
    }
}

#[cfg(test)]
fn state_database_signature(codex_home: &Path) -> StoreFileSignature {
    store_file_signature(&codex_home.join("state_5.sqlite"))
}

#[cfg(test)]
fn store_file_signature(path: &Path) -> StoreFileSignature {
    std::fs::metadata(path)
        .map(|metadata| StoreFileSignature {
            exists: true,
            len: metadata.len(),
            modified_at: metadata.modified().ok(),
        })
        .unwrap_or(StoreFileSignature {
            exists: false,
            len: 0,
            modified_at: None,
        })
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
