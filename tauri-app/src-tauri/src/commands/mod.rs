pub(crate) mod auto_resume;
pub(crate) mod codex_radar;
pub(crate) mod codex_instances;
pub(crate) mod dashboard;
pub(crate) mod live;
pub(crate) mod provider_repair;
pub(crate) mod settings;
pub(crate) mod startup;
pub(crate) mod surface;
pub(crate) mod thread_delete;
pub(crate) mod thread_activity;
pub(crate) mod update;
pub(crate) mod window_auth;

use crate::core::dashboard::LocalCodexDataSource;
use crate::platform;

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
