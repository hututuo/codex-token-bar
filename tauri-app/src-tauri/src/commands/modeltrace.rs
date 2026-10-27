use super::{run_blocking_command, window_auth::require_window_label};
use crate::commands::dashboard::{
    capture_codex_home_source, validate_captured_codex_home_source, CapturedCodexHomeSource,
    CodexHomeSourceToken,
};
use crate::core::{
    app_paths,
    modeltrace::{self, probe::ProbeSession, scoring, store, AutoSettings, Run},
    quota,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{Emitter, State};

#[derive(Clone, Default)]
pub struct ModelTraceRegistry {
    busy: Arc<AtomicBool>,
    settings_gate: Arc<Mutex<()>>,
    open_requested: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
    active: Arc<Mutex<Option<(String, Run)>>>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    scope_key: String,
    models: Vec<String>,
    runs: Vec<Run>,
    busy: bool,
    settings: AutoSettings,
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn path() -> Result<PathBuf, String> {
    app_paths::modeltrace_database_path().ok_or("无法定位检测记录目录".into())
}
fn scope(source: &CapturedCodexHomeSource) -> Result<String, String> {
    let account = quota::accounts::current_credential(&source.codex_home)?.id();
    Ok(format!(
        "{:x}",
        Sha256::digest(format!(
            "modeltrace-v1\0{}\0{}\0{account}",
            source.source_token.canonical_home_key, source.source_token.physical_home_key
        ))
    ))
}
fn storage_identity(source: &CapturedCodexHomeSource) -> Result<String, String> {
    crate::core::business_store_route::source_identity("modeltrace", &source.codex_home)
}
fn validate(source: &CapturedCodexHomeSource, expected: &str) -> Result<(), String> {
    validate_captured_codex_home_source(source)?;
    if scope(source)? != expected {
        return Err("账号或数据源已改变，检测已停止".into());
    }
    Ok(())
}
impl ModelTraceRegistry {
    fn start_run(
        &self,
        app: tauri::AppHandle,
        model: String,
        source_token: Option<CodexHomeSourceToken>,
    ) -> Result<Run, String> {
        if self
            .busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Err("已有检测正在执行".into());
        }
        let prepared = (|| -> Result<_, String> {
            let source = capture_codex_home_source(source_token.as_ref())?;
            let scope_key = scope(&source)?;
            let storage_identity = storage_identity(&source)?;
            let run = Run {
                id: uuid::Uuid::new_v4().to_string(),
                model,
                effort: modeltrace::EFFORT.into(),
                started_at: now(),
                completed_at: None,
                status: "running".into(),
                attempts: 0,
                valid_samples: 0,
                message: None,
                attribution: None,
                samples: vec![],
            };
            self.cancel.store(false, Ordering::SeqCst);
            self.publish(&app, &storage_identity, &scope_key, &run)?;
            Ok((source, storage_identity, scope_key, run))
        })();
        match prepared {
            Ok((source, storage_identity, key, run)) => {
                let worker = self.clone();
                let result = run.clone();
                tauri::async_runtime::spawn_blocking(move || worker.execute(app, source, storage_identity, key, run));
                Ok(result)
            }
            Err(e) => {
                self.busy.store(false, Ordering::SeqCst);
                Err(e)
            }
        }
    }
    pub fn initialize(&self, app: tauri::AppHandle) {
        let registry = self.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                let worker = registry.clone();
                let app = app.clone();
                let _ = tauri::async_runtime::spawn_blocking(move || worker.auto_tick(app)).await;
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        });
    }
    fn auto_tick(&self, app: tauri::AppHandle) -> Result<(), String> {
        if self.busy.load(Ordering::SeqCst) {
            return Ok(());
        }
        let _gate = self.settings_gate.lock().map_err(|_| "检测设置锁不可用")?;
        let file = path()?;
        let source = capture_codex_home_source(None)?;
        let storage_identity = storage_identity(&source)?;
        let mut settings = store::auto_settings(&file, &storage_identity)?;
        if !settings.enabled || !(1..=168).contains(&settings.interval_hours) {
            return Ok(());
        }
        let key = scope(&source)?;
        if settings.scope_key.as_deref() != Some(&key) || settings.next_run_at.is_none() {
            settings.scope_key = Some(key);
            settings.next_run_at = Some(now() + i64::from(settings.interval_hours) * 3600);
            return store::save_auto_settings(&file, &storage_identity, &settings);
        }
        if settings.next_run_at.is_some_and(|due| due <= now()) {
            settings.next_run_at = Some(now() + i64::from(settings.interval_hours) * 3600);
            store::save_auto_settings(&file, &storage_identity, &settings)?;
            self.start_run(
                app,
                modeltrace::DEFAULT_MODEL.into(),
                Some(source.source_token),
            )?;
        }
        Ok(())
    }
    fn publish(&self, app: &tauri::AppHandle, storage_identity: &str, scope: &str, run: &Run) -> Result<(), String> {
        store::save(&path()?, storage_identity, scope, run)?;
        *self.active.lock().map_err(|_| "检测状态锁不可用")? = Some((scope.into(), run.clone()));
        let _ = app.emit("modeltrace-updated", scope);
        Ok(())
    }
    fn execute(
        &self,
        app: tauri::AppHandle,
        source: CapturedCodexHomeSource,
        storage_identity: String,
        scope_key: String,
        mut run: Run,
    ) {
        // A separate watcher cancels even while generation is waiting for events.
        let finished = Arc::new(AtomicBool::new(false));
        let watch_done = finished.clone();
        let cancel = self.cancel.clone();
        let watch_source = source.clone();
        let watch_scope = scope_key.clone();
        let watcher = std::thread::spawn(move || {
            while !watch_done.load(Ordering::SeqCst) {
                if validate(&watch_source, &watch_scope).is_err() {
                    cancel.store(true, Ordering::SeqCst);
                    break;
                }
                std::thread::sleep(Duration::from_millis(1000));
            }
        });
        let result = (|| -> Result<(), String> {
            validate(&source, &scope_key)?;
            let storage_identity = storage_identity.as_str();
            let work = path()?.parent().ok_or("无法定位检测目录")?.join("work");
            std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
            let mut session = ProbeSession::connect(&source.codex_home, &self.cancel)?;
            let request_model = run.model.clone();
            let samples =
                session.sample_three(&work, &request_model, &self.cancel, |attempt, sample| {
                    validate(&source, &scope_key)?;
                    run.attempts = run.attempts.max(attempt);
                    if let Some(sample) = sample {
                        run.samples.push(sample);
                        run.valid_samples = run.samples.len();
                    }
                    self.publish(&app, storage_identity, &scope_key, &run)
                })?;
            if self.cancel.load(Ordering::SeqCst) {
                return Err("检测已取消".into());
            }
            run.samples = samples;
            let numbers = run
                .samples
                .iter()
                .map(|s| s.numbers.clone())
                .collect::<Vec<_>>();
            let attribution = scoring::analyze(&numbers)?;
            run.message = Some(modeltrace::result_message(&run.model, &attribution));
            run.attribution = Some(attribution);
            Ok(())
        })();
        finished.store(true, Ordering::SeqCst);
        let _ = watcher.join();
        run.completed_at = Some(now());
        match result {
            Ok(()) => run.status = "completed".into(),
            Err(e) => {
                run.status = if self.cancel.load(Ordering::SeqCst) {
                    "cancelled"
                } else {
                    "failed"
                }
                .into();
                run.message = Some(e);
            }
        }
        if let Err(e) = self.publish(&app, &storage_identity, &scope_key, &run) {
            run.message = Some(format!("检测记录保存失败：{e}"));
            if let Ok(mut active) = self.active.lock() {
                *active = Some((scope_key.clone(), run));
            }
        }
        if let Ok(_gate) = self.settings_gate.lock() {
            if let Ok(file) = path() {
                if let Ok(mut settings) = store::auto_settings(&file, &storage_identity) {
                    if settings.enabled && settings.scope_key.as_deref() == Some(&scope_key) {
                        settings.next_run_at =
                            Some(now() + i64::from(settings.interval_hours) * 3600);
                        let _ = store::save_auto_settings(&file, &storage_identity, &settings);
                    }
                }
            }
        }
        self.busy.store(false, Ordering::SeqCst);
        let _ = app.emit("modeltrace-updated", ());
    }
}

