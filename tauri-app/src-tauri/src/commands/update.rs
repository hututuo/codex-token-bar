use crate::{
    core::{atomic_file, startup_trace},
    platform,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{Emitter, Manager};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_updater::{Update, UpdaterExt};
use tokio::sync::{Mutex, Notify};

const UPDATE_STATE_EVENT: &str = "app-update-state-changed";
const INSTALL_PROGRESS_EVENT: &str = "app-update-install-progress";
const WAKE_INTERVAL: Duration = Duration::from_secs(60);
const CHECK_INTERVAL_MS: i64 = 4 * 60 * 60 * 1_000;

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default)]
struct PersistedUpdateState {
    last_attempt_at: Option<i64>,
    available_version: Option<String>,
    available_body: Option<String>,
    available_date: Option<String>,
    last_notified_version: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateState {
    status: String,
    message: String,
    version: Option<String>,
    body: Option<String>,
    date: Option<String>,
    revision: u64,
}

impl AppUpdateState {
    fn from_persisted(state: &PersistedUpdateState, revision: u64) -> Self {
        match &state.available_version {
            Some(version) => Self {
                status: "available".into(),
                message: format!("发现新版本 {version}"),
                version: Some(version.clone()),
                body: state.available_body.clone(),
                date: state.available_date.clone(),
                revision,
            },
            None => Self::none("", revision),
        }
    }

    fn none(message: impl Into<String>, revision: u64) -> Self {
        Self {
            status: "none".into(),
            message: message.into(),
            version: None,
            body: None,
            date: None,
            revision,
        }
    }
}

#[derive(Clone)]
struct CheckedUpdate<A> {
    version: String,
    body: String,
    date: Option<String>,
    artifact: A,
}

trait UpdateOps<A: Clone + Send + 'static>: Send + Sync {
    fn load(&self) -> Result<Option<PersistedUpdateState>, String>;
    fn persist(&self, state: &PersistedUpdateState) -> Result<(), String>;
    fn check(&self) -> BoxFuture<'_, Result<Option<CheckedUpdate<A>>, String>>;
    fn notify(&self, version: &str) -> Result<(), String>;
    fn present_tray(&self, version: &str) -> Result<bool, String>;
    fn clear_tray(&self) -> Result<bool, String>;
    fn emit(&self, state: &AppUpdateState) -> Result<(), String>;
    fn install(&self, artifact: A) -> BoxFuture<'_, Result<(), String>>;
}

struct RuntimeState<A> {
    persisted: PersistedUpdateState,
    checked: Option<CheckedUpdate<A>>,
    in_flight: Option<u64>,
    completed: BTreeMap<u64, Result<AppUpdateState, String>>,
    next_generation: u64,
    revision: u64,
    installing: bool,
    presented_version: Option<String>,
}

impl<A> Default for RuntimeState<A> {
    fn default() -> Self {
        Self {
            persisted: PersistedUpdateState::default(),
            checked: None,
            in_flight: None,
            completed: BTreeMap::new(),
            next_generation: 0,
            revision: 0,
            installing: false,
            presented_version: None,
        }
    }
}

struct RegistryCore<A> {
    state: Arc<Mutex<RuntimeState<A>>>,
    changed: Arc<Notify>,
    initialized: Arc<AtomicBool>,
    started: Arc<AtomicBool>,
}

impl<A> Clone for RegistryCore<A> {
    fn clone(&self) -> Self {
        Self {
            state: self.state.clone(),
            changed: self.changed.clone(),
            initialized: self.initialized.clone(),
            started: self.started.clone(),
        }
    }
}

