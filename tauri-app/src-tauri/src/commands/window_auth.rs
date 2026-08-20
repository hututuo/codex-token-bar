pub(crate) const MAIN_WINDOW_ONLY_COMMANDS: &[&str] = &[
    "set_codex_home",
    "reset_codex_home",
    "read_dashboard_snapshot",
    "read_precise_dashboard_snapshot",
    "rebuild_precise_index_for_current_version",
    "read_precise_dashboard_progress",
    "read_precise_dashboard_source_probe",
    "acknowledge_attribution_safety",
    "read_usage_cache_status",
    "read_live_thread_options",
    "reset_live_rate_monitor",
    "read_autostart_status",
    "set_autostart_enabled",
    "save_floating_settings",
    "save_display_surfaces",
    "save_custom_account_display_name",
    "save_quota_refresh_interval_ms",
    "save_usage_refresh_settings",
    "save_auto_resume_settings",
    "save_session_enhancement_settings",
    "save_setup_guide_completed",
    "scan_provider_repair",
    "list_provider_backups",
    "create_provider_backup",
    "sync_provider_history",
    "migrate_provider_history",
    "verify_provider_repair",
    "rollback_provider_backup",
    "rebuild_conversation_visibility",
    "read_provider_operation_status",
    "discover_provider_operation_ownership",
    "list_codex_instances",
    "create_codex_instance",
    "import_codex_instance",
    "update_codex_instance",
    "delete_codex_instance",
    "read_codex_instance_runtime_status",
    "list_codex_instance_runtime_statuses",
    "launch_codex_instance",
    "focus_codex_instance",
    "stop_codex_instance",
    "preview_codex_instance_sync",
    "sync_codex_instances",
    "list_codex_instance_sync_transactions",
    "rollback_codex_instance_sync",
    "read_codex_radar_full_snapshot",
    "read_thread_delete_bridge_status",
    "reconnect_thread_delete_bridge",
    "enable_thread_delete_bridge",
    "list_auto_resume_threads",
    "read_auto_resume_status",
    "run_auto_resume_now",
    "cancel_auto_resume_run",
    "list_session_management_catalog",
    "read_session_context_page",
    "archive_session_threads",
    "unarchive_session_threads",
    "prepare_session_delete_confirmation",
    "delete_session_threads",
    "create_session_recovery_archives",
    "read_app_update_state",
    "check_app_update",
    "install_app_update",
];

pub(crate) const SURFACE_SAFE_COMMANDS: &[&str] = &[
    "get_codex_home",
    "read_app_settings",
    "record_startup_event",
    "record_performance_event",
    "read_platform_capabilities",
    "read_account_quota",
    "read_account_reset_credits",
    "read_codex_crowd_radar_payload",
    "read_usage_summary_snapshot",
    "read_live_rate_snapshot",
    "claim_live_rate_owner_session",
    "start_live_rate_stream",
    "stop_live_rate_stream",
    "read_floating_snapshot",
    "read_unread_summary",
    "read_running_thread_summary",
    "acknowledge_current_unread",
    "show_floating_window",
    "hide_floating_window",
    "show_dashboard_window",
    "show_status_panel_window",
    "hide_status_panel_window",
    "dismiss_status_panel_on_blur",
];

