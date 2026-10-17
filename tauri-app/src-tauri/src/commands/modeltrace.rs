use super::{
    dashboard::{
        capture_codex_home_source, validate_captured_codex_home_source, CapturedCodexHomeSource,
    },
    run_blocking_command,
    window_auth::require_window_label,
};
use crate::core::{
    atomic_file,
    modeltrace::{
        self, probe, scoring,
        store::{self, StoredPlan},
        History, Plan, Run, Snapshot,
    },
    quota,
};
use sha2::{Digest, Sha256};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::Emitter;

#[derive(Clone, Default)]
pub(crate) struct ModelTraceRegistry {
    transition: Arc<Mutex<()>>,
    active: Arc<Mutex<Option<StoredPlan>>>,
    busy: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn identity(captured: &CapturedCodexHomeSource) -> Result<(String, String), String> {
    let account = quota::accounts::current_credential(&captured.codex_home)?.id();
    let scope = format!(
        "{:x}",
        Sha256::digest(format!(
            "modeltrace-v1\0{}\0{}\0{account}",
            captured.source_token.canonical_home_key, captured.source_token.physical_home_key
        ))
    );
    Ok((scope, account))
}
fn check_source(stored: &StoredPlan) -> Result<CapturedCodexHomeSource, String> {
    let source = capture_codex_home_source(Some(&stored.source_token))?;
    validate_captured_codex_home_source(&source)?;
    let (_, account) = identity(&source)?;
    if account != stored.account_key {
        return Err("账号已改变，检测计划已停止，请重新开始".into());
    }
    Ok(source)
}

impl ModelTraceRegistry {
    fn publish(&self, app: &tauri::AppHandle, stored: &StoredPlan) {
        if let Ok(mut state) = self.active.lock() {
            let mut next = stored.clone();
            if next.plan.active() && self.cancel.load(Ordering::SeqCst) {
                next.plan.status = "cancelling".into();
            }
            *state = Some(next);
        }
        let _ = app.emit("modeltrace-updated", &stored.scope_key);
    }
    pub fn initialize(&self, app: tauri::AppHandle) {
        let registry = self.clone();
        tauri::async_runtime::spawn_blocking(move || {
            // Startup failure never starts inference or blocks the main window.
            let _ = registry.restore(app);
        });
    }
    fn restore(&self, app: tauri::AppHandle) -> Result<(), String> {
        let _transition = self.transition.lock().map_err(|_| "检测状态锁不可用")?;
        if self
            .busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(());
        }
        let prepared = (|| {
            let source = capture_codex_home_source(None)?;
            self.restore_source(source)
        })();
        match prepared {
            Ok(Some(stored)) => {
                self.publish(&app, &stored);
                let registry = self.clone();
                tauri::async_runtime::spawn_blocking(move || registry.worker(app, stored));
                Ok(())
            }
            Ok(None) => {
                self.busy.store(false, Ordering::SeqCst);
                Ok(())
            }
            Err(e) => {
                self.busy.store(false, Ordering::SeqCst);
                Err(e)
            }
        }
    }
    fn restore_source(
        &self,
        source: CapturedCodexHomeSource,
    ) -> Result<Option<StoredPlan>, String> {
        let (scope, account) = identity(&source)?;
        let Some(mut stored) = store::last_plan(&scope)? else {
            return Ok(None);
        };
        if !stored.plan.active() {
            return Ok(None);
        }
        if stored.account_key != account || stored.home != source.codex_home {
            return Err("检测计划的数据来源已改变".into());
        }
        stored.source_token = source.source_token;
        self.restore_saved_plan(stored)
    }
    fn snapshot_plan(&self, scope: &str) -> Result<Option<StoredPlan>, String> {
        let state = self.active.lock().map_err(|_| "检测状态锁不可用")?;
        if let Some(stored) = state.as_ref().filter(|p| p.scope_key == scope) {
            if !stored.plan.active() || self.busy.load(Ordering::SeqCst) {
                return Ok(Some(stored.clone()));
            }
        }
        let stored = store::last_plan(scope)?;
        if stored.as_ref().is_some_and(|p| p.plan.active()) {
            return Err("检测计划正在恢复，请稍后重试".into());
        }
        Ok(stored)
    }
    fn restore_saved_plan(&self, mut stored: StoredPlan) -> Result<Option<StoredPlan>, String> {
        if store::cancel_requested(&stored.plan.id)? || stored.plan.status == "cancelling" {
            let run = (stored.plan.status == "running"
                || (stored.plan.status == "cancelling" && stored.plan.next_run_at.is_none()))
            .then(|| {
                new_run(
                    &stored,
                    "cancelled",
                    Some("已恢复上次保存的停止请求".into()),
                )
            });
            stored.plan.status = "cancelled".into();
            stored.plan.next_run_at = None;
            if let Some(run) = run {
                stored.plan.completed_rounds += 1;
                store::finish_run(&stored, &run)?;
            } else {
                store::save_plan(&stored)?;
            }
            return Ok(None);
        }
        if stored.plan.status == "running" {
            let run = new_run(
                &stored,
                "interrupted",
                Some("应用在上一轮完成前退出，该轮未自动重试".into()),
            );
            stored.plan.completed_rounds += 1;
            advance(&mut stored.plan);
            stored.round_started_at = None;
            store::finish_run(&stored, &run)?;
        }
        // Register before the worker waits for its next scheduled round, so
        // snapshot reads and cancellation refer to the same restored plan.
        self.cancel.store(false, Ordering::SeqCst);
        *self.active.lock().map_err(|_| "检测状态锁不可用")? = Some(stored.clone());
        Ok(Some(stored))
    }
    fn cancel_plan(&self, plan_id: &str) -> Result<String, String> {
        let mut state = self.active.lock().map_err(|_| "检测状态锁不可用")?;
        let stored = state.as_mut().ok_or("没有正在执行的计划")?;
        if stored.plan.id != plan_id || !self.busy.load(Ordering::SeqCst) {
            return Err("计划已经改变，请刷新后重试".into());
        }
        if !stored.plan.active() {
            return Ok(stored.scope_key.clone());
        }
        store::request_cancel(&stored.plan.id)?;
        self.cancel.store(true, Ordering::SeqCst);
        stored.plan.status = "cancelling".into();
        Ok(stored.scope_key.clone())
    }
    fn start(&self, app: tauri::AppHandle, model: String, rounds: usize) -> Result<Plan, String> {
        modeltrace::validate_rounds(rounds)?;
        if !scoring::models().contains(&model) {
            return Err("模型不在当前 GPT 参考库中".into());
        }
        // An earlier startup may have had no credentials or a different Home.
        // Recover its persisted plan before accepting another one.
        self.restore(app.clone())?;
        let _transition = self.transition.lock().map_err(|_| "检测状态锁不可用")?;
        if self
            .busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Err("已有检测计划，请先停止或等待完成".into());
        }
        let prepared = (|| {
            let source = capture_codex_home_source(None)?;
            let (scope_key, account_key) = identity(&source)?;
            let plan = Plan {
                id: uuid::Uuid::new_v4().to_string(),
                model,
                started_at: now(),
                status: "waiting".into(),
                total_rounds: rounds,
                completed_rounds: 0,
                current_attempt: 0,
                valid_samples: 0,
                next_run_at: Some(now()),
                error: None,
            };
            let stored = StoredPlan {
                plan,
                round_started_at: None,
                scope_key,
                account_key,
                source_token: source.source_token,
                home: source.codex_home,
            };
            store::save_plan(&stored)?;
            Ok::<_, String>(stored)
        })();
        let stored = match prepared {
            Ok(s) => s,
            Err(e) => {
                self.busy.store(false, Ordering::SeqCst);
                return Err(e);
            }
        };
        self.cancel.store(false, Ordering::SeqCst);
        self.publish(&app, &stored);
        let plan = stored.plan.clone();
        let registry = self.clone();
        tauri::async_runtime::spawn_blocking(move || registry.worker(app, stored));
        Ok(plan)
    }
    fn worker(&self, app: tauri::AppHandle, mut stored: StoredPlan) {
        let result = self.run_plan(&app, &mut stored);
        if let Err(error) = result {
            stored.plan.status = if self.cancel.load(Ordering::SeqCst) {
                "cancelled"
            } else {
                "failed"
            }
            .into();
            stored.plan.error = Some(error);
            stored.plan.next_run_at = None;
            if let Err(error) = store::save_plan(&stored) {
                stored.plan.error = Some(format!("保存检测状态失败：{error}"));
            }
        }
        self.publish(&app, &stored);
        self.busy.store(false, Ordering::SeqCst);
    }
    fn run_plan(&self, app: &tauri::AppHandle, stored: &mut StoredPlan) -> Result<(), String> {
        let work = store::root()?.join("probe-workspace");
        std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
        let mut source_checked_at = std::time::Instant::now();
        while stored.plan.completed_rounds < stored.plan.total_rounds {
            if self.cancel.load(Ordering::SeqCst) {
                return Err("检测计划已取消".into());
            }
            if source_checked_at.elapsed() >= Duration::from_secs(5) {
                check_source(stored)?;
                source_checked_at = std::time::Instant::now();
            }
            match modeltrace::slot_action(
                stored.plan.started_at,
                stored.plan.completed_rounds,
                now(),
            ) {
                "wait" => {
                    std::thread::sleep(Duration::from_millis(250));
                    continue;
                }
                "missed" => {
                    let run = new_run(
                        stored,
                        "missed",
                        Some("超过计划时间 5 分钟，未补发检测".into()),
                    );
                    stored.plan.completed_rounds += 1;
                    advance(&mut stored.plan);
                    store::finish_run(stored, &run)?;
                    self.publish(app, stored);
                    continue;
                }
                _ => {}
            }
            check_source(stored)?;
            stored.plan.status = "running".into();
            stored.plan.next_run_at = None;
            stored.plan.current_attempt = 0;
            stored.plan.valid_samples = 0;
            stored.round_started_at = Some(now());
            store::save_plan(stored)?;
            self.publish(app, stored);
            let mut run = new_run(stored, "sampling_failed", None);
            let counts = challenge_counts();
            let mut samples = Vec::new();
            let mut errors = Vec::new();
            let mut source_error = None;
            for attempt in 1..=modeltrace::MAX_ATTEMPTS {
                if self.cancel.load(Ordering::SeqCst) {
                    break;
                }
                let source = match check_source(stored) {
                    Ok(s) => s,
                    Err(e) => {
                        source_error = Some(e);
                        break;
                    }
                };
                stored.plan.current_attempt = attempt;
                store::save_plan(stored)?;
                self.publish(app, stored);
                match probe::sample(
                    &source.codex_home,
                    &work,
                    &stored.plan.model,
                    counts[samples.len()],
                    &self.cancel,
                ) {
                    Ok(sample) => samples.push(sample),
                    Err(error) => errors.push(error),
                }
                checkpoint_samples(stored, &samples)?;
                self.publish(app, stored);
                if let Err(error) = check_source(stored) {
                    source_error = Some(error);
                    break;
                }
                if samples.len() == 3 {
                    break;
                }
            }
            run.attempts = stored.plan.current_attempt;
            run.valid_samples = samples.len();
            run.completed_at = now();
            if self.cancel.load(Ordering::SeqCst) {
                run.status = "cancelled".into();
            } else if let Some(error) = source_error.as_ref() {
                errors.push(error.clone());
            } else if samples.len() == 3 {
                let attribution = scoring::analyze(
                    &samples
                        .iter()
                        .map(|s: &probe::Sample| s.numbers.clone())
                        .collect::<Vec<_>>(),
                )?;
                run.status = modeltrace::judgement(&stored.plan.model, &attribution).into();
                run.attribution = Some(attribution);
            }
            if !errors.is_empty() {
                run.message = Some(errors.join("；"));
            }
            stored.plan.completed_rounds += 1;
            advance(&mut stored.plan);
            stored.round_started_at = None;
            if self.cancel.load(Ordering::SeqCst) {
                stored.plan.status = "cancelled".into();
                stored.plan.next_run_at = None;
            }
            if let Some(error) = source_error.as_ref() {
                stored.plan.status = "failed".into();
                stored.plan.next_run_at = None;
                stored.plan.error = Some(error.clone());
            }
            store::finish_run(stored, &run)?;
            self.publish(app, stored);
            if self.cancel.load(Ordering::SeqCst) || source_error.is_some() {
                return Ok(());
            }
        }
        Ok(())
    }
}