impl<A> Default for RegistryCore<A> {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(RuntimeState::default())),
            changed: Arc::new(Notify::new()),
            initialized: Arc::new(AtomicBool::new(false)),
            started: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl<A: Clone + Send + 'static> RegistryCore<A> {
    async fn initialize(&self, ops: &impl UpdateOps<A>) -> Option<String> {
        if self.initialized.swap(true, Ordering::AcqRel) {
            return None;
        }
        match ops.load() {
            Ok(Some(persisted)) => self.state.lock().await.persisted = persisted,
            Ok(None) => {}
            Err(error) => {
                self.state.lock().await.persisted = PersistedUpdateState::default();
                return Some(error);
            }
        }
        None
    }

    async fn reconcile_presentation(&self, ops: &impl UpdateOps<A>) {
        let (available, notified, presented) = {
            let state = self.state.lock().await;
            (
                state.persisted.available_version.clone(),
                state.persisted.last_notified_version.clone(),
                state.presented_version.clone(),
            )
        };

        match available {
            Some(version) => {
                if notified.as_deref() != Some(version.as_str()) {
                    if ops.notify(&version).is_ok() {
                        let snapshot = {
                            let mut state = self.state.lock().await;
                            if state.persisted.available_version.as_deref()
                                != Some(version.as_str())
                            {
                                return;
                            }
                            state.persisted.last_notified_version = Some(version.clone());
                            state.persisted.clone()
                        };
                        if ops.persist(&snapshot).is_err() {
                            self.state.lock().await.persisted.last_notified_version = notified;
                        }
                    }
                }
                if presented.as_deref() != Some(version.as_str()) {
                    if matches!(ops.present_tray(&version), Ok(true)) {
                        let mut state = self.state.lock().await;
                        if state.persisted.available_version.as_deref() == Some(version.as_str()) {
                            state.presented_version = Some(version);
                        }
                    }
                }
            }
            None if presented.is_some() => {
                if matches!(ops.clear_tray(), Ok(true)) {
                    self.state.lock().await.presented_version = None;
                }
            }
            None => {}
        }
    }

    async fn check(
        &self,
        ops: &impl UpdateOps<A>,
        manual: bool,
        now: i64,
    ) -> Result<AppUpdateState, String> {
        self.reconcile_presentation(ops).await;
        let generation = {
            let mut state = self.state.lock().await;
            if let Some(generation) = state.in_flight {
                drop(state);
                return self.wait_for(generation).await;
            }
            if !manual && !automatic_due(state.persisted.last_attempt_at, now) {
                return Ok(AppUpdateState::from_persisted(
                    &state.persisted,
                    state.revision,
                ));
            }
            state.next_generation = state.next_generation.saturating_add(1);
            let generation = state.next_generation;
            state.in_flight = Some(generation);
            state.persisted.last_attempt_at = Some(now);
            generation
        };

        let attempt = self.state.lock().await.persisted.clone();
        if let Err(error) = ops.persist(&attempt) {
            return self.finish(generation, Err(error)).await;
        }

        let checked = ops.check().await;
        let result = match checked {
            Ok(Some(update)) => self.apply_available(ops, update).await,
            Ok(None) => self.apply_none(ops).await,
            Err(error) => {
                let snapshot = {
                    let mut state = self.state.lock().await;
                    state.checked = None;
                    state.revision = state.revision.saturating_add(1);
                    let mut snapshot =
                        AppUpdateState::from_persisted(&state.persisted, state.revision);
                    if snapshot.status == "available" {
                        snapshot.message = format!(
                            "暂时无法检查更新；仍保留已发现版本 {}",
                            snapshot.version.as_deref().unwrap_or_default()
                        );
                    }
                    snapshot
                };
                match ops.emit(&snapshot) {
                    Ok(()) if snapshot.status == "available" => Ok(snapshot),
                    Ok(()) => Err(error),
                    Err(emit_error) => Err(format!("{error}; emit failed: {emit_error}")),
                }
            }
        };
        self.reconcile_presentation(ops).await;
        self.finish(generation, result).await
    }

    async fn apply_available(
        &self,
        ops: &impl UpdateOps<A>,
        update: CheckedUpdate<A>,
    ) -> Result<AppUpdateState, String> {
        let snapshot = {
            let mut state = self.state.lock().await;
            state.persisted.available_version = Some(update.version.clone());
            state.persisted.available_body = Some(update.body.clone());
            state.persisted.available_date = update.date.clone();
            state.checked = Some(update);
            state.revision = state.revision.saturating_add(1);
            let persisted = state.persisted.clone();
            let snapshot = AppUpdateState::from_persisted(&persisted, state.revision);
            (persisted, snapshot)
        };
        ops.persist(&snapshot.0)?;
        ops.emit(&snapshot.1)?;
        Ok(snapshot.1)
    }

    async fn apply_none(&self, ops: &impl UpdateOps<A>) -> Result<AppUpdateState, String> {
        let (persisted, snapshot) = {
            let mut state = self.state.lock().await;
            state.persisted.available_version = None;
            state.persisted.available_body = None;
            state.persisted.available_date = None;
            state.checked = None;
            state.revision = state.revision.saturating_add(1);
            (
                state.persisted.clone(),
                AppUpdateState::none("已是最新版", state.revision),
            )
        };
        ops.persist(&persisted)?;
        ops.emit(&snapshot)?;
        Ok(snapshot)
    }

    async fn finish(
        &self,
        generation: u64,
        result: Result<AppUpdateState, String>,
    ) -> Result<AppUpdateState, String> {
        let mut state = self.state.lock().await;
        if state.in_flight == Some(generation) {
            state.in_flight = None;
            state.completed.insert(generation, result.clone());
        }
        drop(state);
        self.changed.notify_waiters();
        result
    }

    async fn wait_for(&self, generation: u64) -> Result<AppUpdateState, String> {
        loop {
            let notified = self.changed.notified();
            {
                let state = self.state.lock().await;
                if let Some(result) = state.completed.get(&generation) {
                    return result.clone();
                }
            }
            notified.await;
        }
    }

    async fn install(
        &self,
        ops: &impl UpdateOps<A>,
        requested: &str,
        now: i64,
    ) -> Result<(), String> {
        if self.state.lock().await.installing {
            return Err("更新安装已在进行中".into());
        }
        self.check(ops, true, now).await?;
        let artifact = {
            let mut state = self.state.lock().await;
            if state.installing {
                return Err("更新安装已在进行中".into());
            }
            let available = state.persisted.available_version.as_deref();
            let checked = state.checked.as_ref();
            if available != Some(requested)
                || checked.map(|value| value.version.as_str()) != Some(requested)
            {
                return Err("可安装版本已变化，请重新确认".into());
            }
            let artifact = checked.unwrap().artifact.clone();
            state.installing = true;
            artifact
        };
        let result = ops.install(artifact).await;
        self.state.lock().await.installing = false;
        result
    }
}

