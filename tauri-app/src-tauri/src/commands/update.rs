use crate::{core::atomic_file, platform};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc, time::{Duration, SystemTime, UNIX_EPOCH}};
use tauri::{Emitter, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};
use tokio::sync::{Mutex, Notify};

const UPDATE_STATE_EVENT: &str = "app-update-state-changed";
const INSTALL_PROGRESS_EVENT: &str = "app-update-install-progress";
const WAKE_INTERVAL: Duration = Duration::from_secs(60);
const CHECK_INTERVAL_MS: i64 = 4 * 60 * 60 * 1_000;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
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
}

impl AppUpdateState {
    fn from_persisted(state: &PersistedUpdateState) -> Self {
        match &state.available_version {
            Some(version) => Self {
                status: "available".into(),
                message: format!("发现新版本 {version}"),
                version: Some(version.clone()),
                body: state.available_body.clone(),
                date: state.available_date.clone(),
            },
            None => Self::idle(""),
        }
    }

    fn idle(message: impl Into<String>) -> Self {
        Self { status: "idle".into(), message: message.into(), version: None, body: None, date: None }
    }

}

#[derive(Default)]
struct RuntimeState {
    persisted: PersistedUpdateState,
    in_flight: bool,
    last_result: Option<Result<AppUpdateState, String>>,
    checked_update: Option<Update>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CheckDecision { Join, Skip, Start }

fn decide_check(state: &mut RuntimeState, manual: bool, now: i64) -> CheckDecision {
    if state.in_flight { return CheckDecision::Join; }
    if !manual && !automatic_due(state.persisted.last_attempt_at, now) { return CheckDecision::Skip; }
    state.persisted.last_attempt_at = Some(now);
    CheckDecision::Start
}

#[derive(Default)]
pub struct UpdateMonitorRegistry {
    state: Arc<Mutex<RuntimeState>>,
    changed: Arc<Notify>,
}

impl UpdateMonitorRegistry {
    pub fn initialize(&self, app: &tauri::AppHandle) -> Result<(), String> {
        let path = state_path(app)?;
        let persisted = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| format!("更新状态损坏: {error}"))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => PersistedUpdateState::default(),
            Err(error) => return Err(format!("读取更新状态失败: {error}")),
        };
        self.state.blocking_lock().persisted = persisted;
        Ok(())
    }

    pub fn start(&self, app: tauri::AppHandle) {
        let state = self.state.clone();
        let changed = self.changed.clone();
        tauri::async_runtime::spawn(async move {
            let registry = UpdateMonitorRegistry { state, changed };
            loop {
                let _ = registry.check(&app, false).await;
                tokio::time::sleep(WAKE_INTERVAL).await;
            }
        });
    }

    async fn check(&self, app: &tauri::AppHandle, manual: bool) -> Result<AppUpdateState, String> {
        loop {
            let mut state = self.state.lock().await;
            let now = now_ms();
            match decide_check(&mut state, manual, now) {
                CheckDecision::Join => {
                    let notified = self.changed.notified();
                    drop(state);
                    notified.await;
                    let state = self.state.lock().await;
                    return state.last_result.clone().unwrap_or_else(|| Ok(AppUpdateState::from_persisted(&state.persisted)));
                }
                CheckDecision::Skip => return Ok(AppUpdateState::from_persisted(&state.persisted)),
                CheckDecision::Start => {}
            }
            persist(app, &state.persisted)?;
            state.in_flight = true;
            drop(state);
            break;
        }

        let checked = match app.updater() {
            Ok(updater) => updater.check().await,
            Err(error) => Err(error),
        };
        let result = match checked {
            Ok(Some(update)) => {
                let mut state = self.state.lock().await;
                state.persisted.available_version = Some(update.version.clone());
                state.persisted.available_body = Some(update.body.clone().unwrap_or_default());
                state.persisted.available_date = update.date.map(|date| date.to_string());
                state.checked_update = Some(update);
                match persist(app, &state.persisted) {
                    Err(error) => Err(error),
                    Ok(()) => {
                        let snapshot = AppUpdateState::from_persisted(&state.persisted);
                        // No notification plugin/click API is available in this app version.
                        // The native tray is the visible fallback; its open action already
                        // routes through platform::show_dashboard_window.
                        let should_notify = notification_due(&state.persisted);
                        if should_notify && platform::set_update_available_tray_fallback(app, snapshot.version.as_deref().unwrap_or_default()).unwrap_or(false) {
                            state.persisted.last_notified_version = snapshot.version.clone();
                            if let Err(error) = persist(app, &state.persisted) {
                                drop(state);
                                return finish_check(&self.state, &self.changed, Err(error)).await;
                            }
                        }
                        Ok(snapshot)
                    }
                }
            }
            Ok(None) => {
                let mut state = self.state.lock().await;
                state.persisted.available_version = None;
                state.persisted.available_body = None;
                state.persisted.available_date = None;
                state.checked_update = None;
                persist(app, &state.persisted).map(|_| AppUpdateState::idle("已是最新版"))
            }
            Err(error) => Err(format!("检查更新失败: {error}")),
        };

        finish_check(&self.state, &self.changed, result.clone()).await?;
        if let Ok(snapshot) = &result {
            let _ = app.emit(UPDATE_STATE_EVENT, snapshot);
        }
        result
    }
}