fn checkpoint_samples(stored: &mut StoredPlan, samples: &[probe::Sample]) -> Result<(), String> {
    let audit = store::root()?.join("samples");
    std::fs::create_dir_all(&audit).map_err(|e| e.to_string())?;
    let run_id = format!("{}-{}", stored.plan.id, stored.plan.completed_rounds + 1);
    atomic_file::write_atomically(
        &audit.join(format!("{run_id}.json")),
        &serde_json::to_vec(samples).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    stored.plan.valid_samples = samples.len();
    store::save_plan(stored)
}

fn advance(plan: &mut Plan) {
    plan.current_attempt = 0;
    plan.valid_samples = 0;
    if plan.completed_rounds >= plan.total_rounds {
        plan.status = "completed".into();
        plan.next_run_at = None;
    } else {
        plan.status = "waiting".into();
        plan.next_run_at =
            Some(plan.started_at + plan.completed_rounds as i64 * modeltrace::INTERVAL_SECONDS);
    }
}
fn new_run(stored: &StoredPlan, status: &str, message: Option<String>) -> Run {
    Run {
        id: format!("{}-{}", stored.plan.id, stored.plan.completed_rounds + 1),
        plan_id: stored.plan.id.clone(),
        model: stored.plan.model.clone(),
        started_at: stored.round_started_at.unwrap_or(
            stored.plan.started_at
                + stored.plan.completed_rounds as i64 * modeltrace::INTERVAL_SECONDS,
        ),
        completed_at: now(),
        status: status.into(),
        attempts: stored.plan.current_attempt,
        valid_samples: stored.plan.valid_samples,
        message,
        attribution: None,
    }
}
fn challenge_counts() -> [usize; 3] {
    let id = uuid::Uuid::new_v4();
    let a = id.as_bytes()[0] as usize % 41;
    let mut b = id.as_bytes()[1] as usize % 41;
    if b == a {
        b = (b + 1) % 41;
    }
    let mut c = id.as_bytes()[2] as usize % 41;
    while c == a || c == b {
        c = (c + 1) % 41;
    }
    [292 + a, 292 + b, 292 + c]
}

#[tauri::command]
pub async fn read_modeltrace_snapshot(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, ModelTraceRegistry>,
) -> Result<Snapshot, String> {
    require_window_label(&window, "read_modeltrace_snapshot")?;
    let registry = registry.inner().clone();
    run_blocking_command(move || {
        registry.restore(app)?;
        let source = capture_codex_home_source(None)?;
        let (scope_key, _) = identity(&source)?;
        let stored = registry.snapshot_plan(&scope_key)?;
        let latest = store::history(&scope_key, 0, i64::MAX, None, 1, 0)?
            .runs
            .into_iter()
            .next();
        Ok(Snapshot {
            models: scoring::models(),
            scope_key,
            plan: stored.map(|s| s.plan),
            latest,
            bank_version: scoring::UPSTREAM_COMMIT[..12].into(),
        })
    })
    .await
}
#[tauri::command]
pub async fn start_modeltrace_plan(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, ModelTraceRegistry>,
    model: String,
    rounds: Option<usize>,
) -> Result<Plan, String> {
    require_window_label(&window, "start_modeltrace_plan")?;
    let registry = registry.inner().clone();
    run_blocking_command(move || {
        registry.start(app, model, rounds.unwrap_or(modeltrace::DEFAULT_ROUNDS))
    })
    .await
}
#[tauri::command]
pub async fn cancel_modeltrace_plan(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, ModelTraceRegistry>,
    plan_id: String,
) -> Result<(), String> {
    require_window_label(&window, "cancel_modeltrace_plan")?;
    let registry = registry.inner().clone();
    run_blocking_command(move || {
        let scope_key = registry.cancel_plan(&plan_id)?;
        let _ = app.emit("modeltrace-updated", &scope_key);
        Ok(())
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::dashboard::CodexHomeSourceToken;
    use crate::core::app_paths::app_path_test_env_guard;

    fn saved_plan(status: &str) -> StoredPlan {
        StoredPlan {
            round_started_at: (status == "running").then_some(1005),
            plan: Plan {
                id: "restored-plan".into(),
                model: "gpt-5.6-sol".into(),
                started_at: 1000,
                status: status.into(),
                total_rounds: 3,
                completed_rounds: usize::from(status == "waiting"),
                current_attempt: if status == "running" { 2 } else { 0 },
                valid_samples: usize::from(status == "running"),
                next_run_at: Some(4600),
                error: None,
            },
            scope_key: "scope".into(),
            account_key: "account".into(),
            home: "home".into(),
            source_token: CodexHomeSourceToken {
                canonical_home_key: "home".into(),
                physical_home_key: "physical".into(),
                transition_generation: 0,
            },
        }
    }

    #[test]
    fn selected_rounds_survive_storage_and_finish_on_the_selected_round() {
        assert_eq!(modeltrace::DEFAULT_ROUNDS, 1);
        for rounds in 1..=5 {
            modeltrace::validate_rounds(rounds).unwrap();
            let mut stored = saved_plan("waiting");
            stored.plan.total_rounds = rounds;
            let encoded = serde_json::to_string(&stored).unwrap();
            let mut restored: StoredPlan = serde_json::from_str(&encoded).unwrap();
            assert_eq!(restored.plan.total_rounds, rounds);
            for completed in 0..=rounds {
                restored.plan.completed_rounds = completed;
                advance(&mut restored.plan);
                if completed == rounds {
                    assert_eq!(restored.plan.status, "completed");
                    assert_eq!(restored.plan.next_run_at, None);
                } else {
                    assert_eq!(restored.plan.status, "waiting");
                    assert_eq!(
                        restored.plan.next_run_at,
                        Some(1000 + completed as i64 * 3600)
                    );
                }
            }
        }
        for rounds in [0, 6, usize::MAX] {
            assert!(modeltrace::validate_rounds(rounds).is_err());
        }
        let mut legacy = serde_json::to_value(saved_plan("waiting")).unwrap();
        legacy["plan"]
            .as_object_mut()
            .unwrap()
            .remove("totalRounds");
        let restored: StoredPlan = serde_json::from_value(legacy).unwrap();
        assert_eq!(restored.plan.total_rounds, 3);
    }

    #[test]
    fn restored_waiting_and_interrupted_plans_can_be_stopped_before_next_round() {
        for status in ["waiting", "running"] {
            let root =
                std::env::temp_dir().join(format!("modeltrace-recovery-{}", uuid::Uuid::new_v4()));
            {
                let _env =
                    app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", root.clone())]);
                let stored = saved_plan(status);
                store::save_plan(&stored).unwrap();
                let registry = ModelTraceRegistry::default();
                registry.busy.store(true, Ordering::SeqCst);
                let restored = registry
                    .restore_saved_plan(store::last_plan("scope").unwrap().unwrap())
                    .unwrap()
                    .unwrap();
                assert_eq!(restored.plan.status, "waiting");
                assert_eq!(restored.plan.next_run_at, Some(4600));
                assert_eq!(
                    registry.active.lock().unwrap().as_ref().unwrap().plan.id,
                    stored.plan.id
                );
                assert!(registry.cancel_plan("obsolete-plan").is_err());
                assert!(!registry.cancel.load(Ordering::SeqCst));
                assert_eq!(registry.cancel_plan(&stored.plan.id).unwrap(), "scope");
                assert!(registry.cancel.load(Ordering::SeqCst));
                assert!(store::cancel_requested(&stored.plan.id).unwrap());
                let history = store::history("scope", 0, i64::MAX, None, 10, 0).unwrap();
                assert_eq!(history.runs.len(), usize::from(status == "running"));
                if status == "running" {
                    assert_eq!(history.runs[0].status, "interrupted");
                    assert_eq!(history.runs[0].attempts, 2);
                    assert_eq!(history.runs[0].valid_samples, 1);
                }
                // A second restart honors the saved stop request; it must not
                // schedule inference again or erase the interrupted round.
                let restarted = ModelTraceRegistry::default();
                assert!(restarted.restore_saved_plan(restored).unwrap().is_none());
                assert!(restarted.active.lock().unwrap().is_none());
                assert_eq!(
                    store::last_plan("scope").unwrap().unwrap().plan.status,
                    "cancelled"
                );
                assert_eq!(
                    store::history("scope", 0, i64::MAX, None, 10, 0)
                        .unwrap()
                        .runs
                        .len(),
                    usize::from(status == "running"),
                    "waiting cancellation must not add a future round"
                );
            }
            std::fs::remove_dir_all(&root).unwrap();
        }
    }

    #[test]
    fn existing_credentials_scope_accounts_and_recover_after_login_or_home_switch() {
        use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
        let root =
            std::env::temp_dir().join(format!("modeltrace-identity-{}", uuid::Uuid::new_v4()));
        {
            let _env =
                app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", root.clone())]);
            let home = root.join("home");
            std::fs::create_dir_all(&home).unwrap();
            let source = || CapturedCodexHomeSource {
                codex_home: home.clone(),
                source_path: home.clone(),
                source_token: saved_plan("waiting").source_token,
            };
            let login = |account: &str, signature: &str| {
                // No id_token: valid subscription credentials accepted by the original app.
                let claims = serde_json::json!({"sub":"same-user", "https://api.openai.com/auth": {
                    "chatgpt_account_id":account, "chatgpt_user_id":"same-user"
                }});
                let access = format!(
                    "e30.{}.{signature}",
                    URL_SAFE_NO_PAD.encode(claims.to_string())
                );
                std::fs::write(
                    home.join("auth.json"),
                    serde_json::json!({"tokens":{
                        "access_token":access, "account_id":account
                    }})
                    .to_string(),
                )
                .unwrap();
            };
            let registry = ModelTraceRegistry::default();
            assert!(registry.restore_source(source()).is_err());
            login("account-a", "first");
            let (scope_a, account_a) = identity(&source()).unwrap();
            assert_eq!(
                account_a,
                quota::accounts::current_credential(&home).unwrap().id()
            );
            login("account-a", "rotated");
            assert_eq!(identity(&source()).unwrap().0, scope_a);
            let mut stored = saved_plan("waiting");
            stored.scope_key = scope_a.clone();
            stored.account_key = account_a;
            stored.home = home.clone();
            store::save_plan(&stored).unwrap();
            assert!(registry.snapshot_plan(&scope_a).is_err());
            login("account-b", "other");
            assert_ne!(identity(&source()).unwrap().0, scope_a);
            assert!(registry.restore_source(source()).unwrap().is_none());
            login("account-a", "returned");
            assert_eq!(
                registry
                    .restore_source(source())
                    .unwrap()
                    .unwrap()
                    .plan
                    .next_run_at,
                Some(4600)
            );
            registry.busy.store(true, Ordering::SeqCst);
            assert_eq!(
                registry.snapshot_plan(&scope_a).unwrap().unwrap().plan.id,
                stored.plan.id
            );
            let mut other_home = source();
            other_home.source_token.physical_home_key = "different-home".into();
            assert_ne!(identity(&other_home).unwrap().0, scope_a);
            assert!(registry.restore_source(other_home).unwrap().is_none());
            assert!(registry.restore_source(source()).unwrap().is_some());
            // Another scope's live worker cannot make a persisted orphan look owned.
            let mut other = saved_plan("waiting");
            other.scope_key = "other-scope".into();
            *registry.active.lock().unwrap() = Some(other);
            assert!(registry.snapshot_plan(&scope_a).is_err());
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancel_after_terminal_publication_does_not_reopen_the_plan() {
        let registry = ModelTraceRegistry::default();
        for status in ["completed", "cancelled", "failed"] {
            let stored = saved_plan(status);
            *registry.active.lock().unwrap() = Some(stored.clone());
            // The worker published its final state but has not yet released busy.
            registry.busy.store(true, Ordering::SeqCst);
            assert_eq!(registry.cancel_plan(&stored.plan.id).unwrap(), "scope");
            registry.busy.store(false, Ordering::SeqCst);
            assert!(!registry.cancel.load(Ordering::SeqCst));
            assert_eq!(
                registry
                    .active
                    .lock()
                    .unwrap()
                    .as_ref()
                    .unwrap()
                    .plan
                    .status,
                status
            );
        }
    }

    #[test]
    fn crash_preserves_attempts_samples_and_actual_round_start() {
        let root =
            std::env::temp_dir().join(format!("modeltrace-progress-{}", uuid::Uuid::new_v4()));
        {
            let _env =
                app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", root.clone())]);
            let mut stored = saved_plan("running");
            let sample = probe::Sample {
                expected_count: 300,
                returned_count: 300,
                out_of_range_count: 0,
                numbers: vec![1; 300],
                usage: None,
            };
            for count in 1..=2 {
                stored.plan.current_attempt = count;
                store::save_plan(&stored).unwrap();
                checkpoint_samples(&mut stored, &vec![sample.clone(); count]).unwrap();
            }
            // Exit during attempt 3 after two valid replies, before the round finishes.
            stored.plan.current_attempt = 3;
            store::save_plan(&stored).unwrap();
            let registry = ModelTraceRegistry::default();
            registry
                .restore_saved_plan(store::last_plan("scope").unwrap().unwrap())
                .unwrap();
            let history = store::history("scope", 0, i64::MAX, None, 10, 0).unwrap();
            assert_eq!(history.runs.len(), 1);
            let run = &history.runs[0];
            assert_eq!(
                (run.attempts, run.valid_samples, run.started_at),
                (3, 2, 1005)
            );
            assert_eq!(run.status, "interrupted");
            let samples: Vec<probe::Sample> = serde_json::from_slice(
                &std::fs::read(
                    store::root()
                        .unwrap()
                        .join("samples")
                        .join(format!("{}.json", run.id)),
                )
                .unwrap(),
            )
            .unwrap();
            assert_eq!(samples.len(), 2);
            registry
                .restore_saved_plan(store::last_plan("scope").unwrap().unwrap())
                .unwrap();
            assert_eq!(
                store::history("scope", 0, i64::MAX, None, 10, 0)
                    .unwrap()
                    .runs
                    .len(),
                1
            );
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn restart_after_cancelling_running_round_records_only_that_round() {
        let root = std::env::temp_dir().join(format!("modeltrace-stop-{}", uuid::Uuid::new_v4()));
        {
            let _env =
                app_path_test_env_guard(&[("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", root.clone())]);
            let mut stored = saved_plan("running");
            stored.plan.next_run_at = None;
            store::save_plan(&stored).unwrap();
            store::request_cancel(&stored.plan.id).unwrap();
            let registry = ModelTraceRegistry::default();
            assert!(registry
                .restore_saved_plan(store::last_plan("scope").unwrap().unwrap())
                .unwrap()
                .is_none());
            let history = store::history("scope", 0, i64::MAX, None, 10, 0).unwrap();
            assert_eq!(history.runs.len(), 1);
            assert_eq!(history.runs[0].status, "cancelled");
            assert_eq!(history.runs[0].started_at, 1005);
            assert_eq!(
                store::last_plan("scope")
                    .unwrap()
                    .unwrap()
                    .plan
                    .completed_rounds,
                1
            );
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
#[tauri::command]
pub async fn read_modeltrace_history(
    window: tauri::WebviewWindow,
    since: i64,
    until: i64,
    model: Option<String>,
    offset: usize,
) -> Result<History, String> {
    require_window_label(&window, "read_modeltrace_history")?;
    if since < 0 || until <= since || offset > 1_000_000 {
        return Err("无效的检测历史范围".into());
    }
    run_blocking_command(move || {
        let source = capture_codex_home_source(None)?;
        let (scope, _) = identity(&source)?;
        store::history(&scope, since, until, model.as_deref(), 500, offset)
    })
    .await
}