#[derive(Default)]
pub struct UpdateMonitorRegistry {
    core: RegistryCore<Update>,
}

#[derive(Clone)]
struct TauriUpdateOps {
    app: tauri::AppHandle,
}

impl UpdateOps<Update> for TauriUpdateOps {
    fn load(&self) -> Result<Option<PersistedUpdateState>, String> {
        load_state_soft(&state_path(&self.app)?)
    }

    fn persist(&self, state: &PersistedUpdateState) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(state).map_err(|error| error.to_string())?;
        atomic_file::write_atomically(&state_path(&self.app)?, &bytes)
            .map_err(|error| error.to_string())
    }

    fn check(&self) -> BoxFuture<'_, Result<Option<CheckedUpdate<Update>>, String>> {
        Box::pin(async move {
            let update = self
                .app
                .updater()
                .map_err(|error| error.to_string())?
                .check()
                .await
                .map_err(|error| error.to_string())?;
            Ok(update.map(|artifact| CheckedUpdate {
                version: artifact.version.clone(),
                body: artifact.body.clone().unwrap_or_default(),
                date: artifact.date.map(|date| date.to_string()),
                artifact,
            }))
        })
    }

    fn notify(&self, version: &str) -> Result<(), String> {
        self.app
            .notification()
            .builder()
            .title(format!("Codex Token Bar {version} 可更新"))
            .body("更新已准备好。请从托盘打开主界面并确认安装。")
            .show()
            .map_err(|error| error.to_string())
    }

    fn present_tray(&self, version: &str) -> Result<bool, String> {
        platform::set_update_available_tray_fallback(&self.app, version)
    }

    fn clear_tray(&self) -> Result<bool, String> {
        platform::clear_update_available_tray_fallback(&self.app)
    }

    fn emit(&self, state: &AppUpdateState) -> Result<(), String> {
        self.app
            .emit(UPDATE_STATE_EVENT, state)
            .map_err(|error| error.to_string())
    }

    fn install(&self, artifact: Update) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            let progress_app = self.app.clone();
            artifact
                .download_and_install(
                    move |chunk, total| {
                        let _ = progress_app.emit(
                            INSTALL_PROGRESS_EVENT,
                            serde_json::json!({"chunkLength": chunk, "contentLength": total}),
                        );
                    },
                    {
                        let app = self.app.clone();
                        move || {
                            let _ = app.emit(
                                INSTALL_PROGRESS_EVENT,
                                serde_json::json!({"finished": true}),
                            );
                        }
                    },
                )
                .await
                .map_err(|error| error.to_string())?;
            self.app.restart();
        })
    }
}