async fn finish_check(
    state: &Arc<Mutex<RuntimeState>>,
    changed: &Arc<Notify>,
    result: Result<AppUpdateState, String>,
) -> Result<AppUpdateState, String> {
    let mut locked = state.lock().await;
    locked.in_flight = false;
    locked.last_result = Some(result.clone());
    drop(locked);
    changed.notify_waiters();
    result
}

fn automatic_due(last_attempt_at: Option<i64>, now: i64) -> bool {
    last_attempt_at.map(|attempt| attempt > now || now - attempt >= CHECK_INTERVAL_MS).unwrap_or(true)
}

fn notification_due(state: &PersistedUpdateState) -> bool {
    state.available_version.is_some() && state.last_notified_version.as_ref() != state.available_version.as_ref()
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis().min(i64::MAX as u128) as i64
}

fn state_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    app.path().app_data_dir().map(|path| path.join("update-monitor-state.json")).map_err(|error| error.to_string())
}

fn persist(app: &tauri::AppHandle, state: &PersistedUpdateState) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(state).map_err(|error| error.to_string())?;
    atomic_file::write_atomically(&state_path(app)?, &bytes).map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn read_app_update_state(registry: tauri::State<'_, UpdateMonitorRegistry>) -> Result<AppUpdateState, String> {
    let state = registry.state.lock().await;
    Ok(AppUpdateState::from_persisted(&state.persisted))
}

#[tauri::command]
pub async fn check_app_update(app: tauri::AppHandle, registry: tauri::State<'_, UpdateMonitorRegistry>) -> Result<AppUpdateState, String> {
    registry.check(&app, true).await
}

#[tauri::command]
pub async fn install_app_update(app: tauri::AppHandle, registry: tauri::State<'_, UpdateMonitorRegistry>, version: String) -> Result<(), String> {
    let checked = registry.check(&app, true).await?;
    if checked.status != "available" || checked.version.as_deref() != Some(version.as_str()) {
        return Err("可安装版本已变化，请重新确认".into());
    }
    let update = registry.state.lock().await.checked_update.clone().ok_or_else(|| "更新对象不可用，请重新检查".to_string())?;
    let progress_app = app.clone();
    update.download_and_install(
        move |chunk, total| { let _ = progress_app.emit(INSTALL_PROGRESS_EVENT, serde_json::json!({"chunkLength": chunk, "contentLength": total})); },
        { let app = app.clone(); move || { let _ = app.emit(INSTALL_PROGRESS_EVENT, serde_json::json!({"finished": true})); } },
    ).await.map_err(|error| error.to_string())?;
    app.restart();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restart_cadence_uses_persisted_attempt_and_bounds_failures() {
        assert!(!automatic_due(Some(1_000), 1_000 + CHECK_INTERVAL_MS - 1));
        assert!(automatic_due(Some(1_000), 1_000 + CHECK_INTERVAL_MS));
        assert!(automatic_due(Some(2_000), 1_000));
    }

    #[test]
    fn auto_and_manual_share_one_in_flight_domain_and_attempt_precedes_network() {
        let mut state = RuntimeState::default();
        assert_eq!(decide_check(&mut state, false, 42), CheckDecision::Start);
        assert_eq!(state.persisted.last_attempt_at, Some(42));
        state.in_flight = true;
        assert_eq!(decide_check(&mut state, true, 43), CheckDecision::Join);
        assert_eq!(decide_check(&mut state, false, 43), CheckDecision::Join);
    }

    #[test]
    fn cached_available_state_and_notification_dedupe_survive_restart() {
        let persisted = PersistedUpdateState { available_version: Some("0.8.0".into()), available_body: Some("notes".into()), last_notified_version: Some("0.8.0".into()), ..Default::default() };
        let state = AppUpdateState::from_persisted(&persisted);
        assert_eq!(state.status, "available");
        assert_eq!(state.version.as_deref(), Some("0.8.0"));
        assert_eq!(persisted.last_notified_version.as_ref(), persisted.available_version.as_ref());
        assert!(!notification_due(&persisted));
        let failed_fallback = PersistedUpdateState { last_notified_version: None, ..persisted };
        assert!(notification_due(&failed_fallback));
    }

    #[test]
    fn automatic_path_contains_no_install_operation() {
        let source = include_str!("update.rs");
        let automatic = source.split("async fn check").nth(1).unwrap().split("pub async fn install_app_update").next().unwrap();
        assert!(!automatic.contains("download_and_install"));
    }
}
