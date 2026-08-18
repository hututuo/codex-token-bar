import type {
  CodexHomeStatus,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import type { CommandFailureDiagnostic } from "../api/client";
import { initialDashboardState } from "./dashboardDefaults";
import { mergeWarningDiagnostics, mergeWarnings } from "./dashboardWarnings";

export interface DashboardAppState {
  codexHome: CodexHomeStatus | null;
  platform: PlatformCapabilities | null;
  dashboard: DashboardSnapshot | null;
  liveRate: LiveRateSnapshot | null;
  liveThreadOptions: LiveThreadOption[];
  repair: ProviderRepairSnapshot | null;
  diagnostics: CommandFailureDiagnostic[];
  loading: boolean;
}

export interface DashboardReadyState {
  codexHome: CodexHomeStatus;
  platform: PlatformCapabilities;
  dashboard: DashboardSnapshot;
  liveRate: LiveRateSnapshot;
  liveThreadOptions: LiveThreadOption[];
  repair: ProviderRepairSnapshot;
  diagnostics: CommandFailureDiagnostic[];
}

/**
 * Compact state-sqlite startup data intentionally contains a zero-valued
 * placeholder canvas. It is useful as a hint, but must not flip the app to a
 * ready dashboard. A non-fresh snapshot with a real coverage timestamp is the
 * trusted last-good stale case and remains displayable.
 */
export function dashboardSnapshotHasTrustedStartupData(snapshot: DashboardSnapshot): boolean {
  const coveredAt = snapshot.preciseRecentUsageCoveredAt;
  const hasCoverage = typeof coveredAt === "string"
    && coveredAt.trim().length > 0
    && Number.isFinite(Date.parse(coveredAt));
  // A last-good stale snapshot is still trusted for display when it carries a
  // valid precise coverage boundary; freshness is reported separately.
  if (hasCoverage) {
    return true;
  }

  // Older published caches may contain a real dashboard but no coverage
  // watermark (the watermark was introduced after those caches were written).
  // Do not replace that useful data with an all-zero placeholder while the
  // current precise owner is rebuilding the watermark. A genuinely empty
  // account still fails closed and waits for the first exact result.
  return hasMaterializedStartupData(snapshot);
}

function hasMaterializedStartupData(snapshot: DashboardSnapshot): boolean {
  const stats = snapshot.stats;
  const hasStats = [
    stats.totalTokens,
    stats.peakDayTokens,
    stats.peakThreadTokens,
    stats.totalCalls,
    stats.totalThreads,
  ].some((value) => Number.isFinite(value) && value > 0);
  if (hasStats) {
    return true;
  }

  const hasUsageHistory = snapshot.activityDays.some((day) => (
    (Number.isFinite(day.tokens) && day.tokens > 0)
      || (Number.isFinite(day.calls) && day.calls > 0)
  )) || [snapshot.recentUsage24h, snapshot.recentUsage7d, snapshot.recentUsage30d]
    .some((points) => points.some((point) => (
      (Number.isFinite(point.tokens) && point.tokens > 0)
        || (Number.isFinite(point.calls) && point.calls > 0)
    )));
  if (hasUsageHistory || snapshot.cacheHitRanking.length > 0) {
    return true;
  }

  const hasMeasuredQuota = snapshot.quota.fiveHour.availability === "measured"
    || snapshot.quota.sevenDay.availability === "measured";
  const accountName = snapshot.account.displayName.trim();
  return hasMeasuredQuota
    || (accountName.length > 0
      && !["读取中", "账户待读取", "未知账户", "本地用户", "计划待读取"].includes(accountName));
}

export function readyDashboardState(state: DashboardAppState): DashboardReadyState | null {
  if (
    state.codexHome === null ||
    state.platform === null ||
    state.dashboard === null ||
    state.liveRate === null ||
    state.repair === null
    || !dashboardSnapshotHasTrustedStartupData(state.dashboard)
  ) {
    return null;
  }

  return {
    codexHome: state.codexHome,
    platform: state.platform,
    dashboard: state.dashboard,
    liveRate: state.liveRate,
    liveThreadOptions: state.liveThreadOptions,
    repair: state.repair,
    diagnostics: mergeWarningDiagnostics(
      state.diagnostics,
      mergeWarnings(state.dashboard.warnings, state.liveRate.warnings),
      state.dashboard.generatedAt,
    ),
  };
}

export function visibleDashboardState(state: DashboardAppState): DashboardReadyState {
  const ready = readyDashboardState(state);
  if (ready !== null) {
    return ready;
  }

  const pending = pendingDashboardReadyState();
  return state.codexHome === null
    ? pending
    : { ...pending, codexHome: state.codexHome };
}

export function pendingDashboardReadyState(): DashboardReadyState {
  // `readyDashboardState` deliberately returns null until a precise coverage
  // boundary exists.  The React shell still needs a complete, non-null render
  // model while that first read is in flight; casting the ready result here
  // used to turn the null into `{ codexHome }`, leaving `dashboard` undefined
  // and crashing the first render at `dashboard.account`.
  const { codexHome, platform, dashboard, liveRate, liveThreadOptions, repair, diagnostics } =
    initialDashboardState;
  if (
    codexHome === null ||
    platform === null ||
    dashboard === null ||
    liveRate === null ||
    repair === null
  ) {
    throw new Error("initialDashboardState must provide a complete pending dashboard");
  }

  return {
    codexHome,
    platform,
    dashboard,
    liveRate,
    liveThreadOptions,
    repair,
    diagnostics: mergeWarningDiagnostics(
      diagnostics,
      mergeWarnings(dashboard.warnings, liveRate.warnings),
      dashboard.generatedAt,
    ),
  };
}

export {
  disabledLiveRateSnapshot,
  initialDashboardState,
  pendingLiveRateSnapshot,
  pendingRepairSnapshot,
} from "./dashboardDefaults";
export {
  mergeLiveRate,
  mergeLiveThreadOptions,
  clearPreciseAttributionSafety,
  markPreciseRecentUsageStale,
  mergePreciseDashboard,
  mergeQuota,
  mergeResetCredits,
} from "./dashboardMergers";
