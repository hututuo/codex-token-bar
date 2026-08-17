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
  return hasCoverage && (snapshot.preciseRecentUsageFresh === true || hasCoverage);
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
  return readyDashboardState(initialDashboardState) as DashboardReadyState;
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
  markPreciseRecentUsageStale,
  mergePreciseDashboard,
  mergeQuota,
  mergeResetCredits,
} from "./dashboardMergers";