impl UpdateMonitorRegistry {
    pub fn initialize_and_start(&self, app: tauri::AppHandle) {
        if self.core.started.swap(true, Ordering::AcqRel) {
            return;
        }
        let ops = TauriUpdateOps { app: app.clone() };
        if !self.core.initialized.swap(true, Ordering::AcqRel) {
            match ops.load() {
                Ok(Some(persisted)) => {
                    self.core
                        .state
                        .try_lock()
                        .expect("update state is unowned during setup")
                        .persisted = persisted
                }
                Ok(None) => {}
                Err(error) => {
                    self.core
                        .state
                        .try_lock()
                        .expect("update state is unowned during setup")
                        .persisted = PersistedUpdateState::default();
                    startup_trace::mark(&format!("update monitor state recovered: {error}"));
                    eprintln!("Codex Token Bar: update monitor state recovered: {error}");
                }
            }
        }
        let core = RegistryCore {
            state: self.core.state.clone(),
            changed: self.core.changed.clone(),
            initialized: self.core.initialized.clone(),
            started: self.core.started.clone(),
        };
        tauri::async_runtime::spawn(async move {
            loop {
                core.reconcile_presentation(&ops).await;
                let _ = core.check(&ops, false, now_ms()).await;
                tokio::time::sleep(WAKE_INTERVAL).await;
            }
        });
    }
}

fn state_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_data_dir()
        .map(|path| path.join("update-monitor-state.json"))
        .map_err(|error| error.to_string())
}