pub(crate) const STATUS_WINDOW_ONLY_COMMANDS: &[&str] = &["publish_status_indicator_readout"];

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

    if STATUS_WINDOW_ONLY_COMMANDS.contains(&command) {
        return label == STATUS_WINDOW_LABEL;
    }

    if command == "save_floating_position" {
        return matches!(label, MAIN_WINDOW_LABEL | FLOATING_WINDOW_LABEL);
    }

    if command == "complete_floating_paging_guide" {
        return label == FLOATING_WINDOW_LABEL;
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
    fn status_indicator_publication_is_status_surface_only() {
        for command in STATUS_WINDOW_ONLY_COMMANDS {
            assert!(!allows_window_label(command, "main"));
            assert!(!allows_window_label(command, "floating"));
            assert!(allows_window_label(command, "status"));
            assert!(!allows_window_label(command, "unknown"));
        }
    }

    #[test]
    fn floating_position_save_keeps_existing_floating_window_behavior() {
        assert!(allows_window_label("save_floating_position", "main"));
        assert!(allows_window_label("save_floating_position", "floating"));
        assert!(!allows_window_label("save_floating_position", "status"));
    }

    #[test]
    fn paging_guide_completion_is_floating_surface_only() {
        assert!(!allows_window_label("complete_floating_paging_guide", "main"));
        assert!(allows_window_label("complete_floating_paging_guide", "floating"));
        assert!(!allows_window_label("complete_floating_paging_guide", "status"));
        assert!(!allows_window_label("complete_floating_paging_guide", "unknown"));
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

    #[test]
    fn session_management_commands_are_main_window_only_and_complete() {
        for command in [
            "list_session_management_catalog",
            "read_session_context_page",
            "archive_session_threads",
            "unarchive_session_threads",
            "prepare_session_delete_confirmation",
            "delete_session_threads",
            "create_session_recovery_archives",
        ] {
            assert!(allows_window_label(command, "main"), "{command}");
            assert!(!allows_window_label(command, "floating"), "{command}");
            assert!(!allows_window_label(command, "status"), "{command}");
        }
    }

    fn source_root() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
    }

    fn registered_commands() -> Vec<String> {
        let lib = std::fs::read_to_string(source_root().join("lib.rs")).unwrap();
        let start = lib
            .find("generate_handler![")
            .expect("lib.rs 缺少 generate_handler 注册块");
        let block = &lib[start..];
        let end = block.find("])").expect("generate_handler 注册块未闭合");
        block[..end]
            .lines()
            .filter_map(|line| {
                let line = line.trim().trim_end_matches(',');
                line.rsplit("::").next().filter(|name| {
                    !name.is_empty()
                        && name
                            .chars()
                            .all(|character| character.is_ascii_lowercase() || character == '_')
                })
            })
            .map(str::to_owned)
            .collect()
    }

    fn window_checked_commands() -> Vec<String> {
        let commands_dir = source_root().join("commands");
        let mut checked = Vec::new();
        for entry in std::fs::read_dir(commands_dir).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("rs") {
                continue;
            }
            let source = std::fs::read_to_string(&path).unwrap();
            let mut rest = source.as_str();
            while let Some(position) = rest.find("require_window_label(&window, \"") {
                rest = &rest[position + "require_window_label(&window, \"".len()..];
                let name_end = rest.find('"').expect("命令名字符串未闭合");
                checked.push(rest[..name_end].to_owned());
                rest = &rest[name_end..];
            }
        }
        checked.sort();
        checked.dedup();
        checked
    }

    // 对账：任何调用 require_window_label 的命令必须在某个白名单里；
    // 否则该命令从所有窗口调用都被拒（P0-3 的故障类型）。
    #[test]
    fn every_window_checked_command_is_reachable_from_at_least_one_surface() {
        let checked = window_checked_commands();
        assert!(
            checked.len() >= 40,
            "解析到的受检命令数异常偏少：{}",
            checked.len()
        );
        for command in &checked {
            assert!(
                ["main", "floating", "status"]
                    .iter()
                    .any(|label| allows_window_label(command, label)),
                "{command} 调用了 require_window_label 但不在任何窗口白名单中，任何窗口都无法调用"
            );
        }
    }

    // 反向对账：名单里的每个命令都必须在真实命令体调用校验。只把名字写进
    // allowlist 不能保护没有接收 WebviewWindow 的生产入口。
    #[test]
    fn every_allowlisted_command_checks_its_caller_window() {
        let checked = window_checked_commands();
        for command in MAIN_WINDOW_ONLY_COMMANDS
            .iter()
            .chain(SURFACE_SAFE_COMMANDS.iter())
            .chain(std::iter::once(&"save_floating_position"))
        {
            assert!(
                checked.iter().any(|name| name == command),
                "白名单条目 {command} 没有在真实命令体调用 require_window_label"
            );
        }
    }

    // 对账：白名单条目必须是 generate_handler 中真实注册的命令，防止拼写或改名后的陈旧条目。
    #[test]
    fn every_allowlisted_command_is_registered_in_the_invoke_handler() {
        let registered = registered_commands();
        assert!(
            registered.len() >= 70,
            "解析到的注册命令数异常偏少：{}",
            registered.len()
        );
        for command in MAIN_WINDOW_ONLY_COMMANDS
            .iter()
            .chain(SURFACE_SAFE_COMMANDS.iter())
            .chain(std::iter::once(&"save_floating_position"))
        {
            assert!(
                registered.iter().any(|name| name == command),
                "白名单条目 {command} 不是已注册命令"
            );
        }
    }

    #[test]
    fn provider_migration_and_instance_commands_are_main_window_only() {
        for command in [
            "migrate_provider_history",
            "rebuild_conversation_visibility",
            "list_codex_instances",
            "create_codex_instance",
            "import_codex_instance",
            "update_codex_instance",
            "delete_codex_instance",
            "read_codex_instance_runtime_status",
            "list_codex_instance_runtime_statuses",
            "launch_codex_instance",
            "focus_codex_instance",
            "stop_codex_instance",
            "preview_codex_instance_sync",
            "sync_codex_instances",
            "list_codex_instance_sync_transactions",
            "rollback_codex_instance_sync",
        ] {
            assert!(allows_window_label(command, "main"), "{command}");
            assert!(!allows_window_label(command, "floating"), "{command}");
            assert!(!allows_window_label(command, "status"), "{command}");
        }
    }

    #[test]
    fn usage_refresh_settings_save_is_main_window_only() {
        assert!(allows_window_label("save_usage_refresh_settings", "main"));
        assert!(!allows_window_label("save_usage_refresh_settings", "floating"));
        assert!(!allows_window_label("save_usage_refresh_settings", "status"));
    }
}
