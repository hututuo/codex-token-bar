import type {
  AutostartStatus,
  CodexHomeStatus,
  PlatformCapabilities,
  PlatformFeatureCapability,
} from "../../types/platform";

export const fallbackCodexHome: CodexHomeStatus = {
  path: "~/.codex",
  exists: false,
  source: "待读取",
};

export const fallbackPlatformCapabilities: PlatformCapabilities = {
  platform: "unknown",
  shell: "Tauri desktop",
  floatingWindow: pendingFeature("悬浮窗"),
  floatingTransparency: pendingFeature("透明悬浮窗"),
  floatingDrag: pendingFeature("拖动悬浮窗"),
  floatingLock: pendingFeature("窗口锁定"),
  statusTray: pendingFeature("状态栏"),
  statusTrayLiveText: pendingFeature("状态栏实时数字"),
  autostart: pendingFeature("开机自启"),
  notifications: pendingFeature("完成提醒"),
};

export const fallbackAutostartStatus: AutostartStatus = {
  available: false,
  enabled: false,
  status: "unavailable",
  message: "开机自启状态待读取。",
};

function pendingFeature(label: string): PlatformFeatureCapability {
  return {
    available: false,
    status: "pending",
    label,
    note: "平台能力待读取。",
  };
}
