use super::run_blocking_command;
use crate::core::multi_client_usage::{
    self, ClaudeLocalQuotaSnapshot, MultiClientCacheRankingProjection,
    MultiClientUsagePreference, MultiClientUsageSnapshot,
};
use std::{
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

static LAST_MULTI_CLIENT_SCAN: OnceLock<Mutex<Option<Instant>>> = OnceLock::new();
static RECENT_CLAUDE_SCAN_DIAGNOSTICS: OnceLock<RecentClaudeScanDiagnostics> = OnceLock::new();

/// A background refresh may run while every WebView is hidden. Keep only its
/// bounded Claude scan diagnostics so the next UI-facing read can surface them.
/// Each completed scan replaces this snapshot; a clean scan clears old notices.
#[derive(Default)]
struct RecentClaudeScanDiagnostics {
    lines: Mutex<Vec<String>>,
}

impl RecentClaudeScanDiagnostics {
    fn replace_from(&self, diagnostics: &[String]) {
        let mut latest = diagnostics
            .iter()
            .filter(|line| is_claude_scan_diagnostic(line))
            .map(|line| line.chars().take(512).collect::<String>())
            .collect::<Vec<_>>();
        latest.sort();
        latest.dedup();
        latest.truncate(128);
        if let Ok(mut stored) = self.lines.lock() {
            *stored = latest;
        }
    }

    fn append_to(&self, snapshot: &mut MultiClientUsageSnapshot) {
        let Ok(stored) = self.lines.lock() else { return };
        snapshot.diagnostics.extend(stored.iter().cloned());
        snapshot.diagnostics.sort();
        snapshot.diagnostics.dedup();
    }
}

fn is_claude_scan_diagnostic(line: &str) -> bool {
    line.starts_with("claudeCode:")
        || line.starts_with("claudeDesktop:")
        || line.starts_with("Claude：")
}

fn recent_claude_scan_diagnostics() -> &'static RecentClaudeScanDiagnostics {
    RECENT_CLAUDE_SCAN_DIAGNOSTICS.get_or_init(RecentClaudeScanDiagnostics::default)
}

#[tauri::command]
pub(crate) async fn read_multi_client_usage_snapshot() -> Result<MultiClientUsageSnapshot, String> {
    let mut snapshot = run_blocking_command(multi_client_usage::read_multi_client_usage_snapshot).await?;
    recent_claude_scan_diagnostics().append_to(&mut snapshot);
    Ok(snapshot)
}

#[tauri::command]
pub(crate) async fn read_multi_client_cache_rankings(
    window: tauri::WebviewWindow,
    client: String,
    limit: u32,
) -> Result<MultiClientCacheRankingProjection, String> {
    super::window_auth::require_window_label(&window, "read_multi_client_cache_rankings")?;
    run_blocking_command(move || multi_client_usage::read_multi_client_cache_rankings(&client, limit)).await
}

#[tauri::command]
pub(crate) async fn save_multi_client_usage_preferences(
    preferences: Vec<MultiClientUsagePreference>,
    app: tauri::AppHandle,
    runtime: tauri::State<'_, crate::core::claude_local_runtime::ClaudeLocalRuntimeRegistry>,
) -> Result<Vec<MultiClientUsagePreference>, String> {
    let runtime = runtime.inner().clone();
    let result = run_blocking_command(move || {
        let saved = multi_client_usage::save_multi_client_usage_preferences(preferences)?;
        runtime.reconcile_preferences(&saved);
        Ok(saved)
    })
    .await?;
    if let Ok(mut last) = multi_client_scan_clock().lock() {
        *last = None;
    }
    recent_claude_scan_diagnostics().replace_from(&[]);
    #[cfg(windows)]
    {
        // Restart only an already opted-in reporter whose effective roots changed.
        if let Ok(reporting) = run_blocking_command(|| crate::platform::read_app_settings().map(|s| s.agent_speed_reporting)).await {
            if reporting.enabled {
                use tauri::Manager as _;
                if let Some(registry) = app.try_state::<crate::core::agent_speed_reporting::AgentSpeedReportingRegistry>() {
                    let _ = registry.start(&app, &reporting, false).await;
                }
            }
        }
    }
    #[cfg(not(windows))]
    let _ = app;
    Ok(result)
}

#[tauri::command]
pub(crate) async fn refresh_multi_client_usage(
    app: tauri::AppHandle,
) -> Result<MultiClientUsageSnapshot, String> {
    refresh_and_publish(app).await
}

/// One app-owned scheduler serves every WebView. Backend cooldown also collapses calls across
/// multiple visible windows into a single history scan per minute.
pub(crate) fn initialize_background_refresh(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            let _ = refresh_and_publish(app.clone()).await;
        }
    });
}

