use super::{
    pending_snapshot_with_unread, read_floating_snapshot_from_live,
    read_snapshot_with_unread_scoped, rollout::rollout_file_signatures, LiveRateSourceScope,
};
#[cfg(test)]
use crate::core::unread;
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot, UnreadSummary};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime};

const FAST_REFRESH_INTERVAL: Duration = Duration::from_millis(250);
const IDLE_REFRESH_INTERVAL: Duration = Duration::from_secs(1);
const ACTIVE_REFRESH_HOLD: Duration = Duration::from_secs(10);
// 该 waiter 只用来接住即将完成的 owner。冷启动不应让 native 等待
// 吃完前端 IPC 预算；超时后返回已有数字或 typed pending，owner 稍后发事件升级。
const REFRESH_WAIT_TIMEOUT: Duration = Duration::from_millis(200);

pub struct LiveRateMonitorService {
    codex_home: PathBuf,
    source_scope: LiveRateSourceScope,
    inner: Mutex<LiveRateMonitorState>,
    refresh_ready: Condvar,
}

#[derive(Default)]
struct LiveRateMonitorState {
    all_snapshot: Option<LiveRateSnapshot>,
    selected_snapshot: Option<SelectedSnapshot>,
    last_signature: Option<LogStoreSignature>,
    last_refresh: Option<Instant>,
    last_active_at: Option<Instant>,
    refresh_count: usize,
    signature_count: usize,
    next_refresh_nonce: u64,
    refresh_in_flight: Option<u64>,
    reset_generation: u64,
}

struct SelectedSnapshot {
    selected_thread_id: Option<String>,
    snapshot: LiveRateSnapshot,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct LogStoreSignature {
    database_len: u64,
    database_modified_at: Option<SystemTime>,
    wal_len: u64,
    wal_modified_at: Option<SystemTime>,
    state_len: u64,
    state_modified_at: Option<SystemTime>,
    rollout_files: Vec<RolloutSignatureEntry>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RolloutSignatureEntry {
    path: PathBuf,
    len: u64,
    modified_at: Option<SystemTime>,
}

struct RefreshClaimGuard<'a> {
    service: &'a LiveRateMonitorService,
    nonce: u64,
    reset_generation: u64,
    armed: bool,
}

impl RefreshClaimGuard<'_> {
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for RefreshClaimGuard<'_> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let cleared = {
            let mut state = self
                .service
                .inner
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if state.refresh_in_flight == Some(self.nonce)
                && state.reset_generation == self.reset_generation
            {
                state.refresh_in_flight = None;
                true
            } else {
                false
            }
        };
        if cleared {
            self.service.refresh_ready.notify_all();
        }
    }
}

impl LiveRateMonitorService {
    pub fn new(codex_home: PathBuf) -> Self {
        let source_scope = LiveRateSourceScope::legacy(&codex_home);
        Self::new_scoped(codex_home, source_scope)
    }

    pub fn new_scoped(codex_home: PathBuf, source_scope: LiveRateSourceScope) -> Self {
        Self {
            codex_home,
            source_scope,
            inner: Mutex::new(LiveRateMonitorState::default()),
            refresh_ready: Condvar::new(),
        }
    }

    pub fn codex_home(&self) -> &Path {
        &self.codex_home
    }

    pub fn source_scope(&self) -> &LiveRateSourceScope {
        &self.source_scope
    }

    #[cfg(test)]
    pub fn snapshot(&self, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
        let unread_summary = unread::read_unread_summary(&self.codex_home);
        self.snapshot_with_loaded_unread(selected_thread_id, unread_summary)
    }

    pub fn snapshot_with_unread(
        &self,
        selected_thread_id: Option<&str>,
        unread_summary: UnreadSummary,
    ) -> LiveRateSnapshot {
        self.snapshot_with_loaded_unread(selected_thread_id, unread_summary)
    }

