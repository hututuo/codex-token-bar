import { invoke } from "@tauri-apps/api/core";
import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import {
  mockAccountQuotaBundle,
  mockCodexHome,
  mockDashboardSnapshot,
  mockFloatingPanelSnapshot,
  mockLiveRateSnapshot,
  mockProviderRepairActionResult,
  mockProviderRepairBackups,
  mockProviderRepairSnapshot,
} from "./mock";

const isTauriRuntime = "__TAURI_INTERNALS__" in window;
const DEFAULT_COMMAND_TIMEOUT_MS = 4_000;

async function callCommand<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T> {
  if (!isTauriRuntime) {
    return fallback;
  }

  try {
    return await withTimeout(invoke<T>(command, args), timeoutMs);
  } catch (error) {
    console.warn(`Tauri command failed: ${command}`, error);
    return fallback;
  }
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: number | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = window.setTimeout(() => {
      reject(new Error(`Command timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });

  return Promise.race([promise, timeout]).finally(() => {
    if (timer !== undefined) {
      window.clearTimeout(timer);
    }
  });
}

export function getCodexHome(): Promise<CodexHomeStatus> {
  return callCommand("get_codex_home", mockCodexHome);
}

export function setCodexHome(path: string): Promise<CodexHomeStatus> {
  return callCommand("set_codex_home", { ...mockCodexHome, path, source: "manual" }, { path });
}

export function resetCodexHome(): Promise<CodexHomeStatus> {
  return callCommand("reset_codex_home", mockCodexHome);
}

export function readDashboardSnapshot(): Promise<DashboardSnapshot> {
  return callCommand("read_dashboard_snapshot", mockDashboardSnapshot);
}

export function readPreciseDashboardSnapshot(): Promise<DashboardSnapshot> {
  return callCommand("read_precise_dashboard_snapshot", mockDashboardSnapshot, undefined, 30_000);
}

export function readAccountQuota(): Promise<AccountQuotaBundle> {
  return callCommand("read_account_quota", mockAccountQuotaBundle, undefined, 12_000);
}

export function readLiveRateSnapshot(): Promise<LiveRateSnapshot> {
  return callCommand("read_live_rate_snapshot", mockLiveRateSnapshot, undefined, 1_500);
}

export function readFloatingPanelSnapshot(): Promise<FloatingPanelSnapshot> {
  return callCommand("read_floating_snapshot", mockFloatingPanelSnapshot, undefined, 1_500);
}

export function showFloatingWindow(): Promise<boolean> {
  return callCommand("show_floating_window", true);
}

export function hideFloatingWindow(): Promise<boolean> {
  return callCommand("hide_floating_window", false);
}

export function setStatusTrayReadout(title: string, tooltip: string): Promise<boolean> {
  if (!isTauriRuntime) {
    return Promise.resolve(false);
  }

  return callCommand("set_status_tray_readout", false, { title, tooltip });
}

export function scanProviderRepair(): Promise<ProviderRepairSnapshot> {
  return callCommand("scan_provider_repair", mockProviderRepairSnapshot, undefined, 20_000);
}

export function listProviderBackups(): Promise<ProviderRepairBackupInfo[]> {
  return callCommand("list_provider_backups", mockProviderRepairBackups, undefined, 20_000);
}

export function createProviderBackup(): Promise<ProviderRepairActionResult> {
  return callCommand("create_provider_backup", mockProviderRepairActionResult, undefined, 60_000);
}

export function syncProviderHistory(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommand("sync_provider_history", mockProviderRepairActionResult, { backupId }, 60_000);
}

export function verifyProviderRepair(): Promise<ProviderRepairActionResult> {
  return callCommand("verify_provider_repair", mockProviderRepairActionResult, undefined, 30_000);
}

export function rollbackProviderBackup(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommand("rollback_provider_backup", mockProviderRepairActionResult, { backupId }, 60_000);
}
