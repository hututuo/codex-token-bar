import { invoke } from "@tauri-apps/api/core";
import type {
  AccountQuotaBundle,
  AppSettingsSnapshot,
  AutostartStatus,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
  UnreadSummary,
} from "../types/dashboard";
import {
  emptyDashboardSnapshot,
  emptyFloatingPanelSnapshot,
  emptyLiveRateSnapshot,
  emptyUnreadSummary,
  fallbackAutostartStatus,
  fallbackCodexHome,
  fallbackPlatformCapabilities,
  fallbackProviderRepairSnapshot,
} from "./fallback";
import {
  clearCommandFailure,
  getCommandDiagnosticsSnapshot,
  recordCommandFailure,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
} from "../diagnostics/localDiagnostics";
import { isTauriRuntimeAvailable, withTimeout } from "../platform/runtime";
import type {
  DisplaySurfaceSettings,
  FloatingWindowPosition,
  FloatingWindowSettings,
} from "../types/dashboard";

const DEFAULT_COMMAND_TIMEOUT_MS = 4_000;

export {
  getCommandDiagnosticsSnapshot,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
};

async function callCommand<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    recordCommandFailure(command, new Error("当前不是 Tauri 桌面运行环境。"));
    return fallback;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), timeoutMs);
    clearCommandFailure(command);
    return result;
  } catch (error) {
    recordCommandFailure(command, error);
    return fallback;
  }
}

async function callCommandOptional<T>(
  command: string,
  args?: Record<string, unknown>,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T | null> {
  if (!isTauriRuntimeAvailable()) {
    recordCommandFailure(command, new Error("当前不是 Tauri 桌面运行环境。"));
    return null;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), timeoutMs);
    clearCommandFailure(command);
    return result;
  } catch (error) {
    recordCommandFailure(command, error);
    return null;
  }
}

async function callCommandStrict<T>(
  command: string,
  args?: Record<string, unknown>,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    const error = new Error("当前不是 Tauri 桌面运行环境。");
    recordCommandFailure(command, error);
    throw error;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), timeoutMs);
    clearCommandFailure(command);
    return result;
  } catch (error) {
    const normalized = normalizeError(error);
    recordCommandFailure(command, normalized);
    throw normalized;
  }
}

function normalizeError(error: unknown): Error {
  if (error instanceof Error) {
    return error;
  }
  if (typeof error === "string") {
    return new Error(error);
  }
  try {
    return new Error(JSON.stringify(error));
  } catch {
    return new Error(String(error));
  }
}

export function getCodexHome(): Promise<CodexHomeStatus> {
  return callCommand("get_codex_home", fallbackCodexHome);
}

export function setCodexHome(path: string): Promise<CodexHomeStatus> {
  return callCommandStrict<CodexHomeStatus>("set_codex_home", { path });
}

export function resetCodexHome(): Promise<CodexHomeStatus> {
  return callCommandStrict<CodexHomeStatus>("reset_codex_home");
}

export function readAppSettings(): Promise<AppSettingsSnapshot | null> {
  return callCommandOptional("read_app_settings");
}

export function recordStartupEvent(label: string): Promise<boolean> {
  return callCommand("record_startup_event", false, { label }, 1_000);
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

export function saveSetupGuideCompleted(completed: boolean): Promise<AppSettingsSnapshot> {
  return callCommandStrict<AppSettingsSnapshot>("save_setup_guide_completed", { completed });
}

export function readPlatformCapabilities(): Promise<PlatformCapabilities> {
  return callCommand("read_platform_capabilities", fallbackPlatformCapabilities);
}

export function readAutostartStatus(): Promise<AutostartStatus> {
  return callCommand("read_autostart_status", fallbackAutostartStatus);
}

export function setAutostartEnabled(enabled: boolean): Promise<AutostartStatus> {
  return callCommandStrict<AutostartStatus>("set_autostart_enabled", { enabled });
}

export function readDashboardSnapshot(): Promise<DashboardSnapshot> {
  return callCommand("read_dashboard_snapshot", emptyDashboardSnapshot());
}

export function readPreciseDashboardSnapshot(): Promise<DashboardSnapshot | null> {
  return callCommandOptional("read_precise_dashboard_snapshot", undefined, 30_000);
}

export function readAccountQuota(forceRefresh = false): Promise<AccountQuotaBundle | null> {
  return callCommandOptional(
    "read_account_quota",
    { forceRefresh },
    12_000,
  );
}

export function readLiveRateSnapshot(selectedThreadId?: string | null): Promise<LiveRateSnapshot> {
  return callCommand(
    "read_live_rate_snapshot",
    emptyLiveRateSnapshot(selectedThreadId),
    { selectedThreadId: selectedThreadId || null },
    1_500,
  );
}

export function readLiveThreadOptions(): Promise<LiveThreadOption[]> {
  return callCommand("read_live_thread_options", [], undefined, 1_500);
}

export function readFloatingPanelSnapshot(): Promise<FloatingPanelSnapshot> {
  return callCommand("read_floating_snapshot", emptyFloatingPanelSnapshot, undefined, 1_500);
}

export function readUnreadSummary(): Promise<UnreadSummary> {
  return callCommand("read_unread_summary", emptyUnreadSummary, undefined, 1_500);
}

export function scanProviderRepair(): Promise<ProviderRepairSnapshot> {
  return callCommand("scan_provider_repair", fallbackProviderRepairSnapshot, undefined, 20_000);
}

export function listProviderBackups(): Promise<ProviderRepairBackupInfo[]> {
  return callCommand("list_provider_backups", [], undefined, 20_000);
}

export function createProviderBackup(): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("create_provider_backup", undefined, 60_000);
}

export function syncProviderHistory(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("sync_provider_history", { backupId }, 60_000);
}

export function verifyProviderRepair(): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("verify_provider_repair", undefined, 30_000);
}

export function rollbackProviderBackup(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("rollback_provider_backup", { backupId }, 60_000);
}