    pub fn immediate_snapshot_with_unread(
        &self,
        selected_thread_id: Option<&str>,
        unread_summary: UnreadSummary,
    ) -> LiveRateSnapshot {
        let state = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(mut snapshot) = state.cached_snapshot(selected_thread_id) {
            snapshot.unread_summary = unread_summary;
            return snapshot;
        }
        if let Some(mut snapshot) = state.all_snapshot.clone() {
            snapshot.selected_thread_id = selected_thread_id.map(ToOwned::to_owned);
            snapshot.selected_thread_title = if selected_thread_id.is_some() {
                "选中会话待读取".into()
            } else {
                "选择会话查看单会话速率".into()
            };
            snapshot.selected_tokens_per_second = 0.0;
            snapshot.unread_summary = unread_summary;
            return snapshot;
        }
        drop(state);
        pending_snapshot_with_unread(selected_thread_id, unread_summary)
    }

    fn snapshot_with_loaded_unread(
        &self,
        selected_thread_id: Option<&str>,
        unread_summary: UnreadSummary,
    ) -> LiveRateSnapshot {
        self.snapshot_with_loaded_unread_after_claim(selected_thread_id, unread_summary, || {})
    }

    fn snapshot_with_loaded_unread_after_claim(
        &self,
        selected_thread_id: Option<&str>,
        unread_summary: UnreadSummary,
        after_claim: impl FnOnce(),
    ) -> LiveRateSnapshot {
        let (refresh_nonce, reset_generation) = loop {
            let mut state = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(mut snapshot) = state.cached_snapshot_before_signature(selected_thread_id) {
                snapshot.unread_summary = unread_summary.clone();
                return snapshot;
            }
            if state.refresh_in_flight.is_some() {
                if let Some(mut snapshot) = state.cached_snapshot(selected_thread_id) {
                    snapshot.unread_summary = unread_summary.clone();
                    return snapshot;
                }
                let (state, wait_result) = self
                    .refresh_ready
                    .wait_timeout(state, REFRESH_WAIT_TIMEOUT)
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if wait_result.timed_out() && state.refresh_in_flight.is_some() {
                    drop(state);
                    return self.immediate_snapshot_with_unread(selected_thread_id, unread_summary);
                }
                drop(state);
                continue;
            }
            state.next_refresh_nonce = state.next_refresh_nonce.saturating_add(1);
            let nonce = state.next_refresh_nonce;
            state.refresh_in_flight = Some(nonce);
            break (nonce, state.reset_generation);
        };
        let mut claim_guard = RefreshClaimGuard {
            service: self,
            nonce: refresh_nonce,
            reset_generation,
            armed: true,
        };

        after_claim();
        let signature = log_store_signature(&self.codex_home, &self.source_scope);
        {
            let mut state = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if state.refresh_in_flight != Some(refresh_nonce)
                || state.reset_generation != reset_generation
            {
                self.refresh_ready.notify_all();
                drop(state);
                claim_guard.disarm();
                return read_snapshot_with_unread_scoped(
                    &self.codex_home,
                    &self.source_scope,
                    selected_thread_id,
                    unread_summary,
                );
            }
            state.signature_count += 1;
            let selected_matches = state
                .selected_snapshot
                .as_ref()
                .is_some_and(|cached| cached.selected_thread_id.as_deref() == selected_thread_id);
            if !state.should_refresh(&signature, selected_thread_id, selected_matches) {
                let mut snapshot = state
                    .cached_snapshot(selected_thread_id)
                    .expect("non-refreshing monitor must have a cached snapshot");
                snapshot.unread_summary = unread_summary;
                state.refresh_in_flight = None;
                self.refresh_ready.notify_all();
                claim_guard.disarm();
                return snapshot;
            }
        }

        let snapshot = read_snapshot_with_unread_scoped(
            &self.codex_home,
            &self.source_scope,
            selected_thread_id,
            unread_summary,
        );
        let all_snapshot = if selected_thread_id.is_some() {
            let mut all_snapshot = snapshot.clone();
            all_snapshot.selected_thread_id = None;
            all_snapshot.selected_thread_title = "选择会话查看单会话速率".into();
            all_snapshot.selected_tokens_per_second = 0.0;
            all_snapshot
        } else {
            snapshot.clone()
        };

        let mut state = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.refresh_in_flight == Some(refresh_nonce)
            && state.reset_generation == reset_generation
        {
            state.all_snapshot = Some(all_snapshot);
            state.selected_snapshot = Some(SelectedSnapshot {
                selected_thread_id: selected_thread_id.map(ToOwned::to_owned),
                snapshot: snapshot.clone(),
            });
            state.last_signature = Some(signature);
            state.last_refresh = Some(Instant::now());
            if snapshot.tokens_per_second > 0.05 || snapshot.selected_tokens_per_second > 0.05 {
                state.last_active_at = Some(Instant::now());
            }
            state.refresh_count += 1;
            state.refresh_in_flight = None;
        }
        self.refresh_ready.notify_all();
        claim_guard.disarm();
        snapshot
    }

