import type {
  AccountQuotaBundle,
  CodexHomeSourceEnvelope,
  DashboardSnapshot,
  PlatformCapabilities,
  UsageSummarySnapshot,
  UsageCacheStatus,
} from "../types/dashboard";
import {
  emptyDashboardSnapshot,
  fallbackPlatformCapabilities,
} from "./fallback";
import { callCommand, callCommandOptional, callCommandStrict } from "./command";

export function getCodexHome(): Promise<CodexHomeSourceEnvelope | null> {
  return callCommandOptional("get_codex_home");
}

export function setCodexHome(path: string): Promise<CodexHomeSourceEnvelope> {
  return callCommandStrict<CodexHomeSourceEnvelope>("set_codex_home", { path });
}

export function resetCodexHome(): Promise<CodexHomeSourceEnvelope> {
  return callCommandStrict<CodexHomeSourceEnvelope>("reset_codex_home");
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

export function readUsageSummarySnapshot(): Promise<UsageSummarySnapshot | null> {
  return callCommandOptional("read_usage_summary_snapshot", undefined, 8_000);
}

export function readUsageCacheStatus(): Promise<UsageCacheStatus> {
  return callCommand("read_usage_cache_status", {
    namespace: "tauri-usage-cache-2026-07-v5",
    initialized: true,
    initializedAt: null,
  });
}

export function readAccountQuota(forceRefresh = false): Promise<AccountQuotaBundle | null> {
  return callCommandOptional(
    "read_account_quota",
    { forceRefresh },
    90_000,
  );
}
