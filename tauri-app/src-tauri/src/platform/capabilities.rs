use super::{surface_setup_status, SurfaceSetupStatus};
use crate::models::{PlatformCapabilities, PlatformFeatureCapability};

pub fn platform_capabilities() -> PlatformCapabilities {
    platform_capabilities_for(current_platform(), surface_setup_status())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DesktopPlatform {
    Macos,
    Windows,
    Linux,
    Other,
}

fn current_platform() -> DesktopPlatform {
    if cfg!(target_os = "windows") {
        DesktopPlatform::Windows
    } else if cfg!(target_os = "macos") {
        DesktopPlatform::Macos
    } else if cfg!(target_os = "linux") {
        DesktopPlatform::Linux
    } else {
        DesktopPlatform::Other
    }
}

fn platform_capabilities_for(
    platform: DesktopPlatform,
    setup_status: SurfaceSetupStatus,
) -> PlatformCapabilities {
    let floating_window_error = setup_status.floating_window_error.as_deref();
    let status_surface_error = setup_status
        .status_panel_error
        .as_deref()
        .or(setup_status.status_tray_error.as_deref());
    let status_tray_error = setup_status.status_tray_error.as_deref();

    PlatformCapabilities {
        platform: platform_name(platform).into(),
        shell: "Tauri desktop".into(),
        floating_window: floating_window_capability(platform, floating_window_error),
        floating_transparency: floating_transparency_capability(platform, floating_window_error),
        floating_drag: floating_drag_capability(platform, floating_window_error),
        floating_lock: pending("窗口锁定", "共享 UI 已预留入口，跟随窗口和锁定逻辑留到 Windows 真机实现。"),
        status_tray: status_tray_capability(platform, status_surface_error),
        status_tray_live_text: status_tray_live_text_capability(platform, status_tray_error),
        autostart: autostart_capability(platform),
        notifications: pending("完成提醒", "通知和未读提醒 UI 可复用，系统通知权限留到平台层实现。"),
    }
}

fn platform_name(platform: DesktopPlatform) -> &'static str {
    match platform {
        DesktopPlatform::Windows => "windows",
        DesktopPlatform::Macos => "macos",
        DesktopPlatform::Linux => "linux",
        DesktopPlatform::Other => "unknown",
    }
}

fn floating_window_capability(
    platform: DesktopPlatform,
    setup_error: Option<&str>,
) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("悬浮窗", error);
    }

    match platform {
        DesktopPlatform::Macos => ready(
            "悬浮窗",
            "macOS 调试实现已接通；Windows 会复用同一 UI，再补平台窗口行为。",
        ),
        DesktopPlatform::Windows => ready(
            "悬浮窗",
            "Windows 真机已接入基础悬浮窗；透明、拖动和多屏细节继续验收。",
        ),
        DesktopPlatform::Linux | DesktopPlatform::Other => {
            unavailable("悬浮窗", "当前平台暂未接入桌面悬浮窗。")
        }
    }
}

fn floating_transparency_capability(
    platform: DesktopPlatform,
    setup_error: Option<&str>,
) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("透明悬浮窗", error);
    }

    match platform {
        DesktopPlatform::Macos => ready("透明悬浮窗", "macOS 调试实现可用。"),
        DesktopPlatform::Windows => pending("透明悬浮窗", "Windows 透明背景和阴影策略待真机实现。"),
        DesktopPlatform::Linux | DesktopPlatform::Other => {
            unavailable("透明悬浮窗", "当前平台暂未接入透明窗口。")
        }
    }
}

fn floating_drag_capability(
    platform: DesktopPlatform,
    setup_error: Option<&str>,
) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("拖动悬浮窗", error);
    }

    match platform {
        DesktopPlatform::Macos => ready("拖动悬浮窗", "macOS 调试实现可用。"),
        DesktopPlatform::Windows => pending("拖动悬浮窗", "Windows 拖动、吸附和 DPI 坐标换算待真机实现。"),
        DesktopPlatform::Linux | DesktopPlatform::Other => {
            unavailable("拖动悬浮窗", "当前平台暂未接入拖动。")
        }
    }
}

fn status_tray_capability(
    platform: DesktopPlatform,
    setup_error: Option<&str>,
) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("状态栏", error);
    }

    match platform {
        DesktopPlatform::Macos => ready("状态栏", "macOS 状态栏调试实现可用，已接入独立弹出面板。"),
        DesktopPlatform::Windows => pending(
            "系统托盘",
            "共享弹出面板已完成，Windows 托盘定位和图标行为留到真机实现。",
        ),
        DesktopPlatform::Linux | DesktopPlatform::Other => {
            unavailable("系统托盘", "当前平台暂未接入托盘入口。")
        }
    }
}

