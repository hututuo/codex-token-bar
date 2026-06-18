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

async function callCommand<T>(command: string, fallback: T, args?: Record<string, unknown>): Promise<T> {
  if (!isTauriRuntime) {
    return fallback;
  }

  try {
    return await invoke<T>(command, args);
  } catch (error) {
    console.warn(`Tauri command failed: ${command}`, error);
    return fallback;
  }
}

export function getCodexHome(): Promise<CodexHomeStatus> {
  return callCommand("get_codex_home", mockCodexHome);
}

export function readDashboardSnapshot(): Promise<DashboardSnapshot> {
  return callCommand("read_dashboard_snapshot", mockDashboardSnapshot);
}

export function readPreciseDashboardSnapshot(): Promise<DashboardSnapshot> {
  return callCommand("read_precise_dashboard_snapshot", mockDashboardSnapshot);
}

export function readAccountQuota(): Promise<AccountQuotaBundle> {
  return callCommand("read_account_quota", mockAccountQuotaBundle);
}

export function readLiveRateSnapshot(): Promise<LiveRateSnapshot> {
  return callCommand("read_live_rate_snapshot", mockLiveRateSnapshot);
}

export function readFloatingPanelSnapshot(): Promise<FloatingPanelSnapshot> {
  return callCommand("read_floating_snapshot", mockFloatingPanelSnapshot);
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
  return callCommand("scan_provider_repair", mockProviderRepairSnapshot);
}

export function listProviderBackups(): Promise<ProviderRepairBackupInfo[]> {
  return callCommand("list_provider_backups", mockProviderRepairBackups);
}

export function createProviderBackup(): Promise<ProviderRepairActionResult> {
  return callCommand("create_provider_backup", mockProviderRepairActionResult);
}

export function syncProviderHistory(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommand("sync_provider_history", mockProviderRepairActionResult, { backupId });
}

export function verifyProviderRepair(): Promise<ProviderRepairActionResult> {
  return callCommand("verify_provider_repair", mockProviderRepairActionResult);
}

export function rollbackProviderBackup(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommand("rollback_provider_backup", mockProviderRepairActionResult, { backupId });
}
