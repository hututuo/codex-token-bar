use crate::commands::local_source;
use crate::core::dashboard::DashboardDataSource;
use crate::core::startup_trace;
use crate::core::usage::cache_lifecycle::{self, UsageCacheStatus};
use crate::core::usage::token_count_jsonl::{self, TokenUsageSummary};
use super::window_auth::require_window_label;
use crate::models::{
    AccountQuotaBundle, CodexHomeStatus, DashboardSnapshot, PlatformCapabilities,
};
use crate::platform;
use serde::Serialize;
use std::fmt::Display;
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;
use tauri::{async_runtime, Emitter};

const CODEX_HOME_SOURCE_CHANGED_EVENT: &str = "codex-home-source-changed";

static CODEX_HOME_TRANSITION_STATE: OnceLock<Mutex<CodexHomeTransitionState>> = OnceLock::new();

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeSourceEnvelope {
    pub codex_home: CodexHomeStatus,
    pub canonical_home_key: String,
    pub transition_generation: u64,
}

#[derive(Default)]
struct CodexHomeTransitionState {
    canonical_home_key: Option<String>,
    transition_generation: u64,
}

async fn run_blocking_command<T, F>(work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub fn get_codex_home(window: tauri::WebviewWindow) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "get_codex_home")?;
    startup_trace::mark("command get_codex_home start");
    let result = with_codex_home_transition_state(|transition| {
        Ok(resolve_codex_home_source(
            transition,
            platform::default_codex_home_status(),
        ))
    });
    startup_trace::mark("command get_codex_home end");
    result
}

#[tauri::command]
pub fn set_codex_home(
    window: tauri::WebviewWindow,
    path: String,
) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "set_codex_home")?;
    persist_codex_home_transition(window, || platform::save_codex_home(&path))
}

#[tauri::command]
pub fn reset_codex_home(window: tauri::WebviewWindow) -> Result<CodexHomeSourceEnvelope, String> {
    require_window_label(&window, "reset_codex_home")?;
    persist_codex_home_transition(window, platform::reset_codex_home)
}

fn persist_codex_home_transition(
    window: tauri::WebviewWindow,
    save: impl FnOnce() -> Result<CodexHomeStatus, String>,
) -> Result<CodexHomeSourceEnvelope, String> {
    with_codex_home_transition_state(|transition| {
        commit_codex_home_transition(transition, save, |envelope| {
            window
                .emit_str(
                    CODEX_HOME_SOURCE_CHANGED_EVENT,
                    serde_json::to_string(envelope).map_err(|error| error.to_string())?,
                )
                .map_err(|error| error.to_string())
        })
    })
}

fn with_codex_home_transition_state<T>(
    operation: impl FnOnce(&mut CodexHomeTransitionState) -> Result<T, String>,
) -> Result<T, String> {
    let state =
        CODEX_HOME_TRANSITION_STATE.get_or_init(|| Mutex::new(CodexHomeTransitionState::default()));
    let mut state = state
        .lock()
        .map_err(|_| "Codex Home source transition lock was poisoned".to_string())?;
    operation(&mut state)
}

fn commit_codex_home_transition<E>(
    transition: &mut CodexHomeTransitionState,
    save: impl FnOnce() -> Result<CodexHomeStatus, String>,
    publish: impl FnOnce(&CodexHomeSourceEnvelope) -> Result<(), E>,
) -> Result<CodexHomeSourceEnvelope, String>
where
    E: Display,
{
    let codex_home = save()?;
    let envelope = resolve_codex_home_source(transition, codex_home);
    if let Err(error) = publish(&envelope) {
        startup_trace::mark_performance(format!(
            "codex home source event publish failed generation={} error={error}",
            envelope.transition_generation
        ));
    }
    Ok(envelope)
}

