import type {
  AccountQuotaBundle,
  CodexHomeSourceEnvelope,
  CodexHomeSourceToken,
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

export function readDashboardSnapshot(
  sourceToken: CodexHomeSourceToken,
): Promise<DashboardSnapshot> {
  return callCommand("read_dashboard_snapshot", emptyDashboardSnapshot(), { sourceToken });
}

export function readPreciseDashboardSnapshot(
  sourceToken: CodexHomeSourceToken,
): Promise<DashboardSnapshot | null> {
  // This native read owns a serialized, potentially multi-minute index sync.
  // A JavaScript-only timeout cannot cancel it and only creates another queued
  // read on the next refresh, so wait for the real native outcome.
  return callCommandOptional("read_precise_dashboard_snapshot", { sourceToken }, null);
}

export function readUsageSummarySnapshot(
  sourceToken: CodexHomeSourceToken,
): Promise<UsageSummarySnapshot | null> {
  return callCommandOptional("read_usage_summary_snapshot", { sourceToken }, 8_000);
}

export function readUsageCacheStatus(): Promise<UsageCacheStatus> {
  return callCommand("read_usage_cache_status", {
    namespace: "tauri-usage-cache-2026-07-v6",
    initialized: true,
    initializedAt: null,
  });
}

export function readAccountQuota(
  sourceToken: CodexHomeSourceToken,
  forceRefresh = false,
): Promise<AccountQuotaBundle | null> {
  return callCommandOptional(
    "read_account_quota",
    { forceRefresh, sourceToken },
    90_000,
  );
}