async fn refresh_and_publish(app: tauri::AppHandle) -> Result<MultiClientUsageSnapshot, String> {
    let should_scan = claim_multi_client_scan();
    let mut snapshot = if should_scan {
        match run_blocking_command(multi_client_usage::refresh_multi_client_usage).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                release_multi_client_scan();
                return Err(error);
            }
        }
    } else {
        run_blocking_command(multi_client_usage::read_multi_client_usage_snapshot).await?
    };
    if should_scan {
        // A completed scan is authoritative, including an empty diagnostic set
        // which clears resolved warnings retained from an earlier background run.
        recent_claude_scan_diagnostics().replace_from(&snapshot.diagnostics);
    }
    recent_claude_scan_diagnostics().append_to(&mut snapshot);
    run_blocking_command(move || {
        // The scan's usage gate has been released. Persist quota observations
        // here too, so the app-owned background loop records with WebViews hidden.
        let mut snapshot = snapshot;
        multi_client_usage::capture_local_client_quota_history(&mut snapshot.quotas);
        let lines = multi_client_usage::configured_menu_bar_usage_lines(&snapshot.preferences, &snapshot.summaries);
        crate::platform::set_multi_client_usage_tray_lines(&app, lines)?;
        Ok(snapshot)
    })
    .await
}

fn multi_client_scan_clock() -> &'static Mutex<Option<Instant>> {
    LAST_MULTI_CLIENT_SCAN.get_or_init(|| Mutex::new(None))
}

fn claim_multi_client_scan() -> bool {
    let Ok(mut last) = multi_client_scan_clock().lock() else {
        return false;
    };
    let now = Instant::now();
    if last.is_some_and(|last| now.duration_since(last) < Duration::from_secs(60)) {
        false
    } else {
        *last = Some(now);
        true
    }
}

fn release_multi_client_scan() {
    if let Ok(mut last) = multi_client_scan_clock().lock() {
        *last = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(diagnostics: Vec<String>) -> MultiClientUsageSnapshot {
        MultiClientUsageSnapshot {
            preferences: Vec::new(),
            summaries: Vec::new(),
            today_summaries: Vec::new(),
            seven_day_summaries: Vec::new(),
            detections: Vec::new(),
            trend_buckets: Vec::new(),
            daily_buckets: Vec::new(),
            quotas: Vec::new(),
            diagnostics,
            updated_at: None,
        }
    }

    #[test]
    fn background_claude_diagnostics_reach_reads_and_clean_scan_clears_them() {
        let recent = RecentClaudeScanDiagnostics::default();
        recent.replace_from(&[
            "claudeCode: 分类未完成".to_owned(),
            "deepseek: 无法读取日志".to_owned(),
            "claudeDesktop: 已有另一客户端 checkpoint".to_owned(),
        ]);

        let mut read = snapshot(vec!["设置文件读取失败".to_owned()]);
        recent.append_to(&mut read);
        assert!(read.diagnostics.contains(&"claudeCode: 分类未完成".to_owned()));
        assert!(read.diagnostics.contains(&"claudeDesktop: 已有另一客户端 checkpoint".to_owned()));
        assert!(!read.diagnostics.contains(&"deepseek: 无法读取日志".to_owned()));

        // A later successful scan with no Claude warnings replaces the cache;
        // subsequent cooldown reads do not keep showing a resolved issue.
        recent.replace_from(&[]);
        let mut after_clean_scan = snapshot(Vec::new());
        recent.append_to(&mut after_clean_scan);
        assert!(after_clean_scan.diagnostics.is_empty());
    }

    #[test]
    fn recent_claude_diagnostics_are_deduplicated_and_bounded() {
        let recent = RecentClaudeScanDiagnostics::default();
        let repeated = "claudeCode: same warning".to_owned();
        let mut inputs = vec![repeated.clone(), repeated.clone()];
        inputs.extend((0..200).map(|index| format!("claudeDesktop: warning {index}")));
        recent.replace_from(&inputs);

        let mut read = snapshot(Vec::new());
        recent.append_to(&mut read);
        assert_eq!(read.diagnostics.len(), 128);
        assert!(read.diagnostics.windows(2).all(|pair| pair[0] <= pair[1]));
        assert_eq!(
            read.diagnostics
                .iter()
                .filter(|line| line.as_str() == repeated.as_str())
                .count(),
            1
        );
    }
}

#[tauri::command]
pub(crate) async fn read_claude_local_quota() -> Result<ClaudeLocalQuotaSnapshot, String> {
    run_blocking_command(|| Ok(multi_client_usage::read_claude_local_quota())).await
}

#[tauri::command]
pub(crate) async fn read_claude_desktop_quota() -> Result<ClaudeLocalQuotaSnapshot, String> {
    run_blocking_command(|| Ok(multi_client_usage::read_claude_desktop_quota())).await
}

#[tauri::command]
pub(crate) async fn read_local_client_quotas(force_refresh: Option<bool>, automatic_refresh: Option<bool>) -> Result<Vec<crate::core::multi_client_product::QuotaProviderSnapshot>, String> {
    run_blocking_command(move || Ok(if force_refresh.unwrap_or(false) {
        multi_client_usage::refresh_local_client_quotas()
    } else if automatic_refresh.unwrap_or(false) {
        multi_client_usage::automatically_refresh_local_client_quotas()
    } else {
        multi_client_usage::read_local_client_quotas()
    })).await
}
