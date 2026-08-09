pub(crate) mod auto_resume;
pub(crate) mod codex_radar;
pub(crate) mod codex_instances;
pub(crate) mod dashboard;
pub(crate) mod live;
pub(crate) mod provider_repair;
pub(crate) mod session_management;
pub(crate) mod settings;
pub(crate) mod startup;
pub(crate) mod surface;
pub(crate) mod thread_delete;
pub(crate) mod thread_activity;
pub(crate) mod update;
pub(crate) mod window_auth;

use crate::core::dashboard::LocalCodexDataSource;
use crate::platform;
use std::time::Instant;

pub(crate) fn local_source() -> LocalCodexDataSource {
    LocalCodexDataSource::new(platform::default_codex_home())
}

// 同步 IPC 命令在主线程执行；任何带磁盘 IO 的命令一律 async + 本助手，把
// 阻塞体移交阻塞线程池——主线程与 tokio worker 都不允许直接落盘。
pub(crate) async fn run_blocking_command<T, F>(work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

/// Move a blocking operation to Tauri's blocking pool while reporting the
/// monotonic enqueue-to-worker-start delay to a caller-owned diagnostic hook.
/// The hook runs once, immediately before `work`, and is intentionally kept
/// separate from the normal helper so ordinary commands do not gain tracing
/// overhead or additional logging.
pub(crate) async fn run_blocking_command_with_worker_start<T, F, OnWorkerStart>(
    work: F,
    on_worker_start: OnWorkerStart,
) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
    OnWorkerStart: FnOnce(u64) + Send + 'static,
{
    let enqueued_at = Instant::now();
    tauri::async_runtime::spawn_blocking(move || {
        let queue_wait_ms = u64::try_from(enqueued_at.elapsed().as_millis()).unwrap_or(u64::MAX);
        on_worker_start(queue_wait_ms);
        work()
    })
    .await
    .map_err(|error| error.to_string())?
}
