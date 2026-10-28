use super::run_blocking_command;
use super::window_auth::require_window_label;
use crate::core::agent_speed_reporting::{
    AgentSpeedDisplaySnapshot, AgentSpeedReportingRegistry, AgentSpeedReportingStatus,
};
use crate::models::{
    AgentSpeedReportingSettingsSnapshot, AgentSpeedReportingTransport, SpeedColorGrouping,
    SpeedDisplayMode, SpeedDisplayPreferencesSnapshot,
};
use crate::platform;
use tauri::Emitter as _;

fn local_display_enabled(_settings: &crate::models::AppSettingsSnapshot) -> bool {
    false // Scoped local runtime owns display collection.
}

#[tauri::command]
pub async fn read_speed_display_preferences(
    window: tauri::WebviewWindow,
) -> Result<SpeedDisplayPreferencesSnapshot, String> {
    require_window_label(&window, "read_speed_display_preferences")?;
    let settings = run_blocking_command(platform::read_app_settings).await?;
    Ok(SpeedDisplayPreferencesSnapshot {
        mode: settings.speed_display_mode,
        grouping: settings.speed_color_grouping,
    })
}

#[tauri::command]
pub async fn set_speed_display_preferences(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, AgentSpeedReportingRegistry>,
    mode: String,
    grouping: String,
) -> Result<SpeedDisplayPreferencesSnapshot, String> {
    require_window_label(&window, "set_speed_display_preferences")?;
    let mode = SpeedDisplayMode::parse(&mode)
        .ok_or_else(|| "Speed display mode must be activity or agentSpeed.".to_owned())?;
    let grouping = SpeedColorGrouping::parse(&grouping)
        .ok_or_else(|| "Speed color grouping must be model or client.".to_owned())?;
    let saved = run_blocking_command(move || platform::save_speed_display_preferences(mode, grouping)).await?;
    let prefs = SpeedDisplayPreferencesSnapshot {
        mode: saved.speed_display_mode,
        grouping: saved.speed_color_grouping,
    };
    let registry = registry.inner().clone();
    if let Err(error) = registry
        .start(&app, &saved.agent_speed_reporting, local_display_enabled(&saved))
        .await
    {
        eprintln!("Codex Token Bar: Agent Speed display collector could not synchronize: {error}");
    }
    let _ = app.emit("activity-speed-mode-changed", &saved.display_surfaces.speed_display_mode);
    if let Err(error) = app.emit("speed-display-preferences-changed", &prefs) {
        eprintln!("Codex Token Bar: saved speed display preferences but event delivery failed: {error}");
    }
    Ok(prefs)
}

#[tauri::command]
pub async fn read_agent_speed_display_snapshot(
    window: tauri::WebviewWindow,
    registry: tauri::State<'_, AgentSpeedReportingRegistry>,
) -> Result<AgentSpeedDisplaySnapshot, String> {
    require_window_label(&window, "read_agent_speed_display_snapshot")?;
    Ok(registry.read_display_snapshot())
}

#[tauri::command]
pub async fn read_agent_speed_reporting_status(
    window: tauri::WebviewWindow,
    registry: tauri::State<'_, AgentSpeedReportingRegistry>,
) -> Result<AgentSpeedReportingStatus, String> {
    require_window_label(&window, "read_agent_speed_reporting_status")?;
    let settings = run_blocking_command(platform::read_app_settings).await?;
    Ok(registry.read_status(&settings.agent_speed_reporting))
}

