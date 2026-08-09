import type {
  AppSettingsSnapshot,
  AutoResumeRuntimeStatus,
  AutoResumeSettings,
  AutoResumeThreadOption,
  AutostartStatus,
  DisplaySurfaceSettings,
  FloatingWindowPosition,
  FloatingWindowSettings,
  SessionEnhancementSettings,
} from "../types/dashboard";
import { fallbackAutostartStatus } from "./fallback";
import { callCommand, callCommandStrict } from "./command";
import { isTauriRuntimeAvailable } from "../platform/runtime";

export function readAppSettings(): Promise<AppSettingsSnapshot | null> {
  // null 只表示 Missing（非 Tauri 桌面运行环境，如浏览器预览），调用方走默认值；
  // 桌面环境里的读取失败必须显式抛错交给错误横幅，不再折成 null 静默吞掉。
  if (!isTauriRuntimeAvailable()) {
    return Promise.resolve(null);
  }
  return callCommandStrict<AppSettingsSnapshot>("read_app_settings");
}

export function saveFloatingSettings(settings: FloatingWindowSettings): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_floating_settings", { settings });
}

export function completeFloatingPagingGuide(showPageNavigationArrows: boolean): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("complete_floating_paging_guide", { showPageNavigationArrows });
}

export function saveFloatingPosition(position: FloatingWindowPosition): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_floating_position", { position });
}

export function saveDisplaySurfaces(display: DisplaySurfaceSettings): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_display_surfaces", { display });
}

export function saveCustomAccountDisplayName(customAccountDisplayName: string): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_custom_account_display_name", { customAccountDisplayName });
}

export function saveQuotaRefreshIntervalMs(intervalMs: number): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_quota_refresh_interval_ms", { intervalMs });
}

export function saveSetupGuideCompleted(completed: boolean): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_setup_guide_completed", { completed });
}

export function saveAutoResumeSettings(settings: AutoResumeSettings): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_auto_resume_settings", { settings });
}

export function saveSessionEnhancementSettings(settings: SessionEnhancementSettings): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_session_enhancement_settings", { settings });
}

export function listAutoResumeThreads(): Promise<AutoResumeThreadOption[]> {
  return callCommandStrict<AutoResumeThreadOption[]>("list_auto_resume_threads", undefined, 30_000);
}

export function readAutoResumeStatus(): Promise<AutoResumeRuntimeStatus> {
  return callCommandStrict<AutoResumeRuntimeStatus>("read_auto_resume_status");
}

export function runAutoResumeNow(taskId: string): Promise<AutoResumeRuntimeStatus> {
  return callCommandStrict<AutoResumeRuntimeStatus>(
    "run_auto_resume_now",
    { taskId },
    6 * 60 * 60 * 1_000 + 60_000,
  );
}

export function cancelAutoResumeRun(): Promise<AutoResumeRuntimeStatus> {
  return callCommandStrict<AutoResumeRuntimeStatus>("cancel_auto_resume_run", undefined, 15_000);
}

export function readAutostartStatus(): Promise<AutostartStatus> {
  return callCommand("read_autostart_status", fallbackAutostartStatus);
}

export function setAutostartEnabled(enabled: boolean): Promise<AutostartStatus> {
  return callCommandStrict<AutostartStatus>("set_autostart_enabled", { enabled });
}