    #[cfg(test)]
    pub fn floating_snapshot(&self) -> FloatingPanelSnapshot {
        let live = self.snapshot(None);
        read_floating_snapshot_from_live(&self.codex_home, &live)
    }

    pub fn floating_snapshot_with_unread(
        &self,
        unread_summary: UnreadSummary,
    ) -> FloatingPanelSnapshot {
        let live = self.snapshot_with_unread(None, unread_summary);
        read_floating_snapshot_from_live(&self.codex_home, &live)
    }

    pub fn reset(&self) {
        let mut state = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        state.all_snapshot = None;
        state.selected_snapshot = None;
        state.last_signature = None;
        state.last_refresh = None;
        state.last_active_at = None;
        state.reset_generation = state.reset_generation.saturating_add(1);
        state.refresh_in_flight = None;
        self.refresh_ready.notify_all();
    }

    #[cfg(test)]
    pub fn test_refresh_count(&self) -> usize {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .refresh_count
    }

    #[cfg(test)]
    pub fn test_signature_count(&self) -> usize {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .signature_count
    }

    #[cfg(test)]
    pub fn test_snapshot_after_claim(
        &self,
        selected_thread_id: Option<&str>,
        after_claim: impl FnOnce(),
    ) -> LiveRateSnapshot {
        self.snapshot_with_loaded_unread_after_claim(
            selected_thread_id,
            unread::read_unread_summary(&self.codex_home),
            after_claim,
        )
    }
}

impl LiveRateMonitorState {
    fn cached_snapshot(&self, selected_thread_id: Option<&str>) -> Option<LiveRateSnapshot> {
        if let Some(selected_thread_id) = selected_thread_id {
            return self
                .selected_snapshot
                .as_ref()
                .filter(|cached| cached.selected_thread_id.as_deref() == Some(selected_thread_id))
                .map(|cached| cached.snapshot.clone());
        }
        self.all_snapshot.clone()
    }

    fn cached_snapshot_before_signature(
        &self,
        selected_thread_id: Option<&str>,
    ) -> Option<LiveRateSnapshot> {
        if self.all_snapshot.is_none() {
            return None;
        }
        let last_refresh = self.last_refresh?;
        if last_refresh.elapsed() >= self.refresh_interval() {
            return None;
        }

        if let Some(selected_thread_id) = selected_thread_id {
            return self
                .selected_snapshot
                .as_ref()
                .filter(|cached| cached.selected_thread_id.as_deref() == Some(selected_thread_id))
                .map(|cached| cached.snapshot.clone());
        }

        self.all_snapshot.clone()
    }