#[tauri::command]
pub async fn set_agent_speed_reporting_enabled(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, AgentSpeedReportingRegistry>,
    enabled: bool,
    username: Option<String>,
) -> Result<AgentSpeedReportingStatus, String> {
    require_window_label(&window, "set_agent_speed_reporting_enabled")?;

    #[cfg(not(windows))]
    if enabled {
        return Err("Agent Speed reporting is available on Windows only.".into());
    }

    let registry = registry.inner().clone();
    if !enabled
        && run_blocking_command(platform::read_app_settings)
            .await?
            .agent_speed_reporting
            .enabled
    {
        // Stop report traffic before persisting the opt-out; start() below reopens the same
        // helper in local-only mode when the local display still needs it.
        registry.stop().await?;
    }
    let saved = run_blocking_command(move || {
        let mut reporting = platform::read_app_settings()?.agent_speed_reporting;
        apply_username(&mut reporting, enabled, username)?;
        reporting.enabled = enabled;
        if enabled {
            reporting.invitation_handled = true;
        }
        if reporting.username.trim().is_empty() {
            reporting.ensure_random_username();
        }
        platform::save_agent_speed_reporting_settings(reporting)
    })
    .await?;
    let local_display = local_display_enabled(&saved);
    let settings = saved.agent_speed_reporting;

    if let Err(error) = registry.start(&app, &settings, local_display).await {
        eprintln!("Codex Token Bar: Agent Speed reporter could not start: {error}");
    }

    Ok(registry.read_status(&settings))
}

#[tauri::command]
pub async fn set_agent_speed_reporting_transport(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    registry: tauri::State<'_, AgentSpeedReportingRegistry>,
    transport: String,
) -> Result<AgentSpeedReportingStatus, String> {
    require_window_label(&window, "set_agent_speed_reporting_transport")?;
    let transport = AgentSpeedReportingTransport::parse(&transport)
        .ok_or_else(|| "Agent Speed transport must be http or websocket.".to_owned())?;
    let registry = registry.inner().clone();

    let current = run_blocking_command(platform::read_app_settings)
        .await?
        .agent_speed_reporting;
    if current.transport != transport && current.enabled {
        // Drop pending reports before switching transports; the next run starts from a new baseline.
        registry.stop().await?;
    }

    let saved = run_blocking_command(move || {
        let mut reporting = platform::read_app_settings()?.agent_speed_reporting;
        reporting.transport = transport;
        platform::save_agent_speed_reporting_settings(reporting)
    })
    .await?;
    let local_display = local_display_enabled(&saved);
    let settings = saved.agent_speed_reporting;

    if let Err(error) = registry.start(&app, &settings, local_display).await {
        eprintln!("Codex Token Bar: Agent Speed reporter could not start: {error}");
    }

    Ok(registry.read_status(&settings))
}

#[tauri::command]
pub async fn dismiss_agent_speed_invitation(
    window: tauri::WebviewWindow,
    registry: tauri::State<'_, AgentSpeedReportingRegistry>,
) -> Result<AgentSpeedReportingStatus, String> {
    require_window_label(&window, "dismiss_agent_speed_invitation")?;
    let registry = registry.inner().clone();
    let saved = run_blocking_command(|| {
        let mut reporting = platform::read_app_settings()?.agent_speed_reporting;
        reporting.invitation_handled = true;
        platform::save_agent_speed_reporting_settings(reporting)
    })
    .await?;
    Ok(registry.read_status(&saved.agent_speed_reporting))
}

fn sanitize_username(username: &str) -> Result<String, String> {
    let username = username.trim();
    if username.chars().count() < 2
        || username.chars().count() > 32
        || username.chars().any(char::is_control)
    {
        return Err("Agent Speed username must contain 2 to 32 printable characters.".into());
    }
    Ok(username.to_owned())
}

fn apply_username(
    reporting: &mut AgentSpeedReportingSettingsSnapshot,
    enabled: bool,
    username: Option<String>,
) -> Result<(), String> {
    if enabled {
        if let Some(username) = username {
            reporting.username = sanitize_username(&username)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn username_input_is_trimmed_and_bounded() {
        assert_eq!(
            sanitize_username(" TokenBar-a1b2 ").unwrap(),
            "TokenBar-a1b2"
        );
        assert!(sanitize_username("").is_err());
        assert!(sanitize_username("x").is_err());
        assert!(sanitize_username(&"x".repeat(33)).is_err());
        assert!(sanitize_username("line\nbreak").is_err());
    }

    #[test]
    fn disabling_reporting_ignores_optional_username() {
        let mut reporting = AgentSpeedReportingSettingsSnapshot::default();
        assert!(apply_username(&mut reporting, false, Some("x".into())).is_ok());
        assert!(reporting.username.is_empty());
        assert!(apply_username(&mut reporting, true, Some("x".into())).is_err());
    }
}