#[tauri::command]
pub async fn read_modeltrace_snapshot(
    window: tauri::WebviewWindow,
    state: State<'_, ModelTraceRegistry>,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<Snapshot, String> {
    require_window_label(&window, "read_modeltrace_snapshot")?;
    let registry = state.inner().clone();
    run_blocking_command(move || {
        let source = capture_codex_home_source(source_token.as_ref())?;
        let scope_key = scope(&source)?;
        let storage_identity = storage_identity(&source)?;
        let active = registry
            .active
            .lock()
            .map_err(|_| "检测状态锁不可用")?
            .clone();
        let is_busy = registry.busy.load(Ordering::SeqCst);
        let mut runs = store::history(&path()?, &storage_identity, &scope_key)?;
        for run in &mut runs {
            let owned = active
                .as_ref()
                .is_some_and(|(key, value)| key == &scope_key && value.id == run.id)
                && is_busy;
            if run.status == "running" && !owned {
                run.status = "interrupted".into();
                run.completed_at = Some(now());
                run.message = Some("上次检测已中断，未自动重试".into());
                store::save(&path()?, &storage_identity, &scope_key, run)?;
            }
        }
        if let Some((key, value)) = active {
            if key == scope_key {
                if let Some(index) = runs.iter().position(|r| r.id == value.id) {
                    runs[index] = value;
                } else {
                    runs.insert(0, value);
                }
            }
        }
        validate(&source, &scope_key)?;
        Ok(Snapshot {
            scope_key,
            models: modeltrace::request_models(),
            runs,
            busy: is_busy,
            settings: store::auto_settings(&path()?, &storage_identity)?,
        })
    })
    .await
}

