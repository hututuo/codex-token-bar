use crate::core::{app_paths, atomic_file, auto_resume, quota};
use crate::models::{
    AccountQuotaBundle, AutoResumeRuntimeStatus, AutoResumeSettingsSnapshot,
    AutoResumeThreadOption, QuotaLimit,
};
use crate::platform;
use serde::{Deserialize, Serialize};
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri_plugin_notification::NotificationExt;
use time::{OffsetDateTime, Time};

const TICK_INTERVAL: Duration = Duration::from_secs(15);
const QUOTA_CHECK_INTERVAL_SECONDS: i64 = 60;
static AUTO_RESUME_STATE_WRITE_GATE: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct QuotaWindowRuntime {
    #[serde(default)]
    observed: bool,
    reset_at: Option<i64>,
    remaining_percent: Option<f64>,
    armed: bool,
    #[serde(default)]
    recovery_ready: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistedAutoResumeState {
    #[serde(default)]
    state: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    waiting_for_quota: bool,
    #[serde(default)]
    last_trigger: Option<String>,
    #[serde(default)]
    last_run_at: Option<i64>,
    #[serde(default)]
    next_scheduled_at: Option<i64>,
    #[serde(default)]
    runs_day: String,
    #[serde(default)]
    runs_today: u32,
    #[serde(default)]
    pending_trigger_key: Option<String>,
    #[serde(default)]
    pending_trigger_label: Option<String>,
    #[serde(default)]
    pending_thread_id: Option<String>,
    #[serde(default)]
    pending_trigger_kind: Option<String>,
    #[serde(default)]
    pending_armed_at: Option<i64>,
    #[serde(default)]
    pending_schedule_generation: Option<u64>,
    #[serde(default)]
    schedule_generation: u64,
    #[serde(default)]
    quota_generation: u64,
    #[serde(default)]
    deferred_until: Option<i64>,
    #[serde(default)]
    last_quota_check_at: Option<i64>,
    #[serde(default)]
    last_quota_persist_at: Option<i64>,
    #[serde(default)]
    five_hour: QuotaWindowRuntime,
    #[serde(default)]
    seven_day: QuotaWindowRuntime,
    #[serde(default)]
    revision: u64,
}

impl Default for PersistedAutoResumeState {
    fn default() -> Self {
        Self {
            state: "disabled".into(),
            message: "自动续跑未开启".into(),
            waiting_for_quota: false,
            last_trigger: None,
            last_run_at: None,
            next_scheduled_at: None,
            runs_day: local_day_key(),
            runs_today: 0,
            pending_trigger_key: None,
            pending_trigger_label: None,
            pending_thread_id: None,
            pending_trigger_kind: None,
            pending_armed_at: None,
            pending_schedule_generation: None,
            schedule_generation: 0,
            quota_generation: 0,
            deferred_until: None,
            last_quota_check_at: None,
            last_quota_persist_at: None,
            five_hour: QuotaWindowRuntime::default(),
            seven_day: QuotaWindowRuntime::default(),
            revision: 0,
        }
    }
}

struct RegistryState {
    settings: AutoResumeSettingsSnapshot,
    persisted: PersistedAutoResumeState,
    running: bool,
    cancel: Option<Arc<AtomicBool>>,
}

impl Default for RegistryState {
    fn default() -> Self {
        Self {
            settings: AutoResumeSettingsSnapshot::default(),
            persisted: PersistedAutoResumeState::default(),
            running: false,
            cancel: None,
        }
    }
}

#[derive(Clone, Default)]
pub struct AutoResumeRegistry {
    state: Arc<Mutex<RegistryState>>,
    started: Arc<AtomicBool>,
    schedule_generation: Arc<RwLock<u64>>,
    quota_generation: Arc<RwLock<u64>>,
}

struct BackgroundStartedOwner {
    started: Arc<AtomicBool>,
}

impl Drop for BackgroundStartedOwner {
    fn drop(&mut self) {
        self.started.store(false, Ordering::Release);
    }
}

impl AutoResumeRegistry {
    pub fn initialize_and_start(&self, app: tauri::AppHandle) {
        if self.started.swap(true, Ordering::AcqRel) {
            return;
        }
        let settings = platform::read_app_settings()
            .map(|value| value.auto_resume)
            .unwrap_or_default();
        let persisted = load_state().unwrap_or_default();
        let (schedule_generation, quota_generation, persisted) = {
            let mut state = lock(&self.state);
            state.settings = settings;
            state.persisted = persisted;
            let before = state.persisted.clone();
            normalize_day(&mut state.persisted);
            recover_interrupted_run(&mut state.persisted);
            let settings = state.settings.clone();
            reconcile_schedule(&settings, &mut state.persisted, unix_now());
            refresh_idle_status(&settings, &mut state.persisted);
            if state.persisted != before {
                bump(&mut state.persisted);
            }
            (
                state.persisted.schedule_generation,
                state.persisted.quota_generation,
                state.persisted.clone(),
            )
        };
        let _ = persist_state(&persisted);
        set_generation(&self.schedule_generation, schedule_generation);
        set_generation(&self.quota_generation, quota_generation);
        let registry = self.clone();
        let started = self.started.clone();
        tauri::async_runtime::spawn(async move {
            let _started_owner = BackgroundStartedOwner { started };
            let mut interval = tokio::time::interval(TICK_INTERVAL);
            loop {
                interval.tick().await;
                let tick_registry = registry.clone();
                let tick_app = app.clone();
                let mut tick = tokio::task::JoinSet::new();
                tick.spawn(async move {
                    tick_registry.tick(tick_app).await;
                });
                if let Some(Err(error)) = tick.join_next().await {
                    eprintln!("Codex Token Bar: auto-resume tick recovered after panic: {error}");
                }
            }
        });
    }

    pub fn update_settings(&self, settings: AutoResumeSettingsSnapshot) {
        let now = unix_now();
        let mut state = lock(&self.state);
        let target_changed = state.settings.thread_id != settings.thread_id;
        let quota_context_changed = state.settings.enabled != settings.enabled
            || target_changed
            || state.settings.quota_resume_enabled != settings.quota_resume_enabled
            || state.settings.quota_window != settings.quota_window
            || state.settings.quota_low_threshold_percent != settings.quota_low_threshold_percent
            || state.settings.quota_recovery_threshold_percent
                != settings.quota_recovery_threshold_percent;
        let safety_limits_changed = automatic_safety_limits_changed(&state.settings, &settings);
        let quota_wait_disabled = state.settings.quota_resume_enabled
            && !settings.quota_resume_enabled
            && state.persisted.waiting_for_quota;
        let pending_schedule = matches!(
            state.persisted.pending_trigger_kind.as_deref(),
            Some("interval" | "daily")
        ) || state
            .persisted
            .pending_trigger_label
            .as_deref()
            .is_some_and(|label| label.contains("定时"));
        let schedule_changed = state.settings.schedule_mode != settings.schedule_mode
            || state.settings.interval_minutes != settings.interval_minutes
            || state.settings.daily_hour != settings.daily_hour
            || state.settings.daily_minute != settings.daily_minute
            || target_changed
            || state.settings.enabled != settings.enabled;
        let schedule_generation_changed = schedule_changed || safety_limits_changed;
        let quota_generation_changed = quota_context_changed || safety_limits_changed;
        state.settings = settings;
        if schedule_generation_changed {
            state.persisted.schedule_generation =
                state.persisted.schedule_generation.saturating_add(1);
            set_generation(
                &self.schedule_generation,
                state.persisted.schedule_generation,
            );
        }
        if quota_generation_changed {
            state.persisted.quota_generation = state.persisted.quota_generation.saturating_add(1);
            set_generation(&self.quota_generation, state.persisted.quota_generation);
        }
        if quota_context_changed || quota_wait_disabled || target_changed {
            state.persisted.five_hour = QuotaWindowRuntime::default();
            state.persisted.seven_day = QuotaWindowRuntime::default();
            state.persisted.waiting_for_quota = false;
            state.persisted.pending_trigger_key = None;
            state.persisted.pending_trigger_label = None;
            state.persisted.pending_thread_id = None;
            state.persisted.pending_trigger_kind = None;
            state.persisted.pending_armed_at = None;
            state.persisted.pending_schedule_generation = None;
            state.persisted.last_quota_check_at = None;
            state.persisted.last_quota_persist_at = None;
            state.persisted.deferred_until = None;
            if pending_schedule && state.settings.enabled && state.settings.schedule_mode != "off" {
                state.persisted.next_scheduled_at = Some(now);
            }
        }
        if schedule_changed && pending_schedule {
            clear_pending_trigger(&mut state.persisted);
            state.persisted.deferred_until = None;
        }
        if schedule_changed {
            let current_settings = state.settings.clone();
            state.persisted.next_scheduled_at = if current_settings.enabled {
                initial_next_schedule(&current_settings, now)
            } else {
                None
            };
        }
        if !state.settings.enabled {
            state.persisted.pending_trigger_key = None;
            state.persisted.pending_trigger_label = None;
            state.persisted.pending_thread_id = None;
            state.persisted.pending_trigger_kind = None;
            state.persisted.pending_armed_at = None;
            state.persisted.pending_schedule_generation = None;
            state.persisted.waiting_for_quota = false;
            state.persisted.deferred_until = None;
        }
        let settings = state.settings.clone();
        refresh_idle_status(&settings, &mut state.persisted);
        bump(&mut state.persisted);
        let persisted = state.persisted.clone();
        drop(state);
        let _ = persist_state(&persisted);
    }

    pub fn status(&self) -> AutoResumeRuntimeStatus {
        let state = lock(&self.state);
        status_from(&state)
    }

    pub fn cancel(&self) -> AutoResumeRuntimeStatus {
        let (status, persisted) = {
            let mut state = lock(&self.state);
            let persisted = if let Some(cancel) = &state.cancel {
                cancel.store(true, Ordering::Release);
                state.persisted.message = "正在停止本次自动续跑…".into();
                state.persisted.state = "cancelling".into();
                bump(&mut state.persisted);
                Some(state.persisted.clone())
            } else {
                None
            };
            (status_from(&state), persisted)
        };
        if let Some(persisted) = persisted {
            let _ = persist_state(&persisted);
        }
        status
    }

    pub fn observe_quota(&self, bundle: &AccountQuotaBundle) {
        let mut state = lock(&self.state);
        let now = unix_now();
        let previous_five_reset = state.persisted.five_hour.reset_at;
        let previous_seven_reset = state.persisted.seven_day.reset_at;
        let previous_five_armed = state.persisted.five_hour.armed;
        let previous_seven_armed = state.persisted.seven_day.armed;
        let previous_waiting = state.persisted.waiting_for_quota;
        state.persisted.last_quota_check_at = Some(now);
        let settings = state.settings.clone();
        let recovered = observe_quota_bundle(&settings, &mut state.persisted, bundle);
        let newly_armed = !previous_five_armed && state.persisted.five_hour.armed
            || !previous_seven_armed && state.persisted.seven_day.armed;
        if newly_armed && state.persisted.pending_armed_at.is_none() {
            state.persisted.pending_armed_at = Some(now);
        }
        let important_change = recovered
            || newly_armed
            || previous_five_reset != state.persisted.five_hour.reset_at
            || previous_seven_reset != state.persisted.seven_day.reset_at
            || previous_five_armed != state.persisted.five_hour.armed
            || previous_seven_armed != state.persisted.seven_day.armed
            || previous_waiting != state.persisted.waiting_for_quota;
        let persistence_due = state
            .persisted
            .last_quota_persist_at
            .is_none_or(|last| now.saturating_sub(last) >= 5 * 60);
        let persisted = if important_change || persistence_due {
            state.persisted.last_quota_persist_at = Some(now);
            bump(&mut state.persisted);
            Some(state.persisted.clone())
        } else {
            None
        };
        drop(state);
        if let Some(persisted) = persisted {
            let _ = persist_state(&persisted);
        }
        if recovered {
            // The background tick consumes the pending/recovery trigger. Keeping the
            // observation side-effect synchronous avoids duplicate launches from UI refreshes.
        }
    }

    async fn tick(&self, app: tauri::AppHandle) {
        let now = unix_now();
        let (should_read_quota, stop, persisted) = {
            let mut state = lock(&self.state);
            let before = state.persisted.clone();
            normalize_day(&mut state.persisted);
            let stop =
                !state.settings.enabled || state.running || state.settings.thread_id.is_empty();
            let should_read_quota = if stop {
                let settings = state.settings.clone();
                refresh_idle_status(&settings, &mut state.persisted);
                false
            } else {
                let settings = state.settings.clone();
                reconcile_schedule(&settings, &mut state.persisted, now);
                state.settings.quota_resume_enabled
                    && state.persisted.last_quota_check_at.is_none_or(|last| {
                        now.saturating_sub(last) >= QUOTA_CHECK_INTERVAL_SECONDS
                    })
            };
            let persisted = (state.persisted != before).then(|| {
                bump(&mut state.persisted);
                state.persisted.clone()
            });
            (should_read_quota, stop, persisted)
        };
        if let Some(persisted) = persisted {
            let _ = persist_state(&persisted);
        }
        if stop {
            return;
        }

        if should_read_quota {
            let home = auto_resume::default_codex_home();
            let quota = tauri::async_runtime::spawn_blocking(move || {
                quota::read_account_quota(&home, false)
            })
            .await;
            match quota {
                Ok(Ok(bundle)) => self.observe_quota(&bundle),
                _ => {
                    let persisted = {
                        let mut state = lock(&self.state);
                        state.persisted.last_quota_check_at = Some(unix_now());
                        bump(&mut state.persisted);
                        state.persisted.clone()
                    };
                    let _ = persist_state(&persisted);
                }
            }
        }

        let trigger = {
            let mut state = lock(&self.state);
            let now = unix_now();
            if state
                .persisted
                .deferred_until
                .is_some_and(|until| until > now)
            {
                None
            } else {
                state.persisted.deferred_until = None;
                recovered_trigger(&mut state).or_else(|| due_trigger(&mut state, now))
            }
        };
        if let Some(trigger) = trigger {
            let registry = self.clone();
            tauri::async_runtime::spawn(async move {
                let _ = registry.execute_owned(app, trigger, false).await;
            });
        }
    }

    async fn run_manual(&self, app: tauri::AppHandle) -> Result<AutoResumeRuntimeStatus, String> {
        let (thread_id, consumes_pending) = {
            let state = lock(&self.state);
            let thread_id = state.settings.thread_id.clone();
            let consumes_pending = state.persisted.waiting_for_quota
                && state
                    .persisted
                    .pending_thread_id
                    .as_deref()
                    .is_none_or(|pending| pending == thread_id.as_str());
            (thread_id, consumes_pending)
        };
        let key = format!("manual:{}:{}:{}", thread_id, unix_now(), std::process::id());
        self.execute_owned(
            app,
            Trigger {
                key,
                label: "手动续跑".into(),
                thread_id,
                kind: TriggerKind::Manual,
                consumes_pending,
                freshness_not_before: None,
                schedule_generation: None,
                quota_generation: None,
            },
            true,
        )
        .await
    }

    async fn execute_owned(
        &self,
        app: tauri::AppHandle,
        trigger: Trigger,
        manual: bool,
    ) -> Result<AutoResumeRuntimeStatus, String> {
        let runner = self.clone();
        let recovery = self.clone();
        let receiver = spawn_supervised_task(
            async move { runner.execute(app, trigger, manual).await },
            move |error| {
                let message = format!("自动续跑监督任务异常结束：{error}");
                recovery.finish_without_run(&message, "failed");
                Err(message)
            },
        );
        receiver
            .await
            .map_err(|_| "自动续跑监督任务未返回结果".to_string())?
    }

    async fn execute(
        &self,
        app: tauri::AppHandle,
        trigger: Trigger,
        manual: bool,
    ) -> Result<AutoResumeRuntimeStatus, String> {
        let (settings, cancel, home, persisted) = {
            let mut state = lock(&self.state);
            if state.running {
                return Err("已有自动续跑正在执行".into());
            }
            if state.settings.thread_id.is_empty() {
                return Err("请先选择要续跑的 Codex 任务".into());
            }
            if state.settings.thread_id != trigger.thread_id {
                if trigger.consumes_pending
                    && state.persisted.pending_thread_id.as_deref()
                        == Some(trigger.thread_id.as_str())
                {
                    clear_pending_trigger(&mut state.persisted);
                }
                state.persisted.state = "skipped".into();
                state.persisted.message = "目标任务已更改，旧续跑触发已作废".into();
                bump(&mut state.persisted);
                let status = status_from(&state);
                let persisted = state.persisted.clone();
                drop(state);
                let _ = persist_state(&persisted);
                return Ok(status);
            }
            if !manual {
                if !state.settings.enabled {
                    return Err("自动续跑未开启".into());
                }
                if !automatic_trigger_is_current(&state, &trigger) {
                    let status = settle_stale_automatic_trigger(&mut state, &trigger);
                    let persisted = state.persisted.clone();
                    drop(state);
                    let _ = persist_state(&persisted);
                    return Ok(status);
                }
                if state.persisted.runs_today >= u32::from(state.settings.max_runs_per_day) {
                    let status = settle_daily_limit(&mut state, &trigger, unix_now());
                    let persisted = state.persisted.clone();
                    drop(state);
                    let _ = persist_state(&persisted);
                    return Ok(status);
                }
                if let Some(last) = state.persisted.last_run_at {
                    let cooldown = i64::from(state.settings.cooldown_minutes) * 60;
                    if unix_now().saturating_sub(last) < cooldown {
                        state.persisted.deferred_until = Some(last.saturating_add(cooldown));
                        state.persisted.state = "waiting".into();
                        state.persisted.message = "触发已到，冷却结束后再续跑".into();
                        bump(&mut state.persisted);
                        let status = status_from(&state);
                        let persisted = state.persisted.clone();
                        drop(state);
                        let _ = persist_state(&persisted);
                        return Ok(status);
                    }
                }
            }
            state.running = true;
            state.persisted.deferred_until = None;
            let cancel = Arc::new(AtomicBool::new(false));
            state.cancel = Some(cancel.clone());
            state.persisted.state = "running".into();
            state.persisted.message = format!("正在执行{}", trigger.label);
            state.persisted.last_trigger = Some(trigger.label.clone());
            bump(&mut state.persisted);
            (
                state.settings.clone(),
                cancel,
                auto_resume::default_codex_home(),
                state.persisted.clone(),
            )
        };
        let _ = persist_state(&persisted);

        let shared_cooldown = if manual {
            Duration::ZERO
        } else {
            Duration::from_secs(u64::from(settings.cooldown_minutes) * 60)
        };
        let automatic_limit = (!manual).then(|| auto_resume::AutoResumeAutomaticClaimLimit {
            day_start_unix: local_day_start_timestamp(unix_now()) as f64,
            max_runs: settings.max_runs_per_day,
        });
        let claim_result = match auto_resume::claim_trigger(
            &home,
            &trigger.thread_id,
            &trigger.key,
            shared_cooldown,
            automatic_limit,
        ) {
            Ok(result) => result,
            Err(error) => {
                self.defer_until(unix_now().saturating_add(60));
                self.finish_without_run(&error, "failed");
                return Err(error);
            }
        };

        let stale_status = {
            let mut state = lock(&self.state);
            if automatic_trigger_is_current(&state, &trigger) {
                None
            } else {
                let status = settle_stale_automatic_trigger(&mut state, &trigger);
                Some((status, state.persisted.clone()))
            }
        };
        if let Some((status, persisted)) = stale_status {
            let _ = persist_state(&persisted);
            if let auto_resume::AutoResumeClaimResult::Claimed(claim) = &claim_result {
                let outcome = auto_resume::AutoResumeRunOutcome {
                    status: "skipped".into(),
                    message: "自动续跑设置已更改，旧触发已在执行前作废".into(),
                    turn_id: None,
                    quota_limited: false,
                };
                let _ = claim.complete(&outcome);
            }
            return Ok(status);
        }

        let claim = match claim_result {
            auto_resume::AutoResumeClaimResult::Claimed(claim) => claim,
            auto_resume::AutoResumeClaimResult::Duplicate => {
                return Ok(self.settle_duplicate_trigger(&trigger));
            }
            auto_resume::AutoResumeClaimResult::Busy => {
                self.defer_until(unix_now().saturating_add(60));
                return Ok(self.finish_without_run("同一任务已有续跑进程，已跳过", "guarded"));
            }
            auto_resume::AutoResumeClaimResult::DailyLimit => {
                let (status, persisted) = {
                    let mut state = lock(&self.state);
                    let status = settle_daily_limit(&mut state, &trigger, unix_now());
                    (status, state.persisted.clone())
                };
                let _ = persist_state(&persisted);
                return Ok(status);
            }
        };

        if trigger.consumes_pending {
            let persisted = {
                let mut state = lock(&self.state);
                clear_pending_trigger(&mut state.persisted);
                bump(&mut state.persisted);
                state.persisted.clone()
            };
            let _ = persist_state(&persisted);
        }

        let thread_id = trigger.thread_id.clone();
        let prompt = settings.prompt.clone();
        let client_message_id = trigger.key.clone();
        let freshness_not_before = trigger.freshness_not_before;
        let start_generation_guard = match trigger.kind {
            TriggerKind::Interval | TriggerKind::Daily => {
                trigger.schedule_generation.map(|generation| {
                    auto_resume::AutoResumeStartGenerationGuard::new(
                        self.schedule_generation.clone(),
                        generation,
                    )
                })
            }
            TriggerKind::QuotaRecovery => trigger.quota_generation.map(|generation| {
                auto_resume::AutoResumeStartGenerationGuard::new(
                    self.quota_generation.clone(),
                    generation,
                )
            }),
            TriggerKind::Manual => None,
        };
        let run_cancel = cancel.clone();
        let run_home = home.clone();
        let outcome = match tauri::async_runtime::spawn_blocking(move || {
            auto_resume::run_turn(
                &run_home,
                &thread_id,
                &prompt,
                &client_message_id,
                freshness_not_before,
                start_generation_guard,
                run_cancel,
            )
        })
        .await
        {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(error)) => auto_resume::AutoResumeRunOutcome {
                status: "failed".into(),
                message: error,
                turn_id: None,
                quota_limited: false,
            },
            Err(error) => auto_resume::AutoResumeRunOutcome {
                status: "failed".into(),
                message: format!("自动续跑后台任务异常结束：{error}"),
                turn_id: None,
                quota_limited: false,
            },
        };
        if !manual && outcome.status != "skipped" {
            let persisted = {
                let mut state = lock(&self.state);
                normalize_day(&mut state.persisted);
                state.persisted.runs_today = state.persisted.runs_today.saturating_add(1);
                bump(&mut state.persisted);
                state.persisted.clone()
            };
            let _ = persist_state(&persisted);
        }
        let _ = claim.complete(&outcome);

        let (status, persisted) = {
            let mut state = lock(&self.state);
            state.running = false;
            state.cancel = None;
            state.persisted.state = outcome.status.clone();
            state.persisted.message = outcome.message.clone();
            if outcome.status != "skipped" {
                state.persisted.last_run_at = Some(unix_now());
            }
            if outcome.quota_limited {
                state.persisted.waiting_for_quota = true;
                let current_settings = state.settings.clone();
                let source_still_enabled =
                    !trigger.kind.is_scheduled() || scheduled_trigger_is_current(&state, &trigger);
                if current_settings.thread_id == trigger.thread_id
                    && current_settings.enabled
                    && current_settings.quota_resume_enabled
                    && source_still_enabled
                {
                    arm_selected_windows(&current_settings, &mut state.persisted);
                    // 原触发 key 已随本次运行写入共享 ledger；恢复后必须换统一的
                    // quota:{线程}:{窗口}:{reset} key 重新去重（pending key 留空，
                    // recovered_trigger 按契约构造），沿用旧 key 会拿到 Duplicate
                    // 而永远不再续跑。
                    state.persisted.pending_trigger_key = None;
                    state.persisted.pending_trigger_label = Some("额度恢复续跑".into());
                    state.persisted.pending_thread_id = Some(trigger.thread_id.clone());
                    state.persisted.pending_armed_at = Some(unix_now());
                    state.persisted.pending_schedule_generation = trigger
                        .kind
                        .is_scheduled()
                        .then_some(trigger.schedule_generation)
                        .flatten();
                    state.persisted.pending_trigger_kind = Some(
                        if trigger.kind.is_scheduled() {
                            trigger.kind
                        } else {
                            TriggerKind::QuotaRecovery
                        }
                        .as_str()
                        .into(),
                    );
                } else {
                    clear_pending_trigger(&mut state.persisted);
                    state.persisted.waiting_for_quota = false;
                }
            }
            if trigger.kind.is_scheduled()
                && scheduled_trigger_is_current(&state, &trigger)
                && !outcome.quota_limited
            {
                let current_settings = state.settings.clone();
                advance_schedule_after_trigger(&current_settings, &mut state.persisted, unix_now());
            }
            bump(&mut state.persisted);
            (status_from(&state), state.persisted.clone())
        };
        let _ = persist_state(&persisted);

        if settings.notify_on_result {
            let title = if outcome.status == "succeeded" {
                "Codex 自动续跑完成"
            } else {
                "Codex 自动续跑需要留意"
            };
            let _ = app
                .notification()
                .builder()
                .title(title)
                .body(outcome.message)
                .show();
        }
        Ok(status)
    }

    fn finish_without_run(&self, message: &str, status: &str) -> AutoResumeRuntimeStatus {
        let (status, persisted) = {
            let mut state = lock(&self.state);
            state.running = false;
            state.cancel = None;
            state.persisted.state = status.into();
            state.persisted.message = message.into();
            bump(&mut state.persisted);
            (status_from(&state), state.persisted.clone())
        };
        let _ = persist_state(&persisted);
        status
    }

    fn defer_until(&self, until: i64) {
        let persisted = {
            let mut state = lock(&self.state);
            state.persisted.deferred_until = Some(
                state
                    .persisted
                    .deferred_until
                    .map_or(until, |current| current.max(until)),
            );
            bump(&mut state.persisted);
            state.persisted.clone()
        };
        let _ = persist_state(&persisted);
    }

    fn settle_duplicate_trigger(&self, trigger: &Trigger) -> AutoResumeRuntimeStatus {
        let (status, persisted) = {
            let mut state = lock(&self.state);
            state.running = false;
            state.cancel = None;
            state.persisted.deferred_until = None;
            if trigger.consumes_pending {
                clear_pending_trigger(&mut state.persisted);
            }
            if trigger.kind.is_scheduled() && state.settings.thread_id == trigger.thread_id {
                let settings = state.settings.clone();
                advance_schedule_after_trigger(&settings, &mut state.persisted, unix_now());
            }
            state.persisted.state = "skipped".into();
            state.persisted.message = "该触发已由另一端处理".into();
            bump(&mut state.persisted);
            (status_from(&state), state.persisted.clone())
        };
        let _ = persist_state(&persisted);
        status
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TriggerKind {
    Manual,
    Interval,
    Daily,
    QuotaRecovery,
}

impl TriggerKind {
    fn is_scheduled(self) -> bool {
        matches!(self, Self::Interval | Self::Daily)
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Interval => "interval",
            Self::Daily => "daily",
            Self::QuotaRecovery => "quotaRecovery",
        }
    }

    fn from_pending(value: Option<&str>) -> Self {
        match value {
            Some("interval") => Self::Interval,
            Some("daily") => Self::Daily,
            _ => Self::QuotaRecovery,
        }
    }
}

#[derive(Clone, Debug)]
struct Trigger {
    key: String,
    label: String,
    thread_id: String,
    kind: TriggerKind,
    consumes_pending: bool,
    freshness_not_before: Option<i64>,
    schedule_generation: Option<u64>,
    quota_generation: Option<u64>,
}

fn scheduled_trigger_is_current(state: &RegistryState, trigger: &Trigger) -> bool {
    !trigger.kind.is_scheduled()
        || (state.settings.enabled
            && state.settings.thread_id == trigger.thread_id
            && state.settings.schedule_mode == trigger.kind.as_str()
            && trigger.schedule_generation == Some(state.persisted.schedule_generation))
}

fn quota_trigger_is_current(state: &RegistryState, trigger: &Trigger) -> bool {
    trigger.kind != TriggerKind::QuotaRecovery
        || (state.settings.enabled
            && state.settings.quota_resume_enabled
            && state.settings.thread_id == trigger.thread_id
            && trigger.quota_generation == Some(state.persisted.quota_generation))
}

fn automatic_trigger_is_current(state: &RegistryState, trigger: &Trigger) -> bool {
    scheduled_trigger_is_current(state, trigger) && quota_trigger_is_current(state, trigger)
}

fn automatic_safety_limits_changed(
    current: &AutoResumeSettingsSnapshot,
    next: &AutoResumeSettingsSnapshot,
) -> bool {
    current.cooldown_minutes != next.cooldown_minutes
        || current.max_runs_per_day != next.max_runs_per_day
}

fn settle_stale_automatic_trigger(
    state: &mut RegistryState,
    trigger: &Trigger,
) -> AutoResumeRuntimeStatus {
    state.running = false;
    state.cancel = None;
    if trigger.consumes_pending
        && state.persisted.pending_thread_id.as_deref() == Some(trigger.thread_id.as_str())
    {
        clear_pending_trigger(&mut state.persisted);
    }
    state.persisted.state = "skipped".into();
    state.persisted.message = "自动续跑设置已更改，旧触发已作废".into();
    bump(&mut state.persisted);
    status_from(state)
}

fn settle_daily_limit(
    state: &mut RegistryState,
    trigger: &Trigger,
    now: i64,
) -> AutoResumeRuntimeStatus {
    state.running = false;
    state.cancel = None;
    if trigger.kind == TriggerKind::Daily {
        let settings = state.settings.clone();
        advance_schedule_after_trigger(&settings, &mut state.persisted, now);
        if trigger.consumes_pending {
            clear_pending_trigger(&mut state.persisted);
        }
    } else {
        state.persisted.deferred_until = Some(next_daily_timestamp(0, 0, now));
    }
    state.persisted.state = "guarded".into();
    state.persisted.message = "已达到今天的跨端自动续跑次数上限".into();
    bump(&mut state.persisted);
    status_from(state)
}

#[tauri::command]
pub async fn list_auto_resume_threads(
    window: tauri::WebviewWindow,
) -> Result<Vec<AutoResumeThreadOption>, String> {
    super::window_auth::require_window_label(&window, "list_auto_resume_threads")?;
    let home = auto_resume::default_codex_home();
    tauri::async_runtime::spawn_blocking(move || auto_resume::list_threads(&home))
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub fn read_auto_resume_status(
    window: tauri::WebviewWindow,
    registry: tauri::State<'_, AutoResumeRegistry>,
) -> Result<AutoResumeRuntimeStatus, String> {
    super::window_auth::require_window_label(&window, "read_auto_resume_status")?;
    Ok(registry.status())
}

#[tauri::command]
pub async fn run_auto_resume_now(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, AutoResumeRegistry>,
) -> Result<AutoResumeRuntimeStatus, String> {
    super::window_auth::require_window_label(&window, "run_auto_resume_now")?;
    registry.run_manual(app).await
}

#[tauri::command]
pub fn cancel_auto_resume_run(
    window: tauri::WebviewWindow,
    registry: tauri::State<'_, AutoResumeRegistry>,
) -> Result<AutoResumeRuntimeStatus, String> {
    super::window_auth::require_window_label(&window, "cancel_auto_resume_run")?;
    Ok(registry.cancel())
}

// 跨端触发 key 契约（必须与 Swift AutoResumePolicy 逐字节一致，两端各有
// 同名 contract 测试互为镜像；共享 ledger 按 key 精确匹配去重，格式不一致
// 会使同一触发两端各发一次"继续"）：
// - daily:    daily:{线程}:{本地日期 YYYY-MM-DD}:{HHMM}
// - interval: interval:{线程}:{间隔分钟}:{floor(触发时刻纪元秒 / 间隔秒)}
// - quota:    quota:{线程}:{5h|7d}:{重置纪元秒}（双窗口同时恢复取 5h）
// - capacity: capacity:{线程}:{turnId}（目前仅 Swift 端产生）
// - manual:   manual: 前缀 + 各端自用唯一后缀（不参与跨端去重，只共享
//             每日上限豁免）
fn daily_trigger_key(thread_id: &str, day: &str, hour: u8, minute: u8) -> String {
    format!("daily:{thread_id}:{day}:{hour:02}{minute:02}")
}

fn interval_trigger_key(thread_id: &str, interval_minutes: u32, now: i64) -> String {
    let seconds = i64::from(interval_minutes.max(1)) * 60;
    format!(
        "interval:{thread_id}:{interval_minutes}:{}",
        now.div_euclid(seconds)
    )
}

fn quota_trigger_key(thread_id: &str, recovery_key: &str) -> String {
    format!("quota:{thread_id}:{recovery_key}")
}

fn due_trigger(state: &mut RegistryState, now: i64) -> Option<Trigger> {
    if state.persisted.waiting_for_quota
        || state.persisted.pending_trigger_key.is_some()
        || state.persisted.pending_thread_id.is_some()
    {
        return None;
    }
    let due = state.persisted.next_scheduled_at?;
    if now < due {
        return None;
    }
    let (label, kind) = match state.settings.schedule_mode.as_str() {
        "interval" => ("定时续跑", TriggerKind::Interval),
        "daily" => ("每日定时续跑", TriggerKind::Daily),
        _ => return None,
    };
    let key = match state.settings.schedule_mode.as_str() {
        "daily" => daily_trigger_key(
            &state.settings.thread_id,
            &local_day_key(),
            state.settings.daily_hour,
            state.settings.daily_minute,
        ),
        _ => interval_trigger_key(
            &state.settings.thread_id,
            state.settings.interval_minutes,
            now,
        ),
    };
    if selected_quota_is_low(&state.settings, &state.persisted) {
        state.persisted.waiting_for_quota = true;
        state.persisted.pending_trigger_key = Some(key);
        state.persisted.pending_trigger_label = Some(label.into());
        state.persisted.pending_thread_id = Some(state.settings.thread_id.clone());
        state.persisted.pending_trigger_kind = Some(kind.as_str().into());
        state.persisted.pending_armed_at = Some(now);
        state.persisted.pending_schedule_generation = Some(state.persisted.schedule_generation);
        state.persisted.state = "waitingQuota".into();
        state.persisted.message = "定时触发已到，但额度偏低；将于额度恢复后续跑".into();
        arm_selected_windows(&state.settings, &mut state.persisted);
        bump(&mut state.persisted);
        return None;
    }
    Some(Trigger {
        key,
        label: label.into(),
        thread_id: state.settings.thread_id.clone(),
        kind,
        consumes_pending: false,
        freshness_not_before: Some(due),
        schedule_generation: Some(state.persisted.schedule_generation),
        quota_generation: None,
    })
}

fn recovered_trigger(state: &mut RegistryState) -> Option<Trigger> {
    if !state.persisted.waiting_for_quota
        || !selected_quota_recovered(&state.settings, &state.persisted)
    {
        return None;
    }
    let pending_thread_id = state
        .persisted
        .pending_thread_id
        .as_deref()
        .unwrap_or(state.settings.thread_id.as_str());
    if pending_thread_id != state.settings.thread_id {
        clear_pending_trigger(&mut state.persisted);
        return None;
    }
    // 跨端契约：被低额度挂起的排程触发直接用其槽位 key 去重——对端若已跑过
    // 同一槽位会得到 Duplicate 并推进日程，而不是冷却一过再发一次；纯额度
    // 恢复用统一的 quota:{线程}:{窗口}:{reset} key，与 Swift 端同一恢复事件
    // 相互去重。旧的 "{pending}:{recovery}" 拼接 key 与任何对端 key 都不可能
    // 相等，正是双发的根源之一。
    let key = state
        .persisted
        .pending_trigger_key
        .clone()
        .or_else(|| {
            quota_recovery_key(&state.settings, &state.persisted)
                .map(|recovery_key| quota_trigger_key(&state.settings.thread_id, &recovery_key))
        })?;
    let label = state
        .persisted
        .pending_trigger_label
        .clone()
        .unwrap_or_else(|| "额度恢复续跑".into());
    let kind = TriggerKind::from_pending(state.persisted.pending_trigger_kind.as_deref());
    let schedule_generation = kind
        .is_scheduled()
        .then_some(state.persisted.pending_schedule_generation)
        .flatten();
    Some(Trigger {
        key,
        label,
        thread_id: state.settings.thread_id.clone(),
        kind,
        consumes_pending: true,
        freshness_not_before: state.persisted.pending_armed_at,
        schedule_generation,
        quota_generation: (kind == TriggerKind::QuotaRecovery)
            .then_some(state.persisted.quota_generation),
    })
}

fn observe_quota_bundle(
    settings: &AutoResumeSettingsSnapshot,
    state: &mut PersistedAutoResumeState,
    bundle: &AccountQuotaBundle,
) -> bool {
    if !settings.enabled || !settings.quota_resume_enabled {
        return false;
    }
    let five = observe_window(
        &mut state.five_hour,
        &bundle.quota.five_hour,
        settings.quota_low_threshold_percent,
        settings.quota_recovery_threshold_percent,
    );
    let seven = observe_window(
        &mut state.seven_day,
        &bundle.quota.seven_day,
        settings.quota_low_threshold_percent,
        settings.quota_recovery_threshold_percent,
    );
    let selected = match settings.quota_window.as_str() {
        "fiveHour" => five,
        "sevenDay" => seven,
        _ => five || seven,
    };
    if selected {
        state.waiting_for_quota = true;
        // 以 pending_thread_id 判断"是否已有挂起触发上下文"：运行中撞限的
        // 排程触发会保留 thread/kind 但把 key 留空（恢复时按契约重建），
        // 此处不得用 key 判空覆盖其排程语义。
        if state.pending_thread_id.is_none() {
            state.pending_trigger_label = Some("额度恢复续跑".into());
            state.pending_thread_id = Some(settings.thread_id.clone());
            state.pending_trigger_kind = Some(TriggerKind::QuotaRecovery.as_str().into());
        }
        state.state = "waitingQuota".into();
        state.message = "已确认额度恢复，正在准备续跑".into();
        bump(state);
    }
    selected
}

fn observe_window(
    state: &mut QuotaWindowRuntime,
    limit: &QuotaLimit,
    low_threshold: u8,
    recovery_threshold: u8,
) -> bool {
    let low_threshold = f64::from(low_threshold) / 100.0;
    let recovery_threshold = f64::from(recovery_threshold) / 100.0;
    let previous_reset = state.reset_at;
    let previous_remaining = state.remaining_percent;
    let next_reset = limit.resets_at_unix;
    let next_remaining = limit.remaining_percent;
    if !state.observed {
        state.observed = true;
        state.reset_at = next_reset;
        state.remaining_percent = next_remaining;
        state.recovery_ready = false;
        return false;
    }
    if next_remaining.is_some_and(|remaining| remaining <= low_threshold) {
        state.armed = true;
        state.recovery_ready = false;
    }
    let reset_advanced = previous_reset
        .zip(next_reset)
        .is_some_and(|(previous, next)| next > previous);
    let remaining_recovered =
        previous_remaining
            .zip(next_remaining)
            .is_some_and(|(previous, next)| {
                previous <= low_threshold && next >= recovery_threshold && next >= previous + 0.05
            });
    let recovered = state.armed
        && (reset_advanced || remaining_recovered)
        && next_remaining.is_some_and(|remaining| remaining >= recovery_threshold);
    if recovered {
        state.recovery_ready = true;
    }
    state.reset_at = next_reset;
    state.remaining_percent = next_remaining;
    recovered
}

fn selected_quota_is_low(
    settings: &AutoResumeSettingsSnapshot,
    state: &PersistedAutoResumeState,
) -> bool {
    if !settings.quota_resume_enabled {
        return false;
    }
    let low = f64::from(settings.quota_low_threshold_percent) / 100.0;
    match settings.quota_window.as_str() {
        "fiveHour" => state
            .five_hour
            .remaining_percent
            .is_some_and(|value| value <= low),
        "sevenDay" => state
            .seven_day
            .remaining_percent
            .is_some_and(|value| value <= low),
        _ => {
            state
                .five_hour
                .remaining_percent
                .is_some_and(|value| value <= low)
                || state
                    .seven_day
                    .remaining_percent
                    .is_some_and(|value| value <= low)
        }
    }
}

fn selected_quota_recovered(
    settings: &AutoResumeSettingsSnapshot,
    state: &PersistedAutoResumeState,
) -> bool {
    let recovered = f64::from(settings.quota_recovery_threshold_percent) / 100.0;
    match settings.quota_window.as_str() {
        "fiveHour" => {
            state.five_hour.armed
                && state.five_hour.recovery_ready
                && state
                    .five_hour
                    .remaining_percent
                    .is_some_and(|value| value >= recovered)
        }
        "sevenDay" => {
            state.seven_day.armed
                && state.seven_day.recovery_ready
                && state
                    .seven_day
                    .remaining_percent
                    .is_some_and(|value| value >= recovered)
        }
        _ => {
            let any_recovery_edge = state.five_hour.armed && state.five_hour.recovery_ready
                || state.seven_day.armed && state.seven_day.recovery_ready;
            // 决策口径：只有"曾进入低位"（armed）的已测窗口才需要达到恢复阈值；
            // 从未低位的另一窗口长期低于恢复阈值（如 7d 常年 10%）不得阻塞触发。
            // 撞限武装（arm_selected_windows）会把两个窗口都置 armed，保守语义不变。
            // 与 Swift observeQuota 的 everyLowWindowRecovered 同语义。
            let every_low_window_recovered = [&state.five_hour, &state.seven_day]
                .into_iter()
                .filter(|window| window.armed)
                .filter_map(|window| window.remaining_percent)
                .all(|value| value >= recovered);
            any_recovery_edge && every_low_window_recovered
        }
    }
}

fn quota_recovery_key(
    settings: &AutoResumeSettingsSnapshot,
    state: &PersistedAutoResumeState,
) -> Option<String> {
    let recovered = f64::from(settings.quota_recovery_threshold_percent) / 100.0;
    let five = (state.five_hour.armed
        && state.five_hour.recovery_ready
        && state
            .five_hour
            .remaining_percent
            .is_some_and(|value| value >= recovered))
    .then(|| state.five_hour.reset_at.map(|reset| format!("5h:{reset}")))
    .flatten();
    let seven = (state.seven_day.armed
        && state.seven_day.recovery_ready
        && state
            .seven_day
            .remaining_percent
            .is_some_and(|value| value >= recovered))
    .then(|| state.seven_day.reset_at.map(|reset| format!("7d:{reset}")))
    .flatten();
    match settings.quota_window.as_str() {
        "fiveHour" => five,
        "sevenDay" => seven,
        // 跨端契约：双窗口同时恢复时取 5h。拼接 "5h:{r}+7d:{r}" 与 Swift 的
        // 单窗口 key 永不相等，会导致同一恢复事件两端各发一次。
        _ => five.or(seven),
    }
}

fn arm_selected_windows(
    settings: &AutoResumeSettingsSnapshot,
    state: &mut PersistedAutoResumeState,
) {
    match settings.quota_window.as_str() {
        "fiveHour" => {
            state.five_hour.armed = true;
            state.five_hour.recovery_ready = false;
        }
        "sevenDay" => {
            state.seven_day.armed = true;
            state.seven_day.recovery_ready = false;
        }
        _ => {
            state.five_hour.armed = true;
            state.seven_day.armed = true;
            state.five_hour.recovery_ready = false;
            state.seven_day.recovery_ready = false;
        }
    }
}

fn clear_pending_trigger(state: &mut PersistedAutoResumeState) {
    state.pending_trigger_key = None;
    state.pending_trigger_label = None;
    state.pending_thread_id = None;
    state.pending_trigger_kind = None;
    state.pending_armed_at = None;
    state.pending_schedule_generation = None;
    state.waiting_for_quota = false;
    state.five_hour.armed = false;
    state.seven_day.armed = false;
    state.five_hour.recovery_ready = false;
    state.seven_day.recovery_ready = false;
}

fn reconcile_schedule(
    settings: &AutoResumeSettingsSnapshot,
    state: &mut PersistedAutoResumeState,
    now: i64,
) {
    if !settings.enabled || settings.schedule_mode == "off" {
        state.next_scheduled_at = None;
        return;
    }
    if state.next_scheduled_at.is_none() {
        state.next_scheduled_at = initial_next_schedule(settings, now);
    }
}

fn initial_next_schedule(settings: &AutoResumeSettingsSnapshot, now: i64) -> Option<i64> {
    match settings.schedule_mode.as_str() {
        "interval" => Some(now.saturating_add(i64::from(settings.interval_minutes) * 60)),
        "daily" => Some(next_daily_timestamp(
            settings.daily_hour,
            settings.daily_minute,
            now,
        )),
        _ => None,
    }
}

fn advance_schedule_after_trigger(
    settings: &AutoResumeSettingsSnapshot,
    state: &mut PersistedAutoResumeState,
    now: i64,
) {
    state.next_scheduled_at = match settings.schedule_mode.as_str() {
        "interval" => Some(now.saturating_add(i64::from(settings.interval_minutes) * 60)),
        "daily" => Some(next_daily_timestamp(
            settings.daily_hour,
            settings.daily_minute,
            now,
        )),
        _ => None,
    };
}

fn next_daily_timestamp(hour: u8, minute: u8, now_unix: i64) -> i64 {
    let now = OffsetDateTime::from_unix_timestamp(now_unix)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
        .to_offset(local_offset());
    let candidate = now.replace_time(Time::from_hms(hour, minute, 0).unwrap_or(Time::MIDNIGHT));
    let next = if candidate.unix_timestamp() > now_unix {
        candidate
    } else {
        candidate + time::Duration::days(1)
    };
    next.unix_timestamp()
}

fn local_day_start_timestamp(now_unix: i64) -> i64 {
    OffsetDateTime::from_unix_timestamp(now_unix)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
        .to_offset(local_offset())
        .replace_time(Time::MIDNIGHT)
        .unix_timestamp()
}

fn local_offset() -> time::UtcOffset {
    crate::core::localtime::local_offset()
}

fn recover_interrupted_run(state: &mut PersistedAutoResumeState) -> bool {
    if state.state != "running" {
        return false;
    }
    state.state = "interrupted".into();
    state.message = "上次自动续跑随应用中断，已释放运行状态，可重新续跑".into();
    true
}

fn refresh_idle_status(
    settings: &AutoResumeSettingsSnapshot,
    state: &mut PersistedAutoResumeState,
) {
    if !settings.enabled {
        state.state = "disabled".into();
        state.message = "自动续跑未开启".into();
    } else if settings.thread_id.is_empty() {
        state.state = "needsTarget".into();
        state.message = "请选择要续跑的 Codex 任务".into();
    } else if state.waiting_for_quota {
        state.state = "waitingQuota".into();
        state.message = "额度偏低，已等待额度恢复".into();
    } else if state.state == "disabled" || state.state == "needsTarget" {
        state.state = "armed".into();
        state.message = "自动续跑已就绪".into();
    }
}

fn status_from(state: &RegistryState) -> AutoResumeRuntimeStatus {
    AutoResumeRuntimeStatus {
        state: state.persisted.state.clone(),
        message: state.persisted.message.clone(),
        is_running: state.running,
        waiting_for_quota: state.persisted.waiting_for_quota,
        last_trigger: state.persisted.last_trigger.clone(),
        last_run_at: state.persisted.last_run_at,
        next_scheduled_at: state.persisted.next_scheduled_at,
        runs_today: state.persisted.runs_today,
        revision: state.persisted.revision,
    }
}

fn load_state() -> Result<PersistedAutoResumeState, String> {
    let path = state_path()?;
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| error.to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(PersistedAutoResumeState::default())
        }
        Err(error) => Err(error.to_string()),
    }
}