fn status_tray_live_text_capability(
    platform: DesktopPlatform,
    setup_error: Option<&str>,
) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("状态栏实时数字", error);
    }

    match platform {
        DesktopPlatform::Macos => ready("状态栏实时数字", "macOS 菜单栏可直接显示短数字。"),
        DesktopPlatform::Windows => pending(
            "托盘实时数字",
            "Windows 托盘不能直接放文字，后续需要动态图标或弹出面板方案。",
        ),
        DesktopPlatform::Linux | DesktopPlatform::Other => {
            unavailable("托盘实时数字", "当前平台暂未接入实时托盘文字。")
        }
    }
}

fn autostart_capability(platform: DesktopPlatform) -> PlatformFeatureCapability {
    match platform {
        DesktopPlatform::Macos | DesktopPlatform::Windows | DesktopPlatform::Linux => ready(
            "开机自启",
            "已接入 Tauri autostart 共享接口；登录后隐藏主界面仍需按平台验收。",
        ),
        DesktopPlatform::Other => unavailable("开机自启", "当前平台暂不支持开机自启。"),
    }
}

fn ready(label: &str, note: &str) -> PlatformFeatureCapability {
    feature(label, "ready", note, true)
}

fn pending(label: &str, note: &str) -> PlatformFeatureCapability {
    feature(label, "pending", note, false)
}

fn unavailable(label: &str, note: &str) -> PlatformFeatureCapability {
    feature(label, "unavailable", note, false)
}

fn setup_unavailable(label: &str, error: &str) -> PlatformFeatureCapability {
    feature(
        label,
        "unavailable",
        &format!("平台面创建失败：{error}"),
        false,
    )
}

fn feature(label: &str, status: &str, note: &str, available: bool) -> PlatformFeatureCapability {
    PlatformFeatureCapability {
        available,
        status: status.into(),
        label: label.into(),
        note: note.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_capabilities_mark_debug_surfaces_ready() {
        let capabilities =
            platform_capabilities_for(DesktopPlatform::Macos, SurfaceSetupStatus::default());

        assert_eq!(capabilities.platform, "macos");
        assert_ready(&capabilities.floating_window);
        assert_ready(&capabilities.floating_transparency);
        assert_ready(&capabilities.floating_drag);
        assert_ready(&capabilities.status_tray);
        assert_ready(&capabilities.status_tray_live_text);
        assert_ready(&capabilities.autostart);
        assert_pending(&capabilities.floating_lock);
        assert_pending(&capabilities.notifications);
    }

    #[test]
    fn windows_capabilities_enable_basic_floating_window_only() {
        let capabilities =
            platform_capabilities_for(DesktopPlatform::Windows, SurfaceSetupStatus::default());

        assert_eq!(capabilities.platform, "windows");
        assert_ready(&capabilities.floating_window);
        assert_pending(&capabilities.floating_transparency);
        assert_pending(&capabilities.floating_drag);
        assert_pending(&capabilities.status_tray);
        assert_pending(&capabilities.status_tray_live_text);
        assert_ready(&capabilities.autostart);
    }

    #[test]
    fn setup_errors_make_related_surface_capabilities_unavailable() {
        let capabilities = platform_capabilities_for(
            DesktopPlatform::Macos,
            SurfaceSetupStatus {
                floating_window_error: Some("floating failed".into()),
                status_panel_error: Some("panel failed".into()),
                status_tray_error: None,
            },
        );

        assert_unavailable_with(&capabilities.floating_window, "floating failed");
        assert_unavailable_with(&capabilities.floating_transparency, "floating failed");
        assert_unavailable_with(&capabilities.floating_drag, "floating failed");
        assert_unavailable_with(&capabilities.status_tray, "panel failed");
        assert_ready(&capabilities.status_tray_live_text);
    }

    #[test]
    fn status_tray_error_disables_tray_and_live_text() {
        let capabilities = platform_capabilities_for(
            DesktopPlatform::Macos,
            SurfaceSetupStatus {
                floating_window_error: None,
                status_panel_error: None,
                status_tray_error: Some("tray failed".into()),
            },
        );

        assert_unavailable_with(&capabilities.status_tray, "tray failed");
        assert_unavailable_with(&capabilities.status_tray_live_text, "tray failed");
    }

    fn assert_ready(feature: &PlatformFeatureCapability) {
        assert!(feature.available, "{} should be available", feature.label);
        assert_eq!(feature.status, "ready");
    }

    fn assert_pending(feature: &PlatformFeatureCapability) {
        assert!(!feature.available, "{} should not be available", feature.label);
        assert_eq!(feature.status, "pending");
    }

    fn assert_unavailable_with(feature: &PlatformFeatureCapability, expected_note: &str) {
        assert!(!feature.available, "{} should not be available", feature.label);
        assert_eq!(feature.status, "unavailable");
        assert!(feature.note.contains(expected_note), "note was: {}", feature.note);
    }
}
