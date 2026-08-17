//! Process-local coordination for operations that inspect or mutate one Codex
//! Home.  The file locks used by the individual subsystems remain the
//! cross-process boundary; this lock only prevents another Tauri worker in the
//! same process from observing or changing the home concurrently.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread::ThreadId;

#[derive(Default)]
struct Registry {
    homes: HashMap<PathBuf, HomeState>,
}

#[derive(Clone, Copy)]
struct HomeState {
    owner: ThreadId,
    depth: usize,
}

struct RegistryState {
    registry: Mutex<Registry>,
    wake: Condvar,
}

static APP_OPERATION_REGISTRY: OnceLock<RegistryState> = OnceLock::new();

/// A re-entrant, per-Codex-Home process-local operation lease.
///
/// Re-entrancy is intentional: session mutations hold this lease while they
/// re-read the catalog, and that catalog path opens the exact index, which
/// acquires the same lease again on the same worker thread.
pub(crate) struct AppOperationGuard {
    canonical_home: PathBuf,
    owner: ThreadId,
}

impl AppOperationGuard {
    pub(crate) fn acquire(codex_home: &Path) -> Result<Self, String> {
        let canonical_home = codex_home.canonicalize().map_err(|error| {
            format!(
                "无法确认 Codex Home 应用内操作锁路径 {}：{error}",
                codex_home.display()
            )
        })?;
        let owner = std::thread::current().id();
        let state = app_operation_registry();
        let mut registry = state
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        loop {
            match registry.homes.get_mut(&canonical_home) {
                None => {
                    registry.homes.insert(
                        canonical_home.clone(),
                        HomeState { owner, depth: 1 },
                    );
                    return Ok(Self {
                        canonical_home,
                        owner,
                    });
                }
                Some(home) if home.owner == owner => {
                    home.depth = home.depth.saturating_add(1);
                    return Ok(Self {
                        canonical_home,
                        owner,
                    });
                }
                Some(_) => {
                    registry = state
                        .wake
                        .wait(registry)
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                }
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn canonical_home_for_testing(&self) -> &Path {
        &self.canonical_home
    }
}

impl Drop for AppOperationGuard {
    fn drop(&mut self) {
        let state = app_operation_registry();
        let mut registry = state
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let remove = registry.homes.get_mut(&self.canonical_home).is_some_and(|home| {
            // A guard is only ever dropped by its owner. Keep the check so a
            // poisoned/incorrect caller cannot release another worker's lease.
            if home.owner != self.owner {
                return false;
            }
            home.depth = home.depth.saturating_sub(1);
            home.depth == 0
        });
        if remove {
            registry.homes.remove(&self.canonical_home);
            state.wake.notify_all();
        }
    }
}

fn app_operation_registry() -> &'static RegistryState {
    APP_OPERATION_REGISTRY.get_or_init(|| RegistryState {
        registry: Mutex::new(Registry::default()),
        wake: Condvar::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::mpsc;
    use std::time::Duration;

    fn test_home(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "codex-token-bar-app-operation-lock-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn same_thread_reentrancy_does_not_deadlock() {
        let home = test_home("reentrant");
        let outer = AppOperationGuard::acquire(&home).unwrap();
        let inner = AppOperationGuard::acquire(&home).unwrap();
        assert_eq!(outer.canonical_home_for_testing(), inner.canonical_home_for_testing());
        drop(inner);
        drop(outer);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn different_threads_are_serialized_per_home() {
        let home = test_home("serialized");
        let first = AppOperationGuard::acquire(&home).unwrap();
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let worker_home = home.clone();
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let guard = AppOperationGuard::acquire(&worker_home).unwrap();
            release_rx.recv().unwrap();
            drop(guard);
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        std::thread::sleep(Duration::from_millis(25));
        assert!(release_tx.send(()).is_ok());
        drop(first);
        worker.join().unwrap();
        fs::remove_dir_all(home).unwrap();
    }
}
