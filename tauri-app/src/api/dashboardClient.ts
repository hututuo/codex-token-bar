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

// The cold local index read is still a startup operation, but it must have a
// finite safety boundary. Four seconds is the generic IPC budget for small
// commands; this longer bound covers one cold dashboard read without turning a
// real hung native command into an endless loading state.
export const STARTUP_DASHBOARD_COMMAND_TIMEOUT_MS = 30_000;

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
  // A cold local index can legitimately take longer than the generic 4 second
  // command budget. JavaScript cannot cancel the native IPC, so racing this
  // read against that budget publishes the empty fallback as a false failure
  // while the native command is still running. Keep the existing loading state
  // until the native result arrives; a real native rejection, or a read that
  // exceeds the explicit 30 second startup safety boundary, still records the
  // command diagnostic and returns the empty fallback through callCommand.
  return callCommand(
    "read_dashboard_snapshot",
    emptyDashboardSnapshot(),
    { sourceToken },
    STARTUP_DASHBOARD_COMMAND_TIMEOUT_MS,
  );
}

export function readPreciseDashboardSnapshot(
  sourceToken: CodexHomeSourceToken,
): Promise<DashboardSnapshot | null> {
  // This native read owns a serialized, potentially multi-minute index sync.
  // A JavaScript-only timeout cannot cancel it and only creates another queued
  // read on the next refresh, so wait for the real native outcome.
  return callCommandOptional("read_precise_dashboard_snapshot", { sourceToken }, null);
}

export function acknowledgeAttributionSafety(
  sourceToken: CodexHomeSourceToken,
  provenanceEpoch: string,
  unsafeID: string,
  throughGeneration: number,
): Promise<boolean> {
  return callCommandStrict<boolean>("acknowledge_attribution_safety", {
    provenanceEpoch,
    sourceToken,
    throughGeneration,
    unsafeId: unsafeID,
  });
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
