use super::dashboard::{
    capture_codex_home_source, emit_detected_source_transition, validate_codex_home_source,
    CodexHomeSourceToken,
};
use super::window_auth::require_window_label;
use crate::core::thread_activity::{RunningThreadCounts, ThreadActivityScanner};
use crate::models::RunningThreadSummary;
use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};
use tauri::{AppHandle, State};

const REFRESH_INTERVAL: Duration = Duration::from_secs(1);
const LIVENESS_LEASE_HOURS: u32 = 24;

#[derive(Clone, Default)]
pub struct ThreadActivityRegistry {
    inner: Arc<Mutex<RegistryState>>,
}

#[derive(Default)]
struct RegistryState {
    sources: HashMap<ThreadActivitySourceKey, SourceState>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct ThreadActivitySourceKey {
    canonical_home_key: String,
    physical_home_key: String,
    transition_generation: u64,
}

#[derive(Default)]
struct SourceState {
    scanner: Option<ThreadActivityScanner>,
    summary: Option<RunningThreadSummary>,
    refreshing: bool,
    refresh_started_at: Option<Instant>,
}

struct RefreshJob {
    source_key: ThreadActivitySourceKey,
    codex_home: PathBuf,
    scanner: ThreadActivityScanner,
}

impl ThreadActivityRegistry {
    fn snapshot_or_start(
        &self,
        source_key: ThreadActivitySourceKey,
        codex_home: PathBuf,
    ) -> Result<(RunningThreadSummary, Option<RefreshJob>), String> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| "运行线程扫描状态锁已损坏".to_string())?;
        if !state.sources.contains_key(&source_key) && state.sources.len() >= 2 {
            state.sources.retain(|_, source| source.refreshing);
        }
        let source = state.sources.entry(source_key.clone()).or_default();
        let due = source
            .refresh_started_at
            .map_or(true, |started| started.elapsed() >= REFRESH_INTERVAL);
        let job = if !source.refreshing && due {
            source.refreshing = true;
            source.refresh_started_at = Some(Instant::now());
            Some(RefreshJob {
                source_key,
                codex_home,
                scanner: source.scanner.take().unwrap_or_default(),
            })
        } else {
            None
        };
        let summary = source.summary.clone().unwrap_or_else(scanning_summary);
        Ok((summary, job))
    }

    fn spawn_refresh(&self, job: RefreshJob) {
        let registry = self.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let mut scanner = job.scanner;
            let result = catch_unwind(AssertUnwindSafe(|| scanner.scan(&job.codex_home)))
                .unwrap_or_else(|_| Err("运行线程扫描器发生内部异常".into()));
            registry.finish_refresh(job.source_key, scanner, result);
        });
    }

    fn finish_refresh(
        &self,
        source_key: ThreadActivitySourceKey,
        scanner: ThreadActivityScanner,
        result: Result<RunningThreadCounts, String>,
    ) {
        let Ok(mut state) = self.inner.lock() else {
            return;
        };
        let source = state.sources.entry(source_key).or_default();
        source.scanner = Some(scanner);
        source.refreshing = false;
        source.refresh_started_at = Some(Instant::now());
        let previous = source.summary.clone();
        source.summary = Some(match result {
            Ok(counts) => ready_summary(counts),
            Err(error) => stale_or_unavailable_summary(previous.as_ref(), error),
        });
    }
}

#[tauri::command]
pub async fn read_running_thread_summary(
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: State<'_, ThreadActivityRegistry>,
    source_token: CodexHomeSourceToken,
) -> Result<RunningThreadSummary, String> {
    require_window_label(&window, "read_running_thread_summary")?;
    emit_detected_source_transition(&app)?;
    let captured = capture_codex_home_source(Some(&source_token))?;
    let completed_source_token = captured.source_token.clone();
    let source_key = ThreadActivitySourceKey {
        canonical_home_key: captured.source_token.canonical_home_key.clone(),
        physical_home_key: captured.source_token.physical_home_key.clone(),
        transition_generation: captured.source_token.transition_generation,
    };
    let registry = state.inner().clone();
    let (summary, job) = registry.snapshot_or_start(source_key, captured.codex_home)?;
    if let Some(job) = job {
        registry.spawn_refresh(job);
    }
    emit_detected_source_transition(&app)?;
    validate_codex_home_source(&completed_source_token)?;
    Ok(summary)
}

