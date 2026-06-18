import { invoke } from "@tauri-apps/api/core";
import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import {
  mockAccountQuotaBundle,
  mockCodexHome,
  mockDashboardSnapshot,
  mockFloatingPanelSnapshot,
  mockLiveRateSnapshot,
  mockProviderRepairSnapshot,
} from "./mock";

const isTauriRuntime = "__TAURI_INTERNALS__" in window;

async function callCommand<T>(command: string, fallback: T): Promise<T> {
  if (!isTauriRuntime) {
    return fallback;
  }

  try {
    return await invoke<T>(command);
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

export function scanProviderRepair(): Promise<ProviderRepairSnapshot> {
  return callCommand("scan_provider_repair", mockProviderRepairSnapshot);
}
