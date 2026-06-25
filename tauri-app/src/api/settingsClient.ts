import type {
  AppSettingsSnapshot,
  AutostartStatus,
  DisplaySurfaceSettings,
  FloatingWindowPosition,
  FloatingWindowSettings,
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

export function saveSetupGuideCompleted(completed: boolean): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_setup_guide_completed", { completed });
}

export function readAutostartStatus(): Promise<AutostartStatus> {
  return callCommand("read_autostart_status", fallbackAutostartStatus);
}

export function setAutostartEnabled(enabled: boolean): Promise<AutostartStatus> {
  return callCommandStrict<AutostartStatus>("set_autostart_enabled", { enabled });
}