    fn should_refresh(
        &self,
        signature: &LogStoreSignature,
        selected_thread_id: Option<&str>,
        selected_matches: bool,
    ) -> bool {
        if self.all_snapshot.is_none() {
            return true;
        }
        if selected_thread_id.is_some() && !selected_matches {
            return true;
        }
        if self.last_signature.as_ref() != Some(signature) {
            return true;
        }

        let Some(last_refresh) = self.last_refresh else {
            return true;
        };
        last_refresh.elapsed() >= self.refresh_interval()
    }

    fn refresh_interval(&self) -> Duration {
        if self
            .last_active_at
            .is_some_and(|last_active| last_active.elapsed() <= ACTIVE_REFRESH_HOLD)
        {
            FAST_REFRESH_INTERVAL
        } else {
            IDLE_REFRESH_INTERVAL
        }
    }
}

fn log_store_signature(codex_home: &Path, source_scope: &LiveRateSourceScope) -> LogStoreSignature {
    let database = file_signature(&codex_home.join("logs_2.sqlite"));
    let wal = file_signature(&codex_home.join("logs_2.sqlite-wal"));
    let state = file_signature(&codex_home.join("state_5.sqlite"));
    let rollout_files = rollout_file_signatures(codex_home, source_scope)
        .into_iter()
        .map(|signature| RolloutSignatureEntry {
            path: signature.path,
            len: signature.len,
            modified_at: signature.modified_at,
        })
        .collect();
    LogStoreSignature {
        database_len: database.len,
        database_modified_at: database.modified_at,
        wal_len: wal.len,
        wal_modified_at: wal.modified_at,
        state_len: state.len,
        state_modified_at: state.modified_at,
        rollout_files,
    }
}

struct FileSignature {
    len: u64,
    modified_at: Option<SystemTime>,
}

fn file_signature(path: &Path) -> FileSignature {
    fs::metadata(path)
        .map(|metadata| FileSignature {
            len: metadata.len(),
            modified_at: metadata.modified().ok(),
        })
        .unwrap_or(FileSignature {
            len: 0,
            modified_at: None,
        })
}

#[cfg(test)]
mod immediate_snapshot_tests {
    use super::*;

    fn unread(source: &str) -> UnreadSummary {
        UnreadSummary {
            active: false,
            count: 0,
            label: "none".into(),
            detail: "none".into(),
            source: source.into(),
        }
    }

    #[test]
    fn cold_immediate_snapshot_is_typed_pending_without_claiming_refresh() {
        let monitor = LiveRateMonitorService::new(PathBuf::from("unused"));

        let snapshot = monitor
            .immediate_snapshot_with_unread(Some("thread-a"), unread("codex_sidebar_pending"));

        assert_eq!(snapshot.thread_title, "实时速率正在连接");
        assert_eq!(snapshot.selected_thread_id.as_deref(), Some("thread-a"));
        assert_eq!(snapshot.unread_summary.source, "codex_sidebar_pending");
        assert!(snapshot.warnings.is_empty());
        assert_eq!(monitor.test_refresh_count(), 0);
        assert_eq!(monitor.test_signature_count(), 0);
    }

    #[test]
    fn immediate_snapshot_reuses_existing_live_numbers() {
        let monitor = LiveRateMonitorService::new(PathBuf::from("unused"));
        let mut cached = pending_snapshot_with_unread(None, unread("old"));
        cached.thread_title = "cached live".into();
        cached.tokens_per_second = 42.5;
        monitor.inner.lock().unwrap().all_snapshot = Some(cached);

        let snapshot = monitor.immediate_snapshot_with_unread(None, unread("current"));

        assert_eq!(snapshot.tokens_per_second, 42.5);
        assert_eq!(snapshot.thread_title, "cached live");
        assert_eq!(snapshot.unread_summary.source, "current");
    }

    #[test]
    fn native_refresh_wait_budget_is_below_initial_frontend_ipc_budget() {
        assert!(REFRESH_WAIT_TIMEOUT < Duration::from_millis(1_500));
    }
}
