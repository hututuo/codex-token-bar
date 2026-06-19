import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  UnreadSummary,
} from "../types/dashboard";
import {
  emptyDashboardSnapshot,
  emptyFloatingPanelSnapshot,
  emptyLiveRateSnapshot,
  emptyUnreadSummary,
  fallbackCodexHome,
  fallbackPlatformCapabilities,
} from "./fallback";
import {
  callCommand,
  callCommandOptional,
  callCommandStrict,
  getCommandDiagnosticsSnapshot,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
} from "./command";

export {
  getCommandDiagnosticsSnapshot,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
};

export {
  readAppSettings,
  readAutostartStatus,
  saveDisplaySurfaces,
  saveFloatingPosition,
  saveFloatingSettings,
  saveSetupGuideCompleted,
  setAutostartEnabled,
} from "./settingsClient";

export {
  createProviderBackup,
  listProviderBackups,
  rollbackProviderBackup,
  scanProviderRepair,
  syncProviderHistory,
  verifyProviderRepair,
} from "./providerRepairClient";

export function getCodexHome(): Promise<CodexHomeStatus> {
  return callCommand("get_codex_home", fallbackCodexHome);
}

export function setCodexHome(path: string): Promise<CodexHomeStatus> {
  return callCommandStrict<CodexHomeStatus>("set_codex_home", { path });
}

export function resetCodexHome(): Promise<CodexHomeStatus> {
  return callCommandStrict<CodexHomeStatus>("reset_codex_home");
}

export function recordStartupEvent(label: string): Promise<boolean> {
  return callCommand("record_startup_event", false, { label }, 1_000);
}

export function readPlatformCapabilities(): Promise<PlatformCapabilities> {
  return callCommand("read_platform_capabilities", fallbackPlatformCapabilities);
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