fn scanning_summary() -> RunningThreadSummary {
    RunningThreadSummary {
        total: None,
        main_threads: None,
        subagents: None,
        status: "scanning".into(),
        updated_at: None,
        detail: "正在读取当前数据源的会话生命周期".into(),
        liveness_lease_hours: LIVENESS_LEASE_HOURS,
    }
}

fn ready_summary(counts: RunningThreadCounts) -> RunningThreadSummary {
    RunningThreadSummary {
        total: Some(counts.total()),
        main_threads: Some(counts.main_threads),
        subagents: Some(counts.subagents),
        status: "ready".into(),
        updated_at: Some(unix_ms_now()),
        detail: "按每个会话最新生命周期统计；24 小时仅用于淘汰无新文件活动的孤儿运行态".into(),
        liveness_lease_hours: LIVENESS_LEASE_HOURS,
    }
}

fn stale_or_unavailable_summary(
    previous: Option<&RunningThreadSummary>,
    error: String,
) -> RunningThreadSummary {
    if let Some(previous) = previous.filter(|summary| summary.total.is_some()) {
        return RunningThreadSummary {
            status: "stale".into(),
            detail: format!("沿用最近一次成功结果；本轮刷新失败：{error}"),
            ..previous.clone()
        };
    }
    RunningThreadSummary {
        total: None,
        main_threads: None,
        subagents: None,
        status: "unavailable".into(),
        updated_at: None,
        detail: format!("运行线程暂不可用：{error}"),
        liveness_lease_hours: LIVENESS_LEASE_HOURS,
    }
}

fn unix_ms_now() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source_key(name: &str) -> ThreadActivitySourceKey {
        ThreadActivitySourceKey {
            canonical_home_key: format!("/tmp/{name}"),
            physical_home_key: format!("physical:{name}"),
            transition_generation: 1,
        }
    }

    #[test]
    fn totals_are_always_derived_from_main_and_subagents() {
        let summary = ready_summary(RunningThreadCounts {
            main_threads: 2,
            subagents: 3,
        });
        assert_eq!(summary.total, Some(5));
        assert_eq!(summary.main_threads, Some(2));
        assert_eq!(summary.subagents, Some(3));
    }

    #[test]
    fn failure_keeps_last_good_counts_but_marks_them_stale() {
        let ready = ready_summary(RunningThreadCounts {
            main_threads: 4,
            subagents: 1,
        });
        let stale = stale_or_unavailable_summary(Some(&ready), "temporary".into());
        assert_eq!(stale.status, "stale");
        assert_eq!(stale.total, Some(5));
        assert_eq!(stale.updated_at, ready.updated_at);
    }

    #[test]
    fn first_failure_never_presents_fake_zero_counts() {
        let unavailable = stale_or_unavailable_summary(None, "missing".into());
        assert_eq!(unavailable.status, "unavailable");
        assert_eq!(unavailable.total, None);
        assert_eq!(unavailable.main_threads, None);
        assert_eq!(unavailable.subagents, None);
    }

    #[test]
    fn one_source_starts_only_one_refresh_job_at_a_time() {
        let registry = ThreadActivityRegistry::default();
        let (_, first) = registry
            .snapshot_or_start(source_key("one"), PathBuf::from("/tmp/one"))
            .unwrap();
        let (second_summary, second) = registry
            .snapshot_or_start(source_key("one"), PathBuf::from("/tmp/one"))
            .unwrap();

        assert!(first.is_some());
        assert!(second.is_none());
        assert_eq!(second_summary.status, "scanning");
        assert_eq!(second_summary.total, None);
    }

    #[test]
    fn physical_sources_do_not_share_refresh_or_counts() {
        let registry = ThreadActivityRegistry::default();
        let (_, first) = registry
            .snapshot_or_start(source_key("one"), PathBuf::from("/tmp/one"))
            .unwrap();
        let (_, second) = registry
            .snapshot_or_start(source_key("two"), PathBuf::from("/tmp/two"))
            .unwrap();

        assert!(first.is_some());
        assert!(second.is_some());
    }
}