fn load_state_soft(path: &Path) -> Result<Option<PersistedUpdateState>, String> {
    match std::fs::read(path) {
        Ok(bytes) => match serde_json::from_slice(&bytes) {
            Ok(state) => Ok(Some(state)),
            Err(error) => {
                quarantine_bad_state(path);
                Err(format!("corrupt update state quarantined: {error}"))
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => {
            quarantine_bad_state(path);
            Err(format!("update state read failed: {error}"))
        }
    }
}

fn quarantine_bad_state(path: &Path) {
    let quarantine = path.with_extension(format!("corrupt-{}", now_ms()));
    let _ = std::fs::rename(path, quarantine);
}

fn automatic_due(last_attempt_at: Option<i64>, now: i64) -> bool {
    last_attempt_at
        .map(|attempt| attempt > now || now - attempt >= CHECK_INTERVAL_MS)
        .unwrap_or(true)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[tauri::command]
pub async fn read_app_update_state(
    registry: tauri::State<'_, UpdateMonitorRegistry>,
) -> Result<AppUpdateState, String> {
    let state = registry.core.state.lock().await;
    Ok(AppUpdateState::from_persisted(
        &state.persisted,
        state.revision,
    ))
}

#[tauri::command]
pub async fn check_app_update(
    app: tauri::AppHandle,
    registry: tauri::State<'_, UpdateMonitorRegistry>,
) -> Result<AppUpdateState, String> {
    registry
        .core
        .check(&TauriUpdateOps { app }, true, now_ms())
        .await
}

#[tauri::command]
pub async fn install_app_update(
    app: tauri::AppHandle,
    registry: tauri::State<'_, UpdateMonitorRegistry>,
    version: String,
) -> Result<(), String> {
    registry
        .core
        .install(&TauriUpdateOps { app }, &version, now_ms())
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Mutex as StdMutex,
    };

    struct MockOps {
        loaded: StdMutex<Result<Option<PersistedUpdateState>, String>>,
        persisted: StdMutex<Vec<PersistedUpdateState>>,
        checks: AtomicUsize,
        installs: AtomicUsize,
        notifications: AtomicUsize,
        tray_attempts: AtomicUsize,
        clear_attempts: AtomicUsize,
        events: StdMutex<Vec<AppUpdateState>>,
        check_result: StdMutex<Result<Option<CheckedUpdate<String>>, String>>,
        fail_persist: AtomicBool,
        fail_emit: AtomicBool,
        fail_tray_once: AtomicBool,
        fail_install: AtomicBool,
        fail_notify: AtomicBool,
        check_delay_ms: AtomicU64,
        install_delay_ms: AtomicU64,
    }

    impl MockOps {
        fn available(version: &str) -> Self {
            let ops = Self::default();
            *ops.check_result.lock().unwrap() = Ok(Some(CheckedUpdate {
                version: version.into(),
                body: "notes".into(),
                date: None,
                artifact: version.into(),
            }));
            ops
        }
    }

    impl UpdateOps<String> for MockOps {
        fn load(&self) -> Result<Option<PersistedUpdateState>, String> {
            self.loaded.lock().unwrap().clone()
        }
        fn persist(&self, state: &PersistedUpdateState) -> Result<(), String> {
            if self.fail_persist.load(Ordering::SeqCst) {
                return Err("persist failed".into());
            }
            self.persisted.lock().unwrap().push(state.clone());
            Ok(())
        }
        fn check(&self) -> BoxFuture<'_, Result<Option<CheckedUpdate<String>>, String>> {
            self.checks.fetch_add(1, Ordering::SeqCst);
            let result = self.check_result.lock().unwrap().clone();
            let delay = self.check_delay_ms.load(Ordering::SeqCst);
            Box::pin(async move {
                if delay > 0 {
                    tokio::time::sleep(Duration::from_millis(delay)).await;
                }
                result
            })
        }
        fn notify(&self, _version: &str) -> Result<(), String> {
            self.notifications.fetch_add(1, Ordering::SeqCst);
            if self.fail_notify.load(Ordering::SeqCst) {
                Err("notification denied".into())
            } else {
                Ok(())
            }
        }
        fn present_tray(&self, _version: &str) -> Result<bool, String> {
            self.tray_attempts.fetch_add(1, Ordering::SeqCst);
            if self.fail_tray_once.swap(false, Ordering::SeqCst) {
                Err("tray failed".into())
            } else {
                Ok(true)
            }
        }
        fn clear_tray(&self) -> Result<bool, String> {
            self.clear_attempts.fetch_add(1, Ordering::SeqCst);
            Ok(true)
        }
        fn emit(&self, state: &AppUpdateState) -> Result<(), String> {
            if self.fail_emit.load(Ordering::SeqCst) {
                return Err("emit failed".into());
            }
            self.events.lock().unwrap().push(state.clone());
            Ok(())
        }
        fn install(&self, _artifact: String) -> BoxFuture<'_, Result<(), String>> {
            self.installs.fetch_add(1, Ordering::SeqCst);
            let fail = self.fail_install.load(Ordering::SeqCst);
            let delay = self.install_delay_ms.load(Ordering::SeqCst);
            Box::pin(async move {
                if delay > 0 {
                    tokio::time::sleep(Duration::from_millis(delay)).await;
                }
                if fail {
                    Err("install failed".into())
                } else {
                    Ok(())
                }
            })
        }
    }

    impl Default for MockOps {
        fn default() -> Self {
            Self {
                loaded: StdMutex::new(Ok(None)),
                persisted: StdMutex::new(Vec::new()),
                checks: AtomicUsize::new(0),
                installs: AtomicUsize::new(0),
                notifications: AtomicUsize::new(0),
                tray_attempts: AtomicUsize::new(0),
                clear_attempts: AtomicUsize::new(0),
                events: StdMutex::new(Vec::new()),
                check_result: StdMutex::new(Ok(None)),
                fail_persist: AtomicBool::new(false),
                fail_emit: AtomicBool::new(false),
                fail_tray_once: AtomicBool::new(false),
                fail_install: AtomicBool::new(false),
                fail_notify: AtomicBool::new(false),
                check_delay_ms: AtomicU64::new(0),
                install_delay_ms: AtomicU64::new(0),
            }
        }
    }

    #[test]
    fn attempt_is_persisted_before_network_and_automatic_never_installs() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::available("0.8.0");
            core.check(&ops, false, 42).await.unwrap();
            assert_eq!(
                ops.persisted
                    .lock()
                    .unwrap()
                    .first()
                    .unwrap()
                    .last_attempt_at,
                Some(42)
            );
            assert_eq!(ops.checks.load(Ordering::SeqCst), 1);
            assert_eq!(ops.installs.load(Ordering::SeqCst), 0);
        });
    }

    #[test]
    fn every_failure_finishes_generation_and_next_manual_can_retry() {
        runtime().block_on(async {
            for failure in ["persist", "check", "emit"] {
                let core = RegistryCore::<String>::default();
                let ops = MockOps::available("0.8.0");
                if failure == "persist" {
                    ops.fail_persist.store(true, Ordering::SeqCst);
                }
                if failure == "check" {
                    *ops.check_result.lock().unwrap() = Err("check failed".into());
                }
                if failure == "emit" {
                    ops.fail_emit.store(true, Ordering::SeqCst);
                }
                let _ = core.check(&ops, true, 1).await;
                assert_eq!(core.state.lock().await.in_flight, None, "{failure}");
            }
        });
    }

    #[test]
    fn automatic_and_manual_wait_for_the_same_generation() {
        runtime().block_on(async {
            let core = Arc::new(RegistryCore::<String>::default());
            let ops = Arc::new(MockOps::available("0.8.0"));
            ops.check_delay_ms.store(25, Ordering::SeqCst);
            let automatic = tokio::spawn({
                let core = core.clone();
                let ops = ops.clone();
                async move { core.check(ops.as_ref(), false, 1).await }
            });
            tokio::time::sleep(Duration::from_millis(2)).await;
            let manual = tokio::spawn({
                let core = core.clone();
                let ops = ops.clone();
                async move { core.check(ops.as_ref(), true, 2).await }
            });
            let automatic = automatic.await.unwrap().unwrap();
            let manual = manual.await.unwrap().unwrap();
            assert_eq!(automatic, manual);
            assert_eq!(ops.checks.load(Ordering::SeqCst), 1);
        });
    }

    #[test]
    fn startup_restores_presentation_notification_dedupes_and_tray_retries() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::default();
            *ops.loaded.lock().unwrap() = Ok(Some(PersistedUpdateState {
                available_version: Some("0.8.0".into()),
                last_notified_version: Some("0.8.0".into()),
                ..Default::default()
            }));
            core.initialize(&ops).await;
            ops.fail_tray_once.store(true, Ordering::SeqCst);
            core.reconcile_presentation(&ops).await;
            core.reconcile_presentation(&ops).await;
            assert_eq!(ops.notifications.load(Ordering::SeqCst), 0);
            assert_eq!(ops.tray_attempts.load(Ordering::SeqCst), 2);
            assert_eq!(
                core.state.lock().await.presented_version.as_deref(),
                Some("0.8.0")
            );
        });
    }

    #[test]
    fn notification_failure_uses_tray_without_claiming_notification_dedupe() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::default();
            *ops.loaded.lock().unwrap() = Ok(Some(PersistedUpdateState {
                available_version: Some("0.8.0".into()),
                ..Default::default()
            }));
            ops.fail_notify.store(true, Ordering::SeqCst);
            core.initialize(&ops).await;
            core.reconcile_presentation(&ops).await;
            let state = core.state.lock().await;
            assert_eq!(ops.notifications.load(Ordering::SeqCst), 1);
            assert_eq!(ops.tray_attempts.load(Ordering::SeqCst), 1);
            assert_eq!(state.persisted.last_notified_version, None);
            assert_eq!(state.presented_version.as_deref(), Some("0.8.0"));
        });
    }

    #[test]
    fn corrupt_load_is_soft_and_duplicate_initialize_is_single_owner() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::default();
            *ops.loaded.lock().unwrap() = Err("corrupt quarantined".into());
            assert!(core.initialize(&ops).await.is_some());
            assert!(core.initialize(&ops).await.is_none());
            assert_eq!(
                core.state.lock().await.persisted,
                PersistedUpdateState::default()
            );
        });
    }

    #[test]
    fn corrupt_file_is_quarantined_and_defaults_continue() {
        let root = std::env::temp_dir().join(format!("update-monitor-corrupt-{}", now_ms()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("state.json");
        std::fs::write(&path, b"{truncated").unwrap();
        assert!(load_state_soft(&path).is_err());
        assert!(!path.exists());
        assert!(std::fs::read_dir(&root).unwrap().any(|entry| entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("corrupt-")));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn none_clears_tray_and_network_failure_keeps_trusted_available() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::available("0.8.0");
            core.check(&ops, true, 1).await.unwrap();
            *ops.check_result.lock().unwrap() = Err("offline".into());
            let snapshot = core.check(&ops, true, 2).await.unwrap();
            assert_eq!(snapshot.version.as_deref(), Some("0.8.0"));
            *ops.check_result.lock().unwrap() = Ok(None);
            core.check(&ops, true, 3).await.unwrap();
            assert!(ops.clear_attempts.load(Ordering::SeqCst) > 0);
        });
    }

    #[test]
    fn install_lease_runs_once_releases_on_error_and_rejects_version_race() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::available("0.8.0");
            core.install(&ops, "0.8.0", 1).await.unwrap();
            assert_eq!(ops.installs.load(Ordering::SeqCst), 1);
            ops.fail_install.store(true, Ordering::SeqCst);
            assert!(core.install(&ops, "0.8.0", 2).await.is_err());
            assert!(!core.state.lock().await.installing);
            *ops.check_result.lock().unwrap() = Ok(Some(CheckedUpdate {
                version: "0.9.0".into(),
                body: String::new(),
                date: None,
                artifact: "0.9.0".into(),
            }));
            assert!(core.install(&ops, "0.8.0", 3).await.is_err());
            assert_eq!(ops.installs.load(Ordering::SeqCst), 2);
        });
    }

    #[test]
    fn concurrent_install_requests_download_once() {
        runtime().block_on(async {
            let core = Arc::new(RegistryCore::<String>::default());
            let ops = Arc::new(MockOps::available("0.8.0"));
            ops.install_delay_ms.store(25, Ordering::SeqCst);
            let first = tokio::spawn({
                let core = core.clone();
                let ops = ops.clone();
                async move { core.install(ops.as_ref(), "0.8.0", 1).await }
            });
            tokio::time::sleep(Duration::from_millis(5)).await;
            let second = core.install(ops.as_ref(), "0.8.0", 2).await;
            assert!(second.is_err());
            first.await.unwrap().unwrap();
            assert_eq!(ops.installs.load(Ordering::SeqCst), 1);
        });
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
    }
}
