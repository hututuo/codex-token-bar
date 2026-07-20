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
import { callCommand, callCommandOptional, callCommandStrict } from "./command";

export function readAppSettings(): Promise<AppSettingsSnapshot | null> {
  return callCommandOptional("read_app_settings");
}

export function saveFloatingSettings(settings: FloatingWindowSettings): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_floating_settings", { settings });
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

export function runAutoResumeNow(): Promise<AutoResumeRuntimeStatus> {
  return callCommandStrict<AutoResumeRuntimeStatus>(
    "run_auto_resume_now",
    undefined,
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
