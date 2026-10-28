use serde::Serialize;
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::Notify;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BusinessStartupPhase {
    Preparing,
    Ready,
    Error,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BusinessStartupSnapshot {
    pub(crate) phase: BusinessStartupPhase,
    pub(crate) message: Option<String>,
}

struct CoordinatorState {
    snapshot: BusinessStartupSnapshot,
    job_running: bool,
    initial_job_claimed: bool,
}

/// Process-owned readiness coordinator for business container A.
///
/// Instances are cheap clones around isolated state, which also lets tests
/// exercise transitions without touching the process-wide app coordinator.
#[derive(Clone)]
pub(crate) struct BusinessStartupCoordinator {
    state: Arc<Mutex<CoordinatorState>>,
    changed: Arc<Notify>,
}

impl Default for BusinessStartupCoordinator {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(CoordinatorState {
                snapshot: BusinessStartupSnapshot {
                    phase: BusinessStartupPhase::Preparing,
                    message: None,
                },
                job_running: false,
                initial_job_claimed: false,
            })),
            changed: Arc::new(Notify::new()),
        }
    }
}

impl BusinessStartupCoordinator {
    pub(crate) fn snapshot(&self) -> BusinessStartupSnapshot {
        lock(&self.state).snapshot.clone()
    }

    pub(crate) fn begin_initial(&self) -> bool {
        let mut state = lock(&self.state);
        if state.initial_job_claimed || state.job_running {
            return false;
        }
        state.initial_job_claimed = true;
        state.job_running = true;
        state.snapshot = BusinessStartupSnapshot {
            phase: BusinessStartupPhase::Preparing,
            message: None,
        };
        drop(state);
        self.changed.notify_waiters();
        true
    }

    pub(crate) fn begin_retry(&self) -> Result<(), String> {
        let mut state = lock(&self.state);
        if state.job_running {
            return Err("本地业务数据初始化正在进行".into());
        }
        if state.snapshot.phase != BusinessStartupPhase::Error {
            return Err("本地业务数据初始化仅可在失败后重试".into());
        }
        state.job_running = true;
        state.snapshot = BusinessStartupSnapshot {
            phase: BusinessStartupPhase::Preparing,
            message: None,
        };
        drop(state);
        self.changed.notify_waiters();
        Ok(())
    }

    pub(crate) fn finish(&self, result: Result<(), String>) -> BusinessStartupSnapshot {
        let mut state = lock(&self.state);
        state.job_running = false;
        state.snapshot = match result {
            Ok(()) => BusinessStartupSnapshot {
                phase: BusinessStartupPhase::Ready,
                message: None,
            },
            Err(message) => BusinessStartupSnapshot {
                phase: BusinessStartupPhase::Error,
                message: Some(message),
            },
        };
        let snapshot = state.snapshot.clone();
        drop(state);
        self.changed.notify_waiters();
        snapshot
    }

    pub(crate) fn ensure_ready(&self) -> Result<(), String> {
        match self.snapshot().phase {
            BusinessStartupPhase::Ready => Ok(()),
            BusinessStartupPhase::Preparing | BusinessStartupPhase::Error => {
                Err("本地业务数据尚未就绪".into())
            }
        }
    }

    pub(crate) async fn wait_until_ready(&self) {
        loop {
            let changed = self.changed.notified();
            tokio::pin!(changed);
            // Register before checking readiness, then broadcast transitions:
            // every owner wakes, including when completion races this check.
            changed.as_mut().enable();
            if self.snapshot().phase == BusinessStartupPhase::Ready {
                return;
            }
            changed.await;
        }
    }
}

static PROCESS_COORDINATOR: OnceLock<BusinessStartupCoordinator> = OnceLock::new();

pub(crate) fn process_coordinator() -> BusinessStartupCoordinator {
    PROCESS_COORDINATOR
        .get_or_init(BusinessStartupCoordinator::default)
        .clone()
}

#[cfg(test)]
mod tests {
    use super::{BusinessStartupCoordinator, BusinessStartupPhase};
    use std::sync::{Arc, Barrier};
    use std::thread;

    #[test]
    fn all_deferred_owners_resume_after_readiness() {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
            .block_on(async {
                let coordinator = BusinessStartupCoordinator::default();
                coordinator.begin_initial();
                let mut jobs = Vec::new();
                for _ in 0..8 {
                    let owner = coordinator.clone();
                    jobs.push(tokio::spawn(async move { owner.wait_until_ready().await }));
                }
                tokio::task::yield_now().await;
                coordinator.finish(Ok(()));
                for job in jobs {
                    tokio::time::timeout(std::time::Duration::from_secs(1), job)
                        .await
                        .expect("every owner must wake")
                        .expect("owner must complete");
                }
            });
    }

    #[test]
    fn business_store_gate_opens_only_after_bootstrap_finishes() {
        let coordinator = BusinessStartupCoordinator::default();

        assert_eq!(
            coordinator.snapshot().phase,
            BusinessStartupPhase::Preparing
        );
        assert!(coordinator.ensure_ready().is_err());
        assert!(coordinator.begin_initial());
        assert!(coordinator.ensure_ready().is_err());

        coordinator.finish(Ok(()));
        assert_eq!(coordinator.snapshot().phase, BusinessStartupPhase::Ready);
        assert!(coordinator.ensure_ready().is_ok());
        assert!(coordinator.begin_retry().is_err());
    }

    #[test]
    fn failed_bootstrap_can_be_retried_once_without_duplicate_jobs() {
        let coordinator = BusinessStartupCoordinator::default();
        assert!(coordinator.begin_initial());
        let failed = coordinator.finish(Err("fixture failure".into()));
        assert_eq!(failed.phase, BusinessStartupPhase::Error);
        assert_eq!(failed.message.as_deref(), Some("fixture failure"));
        assert!(coordinator.ensure_ready().is_err());

        let workers = 8;
        let barrier = Arc::new(Barrier::new(workers));
        let joins = (0..workers)
            .map(|_| {
                let coordinator = coordinator.clone();
                let barrier = barrier.clone();
                thread::spawn(move || {
                    barrier.wait();
                    coordinator.begin_retry().is_ok()
                })
            })
            .collect::<Vec<_>>();
        let successful_retries = joins
            .into_iter()
            .map(|join| join.join().unwrap())
            .filter(|started| *started)
            .count();
        assert_eq!(successful_retries, 1);
        assert_eq!(
            coordinator.snapshot().phase,
            BusinessStartupPhase::Preparing
        );

        let ready = coordinator.finish(Ok(()));
        assert_eq!(ready.phase, BusinessStartupPhase::Ready);
        assert!(coordinator.ensure_ready().is_ok());
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}
