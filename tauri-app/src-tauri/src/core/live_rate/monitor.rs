use super::{read_snapshot, read_floating_snapshot_from_live};
use crate::models::{FloatingPanelSnapshot, LiveRateSnapshot};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

const FAST_REFRESH_INTERVAL: Duration = Duration::from_millis(250);
const IDLE_REFRESH_INTERVAL: Duration = Duration::from_secs(1);

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
    refresh_count: usize,
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
        let signature = log_store_signature(&self.codex_home);
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

        let all_snapshot = read_snapshot(&self.codex_home, None);
        let snapshot = if let Some(thread_id) = selected_thread_id {
            read_snapshot(&self.codex_home, Some(thread_id))
        } else {
            all_snapshot.clone()
        };

        state.all_snapshot = Some(all_snapshot);
        state.selected_snapshot = Some(SelectedSnapshot {
            selected_thread_id: selected_thread_id.map(ToOwned::to_owned),
            snapshot: snapshot.clone(),
        });
        state.last_signature = Some(signature);
        state.last_refresh = Some(Instant::now());
        state.refresh_count += 1;
        snapshot
    }

    pub fn floating_snapshot(&self) -> FloatingPanelSnapshot {
        let live = self.snapshot(None);
        read_floating_snapshot_from_live(&self.codex_home, &live)
    }

    #[cfg(test)]
    pub fn test_refresh_count(&self) -> usize {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .refresh_count
    }
}

impl LiveRateMonitorState {
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
        let interval = if self
            .all_snapshot
            .as_ref()
            .is_some_and(|snapshot| snapshot.tokens_per_second > 0.05)
        {
            FAST_REFRESH_INTERVAL
        } else {
            IDLE_REFRESH_INTERVAL
        };
        last_refresh.elapsed() >= interval
    }
}

fn log_store_signature(codex_home: &Path) -> LogStoreSignature {
    let database = file_signature(&codex_home.join("logs_2.sqlite"));
    let wal = file_signature(&codex_home.join("logs_2.sqlite-wal"));
    LogStoreSignature {
        database_len: database.len,
        database_modified_at: database.modified_at,
        wal_len: wal.len,
        wal_modified_at: wal.modified_at,
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
