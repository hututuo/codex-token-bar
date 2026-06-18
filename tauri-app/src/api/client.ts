import { invoke } from "@tauri-apps/api/core";
import type {
  AccountQuotaBundle,
  AppSettingsSnapshot,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import {
  emptyAccountQuotaBundle,
  emptyDashboardSnapshot,
  emptyFloatingPanelSnapshot,
  emptyLiveRateSnapshot,
  fallbackAppSettings,
  fallbackCodexHome,
  fallbackPlatformCapabilities,
  fallbackProviderRepairActionResult,
  fallbackProviderRepairSnapshot,
} from "./fallback";
import { isTauriRuntimeAvailable, withTimeout } from "../platform/runtime";
import type {
  DisplaySurfaceSettings,
  FloatingWindowPosition,
  FloatingWindowSettings,
} from "../types/dashboard";

const DEFAULT_COMMAND_TIMEOUT_MS = 4_000;
const WARNING_THROTTLE_MS = 5_000;
const lastWarningAtByCommand = new Map<string, number>();
const commandDiagnosticsByName = new Map<string, CommandFailureDiagnostic>();
const commandDiagnosticsListeners = new Set<(diagnostics: CommandFailureDiagnostic[]) => void>();

export interface CommandFailureDiagnostic {
  command: string;
  message: string;
  occurredAt: string;
  count: number;
}

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

export function getCommandDiagnosticsSnapshot(): CommandFailureDiagnostic[] {
  return Array.from(commandDiagnosticsByName.values()).sort((left, right) =>
    right.occurredAt.localeCompare(left.occurredAt),
  );
}

export function subscribeCommandDiagnostics(
  listener: (diagnostics: CommandFailureDiagnostic[]) => void,
): () => void {
  commandDiagnosticsListeners.add(listener);
  listener(getCommandDiagnosticsSnapshot());
  return () => {
    commandDiagnosticsListeners.delete(listener);
  };
}

function recordCommandFailure(command: string, error: unknown) {
  const now = Date.now();
  const lastWarningAt = lastWarningAtByCommand.get(command) ?? 0;
  if (now - lastWarningAt < WARNING_THROTTLE_MS) {
    return;
  }

  lastWarningAtByCommand.set(command, now);
  const previous = commandDiagnosticsByName.get(command);
  commandDiagnosticsByName.set(command, {
    command,
    message: commandFailureMessage(error),
    occurredAt: new Date(now).toISOString(),
    count: (previous?.count ?? 0) + 1,
  });
  emitCommandDiagnostics();
  console.warn(`Tauri command failed: ${command}`, error);
}

function clearCommandFailure(command: string) {
  if (commandDiagnosticsByName.delete(command)) {
    emitCommandDiagnostics();
  }
}

function emitCommandDiagnostics() {
  const snapshot = getCommandDiagnosticsSnapshot();
  commandDiagnosticsListeners.forEach((listener) => listener(snapshot));
}

function commandFailureMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === "string") {
    return error;
  }
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}

export function getCodexHome(): Promise<CodexHomeStatus> {
  return callCommand("get_codex_home", fallbackCodexHome);
}

export function setCodexHome(path: string): Promise<CodexHomeStatus> {
  return callCommand("set_codex_home", { ...fallbackCodexHome, path, source: "manual" }, { path });
}

export function resetCodexHome(): Promise<CodexHomeStatus> {
  return callCommand("reset_codex_home", fallbackCodexHome);
}

export function readAppSettings(): Promise<AppSettingsSnapshot> {
  return callCommand("read_app_settings", fallbackAppSettings);
}

export function saveFloatingSettings(settings: FloatingWindowSettings): Promise<AppSettingsSnapshot> {
  return callCommand("save_floating_settings", fallbackAppSettings, { settings });
}

export function saveFloatingPosition(position: FloatingWindowPosition): Promise<AppSettingsSnapshot> {
  return callCommand("save_floating_position", fallbackAppSettings, { position });
}

export function saveDisplaySurfaces(display: DisplaySurfaceSettings): Promise<AppSettingsSnapshot> {
  return callCommand("save_display_surfaces", fallbackAppSettings, { display });
}

export function saveSetupGuideCompleted(completed: boolean): Promise<AppSettingsSnapshot> {
  return callCommand("save_setup_guide_completed", fallbackAppSettings, { completed });
}

export function readPlatformCapabilities(): Promise<PlatformCapabilities> {
  return callCommand("read_platform_capabilities", fallbackPlatformCapabilities);
}

export function readDashboardSnapshot(): Promise<DashboardSnapshot> {
  return callCommand("read_dashboard_snapshot", emptyDashboardSnapshot());
}

export function readPreciseDashboardSnapshot(): Promise<DashboardSnapshot> {
  return callCommand("read_precise_dashboard_snapshot", emptyDashboardSnapshot(), undefined, 30_000);
}

export function readAccountQuota(forceRefresh = false): Promise<AccountQuotaBundle> {
  return callCommand(
    "read_account_quota",
    emptyAccountQuotaBundle(),
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

export function scanProviderRepair(): Promise<ProviderRepairSnapshot> {
  return callCommand("scan_provider_repair", fallbackProviderRepairSnapshot, undefined, 20_000);
}

export function listProviderBackups(): Promise<ProviderRepairBackupInfo[]> {
  return callCommand("list_provider_backups", [], undefined, 20_000);
}

export function createProviderBackup(): Promise<ProviderRepairActionResult> {
  return callCommand("create_provider_backup", fallbackProviderRepairActionResult, undefined, 60_000);
}

export function syncProviderHistory(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommand("sync_provider_history", fallbackProviderRepairActionResult, { backupId }, 60_000);
}

export function verifyProviderRepair(): Promise<ProviderRepairActionResult> {
  return callCommand("verify_provider_repair", fallbackProviderRepairActionResult, undefined, 30_000);
}

export function rollbackProviderBackup(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommand("rollback_provider_backup", fallbackProviderRepairActionResult, { backupId }, 60_000);
}
