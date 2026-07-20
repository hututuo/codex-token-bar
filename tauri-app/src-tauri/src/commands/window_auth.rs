pub(crate) const MAIN_WINDOW_ONLY_COMMANDS: &[&str] = &[
    "set_codex_home",
    "reset_codex_home",
    "read_dashboard_snapshot",
    "read_precise_dashboard_snapshot",
    "read_usage_cache_status",
    "read_live_thread_options",
    "reset_live_rate_monitor",
    "read_autostart_status",
    "set_autostart_enabled",
    "save_floating_settings",
    "save_display_surfaces",
    "save_custom_account_display_name",
    "save_quota_refresh_interval_ms",
    "save_auto_resume_settings",
    "save_session_enhancement_settings",
    "save_setup_guide_completed",
    "scan_provider_repair",
    "list_provider_backups",
    "create_provider_backup",
    "sync_provider_history",
    "verify_provider_repair",
    "rollback_provider_backup",
    "read_provider_operation_status",
    "discover_provider_operation_ownership",
    "read_codex_radar_full_snapshot",
    "read_thread_delete_bridge_status",
    "reconnect_thread_delete_bridge",
    "enable_thread_delete_bridge",
    "list_auto_resume_threads",
    "read_auto_resume_status",
    "run_auto_resume_now",
    "cancel_auto_resume_run",
];

pub(crate) const SURFACE_SAFE_COMMANDS: &[&str] = &[
    "get_codex_home",
    "read_app_settings",
    "record_startup_event",
    "record_performance_event",
    "read_platform_capabilities",
    "read_account_quota",
    "read_codex_crowd_radar_payload",
    "read_usage_summary_snapshot",
    "read_live_rate_snapshot",
    "claim_live_rate_owner_session",
    "start_live_rate_stream",
    "stop_live_rate_stream",
    "read_floating_snapshot",
    "read_unread_summary",
    "acknowledge_current_unread",
    "show_floating_window",
    "hide_floating_window",
    "show_dashboard_window",
    "show_status_panel_window",
    "hide_status_panel_window",
    "dismiss_status_panel_on_blur",
];

const MAIN_WINDOW_LABEL: &str = "main";
const FLOATING_WINDOW_LABEL: &str = "floating";
const STATUS_WINDOW_LABEL: &str = "status";

pub(crate) fn require_window_label(
    window: &tauri::WebviewWindow,
    command: &'static str,
) -> Result<(), String> {
    let label = window.label();
    if allows_window_label(command, label) {
        return Ok(());
    }

    Err(format!("{command} is not available from the {label} window"))
}

pub(crate) fn allows_window_label(command: &str, label: &str) -> bool {
    if MAIN_WINDOW_ONLY_COMMANDS.contains(&command) {
        return label == MAIN_WINDOW_LABEL;
    }

    if command == "save_floating_position" {
        return matches!(label, MAIN_WINDOW_LABEL | FLOATING_WINDOW_LABEL);
    }

    if SURFACE_SAFE_COMMANDS.contains(&command) {
        return is_app_surface_label(label);
    }

    false
}

fn is_app_surface_label(label: &str) -> bool {
    matches!(label, MAIN_WINDOW_LABEL | FLOATING_WINDOW_LABEL | STATUS_WINDOW_LABEL)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn main_window_only_commands_reject_surface_labels() {
        for command in MAIN_WINDOW_ONLY_COMMANDS {
            assert!(allows_window_label(command, "main"));
            assert!(!allows_window_label(command, "floating"), "{command}");
            assert!(!allows_window_label(command, "status"), "{command}");
        }
    }

    #[test]
    fn surface_safe_commands_remain_available_to_all_app_surfaces() {
        for command in SURFACE_SAFE_COMMANDS {
            assert!(allows_window_label(command, "main"), "{command}");
            assert!(allows_window_label(command, "floating"), "{command}");
            assert!(allows_window_label(command, "status"), "{command}");
        }
    }

    #[test]
    fn floating_position_save_keeps_existing_floating_window_behavior() {
        assert!(allows_window_label("save_floating_position", "main"));
        assert!(allows_window_label("save_floating_position", "floating"));
        assert!(!allows_window_label("save_floating_position", "status"));
    }

    #[test]
    fn unknown_or_unowned_windows_are_not_authorized() {
        assert!(!allows_window_label("set_codex_home", "unknown"));
        assert!(!allows_window_label("read_account_quota", "unknown"));
        assert!(!allows_window_label("not_a_registered_command", "main"));
    }

    #[test]
    fn codex_radar_full_detail_command_is_main_window_only() {
        assert!(allows_window_label("read_codex_radar_full_snapshot", "main"));
        assert!(!allows_window_label("read_codex_radar_full_snapshot", "floating"));
        assert!(!allows_window_label("read_codex_radar_full_snapshot", "status"));
    }

    #[test]
    fn crowd_radar_public_read_is_available_to_every_app_surface() {
        for label in ["main", "floating", "status"] {
            assert!(allows_window_label("read_codex_crowd_radar_payload", label));
        }
        assert!(!allows_window_label(
            "read_codex_crowd_radar_payload",
            "unknown"
        ));
    }

    #[test]
    fn codex_home_source_read_is_surface_safe_but_mutation_stays_main_only() {
        for label in ["main", "floating", "status"] {
            assert!(allows_window_label("get_codex_home", label), "{label}");
        }
        for command in ["set_codex_home", "reset_codex_home"] {
            assert!(allows_window_label(command, "main"), "{command}");
            assert!(!allows_window_label(command, "floating"), "{command}");
            assert!(!allows_window_label(command, "status"), "{command}");
        }
    }
}
