use crate::models::{PlatformCapabilities, PlatformFeatureCapability};

pub fn platform_capabilities() -> PlatformCapabilities {
    PlatformCapabilities {
        platform: platform_name().into(),
        shell: "Tauri desktop".into(),
        floating_window: floating_window_capability(),
        floating_transparency: floating_transparency_capability(),
        floating_drag: floating_drag_capability(),
        floating_lock: pending("窗口锁定", "共享 UI 已预留入口，跟随窗口和锁定逻辑留到 Windows 真机实现。"),
        status_tray: status_tray_capability(),
        status_tray_live_text: status_tray_live_text_capability(),
        autostart: pending("开机自启", "需要按系统分别接入登录项 / 启动项，本轮只保留平台接口。"),
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

fn floating_window_capability() -> PlatformFeatureCapability {
    if cfg!(target_os = "macos") {
        ready("悬浮窗", "macOS 调试实现已接通；Windows 会复用同一 UI，再补平台窗口行为。")
    } else if cfg!(target_os = "windows") {
        pending("悬浮窗", "共享 UI 已完成，透明、置顶、拖动和多屏行为需要在 Windows 真机验收。")
    } else {
        unavailable("悬浮窗", "当前平台暂未接入桌面悬浮窗。")
    }
}

fn floating_transparency_capability() -> PlatformFeatureCapability {
    if cfg!(target_os = "macos") {
        ready("透明悬浮窗", "macOS 调试实现可用。")
    } else if cfg!(target_os = "windows") {
        pending("透明悬浮窗", "Windows 透明背景和阴影策略待真机实现。")
    } else {
        unavailable("透明悬浮窗", "当前平台暂未接入透明窗口。")
    }
}

fn floating_drag_capability() -> PlatformFeatureCapability {
    if cfg!(target_os = "macos") {
        ready("拖动悬浮窗", "macOS 调试实现可用。")
    } else if cfg!(target_os = "windows") {
        pending("拖动悬浮窗", "Windows 拖动、吸附和 DPI 坐标换算待真机实现。")
    } else {
        unavailable("拖动悬浮窗", "当前平台暂未接入拖动。")
    }
}

fn status_tray_capability() -> PlatformFeatureCapability {
    if cfg!(target_os = "macos") {
        ready("状态栏", "macOS 状态栏调试实现可用。")
    } else if cfg!(target_os = "windows") {
        pending("系统托盘", "Windows 托盘入口需单独实现图标、菜单和弹出面板。")
    } else {
        unavailable("系统托盘", "当前平台暂未接入托盘入口。")
    }
}

fn status_tray_live_text_capability() -> PlatformFeatureCapability {
    if cfg!(target_os = "macos") {
        ready("状态栏实时数字", "macOS 菜单栏可直接显示短数字。")
    } else if cfg!(target_os = "windows") {
        pending("托盘实时数字", "Windows 托盘不能直接放文字，后续需要动态图标或弹出面板方案。")
    } else {
        unavailable("托盘实时数字", "当前平台暂未接入实时托盘文字。")
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

fn feature(label: &str, status: &str, note: &str, available: bool) -> PlatformFeatureCapability {
    PlatformFeatureCapability {
        available,
        status: status.into(),
        label: label.into(),
        note: note.into(),
    }
}
