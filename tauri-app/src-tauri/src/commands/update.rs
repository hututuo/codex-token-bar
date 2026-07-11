use crate::{
    core::{atomic_file, startup_trace},
    platform,
};
use serde::{Deserialize, Serialize};
use std::{
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
const PRESENTATION_MAX_FAILURES: u8 = 3;
const PRESENTATION_BACKOFF_MS: i64 = 5 * 60 * 1_000;

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

#[derive(Clone, Debug, Eq, PartialEq)]
struct PresentationClaim {
    version: String,
    revision: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum TrayTarget {
    Available(String),
    Clear,
}

#[derive(Clone, Debug)]
struct RetryState<K> {
    key: K,
    failures: u8,
    next_attempt_at: i64,
}

fn retry_allowed<K: Eq>(retry: &Option<RetryState<K>>, key: &K, now: i64, explicit: bool) -> bool {
    match retry {
        Some(retry) if &retry.key == key && retry.failures >= PRESENTATION_MAX_FAILURES => explicit,
        Some(retry) if &retry.key == key => explicit || now >= retry.next_attempt_at,
        _ => true,
    }
}

fn record_failure<K: Clone + Eq>(retry: &mut Option<RetryState<K>>, key: K, now: i64) {
    let failures = retry
        .as_ref()
        .filter(|value| value.key == key)
        .map(|value| value.failures)
        .unwrap_or(0)
        .saturating_add(1);
    let exponent = u32::from(failures.saturating_sub(1).min(4));
    *retry = Some(RetryState {
        key,
        failures,
        next_attempt_at: now
            .saturating_add(PRESENTATION_BACKOFF_MS.saturating_mul(1_i64 << exponent)),
    });
}

fn tray_target_matches(target: &TrayTarget, available: Option<&str>) -> bool {
    match target {
        TrayTarget::Available(version) => available == Some(version.as_str()),
        TrayTarget::Clear => available.is_none(),
    }
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
    in_flight: Option<(u64, Arc<CompletionSlot>)>,
    next_generation: u64,
    revision: u64,
    installing: bool,
    presented_version: Option<String>,
    shown_notification_version: Option<String>,
    notification_claim: Option<PresentationClaim>,
    notification_retry: Option<RetryState<String>>,
    dedupe_persist_claim: Option<PresentationClaim>,
    dedupe_persist_retry: Option<RetryState<String>>,
    tray_claim: Option<(TrayTarget, u64)>,
    tray_retry: Option<RetryState<TrayTarget>>,
}

impl<A> Default for RuntimeState<A> {
    fn default() -> Self {
        Self {
            persisted: PersistedUpdateState::default(),
            checked: None,
            in_flight: None,
            next_generation: 0,
            revision: 0,
            installing: false,
            presented_version: None,
            shown_notification_version: None,
            notification_claim: None,
            notification_retry: None,
            dedupe_persist_claim: None,
            dedupe_persist_retry: None,
            tray_claim: None,
            tray_retry: None,
        }
    }
}

#[derive(Default)]
struct CompletionSlot {
    result: Mutex<Option<Result<AppUpdateState, String>>>,
    ready: Notify,
}

struct RegistryCore<A> {
    state: Arc<Mutex<RuntimeState<A>>>,
    persist_lock: Arc<Mutex<()>>,
    initialized: Arc<AtomicBool>,
    started: Arc<AtomicBool>,
}

impl<A> Clone for RegistryCore<A> {
    fn clone(&self) -> Self {
        Self {
            state: self.state.clone(),
            persist_lock: self.persist_lock.clone(),
            initialized: self.initialized.clone(),
            started: self.started.clone(),
        }
    }
}

impl<A> Default for RegistryCore<A> {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(RuntimeState::default())),
            persist_lock: Arc::new(Mutex::new(())),
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
            Ok(Some(persisted)) => {
                let mut state = self.state.lock().await;
                state.shown_notification_version = persisted.last_notified_version.clone();
                state.persisted = persisted;
            }
            Ok(None) => {}
            Err(error) => {
                self.state.lock().await.persisted = PersistedUpdateState::default();
                return Some(error);
            }
        }
        None
    }

    async fn reconcile_presentation(&self, ops: &impl UpdateOps<A>, now: i64, explicit: bool) {
        let (notification_claim, tray_claim, dedupe_claim) = {
            let mut state = self.state.lock().await;
            let available = state.persisted.available_version.clone();
            let revision = state.revision;

            let notification = available.as_ref().and_then(|version| {
                let claim = PresentationClaim {
                    version: version.clone(),
                    revision,
                };
                let needed = state.shown_notification_version.as_deref() != Some(version.as_str())
                    && state.persisted.last_notified_version.as_deref() != Some(version.as_str());
                if needed
                    && state.notification_claim.is_none()
                    && retry_allowed(&state.notification_retry, version, now, explicit)
                {
                    if explicit {
                        state.notification_retry = None;
                    }
                    state.notification_claim = Some(claim.clone());
                    Some(claim)
                } else {
                    None
                }
            });

            let target = available
                .clone()
                .map(TrayTarget::Available)
                .unwrap_or(TrayTarget::Clear);
            let tray_needed = match &target {
                TrayTarget::Available(version) => {
                    state.presented_version.as_deref() != Some(version.as_str())
                }
                TrayTarget::Clear => state.presented_version.is_some(),
            };
            let tray = if tray_needed
                && state.tray_claim.is_none()
                && retry_allowed(&state.tray_retry, &target, now, explicit)
            {
                if explicit {
                    state.tray_retry = None;
                }
                state.tray_claim = Some((target.clone(), revision));
                Some((target, revision))
            } else {
                None
            };

            let dedupe = available.as_ref().and_then(|version| {
                let pending = state.shown_notification_version.as_deref() == Some(version.as_str())
                    && state.persisted.last_notified_version.as_deref() != Some(version.as_str());
                let claim = PresentationClaim {
                    version: version.clone(),
                    revision,
                };
                if pending
                    && state.dedupe_persist_claim.is_none()
                    && retry_allowed(&state.dedupe_persist_retry, version, now, explicit)
                {
                    if explicit {
                        state.dedupe_persist_retry = None;
                    }
                    state.dedupe_persist_claim = Some(claim.clone());
                    Some(claim)
                } else {
                    None
                }
            });
            (notification, tray, dedupe)
        };

        if let Some(claim) = notification_claim {
            let result = ops.notify(&claim.version);
            let mut state = self.state.lock().await;
            if state.notification_claim.as_ref() == Some(&claim) {
                state.notification_claim = None;
                if result.is_ok()
                    && state.persisted.available_version.as_deref() == Some(claim.version.as_str())
                {
                    state.shown_notification_version = Some(claim.version.clone());
                    state.notification_retry = None;
                } else if result.is_err() {
                    record_failure(&mut state.notification_retry, claim.version, now);
                }
            }
        }

        if let Some((target, revision)) = tray_claim {
            let result = match &target {
                TrayTarget::Available(version) => ops.present_tray(version),
                TrayTarget::Clear => ops.clear_tray(),
            };
            let mut state = self.state.lock().await;
            if state.tray_claim.as_ref() == Some(&(target.clone(), revision)) {
                state.tray_claim = None;
                if matches!(result, Ok(true))
                    && tray_target_matches(&target, state.persisted.available_version.as_deref())
                {
                    state.presented_version = match &target {
                        TrayTarget::Available(version) => Some(version.clone()),
                        TrayTarget::Clear => None,
                    };
                    state.tray_retry = None;
                } else if !matches!(result, Ok(true)) {
                    record_failure(&mut state.tray_retry, target, now);
                }
            }
        }

        let dedupe_claim = if dedupe_claim.is_some() {
            dedupe_claim
        } else {
            let mut state = self.state.lock().await;
            let available = state.persisted.available_version.clone();
            available.and_then(|version| {
                let claim = PresentationClaim {
                    version: version.clone(),
                    revision: state.revision,
                };
                let pending = state.shown_notification_version.as_deref() == Some(version.as_str())
                    && state.persisted.last_notified_version.as_deref() != Some(version.as_str());
                if pending
                    && state.dedupe_persist_claim.is_none()
                    && retry_allowed(&state.dedupe_persist_retry, &version, now, explicit)
                {
                    state.dedupe_persist_claim = Some(claim.clone());
                    Some(claim)
                } else {
                    None
                }
            })
        };
        if let Some(claim) = dedupe_claim {
            let _persist_owner = self.persist_lock.lock().await;
            let snapshot = {
                let state = self.state.lock().await;
                if state.dedupe_persist_claim.as_ref() != Some(&claim)
                    || state.persisted.available_version.as_deref() != Some(claim.version.as_str())
                {
                    drop(state);
                    let mut state = self.state.lock().await;
                    if state.dedupe_persist_claim.as_ref() == Some(&claim) {
                        state.dedupe_persist_claim = None;
                    }
                    return;
                }
                let mut snapshot = state.persisted.clone();
                snapshot.last_notified_version = Some(claim.version.clone());
                snapshot
            };
            let result = ops.persist(&snapshot);
            let mut state = self.state.lock().await;
            if state.dedupe_persist_claim.as_ref() == Some(&claim) {
                state.dedupe_persist_claim = None;
                if result.is_ok()
                    && state.persisted.available_version.as_deref() == Some(claim.version.as_str())
                {
                    state.persisted.last_notified_version = Some(claim.version);
                    state.dedupe_persist_retry = None;
                } else if result.is_err() {
                    record_failure(&mut state.dedupe_persist_retry, claim.version, now);
                }
            }
        }
    }

    async fn check(
        &self,
        ops: &impl UpdateOps<A>,
        manual: bool,
        now: i64,
    ) -> Result<AppUpdateState, String> {
        let (generation, previous_attempt) = {
            let mut state = self.state.lock().await;
            if let Some((_, slot)) = &state.in_flight {
                let slot = slot.clone();
                drop(state);
                return wait_for_slot(slot).await;
            }
            if !manual && !automatic_due(state.persisted.last_attempt_at, now) {
                return Ok(AppUpdateState::from_persisted(
                    &state.persisted,
                    state.revision,
                ));
            }
            state.next_generation = state.next_generation.saturating_add(1);
            let generation = state.next_generation;
            state.in_flight = Some((generation, Arc::new(CompletionSlot::default())));
            let previous_attempt = state.persisted.last_attempt_at;
            state.persisted.last_attempt_at = Some(now);
            (generation, previous_attempt)
        };

        let attempt = self.state.lock().await.persisted.clone();
        let _persist_owner = self.persist_lock.lock().await;
        if let Err(error) = ops.persist(&attempt) {
            let mut state = self.state.lock().await;
            if state.in_flight.as_ref().map(|value| value.0) == Some(generation)
                && state.persisted.last_attempt_at == Some(now)
            {
                state.persisted.last_attempt_at = previous_attempt;
            }
            drop(state);
            return self.finish(generation, Err(error)).await;
        }
        drop(_persist_owner);

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
        self.finish(generation, result).await
    }

    async fn apply_available(
        &self,
        ops: &impl UpdateOps<A>,
        update: CheckedUpdate<A>,
    ) -> Result<AppUpdateState, String> {
        let _persist_owner = self.persist_lock.lock().await;
        let mut state = self.state.lock().await;
        let mut desired = state.persisted.clone();
        desired.available_version = Some(update.version.clone());
        desired.available_body = Some(update.body.clone());
        desired.available_date = update.date.clone();
        ops.persist(&desired)?;
        state.persisted = desired;
        state.checked = Some(update);
        state.revision = state.revision.saturating_add(1);
        let snapshot = AppUpdateState::from_persisted(&state.persisted, state.revision);
        drop(state);
        drop(_persist_owner);
        ops.emit(&snapshot)?;
        Ok(snapshot)
    }

    async fn apply_none(&self, ops: &impl UpdateOps<A>) -> Result<AppUpdateState, String> {
        let _persist_owner = self.persist_lock.lock().await;
        let mut state = self.state.lock().await;
        let mut desired = state.persisted.clone();
        desired.available_version = None;
        desired.available_body = None;
        desired.available_date = None;
        ops.persist(&desired)?;
        state.persisted = desired;
        state.checked = None;
        state.revision = state.revision.saturating_add(1);
        let snapshot = AppUpdateState::none("已是最新版", state.revision);
        drop(state);
        drop(_persist_owner);
        ops.emit(&snapshot)?;
        Ok(snapshot)
    }

    async fn finish(
        &self,
        generation: u64,
        result: Result<AppUpdateState, String>,
    ) -> Result<AppUpdateState, String> {
        let mut state = self.state.lock().await;
        let slot = if state.in_flight.as_ref().map(|value| value.0) == Some(generation) {
            let slot = state.in_flight.as_ref().unwrap().1.clone();
            state.in_flight = None;
            Some(slot)
        } else {
            None
        };
        drop(state);
        if let Some(slot) = slot {
            *slot.result.lock().await = Some(result.clone());
            slot.ready.notify_waiters();
        }
        result
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

async fn wait_for_slot(slot: Arc<CompletionSlot>) -> Result<AppUpdateState, String> {
    loop {
        let mut notified = Box::pin(slot.ready.notified());
        notified.as_mut().enable();
        if let Some(result) = slot.result.lock().await.clone() {
            return result;
        }
        notified.await;
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
                    let mut state = self
                        .core
                        .state
                        .try_lock()
                        .expect("update state is unowned during setup");
                    state.shown_notification_version = persisted.last_notified_version.clone();
                    state.persisted = persisted;
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
            persist_lock: self.core.persist_lock.clone(),
            initialized: self.core.initialized.clone(),
            started: self.core.started.clone(),
        };
        tauri::async_runtime::spawn(async move {
            core.reconcile_presentation(&ops, now_ms(), false).await;
            loop {
                let _ = core.check(&ops, false, now_ms()).await;
                core.reconcile_presentation(&ops, now_ms(), false).await;
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
    let ops = TauriUpdateOps { app };
    let result = registry.core.check(&ops, true, now_ms()).await;
    registry
        .core
        .reconcile_presentation(&ops, now_ms(), true)
        .await;
    result
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
        mpsc, Mutex as StdMutex,
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
        fail_dedupe_persist: AtomicBool,
        fail_emit: AtomicBool,
        fail_tray_once: AtomicBool,
        tray_returns_false: AtomicBool,
        fail_install: AtomicBool,
        fail_notify: AtomicBool,
        notify_started: StdMutex<Option<mpsc::Sender<()>>>,
        notify_release: StdMutex<Option<mpsc::Receiver<()>>>,
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
            if self.fail_persist.load(Ordering::SeqCst)
                || (self.fail_dedupe_persist.load(Ordering::SeqCst)
                    && state.last_notified_version.is_some())
            {
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
            if let Some(started) = self.notify_started.lock().unwrap().as_ref() {
                started.send(()).unwrap();
            }
            if let Some(release) = self.notify_release.lock().unwrap().as_ref() {
                release.recv().unwrap();
            }
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
            } else if self.tray_returns_false.load(Ordering::SeqCst) {
                Ok(false)
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
                fail_dedupe_persist: AtomicBool::new(false),
                fail_emit: AtomicBool::new(false),
                fail_tray_once: AtomicBool::new(false),
                tray_returns_false: AtomicBool::new(false),
                fail_install: AtomicBool::new(false),
                fail_notify: AtomicBool::new(false),
                notify_started: StdMutex::new(None),
                notify_release: StdMutex::new(None),
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
                assert!(core.state.lock().await.in_flight.is_none(), "{failure}");
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
            core.reconcile_presentation(&ops, 1, false).await;
            core.reconcile_presentation(&ops, PRESENTATION_BACKOFF_MS + 1, false)
                .await;
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
            core.reconcile_presentation(&ops, 1, false).await;
            let state = core.state.lock().await;
            assert_eq!(ops.notifications.load(Ordering::SeqCst), 1);
            assert_eq!(ops.tray_attempts.load(Ordering::SeqCst), 1);
            assert_eq!(state.persisted.last_notified_version, None);
            assert_eq!(state.presented_version.as_deref(), Some("0.8.0"));
        });
    }

    #[test]
    fn concurrent_reconcile_threads_claim_notification_once() {
        let core = Arc::new(RegistryCore::<String>::default());
        let ops = Arc::new(MockOps::default());
        *ops.loaded.lock().unwrap() = Ok(Some(PersistedUpdateState {
            available_version: Some("0.8.0".into()),
            ..Default::default()
        }));
        runtime().block_on(core.initialize(ops.as_ref()));
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        *ops.notify_started.lock().unwrap() = Some(started_tx);
        *ops.notify_release.lock().unwrap() = Some(release_rx);

        let first = std::thread::spawn({
            let core = core.clone();
            let ops = ops.clone();
            move || runtime().block_on(core.reconcile_presentation(ops.as_ref(), 1, false))
        });
        started_rx.recv().unwrap();
        let second = std::thread::spawn({
            let core = core.clone();
            let ops = ops.clone();
            move || runtime().block_on(core.reconcile_presentation(ops.as_ref(), 1, false))
        });
        second.join().unwrap();
        assert_eq!(ops.notifications.load(Ordering::SeqCst), 1);
        release_tx.send(()).unwrap();
        first.join().unwrap();
        assert_eq!(ops.notifications.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn notification_success_with_dedupe_persist_failure_never_shows_twice() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::default();
            *ops.loaded.lock().unwrap() = Ok(Some(PersistedUpdateState {
                available_version: Some("0.8.0".into()),
                ..Default::default()
            }));
            ops.fail_dedupe_persist.store(true, Ordering::SeqCst);
            core.initialize(&ops).await;
            core.reconcile_presentation(&ops, 1, false).await;
            core.reconcile_presentation(&ops, 2, false).await;
            core.reconcile_presentation(&ops, PRESENTATION_BACKOFF_MS + 2, false)
                .await;
            let state = core.state.lock().await;
            assert_eq!(ops.notifications.load(Ordering::SeqCst), 1);
            assert_eq!(state.shown_notification_version.as_deref(), Some("0.8.0"));
            assert_eq!(state.persisted.last_notified_version, None);
            assert_eq!(state.dedupe_persist_retry.as_ref().unwrap().failures, 2);
        });
    }

    #[test]
    fn notification_and_tray_failures_have_bounded_backoff() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::default();
            *ops.loaded.lock().unwrap() = Ok(Some(PersistedUpdateState {
                available_version: Some("0.8.0".into()),
                ..Default::default()
            }));
            ops.fail_notify.store(true, Ordering::SeqCst);
            ops.tray_returns_false.store(true, Ordering::SeqCst);
            core.initialize(&ops).await;
            for now in [0, 60_000, 300_000, 900_000, 2_100_000, 99_000_000] {
                core.reconcile_presentation(&ops, now, false).await;
            }
            assert_eq!(ops.notifications.load(Ordering::SeqCst), 3);
            assert_eq!(ops.tray_attempts.load(Ordering::SeqCst), 3);

            core.reconcile_presentation(&ops, 99_000_001, true).await;
            assert_eq!(ops.notifications.load(Ordering::SeqCst), 4);
            assert_eq!(ops.tray_attempts.load(Ordering::SeqCst), 4);
        });
    }

    #[test]
    fn startup_restore_and_concurrent_same_version_check_do_not_notify_twice() {
        let core = Arc::new(RegistryCore::<String>::default());
        let ops = Arc::new(MockOps::available("0.8.0"));
        *ops.loaded.lock().unwrap() = Ok(Some(PersistedUpdateState {
            available_version: Some("0.8.0".into()),
            ..Default::default()
        }));
        runtime().block_on(core.initialize(ops.as_ref()));
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        *ops.notify_started.lock().unwrap() = Some(started_tx);
        *ops.notify_release.lock().unwrap() = Some(release_rx);
        let startup = std::thread::spawn({
            let core = core.clone();
            let ops = ops.clone();
            move || runtime().block_on(core.reconcile_presentation(ops.as_ref(), 1, false))
        });
        started_rx.recv().unwrap();
        runtime().block_on(async {
            core.check(ops.as_ref(), true, 2).await.unwrap();
            core.reconcile_presentation(ops.as_ref(), 2, false).await;
        });
        release_tx.send(()).unwrap();
        startup.join().unwrap();
        runtime().block_on(core.reconcile_presentation(ops.as_ref(), 3, false));
        assert_eq!(ops.notifications.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn failed_available_or_none_persistence_leaves_authoritative_memory_unchanged() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::available("0.8.0");
            core.check(&ops, true, 1).await.unwrap();
            let before = core.state.lock().await.persisted.clone();
            ops.fail_persist.store(true, Ordering::SeqCst);
            assert!(core.apply_none(&ops).await.is_err());
            assert_eq!(core.state.lock().await.persisted, before);
        });
    }

    #[test]
    fn completed_generations_are_not_retained() {
        runtime().block_on(async {
            let core = RegistryCore::<String>::default();
            let ops = MockOps::available("0.8.0");
            for generation in 1..=128 {
                core.check(&ops, true, generation).await.unwrap();
            }
            let state = core.state.lock().await;
            assert!(state.in_flight.is_none());
            assert_eq!(state.next_generation, 128);
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
            core.reconcile_presentation(&ops, 1, true).await;
            *ops.check_result.lock().unwrap() = Err("offline".into());
            let snapshot = core.check(&ops, true, 2).await.unwrap();
            assert_eq!(snapshot.version.as_deref(), Some("0.8.0"));
            *ops.check_result.lock().unwrap() = Ok(None);
            core.check(&ops, true, 3).await.unwrap();
            core.reconcile_presentation(&ops, 3, true).await;
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
