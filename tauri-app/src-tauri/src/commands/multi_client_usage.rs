use super::run_blocking_command;
use crate::core::multi_client_usage::{
    self, ClaudeLocalQuotaSnapshot, MultiClientUsagePreference, MultiClientUsageSnapshot,
};
use std::{
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

static LAST_MULTI_CLIENT_SCAN: OnceLock<Mutex<Option<Instant>>> = OnceLock::new();

#[tauri::command]
pub(crate) async fn read_multi_client_usage_snapshot() -> Result<MultiClientUsageSnapshot, String> {
    run_blocking_command(multi_client_usage::read_multi_client_usage_snapshot).await
}

#[tauri::command]
pub(crate) async fn save_multi_client_usage_preferences(
    preferences: Vec<MultiClientUsagePreference>,
) -> Result<Vec<MultiClientUsagePreference>, String> {
    let result = run_blocking_command(move || {
        multi_client_usage::save_multi_client_usage_preferences(preferences)
    })
    .await?;
    if let Ok(mut last) = multi_client_scan_clock().lock() {
        *last = None;
    }
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
    let snapshot = if should_scan {
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
    let preferences = snapshot.preferences.clone();
    let summaries = snapshot.summaries.clone();
    run_blocking_command(move || {
        let lines = multi_client_usage::configured_menu_bar_usage_lines(&preferences, &summaries);
        crate::platform::set_multi_client_usage_tray_lines(&app, lines).map(|_| ())
    })
    .await?;
    Ok(snapshot)
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

#[tauri::command]
pub(crate) async fn read_claude_local_quota() -> Result<ClaudeLocalQuotaSnapshot, String> {
    run_blocking_command(|| Ok(multi_client_usage::read_claude_local_quota())).await
}
