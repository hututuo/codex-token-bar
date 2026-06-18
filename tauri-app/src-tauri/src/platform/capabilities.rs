use super::surface_setup_status;
use crate::models::{PlatformCapabilities, PlatformFeatureCapability};

pub fn platform_capabilities() -> PlatformCapabilities {
    let setup_status = surface_setup_status();
    let floating_window_error = setup_status.floating_window_error.as_deref();
    let status_surface_error = setup_status
        .status_panel_error
        .as_deref()
        .or(setup_status.status_tray_error.as_deref());
    let status_tray_error = setup_status.status_tray_error.as_deref();

    PlatformCapabilities {
        platform: platform_name().into(),
        shell: "Tauri desktop".into(),
        floating_window: floating_window_capability(floating_window_error),
        floating_transparency: floating_transparency_capability(floating_window_error),
        floating_drag: floating_drag_capability(floating_window_error),
        floating_lock: pending("窗口锁定", "共享 UI 已预留入口，跟随窗口和锁定逻辑留到 Windows 真机实现。"),
        status_tray: status_tray_capability(status_surface_error),
        status_tray_live_text: status_tray_live_text_capability(status_tray_error),
        autostart: autostart_capability(),
        notifications: pending("完成提醒", "通知和未读提醒 UI 可复用，系统通知权限留到平台层实现。"),
    }
}

fn platform_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unknown"
    }
}

fn floating_window_capability(setup_error: Option<&str>) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("悬浮窗", error);
    }

    if cfg!(target_os = "macos") {
        ready("悬浮窗", "macOS 调试实现已接通；Windows 会复用同一 UI，再补平台窗口行为。")
    } else if cfg!(target_os = "windows") {
        pending("悬浮窗", "共享 UI 已完成，透明、置顶、拖动和多屏行为需要在 Windows 真机验收。")
    } else {
        unavailable("悬浮窗", "当前平台暂未接入桌面悬浮窗。")
    }
}

fn floating_transparency_capability(setup_error: Option<&str>) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("透明悬浮窗", error);
    }

    if cfg!(target_os = "macos") {
        ready("透明悬浮窗", "macOS 调试实现可用。")
    } else if cfg!(target_os = "windows") {
        pending("透明悬浮窗", "Windows 透明背景和阴影策略待真机实现。")
    } else {
        unavailable("透明悬浮窗", "当前平台暂未接入透明窗口。")
    }
}

fn floating_drag_capability(setup_error: Option<&str>) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("拖动悬浮窗", error);
    }

    if cfg!(target_os = "macos") {
        ready("拖动悬浮窗", "macOS 调试实现可用。")
    } else if cfg!(target_os = "windows") {
        pending("拖动悬浮窗", "Windows 拖动、吸附和 DPI 坐标换算待真机实现。")
    } else {
        unavailable("拖动悬浮窗", "当前平台暂未接入拖动。")
    }
}

fn status_tray_capability(setup_error: Option<&str>) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("状态栏", error);
    }

    if cfg!(target_os = "macos") {
        ready("状态栏", "macOS 状态栏调试实现可用，已接入独立弹出面板。")
    } else if cfg!(target_os = "windows") {
        pending("系统托盘", "共享弹出面板已完成，Windows 托盘定位和图标行为留到真机实现。")
    } else {
        unavailable("系统托盘", "当前平台暂未接入托盘入口。")
    }
}

fn status_tray_live_text_capability(setup_error: Option<&str>) -> PlatformFeatureCapability {
    if let Some(error) = setup_error {
        return setup_unavailable("状态栏实时数字", error);
    }

    if cfg!(target_os = "macos") {
        ready("状态栏实时数字", "macOS 菜单栏可直接显示短数字。")
    } else if cfg!(target_os = "windows") {
        pending("托盘实时数字", "Windows 托盘不能直接放文字，后续需要动态图标或弹出面板方案。")
    } else {
        unavailable("托盘实时数字", "当前平台暂未接入实时托盘文字。")
    }
}

fn autostart_capability() -> PlatformFeatureCapability {
    if cfg!(any(target_os = "macos", target_os = "windows", target_os = "linux")) {
        ready("开机自启", "已接入 Tauri autostart 共享接口；登录后隐藏主界面仍需按平台验收。")
    } else {
        unavailable("开机自启", "当前平台暂不支持开机自启。")
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