fn persist_state(state: &PersistedAutoResumeState) -> Result<(), String> {
    let path = state_path()?;
    let bytes = serde_json::to_vec_pretty(state).map_err(|error| error.to_string())?;
    let _writer = AUTO_RESUME_STATE_WRITE_GATE
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Ok(current_bytes) = std::fs::read(&path) {
        if let Ok(current) = serde_json::from_slice::<PersistedAutoResumeState>(&current_bytes) {
            if current.revision > state.revision {
                return Ok(());
            }
        }
    }
    atomic_file::write_atomically(&path, &bytes).map_err(|error| error.to_string())
}

fn state_path() -> Result<PathBuf, String> {
    app_paths::auto_resume_state_path().ok_or_else(|| "无法定位自动续跑状态文件".into())
}

fn bump(state: &mut PersistedAutoResumeState) {
    state.revision = state.revision.saturating_add(1);
}

fn normalize_day(state: &mut PersistedAutoResumeState) {
    let today = local_day_key();
    if state.runs_day != today {
        state.runs_day = today;
        state.runs_today = 0;
    }
}

fn local_day_key() -> String {
    OffsetDateTime::now_utc()
        .to_offset(local_offset())
        .date()
        .to_string()
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn spawn_supervised_task<F, T, R>(
    future: F,
    recover: R,
) -> tokio::sync::oneshot::Receiver<T>
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
    R: FnOnce(String) -> T + Send + 'static,
{
    let (sender, receiver) = tokio::sync::oneshot::channel();
    tauri::async_runtime::spawn(async move {
        let result = match tauri::async_runtime::spawn(future).await {
            Ok(result) => result,
            Err(error) => recover(error.to_string()),
        };
        let _ = sender.send(result);
    });
    receiver
}

fn set_generation(generation: &RwLock<u64>, value: u64) {
    *generation
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = value;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AccountInfo, QuotaAvailability, QuotaSnapshot, ResetCreditSummary};

    #[test]
    fn supervised_task_outlives_its_waiter_and_recovers_panics() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let completed = Arc::new(AtomicBool::new(false));
            let observed = completed.clone();
            let receiver = spawn_supervised_task(
                async move {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    observed.store(true, Ordering::Release);
                    7usize
                },
                |_| 0,
            );
            drop(receiver);
            tokio::time::sleep(Duration::from_millis(50)).await;
            assert!(completed.load(Ordering::Acquire));

            let recovered = Arc::new(AtomicBool::new(false));
            let observed = recovered.clone();
            let receiver = spawn_supervised_task(
                async move {
                    panic!("injected auto-resume task panic");
                },
                move |_| {
                    observed.store(true, Ordering::Release);
                    9usize
                },
            );
            assert_eq!(receiver.await.unwrap(), 9);
            assert!(recovered.load(Ordering::Acquire));
        });
    }

    #[test]
    fn startup_recovers_persisted_running_state_and_started_owner_releases_flag() {
        let mut persisted = PersistedAutoResumeState::default();
        persisted.state = "running".into();
        let before_revision = persisted.revision;
        assert!(recover_interrupted_run(&mut persisted));
        assert_eq!(persisted.state, "interrupted");
        assert!(persisted.message.contains("可重新续跑"));
        assert_eq!(persisted.revision, before_revision);

        let started = Arc::new(AtomicBool::new(true));
        {
            let _owner = BackgroundStartedOwner {
                started: started.clone(),
            };
        }
        assert!(!started.load(Ordering::Acquire));
    }

    #[test]
    fn stale_auto_resume_snapshot_cannot_overwrite_a_newer_revision() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-auto-resume-state-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _environment =
            crate::core::usage::cache_lifecycle::usage_cache_test_state_guard(&[(
                "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
                root.clone(),
            )]);
        let mut newer = PersistedAutoResumeState::default();
        newer.revision = 2;
        newer.message = "newer".into();
        persist_state(&newer).unwrap();

        let mut stale = newer.clone();
        stale.revision = 1;
        stale.message = "stale".into();
        persist_state(&stale).unwrap();

        let loaded = load_state().unwrap();
        assert_eq!(loaded.revision, 2);
        assert_eq!(loaded.message, "newer");
        let _ = std::fs::remove_dir_all(root);
    }

    fn limit(label: &str, remaining: f64, reset: i64) -> QuotaLimit {
        QuotaLimit {
            label: label.into(),
            availability: QuotaAvailability::Measured,
            remaining_percent: Some(remaining),
            used_percent: Some(1.0 - remaining),
            resets_at: String::new(),
            resets_at_unix: Some(reset),
        }
    }

    fn bundle(five: QuotaLimit, seven: QuotaLimit) -> AccountQuotaBundle {
        AccountQuotaBundle {
            account: AccountInfo {
                display_name: String::new(),
                plan_label: String::new(),
            },
            quota: QuotaSnapshot {
                five_hour: five,
                seven_day: seven,
                reset_credit: ResetCreditSummary {
                    available_count: 0,
                    status: String::new(),
                    credits: Vec::new(),
                },
                pace_label: String::new(),
            },
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: Vec::new(),
            diagnostics: Vec::new(),
        }
    }

    fn enabled_settings() -> AutoResumeSettingsSnapshot {
        AutoResumeSettingsSnapshot {
            enabled: true,
            thread_id: "thread".into(),
            ..AutoResumeSettingsSnapshot::default()
        }
    }

    #[test]
    fn first_quota_observation_only_establishes_baseline() {
        let settings = enabled_settings();
        let mut state = PersistedAutoResumeState::default();
        let recovered = observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.80, 200), limit("7d", 0.70, 900)),
        );
        assert!(!recovered);
        assert!(!state.waiting_for_quota);
        assert!(!observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 1.0, 200), limit("7d", 0.80, 900)),
        ));
        assert!(!state.five_hour.armed);
        assert!(!state.seven_day.armed);

        let mut low_state = PersistedAutoResumeState::default();
        assert!(!observe_quota_bundle(
            &settings,
            &mut low_state,
            &bundle(limit("5h", 0.04, 200), limit("7d", 0.03, 900)),
        ));
        assert!(!low_state.five_hour.armed);
        assert!(!low_state.seven_day.armed);
    }

    #[test]
    fn low_quota_arms_and_real_reset_recovers_once() {
        let settings = enabled_settings();
        let mut state = PersistedAutoResumeState::default();
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.04, 200), limit("7d", 0.70, 900)),
        );
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.04, 200), limit("7d", 0.70, 900)),
        );
        assert!(state.five_hour.armed);
        assert!(observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 1.0, 500), limit("7d", 0.69, 900)),
        ));
        assert!(!observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.99, 500), limit("7d", 0.68, 900)),
        ));
    }

    #[test]
    fn either_window_uses_the_window_that_actually_recovered_for_dedupe() {
        let settings = enabled_settings();
        let mut state = PersistedAutoResumeState::default();
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.80, 200), limit("7d", 0.04, 900)),
        );
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.79, 200), limit("7d", 0.04, 900)),
        );
        assert!(state.seven_day.armed);
        assert!(observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.78, 200), limit("7d", 1.0, 1_500)),
        ));
        assert_eq!(
            quota_recovery_key(&settings, &state).as_deref(),
            Some("7d:1500")
        );
    }

    #[test]
    fn lowest_window_waits_until_every_measured_limit_has_recovered() {
        let settings = enabled_settings();
        let mut state = PersistedAutoResumeState::default();
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.80, 200), limit("7d", 0.70, 900)),
        );
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.04, 200), limit("7d", 0.03, 900)),
        );
        assert!(state.five_hour.armed);
        assert!(state.seven_day.armed);

        assert!(observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 1.0, 500), limit("7d", 0.03, 900)),
        ));
        assert!(!selected_quota_recovered(&settings, &state));

        assert!(observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.99, 500), limit("7d", 1.0, 1_500)),
        ));
        assert!(selected_quota_recovered(&settings, &state));
        assert_eq!(
            quota_recovery_key(&settings, &state).as_deref(),
            Some("5h:500"),
            "双窗口同时恢复按跨端契约取 5h 单窗口，而不是拼接"
        );
    }

    #[test]
    fn lowest_window_ignores_a_never_low_window_stuck_below_the_recovery_threshold() {
        let settings = enabled_settings();
        let mut state = PersistedAutoResumeState::default();
        // 7d 长期 0.10：高于低位阈值（0.05）从未武装，但一直低于恢复阈值（0.20）。
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.80, 200), limit("7d", 0.10, 900)),
        );
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.04, 200), limit("7d", 0.10, 900)),
        );
        assert!(state.five_hour.armed);
        assert!(!state.seven_day.armed);

        // 决策口径：只有曾进入低位的窗口需要达到恢复阈值；从未低位的 7d
        // 不得阻塞 5h 重置后的触发（旧实现在此永不触发，可阻塞数天）。
        assert!(observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 1.0, 500), limit("7d", 0.10, 900)),
        ));
        assert!(selected_quota_recovered(&settings, &state));
        assert_eq!(
            quota_recovery_key(&settings, &state).as_deref(),
            Some("5h:500")
        );
    }

    #[test]
    fn stale_high_quota_after_limit_error_does_not_immediately_retrigger() {
        let settings = enabled_settings();
        let mut state = PersistedAutoResumeState::default();
        observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.80, 200), limit("7d", 0.70, 900)),
        );
        arm_selected_windows(&settings, &mut state);
        state.waiting_for_quota = true;
        assert!(!selected_quota_recovered(&settings, &state));
        assert!(!observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.79, 200), limit("7d", 0.69, 900)),
        ));
        assert!(!selected_quota_recovered(&settings, &state));
    }

    #[test]
    fn disabled_quota_observations_never_arm_future_auto_resume() {
        let settings = AutoResumeSettingsSnapshot::default();
        let mut state = PersistedAutoResumeState::default();
        assert!(!observe_quota_bundle(
            &settings,
            &mut state,
            &bundle(limit("5h", 0.02, 200), limit("7d", 0.03, 900)),
        ));
        assert!(!state.five_hour.observed);
        assert!(!state.five_hour.armed);
        assert!(!state.seven_day.observed);
        assert!(!state.seven_day.armed);
    }

    #[test]
    fn interval_schedule_stays_due_until_claimed_then_advances_once() {
        let mut settings = AutoResumeSettingsSnapshot::default();
        settings.enabled = true;
        settings.thread_id = "thread".into();
        settings.schedule_mode = "interval".into();
        settings.interval_minutes = 30;
        let mut state = RegistryState {
            settings,
            ..RegistryState::default()
        };
        state.persisted.next_scheduled_at = initial_next_schedule(&state.settings, 1_000);
        assert!(due_trigger(&mut state, 2_799).is_none());
        assert!(due_trigger(&mut state, 2_800).is_some());
        assert_eq!(state.persisted.next_scheduled_at, Some(2_800));
        advance_schedule_after_trigger(&state.settings, &mut state.persisted, 2_800);
        assert_eq!(state.persisted.next_scheduled_at, Some(4_600));
    }

    #[test]
    fn shared_daily_limit_defers_interval_and_advances_daily_without_retry_loop() {
        let now = 1_780_000_000;
        let mut interval_settings = enabled_settings();
        interval_settings.schedule_mode = "interval".into();
        let mut interval_state = RegistryState {
            settings: interval_settings,
            ..RegistryState::default()
        };
        interval_state.running = true;
        interval_state.persisted.next_scheduled_at = Some(now);
        let interval_trigger = due_trigger(&mut interval_state, now).unwrap();
        let status = settle_daily_limit(&mut interval_state, &interval_trigger, now);
        assert_eq!(status.state, "guarded");
        assert!(!status.is_running);
        assert_eq!(interval_state.persisted.next_scheduled_at, Some(now));
        assert!(interval_state
            .persisted
            .deferred_until
            .is_some_and(|until| until > now));

        let mut daily_settings = enabled_settings();
        daily_settings.schedule_mode = "daily".into();
        let mut daily_state = RegistryState {
            settings: daily_settings,
            ..RegistryState::default()
        };
        daily_state.running = true;
        daily_state.persisted.next_scheduled_at = Some(now);
        let daily_trigger = due_trigger(&mut daily_state, now).unwrap();
        settle_daily_limit(&mut daily_state, &daily_trigger, now);
        assert!(daily_state.persisted.deferred_until.is_none());
        assert!(daily_state
            .persisted
            .next_scheduled_at
            .is_some_and(|next| next > now));
    }

    #[test]
    fn materialized_schedule_trigger_is_stale_after_mode_generation_changes() {
        let mut settings = enabled_settings();
        settings.schedule_mode = "interval".into();
        let mut state = RegistryState {
            settings,
            ..RegistryState::default()
        };
        state.persisted.schedule_generation = 4;
        state.persisted.next_scheduled_at = Some(100);
        let trigger = due_trigger(&mut state, 100).unwrap();
        assert_eq!(trigger.schedule_generation, Some(4));
        assert!(scheduled_trigger_is_current(&state, &trigger));

        state.settings.schedule_mode = "daily".into();
        state.persisted.schedule_generation = 5;
        assert!(!scheduled_trigger_is_current(&state, &trigger));
    }

    #[test]
    fn cooldown_and_daily_limit_are_shared_generation_inputs() {
        let current = enabled_settings();
        let mut changed = current.clone();
        changed.cooldown_minutes = changed.cooldown_minutes.saturating_add(1);
        assert!(automatic_safety_limits_changed(&current, &changed));

        changed = current.clone();
        changed.max_runs_per_day = changed.max_runs_per_day.saturating_sub(1);
        assert!(automatic_safety_limits_changed(&current, &changed));

        changed = current.clone();
        changed.notify_on_result = !changed.notify_on_result;
        assert!(!automatic_safety_limits_changed(&current, &changed));
    }

    #[test]
    fn quota_only_trigger_ignores_schedule_generation_changes() {
        let mut state = RegistryState {
            settings: enabled_settings(),
            ..RegistryState::default()
        };
        state.persisted.schedule_generation = 4;
        state.persisted.quota_generation = 9;
        let trigger = Trigger {
            key: "quota:thread:5h:500".into(),
            label: "额度恢复续跑".into(),
            thread_id: "thread".into(),
            kind: TriggerKind::QuotaRecovery,
            consumes_pending: true,
            freshness_not_before: Some(90),
            schedule_generation: None,
            quota_generation: Some(9),
        };

        state.settings.schedule_mode = "daily".into();
        state.persisted.schedule_generation = 5;
        assert!(automatic_trigger_is_current(&state, &trigger));

        state.settings.quota_window = "fiveHour".into();
        state.persisted.quota_generation = 10;
        assert!(!automatic_trigger_is_current(&state, &trigger));
    }

    #[test]
    fn schedule_waits_instead_of_firing_when_quota_is_low() {
        let mut settings = AutoResumeSettingsSnapshot::default();
        settings.enabled = true;
        settings.thread_id = "thread".into();
        settings.schedule_mode = "interval".into();
        let mut state = RegistryState {
            settings,
            ..RegistryState::default()
        };
        state.persisted.next_scheduled_at = Some(100);
        state.persisted.five_hour.remaining_percent = Some(0.02);
        assert!(due_trigger(&mut state, 100).is_none());
        assert!(state.persisted.waiting_for_quota);
        assert!(state.persisted.pending_trigger_key.is_some());
    }

    #[test]
    fn quota_wait_blocks_a_due_schedule_even_when_generic_pending_has_no_key() {
        let mut settings = enabled_settings();
        settings.schedule_mode = "interval".into();
        let mut state = RegistryState {
            settings,
            ..RegistryState::default()
        };
        state.persisted.next_scheduled_at = Some(100);
        state.persisted.waiting_for_quota = true;
        state.persisted.pending_thread_id = Some("thread".into());
        state.persisted.pending_trigger_kind = Some("quotaRecovery".into());
        state.persisted.five_hour.remaining_percent = Some(0.10);
        assert!(due_trigger(&mut state, 100).is_none());
        assert_eq!(state.persisted.next_scheduled_at, Some(100));
    }

    #[test]
    fn scheduled_recovery_does_not_require_reset_timestamp_or_consume_pending_early() {
        let mut settings = enabled_settings();
        settings.quota_window = "fiveHour".into();
        let mut state = RegistryState {
            settings,
            ..RegistryState::default()
        };
        state.persisted.waiting_for_quota = true;
        state.persisted.pending_trigger_key = Some("interval:thread:30:974222".into());
        state.persisted.pending_trigger_label = Some("定时续跑".into());
        state.persisted.pending_thread_id = Some("thread".into());
        state.persisted.pending_trigger_kind = Some("interval".into());
        state.persisted.pending_armed_at = Some(90);
        state.persisted.schedule_generation = 4;
        state.persisted.pending_schedule_generation = Some(4);
        state.persisted.five_hour.armed = true;
        state.persisted.five_hour.recovery_ready = true;
        state.persisted.five_hour.remaining_percent = Some(1.0);
        state.persisted.five_hour.reset_at = None;

        let trigger = recovered_trigger(&mut state).unwrap();
        assert!(trigger.consumes_pending);
        assert_eq!(trigger.thread_id, "thread");
        assert_eq!(trigger.freshness_not_before, Some(90));
        assert_eq!(trigger.schedule_generation, Some(4));
        assert_eq!(trigger.quota_generation, None);
        assert_eq!(
            trigger.key, "interval:thread:30:974222",
            "挂起的排程触发必须用槽位 key 原样去重，不得再拼接恢复后缀"
        );
        assert_eq!(
            state.persisted.pending_trigger_key.as_deref(),
            Some("interval:thread:30:974222")
        );
        assert!(state.persisted.waiting_for_quota);
    }

    #[test]
    fn quota_recovery_trigger_carries_only_quota_generation() {
        let mut settings = enabled_settings();
        settings.quota_window = "fiveHour".into();
        let mut state = RegistryState {
            settings,
            ..RegistryState::default()
        };
        state.persisted.waiting_for_quota = true;
        state.persisted.pending_thread_id = Some("thread".into());
        state.persisted.pending_trigger_kind = Some("quotaRecovery".into());
        state.persisted.pending_armed_at = Some(90);
        state.persisted.schedule_generation = 4;
        state.persisted.quota_generation = 9;
        state.persisted.five_hour.armed = true;
        state.persisted.five_hour.recovery_ready = true;
        state.persisted.five_hour.remaining_percent = Some(1.0);
        state.persisted.five_hour.reset_at = Some(500);

        let trigger = recovered_trigger(&mut state).unwrap();
        assert_eq!(trigger.schedule_generation, None);
        assert_eq!(trigger.quota_generation, Some(9));
        assert_eq!(
            trigger.key, "quota:thread:5h:500",
            "纯额度恢复必须用跨端统一的 quota:{{线程}}:{{窗口}}:{{reset}} key"
        );
        assert!(automatic_trigger_is_current(&state, &trigger));
    }

    #[test]
    fn cross_runtime_trigger_keys_match_the_swift_contract() {
        // 与 Swift 端 AutoResumePolicyTests.testTriggerKeysMatchTheCrossRuntimeContract
        // 互为镜像：同一触发两端必须产出逐字节相同的 key，共享 ledger 的精确
        // 匹配去重才能生效。任何一端改动 key 格式都必须同步另一端与两份测试。
        assert_eq!(
            daily_trigger_key("thread-1", "2026-07-27", 9, 5),
            "daily:thread-1:2026-07-27:0905"
        );
        assert_eq!(
            interval_trigger_key("thread-1", 30, 1_753_600_000),
            "interval:thread-1:30:974222"
        );
        assert_eq!(
            quota_trigger_key("thread-1", "5h:1753602000"),
            "quota:thread-1:5h:1753602000"
        );
        // capacity 触发目前仅 Swift 端产生（capacity:{线程}:{turnId}）；
        // manual 触发不参与跨端去重，仅约定 manual: 前缀共享每日上限豁免。
    }

    #[test]
    fn recovery_pending_for_an_old_target_is_cancelled() {
        let mut settings = enabled_settings();
        settings.thread_id = "thread-b".into();
        settings.quota_window = "fiveHour".into();
        let mut state = RegistryState {
            settings,
            ..RegistryState::default()
        };
        state.persisted.waiting_for_quota = true;
        state.persisted.pending_thread_id = Some("thread-a".into());
        state.persisted.pending_trigger_kind = Some("quotaRecovery".into());
        state.persisted.five_hour.armed = true;
        state.persisted.five_hour.recovery_ready = true;
        state.persisted.five_hour.remaining_percent = Some(1.0);
        state.persisted.five_hour.reset_at = Some(500);

        assert!(recovered_trigger(&mut state).is_none());
        assert!(!state.persisted.waiting_for_quota);
        assert!(state.persisted.pending_thread_id.is_none());
    }
}