fn resolve_codex_home_source(
    transition: &mut CodexHomeTransitionState,
    codex_home: CodexHomeStatus,
) -> CodexHomeSourceEnvelope {
    let canonical_home_key = canonical_home_key(Path::new(&codex_home.path));
    if transition.canonical_home_key.as_deref() != Some(&canonical_home_key) {
        transition.transition_generation = transition.transition_generation.saturating_add(1);
        transition.canonical_home_key = Some(canonical_home_key.clone());
    }

    CodexHomeSourceEnvelope {
        codex_home,
        canonical_home_key,
        transition_generation: transition.transition_generation,
    }
}

fn canonical_home_key(path: &Path) -> String {
    let resolved = std::fs::canonicalize(path).unwrap_or_else(|_| lexical_absolute_path(path));
    platform_path_key(&resolved)
}

fn lexical_absolute_path(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

#[cfg(windows)]
fn platform_path_key(path: &Path) -> String {
    let raw = path.to_string_lossy().replace('\\', "/");
    let without_verbatim_prefix = raw
        .strip_prefix("//?/UNC/")
        .map(|rest| format!("//{rest}"))
        .or_else(|| raw.strip_prefix("//?/").map(str::to_string))
        .unwrap_or(raw);
    without_verbatim_prefix.to_lowercase()
}

#[cfg(not(windows))]
fn platform_path_key(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[tauri::command]
pub fn read_platform_capabilities() -> Result<PlatformCapabilities, String> {
    startup_trace::mark("command read_platform_capabilities start");
    let result = platform::platform_capabilities();
    startup_trace::mark("command read_platform_capabilities end");
    Ok(result)
}

#[tauri::command]
pub async fn read_dashboard_snapshot(
    window: tauri::WebviewWindow,
) -> Result<DashboardSnapshot, String> {
    require_window_label(&window, "read_dashboard_snapshot")?;
    startup_trace::mark("command read_dashboard_snapshot start");
    let started = Instant::now();
    let result = run_blocking_command(|| local_source().read_dashboard_snapshot()).await;
    startup_trace::mark_performance(format!(
        "read_dashboard_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    startup_trace::mark("command read_dashboard_snapshot end");
    result
}

#[tauri::command]
pub async fn read_precise_dashboard_snapshot(
    window: tauri::WebviewWindow,
) -> Result<DashboardSnapshot, String> {
    require_window_label(&window, "read_precise_dashboard_snapshot")?;
    let started = Instant::now();
    let result = run_blocking_command(|| local_source().read_precise_dashboard_snapshot()).await;
    startup_trace::mark_performance(format!(
        "read_precise_dashboard_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub async fn read_usage_summary_snapshot() -> Result<TokenUsageSummary, String> {
    let started = Instant::now();
    let codex_home = platform::default_codex_home();
    let result = run_blocking_command(move || {
        token_count_jsonl::usage_summary_snapshot(&codex_home)
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_usage_summary_snapshot {}ms {}",
        started.elapsed().as_millis(),
        result_status(&result)
    ));
    result
}

#[tauri::command]
pub fn read_usage_cache_status(window: tauri::WebviewWindow) -> Result<UsageCacheStatus, String> {
    require_window_label(&window, "read_usage_cache_status")?;
    Ok(cache_lifecycle::usage_cache_status())
}

#[tauri::command]
pub async fn read_account_quota(force_refresh: Option<bool>) -> Result<AccountQuotaBundle, String> {
    startup_trace::mark_once("command read_account_quota start");
    let started = Instant::now();
    let forced = force_refresh.unwrap_or(false);
    let result = run_blocking_command(move || {
        local_source().read_account_quota(forced)
    })
    .await;
    startup_trace::mark_performance(format!(
        "read_account_quota force={} {}ms {}",
        forced,
        started.elapsed().as_millis(),
        account_quota_result_status(&result)
    ));
    startup_trace::mark_once("command read_account_quota end");
    result
}

fn result_status<T>(result: &Result<T, String>) -> &'static str {
    if result.is_ok() {
        "ok"
    } else {
        "error"
    }
}

fn account_quota_result_status(result: &Result<AccountQuotaBundle, String>) -> String {
    match result {
        Err(error) => format!("error {}", compact_trace_text(error)),
        Ok(bundle) => {
            let quota_available = bundle.quota.five_hour.resets_at_unix.is_some()
                || bundle.quota.seven_day.resets_at_unix.is_some();
            let status = if quota_available {
                "quota_success"
            } else {
                "quota_placeholder"
            };
            if bundle.warnings.is_empty() && bundle.diagnostics.is_empty() {
                status.to_string()
            } else {
                let warnings = bundle
                    .warnings
                    .iter()
                    .map(|warning| {
                        format!(
                            "{}:{}",
                            warning.source,
                            compact_trace_text(&warning.message)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("|");
                let diagnostics = bundle
                    .diagnostics
                    .iter()
                    .map(|diagnostic| {
                        format!(
                            "{}:{}:{}",
                            diagnostic.source,
                            diagnostic.category,
                            compact_trace_text(
                                diagnostic
                                    .raw_cause
                                    .as_deref()
                                    .unwrap_or(&diagnostic.message)
                            )
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("|");
                match (warnings.is_empty(), diagnostics.is_empty()) {
                    (false, false) => format!("{status} warnings=[{warnings}] diagnostics=[{diagnostics}]"),
                    (false, true) => format!("{status} warnings=[{warnings}]"),
                    (true, false) => format!("{status} diagnostics=[{diagnostics}]"),
                    (true, true) => status.to_string(),
                }
            }
        }
    }
}

fn compact_trace_text(text: &str) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= 1200 {
        compact
    } else {
        let mut truncated = compact.chars().take(1200).collect::<String>();
        truncated.push('…');
        truncated
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{
        AccountInfo, AccountQuotaBundle, QuotaLimit, QuotaSnapshot, ResetCreditSummary,
    };
    use std::cell::{Cell, RefCell};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static SOURCE_TEST_PATH_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn codex_home_transition_publishes_canonical_envelope_after_durable_save() {
        let home = disposable_source_test_directory("publish-order");
        let order = RefCell::new(Vec::new());
        let mut transition = CodexHomeTransitionState::default();

        let envelope = commit_codex_home_transition(
            &mut transition,
            || {
                order.borrow_mut().push("save");
                Ok(codex_home_status_for_test(home.join("."), "manual"))
            },
            |published| {
                order.borrow_mut().push("publish");
                assert_eq!(
                    published.codex_home.path,
                    home.join(".").display().to_string()
                );
                assert_eq!(published.canonical_home_key, canonical_home_key(&home));
                assert_eq!(published.transition_generation, 1);
                Ok::<(), String>(())
            },
        )
        .expect("durable save should return its exact envelope");

        assert_eq!(order.into_inner(), vec!["save", "publish"]);
        assert_eq!(envelope.canonical_home_key, canonical_home_key(&home));
        remove_source_test_directory(home);
    }

    #[test]
    fn codex_home_transition_does_not_publish_when_durable_save_fails() {
        let published = Cell::new(false);
        let mut transition = CodexHomeTransitionState::default();

        let result = commit_codex_home_transition(
            &mut transition,
            || Err("injected durable save failure".into()),
            |_| {
                published.set(true);
                Ok::<(), String>(())
            },
        );

        assert_eq!(result.unwrap_err(), "injected durable save failure");
        assert!(!published.get());
        assert_eq!(transition.transition_generation, 0);
        assert_eq!(transition.canonical_home_key, None);
    }

    #[test]
    fn codex_home_transition_generation_advances_only_for_canonical_source_changes() {
        let home_a = disposable_source_test_directory("source-a");
        let home_auto = disposable_source_test_directory("source-auto");
        let home_b = disposable_source_test_directory("source-b");
        let mut transition = CodexHomeTransitionState::default();

        let a = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_a.clone(), "manual"),
        );
        let a_duplicate = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_a.join("."), "manual"),
        );
        let a_same_resolved_source = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_a.clone(), "auto"),
        );
        let auto = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_auto.clone(), "auto"),
        );
        let auto_duplicate = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_auto.join("."), "auto"),
        );
        let b = resolve_codex_home_source(
            &mut transition,
            codex_home_status_for_test(home_b.clone(), "manual"),
        );

        assert_eq!(a.transition_generation, 1);
        assert_eq!(a_duplicate.transition_generation, 1);
        assert_eq!(a_same_resolved_source.transition_generation, 1);
        assert_eq!(auto.transition_generation, 2);
        assert_eq!(auto_duplicate.transition_generation, 2);
        assert_eq!(b.transition_generation, 3);
        assert_eq!(a.canonical_home_key, a_duplicate.canonical_home_key);
        assert_eq!(
            a.canonical_home_key,
            a_same_resolved_source.canonical_home_key
        );

        remove_source_test_directory(home_a);
        remove_source_test_directory(home_auto);
        remove_source_test_directory(home_b);
    }

    #[test]
    fn account_quota_trace_status_distinguishes_placeholder_bundle_from_real_quota() {
        let mut quota = placeholder_quota_for_test();
        quota.pace_label = "额度读取失败".into();
        let placeholder = Ok(AccountQuotaBundle {
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota,
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: vec![],
            diagnostics: Vec::new(),
        });

        assert_eq!(account_quota_result_status(&placeholder), "quota_placeholder");
    }

    #[test]
    fn account_quota_trace_keeps_full_retry_diagnostics() {
        let long_warning = format!(
            "额度读取失败：网络连接失败：{}",
            "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)；".repeat(8)
        );
        let placeholder = Ok(AccountQuotaBundle {
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota: placeholder_quota_for_test(),
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: vec![crate::models::LocalDataWarning {
                source: "account_quota".into(),
                message: long_warning,
            }],
            diagnostics: vec![crate::models::QuotaDiagnostic {
                source: "account_quota".into(),
                category: "network_send_fetch".into(),
                severity: "warning".into(),
                message: "网络连接失败".into(),
                raw_cause: Some("failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)；".repeat(8)),
                underlying_category: None,
                attempts: Some(3),
                http_status: None,
                retryable: true,
                occurred_at: "2026-07-06T00:00:00Z".into(),
                stale_data_displayed: false,
            }],
        });

        let status = account_quota_result_status(&placeholder);
        assert!(status.contains("quota_placeholder warnings=[account_quota:"));
        assert!(status.contains("diagnostics=[account_quota:network_send_fetch:"));
        assert!(status.contains("backend-api/wham/usage"));
        assert!(!status.contains('…'));
    }

    fn placeholder_quota_for_test() -> QuotaSnapshot {
        QuotaSnapshot {
            five_hour: QuotaLimit {
                label: "5h".into(),
                availability: crate::models::QuotaAvailability::Unavailable,
                used_percent: None,
                remaining_percent: None,
                resets_at: "待读取".into(),
                resets_at_unix: None,
            },
            seven_day: QuotaLimit {
                label: "7d".into(),
                availability: crate::models::QuotaAvailability::Unavailable,
                used_percent: None,
                remaining_percent: None,
                resets_at: "待读取".into(),
                resets_at_unix: None,
            },
            pace_label: "待读取".into(),
            reset_credit: ResetCreditSummary {
                available_count: 0,
                status: "重置卡待读取".into(),
                credits: Vec::new(),
            },
        }
    }

    fn codex_home_status_for_test(path: PathBuf, source: &str) -> CodexHomeStatus {
        CodexHomeStatus {
            path: path.display().to_string(),
            exists: true,
            source: source.into(),
        }
    }

    fn disposable_source_test_directory(label: &str) -> PathBuf {
        let sequence = SOURCE_TEST_PATH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "codex-token-bar-source-transition-{}-{}-{sequence}",
            std::process::id(),
            label,
        ));
        std::fs::create_dir_all(&path).expect("create disposable source transition directory");
        path
    }

    fn remove_source_test_directory(path: PathBuf) {
        std::fs::remove_dir_all(path).expect("remove disposable source transition directory");
    }
}
