use super::{read_floating_snapshot_from_live, read_snapshot, rollout::rollout_file_signatures};
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

const FAST_REFRESH_INTERVAL: Duration = Duration::from_millis(250);
const IDLE_REFRESH_INTERVAL: Duration = Duration::from_secs(1);
const ACTIVE_REFRESH_HOLD: Duration = Duration::from_secs(10);

pub struct LiveRateMonitorService {
    codex_home: PathBuf,
    inner: Mutex<LiveRateMonitorState>,
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

impl LiveRateMonitorService {
    pub fn new(codex_home: PathBuf) -> Self {
        Self {
            codex_home,
            inner: Mutex::new(LiveRateMonitorState::default()),
        }
    }

    pub fn codex_home(&self) -> &Path {
        &self.codex_home
    }

    pub fn snapshot(&self, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
        let mut state = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(snapshot) = state.cached_snapshot_before_signature(selected_thread_id) {
            return snapshot;
        }
        let signature = log_store_signature(&self.codex_home);
        state.signature_count += 1;
        let selected_matches = state
            .selected_snapshot
            .as_ref()
            .is_some_and(|cached| cached.selected_thread_id.as_deref() == selected_thread_id);

        if !state.should_refresh(&signature, selected_thread_id, selected_matches) {
            if let Some(selected) = &state.selected_snapshot {
                if selected.selected_thread_id.as_deref() == selected_thread_id {
                    return selected.snapshot.clone();
                }
            }
            if selected_thread_id.is_none() {
                if let Some(snapshot) = &state.all_snapshot {
                    return snapshot.clone();
                }
            }
        }

        let snapshot = read_snapshot(&self.codex_home, selected_thread_id);
        let all_snapshot = if selected_thread_id.is_some() {
            let mut all_snapshot = snapshot.clone();
            all_snapshot.selected_thread_id = None;
            all_snapshot.selected_thread_title = "选择会话查看单会话速率".into();
            all_snapshot.selected_tokens_per_second = 0.0;
            all_snapshot
        } else {
            snapshot.clone()
        };

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
        snapshot
    }

    pub fn floating_snapshot(&self) -> FloatingPanelSnapshot {
        let live = self.snapshot(None);
        read_floating_snapshot_from_live(&self.codex_home, &live)
    }

    pub fn reset(&self) {
        let mut state = self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        state.all_snapshot = None;
        state.selected_snapshot = None;
        state.last_signature = None;
        state.last_refresh = None;
        state.last_active_at = None;
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
}

impl LiveRateMonitorState {
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

fn log_store_signature(codex_home: &Path) -> LogStoreSignature {
    let database = file_signature(&codex_home.join("logs_2.sqlite"));
    let wal = file_signature(&codex_home.join("logs_2.sqlite-wal"));
    let state = file_signature(&codex_home.join("state_5.sqlite"));
    let rollout_files = rollout_file_signatures(codex_home)
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