#[tauri::command]
pub async fn start_modeltrace(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    state: State<'_, ModelTraceRegistry>,
    model: String,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<Run, String> {
    require_window_label(&window, "start_modeltrace")?;
    if !modeltrace::request_models().contains(&model) {
        return Err("不支持的检测模型".into());
    }
    let registry = state.inner().clone();
    run_blocking_command(move || registry.start_run(app, model, source_token)).await
}

#[tauri::command]
pub fn cancel_modeltrace(
    window: tauri::WebviewWindow,
    state: State<'_, ModelTraceRegistry>,
) -> Result<(), String> {
    require_window_label(&window, "cancel_modeltrace")?;
    state.cancel.store(true, Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
pub async fn save_modeltrace_auto_settings(
    window: tauri::WebviewWindow,
    state: State<'_, ModelTraceRegistry>,
    enabled: bool,
    interval_hours: u16,
    source_token: Option<CodexHomeSourceToken>,
) -> Result<AutoSettings, String> {
    require_window_label(&window, "save_modeltrace_auto_settings")?;
    if !(1..=168).contains(&interval_hours) {
        return Err("检测间隔应为 1 至 168 小时".into());
    }
    let registry = state.inner().clone();
    run_blocking_command(move || {
        let _gate = registry
            .settings_gate
            .lock()
            .map_err(|_| "检测设置锁不可用")?;
        let source = capture_codex_home_source(source_token.as_ref())?;
        let key = scope(&source)?;
        let storage_identity = storage_identity(&source)?;
        let settings = AutoSettings {
            enabled,
            interval_hours,
            next_run_at: enabled.then(|| now() + i64::from(interval_hours) * 3600),
            scope_key: Some(key),
        };
        store::save_auto_settings(&path()?, &storage_identity, &settings)?;
        Ok(settings)
    })
    .await
}

#[tauri::command]
pub async fn open_modeltrace(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    state: State<'_, ModelTraceRegistry>,
) -> Result<(), String> {
    require_window_label(&window, "open_modeltrace")?;
    state.open_requested.store(true, Ordering::SeqCst);
    if let Err(e) = crate::platform::show_dashboard_window_from_command(&app).await {
        state.open_requested.store(false, Ordering::SeqCst);
        return Err(e);
    }
    let _ = app.emit("modeltrace-open", ());
    Ok(())
}
#[tauri::command]
pub fn take_modeltrace_open_request(
    window: tauri::WebviewWindow,
    state: State<'_, ModelTraceRegistry>,
) -> Result<bool, String> {
    require_window_label(&window, "take_modeltrace_open_request")?;
    Ok(state.open_requested.swap(false, Ordering::SeqCst))
}
