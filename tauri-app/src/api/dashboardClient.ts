import type {
  AccountQuotaBundle,
  CodexHomeSourceEnvelope,
  CodexHomeSourceToken,
  DashboardSnapshot,
  PreciseDashboardProgress,
  PreciseDashboardRefreshReason,
  PreciseDashboardSourceProbe,
  PlatformCapabilities,
  UsageSummarySnapshot,
  UsageCacheStatus,
} from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import {
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
): Promise<DashboardStartupRead> {
  // A cold local index can legitimately take longer than the generic 4 second
  // command budget. JavaScript cannot cancel the native IPC, so racing this
  // read against an arbitrary deadline publishes the empty fallback as a false
  // failure while the native command is still running. Keep the existing
  // loading state until the native operation itself succeeds or rejects.
  return callCommandOptional<DashboardSnapshot>(
    "read_dashboard_snapshot",
    { sourceToken },
    null,
  ).then((snapshot) => snapshot === null
    ? { status: "unavailable", snapshot: null }
    : {
        status: snapshot.preciseRecentUsageFresh ? "success" : "stale",
        snapshot,
      });
}

export type DashboardStartupRead =
  | { status: "success" | "stale"; snapshot: DashboardSnapshot }
  | { status: "unavailable"; snapshot: null };

export function readPreciseDashboardSnapshot(
  sourceToken: CodexHomeSourceToken,
  requestReason?: PreciseDashboardRefreshReason,
): Promise<DashboardSnapshot | null> {
  // This native read owns a serialized, potentially multi-minute index sync.
  // A JavaScript-only timeout cannot cancel it and only creates another queued
  // read on the next refresh, so wait for the real native outcome.
  const args: Record<string, unknown> = { sourceToken };
  if (requestReason !== undefined) {
    args.requestReason = requestReason;
  }
  return callCommandOptional("read_precise_dashboard_snapshot", args, null);
}

export function readPreciseDashboardProgress(
  sourceToken: CodexHomeSourceToken,
): Promise<PreciseDashboardProgress | null> {
  // Process-local status only: this command never opens the SQLite index and
  // therefore cannot create a second migration/scanner owner.
  return callCommandOptional(
    "read_precise_dashboard_progress",
    { sourceToken },
    null,
  );
}

export function readPreciseDashboardSourceProbe(
  sourceToken: CodexHomeSourceToken,
): Promise<PreciseDashboardSourceProbe | null> {
  // This probe only compares the published session-file metadata with the
  // current source. It deliberately does not scan JSONL bodies; a changed,
  // unknown, or failed probe falls back to the serialized precise owner.
  return callCommandOptional(
    "read_precise_dashboard_source_probe",
    { sourceToken },
    null,
  );
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
  // Native `Ok(None)` is an expected initializing/cache-miss state. A rejected
  // command remains a real I/O/schema/source failure and must stay visible in
  // diagnostics, so do not collapse both cases through callCommandOptional.
  return callCommandStrict<UsageSummarySnapshot | null>(
    "read_usage_summary_snapshot",
    { sourceToken },
    8_000,
  );
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

export function readAccountResetCredits(
  sourceToken: CodexHomeSourceToken,
  forceRefresh = false,
): Promise<ResetCreditBundle | null> {
  return callCommandOptional(
    "read_account_reset_credits",
    { forceRefresh, sourceToken },
    30_000,
  );
}
